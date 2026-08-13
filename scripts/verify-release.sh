#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# verify-release.sh — verify a downloaded Mycelium release (RP-0011 REL-3), fail-closed.
#
#   1. INTEGRITY  — every artifact matches SHA256SUMS (always checked).
#   2. AUTHENTICITY — SHA256SUMS carries a valid SSH signature (SHA256SUMS.sig) from a key in your
#      out-of-band allowed_signers file. Checked when you pass --allowed-signers; the same key/scheme
#      the node updater uses (verify_signed_ref, ADR-0015).
#   3. TAG (optional) — if run inside a clone and given --tag, the git tag's SSH signature verifies.
#
# Usage:
#   scripts/verify-release.sh [DIR] --allowed-signers FILE --signer ID [--tag vX.Y.Z]
#   (DIR defaults to the current directory and must contain the tarball + SHA256SUMS [+ .sig])
#
# Without --allowed-signers it checks INTEGRITY only and warns that authenticity is unverified.
# Exit: 0 = verified, non-zero = any check failed (fail-closed).

set -euo pipefail

DIR="."; TAG=""; ALLOWED=""; SIGNER=""
usage() { sed -n '8,22p' "$0"; }
while [ $# -gt 0 ]; do
	case "$1" in
		--allowed-signers) ALLOWED="${2:?--allowed-signers needs a value}"; shift 2 ;;
		--signer)          SIGNER="${2:?--signer needs a value}"; shift 2 ;;
		--tag)             TAG="${2:?--tag needs a value}"; shift 2 ;;
		--dir)             DIR="${2:?--dir needs a value}"; shift 2 ;;
		-h|--help)         usage; exit 0 ;;
		-*)                echo "verify-release: unknown option: $1" >&2; exit 2 ;;
		*)                 DIR="$1"; shift ;;
	esac
done

if command -v sha256sum >/dev/null 2>&1; then sumc() { sha256sum -c "$@"; }
else sumc() { shasum -a 256 -c "$@"; }; fi

fail() { echo "verify-release: FAIL: $*" >&2; exit 1; }

# RESOLVE THE KEY PATH BEFORE MOVING (Audit-0012 B5). This script cd's into the directory it is
# checking, and the allowed-signers check happens after — so a RELATIVE --allowed-signers resolved
# against $DIR rather than against the caller's cwd, and the file was "not found" for a maintainer or a
# downloader who had done everything right. Both documents prescribe exactly that shape
# (docs/RELEASING.md step 7, QUICKSTART step 1). The obvious recovery is to drop --allowed-signers,
# which falls back to the one mode this project says cannot tell a substituted release from a genuine
# one — so the failure pushes the user toward the weaker check.
#
# Measured: DIR=rel with a relative key path -> "FAIL: --allowed-signers file not found", rc=1; the same
# call with an absolute path -> "integrity AND authenticity verified", rc=0.
case "${ALLOWED:-}" in
	""|/*) : ;;                       # unset, or already absolute
	*) ALLOWED="$PWD/$ALLOWED" ;;
esac
cd "$DIR" || fail "cannot enter directory: $DIR"

# 1. integrity (always)
#
# COUNT THE LINES BEFORE TRUSTING THE CHECK. `-c` over a checksum file with no well-formed lines is not a
# failure to every implementation: Apple's /sbin/sha256sum exits 0 on an empty file and exits 0 with only a
# warning on a malformed one, and that warning is discarded by the redirect below. So on stock macOS an
# empty or truncated SHA256SUMS produced "ok integrity: artifacts match SHA256SUMS" and "verify-release:
# OK", exit 0 — a verifier whose entire contract is to fail closed, reporting success for a download it
# had not checked at all. GNU coreutils gets this right ("no properly formatted checksum lines found",
# exit 1), which is why it survived: it is invisible on Linux and on CI.
#
# No attacker is needed. `curl -f` rejects only HTTP >= 400, so a captive portal or a proxy answering 200
# with an HTML body is enough, and QUICKSTART recommends exactly this integrity-only mode while a
# signature is pending. Requiring at least one well-formed line makes the check independent of which
# implementation is installed, and the count is printed so a human can see WHAT was verified.
[ -f SHA256SUMS ] || fail "SHA256SUMS not found in $(pwd)"
sums_n="$(grep -cE '^[0-9a-fA-F]{64}[[:space:]]+[*]?[^[:space:]]' SHA256SUMS 2>/dev/null || true)"
case "${sums_n:-0}" in
	0) fail "SHA256SUMS contains no well-formed checksum lines — the download is empty, truncated, or is not a checksum file at all (a proxy or captive portal answering 200 with an HTML body looks exactly like this). Nothing was verified." ;;
esac
sumc SHA256SUMS >/dev/null 2>&1 || fail "an artifact does NOT match SHA256SUMS (integrity)"
echo "ok    integrity: $sums_n artifact(s) match SHA256SUMS"

# 2. authenticity (when an allowed-signers key is supplied)
if [ -n "$ALLOWED" ]; then
	[ -f "$ALLOWED" ]       || fail "--allowed-signers file not found: $ALLOWED"
	[ -f SHA256SUMS.sig ]   || fail "SHA256SUMS.sig not found — cannot verify authenticity"
	[ -n "$SIGNER" ]        || fail "--signer ID is required (must match the allowed_signers principal)"
	command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required to verify the signature"
	ssh-keygen -Y verify -f "$ALLOWED" -I "$SIGNER" -n file -s SHA256SUMS.sig < SHA256SUMS >/dev/null 2>&1 \
		|| fail "SHA256SUMS signature did NOT verify against $ALLOWED (authenticity)"
	echo "ok    authenticity: SHA256SUMS signed by '$SIGNER'"
else
	echo "warn  no --allowed-signers supplied: INTEGRITY checked, AUTHENTICITY not verified."
	echo "warn  supply the maintainer key (see docs/RELEASING.md) to verify the signature."
fi

# 3. tag signature (optional, inside a clone)
if [ -n "$TAG" ]; then
	if [ -n "$ALLOWED" ] && command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
		git -c gpg.ssh.allowedSignersFile="$ALLOWED" -c gpg.format=ssh verify-tag "$TAG" >/dev/null 2>&1 \
			&& echo "ok    git tag $TAG signature verifies" \
			|| fail "git tag $TAG signature did NOT verify"
	else
		echo "warn  --tag given but not verifiable here (need a clone + --allowed-signers)"
	fi
fi

# SAY WHICH MODE PASSED. This was a bare "OK", identical in integrity-only mode and in the fully verified
# one — same last line, same exit 0 — so a wrapper, a CI step, or an operator skimming the tail could not
# tell "the bytes match the checksums shipped beside them" from "the maintainer signed this". That
# distinction is the entire point of the tool, and it matters most right now: the maintainer's key is not
# published, so integrity-only is the only mode a downloader can currently run.
if [ -n "$ALLOWED" ]; then
	echo "verify-release: OK — integrity AND authenticity verified"
else
	echo "verify-release: OK (INTEGRITY ONLY) — the artifacts match the checksums that came with them."
	echo "verify-release: authenticity was NOT checked: nothing here proves who produced them. Supply"
	echo "verify-release: --allowed-signers with the maintainer's key to verify that (docs/RELEASING.md)."
fi
