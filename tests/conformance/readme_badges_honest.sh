#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# readme_badges_honest.sh — conformance (RP-0011 Operability chunk A / AC-10): the README badge row
# is HONEST and positioning-clean. The version + Go pills must equal their single source of truth
# (internal/spec.Version and go.mod) so they cannot silently drift; the badge block must make NO
# affirmative operated-network / uptime / status-page / online claim (ADR-0016 separation statement /
# no_operated_network_claim); and every self-hosted shields endpoint must reference only this repo's
# own slug. OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = badges honest + clean, 1 = a drift/claim/leak, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'readme_badges_honest: cannot resolve repo root\n' >&2; exit 2; }
README="$REPO_ROOT/README.md"
VERSION_GO="$REPO_ROOT/internal/spec/version.go"
GOMOD="$REPO_ROOT/go.mod"
SLUG="mycelium0/mycelium"

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== README badges honesty (version/go pills match source; no operated-network claim) ==\n'
for f in "$README" "$VERSION_GO" "$GOMOD"; do
	[ -f "$f" ] || { printf 'readme_badges_honest: missing %s\n' "$f" >&2; exit 2; }
done

# The badge lines (each pill is on its own line: a shields.io / actions-status / endpoint image).
# Scoped by badge markers so the logo's <p align="center"> block is not mistaken for the badge row.
block="$(grep -E 'img\.shields\.io|/actions/workflows/[^)]*badge\.svg|raw\.githubusercontent\.com' "$README")"
[ -n "$block" ] || { bad "no badge row found in README.md (expected shields.io / actions-status pills)"; }

# 1. EVERY version pill message == internal/spec.Version (not just the first — no stale pill escapes)
spec_ver="$(grep -oE 'Version[[:space:]]*=[[:space:]]*"[^"]+"' "$VERSION_GO" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
ver_pills="$(printf '%s\n' "$block" | grep -oE 'badge/version-[0-9]+\.[0-9]+\.[0-9]+' | sed -E 's#badge/version-##')"
ver_bad="$(printf '%s\n' "$ver_pills" | grep -vxF "$spec_ver" | grep -v '^$' || true)"
if [ -n "$ver_pills" ] && [ -z "$ver_bad" ]; then
	ok "version pill(s) all == internal/spec.Version ($spec_ver)"
else
	bad "version pill drift/missing — spec.Version='$spec_ver', offending='${ver_bad:-none}'"
fi

# 2. EVERY Go pill == the go.mod go directive
gomod_go="$(grep -oE '^go[[:space:]]+[0-9]+\.[0-9]+' "$GOMOD" | awk '{print $2}')"
go_pills="$(printf '%s\n' "$block" | grep -oE 'badge/go-[0-9]+\.[0-9]+' | sed -E 's#badge/go-##')"
go_bad="$(printf '%s\n' "$go_pills" | grep -vxF "$gomod_go" | grep -v '^$' || true)"
if [ -n "$go_pills" ] && [ -z "$go_bad" ]; then
	ok "go pill(s) all == go.mod ($gomod_go)"
else
	bad "go pill drift/missing — go.mod='$gomod_go', offending='${go_bad:-none}'"
fi

# 3. no affirmative operated-network / uptime / status-page / online claim in the badge block
if printf '%s' "$block" | grep -qiE 'uptime|status[ -]?page|\bonline\b|operational|live network|operates a'; then
	bad "badge block makes an operated-network / uptime / online claim (ADR-0016 / no_operated_network_claim)"
else
	ok "badge block makes no operated-network / uptime / online claim"
fi

# 4. every githubusercontent/github endpoint references only this repo's own slug
foreign="$(printf '%s' "$block" | grep -oE '(raw\.githubusercontent\.com|github\.com)/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
	| grep -vE "/(${SLUG})(/|$)" || true)"
if [ -n "$foreign" ]; then
	bad "a badge references a foreign slug: $(printf '%s' "$foreign" | tr '\n' ' ')"
else
	ok "all badge endpoints reference only the $SLUG slug"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: README badges are honest, drift-pinned, and positioning-clean.\n'
	exit 0
fi
printf 'FAIL: README badges drifted or made a forbidden claim — see above.\n' >&2
exit 1
