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

func marshalServer(t *testing.T, s sbServer) string {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(s); err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return buf.String()
}

func strp(s string) *string { return &s }

func TestRenderServerShape(t *testing.T) {
	p := rawParams(t, `{
		"node_address":"n.invalid","donor_host":"dh.invalid","donor_sni":"ds.invalid",
		"reality_private_key":"PK","reality_public_key":"PUB","short_ids":["abcd0123"],
		"tls_sni":"t.invalid","ss_password":"SS","shadowtls_password":"STLS","clash_secret":"CS",
		"vless_reality_vision_enabled":true,"vless_reality_grpc_enabled":true,
		"vless_xhttp_tls_enabled":true,"vless_ws_tls_enabled":true,
		"shadowtls_enabled":true,"trojan_enabled":true,"trojan_password":"TR"}`)
	srv, err := RenderServer(p, []ServerClient{{Name: "alice", ID: "id-a", Password: strp("pw")}, {Name: "bob", ID: "id-b"}})
	if err != nil {
		t.Fatalf("RenderServer: %v", err)
	}
	out := marshalServer(t, srv)

	// Dual-engine: the xray-only vless-xhttp-tls inbound must be absent; shadowtls adds the detour SS in.
	var doc struct {
		Inbounds     []map[string]any `json:"inbounds"`
		Experimental struct {
			ClashAPI map[string]any `json:"clash_api"`
		} `json:"experimental"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("re-parse: %v", err)
	}
	var tags []string
	for _, in := range doc.Inbounds {
		tags = append(tags, in["tag"].(string))
	}
	want := []string{"vless-reality-vision-in", "vless-reality-grpc-in", "vless-ws-tls-in", "shadowtls-in", "shadowtls-ss-in", "trojan-in"}
	if strings.Join(tags, ",") != strings.Join(want, ",") {
		t.Errorf("inbound tags = %v\nwant %v (xhttp-tls dropped, shadowtls-ss-in kept)", tags, want)
	}
	if strings.Contains(out, "vless-xhttp-tls-in") {
		t.Errorf("server leaked the xray-only vless-xhttp-tls inbound")
	}
	// clash secret present when provisioned.
	if doc.Experimental.ClashAPI["secret"] != "CS" {
		t.Errorf("clash_api.secret = %v, want CS", doc.Experimental.ClashAPI["secret"])
	}
	// Vision user carries the flow + per-identity password fallback on trojan (alice has pw, bob falls back).
	if !strings.Contains(out, `"flow": "xtls-rprx-vision"`) {
		t.Errorf("vision flow missing")
	}
}

func TestRenderServerReachable(t *testing.T) {
	const base = `{
		"node_address":"n.invalid","donor_host":"dh.invalid","donor_sni":"ds.invalid",
		"reality_private_key":"PK","reality_public_key":"PUB","short_ids":["abcd0123"],
		"ss_password":"SS","shadowtls_password":"STLS",
		"vless_reality_vision_enabled":true,"vless_reality_grpc_enabled":true,
		"shadowsocks_enabled":true,"shadowtls_enabled":true`
	// node_bind absent (reachable=true/default) -> every PUBLIC inbound binds "::"; the detour SS stays loopback.
	srvDefault, err := RenderServer(rawParams(t, base+"}"), []ServerClient{{Name: "a", ID: "id-a"}})
	if err != nil {
		t.Fatalf("RenderServer (default): %v", err)
	}
	checkBinds(t, marshalServer(t, srvDefault), "::")
	// node_bind 127.0.0.1 (reachable=false) -> every PUBLIC inbound binds loopback; the detour stays loopback.
	srvLoop, err := RenderServer(rawParams(t, base+`,"node_bind":"127.0.0.1"}`), []ServerClient{{Name: "a", ID: "id-a"}})
	if err != nil {
		t.Fatalf("RenderServer (loopback): %v", err)
	}
	checkBinds(t, marshalServer(t, srvLoop), "127.0.0.1")
}

func checkBinds(t *testing.T, out, wantPublic string) {
	t.Helper()
	var doc struct {
		Inbounds []map[string]any `json:"inbounds"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("re-parse: %v", err)
	}
	for _, in := range doc.Inbounds {
		tag, _ := in["tag"].(string)
		listen, _ := in["listen"].(string)
		if tag == "shadowtls-ss-in" { // the hidden detour SS inbound is ALWAYS loopback (never public)
			if listen != "127.0.0.1" {
				t.Errorf("detour %s listen = %q, want 127.0.0.1", tag, listen)
			}
			continue
		}
		if listen != wantPublic {
			t.Errorf("public inbound %s listen = %q, want %q", tag, listen, wantPublic)
		}
	}
}

func TestRenderServerClashSecretOmitted(t *testing.T) {
	p := rawParams(t, `{"node_address":"n","donor_sni":"d","donor_host":"dh","reality_private_key":"P","reality_public_key":"X",
		"short_ids":["abcd0123"],"vless_reality_vision_enabled":true}`)
	srv, err := RenderServer(p, []ServerClient{{Name: "a", ID: "id"}})
	if err != nil {
		t.Fatalf("RenderServer: %v", err)
	}
	out := marshalServer(t, srv)
	if strings.Contains(out, `"secret"`) {
		t.Errorf("clash_api.secret must be OMITTED when clash_secret is unset:\n%s", out)
	}
}

func TestRenderServerFailClosed(t *testing.T) {
	// REALITY enabled but no short_ids -> fail closed (reality material present so it reaches the check).
	if _, err := RenderServer(rawParams(t, `{"node_address":"n","donor_sni":"d","donor_host":"dh","reality_private_key":"P","vless_reality_vision_enabled":true}`), nil); err == nil {
		t.Error("want short_ids error for reality with no short_ids")
	}
	// REALITY enabled but no donor_host -> fail closed (required field).
	if _, err := RenderServer(rawParams(t, `{"node_address":"n","donor_sni":"d","reality_private_key":"P","short_ids":["abcd0123"],"vless_reality_vision_enabled":true}`), nil); err == nil {
		t.Error("want required-field error for reality with no donor_host")
	}
	// own-cert ws-tls but no tls_sni -> fail closed (C03).
	if _, err := RenderServer(rawParams(t, `{"node_address":"n","vless_ws_tls_enabled":true}`), nil); err == nil {
		t.Error("want C03 error for ws-tls with empty tls_sni")
	}
	// nothing enabled -> error.
	if _, err := RenderServer(rawParams(t, `{"node_address":"n"}`), nil); err == nil {
		t.Error("want error when no protocols enabled")
	}
	// two-hop with an unknown via_user -> fail closed (C18).
	th := `{"node_address":"n","donor_sni":"d","reality_private_key":"P","reality_public_key":"X","short_ids":["abcd0123"],
		"vless_reality_vision_enabled":true,"two_hop":{"tag":"e","server":"eg","server_port":443,"sni":"egs","via_user":"ghost"}}`
	if _, err := RenderServer(rawParams(t, th), []ServerClient{{Name: "real", ID: "id"}}); err == nil {
		t.Error("want C18 error for two_hop.via_user that is not a known client")
	}
}
