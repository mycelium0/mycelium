#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# run_protocol_is_current.sh — conformance: the documented way to run the suite still names commands and
# files that exist, and the suite runner still behaves the way the protocol says it does.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   development.md §7.6 was written on 2026-08-10 after a run protocol that existed only as habit cost
#   real time: a macOS-only run called a tree clean that the node called dirty (BSD vs GNU grep), a
#   `git apply` + `git add -A` left an index that `git checkout -- .` would not revert so the next patch
#   failed against an apparently clean tree, a foreground `tests/run.sh | tail` lost its whole transcript
#   on timeout, and node targets resolved by LINE NUMBER connected to nothing after the file they live in
#   was edited.
#
#   Writing that down fixes it exactly once. This project's recurring failure is a document that was true
#   when written and that nothing re-reads — the acceptance ledger claiming a release tag that never
#   existed, the audit noting that no IPv4 literal is an operator address while nothing enforced it. A
#   protocol is a document. So it gets a gate.
#
# WHAT IT CHECKS
#   1. Every command §7.6 tells a contributor to run resolves to something that exists in this tree.
#   2. The claims §7.6 makes about the RUNNER are true of the runner: it prints the `total:` line the
#      protocol says to poll for, and the `run.sh:` terminator, and it honours MYC_REPO_ROOT.
#   3. SKIP is still exit-0-shaped — i.e. the warning "a skipped row counts as a pass in the total" is
#      still accurate, because if run.sh ever started counting skips separately the advice would be wrong.
#   4. The three surfaces that tell people how to run tests agree: development.md §7.6, CONTRIBUTING.md,
#      and the pull-request template. A contributor reads one of the three, not all three.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the protocol is current; 1 = it has drifted.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'run_protocol_is_current: cannot resolve repo root\n' >&2; exit 2; }
DEV="$REPO_ROOT/docs/development.md"
RUNNER="$REPO_ROOT/tests/run.sh"
for f in "$DEV" "$RUNNER"; do
	[ -f "$f" ] || { printf 'run_protocol_is_current: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the documented run protocol still describes this tree ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 0. THE SECTION EXISTS. Everything below is vacuous without it, so say so rather than pass.
# ---------------------------------------------------------------------------------------------------
proto="$(awk '/^### 7\.6\./{f=1} /^### 7\.7\./{f=0} f' "$DEV")"
if [ -z "$proto" ]; then
	badln "development.md has no §7.6 run-protocol section (or it was renumbered). Every row below reads an empty string and would otherwise report clean."
	printf '\nFAIL: the run protocol is gone.\n' >&2
	exit 1
fi
ok "development.md §7.6 exists ($(printf '%s' "$proto" | wc -l | tr -d ' ') lines)"

# ---------------------------------------------------------------------------------------------------
# 1. EVERY PATH THE PROTOCOL TELLS YOU TO RUN EXISTS.
# ---------------------------------------------------------------------------------------------------
printf '\n-- every command it names resolves --\n'
missing=""
for rel in $(printf '%s' "$proto" | grep -ohE '\b(tests|control|scripts)/[A-Za-z0-9_./-]+\.sh\b' | sort -u); do
	[ -f "$REPO_ROOT/$rel" ] || missing="$missing $rel"
done
if [ -z "$missing" ]; then
	ok "every script path named in §7.6 exists"
else
	badln "§7.6 tells a contributor to run scripts that are not in this tree:$missing. A protocol naming a missing file is worse than none — the reader assumes their environment is broken."
fi

# The Go half is named as commands, not paths; check the module is there to run them against.
if printf '%s' "$proto" | grep -q 'go test -race'; then
	[ -f "$REPO_ROOT/go.mod" ] \
		&& ok "it names the -race run and go.mod is present to support it" \
		|| badln "§7.6 names \`go test -race\` but there is no go.mod at the repo root"
else
	badln "§7.6 no longer names \`go test -race\`. The Go half is the one CI treats as strict; a protocol that omits it teaches a partial run."
fi

# ---------------------------------------------------------------------------------------------------
# 2. THE CLAIMS ABOUT THE RUNNER ARE TRUE OF THE RUNNER — driven, not read.
# ---------------------------------------------------------------------------------------------------
printf '\n-- what it says about tests/run.sh is true of tests/run.sh --\n'

# The protocol tells you to poll for these two strings. If either changes, every documented
# wait-loop hangs until its timeout and reports nothing.
grep -q "printf '\\\\n  total:" "$RUNNER" || grep -qE 'total: %d' "$RUNNER" \
	&& ok "the runner still prints the \`total:\` line the protocol polls for" \
	|| badln "tests/run.sh no longer prints a \`total:\` summary line. §7.6 tells the reader to poll for it, so every documented wait-loop would hang until timeout and then report nothing."
grep -qE '^printf .run\.sh:|run\.sh: all offline gates passed|run\.sh: OFFLINE SUITE FAILED' "$RUNNER" \
	&& ok "and the \`run.sh:\` terminator the wait-loop breaks on" \
	|| badln "tests/run.sh no longer prints a \`run.sh:\` terminator line. The documented \`until grep -q '^run.sh:'\` loop never breaks."

# MYC_REPO_ROOT is how the protocol runs the suite from a scratch clone. If gates stopped honouring it,
# a run in /root/myc-test would silently measure whatever tree the script's own path resolves to.
# The property is NOT "every gate mentions MYC_REPO_ROOT" — a self-contained gate needs no repo root at
# all, and counting mentions gave 60/102 and a red row about nothing. What must hold is that a gate which
# DOES resolve a root either takes the override or derives it from its own location, and that none
# hard-codes an absolute path: run from /root/myc-test, a hard-coded path measures a different tree and
# reports on it confidently.
# Follow the DERIVATION CHAIN, not one line. Most gates here go REPO_ROOT <- $HERE <- BASH_SOURCE, and a
# pattern that only inspected the REPO_ROOT= line flagged 40 of them as unredirectable when every one was
# correct. Checking a variable's spelling instead of where its value comes from is how this gate would
# have earned the reputation of a row people delete.
bad_root=""
for g in "$REPO_ROOT"/tests/conformance/*.sh; do
	line="$(grep -m1 '^REPO_ROOT=' "$g" 2>/dev/null)" || continue
	[ -n "$line" ] || continue
	# Direct: takes the override, or resolves from its own file.
	if printf '%s' "$line" | grep -qE 'MYC_REPO_ROOT|dirname|BASH_SOURCE|\$0'; then continue; fi
	# Indirect: via $HERE (or any local), which must itself resolve from this file's location.
	via="$(printf '%s' "$line" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | tr -d '${' | head -1)"
	if [ -n "$via" ] && grep -qE "^${via}=.*(BASH_SOURCE|dirname|\\\$0)" "$g" 2>/dev/null; then continue; fi
	bad_root="$bad_root $(basename "$g")"
done
hard="$(grep -lE '^[^#]*"(/Users|/home)/' "$REPO_ROOT"/tests/conformance/*.sh 2>/dev/null | head -3 | xargs -r -n1 basename | tr '\n' ' ')"
if [ -z "$bad_root" ] && [ -z "$hard" ]; then
	ok "every gate that resolves a repo root takes MYC_REPO_ROOT or derives it from its own path, and none hard-codes one"
else
	badln "these resolve the repo in a way a scratch-clone run cannot redirect:${bad_root}${hard:+ (hard-coded path: $hard)}. Run from /root/myc-test they would measure a different tree and report on it as though it were the one under test."
fi

# ---------------------------------------------------------------------------------------------------
# 3. SKIP IS STILL EXIT-0-SHAPED, so the protocol's warning about it is still true.
# ---------------------------------------------------------------------------------------------------
printf '\n-- "a SKIP counts as a pass in the total" is still accurate --\n'
if printf '%s' "$proto" | grep -qi 'skip'; then
	# Drive it: a gate that prints SKIP and exits 0 must be counted as passed by the runner. If run.sh
	# ever grew a separate skip tally, the advice would be stale in the safe direction — but stale.
	# STRIP COMMENTS FIRST. The runner's header documents which gates skip without a Go toolchain, so a
	# bare grep for "skip" reads prose as behaviour and reports a tally that does not exist — the same
	# mistake this whole suite is built to catch, committed inside the gate that polices the protocol.
	runner_code="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$RUNNER")"
	if printf '%s' "$runner_code" | grep -qiE 'skip[+_]?=|skip(ped)?\+\+|\bskipped\b[[:space:]]*[0-9=]'; then
		badln "tests/run.sh appears to keep a separate skip tally now. If it does, §7.6's warning that 'a skipped row counts as a pass in the total' is no longer accurate and must be rewritten to match — a stale warning is read once and then ignored."
	else
		ok "the runner keeps no skip tally, so a SKIP is still indistinguishable from a pass in the total — exactly what §7.6 warns about"
	fi
else
	badln "§7.6 no longer warns that a SKIP is exit-0 and counts as a pass. That warning exists because an unexplained skip is a row that has quietly stopped testing anything."
fi

# ---------------------------------------------------------------------------------------------------
# 4. THE THREE SURFACES AGREE. A contributor reads one of them, not all three.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the surfaces that tell people how to run tests do not contradict each other --\n'
for pair in "CONTRIBUTING.md:CONTRIBUTING" ".github/PULL_REQUEST_TEMPLATE.md:the PR template"; do
	f="${pair%%:*}"; label="${pair##*:}"
	if [ ! -f "$REPO_ROOT/$f" ]; then
		badln "$f is missing; it is one of the three places a contributor learns how to run the suite"
		continue
	fi
	body="$(cat "$REPO_ROOT/$f")"
	miss=""
	printf '%s' "$body" | grep -q 'tests/run.sh'        || miss="$miss tests/run.sh"
	printf '%s' "$body" | grep -q 'control/selftest.sh' || miss="$miss control/selftest.sh"
	printf '%s' "$body" | grep -qiE 'linux|macos'       || miss="$miss the-platform-caveat"
	if [ -z "$miss" ]; then
		ok "$label names the full set and the platform caveat"
	else
		badln "$label omits:$miss. A contributor who reads only this surface runs a partial suite, or concludes from a macOS run — which has already reported a tree clean that Linux reported dirty."
	fi
done

# ---------------------------------------------------------------------------------------------------
# 5. THE EVIDENCE RULE EXISTS AND IS CROSS-REFERENCED.
#
# development.md §2.2 item 12 and refactoring.md §2.7 are one rule written in two places, because the
# two documents have different readers: one is read while writing code, the other while auditing it. A
# rule that survives in only one of them is a rule half the project never sees. They were added after
# two unfounded conclusions in a row were stated as results — a client probe failing was called network
# filtering when the default route went through an unrelated tunnel, and the follow-up "that tunnel is
# inactive" rested on a single destination that the tunnel happened to release directly.
printf '\n-- the evidence rule is present in both documents that carry it --\n'
REF="$REPO_ROOT/docs/refactoring.md"
if [ ! -f "$REF" ]; then
	badln "docs/refactoring.md is missing; it is one of the two homes of the evidence rule"
else
	dev_has=0; ref_has=0
	grep -qE 'Reporting a conclusion the evidence does not carry' "$DEV" && dev_has=1
	grep -qE '^### 2\.7\..*evidence' "$REF" && ref_has=1
	if [ "$dev_has" -eq 1 ] && [ "$ref_has" -eq 1 ]; then
		ok "the rule is in development.md §2.2 and refactoring.md §2.7"
	else
		badln "the evidence rule is missing from $( [ "$dev_has" -eq 0 ] && printf 'development.md §2.2 ' )$( [ "$ref_has" -eq 0 ] && printf 'refactoring.md §2.7 ' )— one document's readers would never see it. It was written because two unfounded conclusions in a row were reported as measured results."
	fi
	# The two must POINT AT EACH OTHER, or they drift into two different rules with the same name.
	grep -q 'refactoring.md §2.7' "$DEV" \
		&& ok "and development.md cites refactoring.md §2.7 rather than restating it" \
		|| badln "development.md states the evidence rule without citing refactoring.md §2.7. Two unlinked copies of one rule diverge — that is the duplicate-source-of-truth defect §2.2 item 8 forbids, committed in prose."
	# The operational clauses are the rule. Prose without them is a slogan.
	miss=""
	for clause in "name the instrument" "could fail" "strong form" "one sample" "boundary of what"; do
		grep -qi "$clause" "$DEV" || grep -qi "$clause" "$REF" || miss="$miss '$clause'"
	done
	[ -z "$miss" ] \
		&& ok "and the operational clauses survive (instrument, falsifiable, strong form, one sample, stated boundary)" \
		|| badln "the evidence rule has been reduced to a slogan — these operational clauses are gone:$miss. 'Verify your conclusions' with no method attached is advice nobody can fail to believe they are following."
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the documented run protocol has drifted from the tree it describes.\n' >&2
	exit 1
fi
printf 'PASS: the run protocol names only things that exist, and says only true things about the runner.\n'
exit 0
