// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package rotate

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

var t0 = time.Date(2026, 6, 18, 12, 0, 0, 0, time.UTC)

func vdt(state spec.ConnState, reason spec.DetectReason) spec.Verdict {
	return spec.Verdict{State: state, Reason: reason, Class: spec.TransportClassRealityTCP, TransportRef: "active", DecidedAt: t0}
}

func cand(proto string, w float64, promoted bool) spec.RotationCandidate {
	cls, _ := spec.ClassForProto(proto)
	return spec.RotationCandidate{Proto: proto, Class: cls, Action: spec.RotationActionPromoteSibling, Promoted: promoted, Weight: w}
}

// activeCand is the incumbent (degraded) member; its Action is none.
func activeCand(w float64) spec.RotationCandidate {
	c := cand("vless-reality-vision", w, true)
	c.Action = spec.RotationActionNone
	return c
}

// base is an input that ACTS: the active is blocked, the streak reaches FlipConfirmations this tick,
// no cooldown, budget free, and a promoted grpc sibling beats the incumbent by the margin.
func base() PlanInput {
	return PlanInput{
		Active:        activeCand(0.2),
		ActiveVerdict: vdt(spec.ConnStateBlocked, spec.ReasonHandshakeTimeout),
		Ranked:        []spec.RotationCandidate{cand("vless-reality-grpc", 0.9, true)},
		Limits:        DefaultRotationLimits(),
		State:         spec.RotationState{ImpairedStreak: 2}, // +1 this tick = 3 = FlipConfirmations
		Now:           t0,
	}
}

func mustPlan(t *testing.T, in PlanInput) spec.RotationPlan {
	t.Helper()
	p, err := Plan(in)
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if err := p.Validate(); err != nil {
		t.Fatalf("emitted plan invalid: %v (%+v)", err, p)
	}
	return p
}

func TestPlanActsOnSustainedDegradation(t *testing.T) {
	p := mustPlan(t, base())
	if !p.Act {
		t.Fatalf("expected a rotation, held: %s", p.HeldBecause)
	}
	if p.To.Proto != "vless-reality-grpc" || p.Reason != spec.RotationReasonDegradedActive {
		t.Fatalf("rotated to %q reason %q, want grpc / degraded-active", p.To.Proto, p.Reason)
	}
	if !p.NextState.LastRotateAt.Equal(t0) || p.NextState.RotationsInWindow != 1 || p.NextState.ImpairedStreak != 0 {
		t.Fatalf("next state not advanced: %+v", p.NextState)
	}
}

func TestPlanHoldsCleanActive(t *testing.T) {
	in := base()
	in.ActiveVerdict = vdt(spec.ConnStateClean, spec.ReasonNone)
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonClean || p.NextState.ImpairedStreak != 0 {
		t.Fatalf("clean active must hold (reason=%q, streak=%d)", p.Reason, p.NextState.ImpairedStreak)
	}
}

func TestPlanHysteresis(t *testing.T) {
	in := base()
	in.State.ImpairedStreak = 1 // +1 = 2 < FlipConfirmations(3)
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonStreakTooShort {
		t.Fatalf("short streak must hold streak-too-short, got act=%v reason=%q", p.Act, p.Reason)
	}
}

func TestPlanCooldown(t *testing.T) {
	in := base()
	in.State.LastRotateAt = t0.Add(-5 * time.Minute) // < MinInterval(30m)
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonInCooldown {
		t.Fatalf("within cooldown must hold in-cooldown, got act=%v reason=%q", p.Act, p.Reason)
	}
}

func TestPlanRateBudget(t *testing.T) {
	in := base()
	in.State.LastRotateAt = t0.Add(-35 * time.Minute) // cooldown ok (> MinInterval 30m)
	in.State.WindowStart = t0.Add(-40 * time.Minute)  // window still current (<1h)
	in.State.RotationsInWindow = 2                    // == MaxPerWindow
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonNoBudget {
		t.Fatalf("spent budget must hold no-budget, got act=%v reason=%q", p.Act, p.Reason)
	}
}

// TestPlanWindowRollover: once the rate window has expired, the budget resets and the planner acts
// again (the anti-flap reset path).
func TestPlanWindowRollover(t *testing.T) {
	in := base()
	in.State.LastRotateAt = t0.Add(-2 * time.Hour) // cooldown long past
	in.State.WindowStart = t0.Add(-2 * time.Hour)  // window expired (>= Window)
	in.State.RotationsInWindow = 2                 // was at budget, but the window rolls
	p := mustPlan(t, in)
	if !p.Act {
		t.Fatalf("expired window must reset the budget and allow a rotation; held: %s", p.HeldBecause)
	}
	if !p.NextState.WindowStart.Equal(t0) || p.NextState.RotationsInWindow != 1 || p.NextState.RollbacksInWindow != 0 {
		t.Fatalf("window rollover did not reset cleanly: %+v", p.NextState)
	}
}

func TestPlanRollbackLatch(t *testing.T) {
	in := base()
	in.State.HoldUntil = t0.Add(10 * time.Minute) // latched
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonRollbackHold {
		t.Fatalf("rollback latch must hold rollback-hold, got act=%v reason=%q", p.Act, p.Reason)
	}
}

// TestPlanLatchSaturatesStreak: while latched, repeated impaired verdicts must not grow the streak
// without bound — it saturates at FlipConfirmations.
func TestPlanLatchSaturatesStreak(t *testing.T) {
	in := base()
	in.State.HoldUntil = t0.Add(time.Hour) // latched
	in.State.ImpairedStreak = in.Limits.FlipConfirmations
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.NextState.ImpairedStreak != in.Limits.FlipConfirmations {
		t.Fatalf("streak must saturate at FlipConfirmations(%d), got %d", in.Limits.FlipConfirmations, p.NextState.ImpairedStreak)
	}
}

// TestPlanTieBreaksByRegistryOrder: two equal-weight promoted candidates resolve deterministically to
// the lower TransportRegistry index (vless-reality-vision idx 0 < vless-reality-grpc idx 1).
func TestPlanTieBreaksByRegistryOrder(t *testing.T) {
	in := base()
	// The active is a THIRD proto (also reality-tcp) so both tie candidates are eligible — the
	// active's own proto is always skipped as a candidate.
	act := cand("vless-reality-xhttp", 0.1, true)
	act.Action = spec.RotationActionNone
	in.Active = act
	in.Ranked = []spec.RotationCandidate{
		cand("vless-reality-grpc", 0.8, true),   // registry idx 1
		cand("vless-reality-vision", 0.8, true), // registry idx 0 — must win the tie
	}
	p := mustPlan(t, in)
	if p.To.Proto != "vless-reality-vision" {
		t.Fatalf("equal-weight tie must break to the lower registry index (vision), got %q", p.To.Proto)
	}
}

func TestPlanNoBetterCandidate(t *testing.T) {
	in := base()
	in.Ranked = []spec.RotationCandidate{cand("vless-reality-grpc", 0.25, true)} // 0.25 < 0.2+0.1 margin
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonNoBetterCandidate {
		t.Fatalf("within-margin must hold no-better-candidate, got act=%v reason=%q", p.Act, p.Reason)
	}
}

func TestPlanTargetNotPromoted(t *testing.T) {
	in := base()
	in.Ranked = []spec.RotationCandidate{cand("vless-reality-grpc", 0.9, false)} // beats margin but NOT promoted
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act || p.Reason != spec.RotationReasonTargetNotPromoted {
		t.Fatalf("unpromoted best must hold target-not-promoted, got act=%v reason=%q", p.Act, p.Reason)
	}
}

func TestPlanPicksHighestWeightDeterministically(t *testing.T) {
	in := base()
	in.Ranked = []spec.RotationCandidate{
		cand("vless-reality-grpc", 0.6, true),
		cand("vless-ws-tls", 0.9, true),
		cand("amneziawg", 0.7, true),
	}
	p := mustPlan(t, in)
	if !p.Act || p.To.Proto != "vless-ws-tls" {
		t.Fatalf("must pick the highest-weight promoted candidate (ws-tls), got act=%v to=%q", p.Act, p.To.Proto)
	}
}

func TestPlanDeterministic(t *testing.T) {
	a, err1 := Plan(base())
	b, err2 := Plan(base())
	if err1 != nil || err2 != nil {
		t.Fatalf("errs: %v %v", err1, err2)
	}
	if !reflect.DeepEqual(a, b) {
		t.Fatal("Plan is not deterministic for identical input")
	}
}

func TestRecordOutcome(t *testing.T) {
	lim := DefaultRotationLimits()
	st := spec.RotationState{}
	// a successful promote leaves state untouched
	if got := RecordOutcome(st, lim, false, t0); !reflect.DeepEqual(got, st) {
		t.Fatal("promote outcome must not change state")
	}
	// one rollback hits the budget (MaxRollbacksPerWindow=1) and latches HoldUntil
	got := RecordOutcome(st, lim, true, t0)
	if got.RollbacksInWindow != 1 || !got.HoldUntil.Equal(t0.Add(lim.CooldownAfterRollback)) {
		t.Fatalf("rollback must spend the budget and latch HoldUntil: %+v", got)
	}
}

// TestPlanRejectsOutOfSetCandidate is the AC-5 guard at the planner boundary: a candidate proto not
// in the closed registry is refused before any decision.
func TestPlanRejectsOutOfSetCandidate(t *testing.T) {
	in := base()
	bad := in.Ranked[0]
	bad.Proto = "vmess" // not in the closed TransportRegistry
	in.Ranked = []spec.RotationCandidate{bad}
	if _, err := Plan(in); err == nil {
		t.Fatal("Plan must reject a candidate outside the closed transport set (AC-5)")
	}
}

// TestPlanInputCarriesNoGlobalSignal is the AC-4 guard: the planner input can only represent
// node-local signals — no field that looks like a cross-node / global / peer / digest input exists,
// so a rotation can never be driven by one.
func TestPlanInputCarriesNoGlobalSignal(t *testing.T) {
	tp := reflect.TypeOf(PlanInput{})
	forbidden := []string{"global", "peer", "digest", "remote", "cluster", "fleet", "network", "gossip"}
	for i := 0; i < tp.NumField(); i++ {
		n := strings.ToLower(tp.Field(i).Name)
		for _, bad := range forbidden {
			if strings.Contains(n, bad) {
				t.Fatalf("PlanInput.%s looks like a cross-node signal — AC-4 forbids the planner consuming one", tp.Field(i).Name)
			}
		}
	}
}
