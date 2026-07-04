// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
	"time"
)

func TestRenderBundleFrontAppendsFrontedEndpoint(t *testing.T) {
	p := rawParams(t, `{"node_address":"node.direct.invalid","donor_sni":"d.invalid","reality_public_key":"PUB",
		"short_ids":["abcd0123"],"tls_sni":"node.own.invalid",
		"vless_reality_vision_enabled":true,"vless_reality_vision_port":443,
		"vless_xhttp_tls_enabled":true,"vless_xhttp_tls_port":2087}`)
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	base, err := RenderBundle(p, "id-a", "", now)
	if err != nil {
		t.Fatalf("RenderBundle: %v", err)
	}
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}
	fronted, err := RenderBundleFront(p, "id-a", "", fc, now)
	if err != nil {
		t.Fatalf("RenderBundleFront: %v", err)
	}
	if len(fronted.Endpoints) != len(base.Endpoints)+1 {
		t.Fatalf("fronted bundle should add exactly one endpoint: base=%d fronted=%d", len(base.Endpoints), len(fronted.Endpoints))
	}
	fe := fronted.Endpoints[len(fronted.Endpoints)-1]
	if fe.Tag != "mycelium-vless-xhttp-tls-front" {
		t.Errorf("fronted endpoint tag = %q, want mycelium-vless-xhttp-tls-front", fe.Tag)
	}
	if fe.Priority < FrontEndpointPriorityBase {
		t.Errorf("fronted endpoint must be last-resort priority (>= %d), got %d", FrontEndpointPriorityBase, fe.Priority)
	}
	if !strings.Contains(fe.Link, "@front.op.example:443?") {
		t.Errorf("fronted endpoint link must target the front: %s", fe.Link)
	}
}

func TestRenderBundleFrontDisabledIsIdentical(t *testing.T) {
	p := rawParams(t, `{"node_address":"n.invalid","donor_sni":"d.invalid","reality_public_key":"PUB",
		"short_ids":["abcd0123"],"vless_reality_vision_enabled":true,"vless_reality_vision_port":443,
		"vless_ws_tls_enabled":true,"vless_ws_tls_port":2089,"tls_sni":"m.example.com"}`)
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	base, _ := RenderBundle(p, "id-a", "", now)
	// disabled front + a front for a not-served transport must both be no-ops.
	for _, fc := range []FrontConfig{
		{Enabled: false, Domain: "f.example", Transport: "vless-xhttp-tls"},
		{Enabled: true, Domain: "f.example", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}, // xhttp-tls not enabled here
	} {
		got, err := RenderBundleFront(p, "id-a", "", fc, now)
		if err != nil {
			t.Fatalf("RenderBundleFront: %v", err)
		}
		if len(got.Endpoints) != len(base.Endpoints) {
			t.Errorf("a disabled/not-served front must not change the bundle: base=%d got=%d", len(base.Endpoints), len(got.Endpoints))
		}
	}
}

func TestFrontLinkParamsRewritesMatchingTransport(t *testing.T) {
	base := LinkParams{
		Server: "node.direct.invalid", Port: "2087", UUID: "u1",
		TLSSNI: "node.own.invalid", XHTTPPathTLS: "/xt", WSPath: "/ws",
	}
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}
	if err := fc.Validate(); err != nil {
		t.Fatalf("fixture front invalid: %v", err)
	}
	out, fronted := FrontLinkParams("vless-xhttp-tls", base, fc)
	if !fronted {
		t.Fatal("expected the configured frontable transport to be fronted")
	}
	if out.Server != "front.op.example" || out.Port != FrontPort || out.TLSSNI != "front.op.example" {
		t.Errorf("fronted params = server=%q port=%q sni=%q, want front domain + 443 + front sni", out.Server, out.Port, out.TLSSNI)
	}
	// Untouched fields stay.
	if out.UUID != "u1" || out.XHTTPPathTLS != "/xt" {
		t.Errorf("fronting must not change uuid/path: %+v", out)
	}
	// The fronted share-link points the client at the front.
	link, err := ShareLink("vless-xhttp-tls", out)
	if err != nil {
		t.Fatalf("ShareLink: %v", err)
	}
	if !strings.Contains(link, "@front.op.example:443?") || !strings.Contains(link, "sni=front.op.example") {
		t.Errorf("fronted link does not target the front: %s", link)
	}
}

func TestFrontLinkParamsWSTLSHostAndSNI(t *testing.T) {
	base := LinkParams{Server: "node.direct.invalid", Port: "2089", UUID: "u1", TLSSNI: "node.own.invalid", WSPath: "/ws"}
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-ws-tls", Mode: FrontModeRelay}
	out, fronted := FrontLinkParams("vless-ws-tls", base, fc)
	if !fronted {
		t.Fatal("ws-tls should be fronted")
	}
	link, err := ShareLink("vless-ws-tls", out)
	if err != nil {
		t.Fatalf("ShareLink: %v", err)
	}
	// For ws-tls, the front domain must drive BOTH sni= and host=.
	if !strings.Contains(link, "sni=front.op.example") || !strings.Contains(link, "host=front.op.example") {
		t.Errorf("ws-tls fronted link must carry front domain as both sni and host: %s", link)
	}
}

func TestFrontLinkParamsNoOpCases(t *testing.T) {
	base := LinkParams{Server: "node.direct.invalid", Port: "2087", TLSSNI: "node.own.invalid"}
	cases := []struct {
		name  string
		proto string
		fc    FrontConfig
	}{
		{"disabled front", "vless-xhttp-tls", FrontConfig{Enabled: false, Domain: "f.example", Transport: "vless-xhttp-tls"}},
		{"non-matching transport (front fronts ws, render xhttp)", "vless-xhttp-tls", FrontConfig{Enabled: true, Domain: "f.example", Transport: "vless-ws-tls", Mode: FrontModeRelay}},
		{"non-frontable transport", "vless-reality-vision", FrontConfig{Enabled: true, Domain: "f.example", Transport: "vless-reality-vision", Mode: FrontModeRelay}},
		{"empty domain", "vless-xhttp-tls", FrontConfig{Enabled: true, Domain: "", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, fronted := FrontLinkParams(c.proto, base, c.fc)
			if fronted {
				t.Errorf("%s: expected NOT fronted", c.name)
			}
			if out != base {
				t.Errorf("%s: a non-fronted call must return base unchanged, got %+v", c.name, out)
			}
		})
	}
}

func TestFrontLinkParamsTerminateMode(t *testing.T) {
	// terminate mode rewrites the client dial target identically to relay (the mode is an EDGE concern).
	base := LinkParams{Server: "node.direct.invalid", Port: "2087", UUID: "u1", TLSSNI: "node.own.invalid", XHTTPPathTLS: "/xt"}
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-xhttp-tls", Mode: FrontModeTerminate, AckTerminateTradeoff: true}
	if err := fc.Validate(); err != nil {
		t.Fatalf("terminate+ack must be valid: %v", err)
	}
	out, fronted := FrontLinkParams("vless-xhttp-tls", base, fc)
	if !fronted || out.Server != "front.op.example" || out.Port != FrontPort {
		t.Errorf("terminate-mode fronting should rewrite the dial target like relay: %+v fronted=%v", out, fronted)
	}
}
