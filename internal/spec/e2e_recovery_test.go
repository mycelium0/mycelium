// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"testing"
	"time"
)

// baseE2EParams returns a valid params body with the fixed base fields every REALITY/TLS render needs
// (mirrors the proven TestRenderBundleShape fixture); the caller appends the per-proto enable flags.
func baseE2EParams(t *testing.T, enables string) map[string]json.RawMessage {
	t.Helper()
	return rawParams(t, `{
		"node_address":"node.example.invalid","donor_sni":"www.example.invalid","reality_public_key":"PUB",
		"short_ids":["0123abcd"],"tls_sni":"tls.example.invalid","grpc_service_name":"grpc.health.v1.Health"`+enables+`}`)
}

var e2eAt, _ = time.Parse(time.RFC3339, "2026-07-03T12:00:00Z")

// TestBundleIndependentFallbackOK: a served bundle that spans >= 2 DISTINCT transport families satisfies
// the RP-0013 e2e recovery contract (a single-family block leaves the client an independent fallback).
func TestBundleIndependentFallbackOK(t *testing.T) {
	// vision + grpc (both RealityTCP — ONE family) + shadowsocks (ShadowsocksTCP — a SECOND family).
	p := baseE2EParams(t, `,
		"vless_reality_vision_enabled":true,"vless_reality_grpc_enabled":true,
		"shadowsocks_enabled":true,"shadowsocks_port":8388`)
	b, err := RenderBundle(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "idpw", e2eAt)
	if err != nil {
		t.Fatalf("RenderBundle: %v", err)
	}
	fams := b.DistinctClasses()
	if len(fams) < 2 {
		t.Fatalf("distinct families = %v, want >= 2", fams)
	}
	if !b.IndependentFallbackOK() {
		t.Fatalf("a bundle spanning families %v must satisfy the e2e fallback contract", fams)
	}
	// Blocking one WHOLE family must still leave >= 1 endpoint on another (the client's live fallback).
	for _, blocked := range fams {
		survivors := 0
		for _, ep := range b.Endpoints {
			if ep.TransportClass != blocked {
				survivors++
			}
		}
		if survivors == 0 {
			t.Errorf("blocking family %q removes the client's last path — not recovery-safe", blocked)
		}
	}
}

// TestBundleIndependentFallbackSingleFamily: a bundle of MANY endpoints in ONE family is NOT recovery-safe
// — REALITY Vision + gRPC share a handshake/donor/keypair surface, so one block takes them together. The
// invariant must reject it (it is the single-point-of-block the contract exists to forbid).
func TestBundleIndependentFallbackSingleFamily(t *testing.T) {
	// (a) The PURE invariant rejects a single-family bundle: Vision + gRPC are ONE family (RealityTCP) —
	// shared handshake/donor/keypair — so one block takes them together, not recovery-safe.
	b := Bundle{Version: NetworkStateVersion, Endpoints: []Endpoint{
		{Tag: "mycelium-vless-reality-vision", TransportClass: TransportClassRealityTCP},
		{Tag: "mycelium-vless-reality-grpc", TransportClass: TransportClassRealityTCP},
	}}
	if got := b.DistinctClasses(); len(got) != 1 {
		t.Fatalf("vision+grpc must be ONE family (RealityTCP), got %v", got)
	}
	if b.IndependentFallbackOK() {
		t.Fatal("a single-family bundle (REALITY-only) must FAIL the e2e fallback contract (single point of block)")
	}
	// (b) SERVE-TIME enforcement (RP-0013 AC-2): RenderBundle itself REFUSES to emit a single-family bundle
	// fail-closed, so a node never publishes an unrecoverable subscription.
	p := baseE2EParams(t, `,
		"vless_reality_vision_enabled":true,"vless_reality_grpc_enabled":true`)
	if _, err := RenderBundle(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "idpw", e2eAt); err == nil {
		t.Fatal("RenderBundle must fail closed on a single-family (REALITY-only) params set (RP-0013 AC-2 / AC-6)")
	}
}

// TestBundleBlockFamilyFold (Audit-0008 S1-3): two DISTINCT own-cert-TLS classes are NOT an independent
// fallback for one another — after RP-0015 they share the node's ONE tls_sni AND the ONE uTLS ClientHello
// preset, so a single SNI/fingerprint-keyed block on the client→node handshake takes them together. The
// recovery contract must count BLOCK families, not raw classes, and reject a config of only own-cert-TLS.
func TestBundleBlockFamilyFold(t *testing.T) {
	// (a) ws-tls + trojan-tls: TWO distinct classes, but ONE block family (both own-cert TLS, shared SNI+preset).
	own := Bundle{Version: NetworkStateVersion, Endpoints: []Endpoint{
		{Tag: "mycelium-ws-tls", TransportClass: TransportClassWSTLS},
		{Tag: "mycelium-trojan-tls", TransportClass: TransportClassTrojanTLS},
	}}
	if got := own.DistinctClasses(); len(got) != 2 {
		t.Fatalf("ws-tls + trojan are 2 distinct CLASSES, got %v", got)
	}
	if got := own.DistinctBlockFamilies(); len(got) != 1 || got[0] != TransportClass("own-tls-sni") {
		t.Fatalf("ws-tls + trojan must fold to ONE block family [own-tls-sni], got %v", got)
	}
	if own.IndependentFallbackOK() {
		t.Fatal("two own-cert-TLS classes share SNI+preset — one block takes both; must FAIL the fallback contract")
	}
	// (b) ws-tls + reality-tcp: own-cert TLS vs borrowed-donor REALITY — genuinely independent block axes.
	mixed := Bundle{Version: NetworkStateVersion, Endpoints: []Endpoint{
		{Tag: "mycelium-ws-tls", TransportClass: TransportClassWSTLS},
		{Tag: "mycelium-vless-reality-vision", TransportClass: TransportClassRealityTCP},
	}}
	if !mixed.IndependentFallbackOK() {
		t.Fatalf("own-cert-TLS + REALITY are independent block families %v — must satisfy the fallback contract", mixed.DistinctBlockFamilies())
	}
}

// TestBundleDistinctClassesDeterministic: the family set is first-seen (registry-priority) order and stable.
func TestBundleDistinctClassesDeterministic(t *testing.T) {
	p := baseE2EParams(t, `,
		"vless_reality_vision_enabled":true,"shadowsocks_enabled":true,"shadowsocks_port":8388`)
	b, err := RenderBundle(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "idpw", e2eAt)
	if err != nil {
		t.Fatalf("RenderBundle: %v", err)
	}
	got := b.DistinctClasses()
	if len(got) != 2 || got[0] != TransportClassRealityTCP || got[1] != TransportClassShadowsocksTCP {
		t.Fatalf("distinct classes = %v, want [reality-tcp shadowsocks-tcp] in registry order", got)
	}
}
