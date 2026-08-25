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
#
# It also pins the FIREWALL POSTURE as node state rather than argv (Audit-0009 I1): converge_node_tail runs
# unattended from the update timer, which carries no flags, so a `${DO_HARDEN:-1}` argv default there
# silently BECAME the posture — a node deliberately bootstrapped `--no-harden` had ufw force-enabled on its
# first tick. The tail must read node_profile_harden (descriptor field, then the remembered bootstrap
# posture, then ON), and node_profile_harden must be fail-safe rather than fail-closed: it is consulted on
# a cadenced root path where dying would abort the whole converge.
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
grep -qE '\[ -f "\$cfg" \] \|\| return 0' <<<"$fn" \
	&& ok "apply_node_profile is a no-op when node.config.json is absent (byte-identical guard)" \
	|| badln "apply_node_profile does not early-return when the descriptor is absent (not byte-identical-safe)"

# 2. wired into write_params.
wp="$(awk '/^write_params\(\)/{f=1} f{print} /^}/{if(f)exit}' "$NBP")"
grep -qE '(^|[^a-z_])apply_node_profile([^a-z_]|$)' <<<"$wp" \
	&& ok "write_params calls apply_node_profile" \
	|| badln "write_params does not call apply_node_profile (the descriptor never drives the render)"

# 3. reads the enable key from vocab, not a restated '<proto>_enabled' literal in bash.
if grep -qE '"[A-Za-z0-9_]*_enabled"' <<<"$fn" ; then
	badln "apply_node_profile restates an enable-key literal (must read .enable_key from vocab.json)"
else
	ok "apply_node_profile resolves enable keys from the Go-owned vocab.json (no restated literal)"
fi

# 4. honours the operator_toggle_keys allowlist.
grep -qE 'OPERATOR_TOGGLE_KEYS' <<<"$fn" \
	&& ok "apply_node_profile honours the operator_toggle_keys allowlist" \
	|| badln "apply_node_profile does not check the operator_toggle_keys allowlist (fail-open risk)"

# 5. fail-closed: dies on malformed / unknown / non-allowlisted.
[ "$(printf '%s' "$fn" | grep -cE '\bdie\b')" -ge 3 ] \
	&& ok "apply_node_profile is fail-closed (dies on malformed / unknown / non-allowlisted)" \
	|| badln "apply_node_profile lacks fail-closed die paths"

# 6. read-only on the descriptor: never writes node.config.json (only $cfg reads + params $tmp writes).
if grep -qE '>[[:space:]]*"\$cfg"|(mv|cp|tee|install)[^|;&]*"\$cfg"|>[[:space:]]*"[^"]*node\.config\.json"' <<<"$fn" ; then
	badln "apply_node_profile writes the descriptor (must be read-only; the operator supplies it)"
else
	ok "apply_node_profile is read-only on the descriptor (reads node.config.json, writes only params)"
fi

# 7. FIREWALL POSTURE comes from node state, not from this invocation's argv (Audit-0009 I1).
tail_fn="$(awk '/^converge_node_tail\(\)/{f=1} f{print} f&&/^\}/{exit}' "$NBP" | grep -vE '^[[:space:]]*#')"
if [ -z "$tail_fn" ]; then
	badln "converge_node_tail not found in $NBP"
elif grep -q 'node_profile_harden' <<<"$tail_fn" ; then
	ok "converge_node_tail reads the firewall posture from node state (node_profile_harden)"
	grep -q 'DO_HARDEN' <<<"$tail_fn" \
		&& badln "converge_node_tail still consults DO_HARDEN — that is set only from argv, and the update timer invokes the updater with NO flags, so the default silently becomes the posture" \
		|| ok "  and no longer consults the argv-only DO_HARDEN"
else
	badln "converge_node_tail decides the firewall step from argv (DO_HARDEN). It now runs unattended from the update timer, which carries no flags at all, so a node bootstrapped --no-harden has ufw force-enabled on its first tick and every non-mycelium inbound service on the host is blocked (Audit-0009 I1)."
fi
ph_fn="$(awk '/^node_profile_harden\(\)/{f=1} f{print} f&&/^\}/{exit}' "$NBP")"
if [ -z "$ph_fn" ]; then
	badln "node_profile_harden is not defined — there is no node-state source for the firewall posture"
else
	# FAIL-SAFE, not fail-closed: a `die` here aborts a cadenced root converge over a posture read.
	ph_code="$(grep -vE '^[[:space:]]*#' <<<"$ph_fn")"
	grep -qE '\bdie\b' <<<"$ph_code" \
		&& badln "node_profile_harden can die — it is read on every unattended converge, where dying over a posture read aborts the whole tail" \
		|| ok "node_profile_harden is fail-safe (it degrades to a posture, never aborts the converge)"
	# Precedence must be declared-field -> remembered -> ON, and the last word must be 'on'.
	grep -q 'node.config.json' <<<"$ph_fn" && grep -q 'harden.posture' <<<"$ph_fn" \
		&& ok "node_profile_harden consults the declared field, then the remembered bootstrap posture" \
		|| badln "node_profile_harden does not consult both the descriptor field and the remembered posture"
	ph_tail="$(tail -3 <<<"$ph_fn")"
	grep -q "printf 'on'" <<<"$ph_tail" \
		&& ok "  and defaults to ON when neither is present (fail-safe for a firewall, byte-identical to today)" \
		|| badln "node_profile_harden does not default to ON — an undeclared node would silently lose its firewall"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the node profile descriptor read is additive, registry-driven, allowlisted, and fail-closed.\n'
	exit 0
fi
printf 'FAIL: the descriptor read drifted from additive / fail-closed / byte-identical-when-absent — see above.\n' >&2
exit 1
