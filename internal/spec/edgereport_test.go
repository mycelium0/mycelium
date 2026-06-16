// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"errors"
	"testing"
	"time"
)

// goodEdgeReport is a minimal valid EdgeReport reused across the table tests.
func goodEdgeReport() EdgeReport {
	return EdgeReport{
		Version:        NetworkStateVersion,
		RegionBucket:   "bucket-a",
		TransportClass: TransportClassRealityTCP,
		Reachable:      7,
		Unreachable:    3,
		SampleCount:    10,
		MinAggregate:   5,
		SpeedClass:     SignalSpeedMedium,
		ObservedAt:     time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC),
		Retention:      goodDecay(),
	}
}

func TestTransportClassIsValid(t *testing.T) {
	if TransportClassUnknown.IsValid() {
		t.Fatal("zero value must not be valid")
	}
	for _, c := range []TransportClass{
		TransportClassRealityTCP, TransportClassQUICUDP, TransportClassShadowsocksTCP,
		TransportClassShadowTLSTCP, TransportClassTrojanTLS, TransportClassAmneziaWGUDP,
		TransportClassXHTTPTLS, TransportClassWSTLS,
	} {
		if !c.IsValid() {
			t.Fatalf("%q should be valid", c)
		}
	}
	if TransportClass("vmess").IsValid() {
		t.Fatal("an unknown class must not be valid")
	}
}

func TestEdgeReportReachRatio(t *testing.T) {
	r := goodEdgeReport()
	if got := r.ReachRatio(); got != 0.7 {
		t.Fatalf("ReachRatio = %v, want 0.7", got)
	}
	empty := EdgeReport{}
	if got := empty.ReachRatio(); got != 0 {
		t.Fatalf("empty ReachRatio = %v, want 0", got)
	}
}

func TestEdgeReportValidate(t *testing.T) {
	mutate := func(f func(r *EdgeReport)) EdgeReport {
		r := goodEdgeReport()
		f(&r)
		return r
	}
	cases := []struct {
		name    string
		report  EdgeReport
		wantErr error
		wantOK  bool
	}{
		{"ok", goodEdgeReport(), nil, true},
		{"bad version", mutate(func(r *EdgeReport) { r.Version = 99 }), nil, false},
		{"empty region", mutate(func(r *EdgeReport) { r.RegionBucket = "" }), ErrEmptyField, false},
		{"bad class", mutate(func(r *EdgeReport) { r.TransportClass = "vmess" }), ErrUnknownEnum, false},
		{"negative count", mutate(func(r *EdgeReport) { r.Reachable = -1; r.SampleCount = 2 }), nil, false},
		{"sum mismatch", mutate(func(r *EdgeReport) { r.SampleCount = 9 }), nil, false},
		{"below floor", mutate(func(r *EdgeReport) { r.Reachable = 1; r.Unreachable = 1; r.SampleCount = 2 }), ErrAggregationFloor, false},
		{"wrong speed class", mutate(func(r *EdgeReport) { r.SpeedClass = SignalSpeedFast }), ErrUnknownEnum, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.report.Validate()
			if tc.wantOK {
				if err != nil {
					t.Fatalf("want success, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatal("want an error, got nil")
			}
			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Fatalf("want %v, got %v", tc.wantErr, err)
			}
		})
	}
}
