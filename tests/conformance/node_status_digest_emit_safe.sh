#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_status_digest_emit_safe.sh — conformance (RP-0010 C5 / ADR-0030): the advisory-emit
# NodeStatusDigest — the ONLY connectivity-state artifact a node may emit — is k-floored, class-
# aggregate, and carries NO per-node row / stable correlator / identity-or-location field BY
# CONSTRUCTION, and its builder OMITS sub-floor cells (never zeroes them).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The rejected per-node design (a stable node_ref + a per-node transport-health vector) lets an
#   observer reconstruct the network map (ADR-0030, THREAT-MODEL asset #5). The digest is built
#   inside-out from the privacy invariants to forbid that: per-CLASS health only, k-floored with
#   omit-not-zero, no node identifier. This gate pins those at the conformance layer so the discipline
#   holds even where `go test` does not run (the offline suite), and so a "make it convenient" refactor
#   that adds a node_ref / count / endpoint cannot land silently. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. The schema (internal/spec/network.go: NodeStatusDigest + ClassHealth + Validate) and the inert
#      builder (internal/spec/node_status_digest.go: BuildNodeStatusDigest) exist.
#   2. The ClassHealth + NodeStatusDigest struct fields carry NO per-node/identity/location field
#      (node_ref/node_id/host/ip/asn/sni/geo/country/region-precise/endpoint/sibling/member/
#      transport_ref/peer) — the type makes a per-node row unrepresentable.
#   3. The builder enforces k-FLOOR with OMIT-NOT-ZERO (a `len < k` cell is skipped) and emits NOTHING
#      below the floor (returns ErrAggregationFloor) — never a zeroed/imputed sub-floor cell.
#   4. The builder forces Region = RegionUnspecified (REGION_COARSENESS until the vocab-hardening ADR).
#   5. If Go is present, the digest + builder tests pass.
#   The fine-state OPSEC boundary (no ConnState/DetectReason in the digest) is pinned by
#   detector_state_closed_vocab (it scans every internal/spec source); not re-checked here.
#
# Exit: 0 = emit-safe (k-floored, class-aggregate, no per-node row), 1 = a violation, 2 = usage/env err.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_status_digest_emit_safe: cannot resolve repo root\n' >&2; exit 2; }
NET="$REPO_ROOT/internal/spec/network.go"
BLD="$REPO_ROOT/internal/spec/node_status_digest.go"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }
strip() { sed -e 's://.*$::' "$1"; }

printf '== advisory-emit NodeStatusDigest safety check (RP-0010 C5 / ADR-0030) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

[ -f "$NET" ] || { printf 'FAIL: internal/spec/network.go missing\n' >&2; exit 2; }
[ -f "$BLD" ] || { printf 'FAIL: internal/spec/node_status_digest.go (the inert builder) missing\n' >&2; exit 1; }
ok "schema + builder sources present"

strip "$NET" | grep -qE 'type NodeStatusDigest struct' && ok "NodeStatusDigest type present" || badln "NodeStatusDigest type missing"
strip "$NET" | grep -qE 'type ClassHealth struct'      && ok "ClassHealth type present"      || badln "ClassHealth type missing"
strip "$NET" | grep -qE 'func \(d \*NodeStatusDigest\) Validate\(\) error' && ok "NodeStatusDigest.Validate present" || badln "Validate missing"
strip "$BLD" | grep -qE 'func BuildNodeStatusDigest\(' && ok "BuildNodeStatusDigest present (the inert constructor)" || badln "BuildNodeStatusDigest missing"

# 2. NO per-node / identity / location field in the two emit struct bodies.
bodies="$(strip "$NET" | awk '/type (NodeStatusDigest|ClassHealth) struct/{f=1} f{print} /^}/{if(f){f=0; print "---"}}')"
forbidden='node_ref|node_id|nodeid|noderef|\bnode\b|host|hostname|\bip\b|addr|endpoint|sni|country|\bgeo\b|asn|sibling|member|transport_ref|peer|latency'
hit="$(printf '%s\n' "$bodies" | grep -iE "\"($forbidden)\"|[[:space:]]($forbidden)[[:space:]]" || true)"
if [ -z "$hit" ]; then
	ok "NodeStatusDigest/ClassHealth carry no per-node/identity/location field (per-node row unrepresentable)"
else
	badln "an emit struct grew a per-node/identity/location field: $(printf '%s' "$hit" | tr '\n' '|')"
fi

# 3. k-floor with omit-not-zero + emit-nothing-below-floor.
if strip "$BLD" | grep -qE 'len\(hs\)[[:space:]]*<[[:space:]]*k' && strip "$BLD" | grep -qE 'continue'; then
	ok "builder OMITS a sub-floor class (len < k -> continue; omit-not-zero)"
else
	badln "builder does not omit sub-floor classes (the k-floor / omit-not-zero invariant is missing)"
fi
if strip "$BLD" | grep -qE 'len\(cells\)[[:space:]]*==[[:space:]]*0' && strip "$BLD" | grep -qE 'ErrAggregationFloor'; then
	ok "builder emits NOTHING below the floor (returns ErrAggregationFloor, never a sub-floor digest)"
else
	badln "builder does not fail-closed when no class meets the floor"
fi

# 4. region forced unspecified.
if strip "$BLD" | grep -qE 'Region:[[:space:]]*RegionUnspecified'; then
	ok "builder forces Region = RegionUnspecified (REGION_COARSENESS)"
else
	badln "builder does not force RegionUnspecified (a precise region re-opens the enumeration surface)"
fi

# 5. Go test half (skip-if-no-Go).
if command -v go >/dev/null 2>&1; then
	if ( cd "$REPO_ROOT" && go test ./internal/spec -run 'NodeStatusDigest|BuildNodeStatus' >/dev/null 2>&1 ); then
		ok "go test ./internal/spec -run 'NodeStatusDigest|BuildNodeStatus' passes"
	else
		badln "the digest / builder Go tests FAILED"
	fi
else
	printf 'SKIP (go test half): no Go toolchain — the structural greps above ran; on a Go host the tests run too.\n'
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the advisory-emit digest is k-floored, class-aggregate, and carries no per-node row — emit-safe by construction (ADR-0030).\n'
	exit 0
fi
printf 'FAIL: the advisory-emit digest lost a privacy invariant (per-node field / sub-floor leak / precise region) — see above.\n' >&2
exit 1
