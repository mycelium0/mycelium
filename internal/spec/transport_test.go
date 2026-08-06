// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"testing"
)

// TestTransportRegistryClassesAreValidAndClosed binds the registry to the closed
// transport-class vocabulary: every proto's class is a valid member, and the SET of
// classes the registry covers is EXACTLY the closed vocabulary (no class is left
// without a proto, and no proto introduces a class outside the vocabulary). This is
// the invariant that lets the shell trust control/vocab.json as the whole story.
func TestTransportRegistryClassesAreValidAndClosed(t *testing.T) {
	reg := TransportRegistry()
	if len(reg) == 0 {
		t.Fatal("transport registry is empty")
	}
	covered := make(map[TransportClass]bool)
	for _, p := range reg {
		if !p.Class.IsValid() {
			t.Errorf("proto %q maps to an invalid transport class %q", p.Proto, p.Class)
		}
		covered[p.Class] = true
	}
	vocab := make(map[TransportClass]bool)
	for _, c := range TransportClasses() {
		if !c.IsValid() {
			t.Errorf("closed vocabulary lists an invalid class %q", c)
		}
		vocab[c] = true
		if !covered[c] {
			t.Errorf("transport class %q is in the closed vocabulary but no proto covers it", c)
		}
	}
	for c := range covered {
		if !vocab[c] {
			t.Errorf("proto registry introduces class %q outside the closed vocabulary", c)
		}
	}
}

// TestTransportRegistryUniqueness ensures proto names, the params enable/port keys,
// and the (engine, default-port) listen tuples do not collide — a duplicate would let
// two protos fight over one params key or one listen port.
func TestTransportRegistryUniqueness(t *testing.T) {
	seenProto := make(map[string]bool)
	seenEnable := make(map[string]bool)
	seenPortKey := make(map[string]bool)
	for _, p := range TransportRegistry() {
		if seenProto[p.Proto] {
			t.Errorf("duplicate proto name %q", p.Proto)
		}
		seenProto[p.Proto] = true

		// Params-toggled protos must carry a full, unique key set + a real port; the
		// non-toggled dataplane (amneziawg) carries empties and is exempt.
		if p.Engine == EngineAmneziaWG {
			if p.EnableKey != "" || p.PortKey != "" || p.DefaultPort != 0 {
				t.Errorf("non-toggled proto %q must carry empty params keys and zero default port", p.Proto)
			}
			continue
		}
		if p.EnableKey == "" || p.PortKey == "" {
			t.Errorf("params-toggled proto %q is missing an enable/port key", p.Proto)
		}
		if p.DefaultPort < 1 || p.DefaultPort > 65535 {
			t.Errorf("proto %q default port %d is out of range 1..65535", p.Proto, p.DefaultPort)
		}
		if p.Scheme == "" {
			t.Errorf("params-toggled proto %q is missing a share-link scheme", p.Proto)
		}
		if seenEnable[p.EnableKey] {
			t.Errorf("duplicate enable key %q", p.EnableKey)
		}
		seenEnable[p.EnableKey] = true
		if seenPortKey[p.PortKey] {
			t.Errorf("duplicate port key %q", p.PortKey)
		}
		seenPortKey[p.PortKey] = true
	}
}

// TestClassForProto checks the proto->class lookup that replaces the shell
// `myc_bundle_class_of` case statement, including the fail-closed unknown path.
func TestClassForProto(t *testing.T) {
	cases := []struct {
		proto string
		want  TransportClass
		ok    bool
	}{
		{"vless-reality-vision", TransportClassRealityTCP, true},
		{"vless-reality-grpc", TransportClassRealityTCP, true},
		{"vless-reality-xhttp", TransportClassRealityTCP, true},
		{"vless-xhttp-tls", TransportClassXHTTPTLS, true},
		{"vless-ws-tls", TransportClassWSTLS, true},
		{"hysteria2", TransportClassQUICUDP, true},
		{"tuic", TransportClassQUICUDP, true},
		{"shadowsocks", TransportClassShadowsocksTCP, true},
		{"shadowtls", TransportClassShadowTLSTCP, true},
		{"trojan", TransportClassTrojanTLS, true},
		{"amneziawg", TransportClassAmneziaWGUDP, true},
		{"vmess", TransportClassUnknown, false},
		{"", TransportClassUnknown, false},
	}
	for _, c := range cases {
		got, ok := ClassForProto(c.proto)
		if got != c.want || ok != c.ok {
			t.Errorf("ClassForProto(%q) = (%q, %v), want (%q, %v)", c.proto, got, ok, c.want, c.ok)
		}
	}
}

// TestTransportRegistryIsACopy guards the encapsulation: mutating a returned slice
// must not corrupt the source of truth.
func TestTransportRegistryIsACopy(t *testing.T) {
	reg := TransportRegistry()
	if len(reg) == 0 {
		t.Fatal("empty registry")
	}
	reg[0].Proto = "tampered"
	if again := TransportRegistry(); again[0].Proto == "tampered" {
		t.Error("TransportRegistry() leaks a reference to the package-level table")
	}
}

// TestVocabRoundTrips ensures NewVocab marshals to JSON and back to an identical
// value — the property the committed control/vocab.json relies on.
func TestVocabRoundTrips(t *testing.T) {
	v := NewVocab()
	if v.Version != NetworkStateVersion {
		t.Errorf("vocab version = %d, want %d", v.Version, NetworkStateVersion)
	}
	if len(v.TransportClasses) != len(transportClasses) ||
		len(v.RegionBuckets) != len(regionBuckets) ||
		len(v.HealthValues) != len(healthValues) ||
		len(v.Protos) != len(transportRegistry) {
		t.Fatalf("vocab does not mirror the registries")
	}
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var back Vocab
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(back.Protos) != len(v.Protos) {
		t.Fatalf("round-trip lost protos: %d != %d", len(back.Protos), len(v.Protos))
	}
	for i := range v.Protos {
		if back.Protos[i] != v.Protos[i] {
			t.Errorf("proto[%d] round-trip mismatch: %+v != %+v", i, back.Protos[i], v.Protos[i])
		}
	}
}

// TestOperatorToggleKeysMatchesLegacy pins the registry-derived operator allowlist to the exact set the
// shell hardcoded before RP-0008 moved it into the vocab — so the migration is provably lossless (the
// override merge + the rotation enable-key validation see the identical closed set, just single-sourced).
func TestOperatorToggleKeysMatchesLegacy(t *testing.T) {
	legacy := []string{
		"vless_reality_vision_enabled", "vless_reality_grpc_enabled", "vless_reality_xhttp_enabled",
		"vless_xhttp_tls_enabled", "vless_ws_tls_enabled", "hysteria2_enabled", "tuic_enabled", "shadowsocks_enabled",
		"shadowtls_enabled", "trojan_enabled",
		"vless_reality_vision_port", "vless_reality_grpc_port", "vless_reality_xhttp_port",
		"vless_xhttp_tls_port", "vless_ws_tls_port", "hysteria2_port", "tuic_port", "shadowsocks_port", "shadowtls_port",
		"trojan_port", "xhttp_path", "xhttp_path_tls", "ws_path", "grpc_service_name", "region_bucket",
		"client_fingerprint", // RP-0015: the client uTLS-preset knob joined the tunable allowlist.
		// hysteria2 port hopping. Adding these two to operatorTunableKnobs without adding them here left
		// this test RED at HEAD, and `make test` is the blocking half of CI — so the next real regression
		// would have arrived under a failure someone had already learned to expect. That has happened once
		// in this repo already (b314bc8: "CI had been red for five commits and I never looked").
		"hysteria2_hop_ports", "hysteria2_hop_interval",
	}
	got := OperatorToggleKeys()
	asSet := func(s []string) map[string]int {
		m := make(map[string]int, len(s))
		for _, k := range s {
			m[k]++
		}
		return m
	}
	want, have := asSet(legacy), asSet(got)
	if len(got) != len(legacy) {
		t.Errorf("OperatorToggleKeys length %d != legacy %d", len(got), len(legacy))
	}
	for k := range want {
		if have[k] == 0 {
			t.Errorf("OperatorToggleKeys is missing the legacy key %q", k)
		}
	}
	for k, n := range have {
		if want[k] == 0 {
			t.Errorf("OperatorToggleKeys has an unexpected key %q (not in the legacy allowlist)", k)
		}
		if n > 1 {
			t.Errorf("OperatorToggleKeys has a duplicate key %q (x%d)", k, n)
		}
	}
}

// TestValidHysteria2HopRange is the owner's own behavioural test (Audit-0010 F-007). The appointed
// single owner of a rule that decides what goes into a firewall had NO test of its own: the conformance
// gate drives the SHELL comparator and greps Go for the function's name, which proves the function
// exists, not that it decides correctly. A predicate whose only coverage is "a grep found it" is
// coverage of the wrong thing.
func TestValidHysteria2HopRange(t *testing.T) {
	b := Hysteria2HopPortBounds()
	cases := []struct {
		in   string
		want bool
		why  string
	}{
		{"20000:21000", true, "ordinary range"},
		{"1024:65535", true, "the exact bounds are inclusive"},
		{"2000:2001", true, "the narrowest usable range"},
		{"", false, "empty is not a range; it means no hopping and callers check that separately"},
		{"20000", false, "a bare port is not a range"},
		{":20000", false, "no low field"},
		{"20000:", false, "no high field"},
		{"0:100", false, "below the unprivileged floor"},
		{"1023:2000", false, "one below the floor"},
		{"20000:70000", false, "above the protocol maximum"},
		{"5000:4000", false, "reversed"},
		{"5000:5000", false, "empty interval — lo must be strictly below hi"},
		{"2000:3000:4000", false, "three fields; the outer-field expansions accepted this in shell and iptables refuses it"},
		{" 20000:21000", false, "leading space"},
		{"20000:21000 ", false, "trailing space"},
		{"-1:500", false, "sign"},
		{"1e4:2e4", false, "exponent notation"},
		{"001024:065535", false, "zero-padded: numerically in bounds, and the digit cap refuses it"},
		{"0000000000000000000000000000002000:3000", false, "absurd padding"},
		{"abc", false, "not digits"},
	}
	for _, c := range cases {
		if got := ValidHysteria2HopRange(c.in); got != c.want {
			t.Errorf("ValidHysteria2HopRange(%q) = %v, want %v (%s). Bounds are %d..%d; this predicate "+
				"decides whether a nat/PREROUTING REDIRECT is written, so a wrong answer is either a rule "+
				"that swallows traffic or an advertised range with nothing behind it.",
				c.in, got, c.want, c.why, b.Min, b.Max)
		}
	}
}

// TestValidHysteria2HopInterval pins the duration predicate (Audit-0010 F-005), which had no test either.
func TestValidHysteria2HopInterval(t *testing.T) {
	for in, want := range map[string]bool{
		"30s": true, "3s": true, "2m": true, "1h": true, "500ms": true,
		"": false, "30": false, "s": false, "0s": false, "-5s": false,
		"30sec": false, "1h2m3s": false, "30S": false, "99999s": true, "100000s": false,
	} {
		if got := ValidHysteria2HopInterval(in); got != want {
			t.Errorf("ValidHysteria2HopInterval(%q) = %v, want %v — an unjudged duration reaches sing-box, "+
				"which refuses the whole document and turns an operator typo into a converge that fails "+
				"every tick with a message about JSON.", in, got, want)
		}
	}
	if !ValidHysteria2HopInterval(DefaultHysteria2HopInterval) {
		t.Fatalf("the emitted DEFAULT %q fails the predicate that judges it — every fallback would be "+
			"refused by the very consumer it was meant to satisfy", DefaultHysteria2HopInterval)
	}
}
