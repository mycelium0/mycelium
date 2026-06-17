// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

// NOTE on the wire boundary: that no TRANSMITTED artifact type embeds ConnState
// or DetectReason is enforced structurally by the offline conformance gate
// tests/conformance/detector_state_closed_vocab.sh (it scans the spec sources).
// These Go tests cover the schema's own invariants and the lossy projection.

// goodHealth is a minimal valid TransportHealth window reused across the tests.
func goodHealth() TransportHealth {
	start := time.Date(2026, 6, 17, 10, 0, 0, 0, time.UTC)
	return TransportHealth{
		TransportRef: "tx-1",
		Successes:    8,
		Failures:     2,
		WindowStart:  start,
		WindowEnd:    start.Add(time.Minute),
	}
}

func TestConnStateIsValid(t *testing.T) {
	if ConnStateUnknown.IsValid() {
		t.Fatal("ConnStateUnknown must not be valid")
	}
	for _, s := range []ConnState{ConnStateClean, ConnStateThrottled, ConnStateBlocked, ConnStateShutdown} {
		if !s.IsValid() {
			t.Fatalf("ConnState %q must be valid", s)
		}
	}
	if ConnState("garbage").IsValid() {
		t.Fatal("an unknown ConnState string must not be valid")
	}
}

func TestDetectReasonIsValid(t *testing.T) {
	if ReasonUnknown.IsValid() {
		t.Fatal("ReasonUnknown must not be valid")
	}
	// ReasonNone IS valid — it is the explicit clean-channel cause.
	for _, r := range []DetectReason{
		ReasonNone, ReasonHandshakeTimeout, ReasonConnectionReset,
		ReasonThroughputCollapse, ReasonActiveProbeFailure,
		ReasonSingleStreamDegradation, ReasonUnreachable,
	} {
		if !r.IsValid() {
			t.Fatalf("DetectReason %q must be valid", r)
		}
	}
	if DetectReason("garbage").IsValid() {
		t.Fatal("an unknown DetectReason string must not be valid")
	}
}

// TestAdvisoryHealthIsLossy is the OPSEC-critical test: the projection must
// collapse EVERY impaired state to the single advisory value HealthDegraded, so
// the externalisable advisory cannot reveal which interference class succeeded.
// clean -> alive; unknown -> unknown.
func TestAdvisoryHealthIsLossy(t *testing.T) {
	cases := []struct {
		state ConnState
		want  HealthValue
	}{
		{ConnStateClean, HealthAlive},
		{ConnStateThrottled, HealthDegraded},
		{ConnStateBlocked, HealthDegraded},
		{ConnStateShutdown, HealthDegraded},
		{ConnStateUnknown, HealthUnknown},
		{ConnState("garbage"), HealthUnknown},
	}
	for _, tc := range cases {
		t.Run(string(tc.state), func(t *testing.T) {
			if got := tc.state.AdvisoryHealth(); got != tc.want {
				t.Fatalf("AdvisoryHealth(%q) = %q, want %q", tc.state, got, tc.want)
			}
		})
	}
	// The three impaired states must be INDISTINGUISHABLE after projection.
	for _, s := range []ConnState{ConnStateThrottled, ConnStateBlocked, ConnStateShutdown} {
		if s.AdvisoryHealth() != HealthDegraded {
			t.Fatalf("impaired state %q must project to HealthDegraded (privacy contract)", s)
		}
	}
	// Every projection result must itself be a valid advisory health value.
	for _, tc := range cases {
		if !tc.state.AdvisoryHealth().IsValid() {
			t.Fatalf("AdvisoryHealth(%q) produced a non-canonical HealthValue", tc.state)
		}
	}
}

func TestDetectorSignalValidate(t *testing.T) {
	cases := []struct {
		name    string
		sig     DetectorSignal
		wantErr error // sentinel to match via errors.Is, or nil
		wantAny bool  // expect a non-nil, non-sentinel error
	}{
		{name: "ok", sig: DetectorSignal{Class: TransportClassRealityTCP, Health: goodHealth(), ConnectOK: true, HandshakeOK: true}},
		{name: "unknown class", sig: DetectorSignal{Class: TransportClassUnknown, Health: goodHealth()}, wantErr: ErrUnknownEnum},
		{name: "bad class", sig: DetectorSignal{Class: TransportClass("nope"), Health: goodHealth()}, wantErr: ErrUnknownEnum},
		{name: "empty transport ref", sig: DetectorSignal{Class: TransportClassRealityTCP, Health: TransportHealth{}}, wantErr: ErrEmptyField},
		{name: "handshake without connect", sig: DetectorSignal{Class: TransportClassRealityTCP, Health: goodHealth(), ConnectOK: false, HandshakeOK: true}, wantAny: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.sig.Validate()
			switch {
			case tc.wantAny:
				if err == nil {
					t.Fatal("want a non-nil error, got nil")
				}
			case tc.wantErr != nil:
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("want %v, got %v", tc.wantErr, err)
				}
			default:
				if err != nil {
					t.Fatalf("want nil, got %v", err)
				}
			}
		})
	}
}

func TestVerdictValidate(t *testing.T) {
	cls := TransportClassRealityTCP
	now := time.Date(2026, 6, 17, 10, 1, 0, 0, time.UTC)
	cases := []struct {
		name    string
		v       Verdict
		wantErr error // sentinel to match via errors.Is, or nil
		wantAny bool  // expect a non-nil, non-sentinel error (the cross-field contract)
	}{
		{name: "clean+none ok", v: Verdict{State: ConnStateClean, Reason: ReasonNone, Class: cls, TransportRef: "tx-1", DecidedAt: now}},
		{name: "throttled+collapse ok", v: Verdict{State: ConnStateThrottled, Reason: ReasonThroughputCollapse, Class: cls, TransportRef: "tx-1", DecidedAt: now}},
		{name: "blocked+reset ok", v: Verdict{State: ConnStateBlocked, Reason: ReasonConnectionReset, Class: cls, TransportRef: "tx-1", DecidedAt: now}},
		{name: "shutdown+unreachable ok", v: Verdict{State: ConnStateShutdown, Reason: ReasonUnreachable, Class: cls, TransportRef: "tx-1", DecidedAt: now}},
		{name: "unknown state rejected", v: Verdict{State: ConnStateUnknown, Reason: ReasonNone, Class: cls, TransportRef: "tx-1", DecidedAt: now}, wantErr: ErrUnknownEnum},
		{name: "unknown reason rejected", v: Verdict{State: ConnStateClean, Reason: ReasonUnknown, Class: cls, TransportRef: "tx-1", DecidedAt: now}, wantErr: ErrUnknownEnum},
		{name: "unknown class rejected", v: Verdict{State: ConnStateClean, Reason: ReasonNone, Class: TransportClassUnknown, TransportRef: "tx-1", DecidedAt: now}, wantErr: ErrUnknownEnum},
		{name: "empty transport_ref rejected", v: Verdict{State: ConnStateClean, Reason: ReasonNone, Class: cls, TransportRef: "", DecidedAt: now}, wantErr: ErrEmptyField},
		// Cross-field contract (valid enum members, contract violation -> non-sentinel error):
		{name: "clean with a cause rejected", v: Verdict{State: ConnStateClean, Reason: ReasonThroughputCollapse, Class: cls, TransportRef: "tx-1", DecidedAt: now}, wantAny: true},
		{name: "impaired with none rejected", v: Verdict{State: ConnStateBlocked, Reason: ReasonNone, Class: cls, TransportRef: "tx-1", DecidedAt: now}, wantAny: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.v.Validate()
			switch {
			case tc.wantAny:
				if err == nil {
					t.Fatal("want a cross-field contract error, got nil")
				}
			case tc.wantErr != nil:
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("want %v, got %v", tc.wantErr, err)
				}
			default:
				if err != nil {
					t.Fatalf("want nil, got %v", err)
				}
			}
		})
	}
}

// TestDetectorSignalJSONRoundTrip confirms the node-local signal survives a
// marshal/unmarshal intact (it is a normal serialisable record for node-local
// use, like TransportHealth — the wire boundary is the gate's job, not a missing
// json tag).
func TestDetectorSignalJSONRoundTrip(t *testing.T) {
	in := DetectorSignal{
		Class:               TransportClassRealityTCP,
		Health:              goodHealth(),
		ConnectOK:           true,
		HandshakeOK:         false,
		ConnectReset:        true,
		PostConnectCollapse: false,
		ObservedAt:          time.Date(2026, 6, 17, 10, 2, 0, 0, time.UTC),
	}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out DetectorSignal
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Class != in.Class || out.ConnectOK != in.ConnectOK || out.HandshakeOK != in.HandshakeOK ||
		out.ConnectReset != in.ConnectReset || out.Health.TransportRef != in.Health.TransportRef {
		t.Fatalf("round-trip mismatch: %+v vs %+v", out, in)
	}
}

// TestVerdictJSONRoundTrip confirms the verdict survives a marshal/unmarshal and
// re-validates. (Round-tripping a node-local record is fine; transmitting it is
// what the conformance gate forbids.)
func TestVerdictJSONRoundTrip(t *testing.T) {
	in := Verdict{
		State:        ConnStateThrottled,
		Reason:       ReasonThroughputCollapse,
		Class:        TransportClassRealityTCP,
		TransportRef: "tx-1",
		DecidedAt:    time.Date(2026, 6, 17, 10, 3, 0, 0, time.UTC),
	}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out Verdict
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.State != in.State || out.Reason != in.Reason || out.Class != in.Class || out.TransportRef != in.TransportRef {
		t.Fatalf("round-trip mismatch: %+v vs %+v", out, in)
	}
	if err := out.Validate(); err != nil {
		t.Fatalf("round-tripped verdict failed Validate: %v", err)
	}
}
