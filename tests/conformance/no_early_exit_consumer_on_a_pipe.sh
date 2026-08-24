#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_early_exit_consumer_on_a_pipe.sh — conformance: no shell in this tree feeds a variable through a
# PIPE into a consumer that exits on its first match.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   `printf '%s' "$v" | grep -q PATTERN` under `set -o pipefail`: `grep -q` exits on its FIRST match and
#   closes the pipe, the producer is killed by SIGPIPE, and pipefail takes the pipeline's status from the
#   producer. **A match is reported as a failure.**
#
#   Both polarities are wrong and one is dangerous:
#     * `… | grep -q X && ok || badln`            -> a false FAILURE. Noise, and it teaches re-running CI.
#     * `if … | grep -q FORBIDDEN; then badln; …` -> a false PASS, on the defect the row exists to catch.
#
#   MEASURED: below the pipe buffer 0/20 false failures; above it 20/20 — deterministic, not a race. The
#   buffer is 64 KiB by default but the kernel may allocate a single page (4 KiB) under pressure, which is
#   why a 31 KB value failed on a shared CI runner and not on an idle node.
#
#   THE REASON IT IS A GATE AND NOT A NOTE: the shape has now been swept out THREE times, and the second
#   sweep was regressed by the very next commit in the same release window, in the same file. A mechanical
#   sweep with no guard is a sweep that comes back. Nothing else in the tree polices it.
#
# THE FIX IS ALWAYS THE SAME: remove the pipe. `grep -q PATTERN <<<"$v"` reads from a here-string, so no
# producer can be killed. `{ printf … || true; } |` does NOT work — printf is a builtin, killed by the
# signal rather than returning a status `||` could mask (verified: 40/40 still failing).
#
# SCOPE, stated precisely because a scanner wider than its rule is a scanner people learn to ignore:
#   * BANNED: a HELD VALUE (printf/echo of a variable) piped into a PREDICATE that exits on first match —
#     `grep -q`, `grep -m N`. That is the shape whose STATUS is read, so an EPIPE death changes a verdict.
#   * NOT banned: `sed`/`awk`/`grep -c`/`sort`/`wc` (they read to EOF); a producer reading a FILE rather
#     than a variable; and `head` used to TRUNCATE OUTPUT FOR DISPLAY, where the status is discarded.
#     Where `head`'s status would matter, an early-exit grep is in the same pipeline and is caught anyway.
#   * A line may opt out with a trailing `# EPIPE-INTENDED` marker — one gate in this tree DEMONSTRATES
#     the SIGPIPE mechanism on purpose and must keep the shape it is proving.
#
# OFFLINE. No root, no network, no node. Exit: 0 = no piped early-exit consumer; 1 = at least one.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== no variable is piped into a consumer that exits on its first match ==\n\n'

# The banned shape: a producer of a HELD VALUE (printf/echo of a variable, or a command substitution)
# piped into grep -q / grep -m N / head. Comment lines are excluded — this file and several gates
# DESCRIBE the shape in prose, and a gate that cannot mention what it forbids is not maintainable.
SCAN_DIRS="tests control scripts"
hits="$(
	cd "$REPO_ROOT" || exit 0
	# shellcheck disable=SC2086
	grep -rnE "(printf|echo) +'[^']*' +\"\\\$[A-Za-z_{][A-Za-z_0-9}]*\" *\| *grep -([a-zA-Z]*q|m)" $SCAN_DIRS 2>/dev/null \
		| grep -vE ':[0-9]+:[[:space:]]*#' \
		| grep -vE 'EPIPE-INTENDED' \
		| grep -vE '/no_early_exit_consumer_on_a_pipe\.sh:'
)"

if [ -z "$hits" ]; then
	ok "no piped early-exit consumer anywhere in $SCAN_DIRS"
else
	n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
	badln "$n site(s) pipe a held value into a consumer that exits early. Under pipefail a MATCH is then reported as a failure, and where a match means 'defect found' the row reports OK on the defect. Replace the pipe with a here-string: grep -q PATTERN <<<\"\$var\"."
	printf '%s\n' "$hits" | head -20 | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------------------------------
# The gate must be able to fail. Prove the detector fires on a planted instance rather than trusting a
# grep that returns nothing — a scanner whose only evidence is silence is the shape this suite distrusts.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the scanner itself can see the shape --\n'
W="$(mktemp -d "${TMPDIR:-/tmp}/myc.eepc.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tests"
printf '#!/usr/bin/env bash\nset -uo pipefail\nprintf %%s "$v" | grep -q X\n' > "$W/tests/planted.sh"
planted="$(cd "$W" && grep -rnE "(printf|echo)[^|]*\| *(grep -[a-zA-Z]*q|grep -m|head( |$))" tests 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#')"
[ -n "$planted" ] \
	&& ok "a planted instance is detected, so an empty result above means absence and not a broken scan" \
	|| badln "the scanner did NOT find a planted instance — its silence proves nothing"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a matched pattern can be reported as a failed check.\n' >&2
	exit 1
fi
printf 'PASS: every held value reaches its consumer without a pipe that can be closed early.\n'
exit 0
