#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# engine_manifest_additive.sh — conformance (RP-0011 chunk C-2): the engine-manifest read in
# install_singbox / install_xray is ADDITIVE and FAIL-CLOSED. For each installer it asserts:
#   1. the manifest fill calls manifest_engine_pins <engine>;
#   2. the fill is GUARDED on an ABSENT pin ([ -z "$X_VERSION" ] || [ -z "$X_SHA256" ]) — an explicit
#      operator flag is never overwritten, so a flag-passing caller is byte-identical;
#   3. the fail-closed pin die ([ -n "$X_VERSION" ] || die ...) is STILL PRESENT, and the fill sits
#      BEFORE it — so an unfillable pin (no manifest / uncovered arch) still fails closed;
#   4. nb_engine_manifest is sourced in lockstep — present in BOTH the node-bootstrap `for _lib in …`
#      loop AND the node_update_artifact_root NB_LIBS list (else the --update re-exec can't resolve it).
# OFFLINE + INSPECT-ONLY (the runtime additive/byte-identity behaviour is proven by the m1 drill).
#
# Exit: 0 = additive + fail-closed + sourced in lockstep, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'engine_manifest_additive: cannot resolve repo root\n' >&2; exit 2; }
NBI="$REPO_ROOT/control/lib/nb_install.sh"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
ART="$REPO_ROOT/tests/conformance/node_update_artifact_root.sh"
for f in "$NBI" "$NB" "$ART"; do [ -f "$f" ] || { printf 'engine_manifest_additive: missing %s\n' "$f" >&2; exit 2; }; done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== engine-manifest read is additive + fail-closed (RP-0011 C-2) ==\n'

# extract a function body
fnbody() { awk -v fn="$1" 'index($0, fn"()")==1 {f=1} f{print} /^}/{if(f) exit}' "$NBI"; }

check_installer() { # <fn> <engine> <VERVAR> <SHAVAR>
	local fn="$1" engine="$2" ver="$3" sha="$4" body
	body="$(fnbody "$fn")"
	[ -n "$body" ] || { badln "$fn not found in nb_install.sh"; return; }
	printf '%s' "$body" | grep -q "manifest_engine_pins $engine" \
		&& ok "$fn fills from manifest_engine_pins $engine" \
		|| badln "$fn does not call manifest_engine_pins $engine"
	printf '%s' "$body" | grep -qE "\[ -z \"\\\$$ver\" \] \|\| \[ -z \"\\\$$sha\" \]" \
		&& ok "$fn fill is guarded on an ABSENT pin (additive — explicit flag wins)" \
		|| badln "$fn manifest fill is not guarded on [ -z \$$ver ] || [ -z \$$sha ] (could overwrite an operator flag)"
	printf '%s' "$body" | grep -qE "\[ -n \"\\\$$ver\" \] +\|\| +die" \
		&& ok "$fn keeps the fail-closed pin die after the fill" \
		|| badln "$fn lost its fail-closed [ -n \$$ver ] || die guard"
	# ordering: the manifest_engine_pins call must appear BEFORE the die (fill, then fail-closed check)
	local fill_ln die_ln
	fill_ln="$(printf '%s\n' "$body" | grep -nE "manifest_engine_pins $engine" | head -1 | cut -d: -f1)"
	die_ln="$(printf '%s\n' "$body" | grep -nE "\[ -n \"\\\$$ver\" \] +\|\| +die" | head -1 | cut -d: -f1)"
	if [ -n "$fill_ln" ] && [ -n "$die_ln" ] && [ "$fill_ln" -lt "$die_ln" ]; then
		ok "$fn fills BEFORE the fail-closed die (a manifest pin satisfies it)"
	else
		badln "$fn fill does not precede the die (line $fill_ln vs $die_ln)"
	fi
}

check_installer install_singbox singbox SINGBOX_VERSION SINGBOX_SHA256
check_installer install_xray    xray    XRAY_VERSION    XRAY_SHA256

# lockstep sourcing
grep -qE '^for _lib in .*\bnb_engine_manifest\b' "$NB" \
	&& ok "nb_engine_manifest is in the node-bootstrap lib-sourcing loop" \
	|| badln "nb_engine_manifest missing from the node-bootstrap 'for _lib in …' loop"
grep -qE '^NB_LIBS=".*\bnb_engine_manifest\b' "$ART" \
	&& ok "nb_engine_manifest is in node_update_artifact_root NB_LIBS (lockstep)" \
	|| badln "nb_engine_manifest missing from node_update_artifact_root NB_LIBS — the --update re-exec would fail to source it"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the manifest read fills only absent pins, before a still-present fail-closed die, sourced in lockstep.\n'
	exit 0
fi
printf 'FAIL: the engine-manifest read is not additive/fail-closed.\n' >&2
exit 1
