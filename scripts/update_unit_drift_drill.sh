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

# --- the EFFECTIVE ExecStart ----------------------------------------------------------------------
# Per-node flags (the signer path, the ref pin) belong in a systemd DROP-IN, not in the unit file —
# hand-editing the unit is the exact drift this drill exists to catch, and a drop-in keeps the
# installed unit a pristine template copy that `systemctl revert` resets in one command.
#
# So every check about WHAT WILL RUN must read the MERGED unit, not the file. Reading the file was
# wrong in both directions: it false-CRITs a correctly-armed node whose flags live in a drop-in, and —
# far worse — it is BLIND to a drop-in that adds --insecure-no-verify. A check that is permanently red
# on a correct node stops being read, and a check with a hole that big is not a check.
# Falls back to the file's ExecStart if systemctl cannot report (unit absent / systemd not answering).
# EVERY ExecStart, not the first. `Type=oneshot` admits MULTIPLE ExecStart= lines and systemd runs them
# all, in order, as root. This read used `head -1`, so a drop-in that APPENDS a second command — after an
# earlier drop-in has already supplied the authenticated one, which is exactly the live posture here — was
# invisible to all three checks below, and the drill printed "no provenance bypass" and "the effective
# command is authenticated" while the second command ran unattended every 15 minutes. The injection test
# that accompanied the original fix only exercised a RESETTING drop-in (one that clears and replaces), so
# it never touched this shape (Audit-0009 C2).
exec_all="$(systemctl show "$SVC_NAME" -p ExecStart --value 2>/dev/null \
	| sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//' | grep -v '^$')"
[ -n "$exec_all" ] || exec_all="$(directives "$UNIT_DIR/$SVC_NAME" 2>/dev/null | grep -E '^ExecStart=' | sed 's/^ExecStart=//')"
exec_n="$(printf '%s\n' "$exec_all" | grep -c . || true)"
# The checks below reason over the CONCATENATION, so a flag in any command is seen. Count is reported
# separately: on this unit more than one ExecStart is itself the finding, whatever the commands say.
exec_eff="$(printf '%s' "$exec_all" | tr '\n' ' ')"
if [ "${exec_n:-0}" -gt 1 ]; then
	crit "the unit has $exec_n ExecStart commands; systemd runs ALL of them as root, in order."
	crit "        On this unit that is never legitimate: the per-node flags belong in ONE resetting drop-in"
	crit "        (\`ExecStart=\` to clear, then the single authenticated command). A second, APPENDED"
	crit "        command is how a provenance bypass hides behind a correct-looking first one."
	printf '%s\n' "$exec_all" | sed 's/^/          - /'
fi
dropins="$(systemctl show "$SVC_NAME" -p DropInPaths --value 2>/dev/null)"
if [ -n "$dropins" ]; then
	printf '  note  per-node flags come from drop-in(s): %s\n' "$dropins"
	printf '        (the unit FILE stays a pristine template copy; `systemctl revert %s` resets it)\n' "$SVC_NAME"
fi

# --- 2. the provenance bypass (over the EFFECTIVE command + both unit files) ------------------------
bypass=0
if printf '%s' "$exec_eff" | grep -q -- '--insecure-no-verify'; then
	bypass=1
	crit "the EFFECTIVE ExecStart carries --insecure-no-verify — verify_signed_ref returns BEFORE checking anything."
	crit "        Fetched code would be merged, installed and COMPILED as root unauthenticated."
	[ -n "$dropins" ] && crit "        It is coming from a DROP-IN, which the unit file does not show: $dropins"
fi
for name in "$SVC_NAME" "$TMR_NAME"; do
	[ -f "$UNIT_DIR/$name" ] || continue
	if directives "$UNIT_DIR/$name" | grep -q -- '--insecure-no-verify'; then
		bypass=1
		crit "$name (unit file): carries --insecure-no-verify — the shipped template must never carry it."
	fi
done
[ "$bypass" -eq 0 ] && ok "no provenance bypass in the effective command or either unit file"

# --- 3. arming safety (over the EFFECTIVE command) --------------------------------------------------
# An armed timer is only as safe as the command it actually runs, so this reads the merged unit. The
# signature covers the pinned ref's TIP; `merge --ff-only` then ingests every intervening commit, so a
# signed pin is a real provenance gate but NOT a per-commit one. A MUTABLE pin (a branch) is an
# accepted posture on an operator-owned node and is reported, not failed — what fails is arming with
# no authentication at all.
if [ "$tmr_state" = "enabled" ] || [ "$tmr_active" = "active" ]; then
	has_signers=0; has_ref=0
	printf '%s' "$exec_eff" | grep -q -- '--allowed-signers' && has_signers=1
	printf '%s' "$exec_eff" | grep -q -- '--repo-ref'        && has_ref=1
	if [ "$has_signers" -eq 1 ] && [ "$has_ref" -eq 1 ] && [ "$bypass" -eq 0 ]; then
		ok "the timer is ARMED and the effective command is authenticated (--allowed-signers + --repo-ref, no bypass)"
		ref="$(printf '%s' "$exec_eff" | sed -n 's/.*--repo-ref[= ]\{1,\}\([^ ]*\).*/\1/p')"
		case "$ref" in
			v[0-9]*|*[0-9].[0-9]*) ok "  pinned to '$ref' (tag-shaped: an immutable approval)" ;;
			'')                    warn "  --repo-ref present but its value could not be parsed" ;;
			*)                     warn "  pinned to the MUTABLE ref '$ref': every push to it reaches this node within one cadence, and the signature covers only the tip (intervening commits ride in on the fast-forward). Accepted posture for an operator-owned node; not for a shared one." ;;
		esac
	else
		crit "THE TIMER IS ARMED WITHOUT AN AUTHENTICATED FETCH."
		[ "$has_signers" -eq 0 ] && crit "        missing --allowed-signers (no key to verify against)"
		[ "$has_ref" -eq 0 ]     && crit "        missing --repo-ref (no pinned ref to verify)"
		[ "$bypass" -eq 1 ]      && crit "        and the provenance gate is explicitly bypassed"
		crit "        A periodic root-level unattended pull is running now. Disarm immediately:"
		crit "          systemctl disable --now $TMR_NAME"
	fi
else
	ok "the timer is not armed (enabled=$tmr_state active=$tmr_active) — installing is not arming"
fi

# --- 4. node-specific pins (over the EFFECTIVE command) --------------------------------------------
# A per-node value in a DROP-IN is fine and expected (that is where the signer path belongs). What this
# flags is a value that pins the command to ONE node: an address literal or a client list. Those make
# the unit non-portable and put a node address in a root-run command line.
if [ -n "$exec_eff" ]; then
	pins=""
	printf '%s' "$exec_eff" | grep -qE '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' && pins="$pins address-literal"
	printf '%s' "$exec_eff" | grep -q -- '--clients'                                      && pins="$pins --clients"
	printf '%s' "$exec_eff" | grep -q -- '--node-address'                                 && pins="$pins --node-address"
	if [ -n "$pins" ]; then
		warn "the effective ExecStart bakes in node-specific value(s):$pins"
		warn "  -> a node address in a root-run command line is an OPSEC item, and the unit stops being resettable by a plain re-cp."
	else
		ok "the effective ExecStart carries no baked-in node address or client list"
	fi
fi

# --- 5. converge freshness (Audit-0009 X1) -----------------------------------------------------------
# The timer can be enabled, active and scheduled and still never have converged — that is exactly what two
# of three nodes looked like on 2026-07-28, and it took reading NextElapse by hand to see it. A schedule is
# an intention; the stamp is the outcome. Report the outcome.
if [ "$tmr_state" = "enabled" ] || [ "$tmr_active" = "active" ]; then
	stamp_f="/var/lib/mycelium/last_converge_ok"
	if [ -r "$stamp_f" ]; then
		st="$(cat "$stamp_f" 2>/dev/null)"; now_s="$(date +%s 2>/dev/null || printf '')"
		case "$st" in ''|*[!0-9]*) st="" ;; esac
		if [ -n "$st" ] && [ -n "$now_s" ]; then
			age=$(( now_s - st ))
			if [ "$age" -lt 0 ]; then
				warn "the converge stamp is in the FUTURE (${age}s) — the clock moved; treat the age below as unusable."
			elif [ "$age" -gt 5400 ]; then
				crit "the timer is armed but the last SUCCESSFUL converge was ${age}s ago (>90 min)."
				crit "        An armed schedule is an intention; this is the outcome. A timer can be enabled,"
				crit "        active and scheduled and still never fire — check the next elapse, not is-enabled:"
				crit "          systemctl show mycelium-update.timer -p NextElapseUSecMonotonic   # 'infinity' = dead"
			else
				ok "last successful converge ${age}s ago (armed and actually converging)"
			fi
		else
			warn "converge stamp present but unreadable — cannot judge freshness (no signal, not a failure)."
		fi
	else
		warn "no converge stamp at $stamp_f yet — expected on a node that has not completed an unattended"
		warn "  converge since this check shipped; it appears after the first successful tick."
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: this node deviates from the shipped update-unit contract (see CRIT above).\n' >&2
	exit 1
fi
[ "$warn_n" -gt 0 ] && printf 'PASS with %d warning(s).\n' "$warn_n" || printf 'PASS: deployed unit matches the template and is not unsafely armed.\n'
exit 0
