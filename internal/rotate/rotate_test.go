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

// TestPlanRateBudgetIsBoundedBySchedule replaces a test that asserted an UNREACHABLE state.
//
// It used to hand-build `RotationsInWindow = MaxPerWindow` with a mid-window WindowStart and a
// LastRotateAt 35 minutes back — a state no schedule can produce, because two acts inside a 40-minute
// window require them 5 minutes apart and the cooldown is 30. It then asserted the per-window budget
// guard fired. That guard is now deleted: with `MinInterval * MaxPerWindow >= Window` enforced exactly by
// RotationLimits.Validate, the cooldown alone bounds a window and the guard could never bind.
//
// The property that actually matters survives and is asserted here the only honest way — by ITERATING
// the planner from the zero state and counting, so every state visited is one the system can reach.
func TestPlanRateBudgetIsBoundedBySchedule(t *testing.T) {
	lim := DefaultRotationLimits()
	if err := lim.Validate(); err != nil {
		t.Fatalf("defaults do not validate: %v", err)
	}
	in := base()
	in.State = spec.RotationState{}
	blocked := vdt(spec.ConnStateBlocked, spec.ReasonConnectionReset)

	// Tick every minute for three windows. Sustained impairment throughout: the planner is trying to act
	// on every tick and only the rate machinery stops it.
	const tick = time.Minute
	ticks := int(3 * lim.Window / tick)
	st := in.State
	worst := 0
	var acts []time.Time
	for i := 0; i < ticks; i++ {
		cur := in
		cur.State = st
		cur.ActiveVerdict = blocked
		cur.Now = t0.Add(time.Duration(i) * tick)
		p, err := Plan(cur)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
		if p.Act {
			acts = append(acts, cur.Now)
			// Count acts inside every rolling Window ending at this act — the property the deleted guard
			// claimed to enforce, measured over the schedule rather than over an injected counter.
			n := 0
			for _, a := range acts {
				if !a.Before(cur.Now.Add(-lim.Window)) {
					n++
				}
			}
			if n > worst {
				worst = n
			}
		}
		st = p.NextState
	}
	if len(acts) == 0 {
		t.Fatal("no act in three windows of sustained impairment — the schedule never reaches the act path, so this measures nothing")
	}
	// THE TRUE BOUND IS MaxPerWindow + 1, AND THAT IS A FINDING, NOT A ROUNDING ALLOWANCE.
	//
	// `MaxPerWindow` bounds a TUMBLING window — the counter resets when WindowStart is re-anchored. What
	// an observer sees is a ROLLING window, and with `MinInterval * MaxPerWindow == Window` (the shipped
	// defaults: 30m x 2 == 1h) the cooldown permits acts at 0, I, 2I, ... so any span of length W holds
	// floor(W/I) + 1 == MaxPerWindow + 1 of them.
	//
	// The deleted budget guard did NOT prevent this: the identical schedule overruns by the same margin on
	// the revision that still contains it (measured, e52813e), because it read the tumbling counter and
	// was unreachable anyway. So the anti-beacon cap has always been one weaker than its name suggests.
	//
	// Bounding the ROLLING window to MaxPerWindow needs a STRICT inequality — `MinInterval *
	// MaxPerWindow > Window` — which the shipped defaults do not satisfy (30m x 2 == 1h, not >). Making
	// it strict is a posture change to three live nodes: it would require MinInterval 31m, or Window 59m,
	// or a different cap. That is an operator decision, recorded rather than taken here.
	if worst > lim.MaxPerWindow+1 {
		t.Fatalf("%d acts inside one rolling %v window; the documented cap is %d and the true bound under "+
			"`MinInterval * MaxPerWindow == Window` is %d. Exceeding even that means the cooldown itself is "+
			"not holding. Acts at %v.",
			worst, lim.Window, lim.MaxPerWindow, lim.MaxPerWindow+1, acts)
	}
	// And pin the gap itself, so the day someone makes the inequality strict this row tells them the
	// bound tightened and the comment above is stale.
	if lim.MinInterval*time.Duration(lim.MaxPerWindow) > lim.Window && worst > lim.MaxPerWindow {
		t.Fatalf("the inequality is now STRICT (%v x %d > %v), which should bound a ROLLING window to %d, "+
			"but %d acts landed in one. Either the arithmetic or this expectation is wrong.",
			lim.MinInterval, lim.MaxPerWindow, lim.Window, lim.MaxPerWindow, worst)
	}
}

// TestRotationLimitsArithmeticIsExact pins the inequality that replaced the deleted guard. It must
// MULTIPLY: `Window/MaxPerWindow` is integer time.Duration division, which left a `Window mod
// MaxPerWindow` nanosecond slit where an extra act could fall inside a window — the only case the
// deleted guard could ever have caught, and unreachable in practice while looking like enforcement.
func TestRotationLimitsArithmeticIsExact(t *testing.T) {
	// A configuration that the old DIVIDING form accepted and the exact form must refuse: W=1h, M=7,
	// floor(W/M) = 514285714285ns, and 7 * that = 1h - 5ns < 1h.
	l := DefaultRotationLimits()
	l.Window = time.Hour
	l.MaxPerWindow = 7
	l.MinInterval = l.Window / 7 // integer division: 5ns short of the exact requirement
	if err := l.Validate(); err == nil {
		t.Fatalf("limits accepted with MinInterval*MaxPerWindow = %v < Window = %v. The rounding slit is "+
			"exactly what the deleted budget guard was the only defence against; the inequality must be "+
			"exact or the deletion is unsound.", l.MinInterval*time.Duration(l.MaxPerWindow), l.Window)
	}
	l.MinInterval = (l.Window + 6) / 7 // ceil: 7 * this >= Window
	if err := l.Validate(); err != nil {
		t.Fatalf("limits refused when MinInterval*MaxPerWindow = %v >= Window = %v: %v",
			l.MinInterval*time.Duration(l.MaxPerWindow), l.Window, err)
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

// TestPlanExcludesL7DeadCandidate: a candidate this node's own L7 probe reports client-DEAD is
// excluded from the pool BEFORE the margin/promote checks — even when it would otherwise win — so a
// rotation never lands on a co-failed sibling. With the dead candidate the only option, the planner
// holds no-better-candidate (NOT target-not-promoted: the exclusion happens before anyBetterByMargin,
// so a dead-but-promoted candidate cannot mislabel the hold reason). Audit-0007 S2.
func TestPlanExcludesL7DeadCandidate(t *testing.T) {
	in := base()
	dead := cand("vless-reality-grpc", 0.9, true) // beats the 0.2 incumbent by the 0.1 margin AND is promoted
	dead.L7Dead = true
	in.Ranked = []spec.RotationCandidate{dead}
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act {
		t.Fatalf("must not rotate onto an L7-dead sibling, rotated to %q", p.To.Proto)
	}
	if p.Reason != spec.RotationReasonNoBetterCandidate {
		t.Fatalf("an excluded dead candidate must hold no-better-candidate, got %q", p.Reason)
	}
}

// TestPlanRotatesPastL7DeadToLiveSibling: when the highest-weight candidate is L7-dead, the planner
// skips it and rotates to the next LIVE candidate that still beats the margin — the degraded active is
// recovered without landing on a co-failed sibling. Audit-0007 S2.
func TestPlanRotatesPastL7DeadToLiveSibling(t *testing.T) {
	in := base()
	deadTop := cand("vless-ws-tls", 0.95, true)
	deadTop.L7Dead = true
	live := cand("vless-reality-grpc", 0.7, true) // still > 0.2 + 0.1 margin
	in.Ranked = []spec.RotationCandidate{deadTop, live}
	p := mustPlan(t, in)
	if !p.Act || p.To.Proto != "vless-reality-grpc" {
		t.Fatalf("must skip the L7-dead top candidate and rotate to the live sibling, got act=%v to=%q", p.Act, p.To.Proto)
	}
}

// TestPlanExcludesPathResetCandidate: a candidate whose served client flows the node's passive path-level
// observer reports meeting RSTs (PathReset=true, RP-0014 chunk B) is excluded from the pool exactly like an
// L7-dead sibling — the planner never rotates ONTO a co-reset target, even one that beats the margin.
func TestPlanExcludesPathResetCandidate(t *testing.T) {
	in := base()
	reset := cand("vless-reality-grpc", 0.9, true) // beats the 0.2 incumbent by the 0.1 margin AND is promoted
	reset.PathReset = true
	in.Ranked = []spec.RotationCandidate{reset}
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act {
		t.Fatalf("must not rotate onto a path-reset sibling, rotated to %q", p.To.Proto)
	}
	if p.Reason != spec.RotationReasonNoBetterCandidate {
		t.Fatalf("an excluded path-reset candidate must hold no-better-candidate, got %q", p.Reason)
	}
}

// TestPlanRotatesPastPathResetToLiveSibling: when the highest-weight candidate is path-reset, the planner
// skips it and rotates to the next candidate whose flows are clean and still beats the margin.
func TestPlanRotatesPastPathResetToLiveSibling(t *testing.T) {
	in := base()
	resetTop := cand("vless-ws-tls", 0.95, true)
	resetTop.PathReset = true
	live := cand("vless-reality-grpc", 0.7, true) // still > 0.2 + 0.1 margin
	in.Ranked = []spec.RotationCandidate{resetTop, live}
	p := mustPlan(t, in)
	if !p.Act || p.To.Proto != "vless-reality-grpc" {
		t.Fatalf("must skip the path-reset top candidate and rotate to the live sibling, got act=%v to=%q", p.Act, p.To.Proto)
	}
}

// TestPlanExcludesPathCollapseCandidate: a candidate whose established served flows the observer reports in a
// downstream throughput collapse (PathCollapse=true, RP-0014 chunk B increment 2) is excluded from the pool
// like a path-reset sibling — never rotate ONTO a co-collapsing target, even one that beats the margin.
func TestPlanExcludesPathCollapseCandidate(t *testing.T) {
	in := base()
	collapse := cand("vless-reality-grpc", 0.9, true)
	collapse.PathCollapse = true
	in.Ranked = []spec.RotationCandidate{collapse}
	p, err := Plan(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Act {
		t.Fatalf("must not rotate onto a path-collapse sibling, rotated to %q", p.To.Proto)
	}
	if p.Reason != spec.RotationReasonNoBetterCandidate {
		t.Fatalf("an excluded path-collapse candidate must hold no-better-candidate, got %q", p.Reason)
	}
}

// TestPlanRotatesPastPathCollapseToLiveSibling: when the highest-weight candidate is path-collapse, the
// planner skips it and rotates to the next candidate whose flows are healthy and still beats the margin.
func TestPlanRotatesPastPathCollapseToLiveSibling(t *testing.T) {
	in := base()
	collapseTop := cand("vless-ws-tls", 0.95, true)
	collapseTop.PathCollapse = true
	live := cand("vless-reality-grpc", 0.7, true)
	in.Ranked = []spec.RotationCandidate{collapseTop, live}
	p := mustPlan(t, in)
	if !p.Act || p.To.Proto != "vless-reality-grpc" {
		t.Fatalf("must skip the path-collapse top candidate and rotate to the live sibling, got act=%v to=%q", p.Act, p.To.Proto)
	}
}

// TestPlanPicksHighestWeightDeterministically: within ONE exposure tier, the highest-weight promoted
// candidate wins, deterministically. The candidates are deliberately same-tier (all own-cert TLS) because
// weight only ranks inside a tier — across tiers the safer one wins regardless of weight, which is pinned
// separately by TestPlanPrefersSaferExposureOverWeight.
func TestPlanPicksHighestWeightDeterministically(t *testing.T) {
	in := base()
	in.Ranked = []spec.RotationCandidate{
		cand("trojan", 0.6, true),       // own-cert TLS
		cand("vless-ws-tls", 0.9, true), // own-cert TLS — highest weight in the tier
		cand("vless-xhttp-tls", 0.7, true),
	}
	p := mustPlan(t, in)
	if !p.Act || p.To.Proto != "vless-ws-tls" {
		t.Fatalf("must pick the highest-weight promoted candidate within the tier (ws-tls), got act=%v to=%q", p.Act, p.To.Proto)
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

// TestPlanPrefersSaferExposureOverWeight: the load-bearing property of the exposure ranking — a RISKIER
// shape that currently measures BETTER must not be promoted over a viable safer one. Weight ranks only
// within a tier; the cost of a risky shape is paid when it is classified, not while it works.
func TestPlanPrefersSaferExposureOverWeight(t *testing.T) {
	in := base()
	// shadowsocks (tier 6, NO COVER) measures far better than vless-ws-tls (tier 3, own-cert TLS).
	// The safer one must still win.
	in.Ranked = []spec.RotationCandidate{
		cand("shadowsocks", 0.99, true),
		cand("vless-ws-tls", 0.55, true),
	}
	p, err := Plan(in)
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if !p.Act {
		t.Fatalf("expected a rotation, got hold: %s", p.Reason)
	}
	if p.To.Proto != "vless-ws-tls" {
		t.Fatalf("promoted %q over the safer own-cert-TLS candidate — exposure must out-rank weight", p.To.Proto)
	}
}

// TestPlanFallsBackToRiskierWhenSaferIsNotViable: the other half of the contract — the risky axis EXISTS
// to be used when nothing safer can carry traffic. With the safer candidate L7-dead, the last-resort
// no-cover shape must be chosen rather than holding.
func TestPlanFallsBackToRiskierWhenSaferIsNotViable(t *testing.T) {
	in := base()
	dead := cand("vless-ws-tls", 0.90, true)
	dead.L7Dead = true
	in.Ranked = []spec.RotationCandidate{dead, cand("shadowsocks", 0.60, true)}
	p, err := Plan(in)
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if !p.Act || p.To.Proto != "shadowsocks" {
		t.Fatalf("with every safer candidate dead the last-resort axis must be used; got act=%v to=%q (%s)", p.Act, p.To.Proto, p.Reason)
	}
}

// TestExposureTiersAreTotalAndOrdered: every registry proto carries a tier, REALITY is the safest and the
// uncovered TCP shape is the riskiest — so a future edit cannot quietly leave a proto untiered (which
// would sort it as safe) or reorder the two ends without arguing with this test.
func TestExposureTiersAreTotalAndOrdered(t *testing.T) {
	for _, d := range spec.TransportRegistry() {
		if d.Exposure < spec.ExposureBorrowedTLS || d.Exposure > spec.ExposureNoCover {
			t.Errorf("proto %q has no valid exposure tier (%d)", d.Proto, d.Exposure)
		}
	}
	if exposureOf("vless-reality-vision") != spec.ExposureBorrowedTLS {
		t.Error("REALITY must be the safest tier (it borrows a real donor handshake)")
	}
	if exposureOf("shadowsocks") != spec.ExposureNoCover {
		t.Error("standalone Shadowsocks must be the last-resort tier (no handshake cover at all)")
	}
	if exposureOf("no-such-proto") <= spec.ExposureNoCover {
		t.Error("an unknown proto must sort LAST, never be treated as safe")
	}
}

// TestPlanNeverEmitsAPortMoveWhileRotatePortIsReserved is the guard the RESERVATION actually needs.
//
// `rotate-port` is declared, validated, round-trips, and is listed as deliberately not requestable — and
// the reservation was enforced on the ACTION NAME alone. The capability rode in under promote-sibling:
// ToPort reaches a candidate from the node-local measure config, the promote branch copied the candidate
// wholesale, and the executor reads `.to.to_port` with no reference to `.to.action`. Port keys are in the
// operator allowlist, so a moved port SURVIVES write_params. The result was an unattended 90-second loop
// able to move a served port that every issued client config still names, with no channel to re-fetch —
// precisely the outage the reservation was written to prevent.
//
// Asserting on the action name cannot catch that: the plan says "promote-sibling" in both the safe and the
// unsafe case. The assertion has to be on the FIELD THAT CAUSES THE MOVE, over every branch that can emit
// an act plan. Remove `to.ToPort = 0` from either branch of Plan and this fails.
func TestPlanNeverEmitsAPortMoveWhileRotatePortIsReserved(t *testing.T) {
	// A candidate carrying a port move, exactly as a hand-edited measure.config.json would supply it.
	poisoned := cand("vless-reality-grpc", 0.9, true)
	poisoned.FromPort = 8443
	poisoned.ToPort = 9443

	cases := []struct {
		name string
		in   PlanInput
	}{
		{
			name: "promote-sibling: the ranked candidate carries a port move",
			in: func() PlanInput {
				in := base()
				in.Ranked = []spec.RotationCandidate{poisoned}
				return in
			}(),
		},
		{
			name: "demote-active: the incumbent carries a port move and no sibling beats it",
			in: func() PlanInput {
				in := base()
				a := activeCand(0.2)
				a.FromPort = 8443
				a.ToPort = 9443
				in.Active = a
				// No candidate beats the incumbent by the margin -> the demote branch, if the baseline
				// leaves an independent fallback. Two distinct families in the issued baseline do.
				// Candidates from THREE DISTINCT block families, none beating the incumbent by the margin.
				// With only grpc ranked, served = {vision, grpc} — both reality-tcp, which fold to ONE block
				// family — so excluding the demoted vision left a single family and the floor refused. The
				// branch is unreachable with a same-family fixture, which is why the original row skipped.
				in.Ranked = []spec.RotationCandidate{
					cand("vless-reality-grpc", 0.2, true),
					cand("hysteria2", 0.2, true),
					cand("trojan", 0.2, true),
				}
				// The baseline MUST contain grpc. DemoteKeepsIndependentFallback intersects the served set
				// with the issued baseline and skips any served proto the baseline does not hold; with grpc
				// absent the intersection was empty, the floor refused, the planner HELD — and the row
				// t.Skipped. The demote branch's own `to.ToPort = 0` was therefore enforced by nothing, while
				// the commit that added it said otherwise (Audit-0010 F-011).
				in.IssuedBaseline = []string{"vless-reality-vision", "vless-reality-grpc", "hysteria2", "trojan"}
				return in
			}(),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, err := Plan(tc.in)
			if err != nil {
				t.Fatalf("Plan: %v", err)
			}
			// FAIL, never skip. A skip here is indistinguishable from the assertion passing, and that is
			// exactly what happened: the demote row held for a fixture reason and reported nothing, so one
			// of the two branches this test exists to cover was never reached.
			if !p.Act {
				t.Fatalf("the planner HELD (%s), so this row asserted nothing about the branch it names. "+
					"Fix the fixture until the branch is reached — a row that cannot reach its own code path "+
					"is a pass indistinguishable from absent coverage.", p.HeldBecause)
			}
			if p.To.ToPort != 0 {
				t.Fatalf("the planner emitted an act plan carrying to_port=%d under action %q. "+
					"The executor applies to_port without consulting the action, and the port key survives "+
					"write_params, so this is a served-port move executed unattended while rotate-port is "+
					"supposed to be unrequestable. Every issued client config still names the old port.",
					p.To.ToPort, p.To.Action)
			}
			if p.To.Action == spec.RotationActionRotatePort {
				t.Fatalf("the planner emitted the reserved action %q outright", p.To.Action)
			}
		})
	}
}
