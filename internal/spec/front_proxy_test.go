// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
)

func TestRenderFrontProxyRelay(t *testing.T) {
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}
	conf, err := RenderFrontProxy(fc, "node.direct.invalid", "2087")
	if err != nil {
		t.Fatalf("RenderFrontProxy relay: %v", err)
	}
	for _, want := range []string{"stream {", "ssl_preread on;", `$ssl_preread_server_name`, `"front.op.example"`, `"node.direct.invalid:2087"`, "proxy_pass $mycelium_front_upstream;"} {
		if !strings.Contains(conf, want) {
			t.Errorf("relay config missing %q:\n%s", want, conf)
		}
	}
	// relay must NOT terminate TLS (no ssl_certificate, no http server).
	if strings.Contains(conf, "ssl_certificate") || strings.Contains(conf, "listen 443 ssl") {
		t.Errorf("relay config must not terminate TLS:\n%s", conf)
	}
}

func TestRenderFrontProxyTerminate(t *testing.T) {
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-ws-tls", Mode: FrontModeTerminate, AckTerminateTradeoff: true}
	conf, err := RenderFrontProxy(fc, "node.direct.invalid", "2089")
	if err != nil {
		t.Fatalf("RenderFrontProxy terminate: %v", err)
	}
	for _, want := range []string{"http {", "listen 443 ssl;", "server_name front.op.example;", "ssl_certificate", "proxy_pass https://node.direct.invalid:2089;", "Upgrade $http_upgrade", "WARNING"} {
		if !strings.Contains(conf, want) {
			t.Errorf("terminate config missing %q:\n%s", want, conf)
		}
	}
}

func TestRenderFrontProxyTerminateNeedsAck(t *testing.T) {
	// terminate without the ack must fail closed (Validate rejects it).
	fc := FrontConfig{Enabled: true, Domain: "f.example", Transport: "vless-xhttp-tls", Mode: FrontModeTerminate}
	if _, err := RenderFrontProxy(fc, "n.invalid", "2087"); err == nil {
		t.Error("terminate without ack_terminate_tradeoff must fail closed")
	}
}

func TestRenderFrontProxyConfigInjectionGuard(t *testing.T) {
	bad := []struct {
		name, domain, node string
	}{
		{"domain with semicolon", "f.example;return 200", "n.invalid"},
		{"domain with space+brace", "f.example } server {", "n.invalid"},
		{"node with semicolon", "f.example", "n.invalid; proxy_pass evil"},
		{"domain with quote", "f.\"example", "n.invalid"},
	}
	for _, c := range bad {
		fc := FrontConfig{Enabled: true, Domain: c.domain, Transport: "vless-xhttp-tls", Mode: FrontModeRelay}
		if _, err := RenderFrontProxy(fc, c.node, "2087"); err == nil {
			t.Errorf("%s: expected the config-injection guard to reject it", c.name)
		}
	}
	// A bracketed IPv6 literal is a legitimate host.
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}
	if _, err := RenderFrontProxy(fc, "[2001:db8::1]", "2087"); err != nil {
		t.Errorf("a bracketed IPv6 node address must be accepted: %v", err)
	}
}

func TestRenderFrontProxyFailClosed(t *testing.T) {
	// disabled front -> error.
	if _, err := RenderFrontProxy(FrontConfig{Enabled: false, Domain: "f", Transport: "vless-xhttp-tls"}, "n", "2087"); err == nil {
		t.Error("disabled front must not render an edge proxy")
	}
	// non-frontable transport -> Validate error.
	if _, err := RenderFrontProxy(FrontConfig{Enabled: true, Domain: "f.example", Transport: "vless-reality-vision", Mode: FrontModeRelay}, "n.invalid", "2087"); err == nil {
		t.Error("a non-frontable transport must fail closed")
	}
	// bad node port -> error.
	if _, err := RenderFrontProxy(FrontConfig{Enabled: true, Domain: "f.example", Transport: "vless-xhttp-tls", Mode: FrontModeRelay}, "n.invalid", "99999"); err == nil {
		t.Error("an out-of-range node port must fail closed")
	}
}

func TestFrontProxyFromParams(t *testing.T) {
	fc := FrontConfig{Enabled: true, Domain: "front.op.example", Transport: "vless-ws-tls", Mode: FrontModeRelay}
	p := rawParams(t, `{"node_address":"node.direct.invalid","vless_ws_tls_port":2089}`)
	conf, err := FrontProxyFromParams(fc, p)
	if err != nil {
		t.Fatalf("FrontProxyFromParams: %v", err)
	}
	if !strings.Contains(conf, `"node.direct.invalid:2089"`) {
		t.Errorf("resolved upstream missing from config:\n%s", conf)
	}
	// default port when the param is absent (registry default 2089 for ws-tls).
	conf2, err := FrontProxyFromParams(fc, rawParams(t, `{"node_address":"node.direct.invalid"}`))
	if err != nil {
		t.Fatalf("FrontProxyFromParams default port: %v", err)
	}
	if !strings.Contains(conf2, "node.direct.invalid:2089") {
		t.Errorf("default ws-tls port (2089) not used:\n%s", conf2)
	}
	// missing node_address -> fail closed.
	if _, err := FrontProxyFromParams(fc, rawParams(t, `{}`)); err == nil {
		t.Error("missing node_address must fail closed")
	}
}
