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
#      only the built-in github.token, never a custom signing secret;
#   6. publish NOTES THAT EXIST — the workflow's own extractor, run here over the real CHANGELOG for the
#      current spec.Version, must produce a non-empty block that is not its own fallback stub;
#   7. keep the SIGNED bytes and the PUBLISHED bytes the same object — the maintainer signs a LOCALLY
#      built dist/SHA256SUMS while the workflow publishes CI's copy, so the signature only means anything
#      if the two files are identical, which rests on the artifact being reproducible ACROSS hosts.
# OFFLINE + INSPECT-ONLY (static lint of the YAML), except check 6, which EXECUTES the workflow's own
# extraction command rather than reimplementing it — a reimplementation can agree with itself while
# disagreeing with what CI actually runs.
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

# 3b. THE AUTHENTICITY ROOT IS ACTUALLY CHECKED (Audit-0011 #14).
#
# This workflow's header calls the signed tag "the authenticity root", and `gh release create
# --verify-tag` reads as though it verifies that. It does not: gh defines --verify-tag as aborting if the
# tag does not exist ON THE REMOTE — existence, not signature. So a plain `git tag vX.Y.Z && git push
# --tags` produced a complete, normal-looking release with assets, notes and a version guard all green,
# and nothing in the lane could tell. Not theoretical: docs/RELEASING.md records that the documented
# `user.signingkey` once pointed at a nonexistent file, so local signing had already failed silently.
#
# `git verify-tag` is the only command here that reads the signature. It must run BEFORE publish, and it
# must resolve against the repository's committed allowed_signers rather than whatever the runner happens
# to have configured.
if grep -qE '^[[:space:]]*(-|run:|[[:space:]])*.*git verify-tag' "$WF"; then
	ok "the lane runs \`git verify-tag\` on the pushed tag (gh's --verify-tag checks EXISTENCE, not signature)"
	grep -q 'allowedSignersFile' "$WF" \
		&& ok "and resolves it against the committed allowed_signers, not the runner's ambient config" \
		|| badln "git verify-tag runs without setting gpg.ssh.allowedSignersFile. On a GitHub runner there is no ambient allowed-signers file, so the verification resolves against nothing and its result is meaningless."
	# It must precede the publish, or it verifies something already released.
	# Ignore COMMENT lines on both sides. The first draft compared line numbers without doing so and
	# reported the publish as preceding the check — because the rationale comment above the new step
	# mentions `gh release create` by name. A gate that reads prose as code is the defect it is here to
	# catch, in miniature.
	nocomment() { grep -vE '^[[:space:]]*#' "$WF" | grep -n "$1" | head -1 | cut -d: -f1; }
	vline="$(nocomment 'git verify-tag')"
	pline="$(nocomment 'gh release create')"
	if [ -n "$vline" ] && [ -n "$pline" ] && [ "$vline" -lt "$pline" ]; then
		ok "and it runs BEFORE \`gh release create\` (line $vline < $pline)"
	else
		badln "git verify-tag appears at line ${vline:-?} but the publish is at line ${pline:-?} — verifying after publishing is not a gate, it is a post-mortem. A failed check would leave a signed tag with assets already attached."
	fi
else
	badln "release.yml never runs \`git verify-tag\`. Its own header calls the signed tag the authenticity root, and \`gh release create --verify-tag\` does NOT check a signature — gh defines it as aborting only if the tag does not exist on the remote. Without this, an unsigned \`git tag\` publishes a complete, normal-looking release."
fi

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

# --- 6. THE NOTES THE RELEASE WOULD ACTUALLY PUBLISH ------------------------------------------------
# Lifted verbatim from the workflow rather than rewritten: this gate must fail when CI's extraction
# produces nothing, not when a private copy of the logic does. The fallback exists so a release never
# publishes an empty body — but silently shipping "See CHANGELOG.md." in place of the notes is the
# failure, not the safety net.
ver="$(grep -E '^[[:space:]]*const[[:space:]]+Version' "$REPO_ROOT/internal/spec/version.go" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
awkcmd="$(grep -m1 -E "^[[:space:]]*awk -v v=" "$WF" | sed -E 's/^[[:space:]]*//; s/ > RELEASE_NOTES\.md$//')"
if [ -z "$ver" ]; then
	badln "could not read spec.Version — cannot check the notes the release would publish"
elif [ -z "$awkcmd" ]; then
	badln "could not find the release-notes extraction command in $WF — re-confirm this gate against the new shape"
else
	# The version is INLINED into the lifted command by the expansion below, so no `ver` needs to exist at
	# eval time — the `ver="$ver"` prefix this used to carry was seen only by the forked process and could
	# never have affected the expansion (shellcheck SC2097/SC2098, and it was right).
	notes="$(cd "$REPO_ROOT" && eval "${awkcmd/\$ver/$ver}" 2>/dev/null || true)"
	body="$(printf '%s\n' "$notes" | grep -vE '^## \[' | tr -d '[:space:]')"
	if [ -z "$body" ]; then
		badln "the workflow's own extractor finds NO notes for spec.Version=$ver in CHANGELOG.md, so the release would publish its fallback stub ('See CHANGELOG.md.') as the entire body. Add a '## [$ver]' section with content, or bump the version to one that has one."
	else
		lines="$(printf '%s\n' "$notes" | grep -c . || true)"
		ok "the release would publish real notes for $ver ($lines lines from CHANGELOG.md, extracted by the workflow's own command)"
	fi
fi

# --- 7. THE SIGNED BYTES ARE THE PUBLISHED BYTES ----------------------------------------------------
# docs/RELEASING.md has the maintainer sign dist/SHA256SUMS on their own machine; this workflow publishes
# the copy CI built. Nothing reconciles them — they are simply expected to be identical, which is true
# only while `make dist` is reproducible across MACHINES (release_dist_sane check 6, added after a
# host-gzip dependency made them differ in practice). This check pins the three links in that chain that
# live here: same producer, same filename published as is signed, same filename the verifier reads.
sums_built=0; sums_pub=0
grep -qE '^[[:space:]]*run:[[:space:]]*make dist' "$WF" && sums_built=1
grep -qE 'dist/SHA256SUMS' "$WF" && sums_pub=1
if [ "$sums_built" -eq 1 ] && [ "$sums_pub" -eq 1 ]; then
	ok "the published SHA256SUMS has the same PRODUCER as the one the maintainer builds (byte equality is asserted by the operator at RELEASING.md step 5, not observable here)"
else
	badln "the workflow does not both build via 'make dist' and publish dist/SHA256SUMS (build=$sums_built publish=$sums_pub). If CI computes the checksums by some other means, the maintainer's locally signed SHA256SUMS is a signature over a different file and verify-release.sh fails closed for every downloader."
fi
for f in docs/RELEASING.md scripts/verify-release.sh; do
	[ -f "$REPO_ROOT/$f" ] || { badln "$f is missing — the sign/verify chain cannot be checked"; continue; }
	grep -q 'SHA256SUMS' "$REPO_ROOT/$f" \
		&& ok "$f operates on SHA256SUMS (the same object the workflow publishes)" \
		|| badln "$f does not name SHA256SUMS — the signed payload and the published payload have drifted apart"
done
# -F, because the dot is a WILDCARD: `grep 'SHA256SUMS.sig'` matched the prose line "SHA256SUMS signature
# did NOT verify" and reported success for a file that never mentioned the detached signature at all.
grep -qF 'SHA256SUMS.sig' "$REPO_ROOT/scripts/verify-release.sh" 2>/dev/null \
	&& ok "verify-release.sh checks the detached signature over that exact file" \
	|| badln "verify-release.sh does not verify SHA256SUMS.sig — integrity would be checked but authenticity never would"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the release workflow builds + verifies + publishes honestly, with no signing material in CI.\n'
	exit 0
fi
printf 'FAIL: the release workflow is not sane.\n' >&2
exit 1
