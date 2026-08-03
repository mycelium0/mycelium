#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_served_port_is_real.sh — conformance: the AmneziaWG port the node opens in its firewall is the port
# AmneziaWG is actually served on, not a remembered default. EXECUTED over a value table.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   $STATE_DIR/awg.port exists so the firewall step knows which UDP port to admit. It was written once,
#   at bootstrap, with the canonical default — never with the port the node ended up using. Measured on
#   the live nodes:
#     m1  marker ABSENT        awg0.conf ListenPort 443   -> the firewall's AWG branch never fired at all
#     m2  marker says 51820    awg0.conf ListenPort 443   -> ufw admits 51820/udp; nothing listens there
#     m4  marker says 51820    awg0.conf ListenPort 443   -> the same
#
#   Two of three nodes therefore held open a UDP port with no service behind it, and neither admitted the
#   real port on AmneziaWG's account. That is worse than a wasted rule: 51820 is the WireGuard default, so
#   a host with it open and SILENT, while the tunnel runs elsewhere, announces "there is WireGuard here"
#   without serving it — a distinguishing mark on a node whose entire design is to carry none.
#
#   The defect is a shape, not a typo: a cache that records what the value was ASSUMED to be rather than
#   what it IS. The live config is the authority; the marker is a cache of it, and a cache that disagrees
#   with its source is worse than no cache, because everything downstream trusts it.
#
# WHAT IT CHECKS, by running the real resolver over a throwaway node root
#   1. The live config wins over the marker, whatever the marker says.
#   2. The marker is CORRECTED to match, so the next pass is right even if the config is unreadable.
#   3. With no config, a present marker is honoured (the cache is still useful).
#   4. With neither, the canonical default is used and recorded.
#   5. A malformed port in either place never propagates.
#
# OFFLINE. No root. Nothing outside its own mktemp root.
# Exit: 0 = the resolved port always matches what is served; 1 = it does not; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'awg_served_port_is_real: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_render_awg.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
for f in "$LIB" "$FIXTURE"; do
	[ -f "$f" ] || { printf 'awg_served_port_is_real: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== AmneziaWG: is the port we open the port we serve ==\n'

log()  { :; }
warn() { :; }
die()  { printf 'lib: %s\n' "$*" >&2; exit 1; }
run()  { "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB" || { printf 'FAIL: could not source %s\n' "$LIB" >&2; exit 2; }

# row LABEL  CONF_PORT_OR_NONE  MARKER_OR_NONE  WANT_PORT
row() {
	local label="$1" confport="$2" marker="$3" want="$4"
	(
		set -u
		fail=0
		fakenode_init
		MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"; export MYC_AWG_CONF
		if [ "$confport" != "none" ]; then
			printf '[Interface]\nPrivateKey = S\nAddress = 10.13.13.1/24\nListenPort = %s\n' "$confport" >"$MYC_AWG_CONF"
		fi
		[ "$marker" != "none" ] && printf '%s\n' "$marker" >"$STATE_DIR/awg.port"

		got="$(_awg_resolve_port)"
		[ "$got" = "$want" ] \
			&& ok "$label: resolved $got" \
			|| badln "$label: resolved '$got', expected '$want'. Whatever this returns is the port the firewall opens; when it disagrees with the served config the node holds a silent port open and leaves the real one unadmitted on this transport's account."

		cached="$(cat "$STATE_DIR/awg.port" 2>/dev/null || printf 'none')"
		[ "$cached" = "$want" ] \
			&& ok "$label: the marker was corrected to $cached" \
			|| badln "$label: the marker still reads '$cached' after resolving '$want'. A cache that keeps disagreeing with its source will be trusted by the next pass that cannot read the source."
		exit "$fail"
	) || fail=1
}

row "live config wins over a WRONG marker (the live m2/m4 state)" 443   51820 443
row "live config wins over an ABSENT marker (the live m1 state)"  443   none  443
row "no config: a present marker is honoured"                     none  8443  8443
row "neither: the canonical default, and it is recorded"          none  none  51820
row "a malformed marker never propagates"                         none  "abc" 51820
row "a malformed ListenPort falls through to the marker"          "" 8444 8444

# The idempotency of the resolver itself: a second call must not move the answer.
(
	set -u
	fail=0
	fakenode_init
	MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"; export MYC_AWG_CONF
	printf '[Interface]\nPrivateKey = S\nListenPort = 443\n' >"$MYC_AWG_CONF"
	a="$(_awg_resolve_port)"; b="$(_awg_resolve_port)"; c="$(_awg_resolve_port)"
	[ "$a" = "$b" ] && [ "$b" = "$c" ] \
		&& ok "repeated resolution is stable ($a)" \
		|| badln "the resolver returned $a then $b then $c — the firewall would chase a moving answer"
	exit "$fail"
) || fail=1

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the node would open a UDP port other than the one AmneziaWG is served on.\n' >&2
	exit 1
fi
printf 'PASS: the resolved port always follows the served config, and the marker is kept honest.\n'
exit 0
