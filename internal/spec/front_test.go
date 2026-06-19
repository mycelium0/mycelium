// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "testing"

func TestFrontModeIsValid(t *testing.T) {
	for _, m := range []FrontMode{FrontModeRelay, FrontModeTerminate} {
		if !m.IsValid() {
			t.Errorf("%q should be valid", m)
		}
	}
	for _, m := range []FrontMode{FrontModeUnknown, "proxy", "tunnel"} {
		if m.IsValid() {
			t.Errorf("%q should be invalid", m)
		}
	}
}

func TestIsFrontableTransport(t *testing.T) {
	for _, p := range []string{"vless-xhttp-tls", "vless-ws-tls"} {
		if !IsFrontableTransport(p) {
			t.Errorf("%q should be frontable (genuine-TLS own-cert HTTP)", p)
		}
	}
	// REALITY / raw / UDP transports are NOT frontable.
	for _, p := range []string{"vless-reality-vision", "vless-reality-grpc", "hysteria2", "tuic", "shadowsocks", "trojan", "amneziawg", ""} {
		if IsFrontableTransport(p) {
			t.Errorf("%q must NOT be frontable", p)
		}
	}
}

func TestFrontConfigEffectiveMode(t *testing.T) {
	if (FrontConfig{}).EffectiveMode() != FrontModeRelay {
		t.Error("empty mode must default to relay (doctrine-clean default)")
	}
	if (FrontConfig{Mode: FrontModeTerminate}).EffectiveMode() != FrontModeTerminate {
		t.Error("an explicit mode must be preserved")
	}
}

func TestFrontConfigValidate(t *testing.T) {
	// Disabled is always valid (default-off, inert) — even with otherwise-bogus fields.
	if err := (FrontConfig{Enabled: false, Transport: "nonsense"}).Validate(); err != nil {
		t.Errorf("disabled front should validate: %v", err)
	}
	// A clean enabled relay front (empty mode => relay).
	if err := (FrontConfig{Enabled: true, Domain: "front.example.invalid", Transport: "vless-xhttp-tls"}).Validate(); err != nil {
		t.Errorf("valid relay front rejected: %v", err)
	}
	// Explicit relay is fine and needs no ack.
	if err := (FrontConfig{Enabled: true, Domain: "d", Transport: "vless-ws-tls", Mode: FrontModeRelay}).Validate(); err != nil {
		t.Errorf("explicit relay rejected: %v", err)
	}
	// Terminate WITH the ack is allowed.
	if err := (FrontConfig{Enabled: true, Domain: "d", Transport: "vless-ws-tls", Mode: FrontModeTerminate, AckTerminateTradeoff: true}).Validate(); err != nil {
		t.Errorf("acknowledged terminate rejected: %v", err)
	}

	bad := []struct {
		name string
		c    FrontConfig
	}{
		{"enabled, no domain", FrontConfig{Enabled: true, Transport: "vless-xhttp-tls"}},
		{"non-frontable transport (reality)", FrontConfig{Enabled: true, Domain: "d", Transport: "vless-reality-vision"}},
		{"non-frontable transport (udp)", FrontConfig{Enabled: true, Domain: "d", Transport: "amneziawg"}},
		{"unknown mode", FrontConfig{Enabled: true, Domain: "d", Transport: "vless-ws-tls", Mode: FrontMode("proxy")}},
		{"terminate WITHOUT ack (the metadata leak)", FrontConfig{Enabled: true, Domain: "d", Transport: "vless-ws-tls", Mode: FrontModeTerminate}},
	}
	for _, b := range bad {
		if err := b.c.Validate(); err == nil {
			t.Errorf("%s: Validate accepted, want fail-closed error", b.name)
		}
	}
}
