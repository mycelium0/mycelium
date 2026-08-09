#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# bootstrap_from_zero_survives.sh — conformance: the FIRST install on a machine that has never run this
# software must not be killed by the absence of state it has not created yet, and an unexpected death
# must name itself.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS — it was measured, on a wiped production node, not imagined.
#
#   A from-zero `fungi deploy` exited 1 after 50 seconds having printed NOT ONE line of error. sing-box
#   was already promoted and running; AmneziaWG was half-configured; the operator got a half-installed
#   host and an exit code. Finding the cause needed `bash -x`, and it was one line:
#
#       [ -n "$port" ] || port="$(cat "$STATE_DIR/awg.port" 2>/dev/null)"
#
#   On a node with no port cache — which is EVERY fresh node — `cat` exits 1, the assignment inherits
#   that status, the `||` list inherits it, and `set -euo pipefail` terminates the bootstrap. The
#   `2>/dev/null` swallowed the only clue. The next two lines already treat an empty value as "use the
#   canonical default", so there was never anything for the failure to signal.
#
#   Every node in this network was bootstrapped before that shape existed, so nothing on any of them
#   could notice, and no gate looked: the whole suite runs against nodes and fixtures that already have
#   state. THE FIRST RUN IS THE ONE PATH NOTHING ELSE COVERS.
#
# WHAT IT CHECKS, by DRIVING the shipped code against a state directory that is genuinely empty
#   1. `_awg_resolve_port` under `set -e` with NO cache and NO awg0.conf returns 0 and yields the
#      canonical default. This is the exact line that killed the install.
#   2. The class, not just the instance: no lib assigns from a command substitution in a bare `||` list
#      where the substitution is allowed to fail. That construct is invisible in review and fatal at run
#      time under `set -e`.
#   3. The entrypoint installs an ERR trap with `set -E`, and a deliberate `die` is excluded from it. A
#      refusal explains itself; a bug must not be quieter than a refusal.
#
# OFFLINE. No root, no network. Exit: 0 = a first run survives and a bug announces itself; 1 = it does not.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'bootstrap_from_zero_survives: cannot resolve repo root\n' >&2; exit 2; }
AWG="$REPO_ROOT/control/lib/nb_render_awg.sh"
ENTRY="$REPO_ROOT/scripts/node-bootstrap.sh"
for f in "$AWG" "$ENTRY"; do
	[ -f "$f" ] || { printf 'bootstrap_from_zero_survives: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.zero.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

printf '== the first install on a machine that has never run this ==\n'

# ---------------------------------------------------------------------------------------------------
# 1. THE EXACT LINE. Driven under `set -e`, against genuinely absent state.
# ---------------------------------------------------------------------------------------------------
printf '\n-- resolving the AmneziaWG port with no cache and no config --\n'
out="$(
	set -euo pipefail
	STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
	MYC_AWG_CONF="$WORK/absent-awg0.conf"     # deliberately does not exist
	DRY_RUN=0
	log()  { :; }
	warn() { :; }
	die()  { printf 'lib-die: %s\n' "$*" >&2; exit 1; }
	have() { command -v "$1" >/dev/null 2>&1; }
	run()  { "$@"; }
	# shellcheck source=/dev/null
	. "$AWG" 2>/dev/null || { printf 'SOURCE-FAILED'; exit 0; }
	_awg_resolve_port
	printf ' rc=%s' "$?"
)" 2>/dev/null
rc=$?
case "$out" in
	SOURCE-FAILED) badln "could not source nb_render_awg.sh standalone — this section would prove nothing" ;;
	*)
		if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
			badln "_awg_resolve_port DIED (rc=$rc, output '$out') on a state dir with no awg.port and no awg0.conf. That is every fresh node, and under the entrypoint's \`set -euo pipefail\` this kills the whole bootstrap — measured: rc=1 after 50s, sing-box already running, AmneziaWG half-configured, and NOT ONE line of error because the \`2>/dev/null\` swallowed it."
		else
			ok "it returns cleanly and yields a port (${out%% *}) — a fresh node is not killed by its own missing cache"
		fi ;;
esac

# ---------------------------------------------------------------------------------------------------
# 2. THE CLASS. One instance was found by wiping a node; the construct must not return.
# ---------------------------------------------------------------------------------------------------
printf '\n-- no bare assignment from a substitution that is allowed to fail --\n'
# `x="$(cmd ...)"` as the RIGHT side of a bare `||`, with no `|| true` inside the substitution. Under
# `set -e` the list's status is the assignment's, and the assignment's is the substitution's.
offenders="$(grep -rnE '\|\|[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*="\$\([^)]*\)"[[:space:]]*$' \
	"$REPO_ROOT"/control/lib/*.sh "$REPO_ROOT"/scripts/*.sh 2>/dev/null \
	| grep -v '|| true)' | head -5)"
if [ -z "$offenders" ]; then
	ok "no lib ends a bare \`||\` list with an assignment from a fallible substitution"
else
	badln "these lines can kill a run under \`set -e\` with no message: $(printf '%s' "$offenders" | tr '\n' ' ' | cut -c1-300). The status of \`x=\$(cmd)\` is cmd's, the \`||\` list inherits it, and a \`2>/dev/null\` on the inner command hides the cause. Put \`|| true\` INSIDE the substitution where the empty value is acceptable."
fi

# ---------------------------------------------------------------------------------------------------
# 3. A BUG MUST NOT BE QUIETER THAN A REFUSAL.
# ---------------------------------------------------------------------------------------------------
printf '\n-- an unexpected death names itself --\n'
strip() { sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$1"; }
body="$(strip "$ENTRY")"

printf '%s' "$body" | grep -qE "^trap .*ERR" \
	&& ok "the entrypoint installs an ERR trap" \
	|| badln "no ERR trap in scripts/node-bootstrap.sh. Any command that trips \`set -e\` then exits silently — which is exactly how a from-zero install failed with an empty log and cost a bash -x to diagnose."
printf '%s' "$body" | grep -qE "^set -E$|^set -[a-zA-Z]*E" \
	&& ok "and \`set -E\`, without which the trap never fires inside a function" \
	|| badln "the ERR trap is installed without \`set -E\`. Traps are NOT inherited by functions or subshells by default, so every failure inside control/lib/* — i.e. nearly all of them — would still be silent."
printf '%s' "$body" | grep -q 'MYC_DELIBERATE_EXIT=1' \
	&& ok "and a deliberate \`die\` is excluded, so a refusal is not reported twice as a bug" \
	|| badln "die() does not mark its exit deliberate; every fail-closed refusal would also print an UNEXPECTED-failure block, which trains people to ignore both"

# The trap must actually FIRE — assert the mechanism, not its source text.
probe="$(
	bash -c '
		set -Eeuo pipefail
		MYC_DELIBERATE_EXIT=0
		_t() { printf "TRAPPED:%s\n" "$3"; }
		trap '"'"'_t "$?" "$LINENO" "$BASH_COMMAND"'"'"' ERR
		f() { local p=""; [ -n "$p" ] || p="$(cat /nonexistent-probe 2>/dev/null)"; }
		f
	' 2>&1 | head -1
)"
case "$probe" in
	TRAPPED:*) ok "and the mechanism fires on this exact construct, from inside a function" ;;
	*)         badln "the ERR-trap mechanism did not fire on the very construct that caused the outage (got '$probe'). Then the guard is source text, not behaviour." ;;
esac

# ---------------------------------------------------------------------------------------------------
# 4. A CONVERGE THAT DOES NOTHING MUST NOT REPORT SUCCESS.
#
# MYC_NB_NO_DISPATCH=1 exists so a test can SOURCE the entrypoint and reach its pure helpers. Executed
# with the variable set, the guard skipped every flow, control fell off the end of the script, and it
# exited **0** — measured. That is the worst shape a failure can take here: indistinguishable from a
# converge that worked. And it is an ordinary exported string, so a CI runner, a drill harness, or a
# shell that had once run the rotate gate could be carrying it — which would make a from-zero install
# drill green on a host where nothing whatsoever had been installed.
printf '\n-- a no-op converge cannot report success --\n'
out="$(MYC_NB_NO_DISPATCH=1 bash "$ENTRY" --clients probe 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
	badln "MYC_NB_NO_DISPATCH=1 with the entrypoint EXECUTED exited 0 having run no flow at all. A converge that silently does nothing and reports success is indistinguishable from one that worked; any drill or CI job carrying that variable would certify an empty host."
elif printf '%s' "$out" | grep -q 'EXECUTED, not sourced'; then
	ok "an executed run refuses the sourcing-only seam and says why (rc=$rc)"
else
	badln "an executed run under MYC_NB_NO_DISPATCH=1 exited $rc but did not explain itself: '$(printf '%s' "$out" | head -1 | cut -c1-160)'. A refusal nobody can read is one people work around by re-exporting the variable."
fi
# ...and the seam must STILL work for the thing it exists for.
# Clear the positional parameters first: the entrypoint parses "$@" at source time and would die on
# this gate's own arguments before defining a single function (rotate_rollback_executes.sh:98-101
# records the same trap).
srcd="$(MYC_NB_NO_DISPATCH=1 bash -c 'set --; . "$0" >/dev/null 2>&1; command -v flow_bootstrap >/dev/null && echo REACHED' "$ENTRY" 2>/dev/null)"
[ "$srcd" = "REACHED" ] \
	&& ok "and sourcing still reaches the entrypoint's functions — the seam is narrowed, not removed" \
	|| badln "sourcing the entrypoint under MYC_NB_NO_DISPATCH=1 no longer reaches its functions. That seam is the only way a test can drive verify_post_apply and the rotation rollback branch; closing it makes those paths untestable again."

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a first install can still die on absent state, or die without saying so.\n' >&2
	exit 1
fi
printf 'PASS: a fresh node survives its own missing state, and an unexpected failure names its line.\n'
exit 0
