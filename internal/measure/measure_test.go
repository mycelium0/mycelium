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
	if _, err := a.Tick(nil, "no-such-ref", spec.RotationState{}, t0); err == nil {
		t.Error("Tick with unknown active ref: want error")
	}
	if _, err := a.Tick([]spec.TransportHealth{health("ghost-ref", 5, 0, t0)}, activeRef, spec.RotationState{}, t0); err == nil {
		t.Error("Tick with snapshot ref not a member: want error")
	}
	dup := []spec.TransportHealth{health(candRef, 6, 0, t0), health(candRef, 0, 6, t0)}
	if _, err := a.Tick(dup, activeRef, spec.RotationState{}, t0); err == nil {
		t.Error("Tick with a duplicate ref in one snapshot: want fail-closed error (one window double-folded otherwise)")
	}
}

// TestZeroSampleWindowIsNoData proves a window with no probes (the ref's samples lapsed or aged out)
// is treated as no-data, not as a black-hole: it is not folded, so a quiet member keeps its carried
// verdict instead of latching to Shutdown.
func TestZeroSampleWindowIsNoData(t *testing.T) {
	a := newAsm(t)
	// Establish a clean verdict for the active.
	pi, err := a.Tick([]spec.TransportHealth{health(activeRef, 6, 0, t0), health(candRef, 6, 0, t0)}, activeRef, spec.RotationState{}, t0)
	if err != nil {
		t.Fatalf("warm tick: %v", err)
	}
	if pi.ActiveVerdict.State != spec.ConnStateClean {
		t.Fatalf("warm active verdict = %q, want clean", pi.ActiveVerdict.State)
	}
	// The active now reports a 0/0 window (probes lapsed). It must NOT be classified Shutdown.
	at := t0.Add(time.Minute)
	pi, err = a.Tick([]spec.TransportHealth{health(activeRef, 0, 0, at), health(candRef, 6, 0, at)}, activeRef, spec.RotationState{}, at)
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
		pi, err = a.Tick(snap, activeRef, spec.RotationState{}, at)
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

// TestAssembleClosesLoopActs is the end-to-end proof: an impaired active that then idles out of the
// snapshot evaporates below a still-clean sibling by the margin, so the assembled input drives the
// planner to rotate. This closes the measure -> detect -> tune -> assemble -> plan loop.
func TestAssembleClosesLoopActs(t *testing.T) {
	a := newAsm(t)
	// Phase 1: active failing, candidate clean — active verdict latches impaired, candidate climbs.
	for i := 0; i < 5; i++ {
		at := t0.Add(time.Duration(i) * time.Minute)
		snap := []spec.TransportHealth{health(activeRef, 0, 6, at), health(candRef, 6, 0, at)}
		if _, err := a.Tick(snap, activeRef, spec.RotationState{}, at); err != nil {
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
		pi, err = a.Tick(snap, activeRef, st, at)
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
		p1, err1 := a1.Tick(snap, activeRef, st, at)
		p2, err2 := a2.Tick(snap, activeRef, st, at)
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
		before, err = a.Tick(snap, activeRef, spec.RotationState{}, at)
		if err != nil {
			t.Fatalf("warmup tick %d: %v", i, err)
		}
	}
	if before.ActiveVerdict.State != spec.ConnStateClean {
		t.Fatalf("active verdict after clean warmup = %q, want clean", before.ActiveVerdict.State)
	}
	// Two hours later, only the candidate reports; the active idles.
	after, err := a.Tick([]spec.TransportHealth{health(candRef, 6, 0, t0.Add(2*time.Hour))}, activeRef, spec.RotationState{}, t0.Add(2*time.Hour))
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
