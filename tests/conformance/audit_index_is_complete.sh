#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# audit_index_is_complete.sh — conformance: every audit report in the tree is listed in the audit index,
# and every audit the project has actually run exists as a report.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   MEASURED 2026-08-25: `docs/audits/` held fifteen reports and the index listed six. Audits 0008 through
#   0012 — including the release-readiness audit whose single open item still blocks the tag — were in the
#   tree and invisible from the only page that claims to enumerate them.
#
#   Worse in the other direction: two audits had been RUN and never written down at all. The pre-release
#   audit at v0.2.95 and the cutover-delta audit at v0.2.101 existed as working notes, so "the audit says
#   we are ready" could not be checked by anyone, including its author. An audit nobody can read is an
#   audit nobody can check, and a project that answers release questions from memory is answering them
#   from the least reliable source it has.
#
#   `docs_link_integrity.sh` already proves every link RESOLVES. That is a different property: a report
#   that is never linked resolves perfectly.
#
# WHAT IT CHECKS
#   1. Every `NNNN-*.md` in docs/audits/ appears in docs/audits/README.md.
#   2. The index links no audit file that does not exist (caught by link integrity too, asserted here so
#      this gate's own claim is symmetric rather than half a rule).
#   3. The index actually contains rows — an empty table would satisfy 1 and 2 vacuously.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the index enumerates the audits; 1 = it does not.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
DIR="$REPO_ROOT/docs/audits"
IDX="$DIR/README.md"
# docs/audits/ is LOCAL-ONLY BY DESIGN (.gitignore) — audit reports are not published, and are cited by
# ID rather than by link. So on a fresh clone or in CI the directory is simply absent, and that is not a
# failure: there is nothing to enumerate. Skipping is stated, not silent, so an empty result here is never
# read as "the index is complete".
fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== every audit in the tree is in the index, and vice versa ==\n\n'

# ---------------------------------------------------------------------------------------------------
# WHAT THIS GATE CAN AND CANNOT DO, MEASURED.
#
# docs/audits/ is local-only by design, so in a clone, a `git archive` tarball or CI the directory is
# absent and this gate printed "PASS (skipped)" — it could not fail anywhere except the author's machine.
# (Audit-0015 S3-2.)
#
# The obvious repair was a row that runs anywhere: audits are cited BY ID across the tracked tree, so
# require the cited IDs to run 0001..max with no gaps. DRIVEN AGAINST A REAL TARBALL, THAT RULE IS FALSE:
# Audit-0002 and Audit-0003 (early tactical reviews) leave no citation in the published tree at all, so
# the row reported a hole in an audit trail that has none. A rule that fires on the healthy tree is worse
# than no rule, so it is not shipped, and this note stands in its place so the next person does not spend
# the same hour rediscovering it.
#
# What remains true: this gate needs the reports, the reports are deliberately unpublished, and therefore
# it SKIPS in a published checkout. That skip is no longer silent — tests/run.sh marks a gate with any
# skipped row as PASS* and counts it in `partial:`, so "119/119" can no longer be read as "119 checks
# ran". Making the skip visible is the fix; pretending the gate can run without its inputs is not.
# ---------------------------------------------------------------------------------------------------
ids="$(grep -rhoE 'Audit-[0-9]{4}' "$REPO_ROOT/docs" "$REPO_ROOT/tests" "$REPO_ROOT/control" \
	"$REPO_ROOT/scripts" "$REPO_ROOT/internal" "$REPO_ROOT/cmd" 2>/dev/null \
	| grep -oE '[0-9]{4}$' | sort -u)"

if [ ! -f "$IDX" ]; then
	printf '  SKIP  no docs/audits/ in this checkout (local-only by design), so EVERY row of this gate was\n'
	printf '        skipped: it checked nothing here. tests/run.sh counts this gate as PASS* / partial.\n'
	printf '\n-- Result --\nPASS (nothing checked — see the SKIP above)\n'
	exit 0
fi

idx="$(cat "$IDX")"

rows="$(grep -c '^| Audit-' "$IDX" 2>/dev/null || printf 0)"
[ "${rows:-0}" -ge 1 ] \
	&& ok "the index lists $rows audit(s)" \
	|| badln "the index table is empty, so both rows below would pass by having nothing to compare"

# EVERY CITED ID MUST HAVE AN INDEX ROW. The rows on either side of this one compare the index against
# the FILES in docs/audits/, so an audit that left citations in the tree but no report — Audit-0007, whose
# outcome landed as ADR-0036 and whose report was never filed here — was invisible to both: no file to be
# unlisted, no row to be unbacked. The index is the only page that claims to enumerate the audits, so an
# ID the tree cites and the index omits is one a reader is told exists and cannot find. A row saying
# "report not retained, see ADR-XXXX" satisfies this; silence does not.
uncited=""
while IFS= read -r id; do
	[ -n "$id" ] || continue
	grep -qE "^\| Audit-$id " <<<"$idx" || uncited="$uncited Audit-$id"
done <<<"$ids"
[ -z "$uncited" ] \
	&& ok "every audit ID the tree cites has an index row" \
	|| badln "the tree cites$uncited and the index has no row for it. Either file the report, or give the ID a row that says where its outcome went — a reader following a citation to a page that does not mention the ID has no next step."

missing=""
for f in "$DIR"/[0-9][0-9][0-9][0-9]-*.md; do
	[ -e "$f" ] || continue
	b="$(basename "$f")"
	grep -qF -- "$b" <<<"$idx" || missing="$missing $b"
done
if [ -z "$missing" ]; then
	ok "every report in docs/audits/ is listed"
else
	badln "these reports exist and the index does not mention them:$missing. The index is the only page that claims to enumerate the audits — a report it omits is one nobody will find, including the person asking whether the project has been audited."
fi

dangling=""
while read -r ref; do
	[ -n "$ref" ] || continue
	[ -e "$DIR/$ref" ] || dangling="$dangling $ref"
done <<EOF
$(grep -oE '\(([0-9]{4}-[A-Za-z0-9._-]+\.md)\)' "$IDX" | tr -d '()' | sort -u)
EOF
[ -z "$dangling" ] \
	&& ok "and the index names no report that is missing from the tree" \
	|| badln "the index links reports that do not exist:$dangling"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the audit index does not enumerate the audits.\n' >&2
	exit 1
fi
printf 'PASS: the index and the directory agree.\n'
exit 0
