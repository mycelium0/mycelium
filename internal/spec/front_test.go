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

// TestLoadFrontConfigAcceptsBothShapes pins ADR-0038 §2: node.config.json is the single owner of front
// configuration, and the standalone file remains an explicit override. Before this, spec.NodeProfile
// declared and VALIDATED a Front field that nothing consumed — an operator following ADR-0034 configured
// a front that never existed, and `node plan` reported it as live. The first remediation materialised
// the profile's .front into a derived third file, which is the same one-truth-two-locations defect
// (development.md §2.2 item 8); deciding the shape here means no file is written.
func TestLoadFrontConfigAcceptsBothShapes(t *testing.T) {
	bare := []byte(`{"enabled":true,"domain":"front.example.invalid","transport":"vless-ws-tls","mode":"relay"}`)
	got, err := LoadFrontConfig(bare)
	if err != nil {
		t.Fatalf("bare FrontConfig: %v", err)
	}
	if !got.Enabled || got.Domain != "front.example.invalid" {
		t.Fatalf("bare FrontConfig decoded wrong: %+v", got)
	}

	profile := []byte(`{"harden":true,"reachable":true,"front":` + string(bare) + `}`)
	got2, err := LoadFrontConfig(profile)
	if err != nil {
		t.Fatalf("node profile: %v", err)
	}
	if got2 != got {
		t.Fatalf("the profile shape decoded differently from the bare one:\n bare=%+v\n prof=%+v\n"+
			"Two shapes of one truth must resolve identically, or an operator who follows ADR-0034 gets a "+
			"different front from one who writes the standalone file.", got, got2)
	}

	// A profile with no .front is the fail-closed direction: disabled, exactly like no configuration.
	got3, err := LoadFrontConfig([]byte(`{"harden":true}`))
	if err != nil {
		t.Fatalf("profile without .front: %v", err)
	}
	if got3.Enabled {
		t.Fatalf("a profile carrying no .front produced an ENABLED front (%+v) — absence must never enable", got3)
	}

	if _, err := LoadFrontConfig([]byte(`not json`)); err == nil {
		t.Fatal("a non-JSON document was accepted; the loader must fail closed")
	}
}
