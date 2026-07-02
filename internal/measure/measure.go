// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package measure is the Phase-2 MEASURE plane (RP-0010 Plane 1). It is the node-local seam that
// turns the already-built internal/reach health signal into the rotate.PlanInput the pure planner
// consumes, closing the adaptivity loop measure -> detect -> tune -> assemble -> plan.
//
// It WRAPs existing components and adds NO new measurement surface (RP-0010 AC-6): it consumes only
// reach's fast-class spec.TransportHealth (a success/failure window per opaque transport ref) and
// never dials, reads files, or runs a process. reach gathers only success/failure, not the
// per-observation fault by-products the classifier keys on, so the DetectorSignal is DERIVED from
// the window (see detectorSignal): a window with at least one success proves the channel connects
// and handshakes (ConnectOK = HandshakeOK = true); a window with zero successes proves no connection
// established (ConnectOK = false, which the classifier reads as a black-hole). The by-products reach
// never measures (active-probe / own-cert result, post-connect throughput collapse, single-stream
// comparison) are presented as NON-faulted so they cannot spuriously trigger, and the success RATIO
// then refines a connecting channel into clean vs throttled via the detector's hysteresis dead-zone.
// Measuring those finer signatures directly would need a richer probe the node does not run, and
// adding one would breach AC-6.
//
// Two consequences of that WRAP follow by design, not by oversight:
//   - The reach-only signal yields only Clean, Throttled (aggregate-degraded), or Shutdown (no
//     connection at all). The fine ConnStateBlocked signatures — connect-reset, active-probe failure,
//     post-connect throughput collapse — are structurally unreachable here because reach gathers none
//     of them; surfacing them awaits a richer, separately-gated probe plane. The planner treats
//     Shutdown and Throttled alike (both impaired), so the coarser naming does not change actuation.
//   - The fidelity of a "clean" verdict is bounded by what reach's probe actually exercises: a bare
//     TCP-connect anchor witnesses reachability, not the channel handshake, so a connect-OK but
//     handshake-blocked path can read clean. That is a reach probe-configuration property (use a
//     handshaking probe where the distinction matters), not something this plane can recover from an
//     opaque success/failure window.
//
// A zero-sample window (a registered ref with no probes in the window) is NOT folded: it is treated
// as no-data (like an absent member), so a transport whose probes merely lapsed is never mistaken for
// a dead one. A snapshot that repeats a ref is refused (fail-closed), so one window is never
// double-counted.
//
// It is strictly ADVISORY (RP-0010 AC-4): Tick only ASSEMBLES a plan input. It never rotates,
// applies, or transmits anything — actuation stays behind the RP-0012 triple gate. The fine
// ConnState/Verdict it folds through is node-local and never leaves the node (ADR-0030).
//
// The Assembler is stateful across ticks: it holds one detect.Detector (success-ratio hysteresis,
// anti-flap) and one tune.Weight (evaporating pheromone) per transport member, so a transient blip
// neither flips a verdict nor erases a member's accumulated standing. Folding the same snapshot
// stream yields the same plan inputs (deterministic; time is injected, never read internally).
package measure

import (
	"fmt"
	"sort"
	"time"

	"github.com/mycelium0/mycelium/internal/detect"
	"github.com/mycelium0/mycelium/internal/rotate"
	"github.com/mycelium0/mycelium/internal/spec"
	"github.com/mycelium0/mycelium/internal/tune"
)

// Member describes one transport member the node serves and can rotate among. It links the opaque
// reach health ref (the join key onto a snapshot) to the closed-registry proto and the move that
// promotes this member. Class is NOT carried — it is derived from Proto via the closed transport
// registry (the single source of truth), so a Member cannot disagree with the registry. Action is
// the promote move for this member when it is a candidate; the Assembler emits RotationActionNone
// for whichever member is currently active (an incumbent makes no move).
type Member struct {
	Ref      string              // opaque reach transport ref (joins TransportHealth -> this member); node-local, no SNI/endpoint
	Proto    string              // closed-registry proto id (spec.TransportRegistry)
	Action   spec.RotationAction // the move that promotes this member when it is a candidate
	FromPort int                 // current canonical port (0 if not port-toggled)
	ToPort   int                 // target canonical port (0 if unchanged / not toggled)
}

// Assembler is the node-local MEASURE plane. Build it once with the node's transport members and the
// detect/tune/rotation policies, then call Tick on each reach snapshot to obtain the current
// rotate.PlanInput. It is fail-closed at construction and on every tick.
type Assembler struct {
	order     []string          // member refs in declared order (stable rank tiebreak)
	members   map[string]Member // by ref
	class     map[string]spec.TransportClass
	detectors map[string]*detect.Detector // by ref, stateful across ticks
	weights   map[string]*tune.Weight     // by ref, stateful across ticks
	verdicts  map[string]spec.Verdict     // last verdict per ref, carried across ticks
	limits    spec.RotationLimits
}

// New builds an Assembler for the given members under the given policies. It is fail-closed (cf.
// detect.New, tune.NewWeight): it refuses an empty member set, an empty or duplicate ref, a proto
// outside the closed registry, an invalid rotation action, an out-of-range port, or detect/tune/
// rotation policies that do not validate — rather than silently trusting the caller. now seeds the
// per-member tuners' clocks.
func New(members []Member, limits spec.RotationLimits, th detect.Thresholds, p tune.Params, now time.Time) (*Assembler, error) {
	if len(members) == 0 {
		return nil, fmt.Errorf("measure: refusing to build assembler: %w: members", spec.ErrEmptyField)
	}
	if err := limits.Validate(); err != nil {
		return nil, fmt.Errorf("measure: refusing to build assembler: %w", err)
	}
	a := &Assembler{
		members:   make(map[string]Member, len(members)),
		class:     make(map[string]spec.TransportClass, len(members)),
		detectors: make(map[string]*detect.Detector, len(members)),
		weights:   make(map[string]*tune.Weight, len(members)),
		verdicts:  make(map[string]spec.Verdict, len(members)),
		limits:    limits,
	}
	seenProto := make(map[string]bool, len(members))
	for _, m := range members {
		if m.Ref == "" {
			return nil, fmt.Errorf("measure: refusing to build assembler: %w: member ref", spec.ErrEmptyField)
		}
		if _, dup := a.members[m.Ref]; dup {
			return nil, fmt.Errorf("measure: refusing to build assembler: duplicate member ref %q", m.Ref)
		}
		cls, ok := spec.ClassForProto(m.Proto)
		if !ok {
			return nil, fmt.Errorf("measure: refusing to build assembler: %w: member proto %q is not in the closed transport registry", spec.ErrUnknownEnum, m.Proto)
		}
		if seenProto[m.Proto] {
			// The planner keys candidate selection on proto (rotate.Plan skips c.Proto == active.Proto and
			// ranks by registry order), so two members sharing a proto would leave one permanently
			// un-selectable. Reject it, mirroring the duplicate-ref rejection.
			return nil, fmt.Errorf("measure: refusing to build assembler: duplicate member proto %q", m.Proto)
		}
		seenProto[m.Proto] = true
		if !m.Action.IsValid() {
			return nil, fmt.Errorf("measure: refusing to build assembler: %w: member %q action %q", spec.ErrUnknownEnum, m.Proto, m.Action)
		}
		if m.FromPort < 0 || m.FromPort > 65535 || m.ToPort < 0 || m.ToPort > 65535 {
			return nil, fmt.Errorf("measure: refusing to build assembler: member %q port out of range", m.Proto)
		}
		d, err := detect.New(cls, m.Ref, th)
		if err != nil {
			return nil, fmt.Errorf("measure: refusing to build assembler: %w", err)
		}
		w, err := tune.NewWeight(cls, m.Ref, p, now)
		if err != nil {
			return nil, fmt.Errorf("measure: refusing to build assembler: %w", err)
		}
		a.order = append(a.order, m.Ref)
		a.members[m.Ref] = m
		a.class[m.Ref] = cls
		a.detectors[m.Ref] = d
		a.weights[m.Ref] = w
		// Seed a valid, non-impaired verdict so a member not yet observed still assembles into a
		// well-formed (rotate.Plan-validatable) plan input that asserts no impairment — the planner
		// must never rotate on the absence of data. Overwritten on the member's first Observe.
		a.verdicts[m.Ref] = spec.Verdict{State: spec.ConnStateClean, Reason: spec.ReasonNone, Class: cls, TransportRef: m.Ref, DecidedAt: now}
	}
	return a, nil
}

// detectorSignal derives a DetectorSignal from one reach health window plus this ref's node-local L7
// liveness (RP-0010 AC-6 clarification). reach reports only success/failure counts, so the L4 flags
// are inferred from the window: at least one success proves the channel connected and (at the reach
// layer) handshaked at least once, while zero successes means no probe connected (ConnectOK false ->
// the classifier's shutdown branch). activeProbeOK carries the own-cert/cover-path L7 liveness (the
// Plane-2 "active-probe response failure" signal): a loopback own-keys handshake against this node's
// OWN listener, so a listener that is bound-but-client-DEAD at L7 (a broken REALITY dest, a bad
// own-cert) faults ActiveProbeOK -> the classifier's blocked branch, catching what the L4 reach window
// cannot see. Absent L7 evidence the caller passes true (non-faulted), preserving the pre-L7 behaviour;
// the remaining by-products reach does not measure (reset, post-connect collapse, single-stream) stay
// non-faulted so they never spuriously classify. A connecting-but-lossy channel with no boolean fault
// is then graded by the success ratio inside the detector, not here.
func detectorSignal(cls spec.TransportClass, h spec.TransportHealth, activeProbeOK bool) spec.DetectorSignal {
	connected := h.Successes > 0
	return spec.DetectorSignal{
		Class:         cls,
		Health:        h,
		ConnectOK:     connected,
		HandshakeOK:   connected,
		ActiveProbeOK: activeProbeOK,
		ObservedAt:    h.WindowEnd,
	}
}

// Tick folds one reach snapshot into the plane and assembles the current rotate.PlanInput. activeRef
// names the currently-active member (the incumbent). state is the caller-held between-tick rotation
// memory, passed straight through to the plan input. now is the injected clock. activeProbe maps a
// member ref to its node-local own-cert/cover-path L7 liveness (RP-0010 AC-6 clarification): an
// explicit false faults that ref's active-probe -> the classifier's blocked branch (catching an
// L7-dead listener the L4 window cannot see); a ref absent from the map, or a nil map, defaults to
// healthy (the pre-L7 behaviour, so a caller with no L7 signal folds exactly as before).
//
// A member present in the snapshot has its detector and tuner advanced; a member absent from the
// snapshot (no fresh samples this tick) keeps its carried verdict and is ranked on its decayed
// weight, read at now. A snapshot ref with no known member, or an unknown activeRef, is refused
// (fail-closed) rather than silently dropped. Deterministic for a given snapshot stream, clock, and
// activeProbe map.
func (a *Assembler) Tick(snapshot []spec.TransportHealth, activeRef string, state spec.RotationState, now time.Time, activeProbe map[string]bool) (rotate.PlanInput, error) {
	if _, ok := a.members[activeRef]; !ok {
		return rotate.PlanInput{}, fmt.Errorf("measure: tick: active ref %q is not a known member", activeRef)
	}
	// Fold each fresh health sample through its detector (verdict) then its tuner (weight).
	seen := make(map[string]bool, len(snapshot))
	for i := range snapshot {
		h := snapshot[i]
		cls, ok := a.class[h.TransportRef]
		if !ok {
			return rotate.PlanInput{}, fmt.Errorf("measure: tick: snapshot ref %q is not a known member", h.TransportRef)
		}
		// Fail closed on a malformed snapshot (mirrors New's duplicate-member rejection): a ref repeated
		// in one snapshot would fold a single window twice — advancing the detector's anti-flap count
		// and reinforcing the tuner twice at the same instant — making the result depend on repetition.
		if seen[h.TransportRef] {
			return rotate.PlanInput{}, fmt.Errorf("measure: tick: snapshot contains a duplicate ref %q", h.TransportRef)
		}
		seen[h.TransportRef] = true
		// A zero-sample window carries NO information (the probes lapsed or aged out of the window). Treat
		// it exactly like a member absent from the snapshot: do not fold it, so "no data" is never mistaken
		// for a confirmed black-hole (Successes==0 would otherwise drive ConnectOK=false -> Shutdown). The
		// member keeps its carried verdict and its weight evaporates on its own — decay, not a hard fault.
		if h.Successes == 0 && h.Failures == 0 {
			continue
		}
		// activeProbe carries this ref's node-local own-cert/cover-path L7 liveness; an unset ref (or a
		// nil map) defaults to healthy, so a caller with no L7 signal folds exactly as it did pre-L7.
		ap := true
		if activeProbe != nil {
			if live, ok := activeProbe[h.TransportRef]; ok {
				ap = live
			}
		}
		v, err := a.detectors[h.TransportRef].Observe(detectorSignal(cls, h, ap))
		if err != nil {
			return rotate.PlanInput{}, fmt.Errorf("measure: tick: observe %q: %w", h.TransportRef, err)
		}
		if err := a.weights[h.TransportRef].Observe(v, now); err != nil {
			return rotate.PlanInput{}, fmt.Errorf("measure: tick: reinforce %q: %w", h.TransportRef, err)
		}
		a.verdicts[h.TransportRef] = v
	}
	// Assemble a candidate per member (declared order), reading each weight at now so an
	// un-refreshed member ranks on its evaporated pheromone. The incumbent is split out as Active
	// (with no move); the rest become the ranked candidate pool.
	var active spec.RotationCandidate
	ranked := make([]spec.RotationCandidate, 0, len(a.order))
	for _, ref := range a.order {
		m := a.members[ref]
		c := spec.RotationCandidate{
			Proto:    m.Proto,
			Class:    a.class[ref],
			Action:   m.Action,
			FromPort: m.FromPort,
			ToPort:   m.ToPort,
			Promoted: a.weights[ref].Promoted(),
			Weight:   a.weights[ref].Value(now),
		}
		if ref == activeRef {
			c.Action = spec.RotationActionNone // the incumbent carries no move
			active = c
			continue
		}
		ranked = append(ranked, c)
	}
	// Stable weight-descending order: deterministic and human-readable. The planner does its own
	// margin selection over the pool, so this order is presentational, not load-bearing.
	sort.SliceStable(ranked, func(i, j int) bool { return ranked[i].Weight > ranked[j].Weight })

	return rotate.PlanInput{
		Active:        active,
		ActiveVerdict: a.verdicts[activeRef],
		Ranked:        ranked,
		Limits:        a.limits,
		State:         state,
		Now:           now,
	}, nil
}
