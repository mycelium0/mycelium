// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// RenderSubscription is the Go-owned port of the shell `myc_sb_render_subscription`
// (control/lib/render_singbox.sh), RP-0008 P3-d. Per client it emits, byte-identically to the shell,
// two files:
//
//   - <safe>.singbox.json — one sing-box outbound per ENABLED, sing-box-ENGINE protocol (in registry
//     priority order), the ShadowTLS handshake detour when ShadowTLS is on, plus a urltest "auto", a
//     "mycelium" selector, and direct/block outbounds.
//   - <safe>.clash.yaml — one Clash-Meta proxy per Clash-supported enabled protocol (REALITY Vision/gRPC,
//     Hysteria2, TUIC, Shadowsocks, Trojan; ShadowTLS / XHTTP / WS are not represented by Clash-Meta and
//     are intentionally skipped), plus a url-test + select proxy-group.
//
// Dual-engine (ADR-0032): the enabled set is filtered to the sing-box ENGINE — an xray-only proto
// (vless-xhttp-tls) is dropped, because a sing-box client cannot dial the xhttp transport (the Xray
// client dials it instead). Resolution mirrors the shell EXACTLY (CONFLICTING_SOURCE_OF_TRUTH): the
// per-identity password falls back to the shared protocol secret (TUIC uses the UUID); the own-cert
// genuine-TLS families fail closed without an explicit tls_sni (C03). Pure + deterministic. The
// subscription_go_equiv gate pins the byte-equivalence; until green the shell stays authoritative.
func RenderSubscription(params map[string]json.RawMessage, clients []SubClient) ([]ClientSubscription, error) {
	// Pre-filter enabled set: every params-toggled proto that is on (sing-box + xray engines, registry
	// order — the shell's myc_sb_enabled_list over MYC_SB_PROTOS).
	var enabledAll []ProtoDescriptor
	for i := range transportRegistry {
		d := transportRegistry[i]
		if d.EnableKey == "" || !paramBool(params, d.EnableKey) {
			continue
		}
		enabledAll = append(enabledAll, d)
	}
	if len(enabledAll) == 0 {
		return nil, fmt.Errorf("subscription: no protocols enabled in params")
	}
	// Keep only the sing-box-ENGINE protos (drop e.g. vless-xhttp-tls — the Xray client dials it).
	var enabled []ProtoDescriptor
	for _, d := range enabledAll {
		if d.Engine == EngineSingBox {
			enabled = append(enabled, d)
		}
	}
	if len(enabled) == 0 {
		return nil, fmt.Errorf("subscription: no sing-box-dialable protocols enabled (only xray-engine protos were on)")
	}

	// Shared connection parameters.
	nodeAddr := paramStr(params, "node_address", "")
	donorSNI := paramStr(params, "donor_sni", "")
	tlsFallback := donorSNI
	if tlsFallback == "" {
		tlsFallback = "localhost"
	}
	// C03 fail-closed: an own-cert genuine-TLS family in the enabled set REQUIRES an explicit tls_sni.
	for _, d := range enabled {
		if d.Proto == "vless-ws-tls" || d.Proto == "vless-xhttp-tls" {
			if paramStr(params, "tls_sni", "") == "" {
				return nil, fmt.Errorf("subscription: an own-cert genuine-TLS family (vless-xhttp-tls/vless-ws-tls) is enabled but params.tls_sni is empty — set params.tls_sni (never fall back to donor_sni)")
			}
		}
	}
	pub := paramStr(params, "reality_public_key", "")
	shortFirst := firstShortID(params)
	tlsSNI := paramStr(params, "tls_sni", tlsFallback)
	grpcService := paramStr(params, "grpc_service_name", "grpc")
	xhttpPath := paramStr(params, "xhttp_path", "/")
	// (xhttp_path_tls is intentionally not resolved: vless-xhttp-tls is an xray-engine proto, filtered out
	// of the sing-box subscription above, so no sing-box outbound dials it.)
	wsPath := paramStr(params, "ws_path", "/ws")

	ssPassword := paramStr(params, "ss_password", "")
	trojanPassword := paramStr(params, "trojan_password", "")
	hysteria2Password := paramStr(params, "hysteria2_password", "")
	shadowtlsPassword := paramStr(params, "shadowtls_password", "")

	// Resolved ports, keyed by proto (registry default when the param is absent).
	portOf := func(proto string) (int, error) {
		for i := range transportRegistry {
			if transportRegistry[i].Proto == proto {
				d := transportRegistry[i]
				s := paramStr(params, d.PortKey, strconv.Itoa(d.DefaultPort))
				p, err := strconv.Atoi(s)
				if err != nil {
					return 0, fmt.Errorf("subscription: port for %q is not an integer (%q)", proto, s)
				}
				return p, nil
			}
		}
		return 0, fmt.Errorf("subscription: unknown proto %q", proto)
	}

	realityTLS := func() subTLS {
		return subTLS{Enabled: true, ServerName: donorSNI, UTLS: subUTLS{Enabled: true, Fingerprint: "chrome"}, Reality: &subReality{Enabled: true, PublicKey: pub, ShortID: shortFirst}}
	}
	plainTLS := func(alpn []string) subTLS {
		return subTLS{Enabled: true, ServerName: tlsSNI, UTLS: subUTLS{Enabled: true, Fingerprint: "chrome"}, ALPN: alpn}
	}
	or := func(a, b string) string {
		if a != "" {
			return a
		}
		return b
	}

	// VALID-NAME CONTRACT. The byte-equivalence with the shell holds for valid client names — non-empty
	// and free of the characters the shell's `jq @tsv | read` client loop mishandles. The Go port handles
	// the real name directly and deliberately does NOT reproduce two latent shell quirks on pathological
	// names: (1) an EMPTY name (rejected upstream by `myc_identity_add`, so it cannot occur via the
	// sanctioned path) — the shell's whitespace-IFS `read` field-shifts the id into the name; here it is
	// simply skipped; (2) a literal backslash / control char in a name — the shell leaves the `@tsv` escape
	// doubled; here the actual name byte is sanitised. Neither arises for a realistic identity label.
	var out []ClientSubscription
	for _, c := range clients {
		if c.Name == "" {
			continue
		}
		ipw := c.Password
		hy2pw := or(ipw, hysteria2Password)
		sspw := or(ipw, ssPassword)
		stlspw := or(ipw, shadowtlsPassword)
		trpw := or(ipw, trojanPassword)
		tuicpw := or(ipw, c.ID)

		var proxies []any
		var detours []any
		var tags []string
		for _, d := range enabled {
			port, err := portOf(d.Proto)
			if err != nil {
				return nil, err
			}
			switch d.Proto {
			case "vless-reality-vision":
				proxies = append(proxies, subVLESS{Type: "vless", Tag: d.Proto, Server: nodeAddr, ServerPort: port, UUID: c.ID, Flow: "xtls-rprx-vision", PacketEncoding: "xudp", TLS: realityTLS()})
			case "vless-reality-grpc":
				proxies = append(proxies, subVLESS{Type: "vless", Tag: d.Proto, Server: nodeAddr, ServerPort: port, UUID: c.ID, Flow: "", PacketEncoding: "xudp", TLS: realityTLS(), Transport: &subTransport{Type: "grpc", ServiceName: grpcService}})
			case "vless-reality-xhttp":
				proxies = append(proxies, subVLESS{Type: "vless", Tag: d.Proto, Server: nodeAddr, ServerPort: port, UUID: c.ID, Flow: "", PacketEncoding: "xudp", TLS: realityTLS(), Transport: &subTransport{Type: "xhttp", Path: xhttpPath}})
			case "vless-ws-tls":
				proxies = append(proxies, subVLESS{Type: "vless", Tag: d.Proto, Server: nodeAddr, ServerPort: port, UUID: c.ID, Flow: "", PacketEncoding: "xudp", TLS: plainTLS([]string{"http/1.1"}), Transport: &subTransport{Type: "ws", Path: wsPath, Headers: &subHeaders{Host: tlsSNI}}})
			case "hysteria2":
				proxies = append(proxies, subHysteria2{Type: "hysteria2", Tag: d.Proto, Server: nodeAddr, ServerPort: port, Password: hy2pw, TLS: plainTLS([]string{"h3"})})
			case "tuic":
				proxies = append(proxies, subTUIC{Type: "tuic", Tag: d.Proto, Server: nodeAddr, ServerPort: port, UUID: c.ID, Password: tuicpw, CongestionControl: "bbr", TLS: plainTLS([]string{"h3"})})
			case "shadowsocks":
				proxies = append(proxies, subShadowsocks{Type: "shadowsocks", Tag: d.Proto, Server: nodeAddr, ServerPort: port, Method: "2022-blake3-aes-256-gcm", Password: sspw})
			case "shadowtls":
				// Routable outbound: Shadowsocks detoured through the hidden ShadowTLS-handshake outbound.
				proxies = append(proxies, subShadowTLSRoute{Type: "shadowsocks", Tag: d.Proto, Method: "2022-blake3-aes-256-gcm", Password: sspw, Detour: "shadowtls-handshake"})
				detours = append(detours, subShadowTLSHandshake{Type: "shadowtls", Tag: "shadowtls-handshake", Server: nodeAddr, ServerPort: port, Version: 3, Password: stlspw, TLS: subTLS{Enabled: true, ServerName: tlsSNI, UTLS: subUTLS{Enabled: true, Fingerprint: "chrome"}}})
			case "trojan":
				proxies = append(proxies, subTrojan{Type: "trojan", Tag: d.Proto, Server: nodeAddr, ServerPort: port, Password: trpw, TLS: plainTLS([]string{"h2", "http/1.1"})})
			default:
				return nil, fmt.Errorf("subscription: proto %q has no sing-box client outbound shape", d.Proto)
			}
			tags = append(tags, d.Proto)
		}

		outbounds := make([]any, 0, len(proxies)+len(detours)+4)
		outbounds = append(outbounds, proxies...)
		outbounds = append(outbounds, detours...)
		outbounds = append(outbounds,
			subURLTest{Type: "urltest", Tag: "auto", Outbounds: tags, URL: urltestURL, Interval: urltestInterval, Tolerance: urltestTolerance, IdleTimeout: urltestIdleTimeout},
			subSelector{Type: "selector", Tag: "mycelium", Outbounds: append([]string{"auto"}, tags...), Default: "auto"},
			subSimple{Type: "direct", Tag: "direct"},
			subSimple{Type: "block", Tag: "block"},
		)

		clash := renderClash(c.Name, nodeAddr, c.ID, donorSNI, pub, shortFirst, tlsSNI, sspw, hy2pw, trpw, grpcService, enabled, portOf)

		out = append(out, ClientSubscription{
			Name:    c.Name,
			Safe:    sanitizeName(c.Name),
			Singbox: SubDoc{Outbounds: outbounds},
			Clash:   clash,
		})
	}
	return out, nil
}

// renderClash hand-emits the Clash-Meta YAML byte-identically to the shell `myc_sb_emit_clash`.
// jq has no YAML output, so the shell emits by printf; every value is quoted so special characters are
// inert. Clash-Meta supports neither ShadowTLS nor the XHTTP/WS transports, so those are skipped.
func renderClash(name, server, uuid, dsni, pub, sid, tsni, sspw, hy2pw, trpw, grpc string, enabled []ProtoDescriptor, portOf func(string) (int, error)) string {
	var b strings.Builder
	b.WriteString("# Copyright © 2026 mindicator & silicon bags quartet.\n")
	b.WriteString("# SPDX-License-Identifier: AGPL-3.0-or-later\n")
	b.WriteString("# This file is part of Mycelium, licensed under the GNU Affero General Public\n")
	b.WriteString("# License v3.0 or later. See the LICENSE file in the repository root.\n")
	b.WriteString("#\n")
	fmt.Fprintf(&b, "# Clash-Meta proxies + groups for client \"%s\". Generated by myceliumctl (engine: singbox).\n", name)
	b.WriteString("# Merge \"proxies\" and \"proxy-groups\" into your Clash-Meta config. ShadowTLS and XHTTP\n")
	b.WriteString("# are not represented here (Clash-Meta lacks support); use the sing-box config for those.\n")
	b.WriteString("proxies:\n")

	port := func(proto string) string { p, _ := portOf(proto); return strconv.Itoa(p) }
	var names string // leading-comma list, mirrors the shell accumulation
	for _, d := range enabled {
		switch d.Proto {
		case "vless-reality-vision":
			fmt.Fprintf(&b, "  - name: \"mycelium-%s-vision\"\n", name)
			b.WriteString("    type: vless\n")
			fmt.Fprintf(&b, "    server: \"%s\"\n", server)
			fmt.Fprintf(&b, "    port: %s\n", port("vless-reality-vision"))
			fmt.Fprintf(&b, "    uuid: \"%s\"\n", uuid)
			b.WriteString("    network: tcp\n")
			b.WriteString("    udp: true\n")
			b.WriteString("    flow: xtls-rprx-vision\n")
			b.WriteString("    tls: true\n")
			fmt.Fprintf(&b, "    servername: \"%s\"\n", dsni)
			b.WriteString("    client-fingerprint: chrome\n")
			b.WriteString("    reality-opts:\n")
			fmt.Fprintf(&b, "      public-key: \"%s\"\n", pub)
			fmt.Fprintf(&b, "      short-id: \"%s\"\n", sid)
			names += fmt.Sprintf(", \"mycelium-%s-vision\"", name)
		case "vless-reality-grpc":
			fmt.Fprintf(&b, "  - name: \"mycelium-%s-grpc\"\n", name)
			b.WriteString("    type: vless\n")
			fmt.Fprintf(&b, "    server: \"%s\"\n", server)
			fmt.Fprintf(&b, "    port: %s\n", port("vless-reality-grpc"))
			fmt.Fprintf(&b, "    uuid: \"%s\"\n", uuid)
			b.WriteString("    network: grpc\n")
			b.WriteString("    udp: true\n")
			b.WriteString("    tls: true\n")
			fmt.Fprintf(&b, "    servername: \"%s\"\n", dsni)
			b.WriteString("    client-fingerprint: chrome\n")
			b.WriteString("    grpc-opts:\n")
			fmt.Fprintf(&b, "      grpc-service-name: \"%s\"\n", grpc)
			b.WriteString("    reality-opts:\n")
			fmt.Fprintf(&b, "      public-key: \"%s\"\n", pub)
			fmt.Fprintf(&b, "      short-id: \"%s\"\n", sid)
			names += fmt.Sprintf(", \"mycelium-%s-grpc\"", name)
		case "hysteria2":
			fmt.Fprintf(&b, "  - name: \"mycelium-%s-hysteria2\"\n", name)
			b.WriteString("    type: hysteria2\n")
			fmt.Fprintf(&b, "    server: \"%s\"\n", server)
			fmt.Fprintf(&b, "    port: %s\n", port("hysteria2"))
			fmt.Fprintf(&b, "    password: \"%s\"\n", hy2pw)
			fmt.Fprintf(&b, "    sni: \"%s\"\n", tsni)
			b.WriteString("    alpn:\n")
			b.WriteString("      - h3\n")
			names += fmt.Sprintf(", \"mycelium-%s-hysteria2\"", name)
		case "tuic":
			fmt.Fprintf(&b, "  - name: \"mycelium-%s-tuic\"\n", name)
			b.WriteString("    type: tuic\n")
			fmt.Fprintf(&b, "    server: \"%s\"\n", server)
			fmt.Fprintf(&b, "    port: %s\n", port("tuic"))
			fmt.Fprintf(&b, "    uuid: \"%s\"\n", uuid)
			fmt.Fprintf(&b, "    password: \"%s\"\n", uuid)
			fmt.Fprintf(&b, "    sni: \"%s\"\n", tsni)
			b.WriteString("    congestion-controller: bbr\n")
			b.WriteString("    alpn:\n")
			b.WriteString("      - h3\n")
			names += fmt.Sprintf(", \"mycelium-%s-tuic\"", name)
		case "shadowsocks":
			fmt.Fprintf(&b, "  - name: \"mycelium-%s-ss2022\"\n", name)
			b.WriteString("    type: ss\n")
			fmt.Fprintf(&b, "    server: \"%s\"\n", server)
			fmt.Fprintf(&b, "    port: %s\n", port("shadowsocks"))
			b.WriteString("    cipher: 2022-blake3-aes-256-gcm\n")
			fmt.Fprintf(&b, "    password: \"%s\"\n", sspw)
			b.WriteString("    udp: true\n")
			names += fmt.Sprintf(", \"mycelium-%s-ss2022\"", name)
		case "trojan":
			fmt.Fprintf(&b, "  - name: \"mycelium-%s-trojan\"\n", name)
			b.WriteString("    type: trojan\n")
			fmt.Fprintf(&b, "    server: \"%s\"\n", server)
			fmt.Fprintf(&b, "    port: %s\n", port("trojan"))
			fmt.Fprintf(&b, "    password: \"%s\"\n", trpw)
			fmt.Fprintf(&b, "    sni: \"%s\"\n", tsni)
			b.WriteString("    client-fingerprint: chrome\n")
			b.WriteString("    alpn:\n")
			b.WriteString("      - h2\n")
			b.WriteString("      - http/1.1\n")
			names += fmt.Sprintf(", \"mycelium-%s-trojan\"", name)
		default:
			// shadowtls / reality-xhttp / ws-tls: not represented in Clash-Meta (see header note).
		}
	}

	if names != "" {
		namesClean := strings.TrimPrefix(names, ", ")
		b.WriteString("proxy-groups:\n")
		b.WriteString("  - name: \"mycelium-auto\"\n")
		b.WriteString("    type: url-test\n")
		b.WriteString("    url: \"https://www.gstatic.com/generate_204\"\n")
		b.WriteString("    interval: 300\n")
		b.WriteString("    tolerance: 150\n")
		b.WriteString("    lazy: true\n")
		fmt.Fprintf(&b, "    proxies: [ %s ]\n", namesClean)
		b.WriteString("  - name: \"mycelium\"\n")
		b.WriteString("    type: select\n")
		fmt.Fprintf(&b, "    proxies: [ \"mycelium-auto\", %s ]\n", namesClean)
	}
	return b.String()
}

// sanitizeName mirrors the shell `tr -c 'A-Za-z0-9._-' '_'` (byte-wise): every byte outside the set
// becomes '_'. Names are ASCII (enforced elsewhere), so byte-wise == rune-wise here.
func sanitizeName(name string) string {
	b := []byte(name)
	for i, ch := range b {
		switch {
		case ch >= 'A' && ch <= 'Z', ch >= 'a' && ch <= 'z', ch >= '0' && ch <= '9', ch == '.', ch == '_', ch == '-':
			// keep
		default:
			b[i] = '_'
		}
	}
	return string(b)
}
