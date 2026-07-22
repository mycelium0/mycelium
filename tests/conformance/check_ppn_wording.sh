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
#     * the apparatus acronyms "DPI" / "TSPU" / "ТСПУ" — name the PHENOMENON
#       (network degradation), never the filtering box (whole word, any case)
#     * a country name from the small denylist below (whole word, any case)
#
#   The SAME patterns are also checked against COMMIT MESSAGES (not just files): a forbidden
#   term in a message is just as public, and one slipped past this gate once (a 'circumvent'
#   substring rode a commit message while the doc it described was already neutral — the file
#   walk cannot see messages). By default only HEAD's message is scanned (so frozen pre-policy
#   history never trips it); set MYC_PPN_MSG_RANGE=<rev-range> (e.g. origin/main..HEAD) to scan
#   every new message in a range before landing them.
#
#   Approved neutral vocabulary (NOT flagged): persistent private network, network
#   adversary, network interference, network degradation, forced degradation, network
#   stability attacks, behavioral-layer detection, blocking, AS-level blocking, active
#   probing, throttling, indistinguishability, adversary, reachability, resilience,
#   persistence.
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
# Substring patterns (catch inflections like censorship / circumvention; ТСПУ is the
# Cyrillic apparatus acronym, matched as a substring because word boundaries are
# unreliable around multibyte text in the C locale).
FORBIDDEN_SUBSTR='censor|circumvent|ТСПУ'

# Apparatus acronyms — name the PHENOMENON ("network degradation"), never the filtering
# box. Whole-word, case-insensitive (so "DPI"/"dpi"/"Dpi" all trip, but substrings do not).
FORBIDDEN_WORDS='DPI|TSPU'

# Country denylist — matched as whole words (case-insensitive). Comprehensive: a deploy
# jurisdiction or node location must never leak into the tree, so this covers UN member
# states (common short names) plus the adjectival forms most likely to appear in prose.
# A few country names that collide hard with ordinary English/identifiers are intentionally
# omitted to avoid false positives (e.g. "Chad", "Jordan", "Georgia", "Chile", "Turkey"
# as the bird, "Polish" the verb) — their abbreviated and adjectival leaks are still caught
# by COUNTRY_WORDS adjectives and the LOCATION_CODES pattern below.
COUNTRY_WORDS='Afghanistan|Albania|Algeria|Andorra|Angola|Argentina|Argentine|Armenia|Armenian|Australia|Australian|Austria|Austrian|Azerbaijan|Azerbaijani|Bahamas|Bahrain|Bangladesh|Barbados|Belarus|Belarusian|Belgium|Belgian|Belize|Benin|Bhutan|Bolivia|Bosnia|Botswana|Brazil|Brazilian|Brunei|Bulgaria|Bulgarian|Burkina|Burundi|Cambodia|Cameroon|Canada|Canadian|Cameroonian|China|Chinese|Colombia|Colombian|Comoros|Congo|Croatia|Croatian|Cuba|Cuban|Cyprus|Cypriot|Czechia|Czech|Denmark|Danish|Djibouti|Dominica|Ecuador|Ecuadorian|Egypt|Egyptian|Eritrea|Estonia|Estonian|Eswatini|Ethiopia|Ethiopian|Fiji|Finland|Finnish|France|French|Gabon|Gambia|Germany|German|Ghana|Ghanaian|Greece|Greek|Grenada|Guatemala|Guinea|Guyana|Haiti|Honduras|Hungary|Hungarian|Iceland|Icelandic|India|Indonesia|Indonesian|Iran|Iranian|Iraq|Iraqi|Ireland|Irish|Israel|Israeli|Italy|Italian|Jamaica|Japan|Japanese|Kazakhstan|Kazakh|Kenya|Kenyan|Kiribati|Korea|Korean|Kosovo|Kuwait|Kuwaiti|Kyrgyzstan|Kyrgyz|Laos|Latvia|Latvian|Lebanon|Lebanese|Lesotho|Liberia|Libya|Libyan|Liechtenstein|Lithuania|Lithuanian|Luxembourg|Madagascar|Malawi|Malaysia|Malaysian|Maldives|Malta|Maltese|Mauritania|Mauritius|Mexico|Mexican|Micronesia|Moldova|Moldovan|Monaco|Mongolia|Mongolian|Montenegro|Morocco|Moroccan|Mozambique|Myanmar|Namibia|Nauru|Nepal|Nepalese|Netherlands|Dutch|Nicaragua|Nigeria|Nigerian|Norway|Norwegian|Oman|Pakistan|Pakistani|Palau|Palestine|Palestinian|Panama|Papua|Paraguay|Peru|Peruvian|Philippines|Filipino|Poland|Portugal|Portuguese|Qatar|Qatari|Romania|Romanian|Russia|Russian|Rwanda|Samoa|Senegal|Senegalese|Serbia|Serbian|Seychelles|Singapore|Singaporean|Slovakia|Slovak|Slovenia|Slovenian|Somalia|Somali|Spain|Spaniard|Spanish|Sudan|Sudanese|Suriname|Sweden|Swedish|Switzerland|Swiss|Syria|Syrian|Taiwan|Taiwanese|Tajikistan|Tajik|Tanzania|Tanzanian|Thailand|Togo|Tonga|Tunisia|Tunisian|Turkish|Turkmenistan|Tuvalu|Uganda|Ukraine|Ukrainian|Uruguay|Uzbekistan|Uzbek|Vanuatu|Venezuela|Venezuelan|Vietnam|Vietnamese|Yemen|Yemeni|Zambia|Zambian|Zimbabwe|Soviet'

# Parenthesised location-code lists, e.g. "(KZ, DE)" — two or more uppercase
# two-letter codes inside parentheses. Matched case-sensitively (so it does not trip
# on ordinary lowercase prose). Catches abbreviated node-location leaks.
LOCATION_CODES='\([A-Z]{2}(, ?[A-Z]{2})+\)'

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

	# 1) Forbidden substrings (censor*/circumvent*/ТСПУ).
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
	done < <(grep -IinE "$FORBIDDEN_SUBSTR" "$f" 2>/dev/null || true)

	# 1b) Apparatus acronyms (DPI/TSPU), whole word.
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
	done < <(grep -IinwE "$FORBIDDEN_WORDS" "$f" 2>/dev/null || true)

	# 2) Country names (whole word).
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
	done < <(grep -IinwE "$COUNTRY_WORDS" "$f" 2>/dev/null || true)

	# 3) Parenthesised location-code lists (case-sensitive), e.g. "(KZ, DE)".
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
	done < <(grep -InE "$LOCATION_CODES" "$f" 2>/dev/null || true)

done < <(find "$REPO_ROOT" -type f -print0)

# --- Commit MESSAGE scan --------------------------------------------------------------------
# The file walk cannot see commit messages, yet a forbidden term in a message is just as public
# (it slipped through once). Scan HEAD's message by default; MYC_PPN_MSG_RANGE scans a range of
# new messages. Skips cleanly with no git work-tree (a source tarball has no messages). Only the
# selected commits are scanned — frozen pre-policy history is never re-litigated.
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	if [ -n "${MYC_PPN_MSG_RANGE:-}" ]; then
		msg_commits="$(git -C "$REPO_ROOT" rev-list "$MYC_PPN_MSG_RANGE" 2>/dev/null || true)"
	else
		msg_commits="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
	fi
	for c in $msg_commits; do
		short="$(git -C "$REPO_ROOT" rev-parse --short "$c" 2>/dev/null || printf '%s' "$c")"
		body="$(git -C "$REPO_ROOT" log -1 "$c" --format='%B' 2>/dev/null || true)"
		[ -n "$body" ] || continue
		loc="commit ${short} (message)"
		# Same four pattern groups as the file scan, with the same grep flags.
		while IFS=: read -r lineno text; do
			[ -n "${lineno:-}" ] || continue
			report "$loc" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
		done < <(printf '%s\n' "$body" | grep -inE "$FORBIDDEN_SUBSTR" || true)
		while IFS=: read -r lineno text; do
			[ -n "${lineno:-}" ] || continue
			report "$loc" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
		done < <(printf '%s\n' "$body" | grep -inwE "$FORBIDDEN_WORDS" || true)
		while IFS=: read -r lineno text; do
			[ -n "${lineno:-}" ] || continue
			report "$loc" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
		done < <(printf '%s\n' "$body" | grep -inwE "$COUNTRY_WORDS" || true)
		while IFS=: read -r lineno text; do
			[ -n "${lineno:-}" ] || continue
			report "$loc" "$lineno" "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
		done < <(printf '%s\n' "$body" | grep -nE "$LOCATION_CODES" || true)
	done
fi

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: forbidden framing found. Use neutral PPN vocabulary (see header).\n' >&2
	exit 1
fi

printf 'PASS: no forbidden framing; wording is neutral.\n'
exit 0
