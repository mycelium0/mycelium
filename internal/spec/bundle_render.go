// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"
)

// RenderBundle builds a node's distribution Bundle (bundle.go shape) from its params + first identity —
// the Go-owned port of the shell `myc_render_bundle` (control/lib/render_bundle.sh), RP-0008 P3-b. One
// Endpoint per ENABLED transport, in registry (priority) order, each carrying the coarse class, the
// coarse region bucket, the registry priority index, the advisory health (Phase-1: always "unknown"),
// and the opaque dialable Link (spec.ShareLink — the SAME string the subscription emits). Pure +
// deterministic (the clock is the generatedAt parameter); byte-identical to the shell output (the
// bundle_render_go_equiv gate pins this). Resolution mirrors the shell EXACTLY so the two producers of
// the client config cannot diverge (CONFLICTING_SOURCE_OF_TRUTH): absent/null/false/empty params take
// the documented default; the per-identity password falls back to the shared protocol secret; the
// own-cert genuine-TLS families fail closed without an explicit tls_sni (C03); ports must be 1..65535 (C09).
func RenderBundle(params map[string]json.RawMessage, firstClientID, firstClientPassword string, generatedAt time.Time) (Bundle, error) {
	base, err := bundleBaseLinkParams(params, firstClientID, firstClientPassword)
	if err != nil {
		return Bundle{}, err
	}
	region := paramStr(params, "region_bucket", "unspecified")

	var eps []Endpoint
	for i := range transportRegistry {
		d := transportRegistry[i]
		if d.EnableKey == "" || !paramBool(params, d.EnableKey) {
			continue
		}
		portStr := paramStr(params, d.PortKey, strconv.Itoa(d.DefaultPort))
		port, err := strconv.Atoi(portStr)
		if err != nil || port < 1 || port > 65535 {
			return Bundle{}, fmt.Errorf("bundle: port for %q is not a positive integer in 1..65535 (%q)", d.Proto, portStr)
		}
		lp := base
		lp.Port = portStr
		link, err := ShareLink(d.Proto, lp)
		if err != nil {
			return Bundle{}, fmt.Errorf("bundle: %w", err)
		}
		if link == "" {
			return Bundle{}, fmt.Errorf("bundle: produced an empty Link for %q", d.Proto)
		}
		// Priority is the registry index (the historical MYC_SB_PROTOS order; amneziawg is last and has
		// no enable key, so a link-bearing proto's registry index == its sing-box-list index).
		eps = append(eps, Endpoint{
			Tag:            "mycelium-" + d.Proto,
			TransportClass: d.Class,
			Region:         RegionBucket(region),
			Priority:       i,
			Health:         HealthUnknown,
			Link:           link,
		})
	}
	if len(eps) == 0 {
		return Bundle{}, fmt.Errorf("bundle: no protocols enabled in params (set at least one <proto>_enabled: true)")
	}
	bundle := Bundle{Version: NetworkStateVersion, Endpoints: eps, GeneratedAt: generatedAt}
	// RP-0013 AC-2 serve-time contract (fail-closed): a served bundle MUST span >= 2 INDEPENDENT transport
	// families so a single-family block never removes the client's last path — the precondition for e2e
	// client recovery. Consistent with AC-6 (>= 2 independent families per node). Not just an offline gate:
	// the node itself refuses to publish an unrecoverable single-family bundle.
	if !bundle.IndependentFallbackOK() {
		return Bundle{}, fmt.Errorf("bundle: the enabled transports span only %d independent family (%v) — a served bundle must span >= 2 DISTINCT families so a single-family block never removes the client's last path (RP-0013 AC-2 / AC-6); enable a second, independent transport family", len(bundle.DistinctClasses()), bundle.DistinctClasses())
	}
	return bundle, nil
}

// bundleBaseLinkParams resolves the per-bundle base LinkParams (everything except the per-protocol Port)
// from params + the first identity — the shared resolution RenderBundle and the fronted-endpoint render
// both use, so the direct and fronted Links cannot drift. The bundle_render_go_equiv gate protects this
// extraction (any change to the resolution would break byte-equivalence with the shell).
func bundleBaseLinkParams(params map[string]json.RawMessage, firstClientID, firstClientPassword string) (LinkParams, error) {
	// N4 fail-closed: an empty first-client id would splice into the Link as `vless://@server:port`.
	if firstClientID == "" {
		return LinkParams{}, fmt.Errorf("bundle: first identity has an empty id — cannot build a dialable endpoint credential")
	}
	nodeAddr := paramStr(params, "node_address", "")
	if nodeAddr == "" {
		return LinkParams{}, fmt.Errorf("bundle: node_address is required")
	}
	donorSNI := paramStr(params, "donor_sni", "")
	tlsFallback := donorSNI
	if tlsFallback == "" {
		tlsFallback = "localhost"
	}
	// C03: an own-cert genuine-TLS family (xhttp-tls/ws-tls) REQUIRES its own explicit tls_sni — never the
	// donor/localhost fallback (a cert/SNI mismatch tell). Probe explicit presence separately.
	if (paramBool(params, "vless_xhttp_tls_enabled") || paramBool(params, "vless_ws_tls_enabled")) &&
		paramStr(params, "tls_sni", "") == "" {
		return LinkParams{}, fmt.Errorf("bundle: an own-cert genuine-TLS family (vless-xhttp-tls/vless-ws-tls) is enabled but params.tls_sni is empty — set params.tls_sni (never fall back to donor_sni)")
	}
	ipw := firstClientPassword // per-identity password; falls back to the shared protocol secret below.
	or := func(a, b string) string {
		if a != "" {
			return a
		}
		return b
	}
	base := LinkParams{
		Server:          nodeAddr,
		UUID:            firstClientID,
		DonorSNI:        donorSNI,
		Pub:             paramStr(params, "reality_public_key", ""),
		ShortID:         firstShortID(params),
		TLSSNI:          paramStr(params, "tls_sni", tlsFallback),
		SSPassword:      or(ipw, paramStr(params, "ss_password", "")),
		Hy2Password:     or(ipw, paramStr(params, "hysteria2_password", "")),
		TrojanPassword:  or(ipw, paramStr(params, "trojan_password", "")),
		TUICPassword:    or(ipw, firstClientID),
		GRPCServiceName: paramStr(params, "grpc_service_name", "grpc"),
		XHTTPPath:       paramStr(params, "xhttp_path", "/"),
		WSPath:          paramStr(params, "ws_path", "/ws"),
		Fingerprint:     NormalizeClientFingerprint(paramStr(params, "client_fingerprint", DefaultClientFingerprint)),
	}
	// xhttp_path_tls defaults to xhttp_path when unset (back-compat; C06 lets an operator set them apart).
	base.XHTTPPathTLS = paramStr(params, "xhttp_path_tls", base.XHTTPPath)
	return base, nil
}

// paramStr mirrors the shell `myc_params_get` (jq -r '.key // empty' then a non-empty test): it returns
// the param's value when it is a non-empty string or a number, and the supplied default for
// absent/null/false/empty-string. Numbers render as the shell's `jq -r` would (integer ports -> no decimal).
func paramStr(m map[string]json.RawMessage, key, def string) string {
	raw, ok := m[key]
	if !ok {
		return def
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return def
	}
	switch x := v.(type) {
	case string:
		if x != "" {
			return x
		}
		return def
	case float64:
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'g', -1, 64)
	default: // bool/null/object/array -> the shell's `// empty` + non-empty test falls to the default
		return def
	}
}

// paramBool reports whether m[key] is JSON true (mirrors myc_sb_proto_enabled's `== true`).
func paramBool(m map[string]json.RawMessage, key string) bool {
	raw, ok := m[key]
	if !ok {
		return false
	}
	var b bool
	return json.Unmarshal(raw, &b) == nil && b
}

// firstShortID returns params.short_ids[0] or "" (mirrors `jq -r '.short_ids[0] // empty'`).
func firstShortID(m map[string]json.RawMessage) string {
	raw, ok := m["short_ids"]
	if !ok {
		return ""
	}
	var arr []string
	if json.Unmarshal(raw, &arr) == nil && len(arr) > 0 {
		return arr[0]
	}
	return ""
}
