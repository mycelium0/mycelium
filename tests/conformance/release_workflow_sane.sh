#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# release_workflow_sane.sh — conformance (RP-0011 REL-2): the release workflow is honest + safe.
# .github/workflows/release.yml must:
#   1. trigger ONLY on a `v*` tag (a release is a signed tag, not a branch push);
#   2. build the artifact via `make dist` and VERIFY it with the release_dist_sane gate before publish;
#   3. guard that the tag matches internal/spec.Version (no name drift);
#   4. pin every third-party action to a full 40-hex commit SHA (supply-chain hygiene, like ci.yml);
#   5. hold NO signing secret — CI builds + publishes only; the tag + SHA256SUMS are signed LOCALLY by
#      the maintainer (ADR-0015 SSH-sig), so a CI compromise cannot forge a release. The workflow must
#      not run any signing tool (ssh-keygen -Y sign / gpg --sign / minisign / cosign sign) and must use
#      only the built-in github.token, never a custom signing secret.
# OFFLINE + INSPECT-ONLY (static lint of the YAML).
#
# Exit: 0 = honest+safe release workflow, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'release_workflow_sane: cannot resolve repo root\n' >&2; exit 2; }
WF="$REPO_ROOT/.github/workflows/release.yml"
[ -f "$WF" ] || { printf 'release_workflow_sane: missing %s\n' "$WF" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== release workflow is honest + supply-chain-safe (RP-0011 REL-2) ==\n'

# 1. tag-only trigger
grep -qE "tags:\s*\[\s*'v\*'\s*\]|tags:\s*\[\s*\"v\*\"\s*\]" "$WF" \
	&& ok "triggers only on a v* tag" \
	|| badln "release.yml does not trigger on a 'v*' tag"

# 2. builds via make dist + verifies with the artifact gate
grep -q "make dist" "$WF" \
	&& ok "builds the artifact via 'make dist'" \
	|| badln "release.yml does not build via 'make dist'"
grep -q "release_dist_sane.sh" "$WF" \
	&& ok "verifies the artifact with the release_dist_sane gate before publishing" \
	|| badln "release.yml does not run release_dist_sane before publishing"

# 3. tag == spine version guard
grep -q "internal/spec/version.go" "$WF" && grep -qiE "does not match|!= *\"?\$ver|tag .*version" "$WF" \
	&& ok "guards that the tag matches internal/spec.Version" \
	|| badln "release.yml does not guard tag == spine Version"

# 4. every third-party action pinned to a 40-hex SHA (no @vN / @main / @branch)
unpinned="$(grep -nE '^\s*-?\s*uses:' "$WF" | grep -vE '@[0-9a-f]{40}\b' || true)"
if [ -z "$unpinned" ]; then
	ok "every 'uses:' action is pinned to a full commit SHA"
else
	badln "an action is not SHA-pinned: $(printf '%s' "$unpinned" | tr '\n' ' ')"
fi

# 5. no signing in CI (no signing tool, no custom signing secret — only the built-in github.token)
if grep -qE 'ssh-keygen +-Y +sign|gpg +(-s|--sign|--detach-sign)|minisign +-S|cosign +sign' "$WF"; then
	badln "release.yml runs a signing tool — signing must be LOCAL/maintainer-only (CI holds no key)"
else
	ok "no signing tool runs in CI (the tag + SHA256SUMS are signed locally, ADR-0015)"
fi
# allow ${{ github.token }} / secrets.GITHUB_TOKEN, but flag any OTHER secrets.* (a possible signing key)
othersecret="$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$WF" | grep -vE 'secrets\.GITHUB_TOKEN' || true)"
if [ -z "$othersecret" ]; then
	ok "uses no custom secret (only the built-in token) — no signing material in CI"
else
	badln "release.yml references a non-default secret (possible signing key in CI): $(printf '%s' "$othersecret" | tr '\n' ' ')"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the release workflow builds + verifies + publishes honestly, with no signing material in CI.\n'
	exit 0
fi
printf 'FAIL: the release workflow is not sane.\n' >&2
exit 1
