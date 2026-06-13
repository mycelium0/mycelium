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

// goodScope is a minimal valid TrustScope reused across the table tests.
func goodScope() TrustScope {
	return TrustScope{ID: "scope-a", Label: "local", MaxHops: 1}
}

func TestEnumIsValid(t *testing.T) {
	if SignalSpeedUnknown.IsValid() || !SignalSpeedFast.IsValid() || !SignalSpeedHard.IsValid() {
		t.Fatal("SignalSpeedClass.IsValid mismatch")
	}
	if GradientKindUnknown.IsValid() || !GradientKindSink.IsValid() || !GradientKindSource.IsValid() {
		t.Fatal("GradientKind.IsValid mismatch")
	}
	if EdgeLifecycleUnknown.IsValid() || !EdgeLifecycleCord.IsValid() || !EdgeLifecycleScarred.IsValid() {
		t.Fatal("EdgeLifecycle.IsValid mismatch")
	}
	if SporeTypeUnknown.IsValid() || !SporeTypeRevocation.IsValid() || !SporeTypeRouteCapsule.IsValid() {
		t.Fatal("SporeType.IsValid mismatch")
	}
	if NodeRoleUnknown.IsValid() || !NodeRoleCacheCustodian.IsValid() || !NodeRoleCordEndpoint.IsValid() {
		t.Fatal("NodeRole.IsValid mismatch")
	}
}

func TestTrustScopeValidate(t *testing.T) {
	cases := []struct {
		name    string
		scope   TrustScope
		wantErr error
	}{
		{"ok", goodScope(), nil},
		{"empty id", TrustScope{ID: "", MaxHops: 0}, ErrEmptyField},
		{"negative hops", TrustScope{ID: "s", MaxHops: -1}, nil}, // distinct (non-sentinel) error
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.scope.Validate()
			if tc.name == "ok" && err != nil {
				t.Fatalf("want nil, got %v", err)
			}
			if tc.name != "ok" && err == nil {
				t.Fatal("want an error, got nil")
			}
			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Fatalf("want %v, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestTransportHealthRatioAndValidate(t *testing.T) {
	start := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	h := TransportHealth{
		TransportRef: "tx-1",
		Successes:    3,
		Failures:     1,
		WindowStart:  start,
		WindowEnd:    start.Add(time.Minute),
	}
	if err := h.Validate(); err != nil {
		t.Fatalf("valid transport health errored: %v", err)
	}
	if got := h.SuccessRatio(); got != 0.75 {
		t.Fatalf("SuccessRatio = %v, want 0.75", got)
	}
	empty := TransportHealth{TransportRef: "tx-2", WindowStart: start, WindowEnd: start}
	if got := empty.SuccessRatio(); got != 0 {
		t.Fatalf("empty SuccessRatio = %v, want 0", got)
	}
	bad := h
	bad.TransportRef = ""
	if err := bad.Validate(); !errors.Is(err, ErrEmptyField) {
		t.Fatalf("want ErrEmptyField, got %v", err)
	}
	badWin := h
	badWin.WindowEnd = start.Add(-time.Minute)
	if err := badWin.Validate(); err == nil {
		t.Fatal("want a window-order error, got nil")
	}
}

func goodDecay() DecayPolicy {
	return DecayPolicy{
		TTL:            time.Hour,
		HalfLife:       30 * time.Minute,
		Hysteresis:     0.1,
		RetentionFloor: 0.05,
	}
}

func TestDecayPolicyValidate(t *testing.T) {
	okDecay := goodDecay()
	if err := okDecay.Validate(); err != nil {
		t.Fatalf("valid decay policy errored: %v", err)
	}
	cases := []struct {
		name   string
		mutate func(d *DecayPolicy)
		want   error
	}{
		{"zero ttl", func(d *DecayPolicy) { d.TTL = 0 }, nil},
		{"zero half life", func(d *DecayPolicy) { d.HalfLife = 0 }, nil},
		{"hysteresis high", func(d *DecayPolicy) { d.Hysteresis = 2 }, ErrOutOfRange},
		{"floor negative", func(d *DecayPolicy) { d.RetentionFloor = -1 }, ErrOutOfRange},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := goodDecay()
			tc.mutate(&d)
			err := d.Validate()
			if err == nil {
				t.Fatal("want an error, got nil")
			}
			if tc.want != nil && !errors.Is(err, tc.want) {
				t.Fatalf("want %v, got %v", tc.want, err)
			}
		})
	}
}

func TestStressSignalValidateAndFloor(t *testing.T) {
	s := StressSignal{
		Scope:        goodScope(),
		ReasonCode:   "probe_timeout",
		SampleCount:  10,
		MinAggregate: 5,
		SpeedClass:   SignalSpeedMedium,
		ObservedAt:   time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC),
		Retention:    goodDecay(),
	}
	if err := s.Validate(); err != nil {
		t.Fatalf("valid stress signal errored: %v", err)
	}
	belowFloor := s
	belowFloor.SampleCount = 2
	if err := belowFloor.Validate(); !errors.Is(err, ErrAggregationFloor) {
		t.Fatalf("want ErrAggregationFloor, got %v", err)
	}
	wrongClass := s
	wrongClass.SpeedClass = SignalSpeedFast
	if err := wrongClass.Validate(); !errors.Is(err, ErrUnknownEnum) {
		t.Fatalf("want ErrUnknownEnum, got %v", err)
	}
	noReason := s
	noReason.ReasonCode = ""
	if err := noReason.Validate(); !errors.Is(err, ErrEmptyField) {
		t.Fatalf("want ErrEmptyField, got %v", err)
	}
}

func TestStressSignalJSONRoundTrip(t *testing.T) {
	s := StressSignal{
		Scope:        goodScope(),
		ReasonCode:   "probe_timeout",
		SampleCount:  10,
		MinAggregate: 5,
		SpeedClass:   SignalSpeedMedium,
		ObservedAt:   time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC),
		Retention:    goodDecay(),
	}
	data, err := json.Marshal(&s)
	if err != nil {
		t.Fatal(err)
	}
	var got StressSignal
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatalf("round-tripped stress signal invalid: %v", err)
	}
	// The DecayPolicy time.Duration fields marshal as int64 nanoseconds (the
	// ttl_ns / half_life_ns tags) and must round-trip exactly.
	if got.SpeedClass != SignalSpeedMedium || got.Scope.ID != "scope-a" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.Retention.TTL != time.Hour || got.Retention.HalfLife != 30*time.Minute {
		t.Fatalf("decay duration round-trip mismatch: %+v", got.Retention)
	}
}

func TestGradientSignalValidate(t *testing.T) {
	g := GradientSignal{
		Kind:       GradientKindSink,
		Scope:      goodScope(),
		Magnitude:  0.5,
		MeasuredAt: time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC),
	}
	if err := g.Validate(); err != nil {
		t.Fatalf("valid gradient errored: %v", err)
	}
	badKind := g
	badKind.Kind = GradientKindUnknown
	if err := badKind.Validate(); !errors.Is(err, ErrUnknownEnum) {
		t.Fatalf("want ErrUnknownEnum, got %v", err)
	}
	badMag := g
	badMag.Magnitude = 1.5
	if err := badMag.Validate(); !errors.Is(err, ErrOutOfRange) {
		t.Fatalf("want ErrOutOfRange, got %v", err)
	}
}

func goodEdge() EdgeState {
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	return EdgeState{
		Version:     NetworkStateVersion,
		FromRef:     "ep-a",
		ToRef:       "ep-b",
		Lifecycle:   EdgeLifecycleActive,
		Reliability: 0.9,
		LatencyMS:   42,
		Scope:       goodScope(),
		UpdatedAt:   now,
		ExpiresAt:   now.Add(time.Hour),
	}
}

func TestEdgeStateValidate(t *testing.T) {
	okEdge := goodEdge()
	if err := okEdge.Validate(); err != nil {
		t.Fatalf("valid edge errored: %v", err)
	}
	cases := []struct {
		name   string
		mutate func(e *EdgeState)
		want   error
	}{
		{"bad version", func(e *EdgeState) { e.Version = 99 }, nil},
		{"bad lifecycle", func(e *EdgeState) { e.Lifecycle = EdgeLifecycleUnknown }, ErrUnknownEnum},
		{"empty from", func(e *EdgeState) { e.FromRef = "" }, ErrEmptyField},
		{"reliability high", func(e *EdgeState) { e.Reliability = 2 }, ErrOutOfRange},
		{"expired ttl", func(e *EdgeState) { e.ExpiresAt = e.UpdatedAt }, ErrBadTTL},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := goodEdge()
			tc.mutate(&e)
			err := e.Validate()
			if err == nil {
				t.Fatal("want an error, got nil")
			}
			if tc.want != nil && !errors.Is(err, tc.want) {
				t.Fatalf("want %v, got %v", tc.want, err)
			}
		})
	}
}

func TestEdgeStateJSONRoundTrip(t *testing.T) {
	e := goodEdge()
	data, err := json.MarshalIndent(&e, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	var got EdgeState
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatalf("round-tripped edge invalid: %v", err)
	}
	if got.Lifecycle != EdgeLifecycleActive || got.FromRef != "ep-a" || got.Scope.ID != "scope-a" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

func TestTopologyFragmentValidateAndScopeMatch(t *testing.T) {
	f := NewTopologyFragment(goodScope())
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	f.IssuedAt = now
	f.ExpiresAt = now.Add(time.Hour)
	f.Edges = append(f.Edges, goodEdge())
	if err := f.Validate(); err != nil {
		t.Fatalf("valid fragment errored: %v", err)
	}
	// An edge in a different scope must be rejected (no scope mixing).
	mixed := goodEdge()
	mixed.Scope = TrustScope{ID: "scope-other", MaxHops: 1}
	f.Edges = append(f.Edges, mixed)
	if err := f.Validate(); err == nil {
		t.Fatal("want a scope-mismatch error, got nil")
	}
}

func TestTopologyFragmentJSONRoundTrip(t *testing.T) {
	f := NewTopologyFragment(goodScope())
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	f.IssuedAt = now
	f.ExpiresAt = now.Add(time.Hour)
	f.Edges = append(f.Edges, goodEdge())
	data, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	var got TopologyFragment
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Version != NetworkStateVersion || len(got.Edges) != 1 || got.Scope.ID != "scope-a" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

func goodSpore() SporeEnvelope {
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	return SporeEnvelope{
		Version:     NetworkStateVersion,
		Type:        SporeTypeBootstrap,
		Scope:       goodScope(),
		Payload:     []byte("opaque"),
		IssuedAt:    now,
		ExpiresAt:   now.Add(time.Hour),
		SignerKeyID: "key-1",
		Signature:   []byte{0x01, 0x02, 0x03},
	}
}

func TestSporeEnvelopeValidate(t *testing.T) {
	okSpore := goodSpore()
	if err := okSpore.Validate(); err != nil {
		t.Fatalf("valid spore errored: %v", err)
	}
	cases := []struct {
		name   string
		mutate func(s *SporeEnvelope)
		want   error
	}{
		{"bad type", func(s *SporeEnvelope) { s.Type = SporeTypeUnknown }, ErrUnknownEnum},
		{"empty payload", func(s *SporeEnvelope) { s.Payload = nil }, ErrEmptyField},
		{"no signer", func(s *SporeEnvelope) { s.SignerKeyID = "" }, ErrEmptyField},
		{"no signature", func(s *SporeEnvelope) { s.Signature = nil }, ErrEmptyField},
		{"expired ttl", func(s *SporeEnvelope) { s.ExpiresAt = s.IssuedAt }, ErrBadTTL},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := goodSpore()
			tc.mutate(&s)
			err := s.Validate()
			if err == nil {
				t.Fatal("want an error, got nil")
			}
			if tc.want != nil && !errors.Is(err, tc.want) {
				t.Fatalf("want %v, got %v", tc.want, err)
			}
		})
	}
}

func TestSporeEnvelopeJSONRoundTrip(t *testing.T) {
	s := goodSpore()
	data, err := json.Marshal(&s)
	if err != nil {
		t.Fatal(err)
	}
	var got SporeEnvelope
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatalf("round-tripped spore invalid: %v", err)
	}
	if got.Type != SporeTypeBootstrap || got.SignerKeyID != "key-1" || len(got.Signature) != 3 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

func TestCordPromotionPhaseInvariants(t *testing.T) {
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	c := CordPromotion{
		Version:     NetworkStateVersion,
		CordID:      "cord-1",
		PathRefs:    []string{"ep-a", "ep-b"},
		Scope:       goodScope(),
		Usefulness:  0.8,
		DemoteBelow: 0.3,
		Reversible:  true,
		Autonomous:  false,
		PromotedAt:  now,
	}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid cord promotion errored: %v", err)
	}
	notReversible := c
	notReversible.Reversible = false
	if err := notReversible.Validate(); err == nil {
		t.Fatal("want a reversibility error in Phase 0-2, got nil")
	}
	autonomous := c
	autonomous.Autonomous = true
	if err := autonomous.Validate(); err == nil {
		t.Fatal("want an autonomy error in Phase 0-2, got nil")
	}
	noPath := c
	noPath.PathRefs = nil
	if err := noPath.Validate(); !errors.Is(err, ErrEmptyField) {
		t.Fatalf("want ErrEmptyField, got %v", err)
	}
}

func TestCordPromotionJSONRoundTrip(t *testing.T) {
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	c := CordPromotion{
		Version:     NetworkStateVersion,
		CordID:      "cord-1",
		PathRefs:    []string{"ep-a"},
		Scope:       goodScope(),
		Usefulness:  0.8,
		DemoteBelow: 0.3,
		Reversible:  true,
		Autonomous:  false,
		PromotedAt:  now,
	}
	data, err := json.Marshal(&c)
	if err != nil {
		t.Fatal(err)
	}
	var got CordPromotion
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil {
		t.Fatalf("round-tripped cord invalid: %v", err)
	}
	if got.CordID != "cord-1" || got.Reversible != true || got.Autonomous != false {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}
