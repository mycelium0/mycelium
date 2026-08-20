// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func rawParams(t *testing.T, obj string) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(obj), &m); err != nil {
		t.Fatalf("fixture params: %v", err)
	}
	return m
}

func TestRenderBundleShape(t *testing.T) {
	p := rawParams(t, `{
		"node_address":"node.example.invalid","donor_sni":"www.example.invalid","reality_public_key":"PUB",
		"short_ids":["0123abcd"],"tls_sni":"tls.example.invalid","grpc_service_name":"grpc.health.v1.Health",
		"vless_reality_vision_enabled":true,"vless_reality_vision_port":443,
		"vless_reality_grpc_enabled":true,"vless_reality_grpc_port":8443,
		"shadowsocks_enabled":true,"shadowsocks_port":8388}`)
	at, _ := time.Parse(time.RFC3339, "2026-06-19T12:00:00Z")
	b, err := RenderBundle(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "idpw", at)
	if err != nil {
		t.Fatalf("RenderBundle: %v", err)
	}
	if b.Version != NetworkStateVersion {
		t.Errorf("version = %d, want %d", b.Version, NetworkStateVersion)
	}
	if len(b.Endpoints) != 3 {
		t.Fatalf("endpoints = %d, want 3", len(b.Endpoints))
	}
	// Order = registry priority order; vision(0), grpc(1), shadowsocks(7).
	wantTag := []string{"mycelium-vless-reality-vision", "mycelium-vless-reality-grpc", "mycelium-shadowsocks"}
	wantPrio := []int{0, 1, 7}
	for i, ep := range b.Endpoints {
		if ep.Tag != wantTag[i] {
			t.Errorf("endpoint[%d].Tag = %q, want %q", i, ep.Tag, wantTag[i])
		}
		if ep.Priority != wantPrio[i] {
			t.Errorf("endpoint[%d].Priority = %d, want %d", i, ep.Priority, wantPrio[i])
		}
		if ep.Health != HealthUnknown {
			t.Errorf("endpoint[%d].Health = %q, want unknown", i, ep.Health)
		}
		if ep.Region != RegionBucket("unspecified") {
			t.Errorf("endpoint[%d].Region = %q, want unspecified", i, ep.Region)
		}
		if ep.Link == "" {
			t.Errorf("endpoint[%d].Link is empty", i)
		}
	}
	// The rendered bundle must pass the authoritative validator (the P1 round-trip).
	if err := b.Validate(); err != nil {
		t.Errorf("RenderBundle output fails Bundle.Validate: %v", err)
	}
}

func TestRenderBundleFailClosed(t *testing.T) {
	at := time.Now()
	// empty first-client id
	p := rawParams(t, `{"node_address":"h","vless_reality_vision_enabled":true}`)
	if _, err := RenderBundle(p, "", "pw", at); err == nil {
		t.Error("empty client id should fail closed")
	}
	// own-cert family enabled but no explicit tls_sni (C03)
	p = rawParams(t, `{"node_address":"h","donor_sni":"d","vless_ws_tls_enabled":true,"vless_ws_tls_port":2089}`)
	if _, err := RenderBundle(p, "id", "pw", at); err == nil || !strings.Contains(err.Error(), "tls_sni") {
		t.Errorf("own-cert family without tls_sni should fail closed, got %v", err)
	}
	// no transports enabled
	p = rawParams(t, `{"node_address":"h"}`)
	if _, err := RenderBundle(p, "id", "pw", at); err == nil {
		t.Error("zero enabled transports should fail closed")
	}
	// out-of-range port (C09)
	p = rawParams(t, `{"node_address":"h","vless_reality_vision_enabled":true,"vless_reality_vision_port":70000}`)
	if _, err := RenderBundle(p, "id", "pw", at); err == nil {
		t.Error("out-of-range port should fail closed")
	}
}

// TestRenderBundleAWGEndpoint pins the three things about the AmneziaWG endpoint that the byte-equivalence
// gate cannot see on its own: that it is judged BY the RP-0013 floor rather than appended after it, that
// its priority is 0 (the shell's literal, NOT the registry index — amneziawg is last in the registry), and
// that it carries the client config verbatim.
func TestRenderBundleAWGEndpoint(t *testing.T) {
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	// The DEFAULT profile: two REALITY protos, which collapse to ONE block family.
	p := map[string]json.RawMessage{
		"node_address":                json.RawMessage(`"n.example.invalid"`),
		"donor_host":                  json.RawMessage(`"www.example.invalid"`),
		"donor_sni":                   json.RawMessage(`"www.example.invalid"`),
		"reality_public_key":          json.RawMessage(`"PK"`),
		"short_ids":                   json.RawMessage(`["0123abcd"]`),
		"tls_sni":                     json.RawMessage(`"n.example.invalid"`),
		"grpc_service_name":           json.RawMessage(`"g"`),
		"vless_reality_vision_enabled": json.RawMessage(`true`),
		"vless_reality_grpc_enabled":   json.RawMessage(`true`),
	}

	// Without the AWG config this node is below the floor — that is what makes the next case meaningful.
	if _, err := RenderBundle(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "pw", at); err == nil {
		t.Fatal("the default two-REALITY profile rendered without AmneziaWG; it spans one family and RP-0013 must refuse it. Every assertion below would then prove nothing.")
	}

	const conf = "[Interface]\nPrivateKey = aB+cd/12=\nAddress = 10.8.0.2/32\n\n[Peer]\nPublicKey = XY&Z=\n"
	b, err := RenderBundleWith(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "pw",
		BundleOptions{AWGClientConf: conf}, at)
	if err != nil {
		t.Fatalf("the same node WITH its AmneziaWG endpoint was refused: %v. The endpoint is how a default node reaches its second block family, so it has to be appended before the floor is judged, not after.", err)
	}

	var got *Endpoint
	for i := range b.Endpoints {
		if b.Endpoints[i].Tag == "mycelium-amneziawg" {
			got = &b.Endpoints[i]
		}
	}
	if got == nil {
		t.Fatalf("no mycelium-amneziawg endpoint in %d rendered endpoints", len(b.Endpoints))
	}
	if got.Link != conf {
		t.Errorf("the client config was not carried verbatim:\n got %q\nwant %q", got.Link, conf)
	}
	if got.Priority != 0 {
		t.Errorf("priority = %d, want 0 — the shell writes a literal 0 here, not the registry index (amneziawg is LAST in the registry, so an index would be a silent divergence the byte gate would catch only if a fixture happened to carry it)", got.Priority)
	}
	if got.TransportClass != TransportClassAmneziaWGUDP {
		t.Errorf("transport_class = %q, want %q", got.TransportClass, TransportClassAmneziaWGUDP)
	}
	if !b.IndependentFallbackOK() {
		t.Error("the bundle with AmneziaWG still does not clear the independent-family floor")
	}
	// And it must be additive: no AWG config leaves the render exactly as it was.
	if _, err := RenderBundleWith(p, "a1b2c3d4-e5f6-7890-abcd-ef0123456789", "pw", BundleOptions{}, at); err == nil {
		t.Error("BundleOptions{} rendered the one-family node — the empty options must behave exactly like RenderBundle")
	}
}
