// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package rotate is the Phase-2 auto-rotation PLANNER (RP-0012, executing the RP-0010 Plane-3 ADAPT
// decision). It is the explicit
// Layer-2 rotation policy (development.md §2.2 #4 — no silent bypass) expressed as a pure decision:
// given a node's OWN connectivity verdict for the active transport, its OWN tuner-ranked candidate
// weights, the rotation limits, and the between-tick state, Plan returns a RotationPlan — either a
// hold (with a concrete reason) or a single rotation WITHIN the closed transport set. The executor
// that applies the plan reuses the existing node render -> validate (sing-box check) -> promote ->
// verify -> rollback path; this package never touches a node.
//
// It is pure and deterministic (same input -> byte-identical plan), imports only internal/spec +
// fmt + time, reads no wall clock (the clock is the `Now` parameter), starts no goroutine, and does
// NO I/O — the rotator_pure_planner gate enforces that. By construction the input carries only
// node-LOCAL signals (the active verdict + local weights), never a global/peer/digest signal, so a
// rotation can never be driven by a cross-node signal (AC-4 advisory-never-actuates); and a
// RotationCandidate must resolve in the closed TransportRegistry, so a rotation can never grow the
// protocol set (AC-5).
package rotate

import (
	"fmt"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

// DefaultRotationLimits returns the documented Phase-2 policy: rotate only after 3 consecutive
// impaired verdicts, only for a candidate beating the incumbent by 0.1, at most 2 rotations per hour
// and no more than one per 30 minutes, and a one-hour hold latch after a single rollback. MinInterval
// (30m) == Window/MaxPerWindow (1h / 2), so the cooldown alone bounds the rolling-window count (no
// boundary burst) — the rolling-window correctness invariant in spec.RotationLimits.Validate.
func DefaultRotationLimits() spec.RotationLimits {
	return spec.RotationLimits{
		FlipConfirmations:     3,
		MinWeightMargin:       0.1,
		MinInterval:           30 * time.Minute,
		Window:                time.Hour,
		MaxPerWindow:          2,
		MaxRollbacksPerWindow: 1,
		CooldownAfterRollback: time.Hour,
	}
}

// PlanInput is everything the planner needs for one decision. Every field is node-LOCAL: there is
// deliberately no field for a peer / global / digest signal (AC-4).
type PlanInput struct {
	Active        spec.RotationCandidate   `json:"active"`         // the currently-active transport member (its tuner weight is the incumbent)
	ActiveVerdict spec.Verdict             `json:"active_verdict"` // the node's own detector verdict for the active member
	Ranked        []spec.RotationCandidate `json:"ranked"`         // the node's own tuner-ranked candidate members (with weights + promote flags)
	Limits        spec.RotationLimits      `json:"limits"`         // the rotation policy
	State         spec.RotationState       `json:"state"`          // between-tick memory
	Now           time.Time                `json:"now"`            // injected clock (never read internally)
}

// impaired reports whether a connectivity state warrants considering a rotation (anything but a
// clean or not-yet-known channel).
func impaired(s spec.ConnState) bool {
	return s != spec.ConnStateClean && s != spec.ConnStateUnknown
}

// Plan is the pure rotation decision. It validates its inputs, advances the windowed/streak state,
// and applies the guard order (clean -> hysteresis -> cooldown -> rate/latch -> better-candidate);
// it emits a rotation only when every guard passes, otherwise a hold with a concrete reason. The
// returned plan always satisfies spec.RotationPlan.Validate.
func Plan(in PlanInput) (spec.RotationPlan, error) {
	if err := in.Limits.Validate(); err != nil {
		return spec.RotationPlan{}, fmt.Errorf("rotate plan: %w", err)
	}
	if err := in.Active.Validate(); err != nil {
		return spec.RotationPlan{}, fmt.Errorf("rotate plan active: %w", err)
	}
	if err := in.ActiveVerdict.Validate(); err != nil {
		return spec.RotationPlan{}, fmt.Errorf("rotate plan active verdict: %w", err)
	}
	for i := range in.Ranked {
		if err := in.Ranked[i].Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan candidate %d: %w", i, err)
		}
	}

	// Advance the rate-limit window and the impaired streak (pure; from State + Now). Only the
	// WINDOWED counters reset on a window roll; LastRotateAt and HoldUntil are deliberately carried
	// forward (the cooldown and the rollback latch span window boundaries), so the cooldown/latch
	// guards below read them from in.State while the rate guard reads the windowed ns.RotationsInWindow.
	ns := in.State
	if in.State.WindowStart.IsZero() || in.Now.Sub(in.State.WindowStart) >= in.Limits.Window {
		ns.WindowStart = in.Now
		ns.RotationsInWindow = 0
		ns.RollbacksInWindow = 0
	}
	if impaired(in.ActiveVerdict.State) {
		// Saturate at FlipConfirmations so a long hold/latch cannot grow the streak without bound.
		ns.ImpairedStreak = in.State.ImpairedStreak + 1
		if ns.ImpairedStreak > in.Limits.FlipConfirmations {
			ns.ImpairedStreak = in.Limits.FlipConfirmations
		}
	} else {
		ns.ImpairedStreak = 0
	}

	hold := func(reason spec.RotationReason, because string) (spec.RotationPlan, error) {
		p := spec.RotationPlan{
			Act: false, From: in.Active, Reason: reason, HeldBecause: because,
			NextState: ns, DecidedAt: in.Now,
		}
		p.To.Action = spec.RotationActionNone
		if err := p.Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan (hold) invalid: %w", err)
		}
		return p, nil
	}

	// Guard 1 — never rotate a healthy channel.
	if !impaired(in.ActiveVerdict.State) {
		return hold(spec.RotationReasonClean, "active member is clean/healthy")
	}
	// Guard 2 — rollback latch / explicit hold window.
	if in.Now.Before(in.State.HoldUntil) {
		return hold(spec.RotationReasonRollbackHold, "in post-rollback hold latch")
	}
	// Guard 3 — hysteresis: the impairment must persist FlipConfirmations times.
	if ns.ImpairedStreak < in.Limits.FlipConfirmations {
		return hold(spec.RotationReasonStreakTooShort, "impaired verdict has not persisted long enough")
	}
	// Guard 4 — cooldown since the last rotation.
	if !in.State.LastRotateAt.IsZero() && in.Now.Sub(in.State.LastRotateAt) < in.Limits.MinInterval {
		return hold(spec.RotationReasonInCooldown, "within min-interval of the last rotation")
	}
	// Guard 5 — per-window rotation budget (anti-beacon).
	if ns.RotationsInWindow >= in.Limits.MaxPerWindow {
		return hold(spec.RotationReasonNoBudget, "per-window rotation budget spent")
	}

	// Guard 6 — pick the best closed-set candidate that beats the incumbent by the margin.
	order := registryOrder()
	bestIdx, anyBetterByMargin := -1, false
	for i := range in.Ranked {
		c := in.Ranked[i]
		if c.Proto == in.Active.Proto {
			continue
		}
		if c.Weight < in.Active.Weight+in.Limits.MinWeightMargin {
			continue
		}
		anyBetterByMargin = true
		if !c.Promoted {
			continue
		}
		if bestIdx == -1 || better(c, in.Ranked[bestIdx], order) {
			bestIdx = i
		}
	}
	if bestIdx == -1 {
		if anyBetterByMargin {
			return hold(spec.RotationReasonTargetNotPromoted, "the best candidate is not tuner-promoted yet")
		}
		return hold(spec.RotationReasonNoBetterCandidate, "no closed-set candidate beats the incumbent by the margin")
	}

	// Act — rotate to the chosen candidate. C4a only ever promotes a healthy sibling; rotate-port /
	// regen-reality / demote-active are reserved for later chunks, so the action is normalised
	// unconditionally (a candidate's incoming Action is advisory only).
	to := in.Ranked[bestIdx]
	to.Action = spec.RotationActionPromoteSibling
	ns.LastRotateAt = in.Now
	ns.RotationsInWindow++
	ns.ImpairedStreak = 0
	p := spec.RotationPlan{
		Act: true, From: in.Active, To: to,
		Reason: spec.RotationReasonDegradedActive, NextState: ns, DecidedAt: in.Now,
	}
	if err := p.Validate(); err != nil {
		return spec.RotationPlan{}, fmt.Errorf("rotate plan (act) invalid: %w", err)
	}
	return p, nil
}

// RecordOutcome folds the executor's apply result back into the state. A successful promote needs no
// adjustment (Plan already advanced the window). A rollback spends the rollback budget, and once the
// budget is exhausted the planner LATCHES into a hold for CooldownAfterRollback (leave last-known-good
// running, stop the retry storm, surface for the operator). This budget-then-latch is exactly a
// CIRCUIT-BREAKER open->half-open transition (standard prior art); a vendored breaker (e.g. sony/
// gobreaker) was considered and the ~10-line bespoke latch kept deliberately, to preserve the package's
// zero-dependency purity (no net/os/syscall — the rotator_pure_planner gate) and the Mycelium-specific
// regen/port/sibling actuation it gates. Pure. CALL ORDER: it must run within the
// same tick that produced the plan's NextState (executor: persist NextState, apply, then RecordOutcome
// on the result before the next Plan), so the rollback budget lands in the correct window.
func RecordOutcome(state spec.RotationState, limits spec.RotationLimits, rolledBack bool, now time.Time) spec.RotationState {
	if !rolledBack {
		return state
	}
	s := state
	s.RollbacksInWindow++
	if s.RollbacksInWindow >= limits.MaxRollbacksPerWindow {
		s.HoldUntil = now.Add(limits.CooldownAfterRollback)
	}
	return s
}

// registryOrder maps each closed-set proto to its position in the canonical TransportRegistry, for
// deterministic tie-breaking (a lower index wins).
func registryOrder() map[string]int {
	reg := spec.TransportRegistry()
	m := make(map[string]int, len(reg))
	for i, d := range reg {
		m[d.Proto] = i
	}
	return m
}

// better reports whether candidate a should be preferred over b: higher weight wins; on an exact
// tie, the lower registry index wins (deterministic).
func better(a, b spec.RotationCandidate, order map[string]int) bool {
	if a.Weight != b.Weight {
		return a.Weight > b.Weight
	}
	return order[a.Proto] < order[b.Proto]
}
