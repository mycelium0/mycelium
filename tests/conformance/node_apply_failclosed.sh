#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_apply_failclosed.sh — conformance (ADR-0034 / RP-0011 chunk B2b): flow_node_apply (the --node-apply
# mode that applies the unified node profile to the LIVE node) is LOCAL-ONLY + FAIL-CLOSED. It must:
#   1. validate the candidate ('sing-box check') BEFORE it promotes anything;
#   2. roll back on a failed post-apply verification (rollback_config);
#   3. be LOCAL-ONLY — it never fetches (no myc_fetch_artifacts): applying the local descriptor must not
#      pull + run fresh code;
#   4. carry the NO-OP short-circuit (a candidate byte-identical to the live config => no promote/restart,
#      protecting live client connections — a no-descriptor / no-change node does nothing);
#   5. be reachable ONLY via the explicit --node-apply dispatch mode, and be called by NO auto-run path
#      (never flow_bootstrap / flow_update) — applying a profile is always an explicit operator act.
# OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = local-only + fail-closed + explicit-only, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_apply_failclosed: cannot resolve repo root\n' >&2; exit 2; }
NBP="$REPO_ROOT/control/lib/nb_render_params.sh"
BOOT="$REPO_ROOT/scripts/node-bootstrap.sh"
for f in "$NBP" "$BOOT"; do [ -f "$f" ] || { printf 'node_apply_failclosed: missing %s\n' "$f" >&2; exit 2; }; done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== flow_node_apply is local-only + fail-closed + explicit-only (ADR-0034 / RP-0011 B2b) ==\n'

fn="$(awk '/^flow_node_apply\(\)/{f=1} f{print} /^}/{if(f)exit}' "$NBP")"
[ -n "$fn" ] || { badln "flow_node_apply not found in nb_render_params.sh"; printf 'FAIL\n' >&2; exit 1; }

# 1. validate BEFORE promote.
v="$(printf '%s\n' "$fn" | grep -n 'validate_config' | head -1 | cut -d: -f1)"
p="$(printf '%s\n' "$fn" | grep -n 'promote_config'  | head -1 | cut -d: -f1)"
if [ -n "$v" ] && [ -n "$p" ] && [ "$v" -lt "$p" ]; then
	ok "validate_config runs before promote_config (fail-closed)"
else
	badln "flow_node_apply does not validate before promote (validate@${v:-none} promote@${p:-none})"
fi

# 2. rollback on failure.
printf '%s' "$fn" | grep -q 'rollback_config' \
	&& ok "flow_node_apply rolls back on a failed post-apply verification" \
	|| badln "flow_node_apply has no rollback_config path"

# 3. LOCAL-ONLY: no fetch.
if printf '%s' "$fn" | grep -qE 'myc_fetch_artifacts|git +fetch|git +pull'; then
	badln "flow_node_apply fetches — it must be local-only (apply the local descriptor, never pull+run code)"
else
	ok "flow_node_apply is local-only (no fetch)"
fi

# 4. no-op short-circuit (byte-identical candidate => no promote/restart).
printf '%s' "$fn" | grep -qE 'cmp -s .*SINGBOX_CONFIG' \
	&& ok "flow_node_apply carries the no-op short-circuit (byte-identical => no restart)" \
	|| badln "flow_node_apply lacks the byte-identical no-op short-circuit (would needlessly restart)"

# 5. dispatch wiring: --node-apply -> MODE=node-apply -> flow_node_apply.
grep -qE '^[[:space:]]*--node-apply\)[[:space:]]*MODE="node-apply"' "$BOOT" \
	&& ok "--node-apply sets MODE=node-apply" \
	|| badln "--node-apply is not wired in arg-parse"
grep -qE '^[[:space:]]*node-apply\)[[:space:]]*flow_node_apply' "$BOOT" \
	&& ok "the node-apply mode dispatches flow_node_apply" \
	|| badln "the node-apply dispatch case is missing"

# 6. NO AUTO-RUN: flow_node_apply is called by nothing but the dispatch case (never flow_bootstrap/update).
calls="$(grep -rnE '(^|[^A-Za-z0-9_])flow_node_apply([^A-Za-z0-9_(]|$)' "$BOOT" "$REPO_ROOT"/control/lib/*.sh 2>/dev/null \
	| grep -vE 'flow_node_apply\(\)' \
	| grep -vE ':[[:space:]]*#' \
	| grep -vE 'node-apply\)[[:space:]]*flow_node_apply' || true)"
if [ -z "$calls" ]; then
	ok "flow_node_apply has no auto-run caller (explicit --node-apply only)"
else
	badln "flow_node_apply is called outside the explicit dispatch: $(printf '%s' "$calls" | tr '\n' '|')"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: flow_node_apply is local-only, fail-closed, and reachable only via the explicit --node-apply mode.\n'
	exit 0
fi
printf 'FAIL: flow_node_apply drifted from local-only / fail-closed / explicit-only — see above.\n' >&2
exit 1
