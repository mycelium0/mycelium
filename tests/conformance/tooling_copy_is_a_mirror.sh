#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# tooling_copy_is_a_mirror.sh — conformance: the tooling installed on a node is a MIRROR of the deployed
# artifact, not an accumulation of everything that was ever there.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   install_tooling copied with `cp -a`, which adds and overwrites but NEVER removes. The installed copy
#   could therefore only grow: a file deleted from the checkout stayed on the node forever, and so did
#   anything dropped into the directory by hand.
#
#   MEASURED 2026-08-21 on one live node: two files dated 2026-07-01 — myceliumctl.bak-stale and
#   vocab.json.bak-stale — that nothing in the tree creates and nothing references. Seven weeks.
#
#   They were inert, and the reason matters more than the fact: the libraries are sourced BY NAME, and
#   neither file is a sourced name. The installed copy was safe because of a property of a different
#   file. A glob-sourced lib, a shadowed vocab, a stale myceliumctl reachable by some path — each is one
#   edit away, and none would announce itself.
#
# WHAT IT CHECKS, by DRIVING the shipped function against real directories
#   1. A file the artifact does not have is REMOVED from the installed copy.
#   2. A file both have SURVIVES, with the artifact's content — the row that stops "mirror" from being
#      implemented as "delete everything".
#   3. A file the artifact has but the installed copy lacks is ADDED (the copy still copies).
#   4. THE ORDERING: the prune runs AFTER the copy, so the installed tree is never a subset of the
#      artifact mid-run. A delete-then-copy would leave a window in which MYCTL points at nothing, and a
#      node cannot converge without its tooling. Asserted from the recorded command trace, because a
#      version that pruned first would pass rows 1-3 and still be the dangerous one.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the copy mirrors; 1 = it accumulates.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
LIB="$REPO_ROOT/control/lib/nb_install.sh"
[ -f "$LIB" ] || { printf 'tooling_copy_is_a_mirror: missing %s\n' "$LIB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the installed tooling mirrors the artifact, it does not accumulate ==\n\n'

W="$(mktemp -d "${TMPDIR:-/tmp}/myc.tcm.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

# The artifact: what the node deployed.
mkdir -p "$W/artifact/control/lib"
printf 'CURRENT ENTRYPOINT\n' > "$W/artifact/control/myceliumctl"
printf '{"version":1}\n'      > "$W/artifact/control/vocab.json"
printf 'CURRENT LIB\n'        > "$W/artifact/control/lib/common.sh"
printf 'ONLY IN ARTIFACT\n'   > "$W/artifact/control/lib/brand_new.sh"

# The installed copy: stale entrypoint, two orphans (the shape found on the node), no brand_new.sh.
mkdir -p "$W/tooling/control/lib"
printf 'STALE ENTRYPOINT\n'   > "$W/tooling/control/myceliumctl"
printf '{"version":1}\n'      > "$W/tooling/control/vocab.json"
printf 'CURRENT LIB\n'        > "$W/tooling/control/lib/common.sh"
printf 'ORPHAN A\n'           > "$W/tooling/control/myceliumctl.bak-stale"
printf 'ORPHAN B\n'           > "$W/tooling/control/lib/deleted_upstream.sh"

TRACE="$W/trace"
(
	ARTIFACT_ROOT="$W/artifact"; TOOLING_DIR="$W/tooling"; DRY_RUN=0
	log()  { :; }
	warn() { :; }
	die()  { printf 'DIE %s\n' "$*" >>"$TRACE"; exit 7; }
	have() { command -v "$1" >/dev/null 2>&1; }
	need_root() { :; }
	# run RECORDS and then EXECUTES: the trace gives the ordering, the effects give rows 1-3.
	run()  { printf '%s\n' "$*" >>"$TRACE"; "$@"; }
	# shellcheck source=/dev/null
	. "$LIB" >/dev/null 2>&1 || exit 2
	install_spine() { :; }   # out of scope here: it builds Go
	ARTIFACT_ROOT="$W/artifact"; TOOLING_DIR="$W/tooling"; DRY_RUN=0
	install_tooling
) >/dev/null 2>&1

# ---------------------------------------------------------------------------------------------------
# 1. WHAT THE ARTIFACT DOES NOT HAVE IS GONE.
# ---------------------------------------------------------------------------------------------------
printf -- '-- what the artifact no longer has --\n'
for orphan in myceliumctl.bak-stale lib/deleted_upstream.sh; do
	if [ -e "$W/tooling/control/$orphan" ]; then
		badln "'$orphan' survived the install. cp never removes, so the installed tooling can only grow — a file deleted from the checkout, or dropped in by hand, stays on the node forever. Measured: two such files sat on a live node for seven weeks."
	else
		ok "'$orphan' is removed — the copy mirrors rather than accumulates"
	fi
done

# ---------------------------------------------------------------------------------------------------
# 2. WHAT BOTH HAVE SURVIVES, WITH THE ARTIFACT'S CONTENT.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and what belongs there is intact --\n'
if [ -f "$W/tooling/control/myceliumctl" ] && grep -q 'CURRENT ENTRYPOINT' "$W/tooling/control/myceliumctl"; then
	ok "the entrypoint is present and carries the artifact's content, not the stale one"
else
	badln "the installed entrypoint is missing or stale ($(head -c 40 "$W/tooling/control/myceliumctl" 2>/dev/null | tr -d '\n')). Mirroring must not mean emptying: a node with no myceliumctl cannot converge at all."
fi
[ -f "$W/tooling/control/lib/common.sh" ] \
	&& ok "a library both sides have survives" \
	|| badln "a library present in BOTH the artifact and the installed copy was deleted — the prune is removing more than the difference"

# ---------------------------------------------------------------------------------------------------
# 3. WHAT THE ARTIFACT ADDED IS THERE.
# ---------------------------------------------------------------------------------------------------
[ -f "$W/tooling/control/lib/brand_new.sh" ] \
	&& ok "a file new in the artifact is installed" \
	|| badln "a file present only in the artifact was not installed — the copy half of the mirror stopped working"

# ---------------------------------------------------------------------------------------------------
# 4. ORDERING: COPY, THEN PRUNE.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the tree is never a subset of the artifact mid-run --\n'
first_cp="$(grep -n '^cp -a' "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)"
first_rm="$(grep -n '^rm -f' "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -z "$first_rm" ]; then
	badln "nothing was removed at all, so rows 1-2 above cannot be distinguishing anything"
elif [ -z "$first_cp" ]; then
	badln "no copy was recorded in the trace; the ordering cannot be established"
elif [ "$first_cp" -lt "$first_rm" ]; then
	ok "the copy runs before the prune, so an interrupted converge leaves a COMPLETE tooling directory"
else
	badln "the prune runs BEFORE the copy. That leaves a window in which the installed tooling is incomplete and MYCTL points at nothing — and a node cannot converge without its tooling. Ordering is the whole safety argument here; a prune-first version passes every other row in this gate."
fi

# ---------------------------------------------------------------------------------------------------
# 5. AN INCOMPLETE ARTIFACT MUST NOT BE MIRRORED.
#
# `[ -d ]` is satisfied by an EMPTY directory, and mirroring an empty source means deleting everything.
# MEASURED on the first version of this code: zero files survived and MYCTL pointed at a deleted
# myceliumctl. The accumulate behaviour this replaced at least left working tooling in place, so an
# unguarded mirror is a REGRESSION on exactly the failure that matters.
#
# DRIVEN WITH A RECORDER, not for real. The first draft of this row executed install_tooling against a
# real directory tree, and the suite then failed a LATER, unrelated gate on CI only — a cross-gate
# interaction I could not reproduce on any host I have. Whatever the mechanism, a row that mutates a real
# filesystem to prove a refusal does not need to: the refusal IS the absence of an `rm`, and the trace
# shows that directly. Removing the guard makes the rm appear, which is the whole discrimination.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and an incomplete artifact is not mirrored --\n'
E="$(mktemp -d "${TMPDIR:-/tmp}/myc.tcm2.XXXXXX")" || exit 2
mkdir -p "$E/artifact/control" "$E/tooling/control/lib"
printf 'ENTRYPOINT\n' > "$E/tooling/control/myceliumctl"
printf 'LIB\n'        > "$E/tooling/control/lib/common.sh"
ETRACE="$E/trace"
(
	ARTIFACT_ROOT="$E/artifact"; TOOLING_DIR="$E/tooling"; DRY_RUN=0
	log() { :; }; warn() { :; }; die() { exit 7; }
	have() { command -v "$1" >/dev/null 2>&1; }; need_root() { :; }
	# RECORDER: every mutation install_tooling would perform is written down and NOT performed.
	run() { printf '%s\n' "$*" >>"$ETRACE"; }
	# shellcheck source=/dev/null
	. "$LIB" >/dev/null 2>&1 || exit 2
	install_spine() { :; }
	ARTIFACT_ROOT="$E/artifact"; TOOLING_DIR="$E/tooling"; DRY_RUN=0
	install_tooling
) >/dev/null 2>&1
if grep -q '^rm -f ' "$ETRACE" 2>/dev/null; then
	badln "the tooling was pruned against an artifact that does not even contain myceliumctl ($(grep -c '^rm -f ' "$ETRACE") removal(s) issued). MYCTL then points at a deleted file and the node cannot converge at all — strictly worse than the accumulation this mirror replaced."
else
	ok "an artifact with no myceliumctl issues no removals at all"
fi
grep -q '^cp -a ' "$ETRACE" 2>/dev/null \
	&& ok "and the copy still runs, so the row is not passing because install_tooling did nothing" \
	|| badln "install_tooling issued no copy either — this row would then report a refusal it never observed"
rm -rf "$E"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the installed tooling does not mirror the deployed artifact.\n' >&2
	exit 1
fi
printf 'PASS: the copy adds, updates, and removes — in that order.\n'
exit 0
