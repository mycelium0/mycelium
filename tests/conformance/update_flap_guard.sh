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
# WHY IT EXECUTES THE LADDER (Audit-0009 M1/O1)
#   This gate used to verify the arithmetic by GREPPING FOR ITS SPELLING. Mutation testing at ab39d67
#   showed the incentive inverted: reversing a subtraction so the guard never holds, and swapping the
#   floor for the cap so every transient blip charges six hours, both left 9/9 assertions green — while a
#   pure rename with zero behaviour change turned two of them red. The arithmetic now lives in a PURE
#   helper (myc_update_retry_hold, control/lib/nb_update_apply.sh) that this gate SOURCES AND RUNS over a
#   value table, so the ladder is checked by its outputs. Both mutants above must fail that table.
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

# 2. BOUNDED: the refusal is gated on an AGE vs a computed hold, and the call site delegates the
#    arithmetic to the pure helper rather than open-coding it again.
grep -qE '\[ "\$[a-z_]+" -lt "\$[a-z_]+" \]' <<<"$code" \
	&& ok "the refusal is bounded by a strict age-vs-hold test (any naming)" \
	|| badln "the refusal has no age test — it could suppress updates PERMANENTLY (worse than the flap)"
grep -q 'myc_update_retry_hold' <<<"$code" \
	&& ok "flow_update delegates the hold arithmetic to myc_update_retry_hold (executable, not inline)" \
	|| badln "flow_update computes the hold inline again — the ladder below verifies the helper, so an inline copy is unverified by construction"
for v in UPDATE_RETRY_HOLD_MIN_SEC UPDATE_RETRY_HOLD_MAX_SEC; do
	d="$(grep -E "^$v=" "$NB" | head -1)"
	grep -qE "^$v=\"\\\$\{$v:-[1-9][0-9]*\}\"" <<<"$d" \
		&& ok "$v has a finite, non-zero, env-overridable default" \
		|| badln "$v is missing, zero, or not env-overridable: ${d:-<absent>}"
done

# 3. THE LADDER, EXECUTED. Source the pure helper and drive it over a value table: the documented
#    escalation, the cap, and every fail-safe input. `0 0` means "no hold" (age < hold is then false),
#    which is the promote direction — a broken calculator must degrade to today's un-throttled path, not
#    invent a hold. NOW-FMTIME is fixed at 4000s throughout; only the attempt count varies.
LIB="$REPO_ROOT/control/lib/nb_update_apply.sh"
if [ ! -f "$LIB" ]; then
	badln "control/lib/nb_update_apply.sh is missing — cannot execute the hold ladder"
else
	ladder_out="$(
		set -u
		UPDATE_RETRY_HOLD_MIN_SEC=3600 UPDATE_RETRY_HOLD_MAX_SEC=21600
		# shellcheck source=/dev/null
		. "$LIB" 2>/dev/null
		command -v myc_update_retry_hold >/dev/null 2>&1 || { printf 'MISSING\n'; exit 0; }
		#            label            attempts fmtime now
		for spec in  "attempt-1:1:1000:5000"   "attempt-2:2:1000:5000"   "attempt-3:3:1000:5000" \
		             "attempt-4:4:1000:5000"   "attempt-5:5:1000:5000"   "attempt-99:99:1000:5000" \
		             "no-mtime:3::5000"        "junk-mtime:3:abc:5000"   "no-now:3:1000:" \
		             "clock-back:3:5000:1000"  "no-count:.:1000:5000"    "junk-count:x:1000:5000"; do
			IFS=: read -r lbl a m n <<<"$spec"
			[ "$a" = "." ] && a=""
			printf '%s=%s\n' "$lbl" "$(myc_update_retry_hold "$a" "$m" "$n")"
		done
	)"
	if grep -q 'MISSING' <<<"$ladder_out" ; then
		badln "myc_update_retry_hold is not defined in control/lib/nb_update_apply.sh — the hold arithmetic is unverifiable"
	else
		# The documented ramp: 1h, 1h, 2h, 4h, 6h, 6h… The mutation that pins the hold at the floor and the
		# one that pins it at the cap each break a DIFFERENT row here, so neither can pass this table.
		expect() {
			got="$(printf '%s\n' "$ladder_out" | grep "^$1=" | head -1 | cut -d= -f2-)"
			if [ "$got" = "$2" ]; then ok "hold ladder: $1 -> $2"
			else badln "hold ladder: $1 gave '${got:-<none>}', expected '$2' — the escalation does not match the documented 1h/1h/2h/4h/6h ramp"; fi
		}
		expect attempt-1  "3600 4000"
		expect attempt-2  "3600 4000"
		expect attempt-3  "7200 4000"
		expect attempt-4  "14400 4000"
		expect attempt-5  "21600 4000"
		expect attempt-99 "21600 4000"
		# Fail-safe rows: no usable input may produce a hold.
		expect no-mtime   "0 0"
		expect junk-mtime "0 0"
		expect no-now     "0 0"
		expect clock-back "0 0"
		# An unreadable count throttles at the FLOOR — the one input that degrades toward holding, and only
		# to the minimum, because the count is rewritten on every failure and self-heals next tick.
		expect no-count   "3600 4000"
		expect junk-count "3600 4000"
	fi
fi

# 3b. ESCALATION IS BY ATTEMPT, NOT CALENDAR TIME (Audit-0009 P1), and the count survives deletion of its
#     own file (P2): the failure path rewrites it UNCONDITIONALLY, next to the snapshot it belongs to.
if grep -qE '([a-z_]+)=\$\(\( \1 \+ 1 \)\)' <<<"$code" ; then
	ok "the failure path increments a consecutive-failure count (escalation cannot be skewed by a cadence gap)"
else
	badln "the failure path does not increment an attempt count — an escalation derived from calendar time sends the second failure of a candidate straight to the cap after any gap in the timer's cadence"
fi
# here-string, not a pipe: `grep -m1` exits on the first match and closes it, the producer dies of
# SIGPIPE, and under pipefail this function would return failure for a line it FOUND.
depth_of() { grep -m1 -- "$1" <<<"$code" | sed -E 's/[^\t].*$//' | awk '{print length}'; }
w="$(depth_of 'install -m 0600 /dev/null "$FAILED_SINCE"')"
sn="$(depth_of 'install -m 0600 "$SINGBOX_CONFIG" "$FAILED_CONFIG"')"
if [ -n "$w" ] && [ -n "$sn" ] && [ "$w" -le "$sn" ]; then
	ok "the attempt count is rewritten unconditionally with the snapshot (removing it cannot strand the ladder)"
else
	badln "the attempt count is written only under a condition — if that file is removed externally it is never recreated and a permanently-bad candidate is retried at the floor forever (Audit-0009 P2)"
fi

# 3c. THE HOLD CONSULTS LIVENESS (Audit-0009 A1). Its justification is the live connections two restarts
#     would drop; when the engine is down there are none, and the held candidate is the only untried
#     config the node has left. The refusal must stand down there rather than extend the outage.
hold_region="$(printf '%s\n' "$code" | awk '/\[ "\$fage" -lt "\$fhold" \]/{f=1} f{print} f&&/^\t\tfi$/{exit}')"
if grep -q 'is-active --quiet sing-box' <<<"$hold_region" ; then
	ok "the hold stands down when sing-box is not active (it never extends an outage it cannot shorten)"
else
	badln "the hold does not consult data-plane liveness — on a node whose rollback ALSO failed to start, the refusal declines the only untried config for up to 6h while the node serves nothing"
fi

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
	grep -q 'FAILED_CONFIG\|FAILED_SINCE' <<<"$blocks" && scope_bad="$scope_bad $(basename "$f")"
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
