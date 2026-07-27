// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"slices"
	"strings"
	"testing"
)

func TestNodeProfileValidate(t *testing.T) {
	tests := []struct {
		name    string
		p       NodeProfile
		wantErr bool
	}{
		{"all-default inert is valid", NodeProfile{}, false},
		{"known transports valid", NodeProfile{Transports: []string{"vless-reality-vision", "vless-reality-grpc"}}, false},
		{"unknown transport rejected", NodeProfile{Transports: []string{"not-a-transport"}}, true},
		{"reachable true is valid (operator-declared public entry)", NodeProfile{Reachable: true}, false},
		{"disabled front valid", NodeProfile{Front: FrontConfig{Enabled: false}}, false},
		{"enabled relay front (domain+frontable) valid", NodeProfile{Front: FrontConfig{Enabled: true, Domain: "front.example", Transport: "vless-ws-tls", Mode: FrontModeRelay}}, false},
		{"enabled front non-frontable transport rejected", NodeProfile{Front: FrontConfig{Enabled: true, Domain: "front.example", Transport: "vless-reality-vision"}}, true},
		{"terminate without ack rejected", NodeProfile{Front: FrontConfig{Enabled: true, Domain: "front.example", Transport: "vless-ws-tls", Mode: FrontModeTerminate}}, true},
		{"terminate with ack valid", NodeProfile{Front: FrontConfig{Enabled: true, Domain: "front.example", Transport: "vless-ws-tls", Mode: FrontModeTerminate, AckTerminateTradeoff: true}}, false},
		{"ingress missing via_user rejected", NodeProfile{Ingress: &IngressTwoHop{Server: "s", SNI: "sni"}}, true},
		{"ingress complete valid", NodeProfile{Ingress: &IngressTwoHop{Server: "s", SNI: "sni", ViaUser: "u"}}, false},
		{"weather enabled rejected (reserved/inert)", NodeProfile{Weather: WeatherSlot{Enabled: true}}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.p.Validate()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Validate() err = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}

// A registry proto with no enable key (e.g. AmneziaWG, toggled by a bootstrap flag not a params key)
// is not operator-toggleable through the descriptor and must be rejected.
func TestNodeProfileRejectsNonToggleableTransport(t *testing.T) {
	for _, d := range TransportRegistry() {
		if d.EnableKey == "" {
			p := NodeProfile{Transports: []string{d.Proto}}
			if err := p.Validate(); err == nil {
				t.Fatalf("transport %q has no enable key but the profile accepted it", d.Proto)
			}
			return
		}
	}
	t.Skip("no non-toggleable transport in the registry to exercise this branch")
}

func TestNodeProfileWithTransport(t *testing.T) {
	base := NodeProfile{Transports: []string{"vless-reality-vision", "hysteria2"}}
	cases := []struct {
		name   string
		proto  string
		enable bool
		want   []string
	}{
		{"enable new -> appended", "trojan", true, []string{"vless-reality-vision", "hysteria2", "trojan"}},
		{"enable existing -> dedup, moved last", "vless-reality-vision", true, []string{"hysteria2", "vless-reality-vision"}},
		{"disable existing -> removed", "hysteria2", false, []string{"vless-reality-vision"}},
		{"disable absent -> no-op", "trojan", false, []string{"vless-reality-vision", "hysteria2"}},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			got := base.WithTransport(tt.proto, tt.enable).Transports
			if !slices.Equal(got, tt.want) {
				t.Fatalf("WithTransport(%q, %v) = %v; want %v", tt.proto, tt.enable, got, tt.want)
			}
		})
	}
	// value semantics: the source profile is never mutated.
	if !slices.Equal(base.Transports, []string{"vless-reality-vision", "hysteria2"}) {
		t.Fatalf("WithTransport mutated the source: %v", base.Transports)
	}
}

func TestParseNodeProfileRejectsUnknownFields(t *testing.T) {
	// A node-TYPE enum (or any field outside the closed capability set) must be refused —
	// capabilities, not types (ADR-0034).
	const withType = `{"type":"entry","reachable":false}`
	if _, err := ParseNodeProfile(strings.NewReader(withType)); err == nil {
		t.Fatal("ParseNodeProfile accepted an unknown \"type\" field; expected fail-closed rejection")
	}
	// A clean, all-default descriptor parses.
	const clean = `{"reachable":false,"front":{"enabled":false},"loops":{"update":false,"rotate":false,"measure":false},"weather":{"enabled":false}}`
	if _, err := ParseNodeProfile(strings.NewReader(clean)); err != nil {
		t.Fatalf("ParseNodeProfile rejected a clean default descriptor: %v", err)
	}
}

func TestNodeProfileEnabledKeys(t *testing.T) {
	// empty transports -> no keys (the node keeps its default-on set)
	if keys, err := (NodeProfile{}).EnabledKeys(); err != nil || len(keys) != 0 {
		t.Fatalf("empty profile EnabledKeys = %v, %v; want [], nil", keys, err)
	}
	// known transports -> their registry enable-keys, sorted, each a real registry key
	keys, err := NodeProfile{Transports: []string{"vless-reality-vision", "vless-reality-grpc"}}.EnabledKeys()
	if err != nil {
		t.Fatalf("EnabledKeys error: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("want 2 keys, got %v", keys)
	}
	for i := 1; i < len(keys); i++ {
		if keys[i-1] > keys[i] {
			t.Fatalf("keys not sorted: %v", keys)
		}
	}
	for _, k := range keys {
		found := false
		for _, d := range TransportRegistry() {
			if d.EnableKey == k {
				found = true
			}
		}
		if !found {
			t.Fatalf("key %q is not a registry enable key", k)
		}
	}
	// unknown transport -> error (fail-closed, mirrors Validate)
	if _, err := (NodeProfile{Transports: []string{"nope"}}).EnabledKeys(); err == nil {
		t.Fatal("EnabledKeys accepted an unknown transport")
	}
}

func TestParseNodeProfileValidatesContent(t *testing.T) {
	// Parse runs Validate: a weather-on descriptor is refused even though it is syntactically valid.
	const weatherOn = `{"weather":{"enabled":true}}`
	if _, err := ParseNodeProfile(strings.NewReader(weatherOn)); err == nil {
		t.Fatal("ParseNodeProfile accepted weather.enabled=true; expected the reserved-slot rejection")
	}
}

// TestNewNodeProfileMatchesAbsentDescriptor: the constructor must reproduce the ABSENT-descriptor wire
// posture (public). The Go zero value is deliberately the opposite, so a CLI verb that starts an edit from
// the zero value silently takes a live public node off the network on the next apply — which is exactly
// what happened before this existed.
func TestNewNodeProfileMatchesAbsentDescriptor(t *testing.T) {
	if !NewNodeProfile().Reachable {
		t.Fatal("NewNodeProfile must be PUBLIC — an absent descriptor renders public on the wire")
	}
	var zero NodeProfile
	if zero.Reachable {
		t.Fatal("the Go zero value is expected to be non-public; if that changed, the constructor's reason to exist changed too")
	}
}

// TestTransportEditPreservesPosture: editing the transport set on a node that had NO descriptor must not
// change its reachability posture. This is the regression: `transport enable X` created a descriptor with
// reachable=false and would have rebound a public node to loopback on the next apply.
func TestTransportEditPreservesPosture(t *testing.T) {
	p := NewNodeProfile().WithTransport("shadowsocks", true)
	if !p.Reachable {
		t.Fatal("enabling a transport must not flip a public node to non-public")
	}
	// And the edit still did its job.
	found := false
	for _, tr := range p.Transports {
		if tr == "shadowsocks" {
			found = true
		}
	}
	if !found {
		t.Fatal("the transport edit was lost")
	}
}
