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

// goodEndpoint is a minimal valid Endpoint reused across the table tests.
func goodEndpoint() Endpoint {
	return Endpoint{
		Tag:            "kz1-vision",
		TransportClass: TransportClassRealityTCP,
		Region:         "bucket-a",
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
