#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# bundle_region_closed_vocab.sh — conformance: the distribution-bundle schema (RP-0007-d) keeps its
# CLOSED vocabulary, and any committed bundle artifact uses only closed-vocab values.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The matured self-replenishing subscription (RP-0007-b) serves a typed Bundle of endpoints. A bundle
#   with an open transport/health vocabulary would let a served endpoint advertise an unaudited family
#   or actuate a health signal — a latent global health/abuse oracle (ADR-0025) and a CONFLICTING_SOURCE
#   _OF_TRUTH against internal/spec. This gate keeps the bundle schema closed and HEALTH ADVISORY-ONLY
#   (Phase 1: must be "unknown") at the conformance layer, so the discipline holds even where `go test`
#   does not run (the offline suite). It is OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. The schema source exists (internal/spec/bundle.go).
#   2. HealthValue is a CLOSED enum: the three members + an IsValid().
#   3. Endpoint.TransportClass is the CLOSED TransportClass type, not a raw string.
#   4. The Phase-1 invariant is enforced in Validate(): a non-"unknown" health is rejected.
#   5. Every committed bundle JSON artifact (gates-first: none yet) uses only closed-vocab
#      transport_class + health values.
#
# Exit: 0 = closed vocabulary intact, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'bundle_region_closed_vocab: cannot resolve repo root\n' >&2; exit 2; }
BUNDLE_GO="$REPO_ROOT/internal/spec/bundle.go"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== bundle closed-vocabulary check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# 1. schema source present
if [ -f "$BUNDLE_GO" ]; then
	ok "bundle schema present: internal/spec/bundle.go"
else
	printf 'FAIL: internal/spec/bundle.go is missing (the bundle schema is the closed-vocab anchor).\n' >&2
	exit 1
fi

# 2. HealthValue is a closed enum (three members + IsValid)
for m in 'HealthUnknown HealthValue = "unknown"' 'HealthAlive HealthValue = "alive"' 'HealthDegraded HealthValue = "degraded"'; do
	if grep -qF "$m" "$BUNDLE_GO"; then ok "HealthValue member present: ${m%% *}"; else badln "HealthValue member missing: $m"; fi
done
if grep -qE 'func \(h HealthValue\) IsValid\(\) bool' "$BUNDLE_GO"; then ok "HealthValue.IsValid present (closed enum)"; else badln "HealthValue.IsValid() missing"; fi

# 3. Endpoint.TransportClass uses the closed TransportClass type (not a raw string)
if grep -qE '^[[:space:]]*TransportClass[[:space:]]+TransportClass([[:space:]]|$)' "$BUNDLE_GO"; then
	ok "Endpoint.TransportClass uses the closed TransportClass type"
else
	badln "Endpoint.TransportClass is not the closed TransportClass type (open vocab leak)"
fi

# 4. Phase-1 health-unknown invariant enforced in Validate
if grep -qE 'Health != HealthUnknown' "$BUNDLE_GO"; then
	ok "Phase-1 invariant enforced: health must be \"unknown\" (advisory-only, ADR-0025)"
else
	badln "Phase-1 health-unknown invariant missing from Validate (health could actuate trust)"
fi

# 5. committed bundle JSON artifacts (if any) use only closed-vocab values
VTC='["reality-tcp","quic-udp","shadowsocks-tcp","shadowtls-tcp","trojan-tls","amneziawg-udp","xhttp-tls","ws-tls"]'
VH='["unknown","alive","degraded"]'
fixtures="$(grep -rlE '"endpoints"[[:space:]]*:' "$REPO_ROOT/control/testdata" "$REPO_ROOT/tests" 2>/dev/null | grep -E '\.json$' || true)"
if [ -z "$fixtures" ]; then
	ok "no committed bundle fixtures yet (gates-first; enforces when they land)"
elif ! command -v jq >/dev/null 2>&1; then
	badln "bundle fixtures present but jq unavailable to validate their vocabulary"
else
	for fx in $fixtures; do
		rel="${fx#"$REPO_ROOT"/}"
		bad_tc="$(jq --argjson v "$VTC" '[.endpoints[]?.transport_class // empty | select(($v | index(.)) == null)] | length' "$fx" 2>/dev/null || echo ERR)"
		bad_h="$(jq --argjson v "$VH"  '[.endpoints[]?.health // empty         | select(($v | index(.)) == null)] | length' "$fx" 2>/dev/null || echo ERR)"
		if [ "$bad_tc" = "0" ]; then ok "$rel: transport_class values closed"; else badln "$rel: $bad_tc transport_class value(s) outside the closed vocab"; fi
		if [ "$bad_h" = "0" ]; then ok "$rel: health values closed"; else badln "$rel: $bad_h health value(s) outside the closed vocab"; fi
	done
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the distribution-bundle vocabulary is closed and health stays advisory-only.\n'
	exit 0
fi
printf 'FAIL: the bundle schema/vocabulary drifted open (or a fixture used an unaudited value).\n' >&2
exit 1
