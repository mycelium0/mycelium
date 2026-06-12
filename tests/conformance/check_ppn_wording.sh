#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# check_ppn_wording.sh — conformance: PPN (persistent private network) wording gate.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS CHECKS
#   Mycelium documents and code describe a "persistent private network" in neutral,
#   technical terms. Loaded framing is forbidden anywhere in the tree. This gate FAILS
#   (exit 1) if any of the following appear in a tracked file:
#
#     * the word "censor" / "censorship" / "censoring" (any case)
#     * the word "circumvent" / "circumvention" (any case)
#     * a country name from the small denylist below (whole word, any case)
#
#   Approved neutral vocabulary (NOT flagged): persistent private network, network
#   adversary, network interference, DPI, blocking, AS-level blocking, active probing,
#   throttling, indistinguishability, adversary, reachability, resilience, persistence.
#
# WHAT IS EXCLUDED
#   * .git/                 — version-control internals, not source.
#   * gitignored paths      — local tooling/state, secrets, rendered configs, the vault
#                             (honored via `git check-ignore`).
#   * LICENSE               — the verbatim GNU AGPL text legitimately contains
#                             "Anti-Circumvention Law"; it is canonical and uneditable.
#   * this script itself     — it necessarily names the forbidden terms as patterns.
#   * the conformance dir    — sibling gates likewise carry the patterns by design.
#
# Exit: 0 = clean, 1 = at least one violation, 2 = usage/environment error.

set -euo pipefail

# Resolve the repository root (this file lives at <root>/tests/conformance/).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state,
# secrets, rendered runtime configs, the vault). Returns non-zero outside a git work-tree,
# so the gate still runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

# --- Forbidden vocabulary ---------------------------------------------------
# Substring patterns (catch inflections like censorship / circumvention).
FORBIDDEN_SUBSTR='censor|circumvent'

# Country denylist — matched as whole words (case-insensitive). Deliberately small;
# extend if a new name slips in. Adjectival forms are included where they are likely.
COUNTRY_WORDS='China|Chinese|Russia|Russian|Iran|Iranian|Korea|Korean|Venezuela|Venezuelan|Cuba|Cuban|Belarus|Belarusian|Myanmar|Turkmenistan|Syria|Syrian'

fail=0
report() {
	# report FILE LINENO MATCHTEXT
	printf '  VIOLATION %s:%s  %s\n' "$1" "$2" "$3"
	fail=1
}

printf '== PPN wording check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# Walk every regular file under the repo, skipping excluded paths and binaries.
# We use -print0 / read -d '' to be safe with unusual file names.
while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue

	# Exclusions.
	case "$rel" in
		.git/*) continue ;;
		LICENSE) continue ;;
		tests/conformance/"$SELF_NAME") continue ;;
		tests/conformance/*) continue ;;
	esac

	# Skip binary files (grep -I treats them as non-matching; we also pre-filter).
	if grep -Iq . "$f" 2>/dev/null; then :; else continue; fi

	# 1) Forbidden substrings (censor*/circumvent*).
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
	done < <(grep -IinE "$FORBIDDEN_SUBSTR" "$f" 2>/dev/null || true)

	# 2) Country names (whole word).
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
	done < <(grep -IinwE "$COUNTRY_WORDS" "$f" 2>/dev/null || true)

done < <(find "$REPO_ROOT" -type f -print0)

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: forbidden framing found. Use neutral PPN vocabulary (see header).\n' >&2
	exit 1
fi

printf 'PASS: no forbidden framing; wording is neutral.\n'
exit 0
