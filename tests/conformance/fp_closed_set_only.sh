#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fp_closed_set_only.sh — conformance (RP-0015 increment B): a client-fingerprint rotation can only ever move
# WITHIN the closed preset vocabulary — never to a randomiser (principle 1: a unique per-connection JA4 is
# itself a tell), never to an off-vocab token. The twin of rotate_closed_set_only.sh on the fingerprint axis.
# It pins the discipline at every layer: the Go planner + plan Validate reject an off-vocab / randomiser
# target, the actuator feeds no randomiser into the delta, and the vocabulary excludes random/randomized.
#
# Exit: 0 = closed-set-only, 1 = a violation, 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
SPEC="$REPO_ROOT/internal/spec/fp_rotate.go"
PLANNER="$REPO_ROOT/internal/rotate/fingerprint.go"
ACTUATOR="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
VOCAB="$REPO_ROOT/control/vocab.json"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== fingerprint closed-set-only check (RP-0015 B) ==\n'
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq required.\n' >&2; exit 2; }
for f in "$SPEC" "$PLANNER" "$ACTUATOR" "$VOCAB"; do
	[ -f "$f" ] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 2; }
done

# 1) FingerprintPlan.Validate gates the target through the closed vocabulary (ValidClientFingerprint) and
#    forbids To == From — so no plan that acts can carry an off-vocab or randomiser target.
if grep -qE 'ValidClientFingerprint\(p\.To\)' "$SPEC" && grep -qE 'p\.To == p\.From' "$SPEC"; then
	ok "FingerprintPlan.Validate requires a closed-vocab target distinct from the current preset"
else
	badln "FingerprintPlan.Validate does not gate the target through the closed vocab (+ != current)"
fi

# 2) The planner's act guard resolves the target through the closed vocab (no free-form target).
if grep -qE 'ValidClientFingerprint\(in\.Target\)' "$PLANNER"; then
	ok "PlanFingerprint validates the target against the closed vocab before acting"
else
	badln "PlanFingerprint does not validate the target against ValidClientFingerprint"
fi

# 3) The actuator introduces NO randomiser into the preset choice (it only writes the plan's .to).
FPFNS="$(awk '/RP-0015 increment B \(B3\)/{f=1} f{print}' "$ACTUATOR")"
if printf '%s' "$FPFNS" | grep -qE '\$RANDOM|openssl rand|shuf|sort -R'; then
	badln "the fingerprint actuator feeds a randomiser into the preset choice (forbidden)"
else
	ok "the fingerprint actuator introduces no randomiser (it only applies the plan's closed-vocab .to)"
fi

# 4) The vocabulary itself excludes random/randomized (defence in depth with fingerprint_single_source).
if jq -e '(.client_fingerprints | index("random")) == null and (.client_fingerprints | index("randomized")) == null' "$VOCAB" >/dev/null 2>&1; then
	ok "the client-fingerprint vocabulary excludes random/randomized"
else
	badln "the client-fingerprint vocabulary contains a randomiser member"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a fingerprint rotation could leave the closed preset vocabulary.\n' >&2
	exit 1
fi
printf 'PASS: a fingerprint rotation stays within the closed preset vocabulary; no randomiser, no off-vocab target.\n'
exit 0
