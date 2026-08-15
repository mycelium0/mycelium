#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# served_set_is_what_is_served.sh — conformance: the MEASURE plane judges the transports this node is
# actually serving, and stops judging one it has stopped serving.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Measured on all three live nodes on 2026-08-15, over at least three days of journal. A member the
#   node had stopped serving was still listed in `measure.config.json` members[] and still anchored in
#   `reach.config.json`. Its loopback probe therefore failed for ever; it was permanently the
#   most-impaired member; it won subject selection on every tick; and the node performed a rotation every
#   thirty minutes — roughly fifty a day, each one logging "candidate identical to the live config" —
#   about a transport it was not serving.
#
#   `measure.config.json` was written by operator verbs only. The rotation loop can change what a node
#   serves without either verb running, so the two drifted, and nothing anywhere compared them.
#
#   NOTE WHAT THE STALE ARTEFACT IS NOT. The file itself is rewritten on every rotation
#   (update_measure_active_ref stamps .active_ref), so its mtime is always minutes old. What froze was
#   the members[] array INSIDE it. A freshness check on the file would have reported "fine" throughout —
#   which is why this gate compares CONTENT against params, and never a timestamp.
#
# WHAT IT CHECKS, by DRIVING the shipped shell
#   1. The derivation matches params exactly: every enabled sing-box proto is a member, every disabled one
#      is not, and each member's reach anchor is that proto's own port.
#   2. THE DRIFT CASE: disable a proto in params, run the shared converge tail, and require the member and
#      its reach anchor to be gone. This is the live defect, as a fixture.
#   3. The incumbent pointer SURVIVES a converge when it is still a member — the executor moves it, and a
#      converge that reset it to members[0] would silently undo every rotation.
#   4. …and is re-seeded when it names a member the node no longer serves, rather than left dangling.
#   5. The tail does not switch the plane on: a node that never configured MEASURE gains no config.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the plane measures what is served; 1 = it does not.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'served_set_is_what_is_served: cannot resolve repo root\n' >&2; exit 2; }
MEASURE_LIB="$REPO_ROOT/control/lib/nb_measure.sh"
PARAMS_LIB="$REPO_ROOT/control/lib/nb_render_params.sh"
VOCAB="$REPO_ROOT/control/vocab.json"
for f in "$MEASURE_LIB" "$PARAMS_LIB" "$VOCAB"; do
	[ -f "$f" ] || { printf 'served_set_is_what_is_served: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf '  SKIP  jq unavailable; nothing here can be driven.\nPASS (skipped)\n'; exit 0; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the MEASURE plane judges what this node serves ==\n\n'

# Two real, toggleable sing-box protos from the shipped registry — a fixture that drifts from the
# registry would be testing a string rather than the closed set.
KEEP="$(jq -r '[.protos[] | select(.engine == "sing-box" and .enable_key != "") | .proto][0] // empty' "$VOCAB")"
DROP="$(jq -r '[.protos[] | select(.engine == "sing-box" and .enable_key != "") | .proto][1] // empty' "$VOCAB")"
KEEP_KEY="$(jq -r --arg p "$KEEP" '.protos[] | select(.proto == $p) | .enable_key' "$VOCAB")"
DROP_KEY="$(jq -r --arg p "$DROP" '.protos[] | select(.proto == $p) | .enable_key' "$VOCAB")"
DROP_PORT="$(jq -r --arg p "$DROP" '.protos[] | select(.proto == $p) | .default_port' "$VOCAB")"
if [ -z "$KEEP" ] || [ -z "$DROP" ] || [ -z "$KEEP_KEY" ] || [ -z "$DROP_KEY" ]; then
	printf '  FAIL  could not resolve two toggleable sing-box protos from control/vocab.json.\n' >&2
	exit 1
fi
printf 'driving with kept=%s dropped=%s (port %s)\n\n' "$KEEP" "$DROP" "$DROP_PORT"

# ---------------------------------------------------------------------------------------------------
# The harness. Runs the SHIPPED derivation in a throwaway node root.
#
# `need_root` and `run` are stubbed because this gate is offline and unprivileged; nothing here writes
# outside $W, and the code under test is the member/target derivation, not the privilege check.
# ---------------------------------------------------------------------------------------------------
derive() { # derive <params-json> [existing-active-ref] -> "<rc>|<members csv>|<active_ref>|<reach ports csv>"
	local params="$1" prev="${2:-}" W rc
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.sset.XXXXXX")" || return 1
	(
		export REPO_ROOT ARTIFACT_ROOT="$REPO_ROOT" STATE_DIR="$W" DRY_RUN=0
		export PARAMS_JSON="$W/params.json" MYC_VOCAB="$VOCAB"
		log() { :; }; warn() { :; }; die() { exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }
		run() { :; }            # no systemctl in an offline gate
		need_root() { :; }
		# shellcheck source=/dev/null
		. "$MEASURE_LIB" >/dev/null 2>&1 || exit 2
		printf '%s\n' "$params" >"$W/params.json"
		if [ -n "$prev" ]; then
			jq -n --arg r "$prev" '{version:1, active_ref:$r, members:[{ref:$r, proto:$r, action:"promote-sibling", from_port:0, to_port:0}]}' \
				>"$W/measure.config.json"
		fi
		generate_measure_configs
	) >/dev/null 2>&1
	rc=$?
	printf '%s|%s|%s|%s' "$rc" \
		"$(jq -r '[.members[]?.ref] | sort | join(",")' "$W/measure.config.json" 2>/dev/null)" \
		"$(jq -r '.active_ref // ""' "$W/measure.config.json" 2>/dev/null)" \
		"$(jq -r '[.targets[]?.address | split(":")[1]] | sort | join(",")' "$W/reach.config.json" 2>/dev/null)"
	rm -rf "$W"
}

params_with() { # params_with <drop-enabled:true|false>
	jq -nc --arg k "$KEEP_KEY" --arg d "$DROP_KEY" --argjson v "$1" '{($k): true, ($d): $v}'
}

# ---------------------------------------------------------------------------------------------------
# 1. THE DERIVATION MATCHES PARAMS.
# ---------------------------------------------------------------------------------------------------
printf -- '-- the member set is exactly what params enables --\n'
both="$(derive "$(params_with true)")"
IFS='|' read -r rc members active ports <<EOF
$both
EOF
if [ "$rc" != "0" ]; then
	badln "the derivation failed (rc=$rc) on a two-proto fixture; every row below would prove nothing"
else
	printf '%s' "$members" | tr ',' '\n' | grep -qx "$KEEP" && printf '%s' "$members" | tr ',' '\n' | grep -qx "$DROP" \
		&& ok "both enabled protos are members ($members)" \
		|| badln "members are '$members', expected both $KEEP and $DROP"
	printf '%s' "$ports" | tr ',' '\n' | grep -qx "$DROP_PORT" \
		&& ok "and each member is anchored on its own port ($ports)" \
		|| badln "the reach targets are '$ports' and do not include $DROP's port $DROP_PORT — the plane would probe something other than the member it names"
fi

# ---------------------------------------------------------------------------------------------------
# 2. THE DRIFT CASE — the live defect, as a fixture.
# ---------------------------------------------------------------------------------------------------
printf '\n-- a proto the node has stopped serving leaves the plane --\n'
one="$(derive "$(params_with false)")"
IFS='|' read -r rc members active ports <<EOF
$one
EOF
if [ "$rc" != "0" ]; then
	badln "the derivation failed (rc=$rc) with one proto disabled"
else
	if printf '%s' "$members" | tr ',' '\n' | grep -qx "$DROP"; then
		badln "$DROP is disabled in params and is STILL a member ($members). Its loopback probe then fails for ever, it is permanently the most-impaired member, it wins subject selection on every tick, and the node acts every cooldown about a transport it does not serve — measured on three live nodes over three days."
	else
		ok "$DROP is gone from the member set ($members)"
	fi
	if printf '%s' "$ports" | tr ',' '\n' | grep -qx "$DROP_PORT"; then
		badln "the reach plane still anchors $DROP's port $DROP_PORT (targets: $ports). Nothing is bound there, so the probe reports a permanent fault about a member nobody is serving."
	else
		ok "and its reach anchor is gone with it ($ports)"
	fi
fi

# ---------------------------------------------------------------------------------------------------
# 3 + 4. THE INCUMBENT POINTER.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the incumbent pointer --\n'
kept="$(derive "$(params_with true)" "$DROP")"
IFS='|' read -r rc members active ports <<EOF
$kept
EOF
[ "$active" = "$DROP" ] \
	&& ok "a still-served incumbent survives the derivation ($active)" \
	|| badln "the incumbent was reset from '$DROP' to '$active'. The rotation executor moves this pointer (update_measure_active_ref); a converge that resets it to members[0] silently undoes every rotation the loop made."

reseed="$(derive "$(params_with false)" "$DROP")"
IFS='|' read -r rc members active ports <<EOF
$reseed
EOF
if [ -z "$active" ]; then
	badln "the incumbent came out empty after its member was withdrawn — the daemon refuses to start on an active_ref that is not a member, so the plane would be down until an operator noticed"
elif [ "$active" = "$DROP" ]; then
	badln "the incumbent still names '$DROP', which is no longer served. Every tick then measures a member that is not there."
else
	ok "and one that is no longer served is re-seeded to a member that is ($active)"
fi

# ---------------------------------------------------------------------------------------------------
# 5. THE TAIL MUST NOT SWITCH THE PLANE ON.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the converge tail does not arm a plane nobody enabled --\n'
W="$(mktemp -d "${TMPDIR:-/tmp}/myc.ssoff.XXXXXX")" || exit 2
(
	export REPO_ROOT ARTIFACT_ROOT="$REPO_ROOT" STATE_DIR="$W" DRY_RUN=0
	export PARAMS_JSON="$W/params.json" MYC_VOCAB="$VOCAB"
	log() { :; }; warn() { :; }; die() { exit 7; }
	have() { command -v "$1" >/dev/null 2>&1; }; run() { :; }; need_root() { :; }
	# shellcheck source=/dev/null
	. "$MEASURE_LIB" >/dev/null 2>&1 || exit 2
	params_with_local() { jq -nc --arg k "$KEEP_KEY" '{($k): true}'; }
	params_with_local >"$W/params.json"
	converge_measure_membership
) >/dev/null 2>&1
if [ -f "$W/measure.config.json" ]; then
	badln "the converge tail created a measure config on a node that never configured the plane. MEASURE ships disabled on purpose (the C4c-2 pattern); a converge that arms it turns an operator decision into a side effect."
else
	ok "a node that never configured MEASURE gains no config from a converge"
fi
rm -rf "$W"

# And the tail actually calls it — a derivation nothing invokes is the inert-mechanism defect again.
tail_body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$PARAMS_LIB" | awk '/^converge_node_tail\(\)/,/^}/')"
printf '%s' "$tail_body" | grep -q 'converge_measure_membership' \
	&& ok "and converge_node_tail invokes it, so every converge path re-derives the set" \
	|| badln "converge_node_tail does not call converge_measure_membership. The derivation would then run only from the operator verbs it already ran from, and the drift this gate exists for returns unchanged."

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the plane can judge a transport this node is not serving.\n' >&2
	exit 1
fi
printf 'PASS: the member set is derived from what is served, on every converge, without moving the incumbent.\n'
exit 0
