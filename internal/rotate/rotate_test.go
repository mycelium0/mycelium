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
			// HALF-OPEN, (Now-Window, Now] — the convention RotationLimits.MaxPerWindow documents. The
			// first version of this loop counted a CLOSED interval and reported 3 against a cap of 2,
			// which looked like an overrun and was a boundary coincidence: with MinInterval*MaxPerWindow
			// == Window the acts land exactly Window/MaxPerWindow apart, so a closed interval always
			// catches one extra at its left endpoint. Measured both ways before this was settled.
			n := 0
			for _, a := range acts {
				if a.After(cur.Now.Add(-lim.Window)) && !a.After(cur.Now) {
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
	// THE BOUND IS EXACTLY MaxPerWindow, and the cooldown alone delivers it.
	//
	// RotationLimits.Validate requires MinInterval*MaxPerWindow >= Window (exactly — see the note there
	// on why it multiplies). Points at least MinInterval apart inside a half-open interval of length
	// Window therefore number at most Window/MinInterval <= MaxPerWindow. That is the whole anti-beacon
	// argument, it holds without any counter, and it is why the per-window budget guard was deleted as
	// unreachable rather than repaired.
	//
	// This row is the schedule-level check of that arithmetic: it iterates the planner from the zero
	// state so every state visited is one the system can actually enter, which the deleted guard's tests
	// did not do — they injected RotationsInWindow = MaxPerWindow, a state reachable only by two acts
	// closer together than MinInterval.
	if worst > lim.MaxPerWindow {
		t.Fatalf("%d acts inside one half-open %v window, cap %d, acts at %v. MinInterval*MaxPerWindow >= "+
			"Window is supposed to make this impossible without any counter; if it fails, that inequality "+
			"no longer holds and the anti-beacon property has nothing enforcing it.",
			worst, lim.Window, lim.MaxPerWindow, acts)
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

// ---------------------------------------------------------------------------------------------------
// ADR-0040 2.2 / 2.3 — the planner judges a SET, each member with its own streak and its own direction.
//
// A node serves several people with different constraints, so no single member's health stands for the
// node. Before this, one counter served every member: an impairment on A advanced the very streak that
// authorised demoting B, and B was taken out of service on evidence about something else. These tests
// are the arithmetic of that.
// ---------------------------------------------------------------------------------------------------

func member(proto string, w float64, st spec.ConnState, dir spec.TransportDirection) ServedMember {
	c := cand(proto, w, true)
	c.Action = spec.RotationActionNone
	reason := spec.ReasonNone
	if st != spec.ConnStateClean {
		reason = spec.ReasonHandshakeTimeout
	}
	return ServedMember{Member: c, Verdict: vdt(st, reason), Direction: dir}
}

// TestSetImpairmentDoesNotCrossMembers is the defect this change exists to remove.
func TestSetImpairmentDoesNotCrossMembers(t *testing.T) {
	in := base()
	in.Active = spec.RotationCandidate{}
	in.ActiveVerdict = spec.Verdict{}
	in.State = spec.RotationState{}
	in.Served = []ServedMember{
		member("vless-reality-vision", 0.2, spec.ConnStateBlocked, spec.DirectionIngress),
		member("hysteria2", 0.9, spec.ConnStateClean, spec.DirectionIngress),
	}
	p := mustPlan(t, in)

	if got := p.NextState.ImpairedStreaks["hysteria2"]; got != 0 {
		t.Errorf("the CLEAN member accrued a streak of %d. One member impairment must never advance the counter that authorises demoting another - that is how a healthy transport was taken out of service on evidence about a different one.", got)
	}
	if got := p.NextState.ImpairedStreaks["vless-reality-vision"]; got != 1 {
		t.Errorf("the impaired member streak is %d, want 1", got)
	}
	if p.From.Proto != "vless-reality-vision" {
		t.Errorf("the plan is about %q; it must be about the impaired member", p.From.Proto)
	}
}

// TestSetPicksTheLongestStreak: with two impaired members the subject is deterministic, because a pure
// planner whose decision depends on map order is not reproducible and cannot be audited.
func TestSetPicksTheLongestStreak(t *testing.T) {
	in := base()
	in.Active = spec.RotationCandidate{}
	in.ActiveVerdict = spec.Verdict{}
	in.State = spec.RotationState{ImpairedStreaks: map[string]int{"hysteria2": 2}}
	in.Served = []ServedMember{
		member("vless-reality-vision", 0.2, spec.ConnStateBlocked, spec.DirectionIngress),
		member("hysteria2", 0.2, spec.ConnStateBlocked, spec.DirectionIngress),
	}
	for i := 0; i < 5; i++ {
		p := mustPlan(t, in)
		if p.From.Proto != "hysteria2" {
			t.Fatalf("run %d picked %q; the member with the longer streak must be the subject", i, p.From.Proto)
		}
	}
}

// TestSetHoldsWhenEveryMemberIsClean - a healthy set selects nothing, and the hold names a real member.
func TestSetHoldsWhenEveryMemberIsClean(t *testing.T) {
	in := base()
	in.Active = spec.RotationCandidate{}
	in.ActiveVerdict = spec.Verdict{}
	in.State = spec.RotationState{}
	in.Served = []ServedMember{
		member("vless-reality-vision", 0.9, spec.ConnStateClean, spec.DirectionIngress),
		member("hysteria2", 0.9, spec.ConnStateClean, spec.DirectionIngress),
	}
	p := mustPlan(t, in)
	if p.Act {
		t.Fatal("a set with no impaired member produced an act")
	}
	if p.Reason != spec.RotationReasonClean {
		t.Errorf("reason %q, want %q", p.Reason, spec.RotationReasonClean)
	}
	if p.From.Proto == "" {
		t.Error("the hold names no member; a plan that says nothing about what it held on is not auditable")
	}
	if len(p.NextState.ImpairedStreaks) != 0 {
		t.Errorf("clean members left streaks behind: %v", p.NextState.ImpairedStreaks)
	}
}

// TestServedNormalisesFromLegacyInput - a producer that has not been updated keeps working unchanged,
// and its single member is treated as ingress, which is what a served inbound is.
func TestServedNormalisesFromLegacyInput(t *testing.T) {
	in := base()
	p := mustPlan(t, in)
	if !p.Act {
		t.Fatalf("the legacy single-member input stopped acting: %s / %s", p.Reason, p.HeldBecause)
	}
	if got := p.NextState.ImpairedStreaks[in.Active.Proto]; got != in.Limits.FlipConfirmations {
		t.Errorf("legacy streak did not carry into the per-member map: %d, want %d", got, in.Limits.FlipConfirmations)
	}
}

// TestServedIgnoresLegacyFieldsWhenPopulated - two half-populated sources is the duplicate-truth defect
// this change removes, so Active must be ignored rather than merged.
func TestServedIgnoresLegacyFieldsWhenPopulated(t *testing.T) {
	in := base()
	in.Active = cand("tuic", 0.9, true)
	in.ActiveVerdict = vdt(spec.ConnStateClean, spec.ReasonNone)
	in.State = spec.RotationState{}
	in.Served = []ServedMember{member("vless-reality-vision", 0.2, spec.ConnStateBlocked, spec.DirectionIngress)}
	p := mustPlan(t, in)
	if p.From.Proto == "tuic" {
		t.Fatal("the planner read the legacy Active while Served was populated - two sources for one truth")
	}
	if p.From.Proto != "vless-reality-vision" {
		t.Errorf("subject is %q, want the served impaired member", p.From.Proto)
	}
}

// TestServedRefusesAnUnknownDirection - direction is the machine-checkable half of ADR-0039: what the
// node may conclude about a member depends on which way it faces, so an unset one is fail-closed.
func TestServedRefusesAnUnknownDirection(t *testing.T) {
	in := base()
	in.Served = []ServedMember{member("vless-reality-vision", 0.2, spec.ConnStateBlocked, "")}
	if _, err := Plan(in); err == nil {
		t.Fatal("a served member with no direction was accepted. Direction decides what evidence may justify suppressing it; unset must fail closed, not default.")
	}
	in.Served[0].Direction = spec.TransportDirection("sideways")
	if _, err := Plan(in); err == nil {
		t.Fatal("an out-of-vocabulary direction was accepted")
	}
}

// TestStreaksDropWhenAMemberLeavesTheSet - a stale streak would let a returning member be demoted the
// moment it reappears, on evidence gathered while it was not being served.
func TestStreaksDropWhenAMemberLeavesTheSet(t *testing.T) {
	in := base()
	in.Active = spec.RotationCandidate{}
	in.ActiveVerdict = spec.Verdict{}
	in.State = spec.RotationState{ImpairedStreaks: map[string]int{"hysteria2": 3, "vless-reality-vision": 1}}
	in.Served = []ServedMember{member("vless-reality-vision", 0.2, spec.ConnStateBlocked, spec.DirectionIngress)}
	p := mustPlan(t, in)
	if _, still := p.NextState.ImpairedStreaks["hysteria2"]; still {
		t.Error("a member no longer in the served set kept its streak. It would be demoted the instant it returned, on evidence gathered while nobody was served by it.")
	}
}

// TestScalarStreakMigratesToTheIncumbentOnly is the upgrade every live node performs exactly once: the
// state file holds a scalar and no map, while the updated producer starts sending the whole set.
func TestScalarStreakMigratesToTheIncumbentOnly(t *testing.T) {
	in := base()
	in.State = spec.RotationState{ImpairedStreak: 2} // no map: written by a spine that had none
	in.Served = []ServedMember{
		member("vless-reality-vision", 0.2, spec.ConnStateBlocked, spec.DirectionIngress),
		member("hysteria2", 0.2, spec.ConnStateBlocked, spec.DirectionIngress),
	}
	p := mustPlan(t, in)
	// in.Active is vless-reality-vision in base(); the scalar was that member streak and nobody else.
	if got := p.NextState.ImpairedStreaks["vless-reality-vision"]; got != 3 {
		t.Errorf("the incumbent streak is %d, want 3. Dropping the scalar makes an upgrading node wait another full hysteresis cycle before it may act - on a node whose transport is failing at that moment.", got)
	}
	if got := p.NextState.ImpairedStreaks["hysteria2"]; got != 1 {
		t.Errorf("a non-incumbent member came out at %d, want 1. The scalar belonged to one member; spreading it authorises acting on the others a cycle early, on evidence never gathered about them.", got)
	}

	// And an incumbent that is NOT in the served set hands its streak to nobody.
	in.Active = cand("tuic", 0.9, true)
	p = mustPlan(t, in)
	for proto, n := range p.NextState.ImpairedStreaks {
		if n != 1 {
			t.Errorf("%s inherited a streak of %d from an incumbent outside the served set", proto, n)
		}
	}
}

// ---------------------------------------------------------------------------------------------------
// A PLAN MUST BE ABLE TO CHANGE WHAT IT IS ABOUT.
//
// Measured on all three live nodes on 2026-08-15: the subject was a member the node was NOT steering to,
// the plan promoted a third member, the apply logged "candidate identical to the live config", and the
// whole thing repeated every 30 minutes from at least 2026-08-14T20:34 — an act, every cooldown, for
// ever, that changed nothing and spent the cooldown a real fault would have needed.
// ---------------------------------------------------------------------------------------------------

// TestPromoteIsNotAnAnswerToANonIncumbentSubject is that loop, as a value.
func TestPromoteIsNotAnAnswerToANonIncumbentSubject(t *testing.T) {
	in := base()
	in.Active = cand("vless-reality-vision", 0.99, true) // the incumbent, healthy
	in.ActiveVerdict = vdt(spec.ConnStateClean, spec.ReasonNone)
	in.State = spec.RotationState{ImpairedStreaks: map[string]int{"hysteria2": 3}}
	in.Served = []ServedMember{
		member("vless-reality-vision", 0.99, spec.ConnStateClean, spec.DirectionIngress),
		member("hysteria2", 0.05, spec.ConnStateBlocked, spec.DirectionIngress),
	}
	// A healthy sibling that easily clears the margin — the shape that used to produce a promote.
	in.Ranked = []spec.RotationCandidate{cand("tuic", 0.99, true)}
	p := mustPlan(t, in)

	if p.From.Proto != "hysteria2" {
		t.Fatalf("subject is %q, want the impaired member", p.From.Proto)
	}
	if p.Act && p.To.Action == spec.RotationActionPromoteSibling {
		t.Fatalf("the plan promotes %q while it is about %q. Promoting steers traffic off the INCUMBENT; when the subject is somebody else the move leaves it exactly as it was, so it is the subject again next tick — an act every cooldown, for ever, that changes nothing.", p.To.Proto, p.From.Proto)
	}
	if p.Act {
		// The only act permitted here is the one that is ABOUT the subject.
		if p.To.Action != spec.RotationActionDemoteActive || p.To.Proto != "hysteria2" {
			t.Fatalf("the only act available for a non-incumbent subject is ceasing to serve it; got %s on %s", p.To.Action, p.To.Proto)
		}
	}
}

// TestANonActionableSubjectDoesNotSpendTheCooldown is the harm, separated from the churn: every act sets
// LastRotateAt, so an act that changes nothing still makes the next REAL fault wait out Guard 4.
func TestANonActionableSubjectDoesNotSpendTheCooldown(t *testing.T) {
	in := base()
	in.Active = cand("vless-reality-vision", 0.99, true)
	in.ActiveVerdict = vdt(spec.ConnStateClean, spec.ReasonNone)
	in.State = spec.RotationState{ImpairedStreaks: map[string]int{"hysteria2": 3}}
	in.Served = []ServedMember{
		member("vless-reality-vision", 0.99, spec.ConnStateClean, spec.DirectionIngress),
		member("hysteria2", 0.05, spec.ConnStateBlocked, spec.DirectionIngress),
	}
	in.Ranked = []spec.RotationCandidate{cand("tuic", 0.99, true)}
	in.IssuedBaseline = nil // nothing known to be issued -> the demote is refused, fail-closed

	// Twenty cooldowns, feeding the state back exactly as the loop does.
	st := in.State
	acts := 0
	for i := 0; i < 20; i++ {
		in.State = st
		in.Now = t0.Add(time.Duration(i) * in.Limits.MinInterval)
		p := mustPlan(t, in)
		if p.Act {
			acts++
		}
		if !p.NextState.LastRotateAt.IsZero() {
			t.Fatalf("tick %d advanced LastRotateAt on a plan that could not change its subject. That is the cooldown a real fault needs, spent on nothing.", i)
		}
		st = p.NextState
	}
	if acts != 0 {
		t.Errorf("%d acts over 20 cooldowns with an unactionable subject, want 0", acts)
	}
}

// TestPromoteStillWorksWhenTheSubjectIsTheIncumbent — the guard must not disarm the ordinary case.
func TestPromoteStillWorksWhenTheSubjectIsTheIncumbent(t *testing.T) {
	in := base() // base() has Active impaired and a promoted sibling that beats it
	p := mustPlan(t, in)
	if !p.Act || p.To.Action != spec.RotationActionPromoteSibling {
		t.Fatalf("an impaired INCUMBENT with a better sibling no longer promotes: act=%v reason=%s held=%s", p.Act, p.Reason, p.HeldBecause)
	}
	if p.NextState.LastRotateAt.IsZero() {
		t.Error("a real act did not advance LastRotateAt; the cooldown would never bind")
	}
}
