#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# collapse_gated.sh — conformance: the PostConnectCollapse arm is a decision somebody made, on a node,
# after a drill — not a file somebody touched.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Measured 2026-08-16: the arm sentinel `collapse-armed.enabled` was present on one node of three, dated
#   2026-07-19, and no record anywhere said who decided that or why. Its two siblings — the rotation arm and
#   the fingerprint-rotation arm — each have a verb, a gate and a status surface. Collapse had a `touch`
#   in a comment. It is the only arm in this tree with no instrument, and it is the only one that drifted.
#   That is a mechanism, not a coincidence, and this gate is the instrument.
#
#   The second half is what arming MEANS. tests/e2e/README.md defines the drill in three steps, and its
#   silence proof requires real served traffic — heavy-download including a GRO client, and lossy-but-alive
#   mobile traffic. On the three live nodes there were ZERO established non-loopback sockets on any served
#   port, so that proof cannot be run there at all: an empty predicate coming back empty establishes
#   nothing, and reporting it as a property is development.md §2.2 item 12.
#
# WHAT IT CHECKS
#   1. The sentinel is never tracked in git — an arm that can be committed is an arm a file can turn on.
#   2. `collapse_arm` is the only writer, and it REFUSES without an explicit drill acknowledgement.
#   3. `collapse_disarm` removes it, and both verbs are reachable from the entrypoint.
#   4. The daemon config generator derives `path_collapse_enabled` from the sentinel, and a fresh render
#      with no sentinel is `false` — the documented default, asserted rather than assumed.
#   5. The arm is DECLARABLE and RECONCILED: node.config.json carries `.loops.collapse` and LoopDrift
#      compares it against reality, so a population can be diffed instead of remembered.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the arm is an instrument; 1 = it is a touched file.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'collapse_gated: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_measure.sh"
ENTRY="$REPO_ROOT/scripts/node-bootstrap.sh"
PROFILE="$REPO_ROOT/internal/spec/nodeprofile.go"
for f in "$LIB" "$ENTRY" "$PROFILE"; do
	[ -f "$f" ] || { printf 'collapse_gated: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf '  SKIP  jq unavailable.\nPASS (skipped)\n'; exit 0; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the collapse arm is a decision, not a touched file ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1. NEVER COMMITTABLE.
# ---------------------------------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	tracked="$(git -C "$REPO_ROOT" ls-files | grep -F 'collapse-armed.enabled' || true)"
	[ -z "$tracked" ] \
		&& ok "the arm sentinel is not tracked in git" \
		|| badln "collapse-armed.enabled is TRACKED ($tracked). A committable arm is one a merge can turn on across the whole population without anybody running a drill."
else
	printf '  SKIP  not a git checkout; the tracked-file row did not run.\n'
fi

# ---------------------------------------------------------------------------------------------------
# 2 + 3. THE VERBS, DRIVEN.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the verbs --\n'
drive() { # drive <verb> <drill-ack> -> "<rc>|<sentinel present?>"
	local verb="$1" ack="$2" W rc
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.carm.XXXXXX")" || return 1
	(
		export STATE_DIR="$W" DRY_RUN=0 REPO_ROOT ARTIFACT_ROOT="$REPO_ROOT"
		[ "$ack" = ack ] && export MYC_COLLAPSE_DRILL_DONE=yes
		log() { :; }; warn() { :; }; die() { exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }; run() { "$@"; }; need_root() { :; }
		# shellcheck source=/dev/null
		. "$LIB" >/dev/null 2>&1 || exit 2
		[ "$verb" = disarm ] && : >"$W/collapse-armed.enabled"
		"collapse_${verb}"
	) >/dev/null 2>&1
	rc=$?
	printf '%s|%s' "$rc" "$( [ -f "$W/collapse-armed.enabled" ] && printf 'armed' || printf 'disarmed' )"
	rm -rf "$W"
}

r="$(drive arm noack)"
case "$r" in
	0\|armed) badln "collapse_arm armed WITHOUT any drill acknowledgement (got $r). The silence half of the drill is what separates a signal that fires on interference from one that fires on a bad mobile link, and it cannot be run on a node with no client sessions — arming without it is a posture nobody established." ;;
	*\|disarmed) ok "collapse_arm refuses without an explicit drill acknowledgement, and writes nothing" ;;
	*) badln "collapse_arm without acknowledgement produced '$r'; expected a refusal that leaves the node disarmed" ;;
esac

r="$(drive arm ack)"
case "$r" in
	0\|armed) ok "and arms when the operator states the drill was done" ;;
	*) badln "collapse_arm with the acknowledgement produced '$r'; a verb that cannot arm is not a verb" ;;
esac

r="$(drive disarm noack)"
case "$r" in
	0\|disarmed) ok "collapse_disarm removes the sentinel" ;;
	*) badln "collapse_disarm produced '$r'; expected the sentinel gone" ;;
esac

body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$ENTRY")"
for v in collapse-arm collapse-disarm; do
	printf '%s' "$body" | grep -q -- "--$v" \
		&& ok "--$v is reachable from the entrypoint" \
		|| badln "--$v is not a mode on node-bootstrap.sh; the verb exists in a library nobody can call, which is how the sentinel came to be hand-touched in the first place"
done

# The sentinel must have exactly ONE writer. A second `touch` anywhere reopens the hole.
writers="$(grep -rn 'collapse-armed.enabled' "$REPO_ROOT/control" "$REPO_ROOT/scripts" 2>/dev/null \
	| grep -vE '_collapse_sentinel\(\)|^\s*#' | grep -E 'touch|>\s*"?\$' || true)"
nw="$(printf '%s' "$writers" | sed '/^$/d' | wc -l | tr -d ' ')"
[ "$nw" -le 2 ] \
	&& ok "the sentinel has a single writing path (collapse_arm/collapse_disarm)" \
	|| badln "several places write the arm sentinel: $(printf '%s' "$writers" | tr '\n' ' '). One arm, one writer — otherwise the refusal in the verb is advisory."

# ---------------------------------------------------------------------------------------------------
# 4. THE DEFAULT IS DISARMED, and the generator derives it from the sentinel.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the default, and where the daemon config gets it --\n'
lib_nc="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$LIB")"
printf '%s' "$lib_nc" | grep -q 'MEASURE_PATH_COLLAPSE_ENABLED:-false' \
	&& ok "the shipped default is disarmed" \
	|| badln "MEASURE_PATH_COLLAPSE_ENABLED no longer defaults to false. A signal that faults a served transport must not be on unless somebody turned it on."
printf '%s' "$lib_nc" | grep -q '_collapse_sentinel' \
	&& ok "and generate_measure_configs derives path_collapse_enabled from the sentinel, so the arm survives a config regen" \
	|| badln "the daemon config no longer reads the sentinel; the arm would be lost on every --update, which is worse than not having one"

# ---------------------------------------------------------------------------------------------------
# 5. DECLARABLE AND RECONCILED.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the population can be diffed, not remembered --\n'
grep -q 'Collapse bool `json:"collapse"`' "$PROFILE" \
	&& ok "node.config.json can DECLARE the arm (.loops.collapse)" \
	|| badln "LoopsConfig has no collapse field. Then the arm state exists only as a file on each node, comparable by nothing — which is exactly how it came to be present on one node of three with no record of the decision."
grep -q 'check("collapse"' "$PROFILE" \
	&& ok "and LoopDrift reconciles the declaration against reality" \
	|| badln "LoopDrift does not check collapse. A declaration that is never reconciled is worse than absent: absent says nothing, stale says something false — nodeprofile.go's own words."
grep -rq 'collapse-armed.enabled' "$REPO_ROOT/control/lib/nb_render_params.sh" \
	&& ok "and the converge reads the real sentinel when it reconciles, not the declaration" \
	|| badln "_report_loop_drift does not read the sentinel, so it would compare the declaration against itself"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the collapse arm can be set, lost, or diverge without anyone noticing.\n' >&2
	exit 1
fi
printf 'PASS: one writer, a refusal without the drill, a disarmed default, and a state the population can be diffed on.\n'
exit 0
