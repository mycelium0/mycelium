#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotate_dry_run_default.sh — conformance: the --rotate executor seam is DRY-RUN ONLY and unattended
# rotation is not yet wired (RP-0012 C4b).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   C4b lands the executor SEAM — plan -> params-delta -> render -> `sing-box check` — but stops short
#   of touching live state: it never promotes, and nothing schedules it. The live promote/verify/
#   rollback loop and the unattended timer are C4c, behind the RP-0012 §6 go/no-go. This gate pins the
#   dry-run boundary so a future edit cannot quietly let the seam promote, or auto-arm it on a timer,
#   before the go/no-go is taken. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. The executor lib exists: control/lib/nb_rotate_apply.sh, defining flow_rotate + apply_rotation_to_params.
#   2. flow_rotate / apply_rotation_to_params NEVER call promote_config (the dry-run guarantee — it must
#      not promote a candidate to live).
#   3. flow_rotate REUSES the existing node path (render_candidate + validate_config), not a new
#      render/validate of its own (RP-0008 single render/validate authority).
#   4. The entrypoint wires the seam: it sources nb_rotate_apply and dispatches `rotate) flow_rotate`.
#   5. Nothing AUTO-ARMS rotation: no systemd timer / cron in scripts or libs schedules --rotate
#      (the unattended loop is C4c, gated).
#
# Exit: 0 = dry-run-only and not auto-armed, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotate_dry_run_default: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# code-only view (strip # line comments) so a comment cannot satisfy or trip a code assertion.
libcode() { sed -e 's/#.*$//' "$LIB"; }

printf '== rotation dry-run-only + not-auto-armed check (RP-0012 C4b) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# 1. The executor lib exists and defines the two functions.
if [ -f "$LIB" ]; then
	ok "executor lib present: control/lib/nb_rotate_apply.sh"
else
	printf 'FAIL: control/lib/nb_rotate_apply.sh is missing (the dry-run executor seam).\n' >&2
	exit 1
fi
for fn in flow_rotate apply_rotation_to_params; do
	if grep -qE "^${fn}\(\)" "$LIB"; then
		ok "defines ${fn}()"
	else
		badln "control/lib/nb_rotate_apply.sh does not define ${fn}()"
	fi
done

# 2. Dry-run guarantee: the executor never promotes a candidate to live.
if libcode | grep -qE '\bpromote_config\b'; then
	badln "nb_rotate_apply.sh references promote_config — the C4b seam must be dry-run only (never promote; live promote is C4c)"
else
	ok "nb_rotate_apply.sh never calls promote_config (dry-run only)"
fi

# 3. Reuse the existing render + validate path (no parallel render/validate of its own).
for reuse in render_candidate validate_config; do
	if libcode | grep -qE "\b${reuse}\b"; then
		ok "flow_rotate reuses ${reuse} (the existing node path)"
	else
		badln "flow_rotate does not call ${reuse} — it must reuse the existing render/validate path, not reimplement it"
	fi
done

# 4. The entrypoint wires the seam: sources the lib and dispatches the mode.
if grep -qE '^for _lib in nb_[a-z_].*\bnb_rotate_apply\b.*; do' "$NB"; then
	ok "node-bootstrap.sh sources nb_rotate_apply in the lib loop"
else
	badln "node-bootstrap.sh does not source nb_rotate_apply (the seam is unreachable)"
fi
if grep -qE '^[[:space:]]*rotate\)[[:space:]]*flow_rotate' "$NB"; then
	ok "node-bootstrap.sh dispatches 'rotate) flow_rotate'"
else
	badln "node-bootstrap.sh has no 'rotate) flow_rotate' dispatch (the seam is unreachable)"
fi

# 5. Nothing auto-arms rotation: no timer/cron in scripts or libs schedules --rotate. Scan every line
#    that schedules work (a systemd unit, systemctl enable, or a cron entry) for a --rotate reference.
armed=""
while IFS= read -r f; do
	[ -f "$f" ] || continue
	if grep -nE '\.timer|systemctl[[:space:]]+enable|crontab|cron\.d|OnCalendar|OnUnitActiveSec' "$f" 2>/dev/null \
		| grep -qE -- '--rotate|flow_rotate|rotate_plan'; then
		armed="$armed $(basename "$f")"
	fi
done < <(printf '%s\n' "$NB" "$REPO_ROOT"/control/lib/*.sh)
if [ -z "$armed" ]; then
	ok "no systemd timer / cron schedules --rotate (unattended rotation is C4c, gated)"
else
	badln "rotation appears auto-armed via a timer/cron in:$armed — the unattended loop is C4c, behind the RP-0012 go/no-go"
fi

printf '\n-- Result --\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS: the --rotate seam is dry-run only (never promotes) and is not auto-armed (RP-0012 C4b).\n'
	exit 0
fi
printf 'FAIL: the rotation executor seam is not dry-run-bounded — it could promote or auto-arm before the go/no-go.\n' >&2
exit 1
