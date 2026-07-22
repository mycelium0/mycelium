// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package rotate

import (
	"testing"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

func fpNow() time.Time { return time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC) }

// baseFpInput is a faulted input one streak short of acting, with a fresh window and a valid target.
func baseFpInput() spec.FingerprintPlanInput {
	lim := DefaultRotationLimits()
	return spec.FingerprintPlanInput{
		Current: "chrome",
		Target:  "firefox",
		Faulted: true,
		Limits:  lim,
		State: spec.RotationState{
			WindowStart:    fpNow(),
			ImpairedStreak: lim.FlipConfirmations - 1, // +1 this tick reaches the threshold
		},
		Now: fpNow(),
	}
}

func mustPlanFP(t *testing.T, in spec.FingerprintPlanInput) spec.FingerprintPlan {
	t.Helper()
	p, err := PlanFingerprint(in)
	if err != nil {
		t.Fatalf("PlanFingerprint: %v", err)
	}
	if verr := p.Validate(); verr != nil {
		t.Fatalf("returned plan fails Validate: %v", verr)
	}
	return p
}

// TestPlanFingerprintActsOnSustainedFault: a faulted verdict that reaches FlipConfirmations rotates to the
// A/B target, spends a window slot, resets the streak, and never targets the current preset.
func TestPlanFingerprintActsOnSustainedFault(t *testing.T) {
	in := baseFpInput()
	p := mustPlanFP(t, in)
	if !p.Act {
		t.Fatalf("want Act on a sustained fault, got hold: %s", p.HeldBecause)
	}
	if p.From != "chrome" || p.To != "firefox" {
		t.Errorf("rotate = %s->%s, want chrome->firefox", p.From, p.To)
	}
	if p.Reason != spec.RotationReasonDegradedActive {
		t.Errorf("reason = %q, want degraded-active", p.Reason)
	}
	if p.NextState.RotationsInWindow != 1 || p.NextState.ImpairedStreak != 0 || p.NextState.LastRotateAt != fpNow() {
		t.Errorf("next state = %+v, want rotations=1 streak=0 lastRotate=now", p.NextState)
	}
}

// TestPlanFingerprintGuardOrder walks each hold guard in order.
func TestPlanFingerprintGuardOrder(t *testing.T) {
	holds := func(name string, mut func(i *spec.FingerprintPlanInput), wantReason spec.RotationReason) {
		t.Helper()
		in := baseFpInput()
		mut(&in)
		p := mustPlanFP(t, in)
		if p.Act {
			t.Errorf("%s: want hold, got Act (%s->%s)", name, p.From, p.To)
		}
		if p.Reason != wantReason {
			t.Errorf("%s: reason = %q, want %q", name, p.Reason, wantReason)
		}
		if p.To != "" {
			t.Errorf("%s: a hold must carry no target, got %q", name, p.To)
		}
	}
	// Guard 1: not faulted -> clean (and the streak resets).
	holds("not faulted", func(i *spec.FingerprintPlanInput) { i.Faulted = false }, spec.RotationReasonClean)
	// Guard 2: rollback latch dominates even a sustained fault.
	holds("rollback latch", func(i *spec.FingerprintPlanInput) { i.State.HoldUntil = fpNow().Add(time.Minute) }, spec.RotationReasonRollbackHold)
	// Guard 3: hysteresis not yet met.
	holds("streak too short", func(i *spec.FingerprintPlanInput) { i.State.ImpairedStreak = 0 }, spec.RotationReasonStreakTooShort)
	// Guard 4: within min-interval of the last rotation.
	holds("cooldown", func(i *spec.FingerprintPlanInput) { i.State.LastRotateAt = fpNow().Add(-time.Minute) }, spec.RotationReasonInCooldown)
	// Guard 5: the per-window budget is spent.
	holds("no budget", func(i *spec.FingerprintPlanInput) { i.State.RotationsInWindow = i.Limits.MaxPerWindow }, spec.RotationReasonNoBudget)
	// Guard 6: no valid target distinct from the current preset.
	holds("target == current", func(i *spec.FingerprintPlanInput) { i.Target = "chrome" }, spec.RotationReasonNoBetterCandidate)
	holds("target off-vocab", func(i *spec.FingerprintPlanInput) { i.Target = "bogus" }, spec.RotationReasonNoBetterCandidate)
	holds("target randomiser", func(i *spec.FingerprintPlanInput) { i.Target = "randomized" }, spec.RotationReasonNoBetterCandidate)
}

// TestPlanFingerprintWindowRoll: an expired window resets the in-window rotation count so a fresh fault acts.
func TestPlanFingerprintWindowRoll(t *testing.T) {
	in := baseFpInput()
	in.State.RotationsInWindow = in.Limits.MaxPerWindow // budget spent in the OLD window
	in.State.WindowStart = fpNow().Add(-in.Limits.Window - time.Minute)
	p := mustPlanFP(t, in)
	if !p.Act {
		t.Fatalf("want Act after the window rolled, got hold: %s", p.HeldBecause)
	}
	if p.NextState.RotationsInWindow != 1 {
		t.Errorf("rotations-in-window = %d, want 1 after roll", p.NextState.RotationsInWindow)
	}
}

// TestPlanFingerprintRejectsBadInput: invalid limits and an off-vocab current preset are hard errors.
func TestPlanFingerprintRejectsBadInput(t *testing.T) {
	in := baseFpInput()
	in.Limits.FlipConfirmations = 0 // invalid
	if _, err := PlanFingerprint(in); err == nil {
		t.Error("want error on invalid limits")
	}
	in = baseFpInput()
	in.Current = "bogus" // not a closed-vocab preset
	if _, err := PlanFingerprint(in); err == nil {
		t.Error("want error on an off-vocab current preset")
	}
}
