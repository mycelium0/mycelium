// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// OutboundFromLink parses an opaque client share-link (the same schemes ShareLink emits — vless://,
// hysteria2://, tuic://, ss://, trojan://) into a sing-box client OUTBOUND, the inverse of ShareLink and
// the Go-owned port of the shell `myc_agg_link_outbound` (control/lib/render_aggregate.sh), RP-0008 P3-c.
// It returns the compact-JSON outbound (byte-identical to the shell jq emission — the
// aggregate_outbound_go_equiv gate pins this), or nil when the shell yields null: a ShadowTLS ss-link
// (the Link carries only the inner SS material, never the v3 handshake password/version, so the detour
// outbound cannot be faithfully reconstructed — fail closed) or any unknown scheme. Pure; no network, no
// eval — every value is decoded from the string. tag is the already-namespaced outbound tag to stamp on.
func OutboundFromLink(tag, link string) (json.RawMessage, error) {
	v, err := outboundValue(tag, link)
	if err != nil || v == nil {
		return nil, err
	}
	// Marshal WITHOUT HTML escaping so '&' / '<' / '>' inside a value stay literal (matching jq's
	// compact output); Encode appends a newline, which the raw outbound must not carry.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return json.RawMessage(bytes.TrimRight(buf.Bytes(), "\n")), nil
}

// outboundValue is OutboundFromLink's typed core: it returns the outbound as a typed struct (an aggVless /
// aggHy2 / ... value), or nil for the fail-closed null cases (a ShadowTLS ss-link or an unknown scheme).
// RenderAggregate uses the typed value directly so the merged profile indents uniformly like `jq .`.
func outboundValue(tag, link string) (any, error) {
	main := uriBefore(link, "#")
	scheme := uriBefore(main, "://")
	rest := uriAfter(main, "://")
	authority := uriBefore(rest, "?")
	q := parseQuery(uriAfter(rest, "?"))

	var userinfoRaw, hostport string
	if strings.Contains(authority, "@") {
		userinfoRaw = uriBefore(authority, "@")
		hostport = uriAfter(authority, "@")
	} else {
		hostport = authority
	}
	host := uriDecode(uriBefore(hostport, ":"))
	port := 0
	if n, err := strconv.Atoi(uriAfter(hostport, ":")); err == nil { // C28: hostnames only, no IPv6 literal
		port = n
	}
	ui := uriDecode(userinfoRaw) // decoded userinfo (vless uuid / hy2,trojan password)

	var v any
	switch scheme {
	case "vless":
		// RP-0015 / Audit-0008 S2-4: the fp is carried by the parsed share-link query (which the render
		// splices from the operator's client_fingerprint); the default only applies to a link that omits fp.
		// Normalize against the closed vocab so a hand-edited/foreign link cannot splice an invalid uTLS
		// token (byte-twin of the shell's `normfp` in render_aggregate.sh).
		tls := aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: NormalizeClientFingerprint(qd(q, "fp", DefaultClientFingerprint))}}
		if q["security"] == "reality" {
			tls.Reality = &aggReality{Enabled: true, PublicKey: q["pbk"], ShortID: q["sid"]}
		} else {
			tls.ALPN = strings.Split(qd(q, "alpn", "h2,http/1.1"), ",")
		}
		ob := aggVless{Type: "vless", Tag: tag, Server: host, ServerPort: port, UUID: ui,
			Flow: q["flow"], PacketEncoding: "xudp", TLS: tls}
		switch q["type"] { // network transport; tcp (or unset) carries no transport block
		case "grpc":
			ob.Transport = &aggTransport{Type: "grpc", ServiceName: qd(q, "serviceName", "grpc")}
		case "xhttp":
			ob.Transport = &aggTransport{Type: "xhttp", Path: qd(q, "path", "/")}
		case "ws":
			ob.Transport = &aggTransport{Type: "ws", Path: qd(q, "path", "/ws"),
				Headers: &aggWSHeaders{Host: qd2(q, "host", "sni", "")}}
		}
		v = ob
	case "hysteria2":
		// QUIC uTLS: a separate handshake axis from the REALITY/TLS client fingerprint; hy2/tuic share-links
		// carry no fp, so the RP-0015 client_fingerprint knob deliberately does not reach here (fp-static).
		v = aggHy2{Type: "hysteria2", Tag: tag, Server: host, ServerPort: port, Password: ui,
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: "chrome"},
				ALPN: strings.Split(qd(q, "alpn", "h3"), ",")}}
	case "tuic":
		// QUIC uTLS: separate handshake axis (fp-static; see hysteria2).
		v = aggTuic{Type: "tuic", Tag: tag, Server: host, ServerPort: port,
			UUID: uriDecode(uriBefore(userinfoRaw, ":")), Password: uriDecode(uriAfter(userinfoRaw, ":")),
			CongestionControl: qd(q, "congestion_control", "bbr"),
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: "chrome"},
				ALPN: strings.Split(qd(q, "alpn", "h3"), ",")}}
	case "ss":
		if q["plugin"] == "shadow-tls" { // fail closed: inner-only material, cannot rebuild the v3 detour
			return nil, nil
		}
		v = aggSS{Type: "shadowsocks", Tag: tag, Server: host, ServerPort: port,
			Method: uriDecode(uriBefore(userinfoRaw, ":")), Password: uriDecode(uriAfter(userinfoRaw, ":"))}
	case "trojan":
		v = aggTrojan{Type: "trojan", Tag: tag, Server: host, ServerPort: port, Password: ui,
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: NormalizeClientFingerprint(qd(q, "fp", DefaultClientFingerprint))},
				ALPN: strings.Split(qd(q, "alpn", "h2,http/1.1"), ",")}}
	default:
		return nil, nil
	}
	return v, nil
}

// --- outbound shapes (field order mirrors the shell jq construction order; omitempty drops the keys jq's
// conditional `+ {}` / `// `-defaulted branches omit, so the compact JSON is byte-identical). -----------

type aggUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint"`
}
type aggReality struct {
	Enabled   bool   `json:"enabled"`
	PublicKey string `json:"public_key"`
	ShortID   string `json:"short_id"`
}
type aggTLS struct {
	Enabled    bool        `json:"enabled"`
	ServerName string      `json:"server_name"`
	UTLS       aggUTLS     `json:"utls"`
	ALPN       []string    `json:"alpn,omitempty"`    // tls (own-cert) branch only
	Reality    *aggReality `json:"reality,omitempty"` // reality branch only
}
type aggWSHeaders struct {
	Host string `json:"Host"`
}
type aggTransport struct {
	Type        string        `json:"type"`
	ServiceName string        `json:"service_name,omitempty"` // grpc
	Path        string        `json:"path,omitempty"`         // xhttp/ws
	Headers     *aggWSHeaders `json:"headers,omitempty"`      // ws
}
type aggVless struct {
	Type           string        `json:"type"`
	Tag            string        `json:"tag"`
	Server         string        `json:"server"`
	ServerPort     int           `json:"server_port"`
	UUID           string        `json:"uuid"`
	Flow           string        `json:"flow"`
	PacketEncoding string        `json:"packet_encoding"`
	TLS            aggTLS        `json:"tls"`
	Transport      *aggTransport `json:"transport,omitempty"`
}
type aggHy2 struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Password   string `json:"password"`
	TLS        aggTLS `json:"tls"`
}
type aggTuic struct {
	Type              string `json:"type"`
	Tag               string `json:"tag"`
	Server            string `json:"server"`
	ServerPort        int    `json:"server_port"`
	UUID              string `json:"uuid"`
	Password          string `json:"password"`
	CongestionControl string `json:"congestion_control"`
	TLS               aggTLS `json:"tls"`
}
type aggSS struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Method     string `json:"method"`
	Password   string `json:"password"`
}
type aggTrojan struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Password   string `json:"password"`
	TLS        aggTLS `json:"tls"`
}

// --- pure-string URI helpers (match the shell jq before/after/urldecode/query_to_obj exactly) ----------

// uriBefore returns everything before the FIRST sep (or the whole string if sep is absent) — jq `before`.
func uriBefore(s, sep string) string {
	if i := strings.Index(s, sep); i >= 0 {
		return s[:i]
	}
	return s
}

// uriAfter returns everything after the FIRST sep (or "" if sep is absent) — jq `after`.
func uriAfter(s, sep string) string {
	if i := strings.Index(s, sep); i >= 0 {
		return s[i+len(sep):]
	}
	return ""
}

// uriDecode is the inverse of uriEncode (jq urldecode): split on "%", keep the first chunk literal, and
// for each later chunk turn a leading two hex digits into the byte they encode (rest literal), else keep
// the stray "%" literal. Byte-wise.
func uriDecode(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	parts := strings.Split(s, "%")
	var b strings.Builder
	b.WriteString(parts[0])
	for _, p := range parts[1:] {
		if len(p) >= 2 && isHex(p[0]) && isHex(p[1]) {
			b.WriteByte(hexNibble(p[0])<<4 | hexNibble(p[1]))
			b.WriteString(p[2:])
		} else {
			b.WriteByte('%')
			b.WriteString(p)
		}
	}
	return b.String()
}

func isHex(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
func hexNibble(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	default:
		return c - 'A' + 10
	}
}

// parseQuery parses "k=v&k2=v2" into a map (last value wins, matching jq `add`). Keys are
// producer-controlled literals (never encoded); only the VALUE is percent-decoded. Empty values (k=) are
// preserved. Empty input -> empty map (jq query_to_obj).
func parseQuery(s string) map[string]string {
	m := map[string]string{}
	if s == "" {
		return m
	}
	for _, part := range strings.Split(s, "&") {
		if part == "" {
			continue
		}
		m[uriBefore(part, "=")] = uriDecode(uriAfter(part, "="))
	}
	return m
}

// qd returns m[key] when the key is PRESENT (even an empty value) and def only when it is ABSENT — jq's
// `($q.k // "def")` (the `//` operator defaults on null/absent, never on a present empty string). The
// query map has no entry for an absent param, so presence == ok.
func qd(m map[string]string, key, def string) string {
	if v, ok := m[key]; ok {
		return v
	}
	return def
}

// qd2 is qd with a second fallback key before the literal default (jq `($q.a // $q.b // "def")`).
func qd2(m map[string]string, a, b, def string) string {
	if v, ok := m[a]; ok {
		return v
	}
	if v, ok := m[b]; ok {
		return v
	}
	return def
}

// --- aggregate: fold M per-node Bundles -> one client sing-box profile (RP-0008 P3-c part 2) ----------

// AggregateInput is one of the operator's own nodes for the client-side merge: a parsed distribution
// Bundle plus the LABEL that namespaces its outbound tags so tags from different nodes never collide.
type AggregateInput struct {
	Bundle Bundle
	Label  string
}

// MYC_URLTEST_* single source with render_singbox.sh (C22 anti-flapping hysteresis for the cross-node
// auto-switch); the probe URL is the same generate_204 endpoint the subscription path uses.
const (
	urltestInterval    = "5m"
	urltestTolerance   = 150
	urltestIdleTimeout = "30m"
	urltestURL         = "https://www.gstatic.com/generate_204"
)

// RenderAggregate folds >=2 per-node Bundles into ONE sing-box client profile — the Go port of the shell
// myc_render_aggregate. Each input's endpoints become namespaced client outbounds ("<label>.<tag-without-
// mycelium-prefix>", parsed via outboundValue), then ONE urltest "auto" over all of them, ONE selector
// "mycelium" (default "auto"), then direct + block. LOCAL-only, pure (no network). Fail-closed throughout:
// ASCII labels only, unique labels, a recognised scheme consistent with the declared transport_class, a
// ShadowTLS link refused, port in 1..65535. Byte-identical to the shell (aggregate_render_go_equiv pins it).
func RenderAggregate(inputs []AggregateInput) ([]byte, error) {
	if len(inputs) < 2 {
		return nil, fmt.Errorf("aggregate: need >=2 --bundle inputs to merge (got %d); a single node already has its own subscription", len(inputs))
	}
	var proxies []any
	var tags []string
	seen := map[string]bool{}
	for idx := range inputs {
		label := inputs[idx].Label
		// C27: ASCII whitelist only — refuse non-ASCII/whitespace labels (homoglyph tag-collision risk).
		if strings.IndexFunc(label, func(r rune) bool {
			return !((r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-')
		}) >= 0 {
			return nil, fmt.Errorf("aggregate: node label %q contains a character outside the ASCII whitelist [A-Za-z0-9._-] — non-ASCII/whitespace labels are refused (homoglyph tag-collision risk). Use an ASCII --name", label)
		}
		safe := label
		if safe == "" {
			safe = fmt.Sprintf("node%d", idx+1)
		}
		if seen[safe] {
			return nil, fmt.Errorf("aggregate: duplicate node label %q — every --name must be unique so tags never collide across nodes", safe)
		}
		seen[safe] = true
		for _, ep := range inputs[idx].Bundle.Endpoints {
			shortTag := strings.TrimPrefix(ep.Tag, "mycelium-")
			if shortTag == "" {
				shortTag = ep.Tag
			}
			nsTag := safe + "." + shortTag
			link := ep.Link
			if strings.Contains(link, "plugin=shadow-tls") {
				return nil, fmt.Errorf("aggregate: endpoint link is a ShadowTLS share-link (node %q, tag %q) which cannot be reconstructed into a dialable client outbound from its Link alone (the v3 handshake password/version are not in the Link)", safe, ep.Tag)
			}
			scheme := uriBefore(link, "://")
			if !aggSchemeClassOK(scheme, string(ep.TransportClass)) {
				switch scheme {
				case "vless", "hysteria2", "tuic", "ss", "trojan":
					return nil, fmt.Errorf("aggregate: endpoint scheme %q is inconsistent with its declared transport_class %q (node %q, tag %q) — the Link protocol and the typed family disagree", scheme, ep.TransportClass, safe, ep.Tag)
				default:
					return nil, fmt.Errorf("aggregate: endpoint link has an unrecognised scheme %q (node %q, tag %q) — expected one of vless/hysteria2/tuic/ss/trojan", scheme, safe, ep.Tag)
				}
			}
			ob, err := outboundValue(nsTag, link)
			if err != nil || ob == nil {
				return nil, fmt.Errorf("aggregate: could not parse endpoint link into a client outbound (node %q, tag %q)", safe, ep.Tag)
			}
			if port := aggOutboundPort(ob); port < 1 || port > 65535 {
				return nil, fmt.Errorf("aggregate: endpoint link port %d out of range 1..65535 (node %q, tag %q)", port, safe, ep.Tag)
			}
			proxies = append(proxies, ob)
			tags = append(tags, nsTag)
		}
	}
	if len(proxies) == 0 {
		return nil, fmt.Errorf("aggregate: produced zero outbounds (no endpoints across the inputs)")
	}
	outbounds := make([]any, 0, len(proxies)+4)
	outbounds = append(outbounds, proxies...)
	outbounds = append(outbounds,
		aggURLTest{Type: "urltest", Tag: "auto", Outbounds: tags, URL: urltestURL,
			Interval: urltestInterval, Tolerance: urltestTolerance, IdleTimeout: urltestIdleTimeout},
		aggSelector{Type: "selector", Tag: "mycelium", Outbounds: append([]string{"auto"}, tags...), Default: "auto"},
		aggTagged{Type: "direct", Tag: "direct"},
		aggTagged{Type: "block", Tag: "block"},
	)
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(aggProfile{Outbounds: outbounds}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// aggSchemeClassOK reports whether a share-link scheme is consistent with the endpoint's declared
// transport_class (C26 — the Link protocol and the typed family must agree). Mirrors the shell case table.
func aggSchemeClassOK(scheme, class string) bool {
	switch scheme + ":" + class {
	case "vless:reality-tcp", "vless:xhttp-tls", "vless:ws-tls",
		"hysteria2:quic-udp", "tuic:quic-udp",
		"ss:shadowsocks-tcp", "ss:shadowtls-tcp",
		"trojan:trojan-tls":
		return true
	}
	return false
}

// aggOutboundPort extracts server_port from a typed outbound value (C09 range check).
func aggOutboundPort(ob any) int {
	switch o := ob.(type) {
	case aggVless:
		return o.ServerPort
	case aggHy2:
		return o.ServerPort
	case aggTuic:
		return o.ServerPort
	case aggSS:
		return o.ServerPort
	case aggTrojan:
		return o.ServerPort
	default:
		return 0
	}
}

type aggProfile struct {
	Outbounds []any `json:"outbounds"`
}
type aggURLTest struct {
	Type        string   `json:"type"`
	Tag         string   `json:"tag"`
	Outbounds   []string `json:"outbounds"`
	URL         string   `json:"url"`
	Interval    string   `json:"interval"`
	Tolerance   int      `json:"tolerance"`
	IdleTimeout string   `json:"idle_timeout"`
}
type aggSelector struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Outbounds []string `json:"outbounds"`
	Default   string   `json:"default"`
}
type aggTagged struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}
