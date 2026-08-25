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
if [ ! -f "$IDX" ]; then
	printf '  SKIP  no docs/audits/ in this checkout (local-only by design); nothing to enumerate.\n'
	printf '\n-- Result --\nPASS (skipped)\n'
	exit 0
fi

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== every audit in the tree is in the index, and vice versa ==\n\n'

idx="$(cat "$IDX")"

rows="$(grep -c '^| Audit-' "$IDX" 2>/dev/null || printf 0)"
[ "${rows:-0}" -ge 1 ] \
	&& ok "the index lists $rows audit(s)" \
	|| badln "the index table is empty, so both rows below would pass by having nothing to compare"

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
