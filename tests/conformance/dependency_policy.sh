#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# dependency_policy.sh — conformance: the dependency-currency policy is DECLARED and the version
# pins that the repo already carries are not BELOW the floors that policy declares.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   Maintenance currency is load-bearing for indistinguishability: an out-of-date engine handshake
#   is itself a detection signal. This gate makes the currency POLICY auditable in CI without ever
#   reaching the network. It is OFFLINE and INSPECT-ONLY: it reads tracked files and asserts a
#   self-consistency invariant. It deliberately does NOT enforce "is the pin the newest upstream
#   release" — that is deploy-time currency work (a separate, signed pin-bump change), not a CI
#   invariant, so this gate stays green between bumps.
#
# WHAT THIS CHECKS
#   1. POLICY ADR EXISTS. The dependency-currency policy ADR (0028) is present under docs/adr/.
#      This is the decision record that names the engines under currency management and the
#      version FLOORS below which a pin must never fall.
#   2. LANDSCAPE REFERENCE EXISTS + IS DATED. docs/reference/transport-technique-landscape.md is
#      present and carries at least one machine-readable freshness line ("last-verified:"). The
#      landscape doc is the evidence/watch-list annex; an undated arms-race annex is worse than
#      none, so the date line is mandatory (the gate checks the LINE EXISTS, never that the date
#      is recent — recency is the quarterly-sweep job, not a CI invariant).
#   3. FLOOR/PIN INTERNAL CONSISTENCY. For every floor the policy ADR DECLARES, every matching
#      version pin ALREADY PRESENT in the repo must be >= that floor. The gate flags a pin that
#      sits BELOW a documented floor; it NEVER invents a floor the repo does not declare, and a
#      component with no declared floor is reported as "no floor declared — skipped" (not failed).
#      Pins inspected (only those that exist today):
#        * node_exporter_version  in scripts/node-bootstrap.sh  (NODE_EXPORTER_VERSION="...")
#        * singbox_version / xray_version / node_exporter_version in the tracked Ansible
#          group_vars example (infra/ansible/group_vars/all.yml.example)
#      Floors are read from the policy ADR via a stable, greppable grammar (see FLOOR GRAMMAR).
#
# FLOOR GRAMMAR (what the policy ADR must contain for a floor to be enforced)
#   One floor per line, anywhere in docs/adr/0028-*.md, of the exact shape:
#       floor: <component> <version>
#   where <component> is one of: singbox xray node_exporter utls   (lowercase, underscore-safe)
#   and <version> is a dotted version, optionally v-prefixed, with a trailing ".x" wildcard
#   allowed on the LAST present component (e.g. "v1.11.x" means ">= 1.11.0"). Examples:
#       floor: singbox v1.11.x
#       floor: xray v26.2.4
#       floor: node_exporter 1.8.0
#   A component the ADR does not list this way has NO enforced floor (skipped, not failed). uTLS
#   has no in-repo version pin to compare against (it is transitive via the engine); a uTLS floor
#   line is accepted by the grammar and simply reported as "no in-repo pin to compare" so the ADR
#   can declare it for the human record without tripping the gate.
#
# OUT OF SCOPE (by design)
#   * The Aparecium-style live post-handshake probe is a LIVE, post-deploy check; it belongs in a
#     runbook against a deployed node, NOT in this offline gate.
#   * "Is the pin the latest upstream tag" — deploy-time currency, not a CI invariant.
#
# NEGATIVE TESTING
#   Set MYC_DEPPOLICY_SCAN_DIR to a directory that may contain either or both of:
#     * a file named  *.floors   — extra "floor: <component> <version>" lines (treated like the ADR)
#     * a file named  *.pins     — extra "<component>_version=<version>" lines (treated like a pin
#                                   source; one per line, '#'-comments + blanks ignored)
#   This lets a test force a below-floor pin (or a below-floor floor) and confirm the gate FAILS,
#   without editing any tracked file. The override dir is NOT gitignore-filtered.
#
# bash 3.2-safe: while-read only; no mapfile / readarray / timeout. OFFLINE; reads files only.
#
# Exit: 0 = policy declared and pins are consistent; 1 = a violation; 2 = environment error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

ADR_GLOB_DIR="$REPO_ROOT/docs/adr"
LANDSCAPE_DOC="$REPO_ROOT/docs/reference/transport-technique-landscape.md"
BOOTSTRAP="$REPO_ROOT/scripts/node-bootstrap.sh"
GROUP_VARS="$REPO_ROOT/infra/ansible/group_vars/all.yml.example"

fail=0
okln()   { printf '  ok    %s\n' "$1"; }
badln()  { printf '  FAIL  %s\n' "$1"; fail=1; }
noteln() { printf '  note  %s\n' "$1"; }

printf '== dependency-currency policy check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# --- 1. policy ADR (0028) exists -----------------------------------------------------------------
ADR_FILE=""
for f in "$ADR_GLOB_DIR"/0028-*.md; do
	[ -f "$f" ] || continue
	ADR_FILE="$f"
	break
done
if [ -n "$ADR_FILE" ]; then
	okln "dependency-currency policy ADR present: ${ADR_FILE#"$REPO_ROOT"/}"
else
	badln "no dependency-currency policy ADR found (expected docs/adr/0028-*.md)"
fi

# --- 2. landscape reference doc exists + carries a last-verified line -----------------------------
if [ -f "$LANDSCAPE_DOC" ]; then
	okln "landscape reference present: ${LANDSCAPE_DOC#"$REPO_ROOT"/}"
	if grep -qiE '^[[:space:]>*-]*last-verified:[[:space:]]*[^[:space:]]' "$LANDSCAPE_DOC" 2>/dev/null; then
		okln "landscape reference carries a last-verified: line"
	else
		badln "landscape reference has no 'last-verified:' line (an undated arms-race annex is not maintainable)"
	fi
else
	badln "landscape reference doc not found: ${LANDSCAPE_DOC#"$REPO_ROOT"/}"
fi

# --- version comparison helpers (pure bash 3.2; no sort -V dependency) ----------------------------
# normalise: strip a leading 'v', map a trailing '.x' wildcard component to '.0', keep digits/dots.
_ver_norm() {
	local v="$1"
	v="${v#[vV]}"
	v="${v%.x}"; v="${v%.X}"
	# keep only leading dotted-numeric run (drop any pre-release/build suffix)
	printf '%s' "$v" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/'
}

# _ver_ge A B  -> 0 (true) if version A >= version B, else 1. Compares component-by-component,
# missing components treated as 0. Pure integer arithmetic; bash 3.2-safe.
_ver_ge() {
	local a b ai bi i n
	a="$(_ver_norm "$1")"; b="$(_ver_norm "$2")"
	local IFS='.'
	# shellcheck disable=SC2206
	set -- $a; local -a A=("$@")
	set -- $b; local -a B=("$@")
	n=${#A[@]}; [ ${#B[@]} -gt "$n" ] && n=${#B[@]}
	i=0
	while [ "$i" -lt "$n" ]; do
		ai="${A[$i]:-0}"; bi="${B[$i]:-0}"
		# guard against non-numeric noise
		case "$ai" in ''|*[!0-9]*) ai=0 ;; esac
		case "$bi" in ''|*[!0-9]*) bi=0 ;; esac
		if [ "$ai" -gt "$bi" ]; then return 0; fi
		if [ "$ai" -lt "$bi" ]; then return 1; fi
		i=$((i + 1))
	done
	return 0   # all components equal => A >= B
}

# --- collect declared floors --------------------------------------------------------------------
# floors are accumulated as newline-delimited "<component> <version>" records in $FLOORS.
FLOORS=""
_collect_floors_from() {
	# _collect_floors_from FILE — append valid "floor: <component> <version>" lines.
	local file="$1" comp ver
	[ -f "$file" ] || return 0
	while IFS= read -r line; do
		case "$line" in
			*floor:*) : ;;
			*) continue ;;
		esac
		# parse "floor: <component> <version>" (tolerate leading markdown markers / whitespace)
		comp="$(printf '%s' "$line" | sed -E 's/.*floor:[[:space:]]*([a-z_]+)[[:space:]]+.*/\1/')"
		ver="$(printf '%s' "$line"  | sed -E 's/.*floor:[[:space:]]*[a-z_]+[[:space:]]+([vV]?[0-9][0-9.]*[xX]?).*/\1/')"
		case "$comp" in
			singbox|xray|node_exporter|utls) : ;;
			*) continue ;;
		esac
		[ -n "$ver" ] || continue
		case "$ver" in *[0-9]*) : ;; *) continue ;; esac
		FLOORS="$FLOORS$comp $ver
"
	done < "$file"
}

[ -n "$ADR_FILE" ] && _collect_floors_from "$ADR_FILE"

# Optional negative-test floor fixtures.
if [ -n "${MYC_DEPPOLICY_SCAN_DIR:-}" ] && [ -d "${MYC_DEPPOLICY_SCAN_DIR}" ]; then
	printf 'extra scan dir: %s\n' "$MYC_DEPPOLICY_SCAN_DIR"
	while IFS= read -r ff; do
		[ -n "$ff" ] || continue
		_collect_floors_from "$ff"
	done <<EOF
$(find "$MYC_DEPPOLICY_SCAN_DIR" -type f -name '*.floors' 2>/dev/null)
EOF
fi

# _floor_for COMPONENT -> echo the STRICTEST (highest) declared floor version, or empty. Picking the
# max (not the first) means a later/extra floor line — e.g. a negative-test *.floors fixture appended
# after the ADR floors — correctly overrides a laxer ADR floor for the same component.
_floor_for() {
	local want="$1" c v best=""
	while IFS=' ' read -r c v; do
		[ -n "$c" ] || continue
		[ "$c" = "$want" ] || continue
		if [ -z "$best" ]; then
			best="$v"
		elif _ver_ge "$v" "$best"; then
			best="$v"
		fi
	done <<EOF
$FLOORS
EOF
	[ -n "$best" ] && printf '%s\n' "$best"
	return 0
}

# --- collect pins that ACTUALLY exist in the repo -----------------------------------------------
# pins accumulated as newline-delimited "<component> <version> <source>" records in $PINS.
PINS=""
_add_pin() {
	# _add_pin COMPONENT VERSION SOURCE
	[ -n "${2:-}" ] || return 0
	PINS="$PINS$1 $2 $3
"
}

# node-bootstrap.sh — NODE_EXPORTER_VERSION="x.y.z"
if [ -f "$BOOTSTRAP" ]; then
	v="$(grep -E '^[[:space:]]*NODE_EXPORTER_VERSION=' "$BOOTSTRAP" 2>/dev/null \
		| head -n1 | sed -E 's/.*NODE_EXPORTER_VERSION=["'"'"']?([^"'"'"']+)["'"'"']?.*/\1/')"
	_add_pin node_exporter "$v" "scripts/node-bootstrap.sh"
fi

# tracked Ansible group_vars example — singbox_version / xray_version / node_exporter_version
if [ -f "$GROUP_VARS" ]; then
	for key in singbox xray node_exporter; do
		v="$(grep -E "^[[:space:]]*${key}_version:" "$GROUP_VARS" 2>/dev/null \
			| head -n1 | sed -E 's/.*:[[:space:]]*["'"'"']?([^"'"'"'[:space:]]+)["'"'"']?.*/\1/')"
		_add_pin "$key" "$v" "infra/ansible/group_vars/all.yml.example"
	done
fi

# Optional negative-test pin fixtures: lines of "<component>_version=<version>".
if [ -n "${MYC_DEPPOLICY_SCAN_DIR:-}" ] && [ -d "${MYC_DEPPOLICY_SCAN_DIR}" ]; then
	while IFS= read -r pf; do
		[ -n "$pf" ] || continue
		while IFS= read -r line; do
			case "$line" in ''|\#*) continue ;; esac
			comp="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([a-z_]+)_version=.*/\1/')"
			ver="$(printf '%s'  "$line" | sed -E 's/^[[:space:]]*[a-z_]+_version=["'"'"']?([^"'"'"'[:space:]]+).*/\1/')"
			case "$comp" in singbox|xray|node_exporter|utls) : ;; *) continue ;; esac
			_add_pin "$comp" "$ver" "${pf#"$MYC_DEPPOLICY_SCAN_DIR"/} (fixture)"
		done < "$pf"
	done <<EOF
$(find "$MYC_DEPPOLICY_SCAN_DIR" -type f -name '*.pins' 2>/dev/null)
EOF
fi

# --- 3. floor/pin internal consistency ----------------------------------------------------------
printf '\n-- floor vs pin --\n'
checked=0
while IFS=' ' read -r comp ver src; do
	[ -n "$comp" ] || continue
	[ -n "$ver" ]  || continue
	floor="$(_floor_for "$comp")"
	if [ -z "$floor" ]; then
		noteln "$comp pin $ver ($src): no floor declared in the policy ADR — skipped"
		continue
	fi
	checked=$((checked + 1))
	if _ver_ge "$ver" "$floor"; then
		okln "$comp pin $ver >= declared floor $floor ($src)"
	else
		badln "$comp pin $ver is BELOW the declared floor $floor ($src) — bump the pin or correct the floor"
	fi
done <<EOF
$PINS
EOF

# A declared floor for a component with NO in-repo pin (e.g. utls) is informational, not a failure.
while IFS=' ' read -r fcomp fver; do
	[ -n "$fcomp" ] || continue
	have_pin=0
	while IFS=' ' read -r pcomp _pv _ps; do
		[ "$pcomp" = "$fcomp" ] && have_pin=1
	done <<EOF
$PINS
EOF
	[ "$have_pin" -eq 0 ] && noteln "floor declared for $fcomp ($fver) but no in-repo pin to compare — recorded for the human policy only"
done <<EOF
$FLOORS
EOF

[ "$checked" -eq 0 ] && noteln "no (floor, pin) pair to compare — the gate still enforces checks 1 and 2"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: dependency-currency policy is missing/undated, or a declared version pin sits below a\n' >&2
	printf '      documented floor. Add docs/adr/0028-*.md + docs/reference/transport-technique-landscape.md\n' >&2
	printf '      (with a last-verified: line), and keep every pin >= its declared floor.\n' >&2
	exit 1
fi
printf 'PASS: policy ADR + dated landscape reference present; every declared pin is at/above its floor.\n'
exit 0

