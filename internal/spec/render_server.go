// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"fmt"
	"strconv"
)

// RenderServer is the Go-owned port of the shell `myc_sb_render_server` (control/lib/render_singbox.sh),
// RP-0008 P3-e (render-server → Go + the two-hop via_user routing). It builds the node's sing-box SERVER
// config — one inbound per ENABLED, sing-box-ENGINE protocol (filled from params + identities, in the
// template's inbound order), the hidden ShadowTLS detour SS inbound when ShadowTLS is on, the static
// direct/block outbounds + private/bittorrent route rules, the loopback clash_api (with an optional
// Bearer secret), and — when params declare a `two_hop` upstream — a VLESS+WS+TLS egress outbound plus
// an auth_user route rule (ADR-0029 in-region-ingress → out-of-region-egress).
//
// The result is byte-identical to the shell (the render_server_go_equiv gate pins it): the struct fields
// reproduce the template's per-inbound key order exactly, marshalled the same way as bundle (json.Encoder,
// SetEscapeHTML(false), 2-space, trailing newline). Resolution + fail-closed checks mirror the shell:
// short_ids non-empty when a REALITY proto is on; the own-cert genuine-TLS families require an explicit
// tls_sni (C03); the xray-only vless-xhttp-tls is dropped (dual-engine, ADR-0032); per-identity passwords
// fall back via jq `//` (absent/null only — never ""); the two-hop is fail-closed (C17/C18/C21).
func RenderServer(params map[string]json.RawMessage, clients []ServerClient) (sbServer, error) {
	var zero sbServer

	// Enabled set: params-toggled protos, filtered to the sing-box engine (drop xray-only vless-xhttp-tls).
	enabledSet := map[string]bool{}
	anyEnabled := false
	for i := range transportRegistry {
		d := transportRegistry[i]
		if d.EnableKey == "" || !paramBool(params, d.EnableKey) {
			continue
		}
		anyEnabled = true
		if d.Engine == EngineSingBox {
			enabledSet[d.Proto] = true
		}
	}
	if !anyEnabled {
		return zero, fmt.Errorf("render-server: no protocols enabled in params (set at least one <proto>_enabled: true)")
	}
	if len(enabledSet) == 0 {
		return zero, fmt.Errorf("render-server: no sing-box-servable protocols enabled (only xray-engine protos were on)")
	}

	needReality := enabledSet["vless-reality-vision"] || enabledSet["vless-reality-grpc"] || enabledSet["vless-reality-xhttp"]

	// The shell reads the REALITY material (donor_sni/donor_host/private_key/short_ids) ONLY when a
	// REALITY proto is enabled; otherwise those locals stay empty — so on a non-reality node donor_host is
	// "" (the shadowtls handshake then defaults to www.microsoft.com) and donor_sni is "" (tls_sni falls
	// back to localhost). Mirror that exactly: do not consult those params unless needReality.
	var donorSNI, donorHost, priv string
	var shortIDs []string
	if needReality {
		// These are read via the shell's no-default myc_params_get, which DIES on a missing/empty field.
		// Order mirrors the shell (priv, donor_sni, donor_host) so the first-missing fail-closed matches.
		var err error
		if priv, err = paramRequired(params, "reality_private_key"); err != nil {
			return zero, fmt.Errorf("render-server: %w", err)
		}
		if donorSNI, err = paramRequired(params, "donor_sni"); err != nil {
			return zero, fmt.Errorf("render-server: %w", err)
		}
		if donorHost, err = paramRequired(params, "donor_host"); err != nil {
			return zero, fmt.Errorf("render-server: %w", err)
		}
		shortIDs = allShortIDs(params)
		if len(shortIDs) == 0 {
			return zero, fmt.Errorf("render-server: params.short_ids must contain at least one shortId (a vless-reality-* protocol is enabled)")
		}
	}

	tlsFallback := donorSNI
	if tlsFallback == "" {
		tlsFallback = "localhost"
	}
	tlsSNI := paramStr(params, "tls_sni", tlsFallback)
	tlsCert := paramStr(params, "tls_certificate_path", "/etc/mycelium/tls/fullchain.pem")
	tlsKey := paramStr(params, "tls_key_path", "/etc/mycelium/tls/privkey.pem")

	// C03: an own-cert genuine-TLS family in the (post-filter) enabled set requires an explicit tls_sni.
	if (enabledSet["vless-ws-tls"] || enabledSet["vless-xhttp-tls"]) && paramStr(params, "tls_sni", "") == "" {
		return zero, fmt.Errorf("render-server: an own-cert genuine-TLS family (vless-xhttp-tls/vless-ws-tls) is enabled but params.tls_sni is empty — set params.tls_sni (never fall back to donor_sni)")
	}

	ssPassword := paramStr(params, "ss_password", "")
	trojanPassword := paramStr(params, "trojan_password", "")
	hysteria2Password := paramStr(params, "hysteria2_password", "")
	shadowtlsPassword := paramStr(params, "shadowtls_password", "")
	clashSecret := paramStr(params, "clash_secret", "")

	grpcService := paramStr(params, "grpc_service_name", "grpc")
	xhttpPath := paramStr(params, "xhttp_path", "/")
	wsPath := paramStr(params, "ws_path", "/ws")

	// Reachability posture (RP-0011 chunk D / ADR-0034 §3). node_bind is the listen address for every
	// PUBLIC inbound: it DEFAULTS to "::" (all interfaces — byte-identical to today, so a node with no
	// descriptor / reachable=true renders exactly as before), and apply_node_profile stamps "127.0.0.1"
	// only when the descriptor declares reachable:false (the node is provisioned + converged but NOT a
	// public entry). The hidden detour SS inbound stays 127.0.0.1 unconditionally (it is never public).
	bind := paramStr(params, "node_bind", "::")
	stlsHandshakeDefault := donorHost
	if stlsHandshakeDefault == "" {
		stlsHandshakeDefault = "www.microsoft.com"
	}
	stlsHandshake := paramStr(params, "shadowtls_handshake_server", stlsHandshakeDefault)
	stlsHandshakePort, err := portFrom(params, "shadowtls_handshake_port", "443")
	if err != nil {
		return zero, err
	}

	port := func(proto string) (int, error) {
		for i := range transportRegistry {
			if transportRegistry[i].Proto == proto {
				return portFrom(params, transportRegistry[i].PortKey, strconv.Itoa(transportRegistry[i].DefaultPort))
			}
		}
		return 0, fmt.Errorf("render-server: unknown proto %q", proto)
	}

	// Users (shape differs by protocol). jq `//` falls back on absent/null only (never "").
	pwOr := func(c ServerClient, fallback string) string {
		if c.Password != nil {
			return *c.Password
		}
		return fallback
	}
	usersVision := make([]sbVlessUser, 0, len(clients))
	usersPlain := make([]sbVlessUser, 0, len(clients))
	usersTUIC := make([]sbTuicUser, 0, len(clients))
	usersHy2 := make([]sbPwUser, 0, len(clients))
	usersTrojan := make([]sbPwUser, 0, len(clients))
	usersStls := make([]sbPwUser, 0, len(clients))
	usersSS := make([]sbPwUser, 0, len(clients))
	for _, c := range clients {
		usersVision = append(usersVision, sbVlessUser{Name: c.Name, UUID: c.ID, Flow: "xtls-rprx-vision"})
		usersPlain = append(usersPlain, sbVlessUser{Name: c.Name, UUID: c.ID, Flow: ""})
		usersTUIC = append(usersTUIC, sbTuicUser{Name: c.Name, UUID: c.ID, Password: pwOr(c, c.ID)})
		usersHy2 = append(usersHy2, sbPwUser{Name: c.Name, Password: pwOr(c, hysteria2Password)})
		usersTrojan = append(usersTrojan, sbPwUser{Name: c.Name, Password: pwOr(c, trojanPassword)})
		usersStls = append(usersStls, sbPwUser{Name: c.Name, Password: pwOr(c, shadowtlsPassword)})
		usersSS = append(usersSS, sbPwUser{Name: c.Name, Password: pwOr(c, ssPassword)})
	}

	realityTLS := func() sbRealityTLS {
		return sbRealityTLS{Enabled: true, ServerName: donorSNI, Reality: sbReality{Enabled: true, Handshake: sbHandshake{Server: donorHost, ServerPort: 443}, PrivateKey: priv, ShortID: shortIDs}}
	}

	// Inbounds, in TEMPLATE order, each included only when enabled (shadowtls-ss-in iff shadowtls).
	inbounds := make([]any, 0, 11)
	add := func(proto string, build func(p int) any) error {
		if !enabledSet[proto] {
			return nil
		}
		p, e := port(proto)
		if e != nil {
			return e
		}
		inbounds = append(inbounds, build(p))
		return nil
	}
	if err := add("vless-reality-vision", func(p int) any {
		return sbInVision{Type: "vless", Tag: "vless-reality-vision-in", Listen: bind, ListenPort: p, Users: usersVision, TLS: realityTLS()}
	}); err != nil {
		return zero, err
	}
	if err := add("vless-reality-grpc", func(p int) any {
		return sbInRealityGRPC{Type: "vless", Tag: "vless-reality-grpc-in", Listen: bind, ListenPort: p, Users: usersPlain, TLS: realityTLS(), Transport: sbGRPCTransport{Type: "grpc", ServiceName: grpcService}}
	}); err != nil {
		return zero, err
	}
	if err := add("vless-reality-xhttp", func(p int) any {
		return sbInRealityXHTTP{Type: "vless", Tag: "vless-reality-xhttp-in", Listen: bind, ListenPort: p, Users: usersPlain, TLS: realityTLS(), Transport: sbPathTransport{Type: "xhttp", Path: xhttpPath}}
	}); err != nil {
		return zero, err
	}
	// vless-xhttp-tls is an xray-engine proto — filtered out of the sing-box server (never in enabledSet).
	if err := add("vless-ws-tls", func(p int) any {
		return sbInWSTLS{Type: "vless", Tag: "vless-ws-tls-in", Listen: bind, ListenPort: p, Users: usersPlain, TLS: sbWSCertTLS{Enabled: true, ServerName: tlsSNI, CertificatePath: tlsCert, KeyPath: tlsKey, ALPN: []string{"http/1.1"}}, Transport: sbPathTransport{Type: "ws", Path: wsPath}}
	}); err != nil {
		return zero, err
	}
	if err := add("hysteria2", func(p int) any {
		return sbInHysteria2{Type: "hysteria2", Tag: "hysteria2-in", Listen: bind, ListenPort: p, Users: usersHy2, TLS: sbAlpnCertTLS{Enabled: true, ServerName: tlsSNI, ALPN: []string{"h3"}, CertificatePath: tlsCert, KeyPath: tlsKey}}
	}); err != nil {
		return zero, err
	}
	if err := add("tuic", func(p int) any {
		return sbInTUIC{Type: "tuic", Tag: "tuic-in", Listen: bind, ListenPort: p, Users: usersTUIC, CongestionControl: "bbr", TLS: sbAlpnCertTLS{Enabled: true, ServerName: tlsSNI, ALPN: []string{"h3"}, CertificatePath: tlsCert, KeyPath: tlsKey}}
	}); err != nil {
		return zero, err
	}
	if err := add("shadowsocks", func(p int) any {
		return sbInShadowsocks{Type: "shadowsocks", Tag: "shadowsocks-in", Listen: bind, ListenPort: p, Method: "2022-blake3-aes-256-gcm", Password: ssPassword, Users: usersSS}
	}); err != nil {
		return zero, err
	}
	if err := add("shadowtls", func(p int) any {
		return sbInShadowTLS{Type: "shadowtls", Tag: "shadowtls-in", Listen: bind, ListenPort: p, Version: 3, StrictMode: true, Users: usersStls, Handshake: sbHandshake{Server: stlsHandshake, ServerPort: stlsHandshakePort}, Detour: "shadowtls-ss-in"}
	}); err != nil {
		return zero, err
	}
	// The hidden detour SS inbound is kept iff shadowtls is enabled (it has no public listen_port).
	if enabledSet["shadowtls"] {
		inbounds = append(inbounds, sbInShadowTLSSS{Type: "shadowsocks", Tag: "shadowtls-ss-in", Listen: "127.0.0.1", Network: "tcp", Method: "2022-blake3-aes-256-gcm", Password: ssPassword})
	}
	if err := add("trojan", func(p int) any {
		return sbInTrojan{Type: "trojan", Tag: "trojan-in", Listen: bind, ListenPort: p, Users: usersTrojan, TLS: sbAlpnCertTLS{Enabled: true, ServerName: tlsSNI, ALPN: []string{"h2", "http/1.1"}, CertificatePath: tlsCert, KeyPath: tlsKey}}
	}); err != nil {
		return zero, err
	}

	outbounds := []any{
		sbOutSimple{Type: "direct", Tag: "direct"},
		sbOutSimple{Type: "block", Tag: "block"},
	}
	routeRules := []any{
		sbRuleIPPrivate{IPIsPrivate: true, Outbound: "block"},
		sbRuleProtocol{Protocol: "bittorrent", Outbound: "block"},
	}

	// Two-hop egress (ADR-0029): when params.two_hop is present, append a VLESS+WS+TLS upstream outbound
	// + an auth_user route rule. Fail-closed (C17/C18/C21).
	if thRaw, ok := params["two_hop"]; ok && !isJSONNull(thRaw) {
		ob, rule, err := buildTwoHop(thRaw, params, clients)
		if err != nil {
			return zero, err
		}
		outbounds = append(outbounds, ob)
		routeRules = append(routeRules, rule)
	}

	return sbServer{
		Log:       sbLog{Level: "warn", Timestamp: true},
		Inbounds:  inbounds,
		Outbounds: outbounds,
		Route:     sbRoute{Rules: routeRules, Final: "direct"},
		Experimental: sbExperimental{ClashAPI: sbClashAPI{
			ExternalController: "127.0.0.1:9090",
			Secret:             clashSecret, // omitempty: dropped when no secret was provisioned
		}},
	}, nil
}

// buildTwoHop validates the two_hop overlay and builds the egress outbound + auth_user route rule,
// fail-closed exactly as the shell does (C17 shape/port, C18 via_user is a known client, C21 distinct hop).
func buildTwoHop(thRaw json.RawMessage, params map[string]json.RawMessage, clients []ServerClient) (sbOutTwoHop, sbRuleAuthUser, error) {
	var th map[string]json.RawMessage
	if json.Unmarshal(thRaw, &th) != nil {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop is not an object (fail-closed)")
	}
	via := thStr(th, "via_user", "")
	if via == "" {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.via_user is empty — refusing an unscoped two-hop egress (set the designated client name)")
	}
	tag := thStr(th, "tag", "")
	server := thStr(th, "server", "")
	sni := thStr(th, "sni", "")
	if tag == "" {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.tag is empty (fail-closed; the upstream outbound needs a tag)")
	}
	if server == "" {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.server is empty (fail-closed; the upstream needs an address)")
	}
	if sni == "" {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.sni is empty (fail-closed; the upstream TLS needs a server_name)")
	}
	sp, err := portFrom(th, "server_port", "")
	if err != nil {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.server_port is not a positive integer in 1..65535 (fail-closed)")
	}
	// C18: via_user must name an existing client.
	known := false
	for _, c := range clients {
		if c.Name == via {
			known = true
			break
		}
	}
	if !known {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.via_user %q is not a known client (fail-closed; the auth_user route would never match)", via)
	}
	// C21: the egress must be a distinct node (not this ingress's own address / SNI).
	if ing := paramStr(params, "node_address", ""); ing != "" && server == ing {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.server is THIS node's own address — refusing a two-hop whose egress is the ingress (fail-closed)")
	}
	if ing := paramStr(params, "donor_sni", ""); ing != "" && sni == ing {
		return sbOutTwoHop{}, sbRuleAuthUser{}, fmt.Errorf("render-server: params.two_hop.sni equals this node's donor_sni — refusing a two-hop whose egress shares the ingress SNI (fail-closed)")
	}
	// uuid is passed through verbatim (the shell emits `uuid: $th.uuid`, i.e. null when the overlay omits it).
	uuidRaw := json.RawMessage("null")
	if u, ok := th["uuid"]; ok && !isJSONNull(u) {
		uuidRaw = u
	}
	fingerprint := thStr(th, "fingerprint", "chrome")
	alpn := thStr(th, "alpn", "http/1.1")
	wsPath := thStr(th, "ws_path", "/ws")
	wsHost := thStr(th, "ws_host", sni)
	ob := sbOutTwoHop{
		Type: "vless", Tag: tag, Server: server, ServerPort: sp, UUID: uuidRaw, Flow: "",
		TLS:       sbTwoHopTLS{Enabled: true, ServerName: sni, UTLS: sbUTLS{Enabled: true, Fingerprint: fingerprint}, ALPN: []string{alpn}},
		Transport: sbTwoHopTransport{Type: "ws", Path: wsPath, Headers: sbWSHeaders{Host: wsHost}},
	}
	return ob, sbRuleAuthUser{AuthUser: []string{via}, Outbound: tag}, nil
}

// paramRequired mirrors the shell `myc_params_get` WITHOUT a default: it returns the resolved value, or
// an error when the field is absent/null/false/empty (the shell `myc_die "required params field missing
// or empty: .<key>"`). Use it for the fields the shell reads with no default.
func paramRequired(m map[string]json.RawMessage, key string) (string, error) {
	v := paramStr(m, key, "")
	if v == "" {
		return "", fmt.Errorf("required params field missing or empty: .%s", key)
	}
	return v, nil
}

// allShortIDs returns params.short_ids as a string slice (mirrors `jq -c '.short_ids // []'`).
func allShortIDs(m map[string]json.RawMessage) []string {
	raw, ok := m["short_ids"]
	if !ok {
		return nil
	}
	var arr []string
	if json.Unmarshal(raw, &arr) == nil {
		return arr
	}
	return nil
}

// portFrom resolves m[key] (with default def) to an int in 1..65535 (or returns an error). The value may
// be a JSON number or a numeric string; def "" with an absent key is an error.
func portFrom(m map[string]json.RawMessage, key, def string) (int, error) {
	s := paramStr(m, key, def)
	p, err := strconv.Atoi(s)
	if err != nil || p < 1 || p > 65535 {
		return 0, fmt.Errorf("port for %q is not a positive integer in 1..65535 (%q)", key, s)
	}
	return p, nil
}

// thStr mirrors jq `.key // def` for the two_hop overlay: returns a JSON string value as-is (incl ""),
// and the default for an absent/null/false value (a non-string number/object falls back to paramStr).
func thStr(m map[string]json.RawMessage, key, def string) string {
	raw, ok := m[key]
	if !ok {
		return def
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return def
	}
	switch x := v.(type) {
	case nil:
		return def
	case bool:
		if !x {
			return def
		}
		return paramStr(m, key, def)
	case string:
		return x
	default:
		return paramStr(m, key, def)
	}
}

// isJSONNull reports whether a RawMessage is the literal null (mirrors `.two_hop // empty` dropping null).
func isJSONNull(raw json.RawMessage) bool {
	var v any
	return json.Unmarshal(raw, &v) == nil && v == nil
}
