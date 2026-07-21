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
