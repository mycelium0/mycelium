// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package detect

import (
	"math"
	"testing"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

var tBase = time.Date(2026, 6, 17, 12, 0, 0, 0, time.UTC)

// healthWin builds a valid TransportHealth window with the given success/failure counts.
func healthWin(succ, fail int) spec.TransportHealth {
	return spec.TransportHealth{
		TransportRef: "tx-1",
		Successes:    succ,
		Failures:     fail,
		WindowStart:  tBase,
		WindowEnd:    tBase.Add(time.Minute),
	}
}

// cleanSig is a fully-healthy observation (all probe signatures OK, a clean window). Cases mutate
// individual fields off this base.
func cleanSig() spec.DetectorSignal {
	return spec.DetectorSignal{
		Class:         spec.TransportClassRealityTCP,
		Health:        healthWin(9, 1), // ratio 0.9 >= CleanRatio
		ConnectOK:     true,
		HandshakeOK:   true,
		ActiveProbeOK: true,
		ObservedAt:    tBase.Add(time.Minute),
	}
}

func blockedTimeout() spec.DetectorSignal { s := cleanSig(); s.HandshakeOK = false; return s }
func collapseSig() spec.DetectorSignal    { s := cleanSig(); s.PostConnectCollapse = true; return s }

// mustNew builds a Detector, failing the test if the fail-closed constructor rejects the inputs.
func mustNew(t *testing.T, class spec.TransportClass, ref string, th Thresholds) *Detector {
	t.Helper()
	d, err := New(class, ref, th)
	if err != nil {
		t.Fatalf("New(%q,%q): %v", class, ref, err)
	}
	return d
}

func TestNewFailClosed(t *testing.T) {
	if _, err := New(spec.TransportClass("nope"), "tx-1", DefaultThresholds()); err == nil {
		t.Fatal("New must reject an unknown transport class")
	}
	if _, err := New(spec.TransportClassRealityTCP, "", DefaultThresholds()); err == nil {
		t.Fatal("New must reject an empty transport ref")
	}
	if _, err := New(spec.TransportClassRealityTCP, "tx-1", Thresholds{}); err == nil {
		t.Fatal("New must reject invalid thresholds (zero value)")
	}
}

func TestStateAccessor(t *testing.T) {
	d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	if d.State() != spec.ConnStateUnknown {
		t.Fatalf("fresh detector State() = %q, want unknown", d.State())
	}
	v, err := d.Observe(cleanSig())
	if err != nil {
		t.Fatalf("observe: %v", err)
	}
	if d.State() != v.State {
		t.Fatalf("State() %q != emitted verdict state %q", d.State(), v.State)
	}
}

func TestClassifySignaturePriority(t *testing.T) {
	cases := []struct {
		name       string
		mutate     func(*spec.DetectorSignal)
		wantState  spec.ConnState
		wantReason spec.DetectReason
	}{
		{"clean", func(s *spec.DetectorSignal) {}, spec.ConnStateClean, spec.ReasonNone},
		{"shutdown: no connect", func(s *spec.DetectorSignal) { s.ConnectOK, s.HandshakeOK = false, false }, spec.ConnStateShutdown, spec.ReasonUnreachable},
		{"blocked: reset", func(s *spec.DetectorSignal) { s.HandshakeOK, s.ConnectReset = false, true }, spec.ConnStateBlocked, spec.ReasonConnectionReset},
		{"blocked: timeout", func(s *spec.DetectorSignal) { s.HandshakeOK = false }, spec.ConnStateBlocked, spec.ReasonHandshakeTimeout},
		{"blocked: probe", func(s *spec.DetectorSignal) { s.ActiveProbeOK = false }, spec.ConnStateBlocked, spec.ReasonActiveProbeFailure},
		{"throttled: collapse", func(s *spec.DetectorSignal) { s.PostConnectCollapse = true }, spec.ConnStateThrottled, spec.ReasonThroughputCollapse},
		{"throttled: single-stream", func(s *spec.DetectorSignal) { s.SingleStreamDegraded = true }, spec.ConnStateThrottled, spec.ReasonSingleStreamDegradation},
		// Priority conflicts: the harder fault dominates regardless of softer flags.
		{"no-connect beats collapse", func(s *spec.DetectorSignal) { s.ConnectOK, s.HandshakeOK, s.PostConnectCollapse = false, false, true }, spec.ConnStateShutdown, spec.ReasonUnreachable},
		{"handshake-fault beats collapse", func(s *spec.DetectorSignal) { s.HandshakeOK, s.PostConnectCollapse = false, true }, spec.ConnStateBlocked, spec.ReasonHandshakeTimeout},
		{"probe-fault beats single-stream", func(s *spec.DetectorSignal) { s.ActiveProbeOK, s.SingleStreamDegraded = false, true }, spec.ConnStateBlocked, spec.ReasonActiveProbeFailure},
		{"collapse beats single-stream", func(s *spec.DetectorSignal) { s.PostConnectCollapse, s.SingleStreamDegraded = true, true }, spec.ConnStateThrottled, spec.ReasonThroughputCollapse},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := cleanSig()
			tc.mutate(&s)
			gotState, gotReason := Classify(s)
			if gotState != tc.wantState || gotReason != tc.wantReason {
				t.Fatalf("Classify = (%q,%q), want (%q,%q)", gotState, gotReason, tc.wantState, tc.wantReason)
			}
		})
	}
}

func TestThresholdsValidate(t *testing.T) {
	if err := DefaultThresholds().Validate(); err != nil {
		t.Fatalf("DefaultThresholds must validate: %v", err)
	}
	bad := []Thresholds{
		{CleanRatio: 1.2, DegradedRatio: 0.5, MinSamples: 4, FlipConfirmations: 2},        // ratio > 1
		{CleanRatio: 0.8, DegradedRatio: -0.1, MinSamples: 4, FlipConfirmations: 2},       // ratio < 0
		{CleanRatio: 0.4, DegradedRatio: 0.6, MinSamples: 4, FlipConfirmations: 2},        // degraded > clean
		{CleanRatio: 0.8, DegradedRatio: 0.5, MinSamples: 0, FlipConfirmations: 2},        // samples < 1
		{CleanRatio: 0.8, DegradedRatio: 0.5, MinSamples: 4, FlipConfirmations: 0},        // confirmations < 1
		{CleanRatio: math.NaN(), DegradedRatio: 0.5, MinSamples: 4, FlipConfirmations: 2}, // NaN ratio
	}
	for i, th := range bad {
		if err := th.Validate(); err == nil {
			t.Fatalf("bad thresholds[%d] must fail Validate", i)
		}
	}
}

// TestCorpusPrecisionRecall is the AC-2 measurability check: a labelled-incident corpus is run
// through a fresh Detector and scored with a confusion matrix + per-class precision/recall, and the
// dominant reason is asserted per case. The corpus is the behavioural spec — every labelled incident
// must be classified correctly, so any future logic drift drops accuracy below 1.0 and fails the
// test. (Inline for now; it can move to testdata/ and grow without code changes.)
func TestCorpusPrecisionRecall(t *testing.T) {
	type incident struct {
		name       string
		sig        spec.DetectorSignal
		wantState  spec.ConnState
		wantReason spec.DetectReason
	}
	with := func(mutate func(*spec.DetectorSignal), succ, fail int) spec.DetectorSignal {
		s := cleanSig()
		s.Health = healthWin(succ, fail)
		mutate(&s)
		return s
	}
	noop := func(s *spec.DetectorSignal) {}
	corpus := []incident{
		// Healthy: clean booleans + a healthy window.
		{"clean-strong", with(noop, 10, 0), spec.ConnStateClean, spec.ReasonNone},
		{"clean-ratio-0.9", with(noop, 9, 1), spec.ConnStateClean, spec.ReasonNone},
		// Aggregate degradation: clean booleans but a sustainedly poor window.
		{"degraded-window-0.3", with(noop, 3, 7), spec.ConnStateThrottled, spec.ReasonDegradedWindow},
		{"degraded-window-0.5-edge", with(noop, 5, 5), spec.ConnStateThrottled, spec.ReasonDegradedWindow},
		{"boundary-min-samples", with(noop, 2, 2), spec.ConnStateThrottled, spec.ReasonDegradedWindow}, // total==MinSamples, r=0.5
		// Dead-zone on a FRESH detector (no established state) defaults to clean.
		{"deadzone-fresh-0.65", with(noop, 13, 7), spec.ConnStateClean, spec.ReasonNone},
		// Below MinSamples: the ratio is not yet evidence — clean booleans stay clean even if the
		// few samples look bad.
		{"subfloor-one-success", with(noop, 1, 0), spec.ConnStateClean, spec.ReasonNone},
		{"subfloor-bad-but-too-few", with(noop, 0, 2), spec.ConnStateClean, spec.ReasonNone},
		// Hard signatures (the window is irrelevant once a fault flag is set).
		{"shutdown", with(func(s *spec.DetectorSignal) { s.ConnectOK, s.HandshakeOK = false, false }, 0, 10), spec.ConnStateShutdown, spec.ReasonUnreachable},
		{"blocked-reset", with(func(s *spec.DetectorSignal) { s.HandshakeOK, s.ConnectReset = false, true }, 2, 8), spec.ConnStateBlocked, spec.ReasonConnectionReset},
		{"blocked-timeout", with(func(s *spec.DetectorSignal) { s.HandshakeOK = false }, 2, 8), spec.ConnStateBlocked, spec.ReasonHandshakeTimeout},
		{"blocked-probe", with(func(s *spec.DetectorSignal) { s.ActiveProbeOK = false }, 8, 2), spec.ConnStateBlocked, spec.ReasonActiveProbeFailure},
		{"throttled-collapse", with(func(s *spec.DetectorSignal) { s.PostConnectCollapse = true }, 7, 3), spec.ConnStateThrottled, spec.ReasonThroughputCollapse},
		{"throttled-collapse-bad-window", with(func(s *spec.DetectorSignal) { s.PostConnectCollapse = true }, 3, 7), spec.ConnStateThrottled, spec.ReasonThroughputCollapse}, // fault wins over the ratio
		{"throttled-single-stream", with(func(s *spec.DetectorSignal) { s.SingleStreamDegraded = true }, 8, 2), spec.ConnStateThrottled, spec.ReasonSingleStreamDegradation},
		// A hard fault with a deceptively healthy window must still be caught.
		{"blocked-despite-good-window", with(func(s *spec.DetectorSignal) { s.HandshakeOK = false }, 10, 0), spec.ConnStateBlocked, spec.ReasonHandshakeTimeout},
	}

	states := []spec.ConnState{spec.ConnStateClean, spec.ConnStateThrottled, spec.ConnStateBlocked, spec.ConnStateShutdown}
	matrix := map[spec.ConnState]map[spec.ConnState]int{}
	for _, w := range states {
		matrix[w] = map[spec.ConnState]int{}
	}
	correct := 0
	for _, inc := range corpus {
		d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
		v, err := d.Observe(inc.sig)
		if err != nil {
			t.Fatalf("%s: Observe error: %v", inc.name, err)
		}
		matrix[inc.wantState][v.State]++
		if v.State == inc.wantState {
			correct++
		} else {
			t.Errorf("%s: state got %q, want %q", inc.name, v.State, inc.wantState)
		}
		if v.Reason != inc.wantReason {
			t.Errorf("%s: reason got %q, want %q", inc.name, v.Reason, inc.wantReason)
		}
	}
	acc := float64(correct) / float64(len(corpus))
	t.Logf("corpus: %d incidents, accuracy=%.3f", len(corpus), acc)
	for _, c := range states {
		tp := matrix[c][c]
		fp, fn := 0, 0
		for _, w := range states {
			if w != c {
				fp += matrix[w][c]
			}
		}
		for _, g := range states {
			if g != c {
				fn += matrix[c][g]
			}
		}
		prec, rec := 1.0, 1.0
		if tp+fp > 0 {
			prec = float64(tp) / float64(tp+fp)
		}
		if tp+fn > 0 {
			rec = float64(tp) / float64(tp+fn)
		}
		t.Logf("  class %-9s precision=%.2f recall=%.2f (tp=%d fp=%d fn=%d)", c, prec, rec, tp, fp, fn)
		if rec < 1.0 {
			t.Fatalf("class %q recall %.2f < 1.0 — the classifier missed a labelled incident", c, rec)
		}
	}
	if acc < 1.0 {
		t.Fatalf("corpus accuracy %.3f < 1.0 — the classifier disagrees with a labelled incident", acc)
	}
}

// streamStates feeds a sequence of signals into one Detector and returns the resulting states.
func streamStates(t *testing.T, d *Detector, steps []func() spec.DetectorSignal) []spec.ConnState {
	t.Helper()
	out := make([]spec.ConnState, 0, len(steps))
	for i, mk := range steps {
		v, err := d.Observe(mk())
		if err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
		out = append(out, v.State)
	}
	return out
}

func assertStates(t *testing.T, got, want []spec.ConnState) {
	t.Helper()
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("step %d: got %q, want %q (full: %v)", i, got[i], want[i], got)
		}
	}
}

// TestDetectorAntiFlap: with the default FlipConfirmations=2, a single blocked blip between clean
// observations must NOT move the verdict off clean; two consecutive blocked observations flip it.
func TestDetectorAntiFlap(t *testing.T) {
	d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	got := streamStates(t, d, []func() spec.DetectorSignal{
		cleanSig,       // -> clean (first verdict, immediate)
		blockedTimeout, // blip 1: pending blocked (count 1) -> hold clean
		cleanSig,       // recover -> clean, pending cleared
		blockedTimeout, // blip 1 again -> hold clean
		blockedTimeout, // blip 2 consecutive -> flip to blocked
	})
	assertStates(t, got, []spec.ConnState{
		spec.ConnStateClean, spec.ConnStateClean, spec.ConnStateClean, spec.ConnStateClean, spec.ConnStateBlocked,
	})
}

// TestDetectorCleanFlapDamping: a clean channel whose window dips into the dead-zone (between
// DegradedRatio and CleanRatio) is HELD clean (damping); only a clearly-degraded window (<=
// DegradedRatio), confirmed FlipConfirmations times, moves it to throttled.
func TestDetectorCleanFlapDamping(t *testing.T) {
	d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	deadZone := func() spec.DetectorSignal { s := cleanSig(); s.Health = healthWin(13, 7); return s } // 0.65
	degraded := func() spec.DetectorSignal { s := cleanSig(); s.Health = healthWin(3, 7); return s }  // 0.30
	got := streamStates(t, d, []func() spec.DetectorSignal{
		cleanSig, // establish clean
		deadZone, // dead-zone -> hold clean (damped)
		deadZone, // still clean
		degraded, // clearly degraded, pending throttled count 1 -> hold clean
		degraded, // count 2 -> flip to throttled
	})
	assertStates(t, got, []spec.ConnState{
		spec.ConnStateClean, spec.ConnStateClean, spec.ConnStateClean, spec.ConnStateClean, spec.ConnStateThrottled,
	})
}

// TestDetectorRecoversFromBooleanFault is the regression for the dead-zone latch bug: once a
// boolean-fault state (blocked) is established and the fault flag CLEARS, a dead-zone window must
// NOT pin it as blocked forever — it is capped at aggregate throttled and can climb back to clean as
// the window recovers.
func TestDetectorRecoversFromBooleanFault(t *testing.T) {
	d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	deadZone := func() spec.DetectorSignal { s := cleanSig(); s.Health = healthWin(13, 7); return s } // 0.65, booleans clean
	healthy := func() spec.DetectorSignal { s := cleanSig(); s.Health = healthWin(10, 0); return s }  // 1.0
	got := streamStates(t, d, []func() spec.DetectorSignal{
		blockedTimeout, // establish blocked (immediate)
		deadZone,       // fault cleared, dead-zone: candidate throttled, pending count 1 -> still blocked
		deadZone,       // count 2 -> flip to throttled (NOT latched blocked)
		healthy,        // recovery candidate clean, pending count 1 -> still throttled
		healthy,        // count 2 -> flip to clean
	})
	assertStates(t, got, []spec.ConnState{
		spec.ConnStateBlocked, spec.ConnStateBlocked, spec.ConnStateThrottled, spec.ConnStateThrottled, spec.ConnStateClean,
	})
	// The bug was a permanent blocked latch; assert we fully recovered.
	if d.State() != spec.ConnStateClean {
		t.Fatalf("after recovery State() = %q, want clean", d.State())
	}
}

// TestDetectorImpairedOscillationDoesNotThrash: alternating impaired signatures (never two
// consecutive of the same differing candidate) must not flip the established state (anti-flap).
func TestDetectorImpairedOscillationDoesNotThrash(t *testing.T) {
	d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	got := streamStates(t, d, []func() spec.DetectorSignal{
		blockedTimeout, // establish blocked
		collapseSig,    // throttled candidate, pending count 1
		blockedTimeout, // back to blocked (== state) -> pending cleared
		collapseSig,    // throttled candidate, pending count 1 again
		blockedTimeout, // back to blocked -> pending cleared
	})
	assertStates(t, got, []spec.ConnState{
		spec.ConnStateBlocked, spec.ConnStateBlocked, spec.ConnStateBlocked, spec.ConnStateBlocked, spec.ConnStateBlocked,
	})
}

// TestDetectorDeterministic: the same observation stream yields the same verdict stream (AC-2).
func TestDetectorDeterministic(t *testing.T) {
	steps := []func() spec.DetectorSignal{cleanSig, blockedTimeout, blockedTimeout, cleanSig, cleanSig}
	d1 := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	d2 := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	a := streamStates(t, d1, steps)
	b := streamStates(t, d2, steps)
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("non-deterministic at step %d: %q vs %q", i, a[i], b[i])
		}
	}
}

// TestObserveValidatesSignalAndVerdict: an invalid signal is rejected, and every verdict the
// detector emits validates across the reachable {state,reason} set (Observe enforces this).
func TestObserveValidatesSignalAndVerdict(t *testing.T) {
	d := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	bad := cleanSig()
	bad.Class = spec.TransportClass("nope")
	if _, err := d.Observe(bad); err == nil {
		t.Fatal("Observe must reject an invalid signal")
	}
	degraded := func() spec.DetectorSignal { s := cleanSig(); s.Health = healthWin(3, 7); return s }
	shutdown := func() spec.DetectorSignal { s := cleanSig(); s.ConnectOK, s.HandshakeOK = false, false; return s }
	d2 := mustNew(t, spec.TransportClassRealityTCP, "tx-1", DefaultThresholds())
	for _, mk := range []func() spec.DetectorSignal{cleanSig, blockedTimeout, blockedTimeout, collapseSig, degraded, degraded, shutdown, shutdown} {
		v, err := d2.Observe(mk())
		if err != nil {
			t.Fatalf("observe: %v", err)
		}
		if err := v.Validate(); err != nil {
			t.Fatalf("emitted verdict failed Validate: %v (%+v)", err, v)
		}
	}
}
