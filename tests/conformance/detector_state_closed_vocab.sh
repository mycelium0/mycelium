#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# detector_state_closed_vocab.sh — conformance: the Phase-2 connectivity-state detector schema
# (RP-0010 Plane 2 / ADR-0031 BUILD) keeps its CLOSED vocabulary AND its OPSEC boundary.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The connectivity-state detector classifies a channel into a fine-grained, node-local set
#   {clean / throttled / blocked / shutdown}, with a closed DetectReason cause. That fine state and
#   its cause drive local rotation and MUST NEVER be transmitted: only ConnState's LOSSY projection
#   to the coarse advisory HealthValue (alive/degraded/unknown) may ever leave the node, and then
#   only inside a k-floored, class-aggregate NodeStatusDigest (ADR-0030). If a transmitted artifact
#   embedded the fine ConnState/DetectReason, an observer could read WHICH interference (throttle vs
#   block vs shutdown) succeeded — reopening the topology/operator-graph leak the advisory-only
#   doctrine closes (ADR-0030 / THREAT-MODEL asset #5). This gate keeps that boundary at the
#   conformance layer, so the discipline holds even where `go test` does not run (the offline suite).
#   It is OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. The schema source exists (internal/spec/detector.go).
#   2. ConnState is a CLOSED enum: exactly {clean,throttled,blocked,shutdown} members + an IsValid().
#   3. The AdvisoryHealth() projection exists and is LOSSY: clean -> alive, and throttled/blocked/
#      shutdown ALL collapse to the single value degraded (the privacy contract — impaired states
#      must be indistinguishable after projection).
#   4. OPSEC boundary: NO spec source OTHER THAN detector.go (where they are DEFINED) references the
#      fine ConnState / DetectReason types, and neither is aliased outside detector.go. The scan is a
#      GLOB over every internal/spec/*.go (minus detector.go and *_test.go), so a newly-added wire
#      type (e.g. a digest emitter) is covered by construction — never a hand-maintained file list.
#   5. Phase discipline: the schema carries the inert / never-transmitted marker, and Verdict
#      enforces its clean<->none cross-field contract.
#
# Greps tolerate gofmt whitespace and strip // line-comments for "does this CODE exist" checks, so a
# doc mention cannot satisfy a code assertion and a reformat cannot spuriously fail it.
#
# Exit: 0 = closed vocabulary + OPSEC boundary intact, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'detector_state_closed_vocab: cannot resolve repo root\n' >&2; exit 2; }
DET_GO="$REPO_ROOT/internal/spec/detector.go"
SPEC_DIR="$REPO_ROOT/internal/spec"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# det_code emits detector.go with // line-comments stripped, so a doc mention of a symbol cannot
# satisfy a "this method/const exists in CODE" assertion.
det_code() { sed -e 's://.*$::' "$DET_GO"; }

printf '== connectivity-state detector closed-vocabulary + OPSEC-boundary check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# 1. schema source present
if [ -f "$DET_GO" ]; then
	ok "detector schema present: internal/spec/detector.go"
else
	printf 'FAIL: internal/spec/detector.go is missing (the detector schema is the closed-vocab anchor).\n' >&2
	exit 1
fi

# 2. ConnState is a closed enum (exactly four members + IsValid), whitespace-tolerant
check_member() { # NAME VALUE
	if det_code | grep -qE "^[[:space:]]*$1[[:space:]]+ConnState[[:space:]]*=[[:space:]]*\"$2\"[[:space:]]*$"; then
		ok "ConnState member present: $1"
	else
		badln "ConnState member missing/misformatted: $1 = \"$2\""
	fi
}
check_member ConnStateClean clean
check_member ConnStateThrottled throttled
check_member ConnStateBlocked blocked
check_member ConnStateShutdown shutdown
if det_code | grep -qE 'func \(s ConnState\) IsValid\(\) bool'; then
	ok "ConnState.IsValid present (closed enum)"
else
	badln "ConnState.IsValid() missing"
fi
# Exactly four canonical members + the unknown zero value = 5 declared `ConnStateX ConnState = "..."`.
n_members="$(det_code | grep -cE '^[[:space:]]*ConnState[A-Za-z]+[[:space:]]+ConnState[[:space:]]*=[[:space:]]*"')"
if [ "$n_members" = "5" ]; then
	ok "ConnState has exactly the four canonical members + the unknown zero value (no drift)"
else
	badln "ConnState has $n_members declared values (want 5: unknown + clean/throttled/blocked/shutdown)"
fi

# 3. AdvisoryHealth projection exists and is LOSSY (the privacy contract)
if det_code | grep -qE 'func \(s ConnState\) AdvisoryHealth\(\) HealthValue'; then
	ok "ConnState.AdvisoryHealth() projection present"
else
	badln "ConnState.AdvisoryHealth() projection missing (no safe externalisation path)"
fi
# clean -> alive (widen the window past the doc/case lines)
if det_code | grep -A3 -E '^[[:space:]]*case ConnStateClean:' | grep -qE 'return HealthAlive'; then
	ok "AdvisoryHealth: clean -> alive"
else
	badln "AdvisoryHealth: clean does not project to HealthAlive"
fi
# throttled, blocked, shutdown ALL in ONE case head (any order) -> degraded (indistinguishable)
impaired_head="$(det_code | grep -nE '^[[:space:]]*case ConnState(Throttled|Blocked|Shutdown)(,[[:space:]]*ConnState(Throttled|Blocked|Shutdown)){2}:')"
if [ -n "$impaired_head" ] \
   && printf '%s' "$impaired_head" | grep -q 'ConnStateThrottled' \
   && printf '%s' "$impaired_head" | grep -q 'ConnStateBlocked' \
   && printf '%s' "$impaired_head" | grep -q 'ConnStateShutdown' \
   && det_code | grep -A3 -E '^[[:space:]]*case ConnState(Throttled|Blocked|Shutdown)(,[[:space:]]*ConnState(Throttled|Blocked|Shutdown)){2}:' | grep -qE 'return HealthDegraded'; then
	ok "AdvisoryHealth: throttled/blocked/shutdown all collapse to degraded (privacy contract)"
else
	badln "AdvisoryHealth: impaired states are not collapsed to a single advisory value (the projection leaks which interference succeeded)"
fi

# 4. OPSEC boundary: the fine types are referenced ONLY in detector.go (glob, not a file list)
leaks=""
for src in "$SPEC_DIR"/*.go; do
	[ -f "$src" ] || continue
	case "$src" in
		*/detector.go) continue ;;   # the type is DEFINED here
		*_test.go) continue ;;       # tests legitimately name it
	esac
	if grep -qE '\b(ConnState|DetectReason)\b' "$src"; then
		leaks="$leaks ${src#"$REPO_ROOT"/}"
	fi
done
if [ -z "$leaks" ]; then
	ok "no other spec source references the fine ConnState/DetectReason (only HealthValue is emittable; ADR-0030)"
else
	badln "the fine detector type leaked into a non-detector spec source:$leaks (fine state must never reach a transmitted shape)"
fi
# alias guard: `type X = ConnState` / `= DetectReason` outside detector.go would smuggle the fine type
aliases="$(grep -rnE 'type[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*(ConnState|DetectReason)\b' "$SPEC_DIR" --include='*.go' 2>/dev/null | grep -vE '/detector\.go:|_test\.go:' || true)"
if [ -z "$aliases" ]; then
	ok "the fine types are not aliased outside detector.go (no alias smuggling)"
else
	badln "ConnState/DetectReason is aliased outside detector.go: $aliases"
fi

# 5. Phase discipline + Verdict cross-field contract
if grep -qiE 'never[[:space:]]+transmitted' "$DET_GO"; then
	ok "schema carries the node-local / never-transmitted OPSEC marker"
else
	badln "the never-transmitted OPSEC marker is missing from the detector schema doc"
fi
if det_code | grep -qE 'func \(v \*Verdict\) Validate\(\) error' \
   && grep -qE 'clean channel must carry' "$DET_GO"; then
	ok "Verdict.Validate enforces the clean<->none cross-field contract"
else
	badln "Verdict.Validate / the clean<->none cross-field contract is missing"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the detector vocabulary is closed, the advisory projection is lossy, and no transmitted artifact carries the fine state.\n'
	exit 0
fi
printf 'FAIL: the detector schema/vocabulary drifted open, the projection leaks, or the fine state reached a transmitted shape.\n' >&2
exit 1
