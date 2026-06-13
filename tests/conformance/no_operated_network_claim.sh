#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_operated_network_claim.sh — conformance: no AFFIRMATIVE "operates a public network" claim.
# Author: mindicator & silicon bags quartet.
#
# POLICY (README "separation statement"; GOVERNANCE.md / TRADEMARKS.md / ACCEPTABLE-USE.md /
#         SECURITY.md / docs/runbooks/node-bootstrap.md)
#   This repository publishes server-side SOFTWARE. It does NOT operate a public network, publish
#   public endpoints, or distribute public client configs; each operator independently deploys and
#   controls their OWN node. The project must therefore never make the AFFIRMATIVE claim that it
#   operates / owns a public network — that would contradict the separation statement and the
#   trademark/governance posture.
#
# WHAT THIS CHECKS  (FAIL = exit 1)
#   An AFFIRMATIVE network-operator claim, i.e. a sentence asserting one of:
#       * "operates / runs (a|the|its own) (public) network"
#       * "owned and operated"
#       * "network owner(s)"
#   …WITHOUT a negation token in the SAME sentence. The canonical, REQUIRED separation wording —
#   "(does) not operate a public network", "Software, not an operated network", "the project runs
#   no network", "there is no single project-wide owner of a network" — all carry a negation in the
#   sentence and are explicitly ALLOWED (this gate exists to protect that wording, not to forbid it).
#
# HOW IT WORKS — sentence-aware, so a negation that wraps onto the next source line still counts.
#   Per *.md file: strip the leading markdown blockquote marker ("> "), collapse newlines+runs of
#   whitespace into single spaces, split into sentences on ". ". A sentence is a VIOLATION iff it
#   contains an affirmative phrase AND no negation token (not / no / never / n't / none / without /
#   nor). The negation may sit anywhere in the sentence, which is why the separation statement
#   (negation often a few words before the phrase, sometimes across a line break) stays green.
#
# WHAT IS SCANNED:  *.md prose only (this claim is a marketing/positioning statement, not config).
# WHAT IS EXCLUDED: .git/, gitignored paths (git check-ignore), this conformance directory, and
#                   this script itself (it necessarily names the affirmative phrases as patterns).
#
# Exit: 0 = clean, 1 = an affirmative operate-a-network claim was found, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# _ignored REL -> 0 if git would ignore this repo-relative path. Returns non-zero outside a git
# work-tree, so the gate still runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

# Affirmative network-operator phrasings (case-insensitive).
AFFIRM='(operates?|operating|run|runs|running)[[:space:]]+(its[[:space:]]+own[[:space:]]+|a[[:space:]]+|the[[:space:]]+)?(public[[:space:]]+)?network|owned[[:space:]]+and[[:space:]]+operated|network[[:space:]]+owners?'
# Negation tokens (whole-word). Presence anywhere in the SAME sentence clears the claim.
NEG='(\bnot\b|\bno\b|\bnever\b|n.t\b|\bnone\b|\bwithout\b|\bnor\b)'

fail=0
report() {
	# report FILE SENTENCE
	printf '  CLAIM    %s  %s\n' "$1" "$(printf '%s' "$2" | sed 's/^[[:space:]]*//')"
	fail=1
}

printf '== operated-network claim check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

scan_md() {
	local f rel norm
	f="$1"; rel="${f#"$REPO_ROOT"/}"
	grep -Iq . "$f" 2>/dev/null || return 0

	# Normalize: drop a leading blockquote "> ", flatten newlines to spaces, squeeze spaces, then
	# put one sentence per line (split on ". ").
	norm="$(sed 's/^[[:space:]]*>[[:space:]]\?//' "$f" 2>/dev/null \
		| tr '\n' ' ' | tr -s ' ' | sed 's/\. /.\n/g')"
	[ -n "$norm" ] || return 0

	# A sentence with an affirmative phrase and NO negation token is a violation.
	while IFS= read -r sentence; do
		[ -n "$sentence" ] || continue
		report "$rel" "$sentence"
	done < <(printf '%s\n' "$norm" | grep -iE "($AFFIRM)" | grep -viE "$NEG" || true)
}

while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	scan_md "$f"
done < <(find "$REPO_ROOT" -type f -name '*.md' \
	-not -path '*/.git/*' -not -path '*/tests/conformance/*' -print0)

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: an AFFIRMATIVE operate-a-public-network claim was found.\n' >&2
	printf '      The repository publishes SOFTWARE and does NOT operate a public network. State the\n' >&2
	printf '      separation negatively (e.g. "does not operate a public network"; "Software, not an\n' >&2
	printf '      operated network"); never assert that the project operates or owns a network.\n' >&2
	exit 1
fi

printf 'PASS: no affirmative operate-a-public-network claim; separation wording is intact.\n'
exit 0
