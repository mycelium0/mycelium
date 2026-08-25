#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_early_exit_consumer_on_a_pipe.sh — conformance: no shell in this tree puts a killable producer on
# the same pipeline as a consumer that exits on its first match.
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
#   THE REASON IT IS A GATE AND NOT A NOTE: the shape has now been swept out THREE times, and the second
#   sweep was regressed by the very next commit in the same release window, in the same file. A mechanical
#   sweep with no guard is a sweep that comes back. Nothing else in the tree polices it.
#
# THE FIX — STATED CORRECTLY, BECAUSE THE OLD WORDING HERE WAS FALSE
#   This file used to say "THE FIX IS ALWAYS THE SAME: remove the pipe — `grep -q P <<<"$v"`". That is
#   true only for a ONE-STAGE pipeline. A here-string protects the FIRST producer and nothing else: in
#   `grep -vE P <<<"$v" | grep -q Q` the middle grep is still a process writing into a pipe the final
#   grep closes, and it dies exactly as printf did.
#
#   MEASURED, both platforms, 128 KiB value with the match at the HEAD (below), 20 iterations each:
#     printf '%s' "$v" | grep -q NEEDLE        -> 20/20 false failures   (darwin 24.6 bash 3.2 AND linux bash 5)
#     grep -vE '^zzz' <<<"$v" | grep -q NEEDLE -> 20/20 false failures   <- the "fix" that is not one
#     f="$(grep -vE '^zzz' <<<"$v")"; grep -q NEEDLE <<<"$f" -> 0/20
#     grep -q NEEDLE <<<"$v"                   -> 0/20
#
#   The FIRST run of that experiment scored 0/20 on every arm, including the naive pipeline — because the
#   needle sat at the END of the value, so the producer had already written everything before the consumer
#   exited. An experiment that cannot fail is not an experiment (development.md §2.2 item 12): the match
#   has to be at the head, and the value has to exceed the pipe buffer. That buffer is 64 KiB by default
#   but the kernel may hand out a single page (4 KiB) under pressure, which is why a 31 KB value failed on
#   a shared CI runner and not on an idle node.
#
#   So the rule is: NO stage of a pipeline that ends in an early-exit consumer may be killable. In
#   practice — one stage, from a here-string; or capture each stage into a variable and test that.
#
# SCOPE, stated precisely because a scanner wider than its rule is a scanner people learn to ignore:
#   * BANNED (rule A): a HELD VALUE — printf/echo of a variable or a command substitution — piped into a
#     PREDICATE that exits on first match (`grep -q` in any flag order, `grep -m N`). That is the shape
#     whose STATUS is read, so an EPIPE death changes a verdict.
#   * BANNED (rule B): a here-string producer with ANOTHER stage between it and an early-exit predicate —
#     the half-applied fix above. The here-string saves stage one; stage two dies in its place.
#   * NOT banned: `sed`/`awk`/`grep -c`/`sort`/`wc` as the final consumer (they read to EOF); a producer
#     reading a FILE rather than a variable; `head` used to TRUNCATE OUTPUT FOR DISPLAY, where the status
#     is discarded; and `a <<<"$v" || b <<<"$v"` — a `||` is not a pipeline.
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

# ---------------------------------------------------------------------------------------------------
# THE SCANNER — one function, so the self-test below drives the SAME code the verdict is read from.
#
# It used to be an inline grep in the verdict, with the self-test running a DIFFERENT, looser expression
# against its planted file. That self-test passed while the real scanner could not see the very instance
# it had planted (the planted line had an unquoted format string, which the real regex required to be
# single-quoted) — a can-it-fail check that proved only that some other regex worked. (Audit-0015 S2-3.)
#
# Rule A: (printf|echo) <something containing $>  then one or more `| stage`  then an early-exit grep
# Rule B: <<<...                                   then one or more `| stage`  then an early-exit grep
# `(\|[^|&]+)+` is what carries a THREE-stage pipeline (the multi-stage shape is the whole point of rule
# B) while keeping `||` and `&&` out: after a `|`, the next character must not be another `|`, so a
# logical OR — which is not a pipeline, and in which nothing can be SIGPIPE'd — never matches.
#
# Comment lines are excluded — this file and several gates DESCRIBE the shape in prose, and a gate that
# cannot mention what it forbids is not maintainable.
# ---------------------------------------------------------------------------------------------------
MYC_EEPC_EXIT='grep[[:space:]]+-([A-Za-z]*q[A-Za-z]*|m[[:space:]]*[0-9])'
myc_eepc_scan() {
	local root dirs
	root="$1"; shift
	dirs="$*"
	(
		cd "$root" || exit 0
		# shellcheck disable=SC2086
		{
			grep -rnE "(printf|echo)[[:space:]][^|&]*\\\$[^|&]*(\\|[^|&]+)+$MYC_EEPC_EXIT" $dirs 2>/dev/null
			grep -rnE "<<<[^|&]*(\\|[^|&]+)+$MYC_EEPC_EXIT" $dirs 2>/dev/null
		} \
			| grep -vE ':[0-9]+:[[:space:]]*#' \
			| grep -vE 'EPIPE-INTENDED' \
			| grep -vE '/no_early_exit_consumer_on_a_pipe\.sh:' \
			| sort -u
	)
}

printf '== no pipeline that ends in an early-exit consumer carries a killable producer ==\n\n'

SCAN_DIRS="tests control scripts"
hits="$(myc_eepc_scan "$REPO_ROOT" $SCAN_DIRS)"

if [ -z "$hits" ]; then
	ok "no piped early-exit consumer anywhere in $SCAN_DIRS"
else
	n="$(printf '%s\n' "$hits" | grep -c .)"
	badln "$n site(s) put a killable producer on a pipeline ending in a consumer that exits early. Under pipefail a MATCH is then reported as a failure, and where a match means 'defect found' the row reports OK on the defect. Use ONE stage from a here-string, or capture each stage into a variable first."
	printf '%s\n' "$hits" | sed -n '1,20p' | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------------------------------
# THE GATE MUST BE ABLE TO FAIL — on every variant it CLAIMS to cover, not on one.
#
# A scanner whose only evidence is silence is the shape this suite distrusts. Below: a fixture tree
# carrying one planted line per declared variant, plus the shapes the scope explicitly permits, run
# through myc_eepc_scan itself. A positive that is missed and a negative that is flagged are both FAILs —
# the second matters as much, because a scanner that cries wolf is one people route around.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the scanner sees every variant it claims to cover --\n'
W="$(mktemp -d "${TMPDIR:-/tmp}/myc.eepc.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fx"

plant() {   # plant NAME LINE — one fixture file per case, so a hit names the case
	printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$2" > "$W/fx/$1.sh"
}

# --- must be DETECTED -------------------------------------------------------------------------------
plant pos01_printf_sq      'printf '"'"'%s'"'"' "$v" | grep -q X'
plant pos02_printf_dq      'printf "%s" "$v" | grep -q X'
plant pos03_echo_quoted    'echo "$v" | grep -q X'
plant pos04_echo_bare      'echo $v | grep -q X'
plant pos05_cmdsub         'printf '"'"'%s'"'"' "$(myc_thing)" | grep -q X'
plant pos06_array          'printf '"'"'%s\n'"'"' "${arr[@]}" | grep -q X'
plant pos07_flags_qE       'printf '"'"'%s'"'"' "$v" | grep -qE '"'"'X|Y'"'"''
plant pos08_flags_Eq       'printf '"'"'%s'"'"' "$v" | grep -Eq '"'"'X|Y'"'"''
plant pos09_grep_m         'printf '"'"'%s'"'"' "$v" | grep -m 1 X'
plant pos10_multistage     'printf '"'"'%s'"'"' "$v" | grep -vE '"'"'^#'"'"' | grep -q X'
plant pos11_herestring_2st 'grep -vE '"'"'^#'"'"' <<<"$v" | grep -q X'
plant pos12_hs_then_sed    'sed -n '"'"'1,9p'"'"' <<<"$v" | grep -qi needle'

# --- must NOT be detected ---------------------------------------------------------------------------
plant neg01_one_stage_hs   'grep -q X <<<"$v"'
plant neg02_or_not_pipe    'grep -q X <<<"$v" || grep -q Y <<<"$v"'
plant neg03_reads_to_eof   'printf '"'"'%s'"'"' "$v" | grep -c X'
plant neg04_file_producer  'grep -q X /etc/hosts'
plant neg05_display_head   'printf '"'"'%s\n'"'"' "$hits" | head -20'
plant neg06_awk_consumer   'printf '"'"'%s'"'"' "$v" | awk '"'"'{n++} END{print n}'"'"''
plant neg07_comment        '#printf '"'"'%s'"'"' "$v" | grep -q X'
plant neg08_optout         'printf '"'"'%s'"'"' "$v" | grep -q X   # EPIPE-INTENDED'

seen="$(myc_eepc_scan "$W" fx)"
for f in "$W"/fx/pos*.sh; do
	c="$(basename "$f" .sh)"
	grep -q "fx/$c\.sh:" <<<"$seen" \
		&& ok "detected: $c" \
		|| badln "the scanner MISSED $c — it is a declared variant, so the empty result above cannot be read as absence: $(sed -n '3p' "$f")"
done
for f in "$W"/fx/neg*.sh; do
	c="$(basename "$f" .sh)"
	grep -q "fx/$c\.sh:" <<<"$seen" \
		&& badln "the scanner FLAGGED $c, which the scope explicitly permits: $(sed -n '3p' "$f"). A scanner wider than its rule is one people learn to route around." \
		|| ok "permitted, and not flagged: $c"
done

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a matched pattern can be reported as a failed check.\n' >&2
	exit 1
fi
printf 'PASS: every held value reaches its consumer without a stage that can be killed early.\n'
exit 0
