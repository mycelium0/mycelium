#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# measure_daemon_ships_disabled.sh — conformance (RP-0010 Plane-1 C5c): the MEASURE daemon
# (mycelium-measure.service, run by myceliumd) SHIPS DISABLED. It is written + enabled ONLY by the
# explicit operator flag --measure-enable; no auto path (flow_bootstrap / flow_update / install_tooling
# / install_spine) ever installs, enables, or starts it. So an auto-pull can deploy the (always-built,
# inert) myceliumd binary but can NEVER start the plane — arming is a per-node operator act, exactly
# like the RP-0012 rotate timer (C4c-2).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The MEASURE daemon is advisory (it only assembles + serves a rotate.PlanInput), but it is still a
#   long-running process the node would start on its own if the unit shipped enabled. The safety
#   contract is: the binary is built inertly (install_spine, where Go exists), and the SERVICE exists
#   only after a deliberate --measure-enable. This gate pins that so "built" can never drift into
#   "running" without an operator. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS
#   1. The unit string mycelium-measure.service appears ONLY in nb_measure.sh (the enable/disable path).
#   2. measure_enable is INVOKED only from the node-bootstrap dispatch case `measure-enable)`, never
#      from flow_bootstrap / flow_update / install_tooling / install_spine (no auto-arm).
#   3. install_spine BUILDS myceliumd (cmd/myceliumd) but contains no `systemctl enable/start` of the
#      measure service.
#   4. measure_enable is fail-closed: it requires the myceliumd binary AND both node-local configs.
#
# Exit: 0 = ships disabled / no auto-arm, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'measure_daemon_ships_disabled: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
MEASURE_LIB="$LIB/nb_measure.sh"
INSTALL_LIB="$LIB/nb_install.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== MEASURE daemon ships-disabled / no-auto-arm check (RP-0010 C5c) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

for f in "$MEASURE_LIB" "$INSTALL_LIB" "$NB"; do
	[ -f "$f" ] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 2; }
done
ok "nb_measure.sh / nb_install.sh / node-bootstrap.sh present"

# 1. the unit string lives ONLY in nb_measure.sh (in CODE — a doc mention in a #-comment is fine, e.g.
#    install_spine explaining why building the inert binary is safe, so strip comments first).
unit_hits=""
for f in "$LIB"/*.sh "$NB"; do
	case "$f" in */nb_measure.sh) continue ;; esac
	if sed 's/#.*$//' "$f" | grep -qE 'mycelium-measure\.service'; then
		unit_hits="$unit_hits ${f#"$REPO_ROOT"/}"
	fi
done
if [ -z "$unit_hits" ]; then
	ok "mycelium-measure.service is referenced (in code) only in nb_measure.sh (the enable/disable path)"
else
	badln "mycelium-measure.service referenced (in code) outside nb_measure.sh:$unit_hits"
fi

# 2. measure_enable is invoked ONLY from the dispatch case. Collect every line that CALLS measure_enable
#    (a bare word, not the function definition `measure_enable()` and not the --measure-enable arg-parse).
calls="$(grep -rnE '(^|[^A-Za-z0-9_])measure_enable([^A-Za-z0-9_(]|$)' "$LIB"/*.sh "$NB" 2>/dev/null \
	| grep -vE 'measure_enable\(\)' \
	| grep -vE '\-\-measure-enable\)' \
	| grep -vE '^\s*#' || true)"
# The only legitimate CALL site is the dispatch:  measure-enable)  measure_enable ;;
bad_calls="$(printf '%s\n' "$calls" | grep -vE 'measure-enable\)[[:space:]]*measure_enable' | grep -vE '^\s*$' || true)"
if [ -z "$bad_calls" ]; then
	ok "measure_enable is called only from the node-bootstrap measure-enable dispatch (no auto path arms it)"
else
	badln "measure_enable is invoked outside the dispatch (an auto path could arm the plane): $(printf '%s' "$bad_calls" | tr '\n' '|')"
fi

# 3. install_spine builds myceliumd but never enables/starts the measure service
if grep -qE './cmd/myceliumd' "$INSTALL_LIB"; then
	ok "install_spine builds myceliumd (cmd/myceliumd)"
else
	badln "install_spine does not build myceliumd (the daemon binary would be absent)"
fi
if grep -nE 'systemctl[[:space:]]+(enable|start)[^|]*mycelium-measure' "$INSTALL_LIB" >/dev/null 2>&1; then
	badln "install_spine enables/starts the measure service (it must build inertly, never start it)"
else
	ok "install_spine does NOT enable/start the measure service (built inert)"
fi

# 4. measure_enable is fail-closed: requires the binary + both configs
mfn="$(awk '/^measure_enable\(\)/{f=1} f{print} /^}/{if(f)exit}' "$MEASURE_LIB")"
printf '%s' "$mfn" | grep -qE '\[ -x "\$bin" \].*die'                 && ok "measure_enable requires the myceliumd binary (fail-closed)"        || badln "measure_enable does not fail-closed on a missing myceliumd binary"
printf '%s' "$mfn" | grep -qE '\[ -f "\$reach_cfg" \].*die'           && ok "measure_enable requires the reach config (fail-closed)"            || badln "measure_enable does not fail-closed on a missing reach config"
printf '%s' "$mfn" | grep -qE '\[ -f "\$measure_cfg" \].*die'         && ok "measure_enable requires the measure config (fail-closed)"          || badln "measure_enable does not fail-closed on a missing measure config"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the MEASURE daemon is built inertly and the unit ships disabled — no auto path can arm the advisory plane.\n'
	exit 0
fi
printf 'FAIL: the MEASURE daemon could be started without an explicit operator --measure-enable — see above.\n' >&2
exit 1
