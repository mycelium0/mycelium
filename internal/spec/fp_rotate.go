// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"time"
)

// FingerprintPlanInput is everything the fingerprint planner needs for one decision (RP-0015 increment B).
// It is the SCALAR analogue of rotate.PlanInput: the client uTLS preset is a single node-wide parameter, not
// a member with a proto/port/weight, so it rides its OWN parallel plane and REUSES the transport rotation's
// RotationLimits + RotationState verbatim (no new policy/state types). Every field is node-LOCAL — there is
// deliberately no peer/global/digest signal.
type FingerprintPlanInput struct {
	// Current is the currently-rendered client uTLS preset (the value the node's own A/B probe just used).
	Current string `json:"current"`
	// Target is the closed-vocab preset the same-listener A/B found ALIVE while Current read DEAD — the
	// preset to rotate to. Empty when there is no fingerprint-specific fault.
	Target string `json:"target"`
	// Faulted is this tick's generation-gated verdict: the current preset is fingerprint-specifically
	// filtered (the A/B read Current DEAD + a stable Target ALIVE across >= FpMinGenerations distinct marker
	// generations). It is the SCALAR analogue of an impaired active-member verdict.
	Faulted bool           `json:"faulted"`
	Limits  RotationLimits `json:"limits"` // the rotation policy (reused verbatim)
	State   RotationState  `json:"state"`  // between-tick memory (reused verbatim; separate fp instance)
	Now     time.Time      `json:"now"`    // injected clock (never read internally)
}

// FingerprintPlan is the fingerprint planner's decision: either a hold (Act=false, with a concrete Reason +
// HeldBecause) or a rotation (Act=true) of the client uTLS preset From -> To, where To is always a member of
// the closed vocabulary distinct from From (never a randomiser). Node-local, never transmitted; NextState is
// the RotationState to persist after this decision.
type FingerprintPlan struct {
	Act         bool           `json:"act"`          // true = rotate To; false = hold
	From        string         `json:"from"`         // the (filtered) current preset
	To          string         `json:"to"`           // the preset to rotate to (empty when Act=false)
	Reason      RotationReason `json:"reason"`       // why this decision (reused RotationReason vocabulary)
	HeldBecause string         `json:"held_because"` // human-readable hold note (empty when Act=true)
	NextState   RotationState  `json:"next_state"`   // state to persist after applying this decision
	DecidedAt   time.Time      `json:"decided_at"`   // RFC 3339, UTC
}

// Validate checks the plan's internal consistency: a known reason; when acting, a To in the closed
// fingerprint vocabulary distinct from From with the acted reason; when holding, no target and a stated
// cause. Pure. A random/randomized target can never validate (it is not a vocabulary member).
func (p *FingerprintPlan) Validate() error {
	if !p.Reason.IsValid() {
		return fmt.Errorf("%w: fingerprint plan reason %q", ErrUnknownEnum, p.Reason)
	}
	if p.Act {
		if !ValidClientFingerprint(p.To) {
			return fmt.Errorf("%w: fingerprint plan target %q is not a closed-vocab preset", ErrUnknownEnum, p.To)
		}
		if p.To == p.From {
			return fmt.Errorf("fingerprint plan acts but target %q equals the current preset", p.To)
		}
		if p.Reason != RotationReasonDegradedActive {
			return fmt.Errorf("fingerprint plan acts but the reason is %q (only %q acts)", p.Reason, RotationReasonDegradedActive)
		}
	} else {
		if p.To != "" {
			return fmt.Errorf("fingerprint plan holds but carries a target %q", p.To)
		}
		if p.HeldBecause == "" {
			return fmt.Errorf("%w: fingerprint plan held_because (a hold must state its cause)", ErrEmptyField)
		}
	}
	return nil
}
