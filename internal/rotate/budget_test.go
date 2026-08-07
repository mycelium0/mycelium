// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package rotate

import (
	"testing"

	"github.com/mycelium0/mycelium/internal/spec"
)

// TestEveryActPlanSpendsTheBudget — the anti-beacon limits must bind on EVERY acting move, not only on
// the one that happened to be written first.
//
// The demote branch shipped without them, and the first LIVE execution of the apply path is what found
// it: LastRotateAt never advanced so the 30-minute cooldown never bit, RotationsInWindow never rose so
// the two-per-hour cap was never spent, and the impaired streak was never cleared so the very next tick
// qualified again. An unattended loop free to demote a transport every ninety seconds, on a node whose
// entire design is to not beacon. A review had read that code twice without noticing.
func TestEveryActPlanSpendsTheBudget(t *testing.T) {
	in := base()
	// No sibling beats the incumbent by the margin and none is tuner-promoted: the state that used to be
	// a permanent dead end and is now where demote-active is emitted.
	in.Ranked = []spec.RotationCandidate{
		cand("hysteria2", 0.2, false),
		cand("shadowsocks", 0.2, false),
	}
	in.IssuedBaseline = []string{"vless-reality-vision", "hysteria2", "shadowsocks"}

	p := mustPlan(t, in)
	if !p.Act || p.To.Action != spec.RotationActionDemoteActive {
		t.Fatalf("expected an acting demote-active plan, got act=%v action=%q reason=%q", p.Act, p.To.Action, p.Reason)
	}
	if !p.NextState.LastRotateAt.Equal(in.Now) {
		t.Errorf("LastRotateAt = %v, want %v — without it the min-interval cooldown never applies to a demote", p.NextState.LastRotateAt, in.Now)
	}
	if p.NextState.RotationsInWindow != in.State.RotationsInWindow+1 {
		t.Errorf("RotationsInWindow = %d, want %d — without it the per-window anti-beacon cap is never spent", p.NextState.RotationsInWindow, in.State.RotationsInWindow+1)
	}
	if p.NextState.ImpairedStreak != 0 {
		t.Errorf("ImpairedStreak = %d, want 0 — an uncleared streak makes the very next tick qualify again", p.NextState.ImpairedStreak)
	}
}

// And the budget must actually STOP a second demote once spent.
// TestDemoteRespectsThePerWindowCap was DELETED, not repaired.
//
// It injected `RotationsInWindow = MaxPerWindow` with a mid-window WindowStart and asserted a hold. That
// state is unreachable by any schedule — producing it needs two acts closer together than MinInterval —
// and the guard it exercised has been removed as dead code. A test whose only input is a state the
// system cannot enter, asserting a guard that cannot run, proves nothing about the running program.
//
// What it was believed to protect — the anti-beacon cap — is asserted from a REACHABLE schedule by
// TestPlanRateBudgetIsBoundedBySchedule in rotate_test.go, which also records the measured finding that
// the true ROLLING bound is MaxPerWindow + 1 rather than MaxPerWindow.
