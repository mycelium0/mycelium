#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# aggregate_render_go_equiv.sh — conformance: the Go aggregate fold (spec.RenderAggregate, `myceliumctl
# aggregate`) is BYTE-IDENTICAL to the shell aggregate producer for the same inputs (RP-0008 P3-c part 2,
# the strangler equivalence gate completing the aggregate port). Two per-node bundles (rendered by the
# shell `bundle`, with reserved chars in paths/passwords) are folded by BOTH producers into one sing-box
# client profile and diffed. The profile carries no timestamp, so the comparison is a straight raw byte
# diff. Until green the shell stays authoritative (no cutover).
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-GO (mirrors the other *_go_equiv gates); the Go-side TestRenderAggregate pins the shape.
#
# Exit: 0 = byte-identical (or skipped without Go); 1 = the merged profile diverged; 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
CTL="$REPO_ROOT/control/myceliumctl"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }

printf '== aggregate fold Go↔shell byte-equivalence (RP-0008 P3-c) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

GO=""
if command -v go >/dev/null 2>&1; then GO="$(command -v go)"; else
	for c in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do [ -x "$c" ] && { GO="$c"; break; }; done
fi
if [ -z "$GO" ]; then
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the aggregate byte-equivalence (TestRenderAggregate mirrors it).\n'
	exit 0
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.arge.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
SPINE="$WORK/spine"
if ! ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 "$GO" build -o "$SPINE" ./cmd/myceliumctl ) >/dev/null 2>&1; then
	printf 'FAIL: could not build the Go spine.\n' >&2; exit 2
fi

STATE="$WORK/identities.json"
jq -n '{ version:1, clients:[ { name:"alice", id:"a1b2c3d4-e5f6-7890-abcd-ef0123456789", created:"2026-01-01T00:00:00Z", password:"idpw/1" } ] }' > "$STATE"

# Node A: most link-bearing transports (NOT shadowtls — the aggregate fails closed on it, by design);
# reserved chars in the paths/passwords stress the encode->parse->decode round-trip through both folds.
jq -n '{
	node_address:"nodeA.example.invalid", donor_host:"www.example.invalid", donor_sni:"www.example.invalid",
	reality_public_key:"PUBKEY_aB-cd12", short_ids:["0123abcd"], tls_sni:"a.tls.example.invalid",
	grpc_service_name:"grpc.health.v1.Health", xhttp_path:"/x?a=1", xhttp_path_tls:"/xt#y", ws_path:"/ws&z",
	ss_password:"ss/pw+1", trojan_password:"tr&pw#3", hysteria2_password:"hy2:pw@2",
	vless_reality_vision_enabled:true, vless_reality_grpc_enabled:true, vless_reality_xhttp_enabled:true,
	vless_xhttp_tls_enabled:true, vless_ws_tls_enabled:true, hysteria2_enabled:true, tuic_enabled:true,
	shadowsocks_enabled:true, trojan_enabled:true
}' > "$WORK/pA.json"
# Node B: a smaller, different subset + a different address, to exercise per-node tag namespacing.
jq -n '{
	node_address:"nodeB.example.invalid", donor_host:"www.example.invalid", donor_sni:"www.example.invalid",
	reality_public_key:"PUBKEY_B", short_ids:["feed0001"], tls_sni:"b.tls.example.invalid",
	vless_reality_vision_enabled:true, vless_reality_grpc_enabled:true, trojan_enabled:true, trojan_password:"B&pw"
}' > "$WORK/pB.json"

bash "$CTL" bundle --params "$WORK/pA.json" --state "$STATE" --out "$WORK/bA.json" 2>"$WORK/e" || { printf '  FAIL  bundle A: %s\n' "$(cut -c1-160 "$WORK/e")" >&2; exit 1; }
bash "$CTL" bundle --params "$WORK/pB.json" --state "$STATE" --out "$WORK/bB.json" 2>"$WORK/e" || { printf '  FAIL  bundle B: %s\n' "$(cut -c1-160 "$WORK/e")" >&2; exit 1; }

ARGS=(--out OUT --bundle "$WORK/bA.json" --name nodeA --bundle "$WORK/bB.json" --name nodeB)
if ! bash "$CTL" aggregate "${ARGS[@]/OUT/$WORK/sh.json}" 2>"$WORK/she"; then
	printf '  FAIL  shell aggregate: %s\n' "$(tr -d '\n' < "$WORK/she" | cut -c1-200)" >&2; printf '\n-- Result --\nFAIL\n' >&2; exit 1
fi
if ! "$SPINE" aggregate "${ARGS[@]/OUT/$WORK/go.json}" 2>"$WORK/goe"; then
	printf '  FAIL  Go aggregate: %s\n' "$(tr -d '\n' < "$WORK/goe" | cut -c1-200)" >&2; printf '\n-- Result --\nFAIL\n' >&2; exit 1
fi

n="$(jq '[.outbounds[] | select(.type!="urltest" and .type!="selector" and .type!="direct" and .type!="block")] | length' "$WORK/sh.json")"
printf '  ..    folded %s proxy outbound(s) across 2 nodes on each side\n' "$n"
if diff -u "$WORK/sh.json" "$WORK/go.json" > "$WORK/diff.out" 2>&1; then
	printf '  ok    merged client profile is byte-identical (%s proxies + urltest + selector + direct/block)\n' "$n"
	printf '\n-- Result --\nPASS: spec.RenderAggregate is byte-identical to the shell aggregate producer.\n'
	exit 0
fi
printf '  FAIL  merged profile diverged between shell and Go:\n'
sed 's/^/    /' "$WORK/diff.out" | head -40
printf '\n-- Result --\nFAIL: the Go aggregate fold is not byte-identical — do NOT cut over (RP-0008 P3 equivalence).\n' >&2
exit 1
