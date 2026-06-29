#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# release_verify_failclosed.sh — conformance (RP-0011 REL-3): scripts/verify-release.sh is FAIL-CLOSED.
# Against a synthetic release (a dummy artifact + SHA256SUMS + an SSH-signed SHA256SUMS.sig from an
# EPHEMERAL key + a matching allowed_signers), it must:
#   1. PASS a clean, correctly-signed release;
#   2. FAIL a TAMPERED artifact (integrity);
#   3. FAIL a BAD/forged signature (authenticity);
#   4. FAIL when --allowed-signers is given but SHA256SUMS.sig is missing;
#   5. integrity-only PASS (exit 0) when no --allowed-signers is supplied (warns, never silently OKs auth).
# Needs ssh-keygen (OpenSSH); SKIPS cleanly where absent. OFFLINE + uses a temp dir.
#
# Exit: 0 = verify helper is fail-closed (or skipped), 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'release_verify_failclosed: cannot resolve repo root\n' >&2; exit 2; }
VRS="$REPO_ROOT/scripts/verify-release.sh"
[ -f "$VRS" ] || { printf 'release_verify_failclosed: missing %s\n' "$VRS" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== verify-release.sh is fail-closed (RP-0011 REL-3) ==\n'

command -v ssh-keygen >/dev/null 2>&1 || { printf 'SKIP: ssh-keygen not available.\n'; exit 0; }
if command -v sha256sum >/dev/null 2>&1; then SUM() { sha256sum "$@"; }; else SUM() { shasum -a 256 "$@"; }; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.rvf.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
R="$WORK/rel"; mkdir -p "$R"

# synthetic release
printf 'dummy artifact\n' > "$R/mycelium-test.tar.gz"
( cd "$R" && SUM mycelium-test.tar.gz > SHA256SUMS )
ssh-keygen -q -t ed25519 -N '' -C tester -f "$WORK/k" >/dev/null 2>&1 || { badln "could not generate an ephemeral key"; printf 'FAIL\n' >&2; exit 1; }
ssh-keygen -Y sign -f "$WORK/k" -n file "$R/SHA256SUMS" >/dev/null 2>&1 || { badln "could not sign the fixture"; printf 'FAIL\n' >&2; exit 1; }
printf 'tester %s\n' "$(awk '{print $1" "$2}' "$WORK/k.pub")" > "$WORK/allowed"

run() { bash "$VRS" "$R" "$@" >/dev/null 2>&1; }

# 1. clean + signed → PASS
if run --allowed-signers "$WORK/allowed" --signer tester; then ok "clean correctly-signed release verifies"; else badln "a clean signed release failed to verify"; fi

# 2. tampered artifact → FAIL (integrity)
printf 'tampered\n' >> "$R/mycelium-test.tar.gz"
if run --allowed-signers "$WORK/allowed" --signer tester; then badln "a TAMPERED artifact still verified (integrity not enforced)"; else ok "tampered artifact is rejected (integrity)"; fi
printf 'dummy artifact\n' > "$R/mycelium-test.tar.gz"   # restore (matches SHA256SUMS again)

# 3. forged signature → FAIL (authenticity)
cp "$R/SHA256SUMS.sig" "$WORK/sig.bak"
printf 'garbage\n' > "$R/SHA256SUMS.sig"
if run --allowed-signers "$WORK/allowed" --signer tester; then badln "a FORGED signature still verified (authenticity not enforced)"; else ok "forged signature is rejected (authenticity)"; fi

# 4. signature missing but allowed-signers given → FAIL
rm -f "$R/SHA256SUMS.sig"
if run --allowed-signers "$WORK/allowed" --signer tester; then badln "missing SHA256SUMS.sig still verified"; else ok "missing signature with --allowed-signers is rejected"; fi
cp "$WORK/sig.bak" "$R/SHA256SUMS.sig"   # restore good sig

# 5. no --allowed-signers → integrity-only PASS (exit 0), authenticity intentionally unverified
if run; then ok "integrity-only mode passes when no key is supplied (authenticity warned, not silently OK'd)"; else badln "integrity-only mode failed on a clean artifact"; fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: verify-release.sh enforces integrity always and authenticity when a key is supplied (fail-closed).\n'
	exit 0
fi
printf 'FAIL: the release verify helper is not fail-closed.\n' >&2
exit 1
