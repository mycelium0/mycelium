// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package detect is the Phase-2 connectivity-state classifier (RP-0010 Plane 2, the ADR-0031
// BUILD). It maps the node-local spec.DetectorSignal — assembled from the WRAP'd internal/reach
// measurements plus the probe-layer by-product flags — to a spec.Verdict (a closed ConnState +
// DetectReason). It is the DETECT plane only: it classifies, it never probes, rotates, actuates,
// or transmits anything. By construction it imports only internal/spec and pure stdlib, so
// detection adds NO new probing surface (RP-0010 AC-6); the detector_pure_no_probe conformance gate
// enforces that. The fine state it produces is node-local and never transmitted — only its lossy
// spec.ConnState.AdvisoryHealth() projection is emittable (ADR-0030).
//
// Two layers:
//   - Classify is the PURE, stateless single-observation core: it reads the unambiguous probe
//     signatures and returns the (state, reason) they indicate, with no memory.
//   - Detector adds the fast-class success-ratio hysteresis dead-zone (route-flap damping) and an
//     anti-flap confirmation count over a stream of observations, so a transient blip does not move
//     the verdict. Decisions are deterministic: the same observation stream yields the same verdicts
//     (RP-0010 AC-2).
package detect

import (
	"fmt"

	"github.com/mycelium0/mycelium/internal/spec"
)

// Thresholds parameterises the classifier. Every numeric parameter is named and configurable
// (development.md §2.2) — no magic constants buried in the logic.
type Thresholds struct {
	// CleanRatio is the fast-class success ratio at/above which a channel with no fresh fault
	// signature is confirmed clean.
	CleanRatio float64
	// DegradedRatio is the success ratio at/below which a channel with no fresh fault signature is
	// classified as aggregate-degraded. The open band (DegradedRatio, CleanRatio) is the hysteresis
	// dead-zone: within it the established state is held, damping flapping.
	DegradedRatio float64
	// MinSamples is the minimum window observation count before a ratio-based verdict is trusted;
	// below it the ratio is not yet evidence and the established state is held.
	MinSamples int
	// FlipConfirmations is the number of consecutive consistent observations required to move an
	// already-established state to a new one (1 = flip immediately; the default damps single blips).
	FlipConfirmations int
}

// DefaultThresholds returns the documented Phase-2 defaults: clean at >=80% success, aggregate-
// degraded at <=50%, a 4-sample floor, and a 2-observation anti-flap confirmation.
func DefaultThresholds() Thresholds {
	return Thresholds{CleanRatio: 0.8, DegradedRatio: 0.5, MinSamples: 4, FlipConfirmations: 2}
}

// Validate checks the thresholds are internally consistent: both ratios in [0,1] (the !(>=0 && <=1)
// form also rejects NaN/Inf) with DegradedRatio <= CleanRatio, a positive sample floor, and at
// least one confirmation. Pure.
func (t Thresholds) Validate() error {
	if !(t.CleanRatio >= 0 && t.CleanRatio <= 1) {
		return fmt.Errorf("thresholds: clean_ratio %v not in [0,1]", t.CleanRatio)
	}
	if !(t.DegradedRatio >= 0 && t.DegradedRatio <= 1) {
		return fmt.Errorf("thresholds: degraded_ratio %v not in [0,1]", t.DegradedRatio)
	}
	if t.DegradedRatio > t.CleanRatio {
		return fmt.Errorf("thresholds: degraded_ratio %v must be <= clean_ratio %v", t.DegradedRatio, t.CleanRatio)
	}
	if t.MinSamples < 1 {
		return fmt.Errorf("thresholds: min_samples must be >= 1, got %d", t.MinSamples)
	}
	if t.FlipConfirmations < 1 {
		return fmt.Errorf("thresholds: flip_confirmations must be >= 1, got %d", t.FlipConfirmations)
	}
	return nil
}

// Classify is the pure, stateless single-observation classifier. It reads the unambiguous probe
// signatures in priority order — total loss first, then handshake-layer interference, then
// post-connect degradation — and returns the (state, reason) they indicate. A signal with no fault
// signature returns (clean, none); the fast-class success-ratio dimension is applied by Detector,
// not here. Same input, same output, no side effects.
func Classify(sig spec.DetectorSignal) (spec.ConnState, spec.DetectReason) {
	switch {
	case !sig.ConnectOK:
		// No transport-layer connection at all — black-hole / total loss.
		return spec.ConnStateShutdown, spec.ReasonUnreachable
	case !sig.HandshakeOK:
		// The socket opened but the channel handshake did not establish.
		if sig.ConnectReset {
			return spec.ConnStateBlocked, spec.ReasonConnectionReset
		}
		return spec.ConnStateBlocked, spec.ReasonHandshakeTimeout
	case !sig.ActiveProbeOK:
		// Handshake completed but the cover/own-cert probe was wrong — the path interferes with the
		// shape even though the user handshake passed.
		return spec.ConnStateBlocked, spec.ReasonActiveProbeFailure
	case sig.PostConnectCollapse:
		// Throughput collapsed after a successful connect — the destination-AS "data dies" signature.
		return spec.ConnStateThrottled, spec.ReasonThroughputCollapse
	case sig.SingleStreamDegraded:
		// A single-stream shape degraded while a multiplexed shape on the same node did not. This is
		// a pre-computed comparative by-product supplied by the reach->signal wiring (a later chunk),
		// not a comparison the classifier performs here.
		return spec.ConnStateThrottled, spec.ReasonSingleStreamDegradation
	default:
		return spec.ConnStateClean, spec.ReasonNone
	}
}

// Detector tracks the classification state of ONE transport path and applies hysteresis over a
// stream of observations. It is NOT safe for concurrent use; a caller serialises Observe per path
// (one Detector per (class, transportRef)). It holds no I/O and starts no goroutines.
type Detector struct {
	class        spec.TransportClass
	transportRef string
	th           Thresholds

	state  spec.ConnState // current accepted state (ConnStateUnknown until the first verdict)
	reason spec.DetectReason

	pending      spec.ConnState // a candidate differing from state, not yet confirmed
	pendingCount int            // consecutive observations supporting pending
}

// New returns a Detector for one transport path. It is fail-closed (cf. reach.New): it refuses an
// unknown transport class, an empty transport reference, or thresholds that do not pass
// Thresholds.Validate, rather than silently trusting the caller.
func New(class spec.TransportClass, transportRef string, th Thresholds) (*Detector, error) {
	if !class.IsValid() {
		return nil, fmt.Errorf("detect: refusing to build detector: %w: class %q", spec.ErrUnknownEnum, class)
	}
	if transportRef == "" {
		return nil, fmt.Errorf("detect: refusing to build detector: %w: transport_ref", spec.ErrEmptyField)
	}
	if err := th.Validate(); err != nil {
		return nil, fmt.Errorf("detect: refusing to build detector: %w", err)
	}
	return &Detector{
		class:        class,
		transportRef: transportRef,
		th:           th,
		state:        spec.ConnStateUnknown,
		reason:       spec.ReasonUnknown,
		pending:      spec.ConnStateUnknown,
	}, nil
}

// State returns the detector's current accepted ConnState (ConnStateUnknown before the first
// observation).
func (d *Detector) State() spec.ConnState { return d.state }

// Observe folds one signal into the detector and returns the current Verdict. The signal is
// validated first. When the latest probe shows no fresh fault signature, the fast-class success
// ratio decides: at/above CleanRatio it confirms clean, at/below DegradedRatio it is aggregate-
// degraded, and otherwise (a dead-zone ratio, or too few samples to trust it) the established state
// is held to damp flapping — but a state that was attributed to a now-cleared boolean fault is
// never LATCHED: it is capped at aggregate degradation so the path can climb back out. A change
// away from an already-established state then requires FlipConfirmations consecutive consistent
// candidates; the first-ever verdict is accepted immediately. Deterministic: the same stream yields
// the same verdicts.
func (d *Detector) Observe(sig spec.DetectorSignal) (spec.Verdict, error) {
	if err := sig.Validate(); err != nil {
		return spec.Verdict{}, fmt.Errorf("detector observe: %w", err)
	}

	cand, candReason := Classify(sig)

	if cand == spec.ConnStateClean {
		total := sig.Health.Successes + sig.Health.Failures
		r := sig.Health.SuccessRatio()
		switch {
		case total >= d.th.MinSamples && r >= d.th.CleanRatio:
			cand, candReason = spec.ConnStateClean, spec.ReasonNone
		case total >= d.th.MinSamples && r <= d.th.DegradedRatio:
			cand, candReason = spec.ConnStateThrottled, spec.ReasonDegradedWindow
		default:
			// Weak evidence: a dead-zone ratio or too few samples. Hold the established state to damp
			// flapping, but cap a held impaired state at aggregate degradation — never re-latch a
			// boolean-fault state (blocked/shutdown) whose fault flag has already cleared.
			switch d.state {
			case spec.ConnStateUnknown, spec.ConnStateClean:
				cand, candReason = spec.ConnStateClean, spec.ReasonNone
			default:
				cand, candReason = spec.ConnStateThrottled, spec.ReasonDegradedWindow
			}
		}
	}

	switch {
	case cand == d.state:
		// Same state: refresh the (possibly shifted) dominant reason, clear any pending flip.
		d.reason = candReason
		d.pending, d.pendingCount = spec.ConnStateUnknown, 0
	case d.state == spec.ConnStateUnknown:
		// First-ever verdict: accept immediately, no hysteresis to apply.
		d.state, d.reason = cand, candReason
		d.pending, d.pendingCount = spec.ConnStateUnknown, 0
	default:
		// A change from an established state: require FlipConfirmations consecutive candidates.
		if cand == d.pending {
			d.pendingCount++
		} else {
			d.pending, d.pendingCount = cand, 1
		}
		if d.pendingCount >= d.th.FlipConfirmations {
			d.state, d.reason = cand, candReason
			d.pending, d.pendingCount = spec.ConnStateUnknown, 0
		}
	}

	v := spec.Verdict{
		State:        d.state,
		Reason:       d.reason,
		Class:        d.class,
		TransportRef: d.transportRef,
		DecidedAt:    sig.ObservedAt,
	}
	if err := v.Validate(); err != nil {
		// Defensive invariant: the classifier must only ever produce consistent (state,reason) pairs.
		return spec.Verdict{}, fmt.Errorf("detector: emitted invalid verdict: %w", err)
	}
	return v, nil
}
