#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# docs_link_integrity.sh — conformance: every relative link in a TRACKED document resolves, and no
# tracked document links to a file that is never published.
#
# WHY THIS GATE EXISTS. The documentation corpus drifts in one characteristic way: an edit lands in one
# place and the documents that point at it are not touched. Most of that drift needs a human to notice,
# but the mechanical half — a link to a path that does not exist, or a path that exists only on the
# author's disk — is checkable offline and cheap. Two such links shipped (RP-0015 and RP-0016 both cited
# an ADR under a filename that was never in the tree) and were found only by a deliberate audit.
#
# TWO CHECKS
#   1. RESOLVES — a relative link target exists (file or directory). Catches renames, invented slugs,
#      and moved files.
#   2. PUBLISHED — a tracked document never links to an UNTRACKED path. `docs/audits/` and
#      `docs/research/` are deliberately gitignored local-only records; a public document pointing at
#      one sends every reader to a 404 and advertises the existence of material that was never meant to
#      ship. This half also catches links to build output or operator-local state.
#
# NOT CHECKED (deliberately): external URLs (no network in this suite — an offline gate must not depend
# on the internet being up or a remote host being polite), and `#fragment` anchors within a file.
#
# The file list comes from `git ls-files`, so untracked scratch files are never scanned and the check
# needs no ignore-file interpretation of its own.
#
# Exit: 0 = every link resolves and is published, 1 = a broken or unpublished link, 2 = usage/precondition.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
cd "$REPO_ROOT" || { printf 'FAIL: cannot enter repo root.\n' >&2; exit 2; }

printf '== documentation link integrity ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v git >/dev/null 2>&1 || { printf 'SKIP: git unavailable (source tarball) — nothing to enumerate.\n'; exit 0; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'SKIP: not a git work-tree (source tarball).\n'; exit 0; }

docs="$(git ls-files '*.md' 2>/dev/null)"
[ -n "$docs" ] || { printf 'FAIL: git ls-files returned no markdown files.\n' >&2; exit 2; }

# The tracked-path set, built ONCE into a sorted file: every tracked file PLUS every ancestor directory
# of one (a link to `../adr/` is a real browsable path, but directories never appear in `git ls-files`).
# Membership is then a single sorted-set difference instead of a grep per link — 1700+ links make the
# per-link form dominate the whole suite's runtime.
WORK="$(mktemp -d)" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

git ls-files 2>/dev/null | awk '
	{ print $0
	  n = split($0, part, "/")
	  acc = ""
	  for (i = 1; i < n; i++) { acc = (i == 1 ? part[i] : acc "/" part[i]); print acc }
	}' | sort -u > "$WORK/tracked"

# normalize PATH -> collapse "a/b/../c" and "./" so the result can be compared to a git path.
# Pure bash on purpose: this runs once per link, and spawning a process per link dominated the runtime.
normalize() {
	local p="$1" part out=() IFS='/'
	read -r -a _parts <<< "$p"
	for part in "${_parts[@]}"; do
		case "$part" in
			''|'.') continue ;;
			'..') [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
			*) out+=("$part") ;;
		esac
	done
	printf '%s' "${out[*]}"
}

# Pass 1: resolve every relative link to a repo path, recording "rel<TAB>doc<TAB>link".
broken=0
checked=0
while IFS= read -r doc; do
	[ -n "$doc" ] || continue
	dir="$(dirname "$doc")"
	while IFS= read -r link; do
		[ -n "$link" ] || continue
		case "$link" in
			http://*|https://*|mailto:*|'#'*|'<'*) continue ;;
		esac
		target="${link%%#*}"          # drop the #fragment
		target="${target%% *}"        # drop a ("title") suffix
		[ -n "$target" ] || continue  # a bare #anchor
		case "$target" in
			'/'*) rel="$(normalize "${target#/}")" ;;
			*)    rel="$(normalize "$dir/$target")" ;;
		esac
		[ -n "$rel" ] || continue
		checked=$((checked + 1))
		if [ ! -e "$REPO_ROOT/$rel" ]; then
			printf '  BROKEN       %s -> %s\n' "$doc" "$link"
			broken=$((broken + 1))
		else
			printf '%s\t%s\t%s\n' "$rel" "$doc" "$link" >> "$WORK/resolved"
		fi
	done < <(grep -oE '\]\([^)]+\)' "$doc" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')
done <<EOF
$docs
EOF

# Pass 2: one sorted-set difference gives every target that exists on disk but is not tracked; a single
# awk join then attributes each to the document(s) that referenced it.
unpublished=0
if [ -s "$WORK/resolved" ]; then
	cut -f1 "$WORK/resolved" | sort -u > "$WORK/targets"
	comm -23 "$WORK/targets" "$WORK/tracked" > "$WORK/untracked"
	if [ -s "$WORK/untracked" ]; then
		awk -F'\t' 'NR==FNR { bad[$0]=1; next }
			($1 in bad) { printf "  UNPUBLISHED  %s -> %s  (exists locally but is not tracked — a reader of the published repo cannot follow it)\n", $2, $3; n++ }
			END { exit 0 }' "$WORK/untracked" "$WORK/resolved"
		unpublished="$(awk -F'\t' 'NR==FNR { bad[$0]=1; next } ($1 in bad) { n++ } END { print n+0 }' "$WORK/untracked" "$WORK/resolved")"
	fi
fi

# ---------------------------------------------------------------------------------------------------
# EVERY ADR IS IN THE INDEX. An unindexed decision record is one nobody finds.
#
# docs/adr/README.md is the only enumeration of what has been decided. It was silently one behind when
# this row was written — ADR-0038 had shipped and was never listed — so the index had already begun
# doing what this project keeps catching documents doing: staying true as of the day it was written.
# Link integrity cannot notice this, because a document nobody links to breaks no link.
adr_dir="$REPO_ROOT/docs/adr"
if [ ! -d "$adr_dir" ] || [ ! -f "$adr_dir/README.md" ]; then
	printf '  SKIP  docs/adr/README.md not present; the index check did not run.\n'
else
	missing=""; n=0
	for f in "$adr_dir"/[0-9]*.md; do
		[ -f "$f" ] || continue
		n=$((n + 1))
		id="$(basename "$f" | cut -d- -f1)"
		grep -q "^| \[$id\]" "$adr_dir/README.md" || missing="$missing $id"
	done
	unindexed=0
	if [ "$n" -lt 5 ]; then
		printf '  FAIL  only %d ADR file(s) were seen — the scan is not reaching docs/adr/, so a clean result here means nothing.\n' "$n"
		unindexed=1
	elif [ -z "$missing" ]; then
		printf '  ok    all %d ADRs appear in docs/adr/README.md\n' "$n"
	else
		printf '  FAIL  these ADRs exist but are absent from docs/adr/README.md:%s. The index is the only enumeration of what this project has decided; a record that is not in it is one nobody finds, and link integrity cannot catch it because an unlinked document breaks no link.\n' "$missing"
		unindexed=$(printf '%s' "$missing" | wc -w | tr -d ' ')
	fi
fi

printf '\n-- Result --\n'
printf 'checked %d relative link(s) across %d tracked document(s).\n' "$checked" "$(printf '%s\n' "$docs" | grep -c '')"
if [ "$broken" -ne 0 ] || [ "$unpublished" -ne 0 ] || [ "${unindexed:-0}" -ne 0 ]; then
	[ "$broken" -ne 0 ]      && printf 'FAIL: %d link(s) point at a path that does not exist.\n' "$broken" >&2
	[ "$unpublished" -ne 0 ] && printf 'FAIL: %d link(s) point at an UNTRACKED path — a reader of the published repo cannot follow them (docs/audits/ and docs/research/ are local-only by design; cite the code or an ADR instead).\n' "$unpublished" >&2
	[ "${unindexed:-0}" -ne 0 ] && printf 'FAIL: %d ADR(s) are absent from docs/adr/README.md — the only enumeration of what this project has decided.\n' "$unindexed" >&2
	exit 1
fi
printf 'PASS: every relative link resolves to a tracked path, and every ADR is in the index.\n'
exit 0
