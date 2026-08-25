#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# update_outcome_is_named.sh — conformance: when an unattended update fails, the node publishes WHICH
# stage failed, says only what is true about it, and does not count a rehearsal as an attempt.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   `mycelium_update_last_failure_reason` is the one surface that tells an operator where to look when a
#   node stops converging. Nothing checked it, and three things were wrong at once (Audit-0015 S2-5):
#
#   1. EVERY render refusal published 9 = "other/unclassified". The three `render` call sites in
#      nb_update_apply.sh — including the two that fire when the Go spine's provenance does not match the
#      deployed artifact, i.e. the most likely refusal on a freshly cut-over node — passed a reason no arm
#      of myc_update_reason_code matched. The code that means "we do not know" was published for the case
#      the vocabulary existed to name.
#   2. The warning asserted "This node is not taking new code" for every reason. That is true for exactly
#      2 of the 11 call sites (signature, fast-forward). On the other 9 the node TOOK the code and refused
#      to serve it — a different fault, a different remedy, and the message sent the operator to the git
#      tip when the renderer was what broke.
#   3. `rotate_apply_dryrun`, whose stated contract is "promotes nothing, mutates no persisted state",
#      reached record_update_failure through render_candidate/validate_config and incremented
#      mycelium_update_consecutive_failures. A rehearsal that correctly refused a candidate raised the
#      metric that means "this node has stopped taking new code", with nothing wrong with updating at all.
#
#   The common shape is this suite's oldest one: a surface reporting confidently about something it did
#   not observe. So the rows below drive the REAL functions with the REAL reason strings found in the
#   tree — a new call site with a new reason fails this gate rather than quietly publishing 9.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the outcome surface is honest; 1 = it is not.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
OBS="$REPO_ROOT/control/lib/nb_observability.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

[ -f "$OBS" ] || { printf 'update_outcome_is_named: %s not found\n' "$OBS" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/myc.uoin.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

printf '== a failed update names its stage, claims only what is true, and a rehearsal is not an attempt ==\n\n'

# ---------------------------------------------------------------------------------------------------
# A driver that sources the REAL lib with the entrypoint's helpers stubbed. Sourcing the lib rather than
# grepping it is the whole point: the defect was a case arm that did not exist, and no amount of reading
# the vocabulary comment would have shown that — the comment was correct and the code did not implement
# it. Everything the lib writes goes to a throwaway STATE_DIR.
# ---------------------------------------------------------------------------------------------------
mk_driver() {   # mk_driver FILE BODY
	cat > "$1" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail
log()  { printf 'log: %s\n' "\$*"; }
warn() { printf 'warn: %s\n' "\$*"; }
die()  { printf 'die: %s\n' "\$*"; exit 1; }
have() { command -v "\$1" >/dev/null 2>&1; }
STATE_DIR="$W/state"
NODE_EXPORTER_TEXTFILE_DIR="$W/state"
DRY_RUN=0
mkdir -p "\$STATE_DIR"
# shellcheck disable=SC1090
. "$OBS"
$2
DRIVER
}

# ---------------------------------------------------------------------------------------------------
# 1. EVERY reason the tree actually passes must resolve to a named code.
#
# The reason set is DERIVED from the call sites, not typed here, so adding a call site with a new reason
# fails this row instead of silently publishing 9.
# ---------------------------------------------------------------------------------------------------
printf '\n-- every reason the tree passes resolves to a named code --\n'
REASONS="$(
	grep -rhoE '_record_update_failure_if_available[[:space:]]+[a-z-]+' \
		"$REPO_ROOT/control" "$REPO_ROOT/scripts" 2>/dev/null \
		| awk '{print $2}' | sort -u
)"
if [ -z "$REASONS" ]; then
	badln "no record_update_failure call sites were found at all — this row would pass on an empty set, which proves nothing"
else
	printf '  (reasons found in the tree: %s)\n' "$(tr '\n' ' ' <<<"$REASONS")"
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		mk_driver "$W/code.sh" "myc_update_reason_code $r"
		got="$(bash "$W/code.sh" 2>/dev/null | tail -1)"
		case "$got" in
			9) badln "the reason '$r' is passed at a live call site and publishes 9 = other/unclassified. The closed vocabulary exists so an operator can tell WHICH stage refused; a reason with no arm is the vocabulary failing on the case it was written for." ;;
			[0-8]) ok "$r -> $got" ;;
			*)  badln "myc_update_reason_code $r emitted '$got', which is not a single digit" ;;
		esac
	done <<<"$REASONS"
fi

# ---------------------------------------------------------------------------------------------------
# 2. The published HELP text and the function must agree, in BOTH directions.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the metric help text and the code agree --\n'
help_line="$(grep -m1 'mycelium_update_last_failure_reason Closed-vocab' "$OBS")"
if [ -z "$help_line" ]; then
	badln "the reason metric publishes no HELP line naming its vocabulary — the code is then a number with no key"
else
	fn_codes="$(awk '/^myc_update_reason_code\(\)/,/^}/' "$OBS" | grep -oE "printf '[0-9]'" | grep -oE '[0-9]' | sort -u)"
	miss=""
	while IFS= read -r c; do
		[ -n "$c" ] || continue
		grep -q "[^0-9]$c " <<<"$help_line" || miss="$miss $c"
	done <<<"$fn_codes"
	[ -z "$miss" ] \
		&& ok "every code the function can emit ($(tr '\n' ' ' <<<"$fn_codes")) is named in the HELP line" \
		|| badln "the function can publish code(s)$miss that the HELP line does not name — an operator reading the metric has no key for them"
fi

# ---------------------------------------------------------------------------------------------------
# 3. "This node is not taking new code" is said only when it is TRUE.
#
# Driven, not grepped: the message is assembled at runtime from the reason.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the warning claims only what the reason supports --\n'
NOT_TAKING='signature fast-forward'
while IFS= read -r r; do
	[ -n "$r" ] || continue
	rm -rf "$W/state"; mkdir -p "$W/state"
	mk_driver "$W/warn.sh" "record_update_failure $r"
	out="$(bash "$W/warn.sh" 2>&1)"
	says_pinned=no
	grep -qi 'NOT TAKING NEW' <<<"$out" && says_pinned=yes
	expect=no
	case " $NOT_TAKING " in *" $r "*) expect=yes ;; esac
	if [ "$says_pinned" = "$expect" ]; then
		[ "$expect" = yes ] \
			&& ok "$r: says the node is pinned at its revision — and it is" \
			|| ok "$r: does NOT claim the tip was refused — the node took the code and refused to serve it"
	elif [ "$says_pinned" = yes ]; then
		badln "on '$r' the node announces it is NOT TAKING NEW CODE. The fetch succeeded; the $r stage refused afterwards. That sends the operator to the git tip to debug a fault on the node."
	else
		badln "on '$r' the node does not say the tip was refused, but that is exactly what happened — the operator is told to look at this node for a fault that is upstream of it"
	fi
done <<<"$REASONS"

# ---------------------------------------------------------------------------------------------------
# 4. A REHEARSAL IS NOT AN ATTEMPT — behaviour first, then the wiring.
# ---------------------------------------------------------------------------------------------------
printf '\n-- a rehearsal does not move the update-failure counter --\n'
rm -rf "$W/state"; mkdir -p "$W/state"
mk_driver "$W/dry.sh" 'MYC_UPDATE_BOOKKEEPING=0 record_update_failure render
printf "counter=%s\n" "$(cat "$STATE_DIR/update_consecutive_failures" 2>/dev/null || printf missing)"'
dry_out="$(bash "$W/dry.sh" 2>&1)"
grep -qE 'counter=(0|missing)' <<<"$dry_out" \
	&& ok "with bookkeeping off the counter is untouched ($(grep -oE 'counter=[a-z0-9]+' <<<"$dry_out"))" \
	|| badln "a suppressed record still moved the counter ($(grep -oE 'counter=[a-z0-9]+' <<<"$dry_out")) — the suppression does not work, so every row below it would prove nothing"

rm -rf "$W/state"; mkdir -p "$W/state"
mk_driver "$W/live.sh" 'record_update_failure render
printf "counter=%s\n" "$(cat "$STATE_DIR/update_consecutive_failures" 2>/dev/null || printf missing)"'
live_out="$(bash "$W/live.sh" 2>&1)"
grep -q 'counter=1' <<<"$live_out" \
	&& ok "and a real attempt still counts (the suppression is not a blanket off-switch)" \
	|| badln "a REAL failed attempt did not increment the counter ($(grep -oE 'counter=[a-z0-9]+' <<<"$live_out")) — the metric that alerts on a stalled node would stay at zero through the stall"

printf '\n-- and every dry-run executor sets it --\n'
RA="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
dryfns="$(grep -oE '^[a-z_]*dryrun\(\)' "$RA" 2>/dev/null | tr -d '()')"
if [ -z "$dryfns" ]; then
	badln "no dry-run executor was found in nb_rotate_apply.sh — the row cannot be evaluated, and an empty set must not read as a pass"
else
	while IFS= read -r fn; do
		[ -n "$fn" ] || continue
		body="$(awk -v f="^$fn\\\\(\\\\)" '$0 ~ f,/^}/' "$RA")"
		# Comments stripped FIRST, on both sides of the count. The prose beside the guard names both the
		# guard and the calls it covers, so counting raw lines let a comment stand in for a guard, and let
		# deleting the prose change the arithmetic on both sides at once.
		code="$(grep -vE '^[[:space:]]*#' <<<"$body")"
		n_calls="$(grep -cE 'render_candidate|validate_config' <<<"$code")"
		n_guard="$(grep -cE 'MYC_UPDATE_BOOKKEEPING=0' <<<"$code")"
		if [ "$n_calls" -eq 0 ]; then
			ok "$fn renders nothing, so it cannot reach the counter"
		elif [ "$n_guard" -ge "$n_calls" ]; then
			ok "$fn guards all $n_calls render/validate call(s)"
		else
			badln "$fn makes $n_calls render/validate call(s) but guards only $n_guard — a rehearsal that refuses a candidate will raise mycelium_update_consecutive_failures, against its own stated contract of mutating no persisted state"
		fi
	done <<<"$dryfns"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the update-outcome surface reports something it did not observe.\n' >&2
	exit 1
fi
printf 'PASS: every stage is named, the warning fits the reason, and a rehearsal is not counted.\n'
exit 0
