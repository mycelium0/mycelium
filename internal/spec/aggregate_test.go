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

func TestRenderAggregate(t *testing.T) {
	lp := LinkParams{Server: "h", Port: "443", UUID: "u/1", DonorSNI: "d", Pub: "k", ShortID: "s",
		TLSSNI: "t", SSPassword: "ss/p", Hy2Password: "h@", TrojanPassword: "tr&p", TUICPassword: "tu",
		GRPCServiceName: "g", XHTTPPath: "/x", XHTTPPathTLS: "/xt", WSPath: "/ws"}
	mk := func(label, proto string) AggregateInput {
		link, err := ShareLink(proto, lp)
		if err != nil {
			t.Fatalf("ShareLink(%q): %v", proto, err)
		}
		cls, _ := ClassForProto(proto)
		return AggregateInput{Label: label, Bundle: Bundle{Version: NetworkStateVersion, Endpoints: []Endpoint{
			{Tag: "mycelium-" + proto, TransportClass: cls, Region: RegionUnspecified, Priority: 0, Health: HealthUnknown, Link: link}}}}
	}
	out, err := RenderAggregate([]AggregateInput{mk("nodeA", "vless-reality-vision"), mk("nodeB", "trojan")})
	if err != nil {
		t.Fatalf("RenderAggregate: %v", err)
	}
	var prof struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal(out, &prof); err != nil {
		t.Fatalf("profile not JSON: %v", err)
	}
	// 2 proxies + urltest + selector + direct + block
	if len(prof.Outbounds) != 6 {
		t.Fatalf("outbounds = %d, want 6", len(prof.Outbounds))
	}
	if prof.Outbounds[0]["tag"] != "nodeA.vless-reality-vision" || prof.Outbounds[1]["tag"] != "nodeB.trojan" {
		t.Errorf("tags not namespaced: %v / %v", prof.Outbounds[0]["tag"], prof.Outbounds[1]["tag"])
	}
	ut := prof.Outbounds[2]
	if ut["type"] != "urltest" || ut["tag"] != "auto" {
		t.Errorf("3rd outbound not urltest/auto: %v", ut)
	}
	sel := prof.Outbounds[3]
	if sel["type"] != "selector" || sel["tag"] != "mycelium" || sel["default"] != "auto" {
		t.Errorf("4th outbound not selector/mycelium/auto: %v", sel)
	}
}

func TestRenderAggregateFailClosed(t *testing.T) {
	one := AggregateInput{Label: "a", Bundle: Bundle{Endpoints: []Endpoint{{Tag: "mycelium-x", Link: "vless://u@h:1#f"}}}}
	if _, err := RenderAggregate([]AggregateInput{one}); err == nil {
		t.Error("a single input should fail closed (>=2 required)")
	}
	link, _ := ShareLink("vless-reality-vision", LinkParams{Server: "h", Port: "443", UUID: "u", DonorSNI: "d", Pub: "k", ShortID: "s"})
	good := AggregateInput{Label: "ok", Bundle: Bundle{Endpoints: []Endpoint{{Tag: "mycelium-vless-reality-vision", TransportClass: TransportClassRealityTCP, Link: link}}}}
	// non-ASCII label
	bad := good
	bad.Label = "nодe" // Cyrillic 'о'
	if _, err := RenderAggregate([]AggregateInput{good, bad}); err == nil {
		t.Error("non-ASCII label should fail closed")
	}
	// duplicate label
	if _, err := RenderAggregate([]AggregateInput{good, good}); err == nil {
		t.Error("duplicate label should fail closed")
	}
	// scheme/class mismatch (an ss link declared reality-tcp)
	mism := AggregateInput{Label: "m", Bundle: Bundle{Endpoints: []Endpoint{
		{Tag: "mycelium-x", TransportClass: TransportClassRealityTCP, Link: "ss://2022-blake3-aes-256-gcm:p@h:8388#f"}}}}
	if _, err := RenderAggregate([]AggregateInput{good, mism}); err == nil {
		t.Error("scheme/class mismatch should fail closed")
	}
}
