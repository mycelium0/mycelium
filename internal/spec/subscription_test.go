// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// marshalSub renders one client's sing-box doc the way the CLI does (so the test sees the real bytes).
func marshalSub(t *testing.T, d SubDoc) string {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(d); err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return buf.String()
}

func TestRenderSubscriptionShape(t *testing.T) {
	p := rawParams(t, `{
		"node_address":"node.example.invalid","donor_sni":"www.example.invalid","reality_public_key":"PUB",
		"short_ids":["0123abcd"],"tls_sni":"tls.example.invalid","grpc_service_name":"grpc.health.v1.Health",
		"ss_password":"SS","hysteria2_password":"HY","shadowtls_password":"STLS","trojan_password":"TR",
		"vless_reality_vision_enabled":true,"vless_reality_vision_port":443,
		"vless_reality_grpc_enabled":true,"vless_reality_grpc_port":8443,
		"vless_xhttp_tls_enabled":true,"vless_xhttp_tls_port":2087,
		"vless_ws_tls_enabled":true,"vless_ws_tls_port":2089,
		"hysteria2_enabled":true,"hysteria2_port":8444,
		"tuic_enabled":true,"tuic_port":8445,
		"shadowsocks_enabled":true,"shadowsocks_port":8388,
		"shadowtls_enabled":true,"shadowtls_port":8446,
		"trojan_enabled":true,"trojan_port":8447}`)
	clients := []SubClient{
		{Name: "alice one", ID: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", Password: "idpw"},
		{Name: "bob-2", ID: "b0b00000-0000-4000-8000-000000000000"},
	}
	subs, err := RenderSubscription(p, clients)
	if err != nil {
		t.Fatalf("RenderSubscription: %v", err)
	}
	if len(subs) != 2 {
		t.Fatalf("want 2 client subscriptions, got %d", len(subs))
	}

	// Name sanitisation: "alice one" -> "alice_one"; "bob-2" stays.
	if subs[0].Safe != "alice_one" {
		t.Errorf("safe name = %q, want alice_one", subs[0].Safe)
	}
	if subs[1].Safe != "bob-2" {
		t.Errorf("safe name = %q, want bob-2", subs[1].Safe)
	}

	sb := marshalSub(t, subs[0].Singbox)

	// Dual-engine filter (ADR-0032): vless-xhttp-tls is xray-only — it must NOT appear in the sing-box
	// client doc, and crucially no "xhttp" transport with genuine TLS leaks in. (reality-xhttp, a sing-box
	// proto, is absent here so any "xhttp" token would be the forbidden one.)
	if strings.Contains(sb, "vless-xhttp-tls") {
		t.Errorf("sing-box subscription leaked the xray-only vless-xhttp-tls outbound:\n%s", sb)
	}

	// Tags + control outbounds: the urltest "auto" lists exactly the enabled sing-box protos in order,
	// the selector prepends "auto", and direct/block close the list. ShadowTLS adds the handshake detour.
	var doc struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal([]byte(sb), &doc); err != nil {
		t.Fatalf("re-parse rendered sing-box doc: %v", err)
	}
	var tags []string
	var auto, sel map[string]any
	for _, o := range doc.Outbounds {
		switch o["tag"] {
		case "auto":
			auto = o
		case "mycelium":
			sel = o
		}
		tags = append(tags, o["tag"].(string))
	}
	wantOrder := []string{
		"vless-reality-vision", "vless-reality-grpc", "vless-ws-tls", "hysteria2", "tuic",
		"shadowsocks", "shadowtls", "trojan", "shadowtls-handshake", "auto", "mycelium", "direct", "block",
	}
	if strings.Join(tags, ",") != strings.Join(wantOrder, ",") {
		t.Errorf("outbound tag order =\n  %v\nwant\n  %v", tags, wantOrder)
	}
	// urltest "auto" lists the proxy tags (no detour, no control outbounds).
	autoList := toStrings(auto["outbounds"])
	wantAuto := []string{"vless-reality-vision", "vless-reality-grpc", "vless-ws-tls", "hysteria2", "tuic", "shadowsocks", "shadowtls", "trojan"}
	if strings.Join(autoList, ",") != strings.Join(wantAuto, ",") {
		t.Errorf("urltest.outbounds = %v, want %v", autoList, wantAuto)
	}
	if got := toStrings(sel["outbounds"]); got[0] != "auto" || sel["default"] != "auto" {
		t.Errorf("selector must prepend auto + default auto, got outbounds[0]=%q default=%v", got[0], sel["default"])
	}

	// Vision outbound key shape: flow is the vision flow and is PRESENT (jq emits it); no transport key.
	if !strings.Contains(sb, `"flow": "xtls-rprx-vision"`) {
		t.Errorf("vision flow missing/renamed:\n%s", sb)
	}
	// TUIC password falls back to the UUID; the client with a password uses it for ss/hy2.
	if !strings.Contains(sb, `"congestion_control": "bbr"`) {
		t.Errorf("tuic congestion_control missing")
	}

	// Clash-Meta: Vision/gRPC/HY2/TUIC/SS/Trojan present; ShadowTLS, WS and XHTTP families absent.
	clash := subs[0].Clash
	for _, want := range []string{"mycelium-alice one-vision", "mycelium-alice one-grpc", "mycelium-alice one-hysteria2", "mycelium-alice one-tuic", "mycelium-alice one-ss2022", "mycelium-alice one-trojan", "proxy-groups:"} {
		if !strings.Contains(clash, want) {
			t.Errorf("clash yaml missing %q", want)
		}
	}
	for _, bad := range []string{"ws-tls", "xhttp", "shadowtls"} {
		if strings.Contains(clash, bad) {
			t.Errorf("clash yaml unexpectedly contains %q (Clash-Meta does not support it)", bad)
		}
	}
}

// TestRenderSubscriptionNameEdges documents the valid-name contract: the Go port skips an empty name
// (which identity add rejects upstream) and sanitises a backslash/control char in the actual name —
// deliberately NOT reproducing the shell's @tsv/whitespace-IFS quirks on those pathological inputs.
func TestRenderSubscriptionNameEdges(t *testing.T) {
	p := rawParams(t, `{"node_address":"n","donor_sni":"d","reality_public_key":"P","short_ids":["abcd0123"],
		"vless_reality_vision_enabled":true,"vless_reality_vision_port":443}`)
	subs, err := RenderSubscription(p, []SubClient{
		{Name: "ok", ID: "id-ok"},
		{Name: "", ID: "id-empty"}, // skipped
		{Name: "a\\b\tc", ID: "id-bs"},
	})
	if err != nil {
		t.Fatalf("RenderSubscription: %v", err)
	}
	if len(subs) != 2 {
		t.Fatalf("empty name must be skipped: want 2 subs, got %d", len(subs))
	}
	if subs[1].Safe != "a_b_c" {
		t.Errorf("backslash+tab sanitised name = %q, want a_b_c", subs[1].Safe)
	}
}

func toStrings(v any) []string {
	arr, _ := v.([]any)
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		s, _ := e.(string)
		out = append(out, s)
	}
	return out
}

func TestRenderSubscriptionFailClosed(t *testing.T) {
	// C03: an own-cert family (ws-tls) enabled but no tls_sni -> fail closed.
	p := rawParams(t, `{"node_address":"n","donor_sni":"d","vless_ws_tls_enabled":true,"vless_ws_tls_port":2089}`)
	if _, err := RenderSubscription(p, []SubClient{{Name: "a", ID: "id"}}); err == nil {
		t.Error("want C03 error for ws-tls with empty tls_sni, got nil")
	}
	// Only an xray-engine proto enabled -> nothing for the sing-box subscription to emit.
	p2 := rawParams(t, `{"node_address":"n","tls_sni":"t","vless_xhttp_tls_enabled":true,"vless_xhttp_tls_port":2087}`)
	if _, err := RenderSubscription(p2, []SubClient{{Name: "a", ID: "id"}}); err == nil {
		t.Error("want error when only xray-engine protos are enabled, got nil")
	}
	// Nothing enabled -> error.
	if _, err := RenderSubscription(rawParams(t, `{"node_address":"n"}`), []SubClient{{Name: "a", ID: "id"}}); err == nil {
		t.Error("want error when no protocols enabled, got nil")
	}
}
