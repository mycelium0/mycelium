// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"testing"
)

func TestUriDecodeRoundTrip(t *testing.T) {
	for _, s := range []string{"", "plain", "a/b?c#d&e=f", "p@ss:w+d", "/x?a=1", "héllo", "a%b"} {
		if got := uriDecode(uriEncode(s)); got != s {
			t.Errorf("uriDecode(uriEncode(%q)) = %q, want round-trip", s, got)
		}
	}
}

func TestOutboundFromLinkGolden(t *testing.T) {
	// A vless+grpc link parses to the documented sing-box outbound (compact, key order pinned).
	link := "vless://uid%2F1@h:8443?encryption=none&security=reality&sni=s&fp=chrome&pbk=PUB&sid=SID&type=grpc&serviceName=svc#frag"
	ob, err := OutboundFromLink("node-grpc", link)
	if err != nil || ob == nil {
		t.Fatalf("OutboundFromLink: ob=%v err=%v", ob, err)
	}
	want := `{"type":"vless","tag":"node-grpc","server":"h","server_port":8443,"uuid":"uid/1","flow":"","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"s","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"PUB","short_id":"SID"}},"transport":{"type":"grpc","service_name":"svc"}}`
	if string(ob) != want {
		t.Errorf("outbound\n got=%s\nwant=%s", ob, want)
	}
}

func TestOutboundFromLinkShadowTLSAndUnknownAreNull(t *testing.T) {
	// A ShadowTLS ss-link cannot be faithfully reconstructed -> fail closed (null).
	stls := "ss://2022-blake3-aes-256-gcm:pw@h:8446?plugin=shadow-tls&sni=donor#frag"
	if ob, err := OutboundFromLink("t", stls); err != nil || ob != nil {
		t.Errorf("shadowtls link: ob=%v err=%v, want nil,nil", ob, err)
	}
	// A plain ss-link (no plugin) DOES parse.
	ss := "ss://2022-blake3-aes-256-gcm:pw%2F1@h:8388#frag"
	if ob, _ := OutboundFromLink("t", ss); ob == nil {
		t.Errorf("plain ss link parsed to null, want an outbound")
	}
	// An unknown scheme -> null.
	if ob, _ := OutboundFromLink("t", "vmess://x@h:1#f"); ob != nil {
		t.Errorf("unknown scheme: ob=%v, want nil", ob)
	}
}

// TestShareLinkOutboundRoundTrip proves the encode->parse round-trip recovers the connection coordinates
// for every link-bearing transport (ShareLink is the inverse of OutboundFromLink).
func TestShareLinkOutboundRoundTrip(t *testing.T) {
	p := LinkParams{Server: "node.example.invalid", Port: "8443", UUID: "uid/1+2 a", DonorSNI: "d", Pub: "k",
		ShortID: "s", TLSSNI: "t.example.invalid", SSPassword: "ss/p+1", Hy2Password: "h@2", TrojanPassword: "tr&3",
		TUICPassword: "tu?4", GRPCServiceName: "g.h.v1", XHTTPPath: "/x?a=1", XHTTPPathTLS: "/xt#y", WSPath: "/ws&z"}
	for _, d := range TransportRegistry() {
		if d.Scheme == "" {
			continue
		}
		link, err := ShareLink(d.Proto, p)
		if err != nil {
			t.Fatalf("ShareLink(%q): %v", d.Proto, err)
		}
		ob, err := OutboundFromLink("tag", link)
		if err != nil {
			t.Fatalf("OutboundFromLink(%q): %v", d.Proto, err)
		}
		if d.Proto == "shadowtls" { // fail-closed null by design
			if ob != nil {
				t.Errorf("%q: expected null outbound", d.Proto)
			}
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(ob, &m); err != nil {
			t.Fatalf("%q: outbound not JSON: %v", d.Proto, err)
		}
		if m["server"] != "node.example.invalid" {
			t.Errorf("%q: server = %v, want node.example.invalid", d.Proto, m["server"])
		}
		if m["server_port"] != float64(8443) {
			t.Errorf("%q: server_port = %v, want 8443", d.Proto, m["server_port"])
		}
	}
}
