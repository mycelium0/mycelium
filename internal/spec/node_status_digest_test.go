// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// goodDigest is a minimal valid NodeStatusDigest reused across the table tests: a class-aggregate,
// k-floored, TTL-bounded advisory digest in a coarse scope, with region unspecified (the Phase invariant).
func goodDigest() NodeStatusDigest {
	return NodeStatusDigest{
		Version: NetworkStateVersion,
		Scope:   TrustScope{ID: "scope-1", Label: "fleet", MaxHops: 0},
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

// The advisory-fleet digest is a valid SporeType member (it rides a SporeEnvelope of this type).
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
