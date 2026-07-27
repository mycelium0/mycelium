#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# update_unit_drift_drill.sh — ON-NODE drill: does this node's DEPLOYED mycelium-update unit still
# match the shipped template, and is it safe in its current state?
# Author: mindicator & silicon bags quartet.
#
# WHY THIS EXISTS
#   mycelium-update.{service,timer} are the only systemd units in this project with no owner. Every
#   other unit is written by a heredoc in control/lib and rewritten on every apply, so drift is
#   impossible. These two are documentation-grade templates the operator copies BY HAND
#   (docs/runbooks/node-bootstrap.md; RP-0003 workstream W3), and NOTHING reconciles a deployed copy
#   back to the template — not `--node-apply`, not `--update`, not any gate. A hand-edit therefore
#   persists forever and is invisible to the offline suite, which can only see the repo.
#
#   That is not a theoretical gap. On 2026-07-27 two live nodes were found carrying a copy whose
#   ExecStart had grown `--insecure-no-verify` — the flag that makes verify_signed_ref return before
#   it checks anything (ADR-0015's provenance gate) — plus a literal node address and a client list.
#   The timer was disabled, so nothing had actually run unauthenticated; but the documented install
#   procedure ends in `systemctl enable --now`, which would have armed a periodic root-level
#   unauthenticated auto-pull in one command. This drill is what would have caught it.
#
# WHAT IT CHECKS (read-only; mutates NOTHING)
#   1. Deployed vs template: a full diff of the effective directive lines, ExecStart called out
#      explicitly. Any delta is reported, because there is no legitimate silent local edit.
#   2. The provenance bypass: `--insecure-no-verify` anywhere in a deployed unit -> CRITICAL.
#   3. Arming safety: if the timer is ACTIVE or ENABLED, the ExecStart MUST carry both
#      --allowed-signers and a --repo-ref. An armed timer without them is an unauthenticated
#      auto-pull running right now -> CRITICAL.
#   4. Node-specific pins baked into the unit (address literal / --clients) -> WARN (OPSEC + the
#      unit stops being resettable by a plain re-cp).
#   5. Masked/absent states are reported as SAFE, not as failures: masked is a legitimate parked
#      posture pre-W1, and a node that never installed the unit has nothing to drift.
#
# WHY A DRILL AND NOT A GATE: it needs /etc/systemd/system and `systemctl`, which exist only on a
# node. The repo-side counterpart (tests/conformance/update_unit_template_shape.sh) keeps the
# TEMPLATE clean; only this drill can see what a node actually has.
#
# USAGE:  sudo bash scripts/update_unit_drift_drill.sh [--checkout /opt/mycelium]
# Exit:   0 = clean or safely parked, 1 = drift/unsafe arming found, 2 = usage/env error.

set -uo pipefail

CHECKOUT="/opt/mycelium"
while [ $# -gt 0 ]; do
	case "$1" in
		--checkout) CHECKOUT="${2:?--checkout needs a value}"; shift 2 ;;
		-h|--help)  sed -n '7,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)          printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

UNIT_DIR="/etc/systemd/system"
SVC_NAME="mycelium-update.service"
TMR_NAME="mycelium-update.timer"
TPL_SVC="$CHECKOUT/infra/systemd/$SVC_NAME"
TPL_TMR="$CHECKOUT/infra/systemd/$TMR_NAME"

command -v systemctl >/dev/null 2>&1 || { printf 'FAIL: systemctl not found — this drill runs ON A NODE.\n' >&2; exit 2; }
[ -f "$TPL_SVC" ] && [ -f "$TPL_TMR" ] || {
	printf 'FAIL: unit templates not found under %s/infra/systemd (pass --checkout).\n' "$CHECKOUT" >&2; exit 2; }

fail=0; warn_n=0
ok()   { printf '  ok    %s\n' "$1"; }
crit() { printf '  CRIT  %s\n' "$1"; fail=1; }
warn() { printf '  warn  %s\n' "$1"; warn_n=$((warn_n + 1)); }

# directives only — the template headers necessarily NAME the forbidden flag in order to warn about it
directives() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -vE '^$'; }

printf '== mycelium-update deployed-unit drift drill ==\n'
printf 'node:     %s\n' "$(hostname 2>/dev/null || echo '(unknown)')"
printf 'checkout: %s\n\n' "$CHECKOUT"

svc_state="$(systemctl is-enabled "$SVC_NAME" 2>&1 || true)"
tmr_state="$(systemctl is-enabled "$TMR_NAME" 2>&1 || true)"
tmr_active="$(systemctl is-active "$TMR_NAME" 2>&1 || true)"
printf 'state:    service=%s  timer=%s (%s)\n\n' "$svc_state" "$tmr_state" "$tmr_active"

# --- parked / absent postures are legitimate outcomes, not failures -------------------------------
if [ "$svc_state" = "masked" ] || [ "$tmr_state" = "masked" ]; then
	ok "the unit is MASKED — it cannot be armed by \`systemctl enable\`, which fails closed."
	ok "  This is the correct parked posture until RP-0003 W1 (a signed tag to pin) exists."
	ok "  To arm later: systemctl unmask, re-cp the template, append --allowed-signers + --repo-ref, then enable."
	printf '\n-- Result --\nPASS: parked (masked). Nothing can auto-pull on this node.\n'
	exit 0
fi
if [ ! -f "$UNIT_DIR/$SVC_NAME" ] && [ ! -f "$UNIT_DIR/$TMR_NAME" ]; then
	ok "no mycelium-update unit is installed on this node — nothing to drift."
	printf '\n-- Result --\nPASS: not installed.\n'
	exit 0
fi

# --- 1. deployed vs template ----------------------------------------------------------------------
for pair in "$SVC_NAME:$TPL_SVC" "$TMR_NAME:$TPL_TMR"; do
	name="${pair%%:*}"; tpl="${pair#*:}"; dep="$UNIT_DIR/$name"
	if [ ! -f "$dep" ]; then
		warn "$name: template exists but the node has no deployed copy (half-installed)."
		continue
	fi
	if diff -q <(directives "$tpl") <(directives "$dep") >/dev/null 2>&1; then
		ok "$name: deployed copy matches the shipped template exactly"
	else
		crit "$name: DEPLOYED COPY HAS DRIFTED from $tpl"
		printf '        --- template / +++ deployed ---\n'
		diff -u <(directives "$tpl") <(directives "$dep") 2>/dev/null | tail -n +3 | sed 's/^/        /'
		printf '        -> nothing reconciles this back. Reset with: cp %s %s\n' "$tpl" "$dep"
	fi
done

# --- 2. the provenance bypass ---------------------------------------------------------------------
bypass=0
for name in "$SVC_NAME" "$TMR_NAME"; do
	[ -f "$UNIT_DIR/$name" ] || continue
	if directives "$UNIT_DIR/$name" | grep -q -- '--insecure-no-verify'; then
		bypass=1
		crit "$name: carries --insecure-no-verify — verify_signed_ref returns BEFORE checking anything."
		crit "        Fetched code would be merged, installed and COMPILED as root unauthenticated."
	fi
done
[ "$bypass" -eq 0 ] && ok "no deployed unit carries --insecure-no-verify"

# --- 3. arming safety ------------------------------------------------------------------------------
exec_line="$(directives "$UNIT_DIR/$SVC_NAME" 2>/dev/null | grep -E '^ExecStart=' | head -1 || true)"
if [ "$tmr_state" = "enabled" ] || [ "$tmr_active" = "active" ]; then
	has_signers=0; has_ref=0
	printf '%s' "$exec_line" | grep -q -- '--allowed-signers' && has_signers=1
	printf '%s' "$exec_line" | grep -q -- '--repo-ref'        && has_ref=1
	if [ "$has_signers" -eq 1 ] && [ "$has_ref" -eq 1 ] && [ "$bypass" -eq 0 ]; then
		ok "the timer is ARMED and the ExecStart is authenticated (--allowed-signers + --repo-ref, no bypass)"
	else
		crit "THE TIMER IS ARMED WITHOUT AN AUTHENTICATED FETCH."
		[ "$has_signers" -eq 0 ] && crit "        missing --allowed-signers (no key to verify against)"
		[ "$has_ref" -eq 0 ]     && crit "        missing --repo-ref (tracking a MUTABLE branch, not an immutable signed tag)"
		crit "        A periodic root-level unattended pull is running now. Disarm immediately:"
		crit "          systemctl disable --now $TMR_NAME"
	fi
else
	ok "the timer is not armed (enabled=$tmr_state active=$tmr_active) — installing is not arming"
fi

# --- 4. node-specific pins -------------------------------------------------------------------------
if [ -n "$exec_line" ]; then
	pins=""
	printf '%s' "$exec_line" | grep -qE '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' && pins="$pins address-literal"
	printf '%s' "$exec_line" | grep -q -- '--clients'                                      && pins="$pins --clients"
	if [ -n "$pins" ]; then
		warn "the ExecStart bakes in node-specific value(s):$pins"
		warn "  -> the unit is no longer resettable by a plain re-cp, and a node address in a unit file is an OPSEC item."
	else
		ok "the ExecStart carries no baked-in node address or client list"
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: this node deviates from the shipped update-unit contract (see CRIT above).\n' >&2
	exit 1
fi
[ "$warn_n" -gt 0 ] && printf 'PASS with %d warning(s).\n' "$warn_n" || printf 'PASS: deployed unit matches the template and is not unsafely armed.\n'
exit 0
