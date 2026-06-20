// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
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

func TestParseNodeProfileValidatesContent(t *testing.T) {
	// Parse runs Validate: a weather-on descriptor is refused even though it is syntactically valid.
	const weatherOn = `{"weather":{"enabled":true}}`
	if _, err := ParseNodeProfile(strings.NewReader(weatherOn)); err == nil {
		t.Fatal("ParseNodeProfile accepted weather.enabled=true; expected the reserved-slot rejection")
	}
}
