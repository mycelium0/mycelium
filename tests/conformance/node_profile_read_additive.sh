#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_profile_read_additive.sh — conformance (ADR-0034 / RP-0011 chunk B2): the bootstrap reads the
# unified node profile descriptor ADDITIVELY and fail-closed. apply_node_profile (in write_params) must:
#   1. be a NO-OP when node.config.json is ABSENT (the byte-identical guard — every node without a
#      descriptor renders exactly as before, zero blast radius under auto-pull);
#   2. be wired into write_params (so the descriptor actually drives the params render);
#   3. resolve a transport's enable key from the Go-owned vocab.json — never a restated "<proto>_enabled"
#      literal in bash (vocab single source, RP-0008);
#   4. honour the operator_toggle_keys allowlist (only allowlisted toggles, like merge_operator_overrides);
#   5. be FAIL-CLOSED (a present-but-malformed descriptor / unknown transport / non-allowlisted key dies);
#   6. be READ-ONLY on the descriptor (it never writes node.config.json — operator-supplied).
# OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = additive + fail-closed + byte-identical-when-absent, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_profile_read_additive: cannot resolve repo root\n' >&2; exit 2; }
NBP="$REPO_ROOT/control/lib/nb_render_params.sh"
[ -f "$NBP" ] || { printf 'node_profile_read_additive: missing %s\n' "$NBP" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== node profile descriptor read is additive + fail-closed (ADR-0034 / RP-0011 B2) ==\n'

fn="$(awk '/^apply_node_profile\(\)/{f=1} f{print} /^}/{if(f)exit}' "$NBP")"
[ -n "$fn" ] || { badln "apply_node_profile not found in nb_render_params.sh"; printf 'FAIL\n' >&2; exit 1; }

# 1. byte-identical guard: absent descriptor => early no-op return.
printf '%s' "$fn" | grep -qE '\[ -f "\$cfg" \] \|\| return 0' \
	&& ok "apply_node_profile is a no-op when node.config.json is absent (byte-identical guard)" \
	|| badln "apply_node_profile does not early-return when the descriptor is absent (not byte-identical-safe)"

# 2. wired into write_params.
wp="$(awk '/^write_params\(\)/{f=1} f{print} /^}/{if(f)exit}' "$NBP")"
printf '%s' "$wp" | grep -qE '(^|[^a-z_])apply_node_profile([^a-z_]|$)' \
	&& ok "write_params calls apply_node_profile" \
	|| badln "write_params does not call apply_node_profile (the descriptor never drives the render)"

# 3. reads the enable key from vocab, not a restated '<proto>_enabled' literal in bash.
if printf '%s' "$fn" | grep -qE '"[A-Za-z0-9_]*_enabled"'; then
	badln "apply_node_profile restates an enable-key literal (must read .enable_key from vocab.json)"
else
	ok "apply_node_profile resolves enable keys from the Go-owned vocab.json (no restated literal)"
fi

# 4. honours the operator_toggle_keys allowlist.
printf '%s' "$fn" | grep -qE 'OPERATOR_TOGGLE_KEYS' \
	&& ok "apply_node_profile honours the operator_toggle_keys allowlist" \
	|| badln "apply_node_profile does not check the operator_toggle_keys allowlist (fail-open risk)"

# 5. fail-closed: dies on malformed / unknown / non-allowlisted.
[ "$(printf '%s' "$fn" | grep -cE '\bdie\b')" -ge 3 ] \
	&& ok "apply_node_profile is fail-closed (dies on malformed / unknown / non-allowlisted)" \
	|| badln "apply_node_profile lacks fail-closed die paths"

# 6. read-only on the descriptor: never writes node.config.json (only $cfg reads + params $tmp writes).
if printf '%s' "$fn" | grep -qE '>[[:space:]]*"\$cfg"|(mv|cp|tee|install)[^|;&]*"\$cfg"|>[[:space:]]*"[^"]*node\.config\.json"'; then
	badln "apply_node_profile writes the descriptor (must be read-only; the operator supplies it)"
else
	ok "apply_node_profile is read-only on the descriptor (reads node.config.json, writes only params)"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the node profile descriptor read is additive, registry-driven, allowlisted, and fail-closed.\n'
	exit 0
fi
printf 'FAIL: the descriptor read drifted from additive / fail-closed / byte-identical-when-absent — see above.\n' >&2
exit 1
