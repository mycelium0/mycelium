#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# share_link_go_equiv.sh — conformance: the Go share-link renderer (spec.ShareLink, `myceliumctl
# share-link`) is BYTE-IDENTICAL to the shell `myc_bundle_link` across the link-bearing transport matrix
# (RP-0008 P3-a, the strangler equivalence gate). Until this is green, the renderer is NOT cut over —
# the shell stays authoritative; the Go port is additive.
# Author: mindicator & silicon bags quartet.
#
# It drives BOTH renderers with the same already-resolved connection values — including reserved chars
# (`/ ? = # & + : space @`) in every encodable field — and asserts identical output. server/port stay
# structural (literal); every dynamic value is percent-encoded (jq @uri ↔ Go uriEncode). A diverged
# template or encoding rule fails here BEFORE any client ever sees a wrong link.
#
# SKIP-IF-NO-GO: the offline jq-only host cannot run the Go side; the Go-node / CI lane that has go1.26
# runs the comparison (mirrors bundle_go_roundtrip / vocab_single_source step 2). The Go-side unit test
# TestShareLinkGolden pins the templates where Go is unavailable.
#
# Exit: 0 = byte-identical (or skipped without Go); 1 = a proto's link diverged; 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
LIB="$REPO_ROOT/control/lib"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }

printf '== share-link Go↔shell byte-equivalence (RP-0008 P3-a) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# Build the Go spine (skip the gate if no toolchain).
GO=""
if command -v go >/dev/null 2>&1; then
	GO="$(mktemp "${TMPDIR:-/tmp}/myc-spine.XXXXXX")"
	if ! ( cd "$REPO_ROOT" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 go build -o "$GO" ./cmd/myceliumctl ) >/dev/null 2>&1; then
		rm -f "$GO"; GO=""
	fi
fi
if [ -z "$GO" ]; then
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the bash↔Go link equivalence (TestShareLinkGolden mirrors it).\n'
	exit 0
fi
trap 'rm -f "$GO"' EXIT

# Source the shell link generator (myc_bundle_link + myc_uri_encode). common.sh gives myc_die.
export MYC_LIB="$LIB" MYC_ROOT="$REPO_ROOT/control"
# shellcheck disable=SC1090
. "$LIB/common.sh"        || { printf 'FAIL: cannot source common.sh\n' >&2; exit 2; }
. "$LIB/jqlib.sh" 2>/dev/null || true
. "$LIB/render_bundle.sh" || { printf 'FAIL: cannot source render_bundle.sh\n' >&2; exit 2; }
command -v myc_bundle_link >/dev/null 2>&1 || { printf 'FAIL: myc_bundle_link not defined after sourcing\n' >&2; exit 2; }

# Fixture: structural server/port literal; every other field carries a reserved char to exercise encoding.
server="node.example.invalid"; port="443"
uuid="11111111-2222-3333-4444-555555555555"
dsni="www.microsoft.com"; pub="aB-cd_EF12"; sid="0e6e7757f3382b14"; tsni="edge.example.invalid"
sspw="ss/pw+1=x"; hy2pw="hy2:pw@2"; trpw="tr&pw#3"; tuicpw="tuic pw?4"
grpc="grpc.health.v1.Health"; xpath="/x?a=1"; xpath_tls="/xt#y"; ws_path="/ws&z"
# RP-0015: a NON-default closed-vocab fingerprint, so the equivalence proves both renderers thread the
# operator's client_fingerprint identically (not just the shared chrome default).
fp="firefox"

json="$(jq -n \
	--arg server "$server" --arg port "$port" --arg uuid "$uuid" --arg donor_sni "$dsni" \
	--arg pub "$pub" --arg short_id "$sid" --arg tls_sni "$tsni" --arg ss_password "$sspw" \
	--arg hy2_password "$hy2pw" --arg trojan_password "$trpw" --arg tuic_password "$tuicpw" \
	--arg grpc_service_name "$grpc" --arg xhttp_path "$xpath" --arg xhttp_path_tls "$xpath_tls" --arg ws_path "$ws_path" \
	--arg fingerprint "$fp" \
	'{server:$server,port:$port,uuid:$uuid,donor_sni:$donor_sni,pub:$pub,short_id:$short_id,tls_sni:$tls_sni,
	  ss_password:$ss_password,hy2_password:$hy2_password,trojan_password:$trojan_password,tuic_password:$tuic_password,
	  grpc_service_name:$grpc_service_name,xhttp_path:$xhttp_path,xhttp_path_tls:$xhttp_path_tls,ws_path:$ws_path,
	  fingerprint:$fingerprint}')"

# The link-bearing protos = registry protos with a non-empty scheme (from the committed vocab).
PROTOS="$(jq -r '[.protos[] | select(.scheme != "") | .proto] | join(" ")' "$REPO_ROOT/control/vocab.json")"
[ -n "$PROTOS" ] || { printf 'FAIL: no link-bearing protos found in vocab.json\n' >&2; exit 2; }

fail=0
for proto in $PROTOS; do
	b="$(myc_bundle_link "$proto" "$server" "$port" "$uuid" "$dsni" "$pub" "$sid" "$tsni" "$sspw" "$hy2pw" "$trpw" "$tuicpw" "$grpc" "$xpath" "$xpath_tls" "$ws_path" "$fp")"
	g="$(printf '%s' "$json" | "$GO" share-link --proto "$proto" - 2>/dev/null)"
	if [ -n "$b" ] && [ "$b" = "$g" ]; then
		printf '  ok    %s\n' "$proto"
	else
		printf '  FAIL  %s\n    shell: %s\n    go:    %s\n' "$proto" "$b" "$g"
		fail=1
	fi
done

printf '\n-- Result --\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS: spec.ShareLink is byte-identical to myc_bundle_link across the link-bearing transport matrix.\n'
	exit 0
fi
printf 'FAIL: a share-link diverged between the shell and the Go renderer — do NOT cut over (RP-0008 P3 equivalence).\n' >&2
exit 1
