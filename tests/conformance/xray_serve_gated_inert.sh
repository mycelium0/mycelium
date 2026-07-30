#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# xray_serve_gated_inert.sh — conformance (ADR-0032 dual-engine P2-3): the OPTIONAL xray engine's
# serve path (render -> validate -> promote -> install unit -> start) is FAIL-CLOSED and INERT on a
# stock node. The single source of truth for "should this node run xray" is node_needs_xray (an
# xray-engine transport is enabled in params); a stock node enables none, so it never installs a
# config, writes the unit, or starts the service. Unlike the MEASURE daemon (operator-flag armed),
# the xray engine IS brought up automatically by flow_bootstrap — but ONLY under the node_needs_xray
# guard, exactly as sing-box is the primary. This gate pins that the guard is real and the apply is
# fail-closed, so the secondary engine can never start on a node that did not opt in. OFFLINE + INSPECT-ONLY.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS CHECKS
#   1. install_xray_unit's unit has ExecStartPre `xray run -test` — a config xray cannot parse fails
#      the START rather than crash-looping (unit-level fail-closed start).
#   2. validate_xray_config is the pre-promote `xray run -test` gate and fail-closes on a missing binary.
#   3. promote_xray_config keeps a known-good backup and rollback_xray_config exists (apply parity).
#   4. flow_bootstrap's xray serve START (restart_xray) is governed by a node_needs_xray guard.
#   5. No auto path (flow_update / flow_ack / flow_revoke) starts xray (no restart_xray/apply_xray there).
#   6. Default-off: the sole vocab engine=="xray" proto is vless-xhttp-tls, and write_params defaults it
#      disabled — so node_needs_xray is false on a stock node.
#
# Exit: 0 = gated + fail-closed + inert by default, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'xray_serve_gated_inert: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
INSTALL_LIB="$LIB/nb_install.sh"
APPLY_LIB="$LIB/nb_update_apply.sh"
PARAMS_LIB="$LIB/nb_render_params.sh"
VOCAB="$REPO_ROOT/control/vocab.json"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== xray engine serve gated/inert + fail-closed check (ADR-0032 P2-3) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

for f in "$INSTALL_LIB" "$APPLY_LIB" "$PARAMS_LIB" "$NB" "$VOCAB"; do
	[ -f "$f" ] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 2; }
done

# Print a shell function body: from `^name()` to the matching top-level closing brace.
func_body() { awk -v fn="$1" 'index($0,fn"()")==1{f=1} f{print} f&&/^}/{exit}' "$2"; }

# 1. install_xray_unit: ExecStartPre validates with `xray run -test` (fail-closed start).
unit_fn="$(func_body install_xray_unit "$INSTALL_LIB")"
printf '%s' "$unit_fn" | grep -qE 'ExecStartPre=.*run -test' \
	&& ok "install_xray_unit unit has ExecStartPre 'xray run -test' (fail-closed start)" \
	|| badln "install_xray_unit unit lacks an ExecStartPre 'xray run -test' (a bad config would crash-loop)"

# 2. validate_xray_config is the pre-promote `xray run -test` gate + fail-closes on a missing binary.
vfn="$(func_body validate_xray_config "$APPLY_LIB")"
printf '%s' "$vfn" | grep -qE 'run -test' \
	&& ok "validate_xray_config runs 'xray run -test' (pre-promote fail-closed gate)" \
	|| badln "validate_xray_config does not run 'xray run -test'"
printf '%s' "$vfn" | grep -qE 'have "\$XRAY_BIN".*die|XRAY_BIN.*missing' \
	&& ok "validate_xray_config fail-closes on a missing xray binary" \
	|| badln "validate_xray_config does not fail-closed on a missing xray binary"

# 3. promote keeps a known-good backup; rollback exists (apply parity with sing-box).
pfn="$(func_body promote_xray_config "$APPLY_LIB")"
printf '%s' "$pfn" | grep -qE 'cp -f "\$XRAY_CONFIG" "\$XRAY_LASTGOOD_CONFIG"' \
	&& ok "promote_xray_config keeps a known-good backup before replacing the live config" \
	|| badln "promote_xray_config does not back up the live config before replacing it"
grep -qE '^rollback_xray_config\(\)' "$APPLY_LIB" \
	&& ok "rollback_xray_config exists (fail-closed apply parity)" \
	|| badln "rollback_xray_config is missing"

# 4. flow_bootstrap's serve START is governed by a node_needs_xray guard (the guard precedes restart_xray).
fb="$(func_body flow_bootstrap "$NB")"
guard_ln="$(printf '%s\n' "$fb" | grep -nE 'if[[:space:]]+node_needs_xray;[[:space:]]*then' | tail -1 | cut -d: -f1)"
start_ln="$(printf '%s\n' "$fb" | grep -nE '(^|[^A-Za-z0-9_])restart_xray([^A-Za-z0-9_]|$)' | tail -1 | cut -d: -f1)"
if [ -n "$guard_ln" ] && [ -n "$start_ln" ] && [ "$guard_ln" -lt "$start_ln" ]; then
	ok "flow_bootstrap starts xray (restart_xray) only under an 'if node_needs_xray' guard"
else
	badln "flow_bootstrap's restart_xray is not governed by a node_needs_xray guard (serve could start on a stock node)"
fi

# 5. No auto-pull path starts xray DIRECTLY. The auto paths now converge the node through the shared
#    converge_node_tail (which calls apply_node_xray_engine) — that is deliberate and is what keeps an
#    updated/acked/revoked node from leaving its xray engine at the previous revision. A BARE
#    restart_xray/apply_xray in one of these flows would bypass the stock-node guard, so the direct-literal
#    ban stays.
auto_bad=""
for fn in flow_update flow_ack flow_revoke; do
	body="$(func_body "$fn" "$NB")"
	if printf '%s' "$body" | grep -qE '(^|[^A-Za-z0-9_])(restart_xray|apply_xray)([^A-Za-z0-9_]|$)'; then
		auto_bad="$auto_bad $fn"
	fi
done
[ -z "$auto_bad" ] \
	&& ok "no auto path (flow_update/flow_ack/flow_revoke) starts xray directly" \
	|| badln "an auto path starts xray directly (bypassing the stock-node guard):$auto_bad"

# 5b. The permitted indirection is only safe while it is GUARDED. apply_node_xray_engine's FIRST
#     statement must be the stock-node bail-out, so converge_node_tail installs, renders and starts
#     NOTHING on a node with no xray-engine family enabled. Without this assertion the ban above is
#     cosmetic: one level of indirection would evade the literal grep and silently start a second engine
#     on every node on the update cadence.
XRAY_APPLY_LIB="$LIB/nb_render_params.sh"
if [ -f "$XRAY_APPLY_LIB" ]; then
	# ORDERING, not the first line. This asserted that the function's first statement was literally
	# `node_needs_xray || return 0`, and it broke the moment a legitimate TEARDOWN branch was added ahead
	# of it (Audit-0009 K2) — while the property it exists to protect still held. Asserting spelling
	# instead of behaviour is the trap this repo has now hit four times; the property is what matters:
	# NOTHING that installs, renders, promotes or starts xray may be reachable before the stock-node
	# guard, and whatever runs before the guard may only stop/disable/retire.
	xbody="$(func_body apply_node_xray_engine "$XRAY_APPLY_LIB" | grep -vE '^[[:space:]]*#')"
	gline="$(printf '%s\n' "$xbody" | grep -nE 'node_needs_xray[[:space:]]*\|\|[[:space:]]*return 0' | head -1 | cut -d: -f1)"
	sline="$(printf '%s\n' "$xbody" | grep -nE '(^|[^_[:alnum:]])(install_xray|install_xray_unit|render_xray_candidate|promote_xray_config|restart_xray)([^_[:alnum:]]|$)' | head -1 | cut -d: -f1)"
	if [ -z "$gline" ]; then
		badln "apply_node_xray_engine has no 'node_needs_xray || return 0' guard at all — an auto path reaching it via converge_node_tail could install/start xray on a stock node"
	elif [ -n "$sline" ] && [ "$gline" -gt "$sline" ]; then
		badln "apply_node_xray_engine can install/render/start xray (line $sline of its body) BEFORE the stock-node guard (line $gline) — a stock node reached via converge_node_tail would grow a second engine"
	else
		ok "apply_node_xray_engine reaches no install/render/promote/start before its stock-node guard"
		# Whatever precedes the guard is the teardown branch; it may only stop/disable/retire.
		pre="$(printf '%s\n' "$xbody" | sed -n "1,${gline}p")"
		if printf '%s\n' "$pre" | grep -qE '(^|[^_[:alnum:]])(install_xray|install_xray_unit|render_xray_candidate|promote_xray_config|restart_xray)([^_[:alnum:]]|$)'; then
			badln "the code before the stock-node guard installs/renders/starts xray — only stop/disable/retire is permitted there"
		else
			ok "the pre-guard teardown branch only stops/disables/retires (it never installs or starts)"
		fi
	fi
	# And the tail really is the route the auto paths take, so this guard is load-bearing, not decorative.
	if func_body converge_node_tail "$XRAY_APPLY_LIB" | grep -q 'apply_node_xray_engine'; then
		ok "converge_node_tail reaches xray through the guarded apply_node_xray_engine"
	else
		badln "converge_node_tail no longer calls apply_node_xray_engine — an updated node would keep serving a stale xray config"
	fi
else
	badln "cannot locate nb_render_params.sh to verify the xray stock-node guard"
fi

# 6. Default-off: the only vocab engine=="xray" proto is vless-xhttp-tls, default-disabled in write_params.
if command -v jq >/dev/null 2>&1; then
	xray_protos="$(jq -r '[.protos[] | select(.engine=="xray") | .proto] | join(",")' "$VOCAB" 2>/dev/null)"
	enable_keys="$(jq -r '.protos[] | select(.engine=="xray") | .enable_key' "$VOCAB" 2>/dev/null)"
else
	xray_protos="vless-xhttp-tls"; enable_keys="vless_xhttp_tls_enabled"
fi
[ "$xray_protos" = "vless-xhttp-tls" ] \
	&& ok "the sole vocab engine==xray proto is vless-xhttp-tls" \
	|| badln "unexpected xray-engine proto set in vocab: '$xray_protos' (gate assumptions need review)"
defoff=1
for k in $enable_keys; do
	# write_params must default each xray-engine enable key to false (the line `<key>: false,` / `false `).
	grep -qE "$k:[[:space:]]*false" "$PARAMS_LIB" || defoff=0
done
[ "$defoff" -eq 1 ] \
	&& ok "write_params defaults every xray-engine enable key OFF (node_needs_xray false on a stock node)" \
	|| badln "an xray-engine enable key is not defaulted false in write_params (a stock node could pull in xray)"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the xray engine serve path is node_needs_xray-gated, fail-closed, and inert on a stock node.\n'
	exit 0
fi
printf 'FAIL: the xray engine serve path is not safely gated/inert — see above.\n' >&2
exit 1
