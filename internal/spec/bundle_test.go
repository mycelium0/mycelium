// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"
	"time"
)

// goodEndpoint is a minimal valid Endpoint reused across the table tests.
func goodEndpoint() Endpoint {
	return Endpoint{
		Tag:            "node-vision",
		TransportClass: TransportClassRealityTCP,
		Region:         RegionUnspecified,
		Priority:       0,
		Health:         HealthUnknown,
		Link:           "vless://example",
	}
}

// goodBundle is a minimal valid Bundle reused across the table tests.
func goodBundle() Bundle {
	return Bundle{
		Version:     NetworkStateVersion,
		Endpoints:   []Endpoint{goodEndpoint()},
		GeneratedAt: time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC),
	}
}

func TestHealthValueIsValid(t *testing.T) {
	for _, h := range []HealthValue{HealthUnknown, HealthAlive, HealthDegraded} {
		if !h.IsValid() {
			t.Fatalf("%q should be valid", h)
		}
	}
	if HealthValue("").IsValid() {
		t.Fatal("the empty zero value must not be valid")
	}
	if HealthValue("bogus").IsValid() {
		t.Fatal("an unknown health value must not be valid")
	}
}

// The xhttp-tls family added for RP-0007 must be a valid, DISTINCT transport class.
func TestTransportClassXHTTPTLSValid(t *testing.T) {
	if !TransportClassXHTTPTLS.IsValid() {
		t.Fatal("xhttp-tls must be a valid transport class")
	}
	if TransportClassXHTTPTLS == TransportClassRealityTCP {
		t.Fatal("xhttp-tls must be distinct from reality-tcp (not TLS-in-TLS)")
	}
}

// C13: the region vocabulary is closed. In Phase 1 only "unspecified" is valid; anything finer (a
// precise geo/ASN string) must be rejected so the bundle is not a location map.
func TestRegionBucketIsValid(t *testing.T) {
	if !RegionUnspecified.IsValid() {
		t.Fatal("the unspecified bucket must be valid")
	}
	for _, r := range []RegionBucket{"", "us-ca-sf-aws-1a", "eu-west", "bucket-a"} {
		if r.IsValid() {
			t.Fatalf("region %q must NOT be valid in Phase 1 (only %q is)", r, RegionUnspecified)
		}
	}
}

func TestEndpointValidate(t *testing.T) {
	mutate := func(f func(e *Endpoint)) Endpoint {
		e := goodEndpoint()
		f(&e)
		return e
	}
	cases := []struct {
		name    string
		ep      Endpoint
		wantErr error
		wantOK  bool
	}{
		{"ok", goodEndpoint(), nil, true},
		{"empty tag", mutate(func(e *Endpoint) { e.Tag = "" }), ErrEmptyField, false},
		{"bad class", mutate(func(e *Endpoint) { e.TransportClass = "vmess" }), ErrUnknownEnum, false},
		{"xhttp-tls ok", mutate(func(e *Endpoint) { e.TransportClass = TransportClassXHTTPTLS }), nil, true},
		{"empty region", mutate(func(e *Endpoint) { e.Region = "" }), ErrEmptyField, false},
		{"precise region rejected (C13)", mutate(func(e *Endpoint) { e.Region = "us-ca-sf-aws-1a" }), ErrUnknownEnum, false},
		{"negative priority", mutate(func(e *Endpoint) { e.Priority = -1 }), nil, false},
		{"bad health enum", mutate(func(e *Endpoint) { e.Health = "bogus" }), ErrUnknownEnum, false},
		{"non-unknown health rejected in phase 1", mutate(func(e *Endpoint) { e.Health = HealthAlive }), nil, false},
		{"empty link", mutate(func(e *Endpoint) { e.Link = "" }), ErrEmptyField, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.ep.Validate()
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

func TestBundleValidate(t *testing.T) {
	mutate := func(f func(b *Bundle)) Bundle {
		b := goodBundle()
		f(&b)
		return b
	}
	cases := []struct {
		name    string
		bundle  Bundle
		wantErr error
		wantOK  bool
	}{
		{"ok", goodBundle(), nil, true},
		{"bad version", mutate(func(b *Bundle) { b.Version = 99 }), nil, false},
		{"empty endpoints", mutate(func(b *Bundle) { b.Endpoints = nil }), ErrEmptyField, false},
		{"zero generated_at (C15)", mutate(func(b *Bundle) { b.GeneratedAt = time.Time{} }), ErrEmptyField, false},
		{"propagates endpoint error", mutate(func(b *Bundle) { b.Endpoints[0].Link = "" }), ErrEmptyField, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.bundle.Validate()
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

// TestBundleJSONRoundTrip (C16) proves a Bundle survives marshal -> unmarshal -> Validate unchanged.
// It is the Go-side mirror of the bundle_go_roundtrip conformance gate: the wire shape the shell
// renderer emits is exactly what spec.Bundle consumes, so there is no field drift between producer and
// the authoritative validator.
func TestBundleJSONRoundTrip(t *testing.T) {
	want := goodBundle()
	raw, err := json.Marshal(want)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got Bundle
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if err := got.Validate(); err != nil {
		t.Fatalf("round-tripped bundle must validate, got %v", err)
	}
	if got.Version != want.Version || len(got.Endpoints) != len(want.Endpoints) {
		t.Fatalf("round-trip changed version/endpoint count: got %+v", got)
	}
	if !reflect.DeepEqual(got.Endpoints, want.Endpoints) {
		t.Fatalf("round-trip changed endpoints:\n got %+v\nwant %+v", got.Endpoints, want.Endpoints)
	}
	if !got.GeneratedAt.Equal(want.GeneratedAt) {
		t.Fatalf("round-trip changed generated_at: got %s want %s", got.GeneratedAt, want.GeneratedAt)
	}
}

// TestBundleJSONWireShape (C16/C13/C15) validates the literal wire JSON the shell renderer emits, and
// proves a tampered wire value (a precise region, a populated health, a missing timestamp) is rejected
// after unmarshal — the exact checks the bundle_go_roundtrip gate runs against rendered output.
func TestBundleJSONWireShape(t *testing.T) {
	const validWire = `{
		"version": 1,
		"endpoints": [
			{"tag":"node-vision","transport_class":"reality-tcp","region":"unspecified","priority":0,"health":"unknown","link":"vless://example"}
		],
		"generated_at": "2026-06-15T12:00:00Z"
	}`
	var b Bundle
	if err := json.Unmarshal([]byte(validWire), &b); err != nil {
		t.Fatalf("unmarshal valid wire: %v", err)
	}
	if err := b.Validate(); err != nil {
		t.Fatalf("valid wire bundle must validate, got %v", err)
	}
	bad := map[string]string{
		"precise region":   `{"version":1,"generated_at":"2026-06-15T12:00:00Z","endpoints":[{"tag":"t","transport_class":"reality-tcp","region":"us-ca-1","priority":0,"health":"unknown","link":"vless://x"}]}`,
		"populated health":  `{"version":1,"generated_at":"2026-06-15T12:00:00Z","endpoints":[{"tag":"t","transport_class":"reality-tcp","region":"unspecified","priority":0,"health":"alive","link":"vless://x"}]}`,
		"missing timestamp": `{"version":1,"endpoints":[{"tag":"t","transport_class":"reality-tcp","region":"unspecified","priority":0,"health":"unknown","link":"vless://x"}]}`,
	}
	for name, wire := range bad {
		t.Run(name, func(t *testing.T) {
			var bb Bundle
			if err := json.Unmarshal([]byte(wire), &bb); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if err := bb.Validate(); err == nil {
				t.Fatalf("%s must be rejected, got nil", name)
			}
		})
	}
}
