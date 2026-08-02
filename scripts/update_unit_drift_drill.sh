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
#   mycelium-update.{service,timer} have no owner: no code path installs, reconciles or removes them.
#
#   PRECISELY (Audit-0009 AC1 — the earlier wording here claimed drift was impossible everywhere else,
#   and that was false): only the two DATA-PLANE units are rewritten on every promote —
#   install_singbox_unit and install_xray_unit run on each apply, so those genuinely cannot drift. The
#   control-plane units (mycelium-measure, mycelium-rotate, mycelium-l7probe, node_exporter) are written
#   ONCE by their arming verb and never reconciled afterwards, so a hand-edit to any of them persists
#   exactly as it does here — this drill simply does not cover them yet. Do not read a green run as
#   "no unit on this node has drifted"; read it as "the update unit has not". These two are documentation-grade templates the operator copies BY HAND
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
#   6. The TIMER's effective schedule: its drop-ins, its calendar/monotonic triggers and its next
#      elapse. ADDITIVE to check 3, never a replacement for it (Audit-0009 C1) — `is-enabled` and
#      `is-active` cannot tell an armed timer from one that has settled into SubState=elapsed with
#      Trigger=n/a, which is exactly the dead state found on two nodes on 2026-07-28; but they are also
#      what must gate the authentication check, because a dead-but-enabled timer with an unauthenticated
#      ExecStart is one `systemctl restart` away from pulling as root. So both are read and reported
#      separately: state ARMS the safety checks, next-elapse says whether it will actually FIRE.
#
# WHAT IT PRINTS (Audit-0009 S1)
#   Everything this drill emits goes through `redact` first: the node's own hostname, IPv4/IPv6 literals
#   and FQDNs are masked, and the OPSEC warning about an address in a root-run command line now comes
#   BEFORE the value rather than after it. The drift branch — the one the drill exists to produce — used
#   to print the deployed ExecStart verbatim, which on the two nodes of 2026-07-27 meant printing the node
#   address literal it was warning about, into the artifact an operator is most likely to copy off a node
#   during an incident. Scope is deliberately the ADDRESS class, not internal/diag.Redact wholesale: a
#   unit directive is mostly paths and unit names, and the generic opaque-token pass would mask
#   `/etc/systemd/system/...` and leave the diff unreadable. Unit files carry no secrets — those live in
#   the config, which this drill never reads.
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

# redact — mask the node-identifying ADDRESS classes from everything this drill prints (Audit-0009 S1):
# the node's own hostname (word-anchored, and only at >=4 chars, exactly as internal/diag.RedactBundle
# does — a 3-char hostname is a common substring and masking it would corrupt the output), then IPv6,
# then IPv4, then FQDNs. Ordered like internal/diag's rules so the structural classes are scrubbed WHOLE
# rather than fragmented by a broader pass.
#
# The dotted-name pass would also eat `mycelium-update.service`, `override.conf`, `node-bootstrap.sh` —
# the very vocabulary the diff exists to show — so file/unit extensions are protected behind a sentinel
# first and restored after. That is the whole compromise: mask what identifies the node, keep what
# identifies the defect. GNU sed assumed (this drill already requires systemd).
SELF_HOST="$(hostname 2>/dev/null || printf '')"
redact() {
	local h="$SELF_HOST"
	if [ "${#h}" -lt 4 ]; then h=""; fi
	sed -E \
		-e 's/\.(service|timer|socket|target|mount|path|slice|conf|sh|json|pub|md|go|toml|yml|yaml|d)\b/\x01\1/g' \
		${h:+-e "s/\\b$(printf '%s' "$h" | sed -E 's/[][\\.^$*+?(){}|/]/\\\\&/g')\\b/[redacted-host]/gI"} \
		-e 's/(^|[^0-9a-fA-F:.])(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{0,4}::([0-9a-fA-F]{1,4}:)*([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F]{1,4})?)/\1[redacted-ipv6]/g' \
		-e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/[redacted-ipv4]/g' \
		-e 's/\b([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}\b/[redacted-host]/g' \
		-e 's/\x01/./g'
}
say() { printf '%s\n' "$1" | redact; }

# directives only — the template headers necessarily NAME the forbidden flag in order to warn about it
directives() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -vE '^$'; }

printf '== mycelium-update deployed-unit drift drill ==\n'
say "node:     ${SELF_HOST:-(unknown)}"
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
		# The OPSEC warning goes ABOVE the value, not after it (Audit-0009 S1): a warning printed below
		# the thing it warns about arrives after the operator has already copied it.
		printf '        NOTE: addresses/hostnames below are masked; a drifted unit is still a root command\n'
		printf '              line — treat the unmasked original as sensitive before sharing it.\n'
		printf '        --- template / +++ deployed ---\n'
		diff -u <(directives "$tpl") <(directives "$dep") 2>/dev/null | tail -n +3 | redact | sed 's/^/        /'
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
	printf '%s\n' "$exec_all" | redact | sed 's/^/          - /'
fi
dropins="$(systemctl show "$SVC_NAME" -p DropInPaths --value 2>/dev/null)"
if [ -n "$dropins" ]; then
	say "  note  per-node flags come from drop-in(s): $dropins"
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
		# "enabled/active", NOT "armed" (Audit-0009 C1). These two signals cannot distinguish a timer that
		# will fire from one that has settled into SubState=elapsed with Trigger=n/a — the dead state found
		# on two nodes on 2026-07-28. Whether it will actually fire is check 6 below; what THIS branch
		# establishes is that the command it would run is authenticated.
		ok "the timer is ENABLED/ACTIVE and the effective command is authenticated (--allowed-signers + --repo-ref, no bypass)"
		ref="$(printf '%s' "$exec_eff" | sed -n 's/.*--repo-ref[= ]\{1,\}\([^ ]*\).*/\1/p')"
		case "$ref" in
			v[0-9]*|*[0-9].[0-9]*)
				# LOOK AT THE CHECKOUT, not at the shape of the flag. A tag-shaped --repo-ref proves the
				# operator asked for an immutable pin; it does not prove the node took it. `merge --ff-only`
				# is a NO-OP exiting 0 when the checkout is already at or ahead of the tag, which is exactly
				# what happens when a node that has been tracking main is pinned to a freshly cut tag: HEAD
				# stays on main's tip and never moves again, while the signature verifies, the converge runs
				# and the unit reports success. This line used to print "an immutable approval" over precisely
				# that state, replacing the one warning that would otherwise have appeared.
				pin_want="$(git -C "$CHECKOUT" rev-parse -q --verify "refs/tags/${ref}^{commit}" 2>/dev/null || true)"
				pin_head="$(git -C "$CHECKOUT" rev-parse -q --verify HEAD 2>/dev/null || true)"
				if [ -z "$pin_want" ]; then
					warn "  --repo-ref '$ref' is tag-shaped but no such tag exists in $CHECKOUT — the updater would fall back to treating it as a branch"
				elif [ "$pin_want" = "$pin_head" ]; then
					say "  ok    pinned to '$ref' and the checkout IS at that tag (an immutable approval)"
				else
					crit "--repo-ref is '$ref' but the checkout is NOT at that tag."
					crit "        tag:  $pin_want"
					crit "        HEAD: $pin_head"
					crit "        'merge --ff-only' cannot move a checkout backwards, so if HEAD is at or past the"
					crit "        tag it exits 0 having done nothing — on every tick, silently, while every other"
					crit "        signal here reports success. Re-point deliberately:"
					crit "          git -C $CHECKOUT checkout --detach refs/tags/$ref"
				fi ;;
			'')                    warn "  --repo-ref present but its value could not be parsed" ;;
			*)                     warn_n=$((warn_n + 1)); say "  warn  pinned to the MUTABLE ref '$ref': every push to it reaches this node within one cadence, and the signature covers only the tip (intervening commits ride in on the fast-forward). Accepted posture for an operator-owned node; not for a shared one." ;;
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

# --- 3b. the TIMER's effective schedule (Audit-0009 C1) ---------------------------------------------
# ADDITIVE to check 3, deliberately. `is-enabled`/`is-active` gate the authentication check above and must
# keep doing so — a dead-but-enabled timer whose ExecStart is unauthenticated is one `systemctl restart`
# away from a root-level unattended pull, and replacing the state test with a next-elapse test would let it
# skip that check entirely and be reported "not armed". But those two signals also cannot tell an armed
# timer from one that has settled into SubState=elapsed with Trigger=n/a. That is not hypothetical: on
# 2026-07-28 two of three nodes reported enabled+active with NextElapseUSecMonotonic=infinity and had not
# fired in weeks. So the schedule is read and reported on its own terms.
#
# The timer's own DROP-INS are read here too. The project's doctrine puts per-node cadence in a TIMER
# drop-in, and until now the drill read DropInPaths for the SERVICE only — so a drop-in that changed
# OnCalendar=, RandomizedDelaySec= or repointed Unit= at a different service was reported nowhere.
if [ -f "$UNIT_DIR/$TMR_NAME" ]; then
	tmr_dropins="$(systemctl show "$TMR_NAME" -p DropInPaths --value 2>/dev/null)"
	tmr_unit="$(systemctl show "$TMR_NAME" -p Unit --value 2>/dev/null)"
	tmr_cal="$(systemctl show "$TMR_NAME" -p TimersCalendar --value 2>/dev/null)"
	tmr_mono="$(systemctl show "$TMR_NAME" -p TimersMonotonic --value 2>/dev/null)"
	tmr_next_r="$(systemctl show "$TMR_NAME" -p NextElapseUSecRealtime --value 2>/dev/null)"
	tmr_next_m="$(systemctl show "$TMR_NAME" -p NextElapseUSecMonotonic --value 2>/dev/null)"
	tmr_last="$(systemctl show "$TMR_NAME" -p LastTriggerUSec --value 2>/dev/null)"
	[ -n "$tmr_dropins" ] && say "  note  timer drop-in(s): $tmr_dropins"
	[ -n "$tmr_cal" ]     && say "  note  calendar trigger: $tmr_cal"
	[ -n "$tmr_mono" ]    && say "  note  monotonic trigger: $tmr_mono"
	say "  note  last trigger: ${tmr_last:-n/a}"
	# `Unit=` is what the timer will actually start. A drop-in that repoints it is a silent redirection of
	# every tick to some other command, which no other check here would notice.
	if [ -n "$tmr_unit" ] && [ "$tmr_unit" != "$SVC_NAME" ]; then
		crit "$TMR_NAME starts '$tmr_unit', NOT $SVC_NAME — a drop-in has repointed it; every check above examined the wrong unit."
	fi
	# The dead state: no realtime elapse AND no monotonic elapse. systemd reports the monotonic field as 0
	# (or the string 'infinity') and the realtime field empty/'n/a' when nothing is scheduled.
	next_dead=1
	case "$tmr_next_r" in ''|'n/a'|'infinity') : ;; *) next_dead=0 ;; esac
	if [ "$next_dead" -eq 1 ]; then
		case "$tmr_next_m" in ''|'0'|'n/a'|'infinity') : ;; *) next_dead=0 ;; esac
	fi
	if [ "$tmr_state" = "enabled" ] || [ "$tmr_active" = "active" ]; then
		if [ "$next_dead" -eq 1 ]; then
			crit "the timer reports NO NEXT ELAPSE (realtime='${tmr_next_r:-n/a}' monotonic='${tmr_next_m:-n/a}')."
			crit "        It is enabled/active and WILL NEVER FIRE — the state this drill's own two signals cannot see."
			crit "        A monotonic-only trigger that has already elapsed does not re-arm; give it a calendar"
			crit "        trigger in a timer drop-in (OnCalendar=), then: systemctl daemon-reload && systemctl restart $TMR_NAME"
		else
			say "  ok    the timer will fire: next elapse ${tmr_next_r:-monotonic ${tmr_next_m}}"
		fi
	else
		say "  note  next elapse: ${tmr_next_r:-${tmr_next_m:-n/a}} (timer not enabled/active — informational)"
	fi
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
