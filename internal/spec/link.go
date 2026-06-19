// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"strings"
)

// ShareLink renders the opaque, dialable client share-link (the Bundle Endpoint's Link, and the same
// string the subscription emits) for one transport of one node. It is the Go-owned port of the shell
// `myc_bundle_link` (control/lib/render_bundle.sh), the RP-0008 P3 strangler: pure + deterministic, it
// produces a BYTE-IDENTICAL string to the shell template (the share_link_go_equiv gate pins this), so the
// renderer can be cut over to Go only once equivalence is proven. Until then the shell still emits the
// artifact and this is additive.
//
// Encoding contract (matches the shell exactly): the structural URI delimiters (scheme://, the @, the
// host:port colon, ?, &, =, #) and the per-template literal hints (e.g. alpn=h2,http/1.1, the literal
// %2F in the ws alpn) are written by the template and stay literal; EVERY dynamic value spliced in
// (credentials, SNIs, keys, paths, service-name, the #fragment) is percent-encoded via uriEncode so a
// reserved char in a value cannot shift the URI boundaries. server + port are structural authority
// components (a hostname/integer port carry no reserved chars) and are left literal, exactly as the shell.
//
// proto must be one of the link-bearing closed-registry protos; amneziawg (a UDP dataplane with no
// share-link) and any unknown proto return an error — the shell `*` branch yields an empty string and its
// callers never pass those here, so erroring is the faithful typed equivalent (no empty Link is emitted).
func ShareLink(proto string, p LinkParams) (string, error) {
	frag := uriEncode("mycelium-" + proto)
	e := uriEncode
	switch proto {
	case "vless-reality-vision":
		return fmt.Sprintf("vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s",
			e(p.UUID), p.Server, p.Port, e(p.DonorSNI), e(p.Pub), e(p.ShortID), frag), nil
	case "vless-reality-grpc":
		return fmt.Sprintf("vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=grpc&serviceName=%s#%s",
			e(p.UUID), p.Server, p.Port, e(p.DonorSNI), e(p.Pub), e(p.ShortID), e(p.GRPCServiceName), frag), nil
	case "vless-reality-xhttp":
		return fmt.Sprintf("vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s#%s",
			e(p.UUID), p.Server, p.Port, e(p.DonorSNI), e(p.Pub), e(p.ShortID), e(p.XHTTPPath), frag), nil
	case "vless-xhttp-tls":
		// genuine single-layer TLS (own cert; NO reality): security=tls, no pbk/sid; per-family path.
		return fmt.Sprintf("vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2,http/1.1&type=xhttp&path=%s#%s",
			e(p.UUID), p.Server, p.Port, e(p.TLSSNI), e(p.XHTTPPathTLS), frag), nil
	case "vless-ws-tls":
		// genuine single-layer TLS over native WebSocket; alpn=http%2F1.1 (literal %2F so the '/' cannot
		// shift the query boundaries); host carries the own-cert SNI; per-family ws path.
		return fmt.Sprintf("vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s",
			e(p.UUID), p.Server, p.Port, e(p.TLSSNI), e(p.TLSSNI), e(p.WSPath), frag), nil
	case "hysteria2":
		return fmt.Sprintf("hysteria2://%s@%s:%s?sni=%s&alpn=h3#%s",
			e(p.Hy2Password), p.Server, p.Port, e(p.TLSSNI), frag), nil
	case "tuic":
		return fmt.Sprintf("tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr#%s",
			e(p.UUID), e(p.TUICPassword), p.Server, p.Port, e(p.TLSSNI), frag), nil
	case "shadowsocks":
		return fmt.Sprintf("ss://2022-blake3-aes-256-gcm:%s@%s:%s#%s",
			e(p.SSPassword), p.Server, p.Port, frag), nil
	case "shadowtls":
		return fmt.Sprintf("ss://2022-blake3-aes-256-gcm:%s@%s:%s?plugin=shadow-tls&sni=%s#%s",
			e(p.SSPassword), p.Server, p.Port, e(p.TLSSNI), frag), nil
	case "trojan":
		return fmt.Sprintf("trojan://%s@%s:%s?sni=%s&fp=chrome&alpn=h2,http/1.1&type=tcp#%s",
			e(p.TrojanPassword), p.Server, p.Port, e(p.TLSSNI), frag), nil
	default:
		return "", fmt.Errorf("%w: proto %q has no share-link (not a link-bearing transport)", ErrUnknownEnum, proto)
	}
}

// LinkParams carries the already-resolved connection values ShareLink splices into a template. The
// caller resolves them ONCE (from the node's params + first identity) so there is one source of
// connection truth; the field set mirrors the shell `myc_bundle_link` positional arguments. Server and
// Port are structural (left literal); every other field is percent-encoded by ShareLink.
type LinkParams struct {
	Server          string `json:"server"`            // node address (host) — structural, not encoded
	Port            string `json:"port"`              // listen port — structural, not encoded
	UUID            string `json:"uuid"`              // client uuid (vless/tuic)
	DonorSNI        string `json:"donor_sni"`         // REALITY donor SNI (reality transports)
	Pub             string `json:"pub"`               // REALITY public key
	ShortID         string `json:"short_id"`          // REALITY short id
	TLSSNI          string `json:"tls_sni"`           // own-cert SNI (tls/quic transports)
	SSPassword      string `json:"ss_password"`       // shadowsocks / shadowtls password
	Hy2Password     string `json:"hy2_password"`      // hysteria2 password
	TrojanPassword  string `json:"trojan_password"`   // trojan password
	TUICPassword    string `json:"tuic_password"`     // tuic password
	GRPCServiceName string `json:"grpc_service_name"` // gRPC serviceName
	XHTTPPath       string `json:"xhttp_path"`        // REALITY-xhttp path
	XHTTPPathTLS    string `json:"xhttp_path_tls"`    // genuine-TLS-xhttp path
	WSPath          string `json:"ws_path"`           // ws path
}

// uriEncode percent-encodes VALUE exactly as the shell `myc_uri_encode` (jq @uri): every BYTE outside the
// RFC-3986 unreserved set [A-Za-z0-9-_.~] becomes %XX with UPPERCASE hex; unreserved bytes pass through.
// Byte-wise (not rune-wise), matching jq @uri on multibyte input. Pure.
func uriEncode(s string) string {
	const unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte(unreserved, c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
