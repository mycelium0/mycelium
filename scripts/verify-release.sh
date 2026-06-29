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

cd "$DIR" || fail "cannot enter directory: $DIR"

# 1. integrity (always)
[ -f SHA256SUMS ] || fail "SHA256SUMS not found in $(pwd)"
sumc SHA256SUMS >/dev/null 2>&1 || fail "an artifact does NOT match SHA256SUMS (integrity)"
echo "ok    integrity: artifacts match SHA256SUMS"

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

echo "verify-release: OK"
