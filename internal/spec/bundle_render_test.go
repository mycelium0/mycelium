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
