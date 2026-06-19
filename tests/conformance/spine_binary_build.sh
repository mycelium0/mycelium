#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# spine_binary_build.sh — conformance: the Go control-plane binary (myceliumctl-go, cmd/myceliumctl) that
# node-bootstrap's install_spine compiles onto every node (RP-0008 P3 chunk 1) BUILDS, INSTALLS (-o into a
# dest), and is INVOCABLE, using the exact production build env. It also proves the two invariants the
# node-side idempotency rests on: the source rev flows source -> binary via -ldflags -X spec.SourceRev (so
# a node never mis-skips a rebuild and serves a stale binary), and the module stays dependency-free (so the
# offline GOPROXY=off build is real). It asserts NO rendering behaviour — none exists yet in chunk 1; the
# binary is installed but inert (MYCTL stays the shell tool).
#
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-GO: like bundle_go_roundtrip.sh, the offline suite runs where no Go toolchain exists (the
# maintainer's macOS host; the jq-only CI lane) — there this gate SKIPs (exit 0 with a note). Where Go IS
# present (a node with go1.x, or a CI lane that installs Go) it runs the full build + invoke + rev-stamp
# round-trip. The build is fully offline (the module has zero external deps), so GOPROXY/GOSUMDB are off.
#
# Exit: 0 = the spine binary builds + installs + runs and the invariants hold (or skipped, no Go),
#       1 = the build/invoke/rev-stamp/offline invariant failed, 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

printf '== spine binary build check (cmd/myceliumctl -> myceliumctl-go, RP-0008 P3) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# Resolve a Go toolchain: PATH first, then the well-known node install locations. Absent => SKIP.
GO=""
if command -v go >/dev/null 2>&1; then
	GO="$(command -v go)"
else
	for cand in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do
		[ -x "$cand" ] && { GO="$cand"; break; }
	done
fi
if [ -z "$GO" ]; then
	printf '\nSKIP: no Go toolchain present (PATH or the known node locations) — the spine build gate needs\n'
	printf '      `go build ./cmd/myceliumctl`. This is NOT a failure (jq-only host/CI lane); the on-node\n'
	printf '      install_spine build is exercised where Go is installed, and go vet/test cover the package.\n'
	printf 'PASS (skipped): spine binary build not exercised here.\n'
	exit 0
fi
printf 'go: %s\n' "$GO"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.spine.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# A distinctive probe rev that cannot occur incidentally, stamped through the SAME -ldflags the production
# install_spine uses, so a green build here proves the production invocation works byte-for-byte.
PROBE="GATEPROBE0SPINE01"
BIN="$WORK/bin/myceliumctl-go"

# 1. BUILD + INSTALL using the exact production env (offline, static, trimpath, rev-stamped). The build
#    cache is WORK-local so the gate touches nothing global.
if ( cd "$REPO_ROOT" \
	&& GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 GOCACHE="$WORK/gocache" \
	"$GO" build -trimpath \
		-ldflags "-buildid= -X github.com/mycelium0/mycelium/internal/spec.SourceRev=$PROBE" \
		-o "$BIN" ./cmd/myceliumctl ) >"$WORK/build.out" 2>&1; then
	okln "myceliumctl-go builds + installs offline with the production env (GOPROXY=off, CGO=0, trimpath)"
else
	badln "spine build FAILED: $(tr -d '\n' < "$WORK/build.out" | cut -c1-220)"
fi

# 2. INVOCABILITY (proof-of-life): `version` exits 0 and keeps the `myceliumctl ` prefix downstream relies on.
if [ -x "$BIN" ] && "$BIN" version >"$WORK/v.out" 2>&1; then
	if grep -q '^myceliumctl ' "$WORK/v.out"; then
		okln "the built binary runs: $(tr -d '\n' < "$WORK/v.out" | cut -c1-80)"
	else
		badln "myceliumctl-go version output lost the 'myceliumctl ' prefix: $(tr -d '\n' < "$WORK/v.out" | cut -c1-80)"
	fi
else
	badln "myceliumctl-go is not invocable (version did not run)"
fi

# 3. REV-STAMP ROUND-TRIP: the -ldflags rev must surface in `version`. This is the contract the node-side
#    idempotency keys on — if it breaks, a node would rebuild forever or skip wrongly and serve a stale binary.
if grep -qF "$PROBE" "$WORK/v.out"; then
	okln "the build-stamped source rev surfaces in 'version' (idempotency key is real)"
else
	badln "the -ldflags -X spec.SourceRev rev did NOT reach 'version' output — the node idempotency key would be broken"
fi

# 4. OFFLINE-INVARIANT: the module must stay dependency-free, or the GOPROXY=off build silently breaks.
if [ ! -e "$REPO_ROOT/go.sum" ] && ! grep -q '^require' "$REPO_ROOT/go.mod" 2>/dev/null; then
	okln "the module has no external deps (no go.sum, no require in go.mod) — the offline build is real"
else
	badln "an external dependency crept in (go.sum or a require block exists) — GOPROXY=off offline build no longer holds"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the Go spine binary does not build/install/run as the node-bootstrap install_spine expects.\n' >&2
	exit 1
fi
printf 'PASS: cmd/myceliumctl builds offline into a rev-stamped, invocable binary; the spine is installable.\n'
exit 0
