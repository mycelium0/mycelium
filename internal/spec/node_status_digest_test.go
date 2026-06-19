// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// goodDigest is a minimal valid NodeStatusDigest reused across the table tests: a class-aggregate,
// k-floored, TTL-bounded advisory digest in a coarse scope, with region unspecified (the Phase invariant).
func goodDigest() NodeStatusDigest {
	return NodeStatusDigest{
		Version: NetworkStateVersion,
		Scope:   TrustScope{ID: "scope-1", Label: "network", MaxHops: 0},
		Classes: []ClassHealth{
			{Class: TransportClassRealityTCP, Health: HealthDegraded},
			{Class: TransportClassAmneziaWGUDP, Health: HealthAlive},
		},
		Region:       RegionUnspecified,
		SampleCount:  3,
		MinAggregate: 3,
		IssuedAt:     time.Date(2026, 6, 16, 12, 0, 0, 0, time.UTC),
		ExpiresAt:    time.Date(2026, 6, 16, 12, 15, 0, 0, time.UTC),
	}
}

// The advisory-network digest is a valid SporeType member (it rides a SporeEnvelope of this type).
func TestSporeTypeNodeStatusValid(t *testing.T) {
	if !SporeTypeNodeStatus.IsValid() {
		t.Fatal("node-status must be a valid spore type")
	}
}

func TestNodeStatusDigestValidate(t *testing.T) {
	mutate := func(f func(d *NodeStatusDigest)) NodeStatusDigest {
		d := goodDigest()
		f(&d)
		return d
	}
	cases := []struct {
		name    string
		digest  NodeStatusDigest
		wantErr error
		wantOK  bool
	}{
		{"ok", goodDigest(), nil, true},
		{"bad version", mutate(func(d *NodeStatusDigest) { d.Version = 99 }), nil, false},
		{"empty scope", mutate(func(d *NodeStatusDigest) { d.Scope.ID = "" }), ErrEmptyField, false},
		{"no classes", mutate(func(d *NodeStatusDigest) { d.Classes = nil }), ErrEmptyField, false},
		{"bad class", mutate(func(d *NodeStatusDigest) { d.Classes[0].Class = "vmess" }), ErrUnknownEnum, false},
		{"bad health", mutate(func(d *NodeStatusDigest) { d.Classes[0].Health = "bogus" }), ErrUnknownEnum, false},
		// REGION_COARSENESS: a populated region is rejected until the vocab-hardening ADR lands.
		{"precise region rejected", mutate(func(d *NodeStatusDigest) { d.Region = "us-ca-1" }), ErrUnknownEnum, false},
		// AGGREGATION_FLOOR: a sample count below the floor is rejected (never emit a sub-floor digest).
		{"below aggregation floor", mutate(func(d *NodeStatusDigest) { d.SampleCount = 1; d.MinAggregate = 3 }), ErrAggregationFloor, false},
		{"negative floor", mutate(func(d *NodeStatusDigest) { d.MinAggregate = -1 }), nil, false},
		{"non-positive ttl", mutate(func(d *NodeStatusDigest) { d.ExpiresAt = d.IssuedAt }), ErrBadTTL, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.digest.Validate()
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

// TestNodeStatusDigestNoPerNodeField is the structural NO_PER_NODE_ROW proof (ADR-0030): the wire shape
// must carry NO node identifier and NO per-node/endpoint/location field. A future refactor that adds one
// (e.g. a node_ref to "make it convenient") fails here — the type is the guardrail, not a comment.
func TestNodeStatusDigestNoPerNodeField(t *testing.T) {
	raw, err := json.Marshal(goodDigest())
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	wire := strings.ToLower(string(raw))
	// Note: sample_count / min_aggregate are the legitimate k-floor fields, not a per-node count, so
	// "count" is not forbidden; an EXACT per-cell count belongs to a published snapshot, not this digest.
	forbidden := []string{"node_ref", "node_id", "nodeid", "noderef", "\"node\"", "host", "hostname", "\"ip\"", "addr", "endpoint", "sni", "country", "geo", "asn", "sibling"}
	for _, f := range forbidden {
		if strings.Contains(wire, f) {
			t.Fatalf("NodeStatusDigest wire shape must not contain a per-node/identity/location field, found %q in: %s", f, wire)
		}
	}
}

func TestBuildNodeStatusDigest(t *testing.T) {
	scope := TrustScope{ID: "op", Label: "network", MaxHops: 0}
	now := time.Date(2026, 6, 19, 12, 0, 0, 0, time.UTC)
	// k=3: reality-tcp has 3 members (one alive => class alive); amneziawg-udp has 2 (< k => OMITTED).
	obs := map[TransportClass][]HealthValue{
		TransportClassRealityTCP:   {HealthDegraded, HealthAlive, HealthUnknown},
		TransportClassAmneziaWGUDP: {HealthAlive, HealthAlive},
	}
	d, err := BuildNodeStatusDigest(scope, obs, 3, 15*time.Minute, now)
	if err != nil {
		t.Fatalf("BuildNodeStatusDigest: %v", err)
	}
	if err := d.Validate(); err != nil {
		t.Errorf("built digest does not validate: %v", err)
	}
	if len(d.Classes) != 1 {
		t.Fatalf("classes = %d, want 1 (the sub-floor amneziawg class must be OMITTED, never zeroed)", len(d.Classes))
	}
	if d.Classes[0].Class != TransportClassRealityTCP || d.Classes[0].Health != HealthAlive {
		t.Errorf("class[0] = %+v, want reality-tcp/alive (alive-dominant aggregate)", d.Classes[0])
	}
	if d.MinAggregate != 3 || d.SampleCount != 3 {
		t.Errorf("floor/sample = %d/%d, want 3/3", d.MinAggregate, d.SampleCount)
	}
	if !d.IssuedAt.Equal(now) || !d.ExpiresAt.Equal(now.Add(15*time.Minute)) {
		t.Errorf("ttl window wrong: issued %v expires %v", d.IssuedAt, d.ExpiresAt)
	}
	if d.Region != RegionUnspecified {
		t.Errorf("region = %q, want unspecified", d.Region)
	}
}

func TestBuildNodeStatusDigestAggregateAndDeterminism(t *testing.T) {
	scope := TrustScope{ID: "op"}
	now := time.Date(2026, 6, 19, 12, 0, 0, 0, time.UTC)
	obs := map[TransportClass][]HealthValue{
		TransportClassRealityTCP:   {HealthDegraded, HealthUnknown}, // no alive => degraded
		TransportClassAmneziaWGUDP: {HealthUnknown, HealthUnknown},  // all unknown => unknown
	}
	d1, err := BuildNodeStatusDigest(scope, obs, 2, time.Minute, now)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	d2, _ := BuildNodeStatusDigest(scope, obs, 2, time.Minute, now)
	if !reflect.DeepEqual(d1, d2) {
		t.Error("non-deterministic build (same obs must yield the same digest)")
	}
	got := map[TransportClass]HealthValue{}
	for _, c := range d1.Classes {
		got[c.Class] = c.Health
	}
	if got[TransportClassRealityTCP] != HealthDegraded {
		t.Errorf("reality-tcp = %q, want degraded (no alive member)", got[TransportClassRealityTCP])
	}
	if got[TransportClassAmneziaWGUDP] != HealthUnknown {
		t.Errorf("amneziawg-udp = %q, want unknown (all unknown)", got[TransportClassAmneziaWGUDP])
	}
}

func TestBuildNodeStatusDigestFailClosed(t *testing.T) {
	scope := TrustScope{ID: "op"}
	now := time.Date(2026, 6, 19, 12, 0, 0, 0, time.UTC)
	two := []HealthValue{HealthAlive, HealthAlive}
	// every class below the floor -> emit NOTHING (ErrAggregationFloor), never a sub-floor digest.
	if _, err := BuildNodeStatusDigest(scope, map[TransportClass][]HealthValue{TransportClassRealityTCP: {HealthAlive}}, 3, time.Minute, now); !errors.Is(err, ErrAggregationFloor) {
		t.Errorf("sub-floor: err = %v, want ErrAggregationFloor", err)
	}
	if _, err := BuildNodeStatusDigest(scope, map[TransportClass][]HealthValue{TransportClassRealityTCP: two}, 0, time.Minute, now); err == nil {
		t.Error("k=0 should fail")
	}
	if _, err := BuildNodeStatusDigest(scope, map[TransportClass][]HealthValue{TransportClassRealityTCP: two}, 2, 0, now); err == nil {
		t.Error("ttl=0 should fail")
	}
	if _, err := BuildNodeStatusDigest(scope, map[TransportClass][]HealthValue{TransportClass("made-up"): two}, 2, time.Minute, now); err == nil {
		t.Error("an unknown class meeting the floor should fail closed")
	}
	if _, err := BuildNodeStatusDigest(TrustScope{}, map[TransportClass][]HealthValue{TransportClassRealityTCP: two}, 2, time.Minute, now); err == nil {
		t.Error("an invalid scope should fail closed (via Validate)")
	}
}
