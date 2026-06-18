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
	// RotationReasonNoBudget — the per-window rotation budget is spent (hold).
	RotationReasonNoBudget RotationReason = "no-budget"
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
		RotationReasonInCooldown, RotationReasonNoBudget, RotationReasonRollbackHold,
		RotationReasonNoBetterCandidate, RotationReasonTargetNotPromoted:
		return true
	default:
		return false
	}
}

// RotationCandidate is one transport member the planner ranks/selects. Weight is the node-local
// tuner score (copied in by the caller from tune.Weight.Value); Promoted mirrors the tuner's
// hysteretic promote flag. It carries NO endpoint/SNI/identity — only a closed-vocab proto/class,
// the canonical ports, the score, and the move to apply. The fine detector cause that triggered a
// rotation is NOT stored here: it stays in the node-local verdict the caller holds, and the rotation
// is logged class-level only (the RotationPlan's own RotationReason explains the decision), so the
// fine detector-cause vocabulary never enters the rotation schema.
type RotationCandidate struct {
	Proto    string         `json:"proto"`     // closed-registry proto id (TransportRegistry)
	Class    TransportClass `json:"class"`     // its coarse family (closed vocab)
	Action   RotationAction `json:"action"`    // the move to reach/apply it
	FromPort int            `json:"from_port"` // current canonical port (0 if not port-toggled)
	ToPort   int            `json:"to_port"`   // target canonical port (0 if unchanged / not toggled)
	Promoted bool           `json:"promoted"`  // tuner promote flag for this member
	Weight   float64        `json:"weight"`    // node-local tuner weight in [0,1]
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
	if l.CooldownAfterRollback < 0 {
		return fmt.Errorf("rotation limits: cooldown_after_rollback must be >= 0, got %s", l.CooldownAfterRollback)
	}
	// Rolling-window correctness: the cooldown must space rotations far enough that no rolling Window
	// can contain more than MaxPerWindow of them. Without this, the tumbling per-window count alone
	// permits a boundary burst (e.g. 2/window + a window reset = 3 in a rolling window), breaking the
	// anti-flap / anti-beacon contract. Requiring MinInterval >= Window/MaxPerWindow makes the
	// cooldown the binding constraint and the rolling-window bound an invariant.
	if l.MinInterval < l.Window/time.Duration(l.MaxPerWindow) {
		return fmt.Errorf("rotation limits: min_interval %s must be >= window/max_per_window (%s) so no rolling window exceeds the rotation budget",
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
