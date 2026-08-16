#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# ci_lint_strict.sh — conformance: the linters that are declared BLOCKING stay blocking, keep their
# calibrated flags, and are pointed at every shell file the repository actually has.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The shellcheck step ran on every push for the project's whole life and ended in `|| true` every time.
#   The cost
#   was concrete and long-lived: a backtick pair inside an unquoted heredoc in control/lib/nb_measure.sh
#   executed on every `--measure-enable`, mangling the rendered systemd unit on all three live nodes for
#   months. It was reported on every run. Nothing read the report.
#
#   Turning it blocking is one line. KEEPING it blocking is the hard part, because the pressure to append
#   `|| true` arrives exactly when someone is trying to land something else and the linter is in the way.
#   That is what this gate exists to resist.
#
# WHAT IT CHECKS
#   1. NO SILENT PASS: no step in the lint job whose name says "blocking" may end in `|| true`, `|| :`,
#      or carry continue-on-error. The advisory steps may — they say so in their names.
#   3. AND THE LINTER IS ACTUALLY RUN, here, with the flags and file list parsed out of that same job —
#      because rows 1 and 2 read the workflow and neither of them runs anything, which is how a green
#      108/108 suite coexisted with four red CI runs in a single day.
#   2. THE CALIBRATION IS NOT WIDENED: the shellcheck invocation keeps `-S warning` and the two exclusions
#      it was measured against (`-s bash`, `-e SC2034`). Adding a THIRD exclusion, or dropping to a looser
#      severity, is how a blocking linter quietly becomes a decorative one — so a new `-e` fails here and
#      has to be argued for in a commit message.
#   3. THE FILE SET IS DERIVED, NOT LISTED — the behavioural half. Every tracked file whose first line is a
#      bash/sh shebang must be reachable from the lint expression. `git ls-files '*.sh'` missed
#      `scripts/fungi` — the documented deploy entrypoint, a 100+ line bash script with no `.sh` suffix —
#      for the project's whole life. Pinning the literal glob would have preserved that hole; enumerating
#      shebangs finds the next one automatically.
#
# WHAT IT DELIBERATELY DOES NOT CHECK
#   That yamllint and ansible-lint are blocking. They are not, on purpose, and the reasons are recorded
#   inline in the workflow (yamllint's findings are entirely `line-length` against a default this repo does
#   not follow; ansible-lint's job never installs the collections it needs). Requiring them here would
#   force a bad fix. When they are promoted, their step names gain "blocking" and check 1 covers them with
#   no edit to this file.
#
# OFFLINE + INSPECT-ONLY. Exit: 0 = strict, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'ci_lint_strict: cannot resolve repo root\n' >&2; exit 2; }
CI="$REPO_ROOT/.github/workflows/ci.yml"
[ -f "$CI" ] || { printf 'ci_lint_strict: missing %s\n' "$CI" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== CI lint strictness: blocking linters stay blocking ==\n'

# The lint job's body: from `  lint:` to the next top-level job key.
job="$(awk '/^  lint:/{f=1;print;next} f&&/^  [a-z][a-z0-9_-]*:/{exit} f' "$CI")"
[ -n "$job" ] || { printf 'FAIL: could not extract the `lint` job from %s — re-confirm this gate.\n' "$CI" >&2; exit 1; }

# --- 1. no blocking step may swallow its own exit ---------------------------------------------------
# Steps are split on `- name:`; a step is BLOCKING if its name says so.
swallowed=""
blocking_seen=0
step=""
while IFS= read -r line; do
	case "$line" in
		*"- name:"*)
			if [ -n "$step" ]; then
				case "$step" in
					*blocking*)
						blocking_seen=$((blocking_seen + 1))
						nm="$(printf '%s' "$step" | sed -n 's/.*- name: *//p' | head -1)"
						if printf '%s' "$step" | grep -vE '^[[:space:]]*#' | grep -qE '\|\|[[:space:]]*(true|:)[[:space:]]*$|continue-on-error:[[:space:]]*true'; then
							swallowed="$swallowed [$nm]"
						fi ;;
				esac
			fi
			step="$line" ;;
		*) step="$step
$line" ;;
	esac
done <<EOF
$job
EOF
# the trailing step
case "$step" in
	*blocking*)
		blocking_seen=$((blocking_seen + 1))
		nm="$(printf '%s' "$step" | sed -n 's/.*- name: *//p' | head -1)"
		printf '%s' "$step" | grep -vE '^[[:space:]]*#' | grep -qE '\|\|[[:space:]]*(true|:)[[:space:]]*$|continue-on-error:[[:space:]]*true' \
			&& swallowed="$swallowed [$nm]" ;;
esac

if [ "$blocking_seen" -eq 0 ]; then
	badln "no step in the lint job is marked blocking — shellcheck and terraform fmt were made blocking deliberately; if that was reverted, it must be argued for, not dropped"
elif [ -n "$swallowed" ]; then
	badln "a step named BLOCKING swallows its own exit status (\`|| true\` / \`|| :\` / continue-on-error):$swallowed — a linter that cannot fail the build is a linter nobody reads, which is the state that let a live heredoc defect sit for months"
else
	ok "all $blocking_seen step(s) marked blocking actually fail the build"
fi

# --- 2. the shellcheck calibration is not widened ---------------------------------------------------
sc="$(printf '%s\n' "$job" | grep -E '^[[:space:]]*shellcheck ' | grep -v -- '--version' | head -1)"
if [ -z "$sc" ]; then
	badln "no shellcheck invocation found in the lint job"
else
	for flag in '-S warning' '-s bash' '-e SC2034'; do
		printf '%s' "$sc" | grep -qF -- "$flag" \
			&& ok "shellcheck keeps '$flag'" \
			|| badln "shellcheck lost '$flag'. These are calibration, measured at 61 findings raw and 2 with them: -s bash names the dialect for sourced fragments that must not carry a shebang, -e SC2034 retires the 41 false 'unused variable' hits from those same fragments. Dropping -S warning floods the job with style findings and the pressure to re-add '|| true' returns immediately."
	done
	# A third exclusion is the quiet way to neutralise it.
	nex="$(printf '%s' "$sc" | grep -oE '\-e [A-Z0-9,]+' | wc -l | tr -d ' ')"
	if [ "${nex:-0}" -le 1 ]; then
		ok "no exclusion beyond the measured -e SC2034"
	else
		badln "shellcheck carries $nex separate -e exclusions. Each one is a class of defect the build stops seeing; add it only with the finding count and the reason in the commit message, then update this gate deliberately."
	fi
fi

# --- 3. the file set is DERIVED from shebangs, not from a literal glob ------------------------------
# Every tracked bash/sh script must be reachable from the lint expression. This is the check that would
# have caught scripts/fungi on day one.
lintexpr="$(printf '%s\n' "$job" | grep -E 'files=' | head -1)"
if [ -z "$lintexpr" ]; then
	badln "could not find the lint file-set expression (files=...) — re-confirm this gate"
else
	# Enumerate the candidate files. `git ls-files` when we are in a work tree, a filesystem walk when we
	# are not — this gate must be checkable over an extracted tarball or a mutation-harness copy, and it
	# must NEVER pass by finding nothing. An empty enumeration is a gate error, not a clean result: the
	# first draft used git alone, silently enumerated zero files outside a repo, and reported OK for a
	# workflow with scripts/fungi deleted from the lint set — the exact vacuous-pass shape this suite has
	# been rooting out all along.
	all_tracked="$(cd "$REPO_ROOT" && git ls-files 2>/dev/null)"
	if [ -z "$all_tracked" ]; then
		all_tracked="$(cd "$REPO_ROOT" && find . -type f -not -path './.git/*' 2>/dev/null | sed 's|^\./||')"
	fi
	shebang_n=0
	missing=""
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		[ -f "$REPO_ROOT/$f" ] || continue
		head -1 "$REPO_ROOT/$f" 2>/dev/null | grep -qE '^#!.*(bash|/bin/sh|env sh)' || continue
		shebang_n=$((shebang_n + 1))
		case "$f" in
			*.sh) continue ;;   # covered by the glob half of the expression
		esac
		printf '%s' "$lintexpr" | grep -qF -- "$f" || missing="$missing $f"
	done <<EOF
$all_tracked
EOF
	if [ "$shebang_n" -eq 0 ]; then
		badln "enumerated ZERO shell scripts — neither 'git ls-files' nor the filesystem walk found anything, so this check proves nothing. Fail closed rather than report a clean file set."
	elif [ -n "$missing" ]; then
		badln "tracked shell script(s) with no .sh suffix are not named in the lint file set:$missing — \`git ls-files '*.sh'\` cannot see them, and one of them (scripts/fungi) is the documented deploy entrypoint that went unlinted for the project's whole life"
	else
		ok "every one of the $shebang_n bash/sh scripts is reachable from the lint file set"
	fi
	printf '%s' "$lintexpr" | grep -qF "git ls-files" \
		&& ok "the .sh half of the file set is enumerated from git, not hand-listed" \
		|| badln "the lint file set no longer derives from git ls-files — a hand-maintained list goes stale silently"
fi

# --- 3. AND IT IS ACTUALLY RUN HERE -----------------------------------------------------------------
#
# THIS ROW EXISTS BECAUSE ITS ABSENCE COST FOUR RED MERGES IN ONE DAY. Rows 1 and 2 read the workflow and
# assert that the linter is blocking and that its calibration was not widened. Neither of them RUNS it.
# So `tests/run.sh` reported 108/108 green while CI was red on every one of those merges, and the green
# was true: the suite simply did not cover what the blocking linter covers. That is this project's own
# recurring defect — a gate that asserts configuration rather than behaviour — committed by the gate whose
# subject is a linter.
#
# The invocation is DERIVED from the workflow, never restated: the flags and the file list come out of the
# step this gate already parses, so a change to CI moves this row with it and the two cannot drift.
printf '\n-- and the linter actually runs, here, over the same files --\n'
if ! command -v shellcheck >/dev/null 2>&1; then
	printf '  SKIP  shellcheck is not installed on this host, so the blocking linter was NOT exercised.\n'
	printf '        This is the gap that let four red merges through: install shellcheck, or treat a green\n'
	printf '        suite as silent about shell lint until CI reports.\n'
elif [ -z "$sc" ]; then
	printf '  SKIP  no shellcheck invocation was parsed out of the workflow; row 2 already failed on that.\n'
else
	# The flags, exactly as the workflow spells them — parsed, not restated.
	sc_flags="$(printf '%s' "$sc" | grep -oE '\-(s|e|S) [A-Za-z0-9,]+' | tr '\n' ' ')"
	# The same file set the job lints: every tracked *.sh, plus the two tracked bash scripts with no suffix.
	if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		printf '  SKIP  not a git checkout; the file list the job lints cannot be reproduced.\n'
	else
		sc_files="$(git -C "$REPO_ROOT" ls-files '*.sh')"
		for extra in control/myceliumctl scripts/fungi; do
			[ -f "$REPO_ROOT/$extra" ] && sc_files="$sc_files
$extra"
		done
		sc_out="$(cd "$REPO_ROOT" && printf '%s\n' "$sc_files" | sed '/^$/d' | xargs shellcheck $sc_flags 2>&1)"
		if [ -z "$sc_out" ]; then
			ok "shellcheck $sc_flags is clean over $(printf '%s\n' "$sc_files" | sed '/^$/d' | wc -l | tr -d ' ') tracked shell files"
		else
			badln "shellcheck reports findings that CI will block on: $(printf '%s' "$sc_out" | grep -E '^In |SC[0-9]+' | head -6 | tr '\n' ' ')"
			printf '%s\n' "$sc_out" | head -30 | sed 's/^/        /'
		fi
	fi
fi
printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the blocking linters can be bypassed, have been widened, or no longer see every shell file.\n' >&2
	exit 1
fi
printf 'PASS: blocking linters fail the build, keep their measured calibration, and cover every tracked shell file.\n'
exit 0
