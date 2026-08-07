// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"math"
	"testing"
	"time"
)

func TestRotationEnumsIsValid(t *testing.T) {
	if RotationActionUnknown.IsValid() {
		t.Fatal("RotationActionUnknown must be invalid")
	}
	for _, a := range []RotationAction{RotationActionNone, RotationActionPromoteSibling, RotationActionRotatePort, RotationActionRegenReality, RotationActionDemoteActive} {
		if !a.IsValid() {
			t.Fatalf("RotationAction %q must be valid", a)
		}
	}
	if RotationReasonUnknown.IsValid() {
		t.Fatal("RotationReasonUnknown must be invalid")
	}
	for _, r := range []RotationReason{RotationReasonDegradedActive, RotationReasonClean, RotationReasonStreakTooShort, RotationReasonInCooldown, RotationReasonRollbackHold, RotationReasonNoBetterCandidate, RotationReasonTargetNotPromoted} {
		if !r.IsValid() {
			t.Fatalf("RotationReason %q must be valid", r)
		}
	}
	// AC-5 anchor: there is no "add-transport"/"new-proto" action member.
	if RotationAction("add-transport").IsValid() || RotationAction("new-proto").IsValid() {
		t.Fatal("RotationAction must have no add/new-proto member (AC-5)")
	}
}

func goodCandidate() RotationCandidate {
	// ToPort 0: a promote-sibling candidate may NOT carry a port move. The fixture used to set 8443,
	// which encoded the permissive contract that let the reserved move ride in under an authorised action
	// (Audit-0010 F-016). FromPort still names where the sibling is served — reporting where a member
	// lives is not moving it.
	return RotationCandidate{Proto: "vless-reality-grpc", Class: TransportClassRealityTCP, Action: RotationActionPromoteSibling, FromPort: 8443, ToPort: 0, Promoted: true, Weight: 0.8}
}

func TestRotationCandidateValidate(t *testing.T) {
	if err := (func() error { c := goodCandidate(); return c.Validate() })(); err != nil {
		t.Fatalf("good candidate must validate: %v", err)
	}
	bad := []func(*RotationCandidate){
		func(c *RotationCandidate) { c.Proto = "" },                          // empty proto
		func(c *RotationCandidate) { c.Proto = "vmess" },                     // outside the closed registry (AC-5)
		func(c *RotationCandidate) { c.Class = TransportClassQUICUDP },       // class != registry class for the proto
		func(c *RotationCandidate) { c.Action = RotationAction("teleport") }, // unknown action
		func(c *RotationCandidate) { c.ToPort = 70000 },                      // out of range
		func(c *RotationCandidate) { c.Weight = 1.5 },                        // weight > 1
		func(c *RotationCandidate) { c.Weight = math.NaN() },                 // NaN weight
	}
	for i, mut := range bad {
		c := goodCandidate()
		mut(&c)
		if err := c.Validate(); err == nil {
			t.Fatalf("bad candidate[%d] must fail Validate", i)
		}
	}
}

func goodLimits() RotationLimits {
	return RotationLimits{FlipConfirmations: 3, MinWeightMargin: 0.1, MinInterval: 30 * time.Minute, Window: time.Hour, MaxPerWindow: 2, MaxRollbacksPerWindow: 1, CooldownAfterRollback: time.Hour}
}

func TestRotationLimitsValidate(t *testing.T) {
	if err := goodLimits().Validate(); err != nil {
		t.Fatalf("good limits must validate: %v", err)
	}
	bad := []func(*RotationLimits){
		func(l *RotationLimits) { l.FlipConfirmations = 0 },
		func(l *RotationLimits) { l.MinWeightMargin = 1.5 },
		func(l *RotationLimits) { l.MinWeightMargin = math.NaN() },
		func(l *RotationLimits) { l.MinInterval = 0 },
		func(l *RotationLimits) { l.Window = 0 },
		func(l *RotationLimits) { l.MaxPerWindow = 0 },
		func(l *RotationLimits) { l.MaxRollbacksPerWindow = 0 },
		func(l *RotationLimits) { l.CooldownAfterRollback = -time.Second },
		func(l *RotationLimits) { l.MinInterval = 10 * time.Minute }, // < Window/MaxPerWindow (30m): rolling-window invariant
	}
	for i, mut := range bad {
		l := goodLimits()
		mut(&l)
		if err := l.Validate(); err == nil {
			t.Fatalf("bad limits[%d] must fail Validate", i)
		}
	}
}

func TestRotationPlanValidate(t *testing.T) {
	now := time.Now().UTC()
	// a valid ACT plan
	act := RotationPlan{Act: true, To: goodCandidate(), Reason: RotationReasonDegradedActive, DecidedAt: now}
	if err := act.Validate(); err != nil {
		t.Fatalf("valid act plan must validate: %v", err)
	}
	// a valid HOLD plan
	hold := RotationPlan{Act: false, Reason: RotationReasonClean, HeldBecause: "healthy", DecidedAt: now}
	hold.To.Action = RotationActionNone
	if err := hold.Validate(); err != nil {
		t.Fatalf("valid hold plan must validate: %v", err)
	}
	// invalid: acts but reason is not the acted reason
	p := act
	p.Reason = RotationReasonInCooldown
	if err := p.Validate(); err == nil {
		t.Fatal("act plan with a non-acted reason must fail")
	}
	// invalid: acts but target action is none
	p = act
	p.To.Action = RotationActionNone
	if err := p.Validate(); err == nil {
		t.Fatal("act plan with a none target action must fail")
	}
	// invalid: acts to an out-of-registry target (AC-5 at the plan boundary)
	p = act
	p.To.Proto = "vmess"
	if err := p.Validate(); err == nil {
		t.Fatal("act plan with an out-of-registry target must fail (AC-5)")
	}
	// invalid: holds but states no cause
	p = hold
	p.HeldBecause = ""
	if err := p.Validate(); err == nil {
		t.Fatal("hold plan with no held_because must fail")
	}
	// invalid: unknown reason
	p = hold
	p.Reason = RotationReasonUnknown
	if err := p.Validate(); err == nil {
		t.Fatal("plan with an unknown reason must fail")
	}
}

// TestRotationPlanRefusesAPortMoveUnderAnAuthorisedAction pins the reserved-move invariant at the
// contract layer (Audit-0010 F-016). Before this, the rule was two assignments inside rotate.Plan and
// nothing related To.Action to To.ToPort — so any OTHER producer of a plan (a hand-written
// rotate_plan.json, a replayed stale plan, a future planner) could move a served port under an action
// the reservation exists to forbid, and the plan validated and round-tripped cleanly.
func TestRotationPlanRefusesAPortMoveUnderAnAuthorisedAction(t *testing.T) {
	now := time.Now().UTC()
	for _, action := range []RotationAction{RotationActionPromoteSibling, RotationActionDemoteActive} {
		c := goodCandidate()
		c.Action = action
		c.ToPort = 9443
		p := RotationPlan{Act: true, To: c, Reason: RotationReasonDegradedActive, DecidedAt: now}
		if err := p.Validate(); err == nil {
			t.Fatalf("a plan carrying to_port=9443 under action %q VALIDATED. The executor applies "+
				"to.to_port without consulting to.action and port keys survive write_params, so this plan "+
				"moves a served port that every issued client config still names, with no channel to "+
				"re-fetch — the exact outage the reservation exists to prevent.", action)
		}
	}
	// And the reserved action itself may carry one — the reservation is on REQUESTING it, not on the
	// shape being expressible. A validator that refused it outright would make the reserved move
	// unrepresentable rather than unrequestable, and the difference matters the day it is unreserved.
	c := goodCandidate()
	c.Action = RotationActionRotatePort
	c.ToPort = 9443
	p := RotationPlan{Act: true, To: c, Reason: RotationReasonDegradedActive, DecidedAt: now}
	if err := p.Validate(); err != nil {
		t.Fatalf("a rotate-port plan carrying to_port must remain REPRESENTABLE (it is unrequestable, not "+
			"unexpressible): %v", err)
	}
}
