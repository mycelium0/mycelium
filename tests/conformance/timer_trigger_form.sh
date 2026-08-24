#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# timer_trigger_form.sh — conformance: every systemd TIMER this project emits must be provably able to
# fire again. A monotonic-only trigger is accepted ONLY when the emitting code also seeds its anchor.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   `OnUnitActiveSec=` schedules the next elapse relative to the last time the timer's SERVICE was
#   active. That anchor lives in systemd's in-memory unit state, and when it goes stale — a unit re-armed
#   in place, a service that never ran — the timer settles into `SubState=elapsed` with `Trigger=n/a` and
#   NEVER FIRES AGAIN, while `is-enabled` and `is-active` both keep reporting exactly what a healthy timer
#   reports. Deleting the stamp file does not clear it; neither does `restart`.
#
#   On 2026-07-28 two of three live nodes were in that state on `mycelium-update.timer`. They had stopped
#   receiving code, config and revocation changes for weeks, and every signal an operator would think to
#   check said they were armed. Finding it took reading `NextElapseUSecMonotonic` by hand.
#
#   Nothing in the tree constrained the trigger form, so the same pair could be — and was — reintroduced
#   by any new heredoc (Audit-0009 D1). This gate is that constraint.
#
# THE RULE (one of two forms, per emitted timer)
#   A. CALENDAR — the unit carries `OnCalendar=`. The next elapse is derived from the wall clock, so no
#      stale anchor can suppress it, and `Persistent=` becomes meaningful (it only ever applied to
#      calendar timers). Preferred wherever the cadence has a clean expression.
#   B. MONOTONIC + A SEEDED ANCHOR — the unit carries the `OnBootSec`/`OnUnitActiveSec` pair AND the code
#      that installs it also runs `systemctl start <the same unit>.service`, giving the anchor a real
#      value immediately. This is the only accepted form for cadences with no calendar expression (15s,
#      ~90s). The seed must name the SERVICE, not the timer: starting the timer does not set the anchor.
#
#   Neither form is asserted by spelling alone — each emitting site is located by the unit name it writes,
#   and the seed is matched against that same name.
#
# OFFLINE. Exit: 0 = every emitted timer can fire; 1 = one cannot be shown to; 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'timer_trigger_form: cannot resolve repo root\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== systemd timer trigger form: every emitted timer must be able to fire again ==\n'
printf 'repo: %s\n\n' "$REPO_ROOT"

# Every place the project writes a .timer: the shipped templates under infra/systemd, and the heredocs in
# the control-plane libraries. Discovered, not listed, so a NEW emitting site is covered the day it lands.
shopt -s nullglob
tpl_timers=( "$REPO_ROOT"/infra/systemd/*.timer )
emitters=( "$REPO_ROOT"/control/lib/*.sh "$REPO_ROOT"/scripts/*.sh )
shopt -u nullglob

found=0

# --- A. shipped templates ------------------------------------------------------------------------
for t in "${tpl_timers[@]}"; do
	found=$((found + 1))
	name="$(basename "$t")"
	body="$(grep -vE '^[[:space:]]*#' "$t" 2>/dev/null)"
	if grep -qE '^[[:space:]]*OnCalendar=' <<<"$body" ; then
		ok "$name: calendar trigger (cannot be suppressed by a stale anchor)"
		# Persistent= is meaningful only here; note it rather than require it.
		grep -qE '^[[:space:]]*Persistent=true' <<<"$body" \
			&& ok "  and Persistent=true, so one missed run after downtime is caught up"
	elif grep -qE '^[[:space:]]*OnUnitActiveSec=' <<<"$body" ; then
		badln "$name is a SHIPPED TEMPLATE with a monotonic-only trigger. It is copied by hand and enabled with no service start, so nothing seeds its anchor: it can settle into SubState=elapsed / Trigger=n/a and never fire again while is-enabled and is-active both say ARMED. Use OnCalendar=."
	else
		badln "$name declares no OnCalendar= and no OnUnitActiveSec= — it has no recurring trigger at all"
	fi
done

# --- B. heredoc emitters -------------------------------------------------------------------------
# For each `cat >…/<unit>.timer <<UNIT … UNIT` block, decide the form, and for the monotonic form look
# for the anchor seed anywhere in the same file (the seed correctly lives at the enable site, which is
# usually a different function from the writer).
for f in "${emitters[@]}"; do
	[ -f "$f" ] || continue
	grep -qE '/etc/systemd/system/[A-Za-z0-9@._-]+\.timer' "$f" 2>/dev/null || continue
	src="$(basename "$f")"
	# unit names this file writes a timer for
	units="$(grep -oE '/etc/systemd/system/[A-Za-z0-9@._-]+\.timer' "$f" | sed 's#.*/##; s#\.timer$##' | sort -u)"
	for u in $units; do
		# The `cat >` target may be the literal path OR a helper that prints it (the idiom in nb_measure.sh:
		# `cat >"$(_l7probe_timer_unit)" <<UNIT`). Resolve helper -> unit from its one-line definition, so a
		# file using that idiom is not silently skipped — which is exactly what an earlier draft of this
		# gate did, checking three timers and reporting PASS while two went unexamined.
		wr="$u.timer"
		# A path helper is one whose definition PRINTS the unit path — not merely any one-line function
		# that happens to mention the unit. Matching on the mention alone identified helpers by
		# coincidence: adding `rotate_loop_running() { systemctl is-active --quiet mycelium-rotate.timer; }`
		# was enough to make this gate hunt for a heredoc written by a predicate that writes nothing, and
		# report the emitter as unexaminable. Require the printf of a systemd path on the same line.
		fn="$(grep -oE "^[A-Za-z0-9_]+\(\).*printf.*/etc/systemd/system/[A-Za-z0-9@._-]*$u\.timer" "$f" | head -1 | sed -E 's/\(\).*//')"
		[ -n "$fn" ] && wr="$fn"
		found=$((found + 1))
		# the heredoc body for THIS unit: from its cat line to the terminator
		blk="$(awk -v u="$wr" '
			index($0, u) && index($0, "<<") && index($0, "cat") { f=1; next }
			f && /^[A-Z]+$/ { f=0 }
			f { print }' "$f" | grep -vE '^[[:space:]]*#')"
		if [ -z "$blk" ]; then
			badln "$src: could not extract the heredoc body for $u.timer — re-confirm this gate against the new shape"
			continue
		fi
		if grep -qE '^[[:space:]]*OnCalendar=' <<<"$blk" ; then
			ok "$src: $u.timer uses a calendar trigger"
		elif grep -qE '^[[:space:]]*OnUnitActiveSec=' <<<"$blk" ; then
			# Form B: the SERVICE of the same name must be started by this file.
			if grep -qE "systemctl start $u\.service" "$f"; then
				ok "$src: $u.timer is monotonic but its anchor is seeded (systemctl start $u.service)"
			elif grep -qE "systemctl start $u(\.service)?\b" "$f"; then
				badln "$src: $u.timer is monotonic and the only start names the TIMER, not $u.service — starting a timer does not set the OnUnitActiveSec anchor"
			else
				badln "$src: $u.timer uses OnUnitActiveSec= with NOTHING seeding its anchor. A timer whose service has never run has no anchor to schedule from, and one re-armed in place keeps a poisoned one — either way it reports enabled+active and never fires (the state two live nodes reached on 2026-07-28). Add OnCalendar=, or 'systemctl start $u.service' at the enable site."
			fi
		else
			badln "$src: $u.timer declares neither OnCalendar= nor OnUnitActiveSec= — no recurring trigger"
		fi
	done
done

[ "$found" -gt 0 ] || badln "no timers found at all — the discovery globs no longer match; re-confirm this gate"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a timer this project emits cannot be shown to fire again after its first elapse.\n' >&2
	exit 1
fi
printf 'PASS: every emitted timer is calendar-triggered or has a seeded monotonic anchor (%d checked).\n' "$found"
exit 0
