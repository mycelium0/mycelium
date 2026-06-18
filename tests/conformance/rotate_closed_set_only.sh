#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotate_closed_set_only.sh — conformance: auto-rotation can only ever move WITHIN the closed
# transport set; it can never grow the protocol list (RP-0012 AC-5).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   Phase 2 is adaptivity, NOT new protocols (ADR-0010 closed set; RP-0010 scope discipline). The
#   rotation schema enforces this BY CONSTRUCTION: there is no "add-transport" action, and a rotation
#   candidate whose proto is not in the closed TransportRegistry fails Validate. This gate pins both
#   so a future edit cannot quietly let rotation introduce a new shape. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS (internal/spec/rotate.go)
#   1. The schema source exists.
#   2. RotationAction has NO add/new/grow/expand member (no action means "introduce a transport").
#   3. RotationCandidate.Validate is anchored to the closed registry: it resolves the proto via
#      ClassForProto and rejects an unknown one.
#
# Exit: 0 = closed-set-only, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotate_closed_set_only: cannot resolve repo root\n' >&2; exit 2; }
ROT_GO="$REPO_ROOT/internal/spec/rotate.go"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# code-only view (strip // line comments) so a comment cannot satisfy or trip a code assertion
code() { sed -e 's://.*$::' "$ROT_GO"; }

printf '== rotation closed-set-only check (RP-0012 AC-5) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

if [ -f "$ROT_GO" ]; then
	ok "rotation schema present: internal/spec/rotate.go"
else
	printf 'FAIL: internal/spec/rotate.go is missing (the rotation schema is the AC-5 anchor).\n' >&2
	exit 1
fi

# 2. No RotationAction member whose value means "introduce/grow a transport" (widened synonym set).
addish="$(code | grep -E 'RotationAction[[:space:]]*=[[:space:]]*"' | grep -iE '"(add|new|grow|expand|create|install|enable|provision|register|attach|introduce|spawn|onboard)[^"]*"' || true)"
if [ -z "$addish" ]; then
	ok "RotationAction has no add/grow-like member (rotation cannot introduce a transport)"
else
	badln "RotationAction has an add/grow-like member: $(printf '%s' "$addish" | tr '\n' ' ')"
fi

# 3. RotationCandidate.Validate binds the ClassForProto ok-result to a real name and rejects on its
#    negation — name-agnostic, so a `cls, _ := ClassForProto(...)` discard or an unrelated stray `!ok`
#    cannot false-pass. (The Go test TestRotationCandidateValidate `proto="vmess"` proves the actual
#    rejection where a toolchain is present; this is the offline structural anchor.)
ok_name="$(code | grep -E '=[[:space:]]*ClassForProto\(' | sed -nE 's/.*,[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:?=[[:space:]]*ClassForProto\(.*/\1/p' | head -1)"
if [ -z "$ok_name" ] || [ "$ok_name" = "_" ]; then
	badln "RotationCandidate.Validate discards the ClassForProto ok-result (cannot reject an unknown proto)"
elif code | grep -qE "[!]${ok_name}([^A-Za-z0-9_]|\$)"; then
	ok "RotationCandidate.Validate binds the ClassForProto ok-result ('$ok_name') and rejects on !$ok_name"
else
	badln "the ClassForProto ok-result ('$ok_name') is never negated to reject an unknown proto"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: rotation stays within the closed transport set; no action or candidate can grow the protocol list (AC-5).\n'
	exit 0
fi
printf 'FAIL: the rotation schema could introduce a transport outside the closed set.\n' >&2
exit 1
