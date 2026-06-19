// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"errors"
	"strings"
	"testing"
)

func TestUriEncodeMatchesJqAtUri(t *testing.T) {
	// Golden cases verified against `printf '%s' V | jq -sRr '@uri'` (the shell myc_uri_encode):
	// unreserved [A-Za-z0-9-_.~] pass through; everything else -> %XX uppercase, byte-wise.
	cases := map[string]string{
		"":               "",
		"abcXYZ090":      "abcXYZ090",
		"-_.~":           "-_.~",
		"a b":            "a%20b",
		"/api?x=1#frag":  "%2Fapi%3Fx%3D1%23frag",
		"a+b=c&d":        "a%2Bb%3Dc%26d",
		"p@ss:w/d":       "p%40ss%3Aw%2Fd",
		"grpc.health.v1": "grpc.health.v1",
		"héllo":          "h%C3%A9llo", // multibyte: byte-wise %XX of the UTF-8 bytes
	}
	for in, want := range cases {
		if got := uriEncode(in); got != want {
			t.Errorf("uriEncode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestShareLinkGolden(t *testing.T) {
	p := LinkParams{
		Server: "node.example.invalid", Port: "443", UUID: "11111111-2222-3333-4444-555555555555",
		DonorSNI: "www.microsoft.com", Pub: "PUBKEY_aB-cd", ShortID: "0e6e7757", TLSSNI: "edge.example.invalid",
		SSPassword: "ss/pw+1", Hy2Password: "hy2pw", TrojanPassword: "trpw", TUICPassword: "tuicpw",
		GRPCServiceName: "grpc.health.v1.Health", XHTTPPath: "/x", XHTTPPathTLS: "/xt", WSPath: "/ws",
	}
	want := map[string]string{
		"vless-reality-vision": "vless://11111111-2222-3333-4444-555555555555@node.example.invalid:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBKEY_aB-cd&sid=0e6e7757&type=tcp#mycelium-vless-reality-vision",
		"vless-reality-grpc":   "vless://11111111-2222-3333-4444-555555555555@node.example.invalid:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBKEY_aB-cd&sid=0e6e7757&type=grpc&serviceName=grpc.health.v1.Health#mycelium-vless-reality-grpc",
		"vless-ws-tls":         "vless://11111111-2222-3333-4444-555555555555@node.example.invalid:443?encryption=none&security=tls&sni=edge.example.invalid&fp=chrome&alpn=http%2F1.1&type=ws&host=edge.example.invalid&path=%2Fws#mycelium-vless-ws-tls",
		"shadowsocks":          "ss://2022-blake3-aes-256-gcm:ss%2Fpw%2B1@node.example.invalid:443#mycelium-shadowsocks",
	}
	for proto, w := range want {
		got, err := ShareLink(proto, p)
		if err != nil {
			t.Fatalf("ShareLink(%q): %v", proto, err)
		}
		if got != w {
			t.Errorf("ShareLink(%q)\n got=%q\nwant=%q", proto, got, w)
		}
	}
}

func TestShareLinkAllRegistryProtosRenderOrSkip(t *testing.T) {
	// Every link-bearing registry proto (non-empty Scheme) must produce a link; amneziawg + unknown error.
	p := LinkParams{Server: "h", Port: "1", UUID: "u", DonorSNI: "d", Pub: "k", ShortID: "s", TLSSNI: "t",
		SSPassword: "a", Hy2Password: "b", TrojanPassword: "c", TUICPassword: "e", GRPCServiceName: "g",
		XHTTPPath: "/x", XHTTPPathTLS: "/y", WSPath: "/w"}
	for _, d := range TransportRegistry() {
		_, err := ShareLink(d.Proto, p)
		if d.Scheme != "" && err != nil {
			t.Errorf("ShareLink(%q): link-bearing proto errored: %v", d.Proto, err)
		}
		if d.Scheme == "" && err == nil {
			t.Errorf("ShareLink(%q): non-link proto should error", d.Proto)
		}
	}
	if _, err := ShareLink("nope", p); !errors.Is(err, ErrUnknownEnum) {
		t.Errorf("ShareLink(unknown) error = %v, want ErrUnknownEnum", err)
	}
}

func TestShareLinkEncodesReservedChars(t *testing.T) {
	// A reserved char in a value must be encoded, never shift the URI boundaries.
	p := LinkParams{Server: "h", Port: "1", UUID: "a#b&c", DonorSNI: "s", Pub: "k", ShortID: "i"}
	got, err := ShareLink("vless-reality-vision", p)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got[:strings.Index(got, "?")], "#") || strings.Count(got, "#") != 1 {
		t.Errorf("reserved chars in uuid leaked structural delimiters: %q", got)
	}
	if !strings.Contains(got, "a%23b%26c") {
		t.Errorf("uuid not encoded: %q", got)
	}
}
