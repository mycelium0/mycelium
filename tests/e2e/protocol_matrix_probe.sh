#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# protocol_matrix_probe.sh — run a real client against EVERY served protocol of a target node, one at a
# time, from OFF the target host, and report which of them actually carry traffic.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS EXISTS
#   The node-local L7 probe answers "is my own listener completing a handshake when I dial it over
#   loopback". That is a genuinely useful signal and it is NOT the question an operator asks, which is
#   "do my transports work". Loopback cannot see a firewall, a wrong advertised address, an MTU problem,
#   a UDP path that the host's own stack short-circuits, or a credential that only the server half agrees
#   with. Exactly one of those bit us: a node advertised an address belonging to a different machine
#   entirely for weeks while every node-local probe reported six of six alive, because the probe never
#   used the address it publishes.
#
#   The existing client harness (gen_client_config.sh + client_recovery_probe.sh) is the right shape but
#   answers a different question: it routes through the `auto` urltest group and measures FAILOVER. A
#   group that fails over is exactly what hides a broken member. This pins ONE outbound at a time.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT
#   Per protocol, a stock-equivalent sing-box client dials the target USING THE ADDRESS AND CREDENTIALS
#   THE TARGET PUBLISHES, and a real HTTPS request completes through it. So it proves the served
#   endpoint, the advertised address, the credential, the firewall and the path between these two hosts
#   all agree.
#
#   It does not prove reachability from an arbitrary access network. The vantage is one operator-owned
#   host reaching another; a transport that works here can still fail on a path neither host is on.
#   That limit is structural (VIS-0006 §1) and no amount of this fixes it.
#
# USAGE (run ON the client host, with the TARGET's subscription fragment copied over)
#   protocol_matrix_probe.sh --fragment TARGET.singbox.json [--label m2] [--port-base 18800]
#                            [--url https://www.gstatic.com/generate_204] [--timeout 12] [--json OUT]
#
# READ-ONLY on the target: it dials published endpoints as any client would. On the CLIENT host it runs
# one short-lived sing-box per protocol, bound to loopback, and always reaps it.
#
# Exit: 0 = every protocol carried traffic, 1 = at least one did not, 2 = usage/env error.

set -uo pipefail

FRAG="" LABEL="target" PORT_BASE=18800 URL="https://www.gstatic.com/generate_204" TMO=12 JSON_OUT=""
SB="${SINGBOX_BIN:-sing-box}"

usage() { sed -n '/^# USAGE/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--fragment)  FRAG="${2:?--fragment needs a path}"; shift 2 ;;
		--label)     LABEL="${2:?}"; shift 2 ;;
		--port-base) PORT_BASE="${2:?}"; shift 2 ;;
		--url)       URL="${2:?}"; shift 2 ;;
		--timeout)   TMO="${2:?}"; shift 2 ;;
		--json)      JSON_OUT="${2:?}"; shift 2 ;;
		-h|--help)   usage; exit 0 ;;
		*) printf 'protocol_matrix_probe: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done
[ -n "$FRAG" ] || { usage >&2; exit 2; }
[ -f "$FRAG" ] || { printf 'protocol_matrix_probe: fragment not found: %s\n' "$FRAG" >&2; exit 2; }
for b in "$SB" curl jq; do command -v "$b" >/dev/null 2>&1 || { printf 'protocol_matrix_probe: %s required\n' "$b" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.protomatrix.XXXXXX")" || exit 2
CHILD=""
cleanup() { [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The dialable outbounds. selector/urltest are groups, direct/block are terminals, and
# `shadowtls-handshake` is the inner half of the ShadowTLS pair — it is dialed THROUGH its shadowsocks
# partner, never as an endpoint of its own, so pinning it would test nothing.
mapfile -t TAGS < <(jq -r '[.outbounds[]?
	| select((.type|test("selector|urltest|direct|block"))|not)
	| select(.tag != "shadowtls-handshake")
	| .tag] | .[]' "$FRAG" 2>/dev/null)
[ "${#TAGS[@]}" -gt 0 ] || { printf 'protocol_matrix_probe: no dialable outbound in %s\n' "$FRAG" >&2; exit 2; }

printf '== protocol matrix: a real client -> %s, one protocol at a time ==\n' "$LABEL"
printf 'client host: %s   target fragment: %s   probe: %s\n\n' "$(uname -n)" "$(basename "$FRAG")" "$URL"

fail=0 i=0 results=""
for tag in "${TAGS[@]}"; do
	port=$(( PORT_BASE + i )); i=$(( i + 1 ))
	cfg="$WORK/cli.$tag.json"
	# Route EVERYTHING at this one outbound: no group, no fallback, so a failure is attributable.
	jq --arg t "$tag" --argjson p "$port" '{
		log: { level: "error" },
		inbounds: [ { type: "mixed", listen: "127.0.0.1", listen_port: $p } ],
		outbounds: [ .outbounds[]? | select((.type|test("selector|urltest"))|not) ],
		route: { final: $t }
	}' "$FRAG" >"$cfg" 2>/dev/null

	if ! "$SB" check -c "$cfg" >"$WORK/check.$tag" 2>&1; then
		printf '  FAIL  %-22s the client config does not even validate: %s\n' "$tag" "$(head -1 "$WORK/check.$tag")"
		results="$results{\"protocol\":\"$tag\",\"ok\":false,\"stage\":\"config\"},"
		fail=1; continue
	fi

	"$SB" run -c "$cfg" >"$WORK/run.$tag" 2>&1 &
	CHILD=$!
	# Give the client a moment to bind; poll rather than sleeping blind.
	for _ in 1 2 3 4 5 6 7 8; do
		curl -s -o /dev/null --max-time 1 --proxy "socks5h://127.0.0.1:$port" http://127.0.0.1:1 2>/dev/null
		[ -S /proc/net/tcp ] 2>/dev/null || true
		sleep 0.5
		grep -q . "$WORK/run.$tag" 2>/dev/null && break
		break
	done
	sleep 2
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TMO" \
		--proxy "socks5h://127.0.0.1:$port" "$URL" 2>/dev/null)"
	kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; CHILD=""

	case "$code" in
		2*)
			printf '  ok    %-22s HTTP %s — traffic flows end to end\n' "$tag" "$code"
			results="$results{\"protocol\":\"$tag\",\"ok\":true,\"http\":\"$code\"}," ;;
		*)
			printf '  FAIL  %-22s no traffic (HTTP %s). Client log: %s\n' "$tag" "${code:-none}" \
				"$(grep -iE 'error|fail|refused|timeout' "$WORK/run.$tag" 2>/dev/null | head -1 | cut -c1-140)"
			results="$results{\"protocol\":\"$tag\",\"ok\":false,\"http\":\"${code:-}\",\"stage\":\"traffic\"},"
			fail=1 ;;
	esac
done

if [ -n "$JSON_OUT" ]; then
	printf '{"target":"%s","client":"%s","url":"%s","results":[%s]}\n' \
		"$LABEL" "$(uname -n)" "$URL" "${results%,}" >"$JSON_OUT"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: at least one served protocol of %s did not carry traffic from this vantage.\n' "$LABEL" >&2
	exit 1
fi
printf 'PASS: every dialable protocol of %s carried real traffic from an off-host client.\n' "$LABEL"
exit 0
