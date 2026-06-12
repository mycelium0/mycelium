#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# check_headers.sh — conformance: every commentable source/config/script carries the AGPL header.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS CHECKS
#   Each in-scope file must contain the SPDX line
#       SPDX-License-Identifier: AGPL-3.0-or-later
#   near the top (within the first 15 lines, to allow a shebang and a couple of blank lines).
#   The SPDX tag is the load-bearing, machine-verifiable part of the project header.
#
# IN SCOPE (files that support comments)
#   * shell scripts: *.sh, or any extensionless file whose first line is a shell shebang
#   * YAML:          *.yml, *.yaml  (incl. Ansible *.yml)
#   * Jinja:         *.j2           (rendered into commentable config)
#   * HCL/Terraform: *.tf, *.hcl
#   * web/docs:      *.html, *.md
#   * config:        Caddyfile, *.cfg, *.ini, *.toml, *.conf, *.example (non-JSON)
#
# OUT OF SCOPE (no comment syntax, or canonical/binary)
#   * pure JSON          — *.json AND *.json.example: must stay valid for jq/xray; the license is
#                          documented in the adjacent README, never inside the JSON.
#   * LICENSE             — the canonical GNU AGPL text.
#   * .git/               — version-control internals.
#   * gitignored paths    — local tooling/state, secrets, rendered configs, the vault
#                           (honored via `git check-ignore`; falls back to scanning
#                           everything outside a git work-tree).
#   * .gitignore          — VCS ignore list (not part of the source/config scope above).
#   * *.txt               — data/secret exports (e.g. fetched public keys), not source.
#   * binary files        — detected and skipped.
#
# Exit: 0 = every in-scope file has the header, 1 = one or more missing, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state,
# secrets, rendered runtime configs, the vault). Returns non-zero outside a git work-tree,
# so the gate still runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

SPDX='SPDX-License-Identifier: AGPL-3.0-or-later'
HEADER_SCAN_LINES=15

missing=0
checked=0

# is_in_scope PATH-REL -> 0 if the file must carry a header, 1 otherwise.
is_in_scope() {
	local rel="$1" abs="$REPO_ROOT/$1" base
	base="$(basename "$rel")"

	# Hard exclusions first. Pure JSON (with or without a .example suffix) carries NO header.
	case "$rel" in
		.git/*) return 1 ;;
	esac
	case "$base" in
		LICENSE)        return 1 ;;
		*.json)         return 1 ;;
		*.json.example) return 1 ;;
		*.txt)          return 1 ;;
		.gitignore)     return 1 ;;
	esac

	# Extension / name based inclusion.
	case "$base" in
		*.sh|*.yml|*.yaml|*.j2|*.tf|*.hcl|*.html|*.md|*.cfg|*.ini|*.toml|*.conf|*.example)
			return 0 ;;
		Caddyfile)
			return 0 ;;
	esac

	# Extensionless files: in scope only if they are shell scripts (shebang sniff).
	case "$base" in
		*.*) return 1 ;;  # has some other extension we do not police
		*)
			if head -n1 "$abs" 2>/dev/null | grep -Eq '^#!.*\b(ba)?sh\b'; then
				return 0
			fi
			return 1
			;;
	esac
}

printf '== AGPL header check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	is_in_scope "$rel" || continue

	# Skip anything that is not a text file (defensive; in-scope set is text by design).
	if grep -Iq . "$f" 2>/dev/null; then :; else continue; fi

	checked=$((checked + 1))
	if head -n "$HEADER_SCAN_LINES" "$f" | grep -Fq "$SPDX"; then
		:
	else
		printf '  MISSING HEADER  %s\n' "$rel"
		missing=$((missing + 1))
	fi
done < <(find "$REPO_ROOT" -type f -print0)

printf 'checked %d in-scope file(s); %d missing the SPDX header.\n' "$checked" "$missing"

if [ "$missing" -ne 0 ]; then
	printf 'FAIL: add the AGPL header (with "%s") to the files above.\n' "$SPDX" >&2
	exit 1
fi

printf 'PASS: every in-scope file carries the AGPL SPDX header.\n'
exit 0
