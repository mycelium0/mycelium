// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// The sing-box selector's anti-flap knobs reuse the package-level urltestInterval/urltestTolerance/
// urltestIdleTimeout/urltestURL constants (defined in aggregate.go; single source with the shell
// MYC_URLTEST_* + render_singbox.sh). The Clash-Meta url-test group uses its own seconds/ms analogues
// (300/150/lazy), emitted literally in renderClash.

// SubClient is one identity the subscription is emitted for (from identities.json: name, id, optional
// per-identity password that falls back to the shared protocol secret).
type SubClient struct {
	Name     string
	ID       string
	Password string
}

// ClientSubscription is the rendered pair for one client: the sing-box client doc (marshalled by the
// caller exactly like the bundle — json.Encoder, SetEscapeHTML(false), SetIndent("", "  "), trailing
// newline) and the hand-emitted Clash-Meta YAML. Safe is the filename-sanitised client name.
type ClientSubscription struct {
	Name    string
	Safe    string
	Singbox SubDoc
	Clash   string
}

// SubDoc is the sing-box client config: a single "outbounds" array (heterogeneous — one struct per
// outbound type, so each element marshals in its own jq key order).
type SubDoc struct {
	Outbounds []any `json:"outbounds"`
}

// --- sing-box outbound shapes. Field order MUST match the shell jq object literals (byte-equivalence). ---

type subUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint"`
}

type subReality struct {
	Enabled   bool   `json:"enabled"`
	PublicKey string `json:"public_key"`
	ShortID   string `json:"short_id"`
}

// subTLS covers both reality_tls ({enabled, server_name, utls, reality}) and plain_tls ({enabled,
// server_name, utls, alpn}) and the ShadowTLS-handshake tls ({enabled, server_name, utls}). alpn is
// listed before reality so the two non-empty cases each preserve the shell's key order.
type subTLS struct {
	Enabled    bool        `json:"enabled"`
	ServerName string      `json:"server_name"`
	UTLS       subUTLS     `json:"utls"`
	ALPN       []string    `json:"alpn,omitempty"`
	Reality    *subReality `json:"reality,omitempty"`
}

type subHeaders struct {
	Host string `json:"Host"`
}

// subTransport covers grpc ({type, service_name}), xhttp ({type, path}) and ws ({type, path, headers}).
type subTransport struct {
	Type        string      `json:"type"`
	ServiceName string      `json:"service_name,omitempty"`
	Path        string      `json:"path,omitempty"`
	Headers     *subHeaders `json:"headers,omitempty"`
}

type subVLESS struct {
	Type           string        `json:"type"`
	Tag            string        `json:"tag"`
	Server         string        `json:"server"`
	ServerPort     int           `json:"server_port"`
	UUID           string        `json:"uuid"`
	Flow           string        `json:"flow"`
	PacketEncoding string        `json:"packet_encoding"`
	TLS            subTLS        `json:"tls"`
	Transport      *subTransport `json:"transport,omitempty"`
}

type subHysteria2 struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Password   string `json:"password"`
	TLS        subTLS `json:"tls"`
}

type subTUIC struct {
	Type              string `json:"type"`
	Tag               string `json:"tag"`
	Server            string `json:"server"`
	ServerPort        int    `json:"server_port"`
	UUID              string `json:"uuid"`
	Password          string `json:"password"`
	CongestionControl string `json:"congestion_control"`
	TLS               subTLS `json:"tls"`
}

type subShadowsocks struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Method     string `json:"method"`
	Password   string `json:"password"`
}

// subShadowTLSRoute is the routable Shadowsocks outbound that detours through the hidden handshake.
type subShadowTLSRoute struct {
	Type     string `json:"type"`
	Tag      string `json:"tag"`
	Method   string `json:"method"`
	Password string `json:"password"`
	Detour   string `json:"detour"`
}

type subShadowTLSHandshake struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Version    int    `json:"version"`
	Password   string `json:"password"`
	TLS        subTLS `json:"tls"`
}

type subTrojan struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Password   string `json:"password"`
	TLS        subTLS `json:"tls"`
}

type subURLTest struct {
	Type        string   `json:"type"`
	Tag         string   `json:"tag"`
	Outbounds   []string `json:"outbounds"`
	URL         string   `json:"url"`
	Interval    string   `json:"interval"`
	Tolerance   int      `json:"tolerance"`
	IdleTimeout string   `json:"idle_timeout"`
}

type subSelector struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Outbounds []string `json:"outbounds"`
	Default   string   `json:"default"`
}

type subSimple struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}
