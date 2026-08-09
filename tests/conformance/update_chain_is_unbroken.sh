#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# update_chain_is_unbroken.sh — conformance: nothing on `main` can leave a tip the nodes will refuse, and
# when a node DOES refuse, that fact is published rather than left in a journal.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Two unrelated causes put all three nodes into "refusing to update", and BOTH were invisible from
#   every surface anyone watches:
#
#     1. A pull request merged with GitHub's button. `verify_signed_ref` (control/lib/nb_update_apply.sh)
#        runs `git verify-commit` on the tip of origin/main against the operator's allowed-signers file.
#        A locally authored commit carries that signature; a merge commit created by GitHub does not.
#        Every node correctly refused the tip — for four merges running.
#     2. A locally modified checkout on a node, left behind by using it as a build/test host. The
#        fast-forward then cannot apply and the update refuses, also correctly.
#
#   In both cases `main` was green, CI was green, the timer was `active`, the unit was enabled, the data
#   plane kept serving, and the only place the truth appeared was `journalctl -u mycelium-update`. The
#   network stopped taking code for days and nothing said so.
#
#   development.md §6.3 now carries the merge rule in prose. Prose is what we had before; this is the
#   gate. And a rule that only prevents cause 1 leaves cause 2 — and the next cause — just as silent, so
#   the second half of this gate is about the REPORTING, which is cause-agnostic.
#
# WHAT IT CHECKS
#   A. THE CAUSE — no commit on this branch was committed by GitHub's web-flow identity. That identity is
#      the exact, offline-checkable signature of a button merge: `git log --format=%cn` reads
#      `GitHub <noreply@github.com>`. CI cannot verify the OPERATOR's key (the allowed-signers file is
#      out-of-band by design, §8.7) — but it can see who committed, and that is sufficient to catch this.
#   B. THE REPORTING — the refusal sites call the failure recorder, the recorder publishes a consecutive
#      count and a CLOSED-VOCAB reason code, and a success RESETS both. Driven, not grepped.
#   C. NO ERROR TEXT IN THE METRIC — the reason is an integer. An error string can carry a path, a ref or
#      a hostname, and this file is read by node_exporter (§8.5).
#
# OFFLINE. No root, no network. Exit: 0 = the chain holds and a break is visible; 1 = it does not.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'update_chain_is_unbroken: cannot resolve repo root\n' >&2; exit 2; }
OBS="$REPO_ROOT/control/lib/nb_observability.sh"
UPD="$REPO_ROOT/control/lib/nb_update_apply.sh"
for f in "$OBS" "$UPD"; do
	[ -f "$f" ] || { printf 'update_chain_is_unbroken: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.uchain.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

printf '== the update chain: unbreakable at the source, visible when it breaks ==\n'

# ---------------------------------------------------------------------------------------------------
# A. THE CAUSE — no button merges.
# ---------------------------------------------------------------------------------------------------
printf '\n-- nothing here was merged with the GitHub button --\n'
if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	printf '  SKIP  not a git checkout (release tarball); the committer identity cannot be inspected.\n'
else
	# THE BASELINE, named and dated rather than implied. Eight PRs (#10-#17) were merged with the button
	# before this was understood; they are in history and cannot be unmade without a rewrite nobody wants.
	# Failing on them forever would make this gate permanently red, and a permanently red gate is one
	# people learn to skip — which is how the original rule (prose in §6.3) failed. So the check starts
	# AFTER the last of them and guards everything since. If a rewrite ever removes them, this constant
	# becomes unnecessary and the range can widen; until then it is a recorded fact, not an exemption.
	BASELINE="e19dd82"   # Merge pull request #17 — the last button merge, 2026-08-06
	if git -C "$REPO_ROOT" cat-file -e "$BASELINE^{commit}" 2>/dev/null; then
		range="$BASELINE..HEAD"
	else
		# A shallow clone (CI often fetches depth-limited) cannot see the baseline. Fall back to the
		# branch's own commits, which is the range a PR check needs anyway, and say which one ran.
		base="$(git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || printf '')"
		[ -n "$base" ] && range="$base..HEAD" || range="HEAD~1..HEAD"
		printf '  NOTE  baseline %s not in this clone (shallow?); checking %s instead.\n' "$BASELINE" "$range"
	fi
	offenders="$(git -C "$REPO_ROOT" log --format='%h %ce' "$range" 2>/dev/null \
		| awk '$2 == "noreply@github.com" { print $1 }' | head -5)"
	if [ -z "$offenders" ]; then
		ok "no commit in $range carries GitHub's web-flow committer identity"
	else
		badln "these commits were committed by GitHub, i.e. merged with the button: $(printf '%s' "$offenders" | tr '\n' ' '). verify_signed_ref runs \`git verify-commit\` on the tip of origin/main against the operator's allowed-signers file, and a commit GitHub created is not signed by that key — so every node refuses the tip, silently, while main stays green. Merge locally with \`git merge --no-ff\` and push (development.md §6.3)."
	fi
fi

# ---------------------------------------------------------------------------------------------------
# B. THE REPORTING — driven, not grepped.
# ---------------------------------------------------------------------------------------------------
printf '\n-- a refusing node says so, in a metric --\n'
(
	set -u
	STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
	NODE_EXPORTER_TEXTFILE_DIR="$WORK/textfile"; mkdir -p "$NODE_EXPORTER_TEXTFILE_DIR"
	DRY_RUN=0
	log()  { :; }
	warn() { :; }
	die()  { printf 'lib: %s\n' "$*" >&2; exit 1; }
	have() { command -v "$1" >/dev/null 2>&1; }
	run()  { "$@"; }
	# shellcheck source=/dev/null
	. "$OBS" || exit 2
	# AFTER sourcing: the lib assigns NODE_EXPORTER_TEXTFILE_DIR unconditionally at source time, so a
	# value set before the source is overwritten and the fixture would write into the REAL node_exporter
	# directory — which on a node is a live metrics surface, and in a sandbox simply does not exist. The
	# first draft did exactly that and every row read an empty metric.
	NODE_EXPORTER_TEXTFILE_DIR="$WORK/textfile"

	prom="$NODE_EXPORTER_TEXTFILE_DIR/mycelium_update.prom"
	metric() { sed -n "s/^$1 //p" "$prom" 2>/dev/null | head -1; }

	fail=0
	record_update_failure signature
	[ "$(metric mycelium_update_consecutive_failures)" = "1" ] \
		&& printf '  ok    a refused attempt publishes a consecutive-failure count\n' \
		|| { printf '  FAIL  the failure count is %s after one refusal — a stalled node stays invisible\n' "$(metric mycelium_update_consecutive_failures)"; fail=1; }
	[ "$(metric mycelium_update_last_failure_reason)" = "1" ] \
		&& printf '  ok    and the reason, as a closed-vocab code (1 = signature)\n' \
		|| { printf '  FAIL  the reason code is %s, expected 1 for a signature refusal\n' "$(metric mycelium_update_last_failure_reason)"; fail=1; }

	record_update_failure fast-forward
	record_update_failure fast-forward
	[ "$(metric mycelium_update_consecutive_failures)" = "3" ] \
		&& printf '  ok    consecutive refusals accumulate (3)\n' \
		|| { printf '  FAIL  three refusals produced a count of %s; a count that does not rise cannot be alerted on\n' "$(metric mycelium_update_consecutive_failures)"; fail=1; }
	[ "$(metric mycelium_update_last_failure_reason)" = "2" ] \
		&& printf '  ok    and the reason follows the LATEST refusal (2 = fast-forward)\n' \
		|| { printf '  FAIL  the reason code is %s, expected 2\n' "$(metric mycelium_update_last_failure_reason)"; fail=1; }

	record_converge_ok
	{ [ "$(metric mycelium_update_consecutive_failures)" = "0" ] && [ "$(metric mycelium_update_last_failure_reason)" = "0" ]; } \
		&& printf '  ok    a success RESETS both — a recovered node stops reporting a stall\n' \
		|| { printf '  FAIL  after a success the count is %s and the reason %s. A counter that never clears reports a stall on a healthy node, which trains people to ignore it.\n' "$(metric mycelium_update_consecutive_failures)" "$(metric mycelium_update_last_failure_reason)"; fail=1; }
	[ -n "$(metric mycelium_update_last_success_timestamp_seconds)" ] \
		&& printf '  ok    and the success timestamp is still published alongside\n' \
		|| { printf '  FAIL  the success timestamp vanished when the failure series were added\n'; fail=1; }

	# C. NO TEXT. The reason must be an integer; an error string can carry a path or a ref.
	record_update_failure "could not fetch from https://example.invalid/secret-path"
	if grep -qiE 'example\.invalid|secret-path|https?://' "$prom"; then
		printf '  FAIL  the metric file contains error TEXT. It is read by node_exporter, and an error string can carry a path, a ref or a hostname (§8.5).\n'; fail=1
	else
		printf '  ok    an unclassified reason emits a code, never the error text\n'
	fi
	[ "$(metric mycelium_update_last_failure_reason)" = "9" ] \
		&& printf '  ok    and it maps to the catch-all code (9)\n' \
		|| { printf '  FAIL  an unknown reason produced code %s, expected 9\n' "$(metric mycelium_update_last_failure_reason)"; fail=1; }
	exit "$fail"
) || fail=1

# ---------------------------------------------------------------------------------------------------
# D. THE REFUSAL SITES CALL IT. A recorder nothing invokes is the same silence with more code.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the refusals that stalled the network are the ones instrumented --\n'
strip() { sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$1"; }
for pair in "signature verification FAILED:signature" "fast-forward update failed:fast-forward"; do
	msg="${pair%%:*}"; reason="${pair##*:}"
	line="$(strip "$UPD" | grep -F "$msg" | head -1)"
	if [ -z "$line" ]; then
		badln "the refusal '$msg' is gone from nb_update_apply.sh — either it was renamed (update this gate) or the fail-closed refusal was removed"
	elif printf '%s' "$line" | grep -qF "_record_update_failure_if_available $reason"; then
		ok "the '$reason' refusal records itself before dying"
	else
		badln "the refusal '$msg' does not record the failure. It is one of the two that stalled every node for days with nothing but a journal entry to show for it."
	fi
done

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the update chain can break silently.\n' >&2
	exit 1
fi
printf 'PASS: no button merge on this branch, and a node that refuses an update publishes the fact.\n'
exit 0
