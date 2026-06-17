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
#   forgot the changelog" and "added a changelog entry but forgot the const". (It cannot, offline,
#   prove a chunk SHOULD have bumped — that stays the documented per-chunk discipline + review.)
#   OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. internal/spec/version.go declares `const Version = "X.Y.Z"` (SemVer).
#   2. CHANGELOG.md's newest `## [X.Y.Z]` heading exists and matches that version exactly.
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
elif printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
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

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the spine version and the newest CHANGELOG entry are in sync.\n'
	exit 0
fi
printf 'FAIL: version <-> CHANGELOG drift (or a malformed version/heading).\n' >&2
exit 1
