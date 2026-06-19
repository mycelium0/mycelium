// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package tune is the Phase-2 self-tuner (RP-0010 Plane 3, the ADR-0031 ADOPT verdict). It maintains a
// per-(transport-class, path) Weight using STANDARD, named prior art — no novel network biology (the
// "fungal" / Physarum framing is METAPHOR only, ADR-0031). The implemented law is, precisely:
//   - an EWMA / exponential-smoothing update toward a goodness target — each good connectivity Verdict
//     smooths the weight upward by Reinforce*goodness*(1-w) (Robbins-Monro / exponential forgetting);
//   - an exponential time-decay-to-floor by HalfLife — a just-degraded shape fades WITHOUT explicit
//     teardown and re-promotes automatically when a block lifts;
//   - a control-theory Schmitt-trigger Hysteresis band that damps flapping of the promote decision.
// RetentionFloor is a bespoke "scar memory" term: a repeatedly-blocked shape settles low (not eagerly
// retried) but is never forgotten. The reinforce-and-evaporate / Physarum / ant-colony imagery is a
// useful METAPHOR for that decay-and-scar intuition — NOT a citation; the code implements EWMA +
// exponential decay + hysteresis on spec.DecayPolicy, not the Tero-2010 tube-conductivity model.
//
// It is a SCORING layer only. The weight is a ranking input; it NEVER auto-bans, force-routes, or
// hard-trusts (ADR-0025 / RP-0010 AC-4 advisory-never-actuates). The package is pure: it imports
// only internal/spec + pure stdlib (math, time), starts no goroutines, and performs no I/O,
// networking, or process execution — the tuner_pure_advisory conformance gate enforces that. The
// actuation that consumes the ranking (auto-rotation) is a later RP-0010 chunk.
package tune

import (
	"fmt"
	"math"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

// Params configures the self-tuner. Decay is the ADOPTed evaporation shape (spec.DecayPolicy:
// HalfLife + RetentionFloor + Hysteresis); the remaining knobs are the tuner's own. Every parameter
// is named and configurable (development.md §2.2) — no magic constants in the law.
type Params struct {
	Decay spec.DecayPolicy // evaporation shape: HalfLife decay, RetentionFloor floor, Hysteresis band
	// Reinforce is the [0,1] gain applied to a good observation: a Verdict of goodness g raises the
	// weight by Reinforce*g*(1-weight), so a clean shape climbs and a blocked one barely moves.
	Reinforce float64
	// PromoteThreshold is the [0,1] weight around which a path is considered selection-worthy; the
	// Decay.Hysteresis band straddles it so the promote/demote flag does not flap.
	PromoteThreshold float64
	// Initial is the starting weight for a freshly-seen path, in [RetentionFloor, 1].
	Initial float64
}

// DefaultParams returns the documented Phase-2 defaults: a 30-minute decay half-life with a 5% scar
// floor and a 10% hysteresis band, a half-strength reinforcement gain, promotion around the
// mid-point, and a neutral mid-point start.
func DefaultParams() Params {
	return Params{
		Decay: spec.DecayPolicy{
			TTL:            24 * time.Hour,
			HalfLife:       30 * time.Minute,
			Hysteresis:     0.1,
			RetentionFloor: 0.05,
		},
		Reinforce:        0.5,
		PromoteThreshold: 0.5,
		Initial:          0.5,
	}
}

// Validate checks the tuner is internally consistent: a valid decay policy, gains/thresholds in
// [0,1] (the !(>=0 && <=1) form rejects NaN), an Initial at/above the floor, and a hysteresis band
// that fits within [0,1] around the promote threshold. Pure.
func (p Params) Validate() error {
	if err := p.Decay.Validate(); err != nil {
		return fmt.Errorf("tune params decay: %w", err)
	}
	if !(p.Reinforce >= 0 && p.Reinforce <= 1) {
		return fmt.Errorf("tune params: reinforce %v not in [0,1]", p.Reinforce)
	}
	if !(p.PromoteThreshold >= 0 && p.PromoteThreshold <= 1) {
		return fmt.Errorf("tune params: promote_threshold %v not in [0,1]", p.PromoteThreshold)
	}
	if !(p.Initial >= p.Decay.RetentionFloor && p.Initial <= 1) {
		return fmt.Errorf("tune params: initial %v not in [retention_floor %v, 1]", p.Initial, p.Decay.RetentionFloor)
	}
	half := p.Decay.Hysteresis / 2
	if p.PromoteThreshold+half > 1 {
		return fmt.Errorf("tune params: hysteresis high edge %v exceeds 1", p.PromoteThreshold+half)
	}
	// The band edges must be REACHABLE within the attainable weight interval, else the promote flag
	// latches: a low edge below RetentionFloor is never reached (the weight is floored), so the path
	// is un-demotable; and a high edge at the ceiling is never reached when Reinforce < 1 (a
	// fixed-gain reinforcement only asymptotes to 1), so the path is un-promotable.
	if p.PromoteThreshold-half < p.Decay.RetentionFloor {
		return fmt.Errorf("tune params: demote edge %v is below retention_floor %v (path would be un-demotable)",
			p.PromoteThreshold-half, p.Decay.RetentionFloor)
	}
	if p.PromoteThreshold+half >= 1 && p.Reinforce < 1 {
		return fmt.Errorf("tune params: promote edge %v is unreachable with reinforce %v < 1 (path would be un-promotable)",
			p.PromoteThreshold+half, p.Reinforce)
	}
	return nil
}

// goodness maps a connectivity state to the reinforcement target it earns, in [0,1]: a clean shape
// is fully reinforced, a throttled (still-carrying) shape partially, and blocked/shutdown earn no
// reinforcement so they evaporate toward the floor. Pure; the mapping is the law's semantic input,
// not a tunable.
func goodness(s spec.ConnState) float64 {
	switch s {
	case spec.ConnStateClean:
		return 1.0
	case spec.ConnStateThrottled:
		return 0.5
	default: // blocked, shutdown, unknown — no reinforcement
		return 0.0
	}
}

// Weight is the reinforce-and-evaporate weight of ONE transport path (class, transportRef). It is
// NOT safe for concurrent use; a caller serialises Observe/Value per path. It holds no I/O.
type Weight struct {
	class        spec.TransportClass
	transportRef string
	p            Params

	w         float64   // current weight in [RetentionFloor, 1]
	updatedAt time.Time // last time w was evaporated/reinforced
	promoted  bool      // hysteretic selection-worthiness flag
}

// NewWeight returns a Weight for one transport path, seeded at Params.Initial as of `at`. It is
// fail-closed (cf. detect.New): it refuses an unknown class, an empty transport reference, or
// invalid params. A cold path is conservatively promoted only if its seed already clears the
// hysteresis HIGH edge — the same edge a steady-state promotion must cross — so a fresh mid-band
// path starts un-promoted and must earn promotion.
func NewWeight(class spec.TransportClass, transportRef string, p Params, at time.Time) (*Weight, error) {
	if !class.IsValid() {
		return nil, fmt.Errorf("tune: refusing to build weight: %w: class %q", spec.ErrUnknownEnum, class)
	}
	if transportRef == "" {
		return nil, fmt.Errorf("tune: refusing to build weight: %w: transport_ref", spec.ErrEmptyField)
	}
	if err := p.Validate(); err != nil {
		return nil, fmt.Errorf("tune: refusing to build weight: %w", err)
	}
	w := &Weight{class: class, transportRef: transportRef, p: p, w: p.Initial, updatedAt: at}
	w.promoted = p.Initial >= p.PromoteThreshold+p.Decay.Hysteresis/2
	return w, nil
}

// evaporated returns the weight decayed from updatedAt to `at` toward RetentionFloor, without
// mutating. Time only moves forward: a non-positive interval leaves the weight unchanged (clock
// skew never reinforces). Pure.
func (w *Weight) evaporated(at time.Time) float64 {
	dt := at.Sub(w.updatedAt)
	if dt <= 0 {
		return w.w
	}
	floor := w.p.Decay.RetentionFloor
	factor := math.Exp2(-float64(dt) / float64(w.p.Decay.HalfLife))
	return floor + (w.w-floor)*factor
}

// Value returns the current weight as of `at` (evaporated to that instant) without mutating the
// Weight. It is the ranking input a selector reads; it never actuates.
func (w *Weight) Value(at time.Time) float64 { return w.evaporated(at) }

// Promoted reports the hysteretic selection-worthiness flag as last updated by Observe.
func (w *Weight) Promoted() bool { return w.promoted }

// Stale reports whether the path has gone unobserved for longer than the decay TTL — a hint that a
// registry may EVICT the Weight record entirely (distinct from evaporation, which only fades the
// score toward the floor). Pure; never actuates.
func (w *Weight) Stale(at time.Time) bool { return at.Sub(w.updatedAt) > w.p.Decay.TTL }

// Class and TransportRef expose the path identity (node-local; the ref carries no SNI/endpoint).
func (w *Weight) Class() spec.TransportClass { return w.class }
func (w *Weight) TransportRef() string       { return w.transportRef }

// Observe folds one connectivity Verdict in as of `at`: it first evaporates the weight toward the
// floor for the elapsed time, then reinforces by the verdict's goodness, clamps to
// [RetentionFloor, 1], and updates the Hysteresis-banded promote flag. A blocked verdict earns no
// reinforcement, so a blocked path fades toward the floor and re-promotes automatically once clean
// verdicts return — no teardown. The Verdict's class is checked against this Weight's path. An
// out-of-order (stale-stamped) verdict reinforces without evaporating and never rewinds the clock.
// NOTE: because each call evaporates-then-reinforces, the steady-state weight is cadence-sensitive —
// the same verdict mix fed at very different rates settles at different equilibria; that is a
// deliberate property of the discrete law, not a defect.
func (w *Weight) Observe(v spec.Verdict, at time.Time) error {
	if err := v.Validate(); err != nil {
		return fmt.Errorf("tune observe: %w", err)
	}
	if v.Class != w.class {
		return fmt.Errorf("tune observe: verdict class %q does not match weight class %q", v.Class, w.class)
	}

	decayed := w.evaporated(at)
	decayed += w.p.Reinforce * goodness(v.State) * (1 - decayed)

	// Clamp defensively: evaporate-toward-floor plus a non-negative reinforcement already keep the
	// value in [floor, 1]; this guards only against rounding / future-edit drift.
	floor := w.p.Decay.RetentionFloor
	if decayed < floor {
		decayed = floor
	} else if decayed > 1 {
		decayed = 1
	}
	w.w = decayed
	// Never rewind the clock: an out-of-order (stale-stamped) verdict reinforces against the current
	// weight without evaporating (evaporated() short-circuits dt<=0) and must NOT move updatedAt
	// backwards, or the next in-order verdict would over-evaporate across a too-long span.
	if at.After(w.updatedAt) {
		w.updatedAt = at
	}

	// Hysteresis-banded promotion: cross the high edge to promote, the low edge to demote, hold in
	// the band. Damps flapping of the selection decision around the threshold.
	half := w.p.Decay.Hysteresis / 2
	switch {
	case w.w >= w.p.PromoteThreshold+half:
		w.promoted = true
	case w.w <= w.p.PromoteThreshold-half:
		w.promoted = false
	}
	return nil
}
