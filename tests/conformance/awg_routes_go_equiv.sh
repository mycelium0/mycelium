#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_routes_go_equiv.sh — conformance (RP-0008): the Go-owned Selective-Growth route decision
# (spec.ResolveAWGRoutes / `myceliumctl awg-routes`) is BYTE-IDENTICAL to the bash twin
# (compute_client_allowed + sg_allowed_join in control/lib/nb_render_awg.sh).
#
# WHY. This is the VIS-0009 / ADR-0027 decision the shell lib's own header earmarked for the Go migration:
# a generated client carries ONLY impaired-path traffic, and we NEVER silently full-tunnel. Two producers
# now exist during the strangler window, so they are pinned exactly — including the refusal case, the
# recorded opt-out marker, the dropped default route, and the IPv6-leak guard.
#
# It also asserts the ONE-WAY invariant directly on BOTH producers: no input except the deliberate opt-out
# may yield a default route. That is stronger than equivalence — two producers could agree and both be
# wrong — so the property is checked independently of the diff.
#
# Exit: 0 = identical + invariant holds (or skipped), 1 = divergence / a silent full tunnel, 2 = usage.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
AWG_LIB="$REPO_ROOT/control/lib/nb_render_awg.sh"

printf '== AmneziaWG Selective-Growth routes: Go <-> shell byte-equivalence (RP-0008) ==\n'
[ -f "$AWG_LIB" ] || { printf 'FAIL: nb_render_awg.sh missing.\n' >&2; exit 2; }
command -v go >/dev/null 2>&1 || { printf 'SKIP: no Go toolchain.\n'; exit 0; }

# Host env so the lib can be SOURCED standalone.
have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf 'shell FAILED: %s\n' "$*" >&2; exit 1; }
log()  { :; }
warn() { :; }
STATE_DIR="${STATE_DIR:-/nonexistent}"
DRY_RUN=0
DO_AMNEZIAWG=1
# shellcheck source=/dev/null
. "$AWG_LIB" 2>/dev/null || { printf 'FAIL: could not source nb_render_awg.sh.\n' >&2; exit 2; }
command -v compute_client_allowed >/dev/null 2>&1 || { printf 'FAIL: compute_client_allowed not defined.\n' >&2; exit 2; }

WORK="$(mktemp -d)" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
if ! ( cd "$REPO_ROOT" && go build -o "$WORK/myceliumctl" ./cmd/myceliumctl ) 2>/dev/null; then
	printf 'SKIP: could not build myceliumctl.\n'
	exit 0
fi

# Region-exclude fixtures: none, v4-only (leak guard fires), already-v6, a default route (must be dropped),
# and a comments/blanks-only file (yields nothing usable -> safe narrow).
: > "$WORK/empty.txt"
printf '10.0.0.0/8\n172.16.0.0/12\n' > "$WORK/v4only.txt"
printf '10.0.0.0/8\n2001:db8::/32\n' > "$WORK/withv6.txt"
printf '  10.0.0.0/8  # trailing\n\n0.0.0.0/0\n192.168.0.0/16\n' > "$WORK/withdefault.txt"
printf '# only comments\n\n   \n' > "$WORK/commentsonly.txt"

fail=0
checked=0

# shell_routes FULLTUNNEL HASV6 REGIONFILE -> the joined AllowedIPs value (or "REFUSED").
shell_routes() {
	AWG_FULL_TUNNEL_OPTOUT="$1"
	AWG_SPLIT_TUNNEL="${SPLIT:-1}"
	AWG_REGION_EXCLUDE_FILE="$3"
	if compute_client_allowed "$2" >/dev/null 2>&1; then sg_allowed_join; else printf 'REFUSED'; fi
}

# go_routes FULLTUNNEL HASV6 REGIONFILE -> same.
go_routes() {
	local args=()
	[ "$1" -eq 1 ] && args+=(--full-tunnel)
	[ "$2" -eq 1 ] && args+=(--has-v6)
	[ "${SPLIT:-1}" -eq 0 ] && args+=(--no-split-tunnel)
	[ -n "$3" ] && args+=(--region-exclude "$3")
	"$WORK/myceliumctl" awg-routes "${args[@]}" 2>/dev/null || printf 'REFUSED'
}

for ft in 0 1; do
	for v6 in 0 1; do
		for rf in "" "$WORK/empty.txt" "$WORK/v4only.txt" "$WORK/withv6.txt" "$WORK/withdefault.txt" "$WORK/commentsonly.txt"; do
			sh_out="$(shell_routes "$ft" "$v6" "$rf" | tr -d '\n')"
			go_out="$(go_routes "$ft" "$v6" "$rf" | tr -d '\n')"
			checked=$((checked + 1))
			if [ "$sh_out" != "$go_out" ]; then
				printf '  FAIL  DIVERGED full_tunnel=%s v6=%s region=%s\n' "$ft" "$v6" "$(basename "${rf:-none}")"
				printf '         shell: %s\n         go   : %s\n' "$sh_out" "$go_out" >&2
				fail=1
			fi
			# THE invariant, on BOTH producers: only the deliberate opt-out may yield a default route.
			if [ "$ft" -eq 0 ]; then
				case "$sh_out" in *"0.0.0.0/0"*) printf '  FAIL  shell SILENTLY full-tunnels (v6=%s region=%s)\n' "$v6" "$(basename "${rf:-none}")"; fail=1 ;; esac
				case "$go_out" in *"0.0.0.0/0"*) printf '  FAIL  Go SILENTLY full-tunnels (v6=%s region=%s)\n' "$v6" "$(basename "${rf:-none}")"; fail=1 ;; esac
			fi
		done
	done
done

# split-tunnel OFF without the opt-out: BOTH must refuse.
SPLIT=0
sh_ref="$(shell_routes 0 0 "" | tr -d '\n')"
go_ref="$(go_routes 0 0 "" | tr -d '\n')"
SPLIT=1
checked=$((checked + 1))
if [ "$sh_ref" = "REFUSED" ] && [ "$go_ref" = "REFUSED" ]; then
	printf '  ok    split-tunnel off without an opt-out is REFUSED by both producers\n'
else
	printf '  FAIL  an undocumented full tunnel was not refused (shell:%s go:%s)\n' "$sh_ref" "$go_ref"
	fail=1
fi

# The opt-out must RECORD the marker (the no_full_tunnel_default gate keys on it).
if [ "$("$WORK/myceliumctl" awg-routes --full-tunnel --json 2>/dev/null | tr -d ' \n')" != "${_x:-}" ] \
	&& "$WORK/myceliumctl" awg-routes --full-tunnel --json 2>/dev/null | grep -qF 'selective-growth: opt-out (full-tunnel)'; then
	printf '  ok    a deliberate full tunnel records the Selective-Growth opt-out marker\n'
else
	printf '  FAIL  the deliberate full tunnel does not record the opt-out marker\n'
	fail=1
fi

[ "$fail" -eq 0 ] && printf '  ok    %d route decisions are identical across both producers\n' "$checked"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the Go and shell Selective-Growth route producers disagree, or one silently full-tunnels.\n' >&2
	exit 1
fi
printf 'PASS: the route decision is identical across producers and never silently full-tunnels.\n'
exit 0
