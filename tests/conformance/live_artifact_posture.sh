#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# live_artifact_posture.sh — conformance: assertions on the ACTUALLY-DEPLOYED artifacts (the renderer
# template + the bootstrap's live default-on set), not on a superseded template. Closes the gap where
# the GO/NO-GO evidence described a template the fleet does not deploy (Audit-0004 F-002, F-004).
# Author: mindicator & silicon bags quartet.
#
# CHECKS
#   1. clash_api LOOPBACK-ONLY. The deployed renderer template's experimental.clash_api
#      external_controller (the /connections endpoint = the node's richest per-connection metadata
#      surface) MUST bind a loopback address (127.0.0.1 / ::1 / localhost), never 0.0.0.0 / :: / a
#      routable address. A non-loopback bind would expose per-connection metadata network-wide.
#   2. LIVE DEFAULT-ON SET PINNED. scripts/node-bootstrap.sh `write_params` is the live deploy source
#      of truth for which transports a fresh node enables by default. The default-on set MUST be
#      EXACTLY the documented two-port "Variant A" — VLESS+REALITY Vision + gRPC (ADR-0022) — and
#      nothing more. This pins the live posture so it cannot silently grow a new always-on ingress
#      (e.g. enabling HY2/TUIC/Trojan by default) without tripping this gate and updating ADR-0022 +
#      THREAT-MODEL. (group_vars keeps the conservative Vision-only default; that is checked by
#      per_protocol_toggle.sh. The two defaults legitimately differ — see ADR-0022.)
#
# Parses with jq (template) + grep/sed (bootstrap). bash 3.2-safe.
#
# Exit: 0 = posture holds; 1 = a violation; 2 = environment error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for live_artifact_posture.sh\n' >&2; exit 2; }

RT="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
BOOTSTRAP="$REPO_ROOT/scripts/node-bootstrap.sh"

[ -f "$RT" ]        || { printf 'FAIL: renderer template not found: %s\n' "$RT" >&2; exit 2; }
[ -f "$BOOTSTRAP" ] || { printf 'FAIL: node-bootstrap.sh not found: %s\n' "$BOOTSTRAP" >&2; exit 2; }
jq -e . "$RT" >/dev/null 2>&1 || { printf 'FAIL: renderer template is not valid JSON\n' >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== live deployed-artifact posture check ==\n'

# --- 1. clash_api loopback-only ------------------------------------------------------------------
ec="$(jq -r '.experimental.clash_api.external_controller // empty' "$RT")"
if [ -z "$ec" ]; then
	okln "renderer template declares no clash_api external_controller (no metadata surface to bind)"
else
	case "$ec" in
		127.*:*|"[::1]:"*|"::1:"*|localhost:*)
			okln "clash_api external_controller binds loopback only: $ec" ;;
		0.0.0.0:*|"[::]:"*|"::"*|"*:"*)
			badln "clash_api external_controller binds a NON-loopback / all-interfaces address: $ec (must be 127.0.0.1/::1)" ;;
		*)
			badln "clash_api external_controller is not a recognised loopback bind: $ec (must be 127.0.0.1/::1/localhost)" ;;
	esac
fi

# --- 2. live default-on set == documented two-port Variant A (ADR-0022) --------------------------
# Extract every `<proto>_enabled: true|false` boolean from write_params; build the on-set.
EXPECTED_ON="vless_reality_grpc vless_reality_vision"   # sorted
actual_on=""
seen=0
while IFS= read -r m; do
	[ -n "$m" ] || continue
	seen=$((seen + 1))
	key="${m%%_enabled:*}"
	val="$(printf '%s' "$m" | grep -oE 'true|false' | head -n1)"
	[ "$val" = "true" ] && actual_on="$actual_on $key"
done <<EOF
$(grep -oE '[a-z0-9_]+_enabled:[[:space:]]*(true|false)' "$BOOTSTRAP")
EOF

if [ "$seen" -lt 2 ]; then
	badln "found only $seen <proto>_enabled flags in node-bootstrap.sh write_params (expected the full set) — parse drift?"
else
	actual_sorted="$(printf '%s\n' $actual_on | sort | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
	if [ "$actual_sorted" = "$EXPECTED_ON" ]; then
		okln "live default-on set is exactly the documented two-port Variant A (ADR-0022): $actual_sorted"
	else
		badln "live default-on set drifted from ADR-0022 Variant A"
		printf '        expected: %s\n' "$EXPECTED_ON"
		printf '        actual:   %s\n' "$actual_sorted"
		printf '        -> if intended, update ADR-0022 + THREAT-MODEL port posture before changing this gate.\n'
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the deployed artifact posture is not as documented (clash_api bind or live default-on set).\n' >&2
	exit 1
fi
printf 'PASS: clash_api is loopback-only and the live default-on set matches the documented Variant A.\n'
exit 0
