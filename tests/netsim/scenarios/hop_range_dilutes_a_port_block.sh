#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# hop_range_dilutes_a_port_block.sh — netsim: what the hysteria2 hop range ACTUALLY buys, measured.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS FOUND, AND WHY THE FILE IS NAMED WHAT IT IS
#   The feature shipped on the claim that "a block on one UDP port no longer takes the family down".
#   That claim is FALSE as stated, and this scenario is what established it. sing-box's hysteria2 port
#   hopping moves on a TIMER; it does not avoid dead ports and has no signal that a port is dead. When
#   the hop lands on a blocked port the tunnel is down for that interval, and it comes back on the next
#   hop by luck, not by recovery.
#
#   Measured on a node, two points, 3s hop interval:
#     range of 3, 1 blocked  ->  6 failed samples of 24  (25%)
#     range of 11, 1 blocked ->  2 failed samples of 36  (6%)
#   i.e. the outage fraction tracks blocked/total. The range does not remove the outage. It DILUTES it.
#
#   That is a real benefit and a much weaker one than was claimed, and it inverts part of the guidance:
#   a WIDER range dilutes better, while also widening the observable port footprint (THREAT-MODEL). The
#   trade is explicit, not free, and it is now written down in both documents.
#
#   The second-order harm is worth stating because no metric on the node shows it: an intermittently
#   working member is not a cleanly dead one. A client's urltest group re-selects on health, and a member
#   that answers on most probes keeps its place in the group while delivering periodic gaps to the user.
#
# WHAT THE ROWS ASSERT
#   1. BASELINE — the tunnel carries bytes across the range.
#   2. DILUTION — with one port of three blocked, the tunnel is neither fully up nor fully down. Failing
#      "fully down" is the benefit; NOT failing on the presence of gaps is the honesty. If a future
#      sing-box learns to skip dead ports the gaps vanish, and this row says so loudly instead of
#      breaking — that would be an improvement, and the documents would then need revisiting.
#   3. CONTROL — with the whole range blocked the tunnel stops. Without it, every result above is equally
#      consistent with a client that ignores server_ports and dials the plain port.
#   4. RECOVERY — impairments cleared, the tunnel returns within the SLO.
#
# Exit: 0 = the range dilutes as measured; 1 = it does not; 2 = environment refused.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib.sh" || { printf 'netsim: cannot source lib.sh\n' >&2; exit 2; }

# A THREE-port range, deliberately. The claim is about the mechanism, and a narrow range makes the
# mechanism cheap to observe: one blocked port of three is exercised within a couple of hops, where one
# of eleven needs a long window to be visited at all. The first version of this scenario used eleven and
# reported "recovered in 0s" — a pass that meant the client had simply never landed on the dead port.
HOP_LO=20000
HOP_HI=20002
BLOCKED=20001
SERVED=8444
PASSWORD="netsim-TEST_ONLY-hy2"
SAMPLES=24
RECOVER_SLO=20

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  NOTE  %s\n' "$1"; }

printf '== netsim: what the hysteria2 hop range actually buys under a port block ==\n'

netsim_up
netsim_cert
netsim_origin

cat >"$NETSIM_ROOT/server.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "hysteria2", "tag": "hy2-in",
    "listen": "$IP_SRV", "listen_port": $SERVED,
    "users": [{"password": "$PASSWORD"}],
    "tls": {"enabled": true, "certificate_path": "$NETSIM_ROOT/cert.pem",
            "key_path": "$NETSIM_ROOT/key.pem", "alpn": ["h3"]}
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

# hop_interval is 3s here against the emitted production default, which is tuned so the hop is not
# itself a rhythm. A scenario needs several hops inside its window or it measures the wait.
cat >"$NETSIM_ROOT/client.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": $SOCKS_PORT}],
  "outbounds": [{
    "type": "hysteria2", "tag": "hy2",
    "server": "$IP_SRV", "server_port": $SERVED,
    "server_ports": ["$HOP_LO:$HOP_HI"], "hop_interval": "3s",
    "password": "$PASSWORD",
    "tls": {"enabled": true, "server_name": "netsim.invalid", "insecure": true, "alpn": ["h3"]}
  }]
}
EOF

netsim_singbox "$NS_SRV" "$NETSIM_ROOT/server.json" server

# THE PRODUCTION SHAPE: the inbound holds ONE port; a nat/PREROUTING REDIRECT delivers the range onto it.
ip netns exec "$NS_SRV" iptables -t nat -A PREROUTING -i "$VETH_S" -p udp \
	--dport "$HOP_LO:$HOP_HI" -j REDIRECT --to-ports "$SERVED" \
	|| ns_die "could not install the hop REDIRECT"
ns_log "REDIRECT installed: udp $HOP_LO:$HOP_HI -> $SERVED"

netsim_singbox "$NS_CLI" "$NETSIM_ROOT/client.json" client

# --- 1. baseline -------------------------------------------------------------------------------------
if netsim_fetch 8; then
	ok "baseline: the tunnel carries bytes across the hop range"
else
	bad "the tunnel does not work UNIMPAIRED — every row below would be meaningless"
	tail -5 "$NETSIM_ROOT/client.log" 2>/dev/null | sed 's/^/      /' >&2
	exit 1
fi

# --- 2. dilution -------------------------------------------------------------------------------------
netsim_drop_udp "$BLOCKED"
sleep 3
trace=""
misses=0
i=0
while [ "$i" -lt "$SAMPLES" ]; do
	if netsim_fetch 2; then trace="${trace}."; else trace="${trace}X"; misses=$((misses + 1)); fi
	i=$((i + 1))
	sleep 1
done
pct=$(( misses * 100 / SAMPLES ))
ns_log "trace (. = carried, X = gap): $trace"
ns_log "outage: $misses of $SAMPLES samples (${pct}%); 1 of 3 ports blocked"

if [ "$misses" -ge "$SAMPLES" ]; then
	bad "the tunnel was down for EVERY sample with one port of three blocked. The range then buys nothing at all: a client that cannot carry traffic while two of three ports are healthy is no better off than one pinned to a single port, and the wider observable port footprint (THREAT-MODEL) is paid for nothing."
elif [ "$misses" -eq 0 ]; then
	note "NO gaps at all. Measured behaviour was 25% gaps at this ratio when this scenario was written (sing-box hops on a timer and does not avoid dead ports). Zero means the client now SKIPS dead ports — a real improvement, and ARCHITECTURE.md + THREAT-MODEL.md must be revisited, because both currently describe dilution rather than immunity."
	ok "the tunnel carried every sample"
else
	ok "the range DILUTES the block: ${pct}% of samples gapped instead of 100% (the client hops on a timer and does not avoid the dead port; it is down while it sits there)"
fi

# --- 3. control --------------------------------------------------------------------------------------
netsim_clear
netsim_drop_udp "$HOP_LO:$HOP_HI"
sleep 4
if netsim_fetch 5; then
	bad "the tunnel STILL works with the WHOLE range blocked — so the client is not reaching the server through the range at all, and every measurement above describes the plain server_port. Nothing in this file means anything until this row fails."
else
	ok "control: the whole range blocked stops the tunnel (the measurements above were of the range)"
fi

# --- 4. recovery -------------------------------------------------------------------------------------
netsim_clear
if got="$(netsim_time_to_recover "$RECOVER_SLO")"; then
	ok "impairment cleared: the tunnel returns in ${got}s (SLO ${RECOVER_SLO}s)"
else
	bad "the tunnel never returned after the impairment was cleared — an operator would have to intervene on every transient block"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the hop range does not behave as measured and documented.\n' >&2
	exit 1
fi
printf 'PASS: the range dilutes a single-port block rather than removing it, and the control proves the range carried the traffic.\n'
exit 0
