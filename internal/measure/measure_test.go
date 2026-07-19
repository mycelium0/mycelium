// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package measure

import (
	"reflect"
	"testing"
	"time"

	"github.com/mycelium0/mycelium/internal/detect"
	"github.com/mycelium0/mycelium/internal/rotate"
	"github.com/mycelium0/mycelium/internal/spec"
	"github.com/mycelium0/mycelium/internal/tune"
)

var t0 = time.Date(2026, 6, 18, 12, 0, 0, 0, time.UTC)

const (
	activeProto = "vless-reality-vision"
	candProto   = "vless-reality-grpc"
	activeRef   = "ref-active"
	candRef     = "ref-cand"
)

// twoMembers is the standard node shape these tests fold over: an active reality-vision member and
// a reality-grpc sibling candidate, each keyed by an opaque reach ref.
func twoMembers() []Member {
	return []Member{
		{Ref: activeRef, Proto: activeProto, Action: spec.RotationActionPromoteSibling},
		{Ref: candRef, Proto: candProto, Action: spec.RotationActionPromoteSibling},
	}
}

func newAsm(t *testing.T) *Assembler {
	t.Helper()
	a, err := New(twoMembers(), rotate.DefaultRotationLimits(), detect.DefaultThresholds(), tune.DefaultParams(), t0)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return a
}

// health builds a valid one-minute-window TransportHealth for ref ending at end.
func health(ref string, succ, fail int, end time.Time) spec.TransportHealth {
	return spec.TransportHealth{TransportRef: ref, Successes: succ, Failures: fail, WindowStart: end.Add(-time.Minute), WindowEnd: end}
}

func TestNewFailClosed(t *testing.T) {
	good := rotate.DefaultRotationLimits()
	cases := []struct {
		name    string
		members []Member
		limits  spec.RotationLimits
		th      detect.Thresholds
		p       tune.Params
	}{
		{"empty members", nil, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"empty ref", []Member{{Ref: "", Proto: activeProto, Action: spec.RotationActionPromoteSibling}}, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"duplicate ref", []Member{
			{Ref: "x", Proto: activeProto, Action: spec.RotationActionPromoteSibling},
			{Ref: "x", Proto: candProto, Action: spec.RotationActionPromoteSibling},
		}, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"unknown proto", []Member{{Ref: "x", Proto: "not-a-proto", Action: spec.RotationActionPromoteSibling}}, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"duplicate proto", []Member{
			{Ref: "x", Proto: activeProto, Action: spec.RotationActionPromoteSibling},
			{Ref: "y", Proto: activeProto, Action: spec.RotationActionPromoteSibling},
		}, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"invalid action", []Member{{Ref: "x", Proto: activeProto, Action: spec.RotationAction("teleport")}}, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"port out of range", []Member{{Ref: "x", Proto: activeProto, Action: spec.RotationActionRotatePort, ToPort: 70000}}, good, detect.DefaultThresholds(), tune.DefaultParams()},
		{"bad limits", twoMembers(), spec.RotationLimits{}, detect.DefaultThresholds(), tune.DefaultParams()},
		{"bad thresholds", twoMembers(), good, detect.Thresholds{}, tune.DefaultParams()},
		{"bad params", twoMembers(), good, detect.DefaultThresholds(), tune.Params{}},
	}
	for _, c := range cases {
		if _, err := New(c.members, c.limits, c.th, c.p, t0); err == nil {
			t.Errorf("%s: New succeeded, want fail-closed error", c.name)
		}
	}
}

func TestTickFailClosed(t *testing.T) {
	a := newAsm(t)
	if _, err := a.Tick(nil, "no-such-ref", spec.RotationState{}, t0, nil, nil, nil); err == nil {
		t.Error("Tick with unknown active ref: want error")
	}
	if _, err := a.Tick([]spec.TransportHealth{health("ghost-ref", 5, 0, t0)}, activeRef, spec.RotationState{}, t0, nil, nil, nil); err == nil {
		t.Error("Tick with snapshot ref not a member: want error")
	}
	dup := []spec.TransportHealth{health(candRef, 6, 0, t0), health(candRef, 0, 6, t0)}
	if _, err := a.Tick(dup, activeRef, spec.RotationState{}, t0, nil, nil, nil); err == nil {
		t.Error("Tick with a duplicate ref in one snapshot: want fail-closed error (one window double-folded otherwise)")
	}
}

// TestZeroSampleWindowIsNoData proves a window with no probes (the ref's samples lapsed or aged out)
// is treated as no-data, not as a black-hole: it is not folded, so a quiet member keeps its carried
// verdict instead of latching to Shutdown.
func TestZeroSampleWindowIsNoData(t *testing.T) {
	a := newAsm(t)
	// Establish a clean verdict for the active.
	pi, err := a.Tick([]spec.TransportHealth{health(activeRef, 6, 0, t0), health(candRef, 6, 0, t0)}, activeRef, spec.RotationState{}, t0, nil, nil, nil)
	if err != nil {
		t.Fatalf("warm tick: %v", err)
	}
	if pi.ActiveVerdict.State != spec.ConnStateClean {
		t.Fatalf("warm active verdict = %q, want clean", pi.ActiveVerdict.State)
	}
	// The active now reports a 0/0 window (probes lapsed). It must NOT be classified Shutdown.
	at := t0.Add(time.Minute)
	pi, err = a.Tick([]spec.TransportHealth{health(activeRef, 0, 0, at), health(candRef, 6, 0, at)}, activeRef, spec.RotationState{}, at, nil, nil, nil)
	if err != nil {
		t.Fatalf("no-data tick: %v", err)
	}
	if pi.ActiveVerdict.State == spec.ConnStateShutdown {
		t.Error("zero-sample window classified Shutdown — no-data mistaken for a black-hole")
	}
	if pi.ActiveVerdict.State != spec.ConnStateClean {
		t.Errorf("zero-sample window did not carry the prior clean verdict, got %q", pi.ActiveVerdict.State)
	}
}

// TestTickFoldGolden proves one fold: a failing active becomes an impaired verdict, a clean
// candidate climbs to promoted, the incumbent is split out (no move) and the sibling is the lone
// ranked candidate, and the assembled input is well-formed for the planner.
func TestTickFoldGolden(t *testing.T) {
	a := newAsm(t)
	var pi rotate.PlanInput
	for i := 0; i < 4; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 0, 6, at), health(candRef, 6, 0, at)}
		var err error
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("Tick %d: %v", i, err)
		}
	}
	if pi.ActiveVerdict.State == spec.ConnStateClean || pi.ActiveVerdict.State == spec.ConnStateUnknown {
		t.Errorf("active verdict = %q, want an impaired state", pi.ActiveVerdict.State)
	}
	if pi.Active.Proto != activeProto || pi.Active.Action != spec.RotationActionNone {
		t.Errorf("active candidate = %+v, want proto %q with action none", pi.Active, activeProto)
	}
	if len(pi.Ranked) != 1 || pi.Ranked[0].Proto != candProto {
		t.Fatalf("ranked = %+v, want exactly the %q sibling", pi.Ranked, candProto)
	}
	if !pi.Ranked[0].Promoted {
		t.Errorf("clean candidate not promoted after 4 clean folds (weight %v)", pi.Ranked[0].Weight)
	}
	if _, err := rotate.Plan(pi); err != nil {
		t.Errorf("assembled plan input rejected by the planner: %v", err)
	}
}

// TestTickActiveProbeFaultsBlocked proves the DoD-1 detection-fidelity seam (RP-0010 AC-6 clarification):
// a member whose L4 reach window is HEALTHY (the port connects, the fast-class ratio is clean) but whose
// node-local own-cert/cover-path L7 liveness is DEAD (activeProbe[ref]==false) is classified BLOCKED, not
// clean — the exact L4-only blind spot the loopback L7 probe closes. The control proves the signal is what
// flips it: the SAME healthy window with the probe unset (nil map) stays clean.
func TestTickActiveProbeFaultsBlocked(t *testing.T) {
	dead := map[string]bool{activeRef: false}
	a := newAsm(t)
	var pi rotate.PlanInput
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		// L4 healthy for both members; only the active's node-local L7 own-cert probe is dead.
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, dead, nil, nil)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	if pi.ActiveVerdict.State != spec.ConnStateBlocked {
		t.Errorf("L4-healthy + L7-dead active: verdict = %q, want %q (a high success ratio must not mask a boolean active-probe fault)", pi.ActiveVerdict.State, spec.ConnStateBlocked)
	}
	if pi.ActiveVerdict.Reason != spec.ReasonActiveProbeFailure {
		t.Errorf("reason = %q, want %q", pi.ActiveVerdict.Reason, spec.ReasonActiveProbeFailure)
	}

	// Control: the identical L4-healthy window with the L7 probe unset (nil map -> default healthy) stays
	// clean, so the block above is attributable to the L7 signal, not the fold.
	b := newAsm(t)
	var pc rotate.PlanInput
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		pc, err = b.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("control tick %d: %v", i, err)
		}
	}
	if pc.ActiveVerdict.State != spec.ConnStateClean {
		t.Errorf("L4-healthy + L7 unset active: verdict = %q, want clean", pc.ActiveVerdict.State)
	}
}

// TestAssembleClosesLoopActs is the end-to-end proof: an impaired active that then idles out of the
// snapshot evaporates below a still-clean sibling by the margin, so the assembled input drives the
// planner to rotate. This closes the measure -> detect -> tune -> assemble -> plan loop.
// TestTickMarksCandidateL7Dead: a NON-active member the node's own L7 probe reports dead
// (activeProbe[ref]==false) is surfaced on its ranked candidate as L7Dead=true, so the planner can
// exclude it from the pool (never rotate onto a co-failed sibling — Audit-0007 S2). Only an explicit
// false marks a member; the active (unset here) stays eligible, and a nil map leaves every candidate
// live (the control).
func TestTickMarksCandidateL7Dead(t *testing.T) {
	at := t0
	a := newAsm(t)
	deadCand := map[string]bool{candRef: false} // the CANDIDATE is L7-dead; the active is unset (healthy)
	var pi rotate.PlanInput
	var err error
	for i := 0; i < 3; i++ {
		at = at.Add(time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, deadCand, nil, nil)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	if len(pi.Ranked) != 1 {
		t.Fatalf("ranked = %+v, want exactly one sibling", pi.Ranked)
	}
	if !pi.Ranked[0].L7Dead {
		t.Errorf("candidate %q marked dead in the probe map must carry L7Dead=true", pi.Ranked[0].Proto)
	}
	if pi.Active.L7Dead {
		t.Errorf("active member (unset in the probe map) must not be marked L7Dead")
	}

	// Control: the identical fold with a nil probe map leaves the candidate eligible (L7Dead=false), so
	// the flag above is attributable to the probe signal, not the fold.
	b := newAsm(t)
	at = t0
	var pc rotate.PlanInput
	for i := 0; i < 3; i++ {
		at = at.Add(time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		pc, err = b.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("control tick %d: %v", i, err)
		}
	}
	if pc.Ranked[0].L7Dead {
		t.Error("a nil probe map must leave the candidate eligible (L7Dead=false)")
	}
}

func TestAssembleClosesLoopActs(t *testing.T) {
	a := newAsm(t)
	// Phase 1: active failing, candidate clean — active verdict latches impaired, candidate climbs.
	for i := 0; i < 5; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 0, 6, at), health(candRef, 6, 0, at)}
		if _, err := a.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil); err != nil {
			t.Fatalf("phase-1 tick %d: %v", i, err)
		}
	}
	// Phase 2: the active goes silent (no samples) for two hours while the candidate stays clean. The
	// active's pheromone evaporates toward the floor; its impaired verdict is carried.
	var pi rotate.PlanInput
	for i := 0; i < 5; i++ {
		at := t0.Add(2*time.Hour + time.Duration(i)*time.Minute)
		snap := []spec.TransportHealth{health(candRef, 6, 0, at)} // active omitted
		// Inject the impaired streak the real loop accumulates; +1 this tick reaches FlipConfirmations.
		st := spec.RotationState{ImpairedStreak: rotate.DefaultRotationLimits().FlipConfirmations - 1}
		var err error
		pi, err = a.Tick(snap, activeRef, st, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("phase-2 tick %d: %v", i, err)
		}
	}
	if !(pi.Ranked[0].Weight >= pi.Active.Weight+pi.Limits.MinWeightMargin) {
		t.Fatalf("candidate weight %v does not beat active %v by margin %v", pi.Ranked[0].Weight, pi.Active.Weight, pi.Limits.MinWeightMargin)
	}
	plan, err := rotate.Plan(pi)
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if !plan.Act {
		t.Fatalf("planner held on a clearly-degraded active with a healthy promoted sibling: %+v", plan)
	}
	if plan.To.Proto != candProto {
		t.Errorf("rotated to %q, want %q", plan.To.Proto, candProto)
	}
}

// TestTickDeterministic proves the assembler is a pure fold of its inputs: two assemblers fed the
// identical snapshot stream emit byte-identical plan inputs at every tick (RP-0010 AC-2).
func TestTickDeterministic(t *testing.T) {
	a1, a2 := newAsm(t), newAsm(t)
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, i%2, 6, at), health(candRef, 6, 0, at)}
		st := spec.RotationState{ImpairedStreak: i}
		p1, err1 := a1.Tick(snap, activeRef, st, at, nil, nil, nil)
		p2, err2 := a2.Tick(snap, activeRef, st, at, nil, nil, nil)
		if err1 != nil || err2 != nil {
			t.Fatalf("tick %d errors: %v / %v", i, err1, err2)
		}
		if !reflect.DeepEqual(p1, p2) {
			t.Fatalf("tick %d: non-deterministic plan inputs:\n %+v\n %+v", i, p1, p2)
		}
	}
}

// TestIdleMemberEvaporatesAndCarriesVerdict proves a member absent from a snapshot is not erased:
// its weight evaporates (read at the later clock) and its last verdict is carried, not reset.
func TestIdleMemberEvaporatesAndCarriesVerdict(t *testing.T) {
	a := newAsm(t)
	var before rotate.PlanInput
	for i := 0; i < 4; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		before, err = a.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("warmup tick %d: %v", i, err)
		}
	}
	if before.ActiveVerdict.State != spec.ConnStateClean {
		t.Fatalf("active verdict after clean warmup = %q, want clean", before.ActiveVerdict.State)
	}
	// Two hours later, only the candidate reports; the active idles.
	after, err := a.Tick([]spec.TransportHealth{health(candRef, 6, 0, t0.Add(2*time.Hour))}, activeRef, spec.RotationState{}, t0.Add(2*time.Hour), nil, nil, nil)
	if err != nil {
		t.Fatalf("idle tick: %v", err)
	}
	if !(after.Active.Weight < before.Active.Weight) {
		t.Errorf("idle active weight did not evaporate: before %v, after %v", before.Active.Weight, after.Active.Weight)
	}
	if after.ActiveVerdict.State != spec.ConnStateClean {
		t.Errorf("carried active verdict = %q, want the last clean verdict", after.ActiveVerdict.State)
	}
}

// TestDetectorSignalConnectResetFold locks the chunk-B fold at the signal boundary, independent of the
// detector's hysteresis: a path-level ConnectReset on a CONNECTED member overrides the loopback reach
// HandshakeOK (faulting it) and sets ConnectReset, so Classify reaches blocked/connection-reset — the L4
// reach window connected fine (loopback has no on-path element) but the served client handshakes are being
// reset. The override is gated on connectedness: a not-connected member stays ConnectOK=false -> shutdown
// (the path signal is moot there).
func TestDetectorSignalConnectResetFold(t *testing.T) {
	cls := spec.TransportClassRealityTCP
	connected := health(activeRef, 6, 0, t0)

	// No path signal: the connected member folds clean (HandshakeOK stays true, no reset).
	clean := detectorSignal(cls, connected, true, false, false)
	if !clean.ConnectOK || !clean.HandshakeOK || clean.ConnectReset {
		t.Fatalf("no-signal fold: ConnectOK=%v HandshakeOK=%v ConnectReset=%v, want true,true,false",
			clean.ConnectOK, clean.HandshakeOK, clean.ConnectReset)
	}
	if st, r := detect.Classify(clean); st == spec.ConnStateBlocked && r == spec.ReasonConnectionReset {
		t.Fatal("no-signal fold: Classify unexpectedly reached blocked/connection-reset")
	}

	// Path-level ConnectReset on a connected member: HandshakeOK is overridden to false and ConnectReset is
	// set, while the member stays ConnectOK=true (connected-but-reset). Classify -> blocked/connection-reset.
	reset := detectorSignal(cls, connected, true, true, false)
	if !reset.ConnectOK {
		t.Error("reset fold: ConnectOK must stay true (a connected-but-reset member)")
	}
	if reset.HandshakeOK {
		t.Error("reset fold: the path signal must override HandshakeOK to false")
	}
	if !reset.ConnectReset {
		t.Error("reset fold: ConnectReset must be true")
	}
	if st, r := detect.Classify(reset); st != spec.ConnStateBlocked || r != spec.ReasonConnectionReset {
		t.Errorf("reset fold: Classify = (%v, %v), want (blocked, connection-reset)", st, r)
	}

	// The override is moot on a not-connected member: ConnectOK=false wins -> shutdown, never blocked-reset.
	down := detectorSignal(cls, health(activeRef, 0, 0, t0), true, true, false)
	if down.ConnectOK {
		t.Error("down fold: a member with no successes must stay ConnectOK=false")
	}
	if st, _ := detect.Classify(down); st != spec.ConnStateShutdown {
		t.Errorf("down fold: Classify state = %v, want shutdown (the path signal is moot when not connected)", st)
	}
}

// TestTickPathResetFaultsBlockedReset mirrors the L7-dead active test for chunk B: a member whose L4 reach
// window is HEALTHY (the loopback probe connects) but whose node-local passive path observer reports its
// served client flows meeting RSTs (connectReset[ref]==true) is classified BLOCKED/connection-reset, not
// clean — the on-path reset the loopback reach probe cannot see. The control proves the signal is what flips
// it: the SAME healthy window with the path map unset (nil) stays clean.
func TestTickPathResetFaultsBlockedReset(t *testing.T) {
	reset := map[string]bool{activeRef: true}
	a := newAsm(t)
	var pi rotate.PlanInput
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, nil, reset, nil)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	if pi.ActiveVerdict.State != spec.ConnStateBlocked {
		t.Errorf("L4-healthy + path-reset active: verdict = %q, want %q (a high success ratio must not mask a boolean path-reset fault)", pi.ActiveVerdict.State, spec.ConnStateBlocked)
	}
	if pi.ActiveVerdict.Reason != spec.ReasonConnectionReset {
		t.Errorf("reason = %q, want %q", pi.ActiveVerdict.Reason, spec.ReasonConnectionReset)
	}

	// Control: the identical L4-healthy window with the path map unset (nil -> no fault) stays clean, so the
	// block above is attributable to the path signal, not the fold.
	b := newAsm(t)
	var pc rotate.PlanInput
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		pc, err = b.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("control tick %d: %v", i, err)
		}
	}
	if pc.ActiveVerdict.State != spec.ConnStateClean {
		t.Errorf("L4-healthy + path unset active: verdict = %q, want clean", pc.ActiveVerdict.State)
	}
}

// TestTickMarksCandidatePathReset: a NON-active member the node's passive path observer reports meeting RSTs
// (connectReset[ref]==true) is surfaced on its ranked candidate as PathReset=true, so the planner can exclude
// it from the pool (never rotate onto a co-reset sibling — RP-0014 chunk B). Only an explicit true marks a
// member; the active (unset here) stays eligible, and a nil map leaves every candidate live (the control).
func TestTickMarksCandidatePathReset(t *testing.T) {
	at := t0
	a := newAsm(t)
	resetCand := map[string]bool{candRef: true} // the CANDIDATE is path-reset; the active is unset (healthy)
	var pi rotate.PlanInput
	var err error
	for i := 0; i < 3; i++ {
		at = at.Add(time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, nil, resetCand, nil)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	if len(pi.Ranked) != 1 {
		t.Fatalf("ranked = %+v, want exactly one sibling", pi.Ranked)
	}
	if !pi.Ranked[0].PathReset {
		t.Errorf("candidate %q flagged in the path map must carry PathReset=true", pi.Ranked[0].Proto)
	}
	if pi.Active.PathReset {
		t.Error("active member (unset in the path map) must not be marked PathReset")
	}

	// Control: the identical fold with a nil path map leaves the candidate eligible (PathReset=false), so the
	// flag above is attributable to the path signal, not the fold.
	b := newAsm(t)
	at = t0
	var pc rotate.PlanInput
	for i := 0; i < 3; i++ {
		at = at.Add(time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		pc, err = b.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("control tick %d: %v", i, err)
		}
	}
	if pc.Ranked[0].PathReset {
		t.Error("a nil path map must leave the candidate eligible (PathReset=false)")
	}
}

// TestDetectorSignalPostConnectCollapseFold locks the increment-2 fold at the signal boundary: a
// PostConnectCollapse on a CONNECTED member leaves HandshakeOK + ActiveProbeOK UNTOUCHED (the connection did
// establish and the loopback L7 passes; the collapse is post-connect) and sets PostConnectCollapse, so
// Classify reaches throttled/throughput-collapse. Precedence: a member tripping BOTH reset and collapse hits
// the more-severe blocked/connection-reset branch first. The signal is moot on a not-connected member.
func TestDetectorSignalPostConnectCollapseFold(t *testing.T) {
	cls := spec.TransportClassRealityTCP
	connected := health(activeRef, 6, 0, t0)

	// Collapse only: HandshakeOK stays true, ActiveProbeOK stays true, PostConnectCollapse set -> throttled.
	col := detectorSignal(cls, connected, true, false, true)
	if !col.ConnectOK || !col.HandshakeOK || !col.ActiveProbeOK {
		t.Fatalf("collapse fold: ConnectOK/HandshakeOK/ActiveProbeOK must stay true, got %v/%v/%v", col.ConnectOK, col.HandshakeOK, col.ActiveProbeOK)
	}
	if !col.PostConnectCollapse {
		t.Error("collapse fold: PostConnectCollapse must be true")
	}
	if st, r := detect.Classify(col); st != spec.ConnStateThrottled || r != spec.ReasonThroughputCollapse {
		t.Errorf("collapse fold: Classify = (%v, %v), want (throttled, throughput-collapse)", st, r)
	}

	// Reset AND collapse: reset dominates (faults HandshakeOK) -> blocked/connection-reset, the safer verdict.
	both := detectorSignal(cls, connected, true, true, true)
	if st, r := detect.Classify(both); st != spec.ConnStateBlocked || r != spec.ReasonConnectionReset {
		t.Errorf("reset+collapse fold: Classify = (%v, %v), want (blocked, connection-reset) — reset must win", st, r)
	}

	// Not connected: the collapse is moot -> ConnectOK=false -> shutdown, never throttled.
	down := detectorSignal(cls, health(activeRef, 0, 0, t0), true, false, true)
	if down.PostConnectCollapse {
		t.Error("down fold: PostConnectCollapse must be gated off when not connected")
	}
	if st, _ := detect.Classify(down); st != spec.ConnStateShutdown {
		t.Errorf("down fold: Classify state = %v, want shutdown", st)
	}
}

// TestTickPathCollapseFaultsThrottled mirrors the path-reset active test for increment 2: a member whose L4
// reach is HEALTHY and whose loopback L7 passes but whose established served flows the observer reports
// collapsing (postConnectCollapse[ref]==true) is classified THROTTLED/throughput-collapse. The control (nil
// map) stays clean, so the throttle is attributable to the collapse signal.
func TestTickPathCollapseFaultsThrottled(t *testing.T) {
	col := map[string]bool{activeRef: true}
	a := newAsm(t)
	var pi rotate.PlanInput
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, col)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	if pi.ActiveVerdict.State != spec.ConnStateThrottled || pi.ActiveVerdict.Reason != spec.ReasonThroughputCollapse {
		t.Errorf("L4-healthy + path-collapse active: verdict = (%q, %q), want (throttled, throughput-collapse)", pi.ActiveVerdict.State, pi.ActiveVerdict.Reason)
	}

	b := newAsm(t)
	var pc rotate.PlanInput
	for i := 0; i < 6; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		var err error
		pc, err = b.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("control tick %d: %v", i, err)
		}
	}
	if pc.ActiveVerdict.State != spec.ConnStateClean {
		t.Errorf("L4-healthy + collapse unset active: verdict = %q, want clean", pc.ActiveVerdict.State)
	}
}

// TestTickMarksCandidatePathCollapse: a NON-active member the observer reports collapsing is surfaced on its
// ranked candidate as PathCollapse=true, so the planner excludes it from the pool. Only an explicit true
// marks a member; the active (unset) stays eligible, and a nil map leaves every candidate live (the control).
func TestTickMarksCandidatePathCollapse(t *testing.T) {
	at := t0
	a := newAsm(t)
	colCand := map[string]bool{candRef: true}
	var pi rotate.PlanInput
	var err error
	for i := 0; i < 3; i++ {
		at = at.Add(time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, colCand)
		if err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	if len(pi.Ranked) != 1 {
		t.Fatalf("ranked = %+v, want exactly one sibling", pi.Ranked)
	}
	if !pi.Ranked[0].PathCollapse {
		t.Errorf("candidate %q flagged in the collapse map must carry PathCollapse=true", pi.Ranked[0].Proto)
	}
	if pi.Active.PathCollapse {
		t.Error("active member (unset in the collapse map) must not be marked PathCollapse")
	}

	b := newAsm(t)
	at = t0
	var pc rotate.PlanInput
	for i := 0; i < 3; i++ {
		at = at.Add(time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 6, 0, at)}
		pc, err = b.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil)
		if err != nil {
			t.Fatalf("control tick %d: %v", i, err)
		}
	}
	if pc.Ranked[0].PathCollapse {
		t.Error("a nil collapse map must leave the candidate eligible (PathCollapse=false)")
	}
}

// TestStatusObservations proves the chunk-C projection seam: the plane's held per-member verdicts project to
// per-CLASS advisory-health observations (the lossy alive/degraded/unknown view, ADR-0030), grouped by class,
// and that projection feeds spec.BuildNodeStatusDigest to a valid k-floored digest from ONE node's own
// multi-member class (reality-tcp has 2 members here, clearing a k=2 floor) — no second node, no transport.
func TestStatusObservations(t *testing.T) {
	a := newAsm(t)
	// Warm both members: active clean (-> alive), candidate all-failure (-> impaired -> degraded, lossy).
	for i := 0; i < 4; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 6, 0, at), health(candRef, 0, 6, at)}
		if _, err := a.Tick(snap, activeRef, spec.RotationState{}, at, nil, nil, nil); err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
	}
	obs := a.StatusObservations()
	// Both default members are reality-tcp -> one class with two observations.
	hs, ok := obs[spec.TransportClassRealityTCP]
	if !ok || len(hs) != 2 {
		t.Fatalf("StatusObservations = %+v, want reality-tcp with 2 observations", obs)
	}
	// Lossy projection: exactly one alive (the clean active) + one degraded (the impaired candidate); the
	// fine state (throttled/blocked/shutdown) is not distinguishable in the advisory view.
	var alive, degraded int
	for _, h := range hs {
		switch h {
		case spec.HealthAlive:
			alive++
		case spec.HealthDegraded:
			degraded++
		}
	}
	if alive != 1 || degraded != 1 {
		t.Errorf("projection = %v (alive=%d degraded=%d), want 1 alive + 1 degraded", hs, alive, degraded)
	}
	// The seam connects: the projection feeds BuildNodeStatusDigest to a valid k=2 digest from this one node.
	d, err := spec.BuildNodeStatusDigest(spec.TrustScope{ID: "local", MaxHops: 0}, obs, 2, time.Hour, t0)
	if err != nil {
		t.Fatalf("BuildNodeStatusDigest from the projection: %v", err)
	}
	if len(d.Classes) != 1 || d.Classes[0].Class != spec.TransportClassRealityTCP {
		t.Fatalf("digest classes = %+v, want exactly reality-tcp", d.Classes)
	}
	// reality-tcp aggregates alive-dominant (any member alive -> class alive).
	if d.Classes[0].Health != spec.HealthAlive {
		t.Errorf("reality-tcp class health = %q, want alive (alive-dominant aggregate)", d.Classes[0].Health)
	}
	// A k=3 floor omits reality-tcp (only 2 members) -> nothing clears the floor -> emit-nothing (fail-closed).
	if _, err := spec.BuildNodeStatusDigest(spec.TrustScope{ID: "local"}, obs, 3, time.Hour, t0); err == nil {
		t.Error("k=3 floor on a 2-member class must fail-closed (ErrAggregationFloor), got a digest")
	}
}
