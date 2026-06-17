// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package tune

import (
	"math"
	"testing"
	"time"

	"github.com/mindicator/mycelium/internal/spec"
)

var tBase = time.Date(2026, 6, 17, 12, 0, 0, 0, time.UTC)

func verdict(state spec.ConnState, reason spec.DetectReason) spec.Verdict {
	return spec.Verdict{State: state, Reason: reason, Class: spec.TransportClassRealityTCP, TransportRef: "tx-1", DecidedAt: tBase}
}

func cleanV() spec.Verdict    { return verdict(spec.ConnStateClean, spec.ReasonNone) }
func blockedV() spec.Verdict  { return verdict(spec.ConnStateBlocked, spec.ReasonHandshakeTimeout) }
func shutdownV() spec.Verdict { return verdict(spec.ConnStateShutdown, spec.ReasonUnreachable) }

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func mustWeight(t *testing.T, p Params) *Weight {
	t.Helper()
	w, err := NewWeight(spec.TransportClassRealityTCP, "tx-1", p, tBase)
	if err != nil {
		t.Fatalf("NewWeight: %v", err)
	}
	return w
}

func TestParamsValidate(t *testing.T) {
	if err := DefaultParams().Validate(); err != nil {
		t.Fatalf("DefaultParams must validate: %v", err)
	}
	base := DefaultParams()
	bad := []func(*Params){
		func(p *Params) { p.Reinforce = 1.5 },                                  // gain > 1
		func(p *Params) { p.Reinforce = math.NaN() },                           // NaN gain
		func(p *Params) { p.PromoteThreshold = -0.1 },                          // threshold < 0
		func(p *Params) { p.Initial = 0.0 },                                    // below RetentionFloor (0.05)
		func(p *Params) { p.Decay.HalfLife = 0 },                               // invalid decay
		func(p *Params) { p.PromoteThreshold, p.Decay.Hysteresis = 0.95, 0.2 }, // band high edge escapes [0,1]
		func(p *Params) { p.PromoteThreshold, p.Decay.Hysteresis = 0.06, 0.1 }, // low edge 0.01 below floor 0.05 -> un-demotable
		func(p *Params) {
			p.PromoteThreshold, p.Decay.Hysteresis, p.Reinforce = 0.95, 0.1, 0.5
		}, // high edge 1.0 with reinforce<1 -> un-promotable
		func(p *Params) { p.Decay.RetentionFloor = math.NaN() }, // NaN floor -> DecayPolicy.Validate rejects (fail-closed, not fail-open)
	}
	for i, mut := range bad {
		p := base
		mut(&p)
		if err := p.Validate(); err == nil {
			t.Fatalf("bad params[%d] must fail Validate", i)
		}
	}
}

func TestNewWeightFailClosed(t *testing.T) {
	if _, err := NewWeight(spec.TransportClass("nope"), "tx-1", DefaultParams(), tBase); err == nil {
		t.Fatal("NewWeight must reject an unknown class")
	}
	if _, err := NewWeight(spec.TransportClassRealityTCP, "", DefaultParams(), tBase); err == nil {
		t.Fatal("NewWeight must reject an empty transport ref")
	}
	bad := DefaultParams()
	bad.Reinforce = 2
	if _, err := NewWeight(spec.TransportClassRealityTCP, "tx-1", bad, tBase); err == nil {
		t.Fatal("NewWeight must reject invalid params")
	}
}

// TestEvaporationToFloor: with no observations the weight decays toward RetentionFloor — halving the
// excess-over-floor each HalfLife — and never drops below the floor.
func TestEvaporationToFloor(t *testing.T) {
	p := DefaultParams()
	p.Initial = 1.0
	w := mustWeight(t, p)
	floor := p.Decay.RetentionFloor
	hl := p.Decay.HalfLife

	atHalf := w.Value(tBase.Add(hl))
	if !near(atHalf, floor+(1.0-floor)*0.5) {
		t.Fatalf("after one half-life Value=%v, want %v", atHalf, floor+(1.0-floor)*0.5)
	}
	// Far in the future it approaches, but never goes below, the floor.
	far := w.Value(tBase.Add(1000 * hl))
	if far < floor {
		t.Fatalf("Value %v dropped below RetentionFloor %v", far, floor)
	}
	if !near(far, floor) && far > floor+1e-3 {
		t.Fatalf("Value %v did not approach the floor %v", far, floor)
	}
	// Value is read-only: a clock-skewed past read does not increase the weight.
	if past := w.Value(tBase.Add(-hl)); past > p.Initial {
		t.Fatalf("a past read increased the weight: %v > %v", past, p.Initial)
	}
}

// TestReinforceClimbs: repeated clean verdicts drive the weight up toward 1 and promote the path.
func TestReinforceClimbs(t *testing.T) {
	w := mustWeight(t, DefaultParams())
	at := tBase
	for i := 0; i < 6; i++ {
		at = at.Add(time.Minute)
		if err := w.Observe(cleanV(), at); err != nil {
			t.Fatalf("observe: %v", err)
		}
	}
	if v := w.Value(at); v < 0.9 {
		t.Fatalf("after sustained clean, weight=%v, want >0.9", v)
	}
	if !w.Promoted() {
		t.Fatal("a sustained-clean path must be promoted")
	}
}

// TestFadeAndRePromoteWithoutTeardown is the AC-3 marquee: a path that goes blocked fades toward the
// floor and is demoted, then re-promotes automatically when clean verdicts return — all on the SAME
// Weight (no teardown / re-creation), and the weight never drops below RetentionFloor.
func TestFadeAndRePromoteWithoutTeardown(t *testing.T) {
	p := DefaultParams()
	w := mustWeight(t, p)
	floor := p.Decay.RetentionFloor
	at := tBase

	check := func(label string) {
		if v := w.Value(at); v < floor-1e-12 {
			t.Fatalf("%s: weight %v dropped below RetentionFloor %v", label, v, floor)
		}
	}

	// Warm up clean -> promoted.
	for i := 0; i < 4; i++ {
		at = at.Add(time.Minute)
		if err := w.Observe(cleanV(), at); err != nil {
			t.Fatalf("warmup observe: %v", err)
		}
		check("warmup")
	}
	if !w.Promoted() || w.Value(at) < 0.8 {
		t.Fatalf("after warmup: promoted=%v value=%v, want promoted high", w.Promoted(), w.Value(at))
	}

	// Sustained blocked, a half-life apart -> fades toward the floor, demotes.
	for i := 0; i < 6; i++ {
		at = at.Add(p.Decay.HalfLife)
		if err := w.Observe(blockedV(), at); err != nil {
			t.Fatalf("blocked observe: %v", err)
		}
		check("blocked")
	}
	if w.Promoted() {
		t.Fatalf("a sustainedly-blocked path must be demoted; value=%v", w.Value(at))
	}
	fadedTo := w.Value(at)
	if fadedTo > 0.2 {
		t.Fatalf("blocked path did not fade (value=%v)", fadedTo)
	}

	// Recovery: clean verdicts return -> re-promotes on the SAME object, no teardown.
	for i := 0; i < 4; i++ {
		at = at.Add(time.Minute)
		if err := w.Observe(cleanV(), at); err != nil {
			t.Fatalf("recovery observe: %v", err)
		}
		check("recovery")
	}
	if !w.Promoted() {
		t.Fatal("a recovered path must re-promote without teardown")
	}
	if w.Value(at) <= fadedTo {
		t.Fatalf("recovery did not raise the weight: %v <= %v", w.Value(at), fadedTo)
	}
}

// TestHysteresisHoldsInBand: the promote flag is held while the weight sits in the [threshold-h/2,
// threshold+h/2] band — a bare threshold would demote at w just below the threshold, but the
// hysteresis band keeps the prior (promoted) decision until the weight clears the low edge.
func TestHysteresisHoldsInBand(t *testing.T) {
	p := Params{
		Decay:            spec.DecayPolicy{TTL: time.Hour, HalfLife: 30 * time.Minute, Hysteresis: 0.4, RetentionFloor: 0.0},
		Reinforce:        1.0,
		PromoteThreshold: 0.6, // band [0.4, 0.8]
		Initial:          0.0, // starts un-promoted
	}
	w := mustWeight(t, p)
	at := tBase

	// One clean obs -> weight 1.0, promoted (>= hi 0.8).
	at = at.Add(time.Minute)
	if err := w.Observe(cleanV(), at); err != nil {
		t.Fatalf("observe: %v", err)
	}
	if !w.Promoted() {
		t.Fatal("clean obs should promote")
	}

	// One half-life of shutdown -> weight ~0.5: BELOW the 0.6 threshold but ABOVE the 0.4 low edge,
	// so the promote flag must HOLD (the distinguishing hysteresis behaviour).
	at = at.Add(p.Decay.HalfLife)
	if err := w.Observe(shutdownV(), at); err != nil {
		t.Fatalf("observe: %v", err)
	}
	if v := w.Value(at); v < 0.45 || v > 0.55 {
		t.Fatalf("expected weight ~0.5 in the band, got %v", v)
	}
	if !w.Promoted() {
		t.Fatal("hysteresis must hold the promote flag while in the band (w below threshold, above low edge)")
	}

	// Another half-life of shutdown -> ~0.25, below the low edge -> demote.
	at = at.Add(p.Decay.HalfLife)
	if err := w.Observe(shutdownV(), at); err != nil {
		t.Fatalf("observe: %v", err)
	}
	if w.Promoted() {
		t.Fatalf("crossing below the low edge must demote; value=%v", w.Value(at))
	}
}

// TestDeterministic: the same verdict+time sequence yields identical weight and promote state.
func TestDeterministic(t *testing.T) {
	steps := []struct {
		v  spec.Verdict
		dt time.Duration
	}{
		{cleanV(), time.Minute}, {blockedV(), 30 * time.Minute}, {cleanV(), time.Minute}, {shutdownV(), 10 * time.Minute},
	}
	run := func() (float64, bool) {
		w := mustWeight(t, DefaultParams())
		at := tBase
		for _, s := range steps {
			at = at.Add(s.dt)
			if err := w.Observe(s.v, at); err != nil {
				t.Fatalf("observe: %v", err)
			}
		}
		return w.Value(at), w.Promoted()
	}
	v1, p1 := run()
	v2, p2 := run()
	if v1 != v2 || p1 != p2 {
		t.Fatalf("non-deterministic: (%v,%v) vs (%v,%v)", v1, p1, v2, p2)
	}
}

// TestStaleEviction: a freshly-updated weight is not stale; once it has gone unobserved past the
// decay TTL it reports stale (an eviction hint for a registry, distinct from score evaporation).
func TestStaleEviction(t *testing.T) {
	p := DefaultParams()
	w := mustWeight(t, p)
	if w.Stale(tBase.Add(time.Minute)) {
		t.Fatal("a just-created weight must not be stale")
	}
	if w.Stale(tBase.Add(p.Decay.TTL)) {
		t.Fatal("at exactly the TTL the weight is not yet stale")
	}
	if !w.Stale(tBase.Add(p.Decay.TTL + time.Second)) {
		t.Fatal("past the TTL the weight must report stale")
	}
}

func throttledV() spec.Verdict {
	return verdict(spec.ConnStateThrottled, spec.ReasonThroughputCollapse)
}

// TestOutOfOrderObserveDoesNotRewind: a stale-stamped (earlier) verdict reinforces without
// evaporating and must NOT rewind the clock — so it can only HELP, never make the next in-order
// verdict over-evaporate. The sequence with an extra stale clean must not end below the monotone one.
func TestOutOfOrderObserveDoesNotRewind(t *testing.T) {
	run := func(withStale bool) float64 {
		w := mustWeight(t, DefaultParams())
		if err := w.Observe(cleanV(), tBase.Add(30*time.Minute)); err != nil {
			t.Fatalf("observe: %v", err)
		}
		if withStale {
			if err := w.Observe(cleanV(), tBase.Add(time.Minute)); err != nil { // stale, earlier than the last
				t.Fatalf("observe: %v", err)
			}
		}
		if err := w.Observe(cleanV(), tBase.Add(31*time.Minute)); err != nil {
			t.Fatalf("observe: %v", err)
		}
		return w.Value(tBase.Add(31 * time.Minute))
	}
	monotone := run(false)
	withStale := run(true)
	if withStale < monotone-1e-12 {
		t.Fatalf("a stale verdict over-evaporated the next update (clock rewound): withStale=%v < monotone=%v", withStale, monotone)
	}
}

// TestAccessors locks the node-local path-identity accessors (mirrors detect_test.go's State cover).
func TestAccessors(t *testing.T) {
	w := mustWeight(t, DefaultParams())
	if w.Class() != spec.TransportClassRealityTCP || w.TransportRef() != "tx-1" {
		t.Fatalf("accessors: got (%q,%q)", w.Class(), w.TransportRef())
	}
}

// TestGoodnessFailsTowardFloor documents that an unknown state earns no reinforcement (so a refactor
// of the switch cannot silently turn an unrecognised verdict into reinforcement).
func TestGoodnessFailsTowardFloor(t *testing.T) {
	if goodness(spec.ConnStateUnknown) != 0 || goodness(spec.ConnStateBlocked) != 0 || goodness(spec.ConnStateShutdown) != 0 {
		t.Fatal("unknown/blocked/shutdown must earn zero reinforcement")
	}
	if goodness(spec.ConnStateClean) != 1.0 || goodness(spec.ConnStateThrottled) != 0.5 {
		t.Fatal("clean/throttled goodness mapping drifted")
	}
}

// TestReinforceZeroOnlyDecays: with Reinforce=0 even clean verdicts never raise the weight, and a
// sub-band seed never promotes.
func TestReinforceZeroOnlyDecays(t *testing.T) {
	p := DefaultParams()
	p.Reinforce = 0
	w := mustWeight(t, p) // Initial 0.5, seed un-promoted (0.5 < hi 0.55)
	prev := w.Value(tBase)
	at := tBase
	for i := 0; i < 4; i++ {
		at = at.Add(time.Minute)
		if err := w.Observe(cleanV(), at); err != nil {
			t.Fatalf("observe: %v", err)
		}
		if v := w.Value(at); v > prev+1e-12 {
			t.Fatalf("Reinforce=0 must never raise the weight: %v > %v", v, prev)
		}
		prev = w.Value(at)
	}
	if w.Promoted() {
		t.Fatal("Reinforce=0 from a sub-band seed must never promote")
	}
}

// TestGoodnessOrdersEquilibria: sustained clean > sustained throttled > sustained blocked at steady
// state — the goodness(0.5) throttled branch settles strictly between the clean ceiling and the
// blocked floor.
func TestGoodnessOrdersEquilibria(t *testing.T) {
	settle := func(mk func() spec.Verdict) float64 {
		w := mustWeight(t, DefaultParams())
		at := tBase
		for i := 0; i < 40; i++ {
			at = at.Add(time.Minute)
			if err := w.Observe(mk(), at); err != nil {
				t.Fatalf("observe: %v", err)
			}
		}
		return w.Value(at)
	}
	clean, throttled, blocked := settle(cleanV), settle(throttledV), settle(blockedV)
	if !(blocked < throttled && throttled < clean) {
		t.Fatalf("equilibria not ordered blocked<throttled<clean: %v / %v / %v", blocked, throttled, clean)
	}
}

// TestSeedMidBandUnpromoted: a cold path seeded inside the hysteresis band starts un-promoted (it
// must earn the high edge), matching the steady-state promote rule.
func TestSeedMidBandUnpromoted(t *testing.T) {
	p := DefaultParams() // threshold 0.5, hi-edge 0.55, Initial 0.5 (in-band)
	w := mustWeight(t, p)
	if w.Promoted() {
		t.Fatal("a mid-band seed must start un-promoted (earn the high edge)")
	}
}

func TestObserveValidates(t *testing.T) {
	w := mustWeight(t, DefaultParams())
	// invalid verdict (impaired state with ReasonNone violates the cross-field contract)
	if err := w.Observe(spec.Verdict{State: spec.ConnStateBlocked, Reason: spec.ReasonNone, Class: spec.TransportClassRealityTCP, TransportRef: "tx-1", DecidedAt: tBase}, tBase.Add(time.Minute)); err == nil {
		t.Fatal("Observe must reject an invalid verdict")
	}
	// class mismatch
	mismatch := verdict(spec.ConnStateClean, spec.ReasonNone)
	mismatch.Class = spec.TransportClassAmneziaWGUDP
	if err := w.Observe(mismatch, tBase.Add(time.Minute)); err == nil {
		t.Fatal("Observe must reject a verdict for a different transport class")
	}
}
