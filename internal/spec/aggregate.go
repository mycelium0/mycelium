// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"bytes"
	"encoding/json"
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
		tls := aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: qd(q, "fp", "chrome")}}
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
		v = aggHy2{Type: "hysteria2", Tag: tag, Server: host, ServerPort: port, Password: ui,
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: "chrome"},
				ALPN: strings.Split(qd(q, "alpn", "h3"), ",")}}
	case "tuic":
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
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: qd(q, "fp", "chrome")},
				ALPN: strings.Split(qd(q, "alpn", "h2,http/1.1"), ",")}}
	default:
		return nil, nil
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
