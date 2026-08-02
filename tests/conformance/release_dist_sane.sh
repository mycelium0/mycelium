#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# release_dist_sane.sh — conformance (RP-0011 REL-1): the release artifact (`make dist`) is HONEST and
# SAFE. The tarball is the AGPL Corresponding Source, named by the single-source spine version, built
# reproducibly, and carrying ONLY tracked source (never per-node identity/secrets/rendered configs).
# It asserts:
#   1. `make dist` builds a tarball + SHA256SUMS, and SHA256SUMS verifies;
#   6. the artifact is reproducible ACROSS HOSTS, not merely twice on this one — verified by rebuilding
#      with a deliberately different gzip first on PATH and requiring the digest not to move.
#   2. the tarball prefix dir is mycelium-<X.Y.Z> where X.Y.Z == internal/spec.Version == the CHANGELOG
#      top heading (the artifact name can never drift from the spine version);
#   3. it CONTAINS the source needed to bootstrap+build a node (LICENSE, go.mod, Makefile,
#      scripts/node-bootstrap.sh, cmd/myceliumctl, internal/spec, control/lib);
#   4. it is SECRET-FREE — no params.json / identity*.json / *.pem / *.key / rendered server|config.json
#      (supply-chain: a published artifact must never carry node PII or secrets);
#   5. it is DETERMINISTIC — two builds at the same ref are byte-identical (reproducible release).
# Needs a git work tree (git archive); SKIPS cleanly where there is none (e.g. a tar-shipped checkout).
# OFFLINE + builds into a temp dir (never litters the repo).
#
# Exit: 0 = artifact honest+safe+reproducible (or skipped), 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'release_dist_sane: cannot resolve repo root\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== release artifact is honest, secret-free + reproducible (RP-0011 REL-1) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v make >/dev/null 2>&1 || { printf 'SKIP: make not available.\n'; exit 0; }
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	printf 'SKIP: not a git work tree (git archive unavailable) — the CI/checkout lane runs this gate.\n'
	exit 0
fi

# portable sha256 (Linux sha256sum / macOS shasum -a 256)
if command -v sha256sum >/dev/null 2>&1; then SUM() { sha256sum "$@"; }; else SUM() { shasum -a 256 "$@"; }; fi

VERSION_GO="$REPO_ROOT/internal/spec/version.go"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
ver="$(grep -E '^[[:space:]]*const[[:space:]]+Version' "$VERSION_GO" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$ver" ] || { badln "cannot read spine Version"; printf 'FAIL\n' >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.rds.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
tarball="$WORK/d1/mycelium-$ver.tar.gz"

# 1. build + checksum verify
if make -C "$REPO_ROOT" dist DIST_DIR="$WORK/d1" >/dev/null 2>"$WORK/err1"; then
	if [ -f "$tarball" ] && [ -f "$WORK/d1/SHA256SUMS" ]; then
		ok "make dist produced the tarball + SHA256SUMS"
	else
		badln "make dist did not produce mycelium-$ver.tar.gz + SHA256SUMS"
	fi
else
	badln "make dist failed: $(tr '\n' ' ' <"$WORK/err1")"
fi
if [ -f "$tarball" ]; then
	( cd "$WORK/d1" && SUM -c SHA256SUMS >/dev/null 2>&1 ) \
		&& ok "SHA256SUMS verifies against the tarball" \
		|| badln "SHA256SUMS does not verify"
fi

# 2. version-named prefix == spine Version == CHANGELOG top
if [ -f "$tarball" ]; then
	top_dir="$(tar tzf "$tarball" 2>/dev/null | head -1 | sed 's#/.*##')"
	[ "$top_dir" = "mycelium-$ver" ] \
		&& ok "tarball prefix is mycelium-$ver (matches spine Version)" \
		|| badln "tarball prefix '$top_dir' != mycelium-$ver"
	cl_top="$(grep -E '^##[[:space:]]*\[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" 2>/dev/null | head -1 | sed -E 's/^##[[:space:]]*\[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')"
	[ "$cl_top" = "$ver" ] \
		&& ok "CHANGELOG top [$cl_top] == spine Version" \
		|| badln "CHANGELOG top [$cl_top] != spine Version $ver"
fi

# 3. contains the source needed to bootstrap + build
if [ -f "$tarball" ]; then
	listing="$(tar tzf "$tarball" 2>/dev/null)"
	miss=""
	for f in LICENSE go.mod Makefile scripts/node-bootstrap.sh scripts/fungi cmd/myceliumctl/main.go internal/spec/version.go control/lib/nb_install.sh control/engines.manifest.json; do
		printf '%s\n' "$listing" | grep -qx "mycelium-$ver/$f" || miss="$miss $f"
	done
	[ -z "$miss" ] && ok "tarball carries the bootstrap+build source (LICENSE, go.mod, Makefile, node-bootstrap, cmd, internal/spec, control/lib)" \
		|| badln "tarball is missing:$miss"
fi

# 4. secret-free (defence-in-depth: git archive ships only tracked files, but PIN it)
if [ -f "$tarball" ]; then
	leak="$(tar tzf "$tarball" 2>/dev/null | grep -E '(^|/)(params|identity|identities)\.json$|\.pem$|\.key$|(^|/)(server|config)\.json$|config\.(candidate|staged|lastgood)\.json$' || true)"
	[ -z "$leak" ] && ok "tarball is secret-free (no identity/params/keys/rendered configs)" \
		|| badln "tarball carries a secret/identity/rendered-config artifact: $(printf '%s' "$leak" | tr '\n' ' ')"
fi

# 5. deterministic (reproducible release)
if [ -f "$tarball" ]; then
	make -C "$REPO_ROOT" dist DIST_DIR="$WORK/d2" >/dev/null 2>&1
	a="$(SUM "$tarball" | awk '{print $1}')"
	b="$(SUM "$WORK/d2/mycelium-$ver.tar.gz" 2>/dev/null | awk '{print $1}')"
	[ -n "$a" ] && [ "$a" = "$b" ] \
		&& ok "two builds are byte-identical on this host (deterministic)" \
		|| badln "make dist is NOT deterministic (sha $a != $b)"
fi

# 6. REPRODUCIBLE ACROSS HOSTS, which check 5 cannot see.
#
# Check 5 builds twice on ONE machine, so anything that depends on the HOST's tooling rather than on the
# repository is invisible to it — it agrees with itself by construction. That blind spot was real: the
# target piped `git archive --format=tar` into the host `gzip -n -9`, and `-n` only drops the name and
# mtime, it does not make two different gzip implementations agree. Measured at 71fe0f6, the tar stream was
# identical on both hosts (35be7103…) while Apple gzip 457.140.3 produced b74dbe18… and GNU gzip 1.14
# produced ac83a4eb…. docs/RELEASING.md has the maintainer sign a LOCALLY built SHA256SUMS while
# release.yml publishes CI's, so from a macOS workstation the signed sums and the published sums
# disagreed — and verify-release.sh fails closed on exactly that, for every downloader.
#
# We cannot run a second OS here, so we test the PROPERTY instead: the artifact must not depend on the
# host's gzip at all. Put a deliberately different gzip first on PATH and rebuild. Piped through the host
# tool, the digest moves; compressed by git's own zlib (`--format=tar.gz`), it does not.
if [ -f "$tarball" ] && command -v gzip >/dev/null 2>&1; then
	realgzip="$(command -v gzip)"
	mkdir -p "$WORK/sabotage"
	# STRIP any level the caller passes before forcing our own. `gzip -1 -n -9` takes the LAST level, so a
	# stub that merely prepends -1 is cancelled by the Makefile's own -9 and the sabotage silently does
	# nothing — which is how the first draft of this check passed against the piped form it exists to catch.
	{
		echo '#!/bin/sh'
		echo 'args=""'
		echo 'for a in "$@"; do case "$a" in -[1-9]) ;; *) args="$args $a" ;; esac; done'
		echo "exec $realgzip -1 \$args"
	} >"$WORK/sabotage/gzip"
	chmod +x "$WORK/sabotage/gzip"
	( PATH="$WORK/sabotage:$PATH"; make -C "$REPO_ROOT" dist DIST_DIR="$WORK/d3" >/dev/null 2>&1 )
	c="$(SUM "$WORK/d3/mycelium-$ver.tar.gz" 2>/dev/null | awk '{print $1}')"
	if [ -z "$c" ]; then
		badln "the sabotaged-gzip rebuild produced no tarball — cannot judge host independence; re-confirm this check"
	elif [ "$a" = "$c" ]; then
		ok "the artifact does not depend on the host's gzip (compression is git's own — reproducible across platforms)"
	else
		badln "make dist produces a DIFFERENT tarball when the host's gzip changes ($a vs $c). It is therefore not reproducible across machines, and docs/RELEASING.md signs a locally built SHA256SUMS while release.yml publishes CI's — so the signed sums and the published sums disagree and verify-release.sh fails closed for every downloader. Compress with \`git archive --format=tar.gz\` (git's own zlib) rather than piping into the host gzip."
	fi
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the release artifact is the honest Corresponding Source — version-named, secret-free, reproducible.\n'
	exit 0
fi
printf 'FAIL: the release artifact is not sane.\n' >&2
exit 1
