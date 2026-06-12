#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_contact_leak.sh — conformance: no personal contact details (real email addresses) in the tree.
# Author: mindicator & silicon bags quartet.
#
# WHY
#   The operator's identity belongs in git author metadata (set in local git config), NOT written
#   into tracked files. A personal email in public docs or code is a privacy + spam exposure and an
#   avoidable de-anonymisation breadcrumb. This gate FAILS (exit 1) if any real-looking email
#   address appears in a tracked file.
#
# ALLOWED (NOT flagged) — documentation/test placeholders only:
#   * example domains:  *@example.com / .org / .net, *@*.example
#   * reserved TLDs:    *@*.invalid, *@*.test, *@*.localhost   (RFC 2606 / 6761)
#   * noreply locals:   noreply@... / no-reply@...
#   * angle-bracket placeholders such as  security@<domain>  never match (not a literal address).
#
# EXCLUSIONS: .git/, gitignored paths (git check-ignore), this conformance directory (it carries
# the patterns by design), and binary files.
#
# Exit: 0 = clean, 1 = a real email address is present, 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state, secrets,
# rendered runtime configs, the vault). Returns non-zero outside a git work-tree.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

# A pragmatic email shape: local@domain.tld with an alphabetic TLD. Angle-bracket placeholders
# (security@<domain>) do NOT match because '<' is not in the domain character class.
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'

fail=0
report() {
	printf '  CONTACT-LEAK %s:%s  %s\n' "$1" "$2" "$3"
	fail=1
}

# is_allowed EMAIL -> 0 if this address is a documentation/test placeholder, 1 otherwise.
is_allowed() {
	case "$1" in
		*@example.com|*@example.org|*@example.net) return 0 ;;
		*@*.example|*@*.invalid|*@*.test|*@*.localhost) return 0 ;;
		noreply@*|no-reply@*) return 0 ;;
	esac
	return 1
}

printf '== contact-leak check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

checked=0
while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	case "$rel" in
		.git/*) continue ;;
		tests/conformance/*) continue ;;
	esac
	_ignored "$rel" && continue
	# Text files only.
	if grep -Iq . "$f" 2>/dev/null; then :; else continue; fi
	checked=$((checked + 1))

	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		# Test each email-shaped token on the line against the allowlist.
		for tok in $(printf '%s\n' "$text" | grep -oE "$EMAIL_RE" || true); do
			is_allowed "$tok" && continue
			report "$rel" "$lineno" "$tok"
		done
	done < <(grep -nIE "$EMAIL_RE" "$f" 2>/dev/null || true)
done < <(find "$REPO_ROOT" -type f -print0)

printf 'scanned %d text file(s).\n' "$checked"

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a personal/real email address is present in a tracked file. The operator identity\n' >&2
	printf '      belongs in local git config (the commit author), not in the tree. Use a placeholder\n' >&2
	printf '      (security@<domain>, *@example.com) or route contact through GitHub advisories.\n' >&2
	exit 1
fi

printf 'PASS: no real email addresses in tracked files (placeholders only).\n'
exit 0
