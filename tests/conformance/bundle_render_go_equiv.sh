#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# bundle_render_go_equiv.sh — conformance: the Go bundle renderer (spec.RenderBundle, `myceliumctl
# bundle`) is BYTE-IDENTICAL to the shell bundle producer (control/myceliumctl bundle -> render_bundle.sh)
# for the same params + identity (RP-0008 P3-b, the strangler equivalence gate). The only field allowed
# to differ is the generated_at INSTANT (a live clock on each side); it is text-normalized — NOT
# reformatted — before a raw byte diff, so the comparison still proves the two producers emit identical
# bytes (same key order, indentation, escaping, link strings). Until green, the shell stays authoritative
# (no cutover); the Go renderer is additive.
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-GO: the offline jq-only host cannot run the Go side (mirrors bundle_go_roundtrip /
# share_link_go_equiv); the Go-node / CI lane runs the diff, and the Go-side unit test
# TestRenderBundleShape pins the structure where Go is unavailable.
#
# Exit: 0 = byte-identical (or skipped without Go); 1 = the rendered bundle diverged; 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
CTL="$REPO_ROOT/control/myceliumctl"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }

printf '== bundle render Go↔shell byte-equivalence (RP-0008 P3-b) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

GO=""
if command -v go >/dev/null 2>&1; then GO="$(command -v go)"; else
	for c in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do [ -x "$c" ] && { GO="$c"; break; }; done
fi
if [ -z "$GO" ]; then
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the bundle byte-equivalence (TestRenderBundleShape mirrors it).\n'
	exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.brge.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
SPINE="$WORK/spine"
if ! ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 "$GO" build -o "$SPINE" ./cmd/myceliumctl ) >/dev/null 2>&1; then
	printf 'FAIL: could not build the Go spine.\n' >&2; exit 2
fi

# Fixture: ALL link-bearing transports enabled (max template coverage), with tls_sni set (required for
# the own-cert families) and distinct per-family paths. Dummy material — the Link is opaque at the typed
# level. region_bucket carries a reserved char to exercise encoding in both producers identically.
PARAMS="$WORK/params.json"; STATE="$WORK/identities.json"
jq -n '{
	node_address: "node.example.invalid",
	donor_host: "www.example.invalid", donor_sni: "www.example.invalid",
	reality_public_key: "DUMMYPUBKEY_aB-cd12",
	short_ids: [ "0123abcd" ],
	tls_sni: "tls.example.invalid",
	grpc_service_name: "grpc.health.v1.Health",
	xhttp_path: "/x?a=1", xhttp_path_tls: "/xt#y", ws_path: "/ws&z",
	ss_password: "ss/pw+1", trojan_password: "tr&pw", hysteria2_password: "hy2:pw", shadowtls_password: "stls@pw",
	region_bucket: "unspecified",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_reality_grpc_enabled:   true, vless_reality_grpc_port:   8443,
	vless_reality_xhttp_enabled:  true, vless_reality_xhttp_port:  2096,
	vless_xhttp_tls_enabled:      true, vless_xhttp_tls_port:      2087,
	vless_ws_tls_enabled:         true, vless_ws_tls_port:         2089,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	tuic_enabled:                 true, tuic_port:                 8445,
	shadowsocks_enabled:          true, shadowsocks_port:          8388,
	shadowtls_enabled:            true, shadowtls_port:            8446,
	trojan_enabled:               true, trojan_port:               8447
}' > "$PARAMS"
jq -n '{ version: 1, clients: [ { name: "alice", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z", password: "idpw/1" } ] }' > "$STATE"

# Fixture B exercises the OTHER resolution branches the gate would otherwise miss: an EMPTY per-identity
# password (so the per-proto secret falls back to the shared protocol secret — and the shadowtls quirk
# where the link uses ss_password, not shadowtls_password, must match in both), DISTINCT shared secrets,
# the donor-SNI tls fallback OFF (own-cert families absent here so tls_sni can be unset), and default paths.
PARAMS_B="$WORK/params_b.json"; STATE_B="$WORK/identities_b.json"
jq -n '{
	node_address: "node2.example.invalid",
	donor_host: "donor.example.invalid", donor_sni: "donor.example.invalid",
	reality_public_key: "PUB2",
	short_ids: [ "feed0001" ],
	ss_password: "SS_SECRET", trojan_password: "TR_SECRET", hysteria2_password: "HY_SECRET", shadowtls_password: "STLS_SECRET",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_reality_grpc_enabled:   true, vless_reality_grpc_port:   8443,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	tuic_enabled:                 true, tuic_port:                 8445,
	shadowsocks_enabled:          true, shadowsocks_port:          8388,
	shadowtls_enabled:            true, shadowtls_port:            8446,
	trojan_enabled:               true, trojan_port:               8447
}' > "$PARAMS_B"
jq -n '{ version: 1, clients: [ { name: "bob", id: "b0b00000-0000-4000-8000-000000000000", created: "2026-01-01T00:00:00Z" } ] }' > "$STATE_B"

norm() { sed -E 's/("generated_at": ")[^"]*(")/\1NORMALIZED\2/' "$1"; }
fail=0
compare_fixture() { # NAME PARAMS STATE
	local name="$1" params="$2" state="$3"
	if ! bash "$CTL" bundle --params "$params" --state "$state" --out "$WORK/sh.json" 2>"$WORK/sh.err"; then
		printf '  FAIL  [%s] shell render failed: %s\n' "$name" "$(tr -d '\n' < "$WORK/sh.err" | cut -c1-160)"; fail=1; return
	fi
	if ! "$SPINE" bundle --params "$params" --state "$state" --out "$WORK/go.json" 2>"$WORK/go.err"; then
		printf '  FAIL  [%s] Go render failed: %s\n' "$name" "$(tr -d '\n' < "$WORK/go.err" | cut -c1-160)"; fail=1; return
	fi
	norm "$WORK/sh.json" > "$WORK/sh.norm"; norm "$WORK/go.json" > "$WORK/go.norm"
	local n; n="$(jq '.endpoints|length' "$WORK/sh.json" 2>/dev/null)"
	if diff -u "$WORK/sh.norm" "$WORK/go.norm" > "$WORK/diff.out" 2>&1; then
		printf '  ok    [%s] byte-identical across %s endpoints\n' "$name" "$n"
	else
		printf '  FAIL  [%s] bundle JSON diverged:\n' "$name"; sed 's/^/    /' "$WORK/diff.out" | head -30; fail=1
	fi
}
compare_fixture "A: all transports, with client password" "$PARAMS" "$STATE"
compare_fixture "B: subset, EMPTY client password -> shared-secret fallback" "$PARAMS_B" "$STATE_B"

printf '\n-- Result --\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS: spec.RenderBundle is byte-identical to the shell bundle producer (both fixtures).\n'
	exit 0
fi
printf 'FAIL: the Go bundle renderer is not byte-identical — do NOT cut over (RP-0008 P3 equivalence).\n' >&2
exit 1
