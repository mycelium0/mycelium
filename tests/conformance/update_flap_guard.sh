#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# update_flap_guard.sh — conformance: the UNATTENDED updater must not re-promote a candidate it has
# already watched fail at runtime, and the guard that stops it must never become permanent.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   flow_update is armed on live nodes by a systemd timer. `sing-box check` validates SCHEMA only, so a
#   candidate that fails at RUNTIME reaches promote -> restart -> verify_post_apply -> rollback ->
#   restart -> die. `merge --ff-only` is a no-op once merged, so the next tick re-renders the SAME
#   candidate and the node flaps forever: two sing-box restarts per tick, each dropping live client
#   connections. The fix is a bounded, escalating refusal to re-promote a candidate byte-identical to
#   the last failed one. This gate pins BOTH halves — that the refusal exists, and that it is BOUNDED,
#   SELF-CLEARING and NARROW, because a guard that can wedge updates is worse than the flap.
#
# OFFLINE + INSPECT-ONLY. Exit: 0 = pinned; 1 = violation; 2 = usage/env error.
set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'update_flap_guard: cannot resolve repo root\n' >&2; exit 2; }
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
[ -f "$NB" ] || { printf 'update_flap_guard: missing %s\n' "$NB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }
at()    { printf '%s\n' "$code" | grep -nE "$1" | head -1 | cut -d: -f1; }

printf '== unattended updater: bounded anti-flap guard on the promote path ==\n'

fn="$(awk '/^flow_update\(\)/{f=1} f{print} /^}/{if(f)exit}' "$NB")"
[ -n "$fn" ] || { badln "flow_update not found in $NB"; printf 'FAIL\n' >&2; exit 1; }
# Ordering runs over CODE only: a comment that merely NAMES a step must not satisfy an assertion.
code="$(printf '%s\n' "$fn" | grep -vE '^[[:space:]]*#')"

# 1. The guard consults the failed-candidate snapshot BEFORE promote_config.
g="$(at 'cmp -s "\$candidate" "\$FAILED_CONFIG"')"; p="$(at 'promote_config')"
if [ -n "$g" ] && [ -n "$p" ] && [ "$g" -lt "$p" ]; then
	ok "flow_update compares the candidate against \$FAILED_CONFIG before promote_config"
else
	badln "no byte-identity check against \$FAILED_CONFIG before promoting (guard@${g:-none} promote@${p:-none}) — a runtime-bad candidate is re-promoted every tick"
fi

# 2. BOUNDED: the refusal is gated on an AGE vs a computed hold, and the hold is capped.
printf '%s' "$code" | grep -qE '\[ "\$fage" -lt "\$fhold" \]' \
	&& ok "the refusal is bounded by an age test (\$fage < \$fhold)" \
	|| badln "the refusal has no age test — it could suppress updates PERMANENTLY (worse than the flap)"
printf '%s' "$code" | grep -qE '\-le "\$UPDATE_RETRY_HOLD_MAX_SEC" \] \|+ fhold="\$UPDATE_RETRY_HOLD_MAX_SEC"' \
	&& ok "the hold is clamped to \$UPDATE_RETRY_HOLD_MAX_SEC (escalation cannot run away)" \
	|| badln "the hold is not clamped to \$UPDATE_RETRY_HOLD_MAX_SEC — an escalating hold with no cap can wedge updates"
for v in UPDATE_RETRY_HOLD_MIN_SEC UPDATE_RETRY_HOLD_MAX_SEC; do
	d="$(grep -E "^$v=" "$NB" | head -1)"
	printf '%s' "$d" | grep -qE "^$v=\"\\\$\{$v:-[1-9][0-9]*\}\"" \
		&& ok "$v has a finite, non-zero, env-overridable default" \
		|| badln "$v is missing, zero, or not env-overridable: ${d:-<absent>}"
done

# 3. FAIL-SAFE: an unreadable mtime/clock must fall through to promoting, not to holding.
printf '%s' "$code" | grep -qE 'fage=-1' && printf '%s' "$code" | grep -qE '\[ "\$fage" -ge 0 \]' \
	&& ok "an unreadable mtime/clock yields fage=-1 and falls through to promote (fail-safe)" \
	|| badln "no fage=-1 / -ge 0 fail-safe: a missing stat(1) or date(1) could hold instead of promote"

# 4. The failed candidate is snapshotted BEFORE rollback_config (after it, the bytes are gone).
r="$(at 'install -m 0600 .*FAILED_CONFIG')"; b="$(at 'rollback_config')"
if [ -n "$r" ] && [ -n "$b" ] && [ "$r" -lt "$b" ]; then
	ok "the failed candidate is snapshotted 0600 before rollback_config restores the last known-good"
else
	badln "the failed candidate is not snapshotted 0600 before rollback_config (record@${r:-none} rollback@${b:-none}) — nothing to compare next tick, or the secrets-bearing snapshot is over-permissive"
fi

# 5. SELF-CLEARING on BOTH proven-good paths: the verified apply AND the byte-identical short-circuit
#    (the state an operator reaches after fixing the cause out of band with --node-apply).
n="$(printf '%s\n' "$code" | grep -cE 'rm -f "\$FAILED_CONFIG" "\$FAILED_SINCE"')"
c1="$(at 'rm -f "\$FAILED_CONFIG" "\$FAILED_SINCE"')"
if [ "$n" -ge 2 ] && [ -n "$c1" ] && [ -n "$p" ] && [ "$c1" -lt "$p" ]; then
	ok "the anti-flap record is cleared on both proven-good paths (short-circuit and verified apply)"
else
	badln "the anti-flap record is not cleared on both proven-good paths (clears=$n first@${c1:-none} promote@${p:-none}) — a stale record would outlive the failure that caused it"
fi

# 6. NARROW: no OPERATOR-driven flow may consult the unattended timer's failure record.
scope_bad=""
for f in "$NB" "$REPO_ROOT"/control/lib/nb_*.sh; do
	[ -f "$f" ] || continue
	blocks="$(awk '/^(flow_ack|flow_node_apply|flow_revoke|flow_disable_two_hop|rotate_apply_live)\(\)/{f=1} f{print} /^}/{if(f)f=0}' "$f")"
	printf '%s' "$blocks" | grep -q 'FAILED_CONFIG\|FAILED_SINCE' && scope_bad="$scope_bad $(basename "$f")"
done
if [ -n "$scope_bad" ]; then
	badln "an OPERATOR-driven flow consults the failure record (in:$scope_bad) — an ack/apply/rotate must never be blocked by the timer's record"
else
	ok "only the unattended flow_update consults the failure record (operator paths are never blocked)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the unattended updater can re-promote a known-bad candidate every tick, or its guard can wedge updates.\n' >&2
	exit 1
fi
printf 'PASS: a known-bad candidate is not re-promoted, the refusal is bounded, self-clearing and narrow.\n'
exit 0
