#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotate_apply_gated.sh — conformance: the --rotate executor is DRY-RUN by default and a LIVE rotation is
# reachable ONLY behind the triple gate, never re-applies a rolled-back rotation, and is never auto-armed
# (RP-0012 C4b/C4c, §6).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   C4c lets flow_rotate change a live node (promote -> verify -> rollback). The safety of that hinges on
#   THREE static guarantees a future edit must not erode:
#     1. DRY-RUN DEFAULT — with no --apply-rotation, flow_rotate promotes nothing (the dry-run path has no
#        promote_config); promote_config lives ONLY in the live path.
#     2. TRIPLE GATE — the live path is entered only when ROTATE_APPLY (--apply-rotation) is set AND the
#        node is armed (rotate_live_armed / the node-local sentinel); ROTATE_APPLY defaults to 0; and
#        flow_rotate is NEVER called by flow_bootstrap/flow_update (no implicit actuation), and nothing
#        auto-arms --rotate on a timer/cron (the unattended loop is separately, explicitly enabled).
#     3. NO PERSISTENT SELF-OUTAGE — a live rotation persists through the operator-overrides overlay
#        (snapshot before mutate), and the rollback path reverts that overlay, so a rolled-back rotation
#        cannot re-apply on the next write_params/timer tick.
#   This gate pins all three by STATIC inspection (offline; no node, no sing-box).
#
# Exit: 0 = the executor is dry-run-default + triple-gated + revert-safe; 1 = a violation; 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotate_apply_gated: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# fnbody NAME FILE — print the top-level bash function body (opener `NAME() {` through the first `^}`).
fnbody() { awk -v fn="$1" '$0 ~ ("^" fn "\\(\\) \\{") {p=1} p {print} p && /^\}/ {exit}' "$2"; }
# strip `#` comments so doc prose cannot satisfy or trip a code assertion.
nocom() { sed -e 's/#.*$//'; }

printf '== rotation executor: dry-run-default + triple-gated + revert-safe (RP-0012 C4b/C4c) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

[ -f "$LIB" ] || { printf 'FAIL: control/lib/nb_rotate_apply.sh is missing (the executor seam).\n' >&2; exit 1; }
[ -f "$NB" ]  || { printf 'FAIL: scripts/node-bootstrap.sh is missing.\n' >&2; exit 2; }
ok "executor lib present: control/lib/nb_rotate_apply.sh"

# 0. The seam defines its functions.
for fn in flow_rotate rotate_apply_dryrun rotate_apply_live apply_rotation_to_params \
          persist_rotation_to_overlay revert_rotation_overlay rotate_live_armed rotate_arm rotate_disarm; do
	if grep -qE "^${fn}\(\)" "$LIB"; then ok "defines ${fn}()"; else badln "nb_rotate_apply.sh does not define ${fn}()"; fi
done

DRYRUN="$(fnbody rotate_apply_dryrun "$LIB" | nocom)"
LIVE="$(fnbody rotate_apply_live "$LIB" | nocom)"
FLOW="$(fnbody flow_rotate "$LIB" | nocom)"

# 1. DRY-RUN DEFAULT — the dry-run path and the dispatcher itself promote nothing; promote_config is
#    confined to the live path.
if printf '%s' "$DRYRUN" | grep -qw 'promote_config'; then
	badln "rotate_apply_dryrun calls promote_config — the default path must promote NOTHING"
else
	ok "rotate_apply_dryrun never calls promote_config (dry-run default)"
fi
if printf '%s' "$FLOW" | grep -qw 'promote_config'; then
	badln "flow_rotate calls promote_config directly (must be confined to rotate_apply_live)"
else
	ok "flow_rotate does not promote directly (promote is confined to the live path)"
fi
if printf '%s' "$LIVE" | grep -qw 'promote_config'; then
	ok "rotate_apply_live is the sole promote path"
else
	badln "rotate_apply_live does not call promote_config — the live path is incomplete"
fi

# 2. TRIPLE GATE — flow_rotate enters the live path only under BOTH ROTATE_APPLY and the arm check, with
#    a dry-run fallback; and the live path is unreachable without both.
if printf '%s' "$FLOW" | grep -q 'ROTATE_APPLY' \
	&& printf '%s' "$FLOW" | grep -q 'rotate_live_armed' \
	&& printf '%s' "$FLOW" | grep -qw 'rotate_apply_live' \
	&& printf '%s' "$FLOW" | grep -qw 'rotate_apply_dryrun'; then
	ok "flow_rotate gates rotate_apply_live behind ROTATE_APPLY + rotate_live_armed, with a dry-run fallback"
else
	badln "flow_rotate does not gate the live path behind BOTH ROTATE_APPLY and rotate_live_armed (with a dry-run fallback)"
fi
# ROTATE_APPLY defaults OFF in the entrypoint, and --apply-rotation is the only thing that sets it.
if grep -qE '^ROTATE_APPLY=0' "$NB"; then
	ok "ROTATE_APPLY defaults to 0 in node-bootstrap.sh (dry-run unless --apply-rotation)"
else
	badln "ROTATE_APPLY does not default to 0 in node-bootstrap.sh"
fi
if grep -qE '\-\-apply-rotation\)[[:space:]]*ROTATE_APPLY=1' "$NB"; then
	ok "--apply-rotation is the only switch that enables ROTATE_APPLY"
else
	badln "--apply-rotation does not map to ROTATE_APPLY=1 in node-bootstrap.sh"
fi

# 3. NO IMPLICIT ACTUATION — flow_bootstrap/flow_update must NOT call flow_rotate; the ONLY flow_rotate
#    call in the entrypoint is the explicit `rotate)` dispatch.
nb_flowrotate_calls="$(grep -cE '\bflow_rotate\b' "$NB" || true)"
if grep -qE '^[[:space:]]*rotate\)[[:space:]]*flow_rotate' "$NB" && [ "${nb_flowrotate_calls:-0}" -eq 1 ]; then
	ok "flow_rotate is reached ONLY via the explicit 'rotate)' dispatch (no flow_bootstrap/flow_update path)"
else
	badln "flow_rotate is referenced $nb_flowrotate_calls time(s) in the entrypoint — it must appear ONLY in the 'rotate)' dispatch"
fi

# 4. NO PERSISTENT SELF-OUTAGE — the live path persists via the overlay (snapshot before mutate) and the
#    rollback path reverts it; reuse the existing apply primitives, not a re-implementation.
if printf '%s' "$LIVE" | grep -qw 'rollback_config' && printf '%s' "$LIVE" | grep -qw 'revert_rotation_overlay'; then
	ok "rotate_apply_live pairs rollback_config with revert_rotation_overlay (a rolled-back rotation does not re-apply)"
else
	badln "rotate_apply_live does not pair config rollback with overlay revert — a rolled-back rotation could re-apply next tick"
fi
if fnbody persist_rotation_to_overlay "$LIB" | nocom | grep -qE '\bcp\b.*bak|_rotate_overlay_bak'; then
	ok "persist_rotation_to_overlay snapshots the overlay before mutating it (revert path exists)"
else
	badln "persist_rotation_to_overlay does not snapshot the overlay before mutating it"
fi
for prim in render_candidate validate_config promote_config write_params; do
	if printf '%s' "$LIVE" | grep -qw "$prim"; then ok "rotate_apply_live reuses $prim"; else badln "rotate_apply_live does not use $prim (must reuse the existing path)"; fi
done

# 4b. CATCHABILITY — write_params/render_candidate signal failure by `die` (exit 1), which a bare
#     `if ! cmd` / `cmd ||` CANNOT trap (it would terminate the whole sourced script, skipping the overlay
#     revert -> a rolled-back rotation re-applies next tick). They MUST be subshell-wrapped `( cmd )`.
LIBCODE="$(nocom < "$LIB")"
if printf '%s\n' "$LIBCODE" | grep -qE 'if ![[:space:]]+(write_params|render_candidate)\b'; then
	badln "a die-capable call (write_params/render_candidate) is used BARE in an 'if !' test — wrap it '( cmd )' so its die is catchable and the overlay revert runs"
elif printf '%s\n' "$LIBCODE" | grep -qE '(^|[^)])[[:space:]](write_params|render_candidate)[[:space:]]*\|\|'; then
	badln "a die-capable call (write_params/render_candidate) is used BARE with '||' — wrap it '( cmd )' (a die escapes || true)"
else
	ok "die-capable mutating calls (write_params/render_candidate) are subshell-wrapped on recoverable edges (a die cannot skip the overlay revert)"
fi
# pre-promote recovery helper exists and reverts the overlay.
if grep -qE '^rotate_abort_revert\(\)' "$LIB" && fnbody rotate_abort_revert "$LIB" | nocom | grep -qw 'revert_rotation_overlay'; then
	ok "rotate_abort_revert (pre-promote recovery) reverts the overlay"
else
	badln "rotate_abort_revert is missing or does not revert the overlay"
fi

# 4c. DRY-RUN HONORED — --apply-rotation --dry-run must NOT mutate persisted state. flow_rotate gates the
#     live path on DRY_RUN=0, and persist_rotation_to_overlay no-ops under DRY_RUN (defense-in-depth).
if printf '%s' "$FLOW" | grep -qE 'DRY_RUN[^0-9]+-eq 0'; then
	ok "flow_rotate requires DRY_RUN=0 for live apply (--dry-run forces a preview; no persisted mutation)"
else
	badln "flow_rotate does not require DRY_RUN=0 for the live path (--apply-rotation --dry-run could mutate persisted state)"
fi
if fnbody persist_rotation_to_overlay "$LIB" | nocom | grep -qE 'DRY_RUN[^0-9]+-eq 0'; then
	ok "persist_rotation_to_overlay honors DRY_RUN (no overlay mutation under --dry-run)"
else
	badln "persist_rotation_to_overlay does not honor DRY_RUN — --dry-run could still mutate the overlay"
fi

# 4d. ARMED-GUARD NESTING — the rotate_apply_live call must be NESTED under the rotate_live_armed check
#     (line-order), not merely co-occur in flow_rotate (a future edit must not call live outside the arm).
FLOWN="$(fnbody flow_rotate "$LIB" | nocom)"
armed_ln="$(printf '%s\n' "$FLOWN" | grep -nE '\brotate_live_armed\b' | head -1 | cut -d: -f1)"
live_ln="$(printf '%s\n' "$FLOWN" | grep -nE '\brotate_apply_live\b' | head -1 | cut -d: -f1)"
if [ -n "$armed_ln" ] && [ -n "$live_ln" ] && [ "$armed_ln" -lt "$live_ln" ]; then
	ok "flow_rotate checks rotate_live_armed BEFORE the rotate_apply_live call (armed-guard nesting, not mere co-occurrence)"
else
	badln "flow_rotate does not check rotate_live_armed before the rotate_apply_live call (the live call must be nested under the armed guard)"
fi

# 4e. SINGLE SOURCE OF TRUTH (§2.2 #8) — the proto->enable_key mapping is READ from the committed registry
#     (control/vocab.json .protos[].enable_key), never re-derived by a bash naming convention.
ENK="$(fnbody _rotation_enable_key "$LIB" | nocom)"
if printf '%s' "$ENK" | grep -qE '\.protos\[\]' && printf '%s' "$ENK" | grep -qE 'enable_key'; then
	ok "_rotation_enable_key reads enable_key from the registry (vocab.json .protos[]), not a re-derived convention (§2.2 #8)"
else
	badln "_rotation_enable_key does not read enable_key from the registry — re-deriving the rule duplicates the source of truth (§2.2 #8)"
fi

# 5. NO AUTO-ARM — nothing schedules --rotate/--apply-rotation/flow_rotate via a timer/cron in scripts or
#    libs (the unattended loop is a separate, explicit opt-in; the timer ships disabled).
armed=""
while IFS= read -r f; do
	[ -f "$f" ] || continue
	if grep -nE '\.timer|systemctl[[:space:]]+enable|crontab|cron\.d|OnCalendar|OnUnitActiveSec' "$f" 2>/dev/null \
		| grep -qE -- '--rotate|--apply-rotation|flow_rotate'; then
		armed="$armed $(basename "$f")"
	fi
done < <(printf '%s\n' "$NB" "$REPO_ROOT"/control/lib/*.sh)
if [ -z "$armed" ]; then
	ok "nothing auto-arms --rotate (no timer/cron schedules a live rotation)"
else
	badln "rotation appears auto-armed via a timer/cron in:$armed — the unattended loop must be explicitly enabled, never auto-armed"
fi

# 6. The arm sentinel is node-local state, never committed (git can never carry it to a node).
if git -C "$REPO_ROOT" ls-files --error-unmatch '*rotate-live.enabled' >/dev/null 2>&1; then
	badln "a 'rotate-live.enabled' arm sentinel is COMMITTED — it must be node-local state, never in git"
else
	ok "no arm sentinel is committed (live arming stays node-local, off the auto-pull path)"
fi

printf '\n-- Result --\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS: the rotation executor is dry-run by default, the live path is triple-gated + revert-safe, and nothing auto-arms it (RP-0012 §6).\n'
	exit 0
fi
printf 'FAIL: the rotation executor safety invariants are not statically guaranteed.\n' >&2
exit 1
