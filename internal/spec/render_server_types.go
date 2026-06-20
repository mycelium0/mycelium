// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "encoding/json"

// Typed mirror of nodes/dataplane/singbox/server.template.renderer.json. Each struct's field order is
// the TEMPLATE's key order (not alphabetical) so json.Encoder reproduces the shell `jq` output byte for
// byte. The template's tls key order is deliberately INCONSISTENT across inbound families (ws-tls puts
// alpn LAST; hysteria2/tuic/trojan put alpn BEFORE the cert paths), so the own-cert families use two
// distinct tls structs. If the template changes, these structs (and the render) must change with it —
// the render_server_go_equiv gate enforces that lockstep.

// --- users (shape differs by protocol) ---

type sbVlessUser struct {
	Name string `json:"name"`
	UUID string `json:"uuid"`
	Flow string `json:"flow"`
}

type sbTuicUser struct {
	Name     string `json:"name"`
	UUID     string `json:"uuid"`
	Password string `json:"password"`
}

type sbPwUser struct {
	Name     string `json:"name"`
	Password string `json:"password"`
}

// --- tls variants ---

type sbHandshake struct {
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
}

type sbReality struct {
	Enabled    bool        `json:"enabled"`
	Handshake  sbHandshake `json:"handshake"`
	PrivateKey string      `json:"private_key"`
	ShortID    []string    `json:"short_id"`
}

type sbRealityTLS struct {
	Enabled    bool      `json:"enabled"`
	ServerName string    `json:"server_name"`
	Reality    sbReality `json:"reality"`
}

// sbWSCertTLS — the vless-ws-tls inbound's tls: enabled, server_name, certificate_path, key_path, alpn.
type sbWSCertTLS struct {
	Enabled         bool     `json:"enabled"`
	ServerName      string   `json:"server_name"`
	CertificatePath string   `json:"certificate_path"`
	KeyPath         string   `json:"key_path"`
	ALPN            []string `json:"alpn"`
}

// sbAlpnCertTLS — the hysteria2/tuic/trojan tls: enabled, server_name, alpn, certificate_path, key_path.
type sbAlpnCertTLS struct {
	Enabled         bool     `json:"enabled"`
	ServerName      string   `json:"server_name"`
	ALPN            []string `json:"alpn"`
	CertificatePath string   `json:"certificate_path"`
	KeyPath         string   `json:"key_path"`
}

// --- transports ---

type sbGRPCTransport struct {
	Type        string `json:"type"`
	ServiceName string `json:"service_name"`
}

// sbPathTransport covers the xhttp ({type, path}) and ws ({type, path}) INBOUND transports (the ws-tls
// inbound carries no headers in the template — unlike the two-hop ws OUTBOUND).
type sbPathTransport struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

// --- inbounds (template order) ---

type sbInVision struct {
	Type       string        `json:"type"`
	Tag        string        `json:"tag"`
	Listen     string        `json:"listen"`
	ListenPort int           `json:"listen_port"`
	Users      []sbVlessUser `json:"users"`
	TLS        sbRealityTLS  `json:"tls"`
}

type sbInRealityGRPC struct {
	Type       string          `json:"type"`
	Tag        string          `json:"tag"`
	Listen     string          `json:"listen"`
	ListenPort int             `json:"listen_port"`
	Users      []sbVlessUser   `json:"users"`
	TLS        sbRealityTLS    `json:"tls"`
	Transport  sbGRPCTransport `json:"transport"`
}

type sbInRealityXHTTP struct {
	Type       string          `json:"type"`
	Tag        string          `json:"tag"`
	Listen     string          `json:"listen"`
	ListenPort int             `json:"listen_port"`
	Users      []sbVlessUser   `json:"users"`
	TLS        sbRealityTLS    `json:"tls"`
	Transport  sbPathTransport `json:"transport"`
}

type sbInWSTLS struct {
	Type       string          `json:"type"`
	Tag        string          `json:"tag"`
	Listen     string          `json:"listen"`
	ListenPort int             `json:"listen_port"`
	Users      []sbVlessUser   `json:"users"`
	TLS        sbWSCertTLS     `json:"tls"`
	Transport  sbPathTransport `json:"transport"`
}

type sbInHysteria2 struct {
	Type       string        `json:"type"`
	Tag        string        `json:"tag"`
	Listen     string        `json:"listen"`
	ListenPort int           `json:"listen_port"`
	Users      []sbPwUser    `json:"users"`
	TLS        sbAlpnCertTLS `json:"tls"`
}

type sbInTUIC struct {
	Type              string        `json:"type"`
	Tag               string        `json:"tag"`
	Listen            string        `json:"listen"`
	ListenPort        int           `json:"listen_port"`
	Users             []sbTuicUser  `json:"users"`
	CongestionControl string        `json:"congestion_control"`
	TLS               sbAlpnCertTLS `json:"tls"`
}

type sbInShadowsocks struct {
	Type       string     `json:"type"`
	Tag        string     `json:"tag"`
	Listen     string     `json:"listen"`
	ListenPort int        `json:"listen_port"`
	Method     string     `json:"method"`
	Password   string     `json:"password"`
	Users      []sbPwUser `json:"users"`
}

type sbInShadowTLS struct {
	Type       string      `json:"type"`
	Tag        string      `json:"tag"`
	Listen     string      `json:"listen"`
	ListenPort int         `json:"listen_port"`
	Version    int         `json:"version"`
	StrictMode bool        `json:"strict_mode"`
	Users      []sbPwUser  `json:"users"`
	Handshake  sbHandshake `json:"handshake"`
	Detour     string      `json:"detour"`
}

// sbInShadowTLSSS — the hidden detour SS inbound (no listen_port, no users).
type sbInShadowTLSSS struct {
	Type     string `json:"type"`
	Tag      string `json:"tag"`
	Listen   string `json:"listen"`
	Network  string `json:"network"`
	Method   string `json:"method"`
	Password string `json:"password"`
}

type sbInTrojan struct {
	Type       string        `json:"type"`
	Tag        string        `json:"tag"`
	Listen     string        `json:"listen"`
	ListenPort int           `json:"listen_port"`
	Users      []sbPwUser    `json:"users"`
	TLS        sbAlpnCertTLS `json:"tls"`
}

// --- outbounds / route / experimental / log / top ---

type sbOutSimple struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}

// sbTwoHopTLS / sbTwoHopTransport — the two-hop egress VLESS+WS+TLS outbound (ADR-0029).
type sbUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint"`
}

type sbTwoHopTLS struct {
	Enabled    bool     `json:"enabled"`
	ServerName string   `json:"server_name"`
	UTLS       sbUTLS   `json:"utls"`
	ALPN       []string `json:"alpn"`
}

type sbWSHeaders struct {
	Host string `json:"Host"`
}

type sbTwoHopTransport struct {
	Type    string      `json:"type"`
	Path    string      `json:"path"`
	Headers sbWSHeaders `json:"headers"`
}

type sbOutTwoHop struct {
	Type       string            `json:"type"`
	Tag        string            `json:"tag"`
	Server     string            `json:"server"`
	ServerPort int               `json:"server_port"`
	UUID       json.RawMessage   `json:"uuid"` // pass-through: the shell emits `uuid: $th.uuid` (null when absent)
	Flow       string            `json:"flow"`
	TLS        sbTwoHopTLS       `json:"tls"`
	Transport  sbTwoHopTransport `json:"transport"`
}

type sbRuleIPPrivate struct {
	IPIsPrivate bool   `json:"ip_is_private"`
	Outbound    string `json:"outbound"`
}

type sbRuleProtocol struct {
	Protocol string `json:"protocol"`
	Outbound string `json:"outbound"`
}

type sbRuleAuthUser struct {
	AuthUser []string `json:"auth_user"`
	Outbound string   `json:"outbound"`
}

type sbRoute struct {
	Rules []any  `json:"rules"`
	Final string `json:"final"`
}

type sbClashAPI struct {
	ExternalController string `json:"external_controller"`
	Secret             string `json:"secret,omitempty"`
}

type sbExperimental struct {
	ClashAPI sbClashAPI `json:"clash_api"`
}

type sbLog struct {
	Level     string `json:"level"`
	Timestamp bool   `json:"timestamp"`
}

// sbServer is the top-level config in template key order: log, inbounds, outbounds, route, experimental.
type sbServer struct {
	Log          sbLog          `json:"log"`
	Inbounds     []any          `json:"inbounds"`
	Outbounds    []any          `json:"outbounds"`
	Route        sbRoute        `json:"route"`
	Experimental sbExperimental `json:"experimental"`
}

// ServerClient is one identity for the server render. Password is a pointer so an ABSENT password
// (nil) is distinguished from an empty-string one: the shell uses jq `//`, which falls back only on
// null/absent, never on "".
type ServerClient struct {
	Name     string
	ID       string
	Password *string
}
