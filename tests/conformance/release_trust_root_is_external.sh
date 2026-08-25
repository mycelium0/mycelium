#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# release_trust_root_is_external.sh — conformance: a release cannot attest to itself.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Audit-0015, and it was found by an adversarial pass after two audits missed it.
#
#   `make dist` is `git archive`, so every tracked file ships inside the tarball. The day the maintainer's
#   signing key is published — the single act that unblocks a release — `allowed_signers` becomes one of
#   those files. The documented recipe then read BOTH the signer identity and the key out of the extracted
#   archive, checked the archive's signature against the archive's own key, and printed:
#
#       verify-release: OK — integrity AND authenticity verified          (rc=0)
#
#   over a tarball an attacker built. They supply the key, the signature and the checksums together;
#   nothing in the chain is anchored anywhere they do not control.
#
#   The one anchor a downloaded artifact cannot forge is the signed TAG, which lives upstream. It was
#   reachable only inside a clone, every documented invocation passed a download directory, and the miss
#   was a `warn` — while the verdict line, computed from the presence of --allowed-signers alone, still
#   said authenticity was verified.
#
# WHAT IT CHECKS, by BUILDING THE ATTACK
#   1. A hostile release — attacker's tarball, attacker's SHA256SUMS, attacker's key, attacker's signature,
#      the key shipped INSIDE — is REFUSED. Not warned about: refused, non-zero.
#   2. A key from outside the artifact is still accepted, so row 1 is not passing by refusing everything.
#   3. Asking for --tag where it cannot be checked is a REFUSAL, not a warning. That check is the only
#      unforgeable one; skipping it on request is how the verdict came to outrun its evidence.
#   4. Without --tag the verdict does NOT claim authenticity, and names what it did not check.
#
# OFFLINE. No root, no network, no node. Needs ssh-keygen and a sha256 tool; SKIPs loudly without them.
# Exit: 0 = the trust root is outside the artifact; 1 = an artifact can vouch for itself.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
VERIFY="$REPO_ROOT/scripts/verify-release.sh"
[ -f "$VERIFY" ] || { printf 'release_trust_root_is_external: missing %s\n' "$VERIFY" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== a release cannot attest to itself ==\n\n'

command -v ssh-keygen >/dev/null 2>&1 || { printf '  SKIP  no ssh-keygen; the attack cannot be built here.\nPASS (skipped)\n'; exit 0; }
if command -v sha256sum >/dev/null 2>&1; then SUM=sha256sum
elif command -v shasum >/dev/null 2>&1; then SUM="shasum -a 256"
else printf '  SKIP  no sha256 tool.\nPASS (skipped)\n'; exit 0; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/myc.trust.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

# --- the attacker's release: every input is theirs, and the key rides inside ------------------------
mkdir -p "$W/evil"
printf 'THIS TARBALL WAS NOT BUILT BY THE MAINTAINER\n' > "$W/evil/mycelium-9.9.9.tar.gz"
ssh-keygen -q -t ed25519 -N '' -f "$W/evilkey" >/dev/null 2>&1
printf 'maintainer@mycelium0 %s\n' "$(cut -d' ' -f1,2 "$W/evilkey.pub")" > "$W/evil/allowed_signers"
( cd "$W/evil" && $SUM mycelium-9.9.9.tar.gz allowed_signers > SHA256SUMS )
( cd "$W/evil" && ssh-keygen -Y sign -q -f "$W/evilkey" -n file SHA256SUMS >/dev/null 2>&1 )

# The fixture is only worth what it contains: the attack must be INTERNALLY consistent, or row 1 would
# pass because the forgery was simply broken.
if ! ( cd "$W/evil" && $SUM -c SHA256SUMS >/dev/null 2>&1 ); then
	printf 'FAIL: the hostile fixture does not even match its own checksums — this gate would prove nothing.\n' >&2
	exit 2
fi
[ -s "$W/evil/SHA256SUMS.sig" ] || { printf 'FAIL: the hostile fixture is unsigned; nothing to refuse.\n' >&2; exit 2; }
printf '  ..    hostile release built: own tarball, own key shipped inside, own signature over own checksums\n'

# ---------------------------------------------------------------------------------------------------
# 1. THE ATTACK IS REFUSED.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the documented recipe, run against a hostile artifact --\n'
out="$(cd "$W/evil" && bash "$VERIFY" . --allowed-signers ./allowed_signers \
	--signer "$(awk 'NF{print $1; exit}' "$W/evil/allowed_signers")" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
	badln "the verifier ACCEPTED a release that carried its own trust root: '$(tr -d '\n' <<<"$out" | tail -c 200)'. An attacker who rebuilds the tarball supplies the key, the signature and the checksums together, and the operator is told authenticity was verified."
else
	grep -qi 'inside the artifact\|attesting to itself' <<<"$out" \
		&& ok "refused, and the reason names the circularity" \
		|| badln "refused (rc=$rc) but for an unstated reason: $(tr -d '\n' <<<"$out" | tail -c 200). An operator who cannot tell WHY will work around it."
fi

# ---------------------------------------------------------------------------------------------------
# 2. A LEGITIMATE, EXTERNAL KEY STILL WORKS — or row 1 proves only that everything is refused.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and a key from outside the artifact is still accepted --\n'
mkdir -p "$W/good"
printf 'REAL ARTIFACT\n' > "$W/good/mycelium-1.0.0.tar.gz"
ssh-keygen -q -t ed25519 -N '' -f "$W/goodkey" >/dev/null 2>&1
printf 'maintainer@mycelium0 %s\n' "$(cut -d' ' -f1,2 "$W/goodkey.pub")" > "$W/outside_allowed_signers"
( cd "$W/good" && $SUM mycelium-1.0.0.tar.gz > SHA256SUMS )
( cd "$W/good" && ssh-keygen -Y sign -q -f "$W/goodkey" -n file SHA256SUMS >/dev/null 2>&1 )
out2="$(bash "$VERIFY" "$W/good" --allowed-signers "$W/outside_allowed_signers" --signer maintainer@mycelium0 2>&1)"; rc2=$?
[ "$rc2" -eq 0 ] \
	&& ok "an external key verifies the signature (rc=0)" \
	|| badln "a legitimate external key was refused (rc=$rc2): $(tr -d '\n' <<<"$out2" | tail -c 200). Row 1 would then be passing because the tool refuses everything."

# ---------------------------------------------------------------------------------------------------
# 3. THE ONE UNFORGEABLE CHECK IS NOT SKIPPABLE ON REQUEST.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and --tag is not a suggestion --\n'
out3="$(bash "$VERIFY" "$W/good" --allowed-signers "$W/outside_allowed_signers" --signer maintainer@mycelium0 --tag v1.0.0 2>&1)"; rc3=$?
[ "$rc3" -ne 0 ] \
	&& ok "--tag outside a clone is a refusal, not a warning" \
	|| badln "--tag was requested, could not be checked, and the run still succeeded: $(tr -d '\n' <<<"$out3" | tail -c 220). The tag is the only anchor the downloaded artifact cannot forge; skipping it while claiming authenticity is exactly how the verdict stopped meaning what it says."

# ---------------------------------------------------------------------------------------------------
# 4. THE VERDICT NAMES WHAT IT DID NOT CHECK.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the verdict says what it covers --\n'
last="$(printf '%s\n' "$out2" | tail -1)"
case "$last" in
	*"integrity AND authenticity verified"*)
		badln "without --tag the verdict still claims full authenticity: '$last'. A signature over SHA256SUMS proves who produced these bytes, not that upstream published them as a release." ;;
	*"SIGNATURE ONLY"*)
		ok "the unanchored case is reported as SIGNATURE ONLY" ;;
	*)
		badln "the verdict is neither of the two documented forms: '$last'" ;;
esac
grep -qi 'TAG was NOT checked\|tag was not checked' <<<"$out2" \
	&& ok "and it names the check it skipped" \
	|| badln "the output never says the tag went unchecked, so a reader cannot tell which half of the claim they got"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: an artifact can vouch for itself.\n' >&2
	exit 1
fi
printf 'PASS: the trust root must come from outside the artifact, and the verdict states its scope.\n'
exit 0
