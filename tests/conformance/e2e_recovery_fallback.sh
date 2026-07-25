#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# e2e_recovery_fallback.sh — conformance: the RP-0013 (Phase-3) end-to-end client-recovery contract is
# CODIFIED and enforceable — a served bundle must always retain a live fallback on an INDEPENDENT
# transport family, so a single-family block never removes the client's last path. Offline, inspect-only,
# fail-closed.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE (RP-0013 AC-2 "always a live fallback"; threat SINGLE_POINT_OF_BLOCK at the CLIENT)
#   Phase 2 makes a NODE self-drive; Phase 3 proves the loop closes at the CLIENT. The precondition for
#   end-to-end recovery is that the SERVED subscription a client imports spans >= 2 INDEPENDENT transport
#   families (TransportClass) — REALITY Vision/gRPC/XHTTP are ONE family (shared handshake/donor/keypair,
#   ADR-0020 §5), so a bundle of only those is a single point of block no matter how many endpoints it
#   lists. Older gates check the CAPABILITY (transport_family_independence) and the class-MAPPING
#   (sub_channel_not_single_point); this gate pins that the SERVE-TIME invariant on the rendered ARTIFACT
#   is CODIFIED in the Go spine (Bundle.IndependentFallbackOK) and proven meaningful (the single-family
#   bundle is rejected), so it cannot silently regress.
#
#   OFFLINE + INSPECT-ONLY: it reasons about committed Go sources, never a live render.
#
# CHECKS
#   1. The transport registry provides >= 2 INDEPENDENT families (distinct TransportClass) — the capability
#      that makes an independent fallback possible at all.
#   2. RenderBundle stamps the family (TransportClass) onto every served Endpoint — so the invariant is
#      checkable on the artifact a client actually imports, not just the template.
#   3. The e2e contract is CODIFIED: internal/spec/e2e_recovery.go defines Bundle.DistinctClasses +
#      Bundle.IndependentFallbackOK, and the count is over >= 2 distinct BLOCK-independence families
#      (Bundle.DistinctBlockFamilies), not raw classes — plus the blockFamily fold itself must fold the
#      own-cert-TLS classes together. Audit-0008 S1-3: two distinct CLASSES are not an independent fallback
#      for one another when one block takes both (they share the node's one tls_sni + one uTLS preset).
#   4. The invariant is proven MEANINGFUL (not vacuous): the test suite asserts a single-family
#      (REALITY-only) bundle FAILS the contract.
#
# bash 3.2-safe: no mapfile, no associative arrays.
#
# Exit: 0 = the e2e recovery fallback contract is codified + enforceable, 1 = a precondition or the
#       codified invariant is missing/weakened, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

REG="$REPO_ROOT/internal/spec/transport.go"
RENDER="$REPO_ROOT/internal/spec/bundle_render.go"
INV="$REPO_ROOT/internal/spec/e2e_recovery.go"
INV_TEST="$REPO_ROOT/internal/spec/e2e_recovery_test.go"

for f in "$REG" "$RENDER" "$INV" "$INV_TEST"; do
	[ -f "$f" ] || { printf 'FAIL: required source not found: %s\n' "${f#"$REPO_ROOT"/}" >&2; exit 2; }
done

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== e2e recovery fallback contract (RP-0013 AC-2) ==\n'

# 1. >= 2 independent families available in the registry.
fam_count="$(grep -oE 'Class: *TransportClass[A-Za-z0-9]+' "$REG" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
if [ "${fam_count:-0}" -ge 2 ]; then
	okln "registry provides $fam_count independent transport families (>= 2 — an independent fallback is possible)"
else
	badln "registry provides only ${fam_count:-0} transport family — < 2, no independent fallback is possible"
fi

# 2. RenderBundle stamps the family onto every served Endpoint.
if grep -Eq 'TransportClass: *d\.Class' "$RENDER"; then
	okln "RenderBundle stamps TransportClass onto each served Endpoint (the invariant is checkable on the artifact)"
else
	badln "RenderBundle does not stamp TransportClass per Endpoint — the served family cannot be inspected"
fi

# 3. The contract is codified in the Go spine.
if grep -Eq 'func \(b Bundle\) IndependentFallbackOK\(\) bool' "$INV" \
	&& grep -Eq 'func \(b Bundle\) DistinctClasses\(\) \[\]TransportClass' "$INV"; then
	okln "Bundle.IndependentFallbackOK + Bundle.DistinctClasses are codified (internal/spec/e2e_recovery.go)"
else
	badln "the e2e fallback invariant (Bundle.IndependentFallbackOK / DistinctClasses) is not codified"
fi
# 3b. It must actually require >= 2 distinct BLOCK-independence families. Audit-0008 S1-3 strengthened the
# count from raw TransportClass to the coarser BLOCK family: two distinct classes are NOT an independent
# fallback for one another when a SINGLE block takes both (every own-cert TLS class shares the node's one
# tls_sni + the one uTLS preset). Counting raw classes here would re-weaken the contract.
if grep -Eq 'len\(b\.DistinctBlockFamilies\(\)\) >= 2' "$INV"; then
	okln "IndependentFallbackOK requires >= 2 distinct BLOCK families (a single-block bundle is a single point of block)"
else
	badln "IndependentFallbackOK does not require >= 2 distinct BLOCK families — the contract is weakened"
fi
# 3c. The block-family fold must EXIST and must fold the own-cert-TLS classes together (the S1-3 fix). A fold
# that mapped every class to itself would silently restore the old, weaker class-counting contract.
if grep -Eq 'func blockFamily\(c TransportClass\) TransportClass' "$INV" \
	&& grep -Eq 'TransportClassXHTTPTLS, TransportClassWSTLS, TransportClassQUICUDP, TransportClassTrojanTLS' "$INV"; then
	okln "the block-family fold folds the own-cert-TLS classes (shared SNI + ClientHello preset) into one family"
else
	badln "the block-family fold is missing or does not fold the own-cert-TLS classes — SNI/preset-sharing families would falsely certify a fallback"
fi

# 4. The invariant is proven meaningful: a single-family bundle must be rejected by the tests.
if grep -Eq 'IndependentFallbackOK' "$INV_TEST" \
	&& grep -Eiq 'single.?family|REALITY-only|single point of block' "$INV_TEST"; then
	okln "the suite proves a single-family (REALITY-only) bundle FAILS the contract (not vacuous)"
else
	badln "no test proves a single-family bundle is rejected — the invariant could be vacuously true"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the RP-0013 e2e recovery fallback contract is not fully codified/enforceable.\n' >&2
	printf '      A served subscription must span >= 2 independent transport families so a single-family\n' >&2
	printf '      block never removes the client last path (AC-2).\n' >&2
	exit 1
fi
printf 'PASS: the e2e recovery fallback contract is codified + enforceable (served bundle keeps an\n'
printf '      independent fallback; a single-family bundle is rejected — RP-0013 AC-2).\n'
exit 0
