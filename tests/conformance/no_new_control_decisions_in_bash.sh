#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_new_control_decisions_in_bash.sh — conformance: scripts/node-bootstrap.sh stays ORCHESTRATION-ONLY.
# RP-0009 cut the 2130-line control-plane god-object into an orchestration entrypoint + focused
# control/lib/nb_*.sh modules; this gate operationalises RP-0008/RP-0009's "no new control-decisions-in-bash"
# rule so the entrypoint cannot silently re-grow a render/validate/policy/merge control-decision function.
#
# WHAT COUNTS AS ORCHESTRATION (the allowlist of function names the entrypoint may DEFINE):
#   * the tiny helpers: die, log, warn, have, run, need_root, usage, main
#   * the flow dispatchers: flow_*  (bootstrap/update/ack/revoke/disable-two-hop/rotate — they SEQUENCE steps)
#   * the post-apply verifiers: verify_*  (verify the deploy succeeded; no rendering/policy)
# ANYTHING ELSE defined in node-bootstrap.sh is a control-logic or rendering function that belongs in a
# control/lib/nb_*.sh module (or, ultimately, the Go spine — RP-0008), NOT the entrypoint.
#
# CHECKS
#   1. Every function DEFINED in scripts/node-bootstrap.sh matches the orchestration allowlist.
#   2. The entrypoint still SOURCES its libs (the `for _lib in nb_* ...` loop is present) — the
#      decomposition is intact, not re-inlined.
#   3. A denylist of known control-logic function names is NOT defined in the entrypoint (they live in
#      libs) — a direct regression guard against moving render/validate/policy back in.
#
# Exit: 0 = the entrypoint is orchestration-only and sources its libs; 1 = a non-orchestration function
#       was defined in the entrypoint, or the sourcing loop is gone; 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
[ -f "$NB" ] || { printf 'FAIL: node-bootstrap.sh not found: %s\n' "$NB" >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== no new control-decisions in node-bootstrap.sh (orchestration-only) ==\n'
printf 'script: scripts/node-bootstrap.sh (%s lines)\n' "$(wc -l < "$NB" | tr -d '[:space:]')"

# is_orchestration NAME -> 0 if NAME is an allowlisted orchestration function, 1 otherwise.
is_orchestration() {
	case "$1" in
		die|log|warn|have|run|need_root|usage|main) return 0 ;;
		flow_*|verify_*)                            return 0 ;;
		*)                                          return 1 ;;
	esac
}

# 1. Every top-level function defined in the entrypoint must be orchestration. Match both `name() {` and
#    `name()` opener forms at column 0 (top-level definitions only).
offenders=""
while IFS= read -r fn; do
	[ -n "$fn" ] || continue
	is_orchestration "$fn" || offenders="$offenders $fn"
done < <(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$NB" | sed 's/()//')

if [ -n "$offenders" ]; then
	badln "node-bootstrap.sh DEFINES non-orchestration function(s):$offenders"
	badln "  -> a render/validate/policy/merge function belongs in a control/lib/nb_*.sh module (or the Go spine, RP-0008), not the entrypoint."
else
	okln "every function defined in node-bootstrap.sh is orchestration (helpers / flow_* / verify_*)"
fi

# 2. The decomposition is intact: the entrypoint still sources its nb_* libs.
if grep -qE '^for _lib in nb_[a-z_].*; do' "$NB" && grep -qE 'NB_LIB_DIR="\$ARTIFACT_ROOT/control/lib"' "$NB"; then
	okln "the entrypoint sources control/lib/nb_*.sh from ARTIFACT_ROOT (decomposition intact, not re-inlined)"
else
	badln "the nb_* lib sourcing loop (from ARTIFACT_ROOT) is missing — the entrypoint must source its modules"
fi

# 3. Direct regression guard: known control-logic functions must NOT be (re)defined in the entrypoint.
DENY="write_params render_candidate render_serve_bundle render_awg0 validate_config promote_config rollback_config assert_two_hop_shape compute_client_allowed seed_operator_overrides merge_operator_overrides myc_fetch_artifacts setup_amneziawg setup_observability apply_rotation_to_params persist_rotation_to_overlay revert_rotation_overlay record_rotation_rollback rotate_apply_live rotate_abort_revert rotate_enable_loop rotate_disable_loop"
reinlined=""
for d in $DENY; do
	grep -qE "^${d}\(\)" "$NB" && reinlined="$reinlined $d"
done
if [ -n "$reinlined" ]; then
	badln "control-logic function(s) re-defined in the entrypoint (must stay in control/lib/nb_*.sh):$reinlined"
else
	okln "no known control-logic function is defined in the entrypoint (they live in control/lib/nb_*.sh)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: node-bootstrap.sh is not orchestration-only — a control decision leaked back into the entrypoint.\n' >&2
	exit 1
fi
printf 'PASS: node-bootstrap.sh is orchestration-only; control logic lives in the sourced modules (RP-0009).\n'
exit 0
