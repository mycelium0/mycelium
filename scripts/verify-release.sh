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

# THE TRUST ROOT MAY NOT COME FROM THE THING BEING VERIFIED.
#
# `make dist` is `git archive`, so every tracked file ships inside the tarball — and the day the
# maintainer's key is published, `allowed_signers` becomes one of them. An operator who then follows the
# documented recipe reads the signer identity and the key OUT OF THE ARTIFACT, checks the artifact's own
# signature against the artifact's own key, and is told "authenticity verified". An attacker who rebuilds
# the tarball supplies all three: their allowed_signers, their signature, their SHA256SUMS. Nothing in
# that chain is anchored anywhere the attacker does not control.
#
# So: refuse a key that resolves INSIDE the directory under verification. The file must have reached the
# operator by some path other than the download — that is the whole content of "out-of-band", and it was
# stated in the header while the recipe did the opposite.
if [ -n "${ALLOWED:-}" ]; then
	_dir_abs="$(cd "$DIR" 2>/dev/null && pwd -P)" || fail "cannot enter directory: $DIR"
	_key_abs="$(cd "$(dirname "$ALLOWED")" 2>/dev/null && pwd -P)/$(basename "$ALLOWED")" \
		|| fail "cannot resolve --allowed-signers: $ALLOWED"
	case "$_key_abs" in
		"$_dir_abs"/*|"$_dir_abs")
			fail "--allowed-signers ($ALLOWED) resolves INSIDE the artifact being verified ($_dir_abs). That is not a verification: the archive would be attesting to itself, and anyone who rebuilt it supplies the key, the signature and the checksums together. Fetch the maintainer's allowed_signers by a route independent of this download and pass THAT path." ;;
	esac
fi

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
		# NOT A WARNING. --tag is the ONE anchor in this tool that an artifact cannot forge: the tag lives
		# in the upstream repository, not in the download. Skipping it while still printing "authenticity
		# verified" is how the verdict came to mean less than it says. If the caller asked for it, either
		# it is checked or the tool refuses.
		TAG_UNCHECKED=1
		fail "--tag $TAG was requested but could not be checked here: the tag signature lives in the repository, and $(pwd -P) is not a clone (or no --allowed-signers was given). This is the only check in this tool that the downloaded artifact cannot forge, so it is not skippable on request. Verify inside a clone: git -c gpg.ssh.allowedSignersFile=FILE -c gpg.format=ssh verify-tag $TAG"
	fi
else
	TAG_UNCHECKED=1
fi

# SAY WHICH MODE PASSED. This was a bare "OK", identical in integrity-only mode and in the fully verified
# one — same last line, same exit 0 — so a wrapper, a CI step, or an operator skimming the tail could not
# tell "the bytes match the checksums shipped beside them" from "the maintainer signed this". That
# distinction is the entire point of the tool, and it matters most right now: the maintainer's key is not
# published, so integrity-only is the only mode a downloader can currently run.
if [ -n "$ALLOWED" ] && [ "${TAG_UNCHECKED:-0}" -eq 0 ]; then
	echo "verify-release: OK — integrity AND authenticity verified, anchored on the signed tag $TAG"
elif [ -n "$ALLOWED" ]; then
	# SAY WHAT WAS NOT CHECKED. The signature over SHA256SUMS proves the holder of a key in your
	# allowed_signers produced these bytes. It does NOT tie them to any release the upstream repository
	# admits to — only the tag does that. Naming the gap is the difference between a verdict and a mood.
	echo "verify-release: the signed TAG was not checked, so nothing here ties these bytes to a release the"
	echo "verify-release: upstream repository published. Re-run inside a clone with --tag to close that."
	# The VERDICT is the last line, always — a reader, a wrapper and a gate all take the tail.
	echo "verify-release: OK (SIGNATURE ONLY) — SHA256SUMS is signed by '$SIGNER' and the artifacts match it; the TAG was NOT checked."
else
	echo "verify-release: OK (INTEGRITY ONLY) — the artifacts match the checksums that came with them."
	echo "verify-release: authenticity was NOT checked: nothing here proves who produced them. Supply"
	echo "verify-release: --allowed-signers with the maintainer's key to verify that (docs/RELEASING.md)."
fi
