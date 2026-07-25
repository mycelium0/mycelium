#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# architecture_matrix_currency.sh — conformance (Audit-0008 S2-2): docs/ARCHITECTURE.md carries a
# transport/engine matrix that MUST stay current with the registry (control/vocab.json .protos[], the
# single source of truth). A family added to the registry but omitted from the matrix (the WSTLS bug), or
# an engine model that contradicts the registry (the stale "Xray … for the VLESS+REALITY+Vision shape"
# mislabel vs ADR-0032, where Xray serves vless-xhttp-tls), is a documentation-drift defect this gate
# catches offline.
#
# Checks, all single-sourced from vocab.json:
#   1. Every distinct transport CLASS in the registry has a recognizable token in ARCHITECTURE.md. A class
#      the gate does not know a token for is a hard FAIL (a new family → update the doc AND this map).
#   2. Every distinct ENGINE in the registry is named in ARCHITECTURE.md.
#   3. The one Xray-only proto (vless-xhttp-tls) is associated with "Xray" on a single line.
#   4. The stale ADR-0032 mislabel phrase is absent; ADR-0032 is referenced.
#
# Exit: 0 = matrix current, 1 = drift, 2 = usage/precondition.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
VOCAB="$REPO_ROOT/control/vocab.json"
ARCH="$REPO_ROOT/docs/ARCHITECTURE.md"

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not available.\n'; exit 0; }
[ -f "$VOCAB" ] || { printf 'FAIL: control/vocab.json missing.\n' >&2; exit 2; }
[ -f "$ARCH" ]  || { printf 'FAIL: docs/ARCHITECTURE.md missing.\n' >&2; exit 2; }

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

# The doc token that must appear for each registry transport class. A class NOT in this map is an
# unrecognised (new) family — the gate fails so the author documents it AND extends this map.
class_token() {
	case "$1" in
		reality-tcp)     printf 'REALITY' ;;
		xhttp-tls)       printf 'xhttp-tls' ;;
		ws-tls)          printf 'ws-tls' ;;
		quic-udp)        printf 'Hysteria2' ;;   # the QUIC family; TUIC is asserted separately below
		shadowsocks-tcp) printf 'Shadowsocks' ;;
		shadowtls-tcp)   printf 'ShadowTLS' ;;
		trojan-tls)      printf 'Trojan' ;;
		amneziawg-udp)   printf 'AmneziaWG' ;;
		*)               printf '' ;;
	esac
}

printf '== ARCHITECTURE.md transport/engine matrix currency (Audit-0008 S2-2) ==\n'

# 1) Every distinct registry class is documented.
classes="$(jq -r '.protos[].class' "$VOCAB" 2>/dev/null | sort -u)"
[ -n "$classes" ] || { printf 'FAIL: no .protos[].class in vocab.json.\n' >&2; exit 2; }
while IFS= read -r cls; do
	[ -n "$cls" ] || continue
	tok="$(class_token "$cls")"
	if [ -z "$tok" ]; then
		bad "registry class '$cls' has no documented-token mapping — a new family? document it in ARCHITECTURE.md and extend class_token()"
		continue
	fi
	if grep -qF -- "$tok" "$ARCH"; then
		ok "class '$cls' documented (token '$tok')"
	else
		bad "class '$cls' is in the registry but its token '$tok' is absent from ARCHITECTURE.md (family omitted from the matrix)"
	fi
done <<EOF
$classes
EOF

# The QUIC family carries two protos (hysteria2 + tuic); require BOTH named so the matrix cannot drop one.
grep -qF -- 'TUIC' "$ARCH" && ok "QUIC family: TUIC named" || bad "QUIC family: 'TUIC' absent from ARCHITECTURE.md"

# 2) Every distinct registry engine is named in the doc.
engines="$(jq -r '.protos[].engine' "$VOCAB" 2>/dev/null | sort -u)"
while IFS= read -r eng; do
	[ -n "$eng" ] || continue
	case "$eng" in
		sing-box) tok='sing-box' ;;
		xray)     tok='Xray' ;;
		amneziawg) tok='AmneziaWG' ;;
		*)        bad "registry engine '$eng' has no documented-token mapping — extend this gate"; continue ;;
	esac
	if grep -qiF -- "$tok" "$ARCH"; then
		ok "engine '$eng' named in ARCHITECTURE.md (token '$tok')"
	else
		bad "engine '$eng' is in the registry but not named in ARCHITECTURE.md"
	fi
done <<EOF
$engines
EOF

# 3) The Xray-only proto is associated with Xray on one line (engine model correct, not the stale mislabel).
xray_proto="$(jq -r '.protos[] | select(.engine=="xray") | .class' "$VOCAB" 2>/dev/null | head -1)"
if [ -n "$xray_proto" ]; then
	if grep -iE "$xray_proto" "$ARCH" | grep -qi 'Xray'; then
		ok "the Xray-engine family ('$xray_proto') is associated with Xray on a line"
	else
		bad "the Xray-engine family ('$xray_proto') is not associated with 'Xray' on any line (engine model drift)"
	fi
fi

# 4) The stale ADR-0032 mislabel must be gone; ADR-0032 must be referenced.
if grep -qiE 'alternative engine for the VLESS\+REALITY\+Vision' "$ARCH"; then
	bad "the stale engine mislabel ('alternative engine for the VLESS+REALITY+Vision shape') is still present — Xray serves vless-xhttp-tls (ADR-0032), not the Vision shape"
else
	ok "the stale Xray/Vision engine mislabel is absent"
fi
grep -qF -- '0032-xray-automated-toggleable-engine' "$ARCH" \
	&& ok "ADR-0032 (engine model) is referenced" \
	|| bad "ARCHITECTURE.md does not reference ADR-0032 (the engine model source)"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the ARCHITECTURE.md transport/engine matrix has drifted from control/vocab.json (registry).\n' >&2
	exit 1
fi
printf 'PASS: the ARCHITECTURE.md matrix is current with the registry (all families + engines documented).\n'
exit 0
