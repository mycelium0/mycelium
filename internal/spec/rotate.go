// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"time"
)

// -----------------------------------------------------------------------------
// Auto-rotation schema — the inert types for RP-0012 (the auto-rotation actuation, which executes
// the RP-0010 Plane-3 ADAPT decision).
//
// This is pure, typed VOCABULARY + DATA SHAPES for the connectivity-rotation planner. The PURE
// decision (a RotationPlan from a RotationState + the local detector verdict + the local tuner
// ranking) lives in internal/rotate; the EXECUTOR that applies a plan reuses the existing node
// render -> validate (sing-box check) -> promote -> verify -> rollback path (no new apply mechanism).
//
// TWO GUARANTEES BY CONSTRUCTION:
//   - AC-5 (no protocol growth): RotationAction has NO "add-transport" member, and a
//     RotationCandidate whose Proto is not in the closed TransportRegistry fails Validate(). A
//     rotation can only ever move WITHIN the closed transport set.
//   - AC-4 (advisory never actuates): nothing here carries a global / peer / digest signal — a
//     rotation is decided only from a node's OWN local verdict + OWN tuner weights. The planner
//     input cannot represent a cross-node signal, so one can never drive an auto-ban / force-route.
// -----------------------------------------------------------------------------

// RotationAction is the CLOSED set of node-local rotation moves the planner may emit. There is
// deliberately NO "add-transport"/"new-proto" member — that is the AC-5 guarantee. Wire values are
// the lowercase strings below; never hardcode them (development.md §1.1).
type RotationAction string

const (
	// RotationActionUnknown is the zero value and is never a valid wire value.
	RotationActionUnknown RotationAction = ""
	// RotationActionNone is the explicit "no move" action (a hold plan carries it).
	RotationActionNone RotationAction = "none"
	// RotationActionPromoteSibling raises a healthier sibling transport (already in the closed set,
	// already served by this node) ahead of the degraded active one.
	RotationActionPromoteSibling RotationAction = "promote-sibling"
	// RotationActionRotatePort moves the active member to a different canonical port in its own
	// family (within the closed port map).
	RotationActionRotatePort RotationAction = "rotate-port"
	// RotationActionRegenReality regenerates only the REALITY keypair / shortID of a member (a
	// transport parameter, permitted per §2.2 #1) — never the node identity or the pinned donor SNI.
	RotationActionRegenReality RotationAction = "regen-reality"
	// RotationActionDemoteActive demotes the degraded active member (stops advertising it as primary)
	// without adding anything new.
	RotationActionDemoteActive RotationAction = "demote-active"
)

// IsValid reports whether the action is one of the canonical members. RotationActionNone is valid
// (the explicit hold action); only the zero value is invalid.
func (a RotationAction) IsValid() bool {
	switch a {
	case RotationActionNone, RotationActionPromoteSibling, RotationActionRotatePort,
		RotationActionRegenReality, RotationActionDemoteActive:
		return true
	default:
		return false
	}
}

// RotationReason is the CLOSED, enumerable cause a RotationPlan attributes its decision to — never
// free text, so every rotate/hold is countable and carries no PII. Wire values are the lowercase
// strings below; never hardcode them (development.md §1.1).
type RotationReason string

const (
	// RotationReasonUnknown is the zero value and is never a valid wire value.
	RotationReasonUnknown RotationReason = ""
	// RotationReasonDegradedActive is the only ACTED reason: the active member is degraded and a
	// better closed-set candidate was promoted.
	RotationReasonDegradedActive RotationReason = "degraded-active"
	// RotationReasonClean — the active member is clean/healthy; nothing to do (hold).
	RotationReasonClean RotationReason = "active-clean"
	// RotationReasonStreakTooShort — the impaired verdict has not persisted FlipConfirmations times
	// (hysteresis hold).
	RotationReasonStreakTooShort RotationReason = "streak-too-short"
	// RotationReasonInCooldown — within MinInterval of the last rotation, or within
	// CooldownAfterRollback (hold).
	RotationReasonInCooldown RotationReason = "in-cooldown"
	// RotationReasonRollbackHold — the rollback budget was exhausted and the planner is latched into
	// a hold (leave last-known-good running, stop the retry storm) until the latch expires (hold).
	RotationReasonRollbackHold RotationReason = "rollback-hold"
	// RotationReasonNoBetterCandidate — no closed-set candidate beats the incumbent by MinWeightMargin
	// (hold).
	RotationReasonNoBetterCandidate RotationReason = "no-better-candidate"
	// RotationReasonTargetNotPromoted — the best candidate is not tuner-promoted yet (hold).
	RotationReasonTargetNotPromoted RotationReason = "target-not-promoted"
)

// IsValid reports whether the reason is one of the canonical members (the zero value is invalid).
func (r RotationReason) IsValid() bool {
	switch r {
	case RotationReasonDegradedActive, RotationReasonClean, RotationReasonStreakTooShort,
		RotationReasonInCooldown, RotationReasonRollbackHold,
		RotationReasonNoBetterCandidate, RotationReasonTargetNotPromoted:
		return true
	default:
		return false
	}
}

// RotationCandidate is one transport member the planner ranks/selects. Weight is the node-local
// tuner score (copied in by the caller from tune.Weight.Value); Promoted mirrors the tuner's
// hysteretic promote flag; L7Dead mirrors this node's own L7 own-cert/cover-path liveness probe (the
// planner excludes an L7-dead member from the pool so a rotation never lands on a co-failed sibling).
// It carries NO endpoint/SNI/identity — only a closed-vocab proto/class, the canonical ports, the
// score, the liveness flag, and the move to apply. The fine detector cause that triggered a rotation
// is NOT stored here: it stays in the node-local verdict the caller holds, and the rotation is logged
// class-level only (the RotationPlan's own RotationReason explains the decision), so the fine
// detector-cause vocabulary never enters the rotation schema.
type RotationCandidate struct {
	Proto        string         `json:"proto"`                   // closed-registry proto id (TransportRegistry)
	Class        TransportClass `json:"class"`                   // its coarse family (closed vocab)
	Action       RotationAction `json:"action"`                  // the move to reach/apply it
	FromPort     int            `json:"from_port"`               // current canonical port (0 if not port-toggled)
	ToPort       int            `json:"to_port"`                 // target canonical port (0 if unchanged / not toggled)
	Promoted     bool           `json:"promoted"`                // tuner promote flag for this member
	Weight       float64        `json:"weight"`                  // node-local tuner weight in [0,1]
	L7Dead       bool           `json:"l7_dead,omitempty"`       // this node's own L7 probe reports the member client-DEAD; the planner excludes it (Audit-0007 S2). Zero value = eligible.
	PathReset    bool           `json:"path_reset,omitempty"`    // this node's passive path-level observer reports the member's served client flows meeting RSTs (RP-0014 chunk B); the planner excludes it like L7Dead — never rotate ONTO a co-reset sibling. Zero value = eligible.
	PathCollapse bool           `json:"path_collapse,omitempty"` // this node's passive path-level observer reports the member's established served flows in a downstream post-connect throughput collapse (RP-0014 chunk B increment 2); excluded like PathReset — never rotate ONTO a co-collapsing sibling. Zero value = eligible.
}

// Validate checks the candidate is within the closed transport set (the AC-5 anchor): a non-empty
// proto that resolves in TransportRegistry to the stated class, a known action, canonical port
// range, and a weight in [0,1]. Pure.
func (c *RotationCandidate) Validate() error {
	if c.Proto == "" {
		return fmt.Errorf("%w: rotation candidate proto", ErrEmptyField)
	}
	cls, ok := ClassForProto(c.Proto)
	if !ok {
		return fmt.Errorf("%w: rotation candidate proto %q is not in the closed transport registry", ErrUnknownEnum, c.Proto)
	}
	if c.Class != cls {
		return fmt.Errorf("rotation candidate %q: class %q does not match the registry class %q", c.Proto, c.Class, cls)
	}
	if !c.Action.IsValid() {
		return fmt.Errorf("%w: rotation action %q", ErrUnknownEnum, c.Action)
	}
	if c.FromPort < 0 || c.FromPort > 65535 {
		return fmt.Errorf("rotation candidate %q: from_port %d out of range", c.Proto, c.FromPort)
	}
	if c.ToPort < 0 || c.ToPort > 65535 {
		return fmt.Errorf("rotation candidate %q: to_port %d out of range", c.Proto, c.ToPort)
	}
	if !(c.Weight >= 0 && c.Weight <= 1) {
		return fmt.Errorf("%w: rotation candidate weight %v not in [0,1]", ErrOutOfRange, c.Weight)
	}
	return nil
}

// RotationLimits is the explicit Layer-2 rotation policy (development.md §2.2 #4 — no silent
// bypass). Every knob is named (no magic constants). All durations strictly positive; counts >= 1.
type RotationLimits struct {
	FlipConfirmations     int           `json:"flip_confirmations"`         // consecutive impaired verdicts before any move (hysteresis)
	MinWeightMargin       float64       `json:"min_weight_margin"`          // a candidate must beat the incumbent weight by this much
	MinInterval           time.Duration `json:"min_interval_ns"`            // minimum between two promotions (cooldown)
	Window                time.Duration `json:"window_ns"`                  // rate-limit window
	MaxPerWindow          int           `json:"max_per_window"`             // max rotations per Window (anti-beacon)
	MaxRollbacksPerWindow int           `json:"max_rollbacks_per_window"`   // rollback budget before the planner latches to hold
	CooldownAfterRollback time.Duration `json:"cooldown_after_rollback_ns"` // hold-only span after any rollback
}

// Validate checks the limits are internally consistent (positive durations, counts >= 1, margin in
// [0,1] — the !(>=0 && <=1) form rejects NaN). Pure.
// maxPerWindowCeiling bounds MaxPerWindow so `MinInterval * MaxPerWindow` cannot overflow a
// time.Duration (int64 nanoseconds). BASIS: a rotation budget is an anti-beacon cap measured in single
// digits; 1024 is four orders of magnitude above anything defensible and still leaves the product safe
// for any MinInterval up to ~285 years.
const maxPerWindowCeiling = 1024

func (l RotationLimits) Validate() error {
	if l.FlipConfirmations < 1 {
		return fmt.Errorf("rotation limits: flip_confirmations must be >= 1, got %d", l.FlipConfirmations)
	}
	if !(l.MinWeightMargin >= 0 && l.MinWeightMargin <= 1) {
		return fmt.Errorf("%w: rotation min_weight_margin %v not in [0,1]", ErrOutOfRange, l.MinWeightMargin)
	}
	if l.MinInterval <= 0 {
		return fmt.Errorf("rotation limits: min_interval must be > 0, got %s", l.MinInterval)
	}
	if l.Window <= 0 {
		return fmt.Errorf("rotation limits: window must be > 0, got %s", l.Window)
	}
	if l.MaxPerWindow < 1 {
		return fmt.Errorf("rotation limits: max_per_window must be >= 1, got %d", l.MaxPerWindow)
	}
	if l.MaxRollbacksPerWindow < 1 {
		return fmt.Errorf("rotation limits: max_rollbacks_per_window must be >= 1, got %d", l.MaxRollbacksPerWindow)
	}
	// `<= 0`, not `< 0`. Zero was accepted and it DISABLES the rollback latch outright: RecordOutcome
	// sets HoldUntil = now, and `Now.Before(HoldUntil)` is false at that instant and forever after — so
	// the guard reads as enforcement and never fires. Every other duration here is gated `<= 0`; this
	// one was the exception, and the exception was a valid configuration in which a safety mechanism
	// silently did not exist (the constraint census, G2).
	if l.CooldownAfterRollback <= 0 {
		return fmt.Errorf("rotation limits: cooldown_after_rollback must be >= 0, got %s", l.CooldownAfterRollback)
	}
	// Rolling-window correctness: the cooldown must space rotations far enough that no rolling Window
	// can contain more than MaxPerWindow of them. Without this, the tumbling per-window count alone
	// permits a boundary burst (e.g. 2/window + a window reset = 3 in a rolling window), breaking the
	// anti-flap / anti-beacon contract. Requiring MinInterval >= Window/MaxPerWindow makes the
	// cooldown the binding constraint and the rolling-window bound an invariant.
	// MULTIPLY, do not divide (Audit-0010 / the constraint census). `Window/MaxPerWindow` is integer
	// time.Duration division, so it enforced `MinInterval >= floor(W/M)` and left a slit of `W mod M`
	// NANOSECONDS in which more than MaxPerWindow acts could fall inside one window. That slit was the
	// only thing the per-window budget guard could ever catch, and it was unreachable in practice while
	// looking exactly like live enforcement. The guard is gone; this inequality is now the whole
	// argument, so it must be exact: I*M >= W, with no rounding to hide in.
	if l.MaxPerWindow > maxPerWindowCeiling {
		return fmt.Errorf("rotation limits: max_per_window %d is implausibly large (ceiling %d) — the product below would overflow", l.MaxPerWindow, maxPerWindowCeiling)
	}
	if l.MinInterval*time.Duration(l.MaxPerWindow) < l.Window {
		return fmt.Errorf("rotation limits: min_interval %s x max_per_window must be >= window (%s) so the cooldown alone bounds a window to max_per_window acts",
			l.MinInterval, l.Window/time.Duration(l.MaxPerWindow))
	}
	return nil
}

// RotationState is the between-observation memory the planner threads forward (the executor persists
// it node-locally and reloads it; the planner never reads disk or a clock). It carries no identity.
type RotationState struct {
	LastRotateAt      time.Time `json:"last_rotate_at"`      // RFC 3339, UTC; zero = never
	WindowStart       time.Time `json:"window_start"`        // start of the current rate-limit window
	RotationsInWindow int       `json:"rotations_in_window"` // promotions counted in the current window
	RollbacksInWindow int       `json:"rollbacks_in_window"` // rollbacks counted in the current window
	ImpairedStreak    int       `json:"impaired_streak"`     // consecutive impaired verdicts for the active member
	HoldUntil         time.Time `json:"hold_until"`          // planner emits only "none" until this instant (latch)
}

// RotationPlan is the planner's decision: either a hold (Act=false, with a concrete HeldBecause and
// Reason) or a rotation (Act=true) to a single closed-set candidate. It is node-local and never
// transmitted. NextState is the state to persist after this decision.
type RotationPlan struct {
	Act         bool              `json:"act"`          // true = rotate to To; false = hold
	From        RotationCandidate `json:"from"`         // the (degraded) active member
	To          RotationCandidate `json:"to"`           // the member to rotate to (zero when Act=false)
	Reason      RotationReason    `json:"reason"`       // why this decision
	HeldBecause string            `json:"held_because"` // human-readable hold note (empty when Act=true)
	NextState   RotationState     `json:"next_state"`   // state to persist after applying this decision
	DecidedAt   time.Time         `json:"decided_at"`   // RFC 3339, UTC
}

// Validate checks the plan's internal consistency: a known reason; when acting, a valid closed-set
// target with a concrete (non-none) action and the acted reason; when holding, no target action and
// a stated cause. Pure.
func (p *RotationPlan) Validate() error {
	if !p.Reason.IsValid() {
		return fmt.Errorf("%w: rotation plan reason %q", ErrUnknownEnum, p.Reason)
	}
	if p.Act {
		if err := p.To.Validate(); err != nil {
			return fmt.Errorf("rotation plan target: %w", err)
		}
		if p.To.Action == RotationActionNone {
			return fmt.Errorf("rotation plan acts but the target action is %q", RotationActionNone)
		}
		if p.Reason != RotationReasonDegradedActive {
			return fmt.Errorf("rotation plan acts but the reason is %q (only %q acts)", p.Reason, RotationReasonDegradedActive)
		}
		// THE RESERVED-MOVE INVARIANT, at the contract layer (Audit-0010 F-016). Until now the rule was
		// two assignments inside rotate.Plan and lived nowhere else: nothing related To.Action to
		// To.ToPort, so a plan assembled by ANY other producer — a hand-written rotate_plan.json, a
		// replayed stale plan, a future planner — validated, round-tripped, and moved a served port under
		// an action the reservation exists to forbid. The executor applies .to.to_port without consulting
		// .to.action and port keys survive write_params, so this is the last place it can be caught before
		// a client's issued config names a port the node no longer serves.
		if p.To.ToPort != 0 && p.To.Action != RotationActionRotatePort {
			return fmt.Errorf("rotation plan: action %q carries to_port=%d — only %q may move a served port and it is reserved (unrequestable); a port moved under any other action is the reserved move performed under a name that does not name it",
				p.To.Action, p.To.ToPort, RotationActionRotatePort)
		}
	} else {
		if p.To.Action != RotationActionNone && p.To.Action != RotationActionUnknown {
			return fmt.Errorf("rotation plan holds but carries a target action %q", p.To.Action)
		}
		if p.HeldBecause == "" {
			return fmt.Errorf("%w: rotation plan held_because (a hold must state its cause)", ErrEmptyField)
		}
	}
	return nil
}
