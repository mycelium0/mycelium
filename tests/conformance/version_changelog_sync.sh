#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# version_changelog_sync.sh — conformance: the single-source spine version equals the newest
# CHANGELOG heading, so a version bump and its changelog entry can never drift apart.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   internal/spec.Version is the single runtime source of truth for the version (development.md
#   §1.2). The project bumps it per landed phase increment (0.<phase>.<patch>) AND records that
#   increment in CHANGELOG.md in the SAME commit. This gate makes the coupling enforceable: it
#   FAILS if the const and the newest CHANGELOG version disagree — catching "bumped the const but
#   forgot the changelog" and "added a changelog entry but forgot the const".
#
#   IT USED TO STOP THERE, and said so: it "cannot, offline, prove a chunk SHOULD have bumped — that
#   stays the documented per-chunk discipline + review". The discipline is what failed. The version sat
#   at 0.2.29 for 27 days and 97 commits, 67 of them feat/fix, and this gate was GREEN the whole time —
#   a frozen const and a frozen CHANGELOG agree perfectly. A consistency check is satisfied by changing
#   nothing.
#
#   Part of it IS checkable offline, and it is the part that bites. release.yml (:53) extracts the notes
#   for the block whose heading matches spec.Version; `[Unreleased]` sits ABOVE that anchor and is
#   silently dropped. So a non-empty `[Unreleased]` means the notes the release publishes OMIT real
#   changes — on 2026-08-01 that block was 225 lines, and the release would have described the tree as
#   of 2026-07-04. Requiring it empty forces every entry under a real version heading, which forces the
#   bump.
#   OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. internal/spec/version.go declares `const Version = "X.Y.Z"` (SemVer).
#   2. CHANGELOG.md's newest `## [X.Y.Z]` heading exists and matches that version exactly.
#   3. `## [Unreleased]`, if present, is EMPTY.
#
# Exit: 0 = in sync, 1 = drift, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'version_changelog_sync: cannot resolve repo root\n' >&2; exit 2; }
VERSION_GO="$REPO_ROOT/internal/spec/version.go"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== version <-> CHANGELOG sync check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

[ -f "$VERSION_GO" ] || { printf 'FAIL: internal/spec/version.go missing\n' >&2; exit 1; }
[ -f "$CHANGELOG" ]  || { printf 'FAIL: CHANGELOG.md missing\n' >&2; exit 1; }

# Spine version constant (first `const Version = "..."`).
ver="$(grep -E '^[[:space:]]*const[[:space:]]+Version[[:space:]]*=[[:space:]]*"' "$VERSION_GO" \
	| head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
# Newest CHANGELOG version (first `## [X.Y.Z]` heading; an [Unreleased] heading is skipped).
top="$(grep -E '^##[[:space:]]*\[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" \
	| head -1 | sed -E 's/^##[[:space:]]*\[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')"

if [ -z "$ver" ]; then
	badln "could not read a SemVer 'const Version = \"X.Y.Z\"' from internal/spec/version.go"
elif grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$ver" ; then
	ok "spine version: $ver"
else
	badln "spine version $ver is not SemVer X.Y.Z"
fi

if [ -z "$top" ]; then
	badln "could not read a newest '## [X.Y.Z]' heading from CHANGELOG.md"
else
	ok "newest CHANGELOG version: $top"
fi

if [ -n "$ver" ] && [ -n "$top" ]; then
	if [ "$ver" = "$top" ]; then
		ok "spine version matches the newest CHANGELOG heading"
	else
		badln "DRIFT: spec.Version=$ver but newest CHANGELOG heading=$top — bump both in the same commit"
	fi
fi

# 3. [Unreleased] must be empty — see the header. This is the half that fails on a frozen version.
unrel="$(awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f{print}' "$CHANGELOG" | tr -d '[:space:]')"
if [ -z "$unrel" ]; then
	ok "[Unreleased] is empty — every recorded change sits under a version the release will publish"
else
	nl="$(awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f{n++} END{print n+0}' "$CHANGELOG")"
	badln "[Unreleased] holds $nl lines of real changes. release.yml extracts ONLY the block matching spec.Version, and [Unreleased] sits above it, so those changes would be silently absent from the published notes. Move them under a version heading — which means bumping spec.Version. This is the check that would have caught the version frozen for 27 days and 97 commits while this gate stayed green."
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the spine version and the newest CHANGELOG entry are in sync, and nothing is parked in [Unreleased].\n'
	exit 0
fi
printf 'FAIL: version <-> CHANGELOG drift (or a malformed version/heading).\n' >&2
exit 1
