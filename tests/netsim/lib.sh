#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# lib.sh — the netsim fixture: two isolated network namespaces joined by a veth pair, a REAL sing-box on
# each side, and the impairment primitives development.md §7.3 calls for (netem loss/delay/rate,
# iptables DROP, TCP RST injection).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS EXISTS
#   development.md §7.3 makes network-condition simulation mandatory for the adaptation layer, and §14.3
#   makes it mandatory for ANY change to the detector or the rotation loop. Until now the project had
#   none: the loop's behaviour was covered by pure Go tests over synthesised verdicts, which prove the
#   DECISION FUNCTION and prove nothing about the wire. A transport that cannot actually carry traffic
#   under an impairment is not something a verdict table can discover.
#
# WHY NAMESPACES AND NOT THE NODE
#   These scenarios DROP packets and inject RSTs. Run against the host they would cut the live data
#   plane. Everything here lives inside two throwaway `ip netns` with a private /24 and NO route to the
#   outside: the fixture refuses to start if it cannot establish that isolation, and it tears the
#   namespaces down on every exit path. Nothing it does can reach a real client.
#
# WHAT IS REAL HERE
#   Real sing-box server and client processes, real UDP/QUIC and TCP sockets, real netem, real iptables.
#   The HTTP origin the tunnel carries traffic to also lives inside the server namespace, so a scenario
#   never depends on the internet and never leaves the fixture.
#
# REQUIREMENTS: Linux, root, ip/tc/iptables/sing-box/openssl/python3. Refuses (exit 2), never pretends.

set -uo pipefail

NS_SRV="mycnetsim-srv"
NS_CLI="mycnetsim-cli"
IP_SRV="10.77.77.1"
IP_CLI="10.77.77.2"
PFX="24"
VETH_S="ns-veth-s"
VETH_C="ns-veth-c"
ORIGIN_PORT=8080
SOCKS_PORT=10808

NETSIM_ROOT=""
NETSIM_STARTED=0

ns_die() { printf 'netsim: %s\n' "$*" >&2; exit 2; }
ns_log() { printf '  · %s\n' "$*"; }

# netsim_require — every precondition, checked before anything is created. A scenario that silently
# skips a requirement is worse than one that refuses: it reports success for work it did not do.
netsim_require() {
	[ "$(uname -s)" = "Linux" ] || ns_die "Linux only (this host is $(uname -s)); §7.5 runs this on a node."
	[ "$(id -u)" = "0" ] || ns_die "root required (network namespaces + tc + iptables)."
	local t
	for t in ip tc iptables sing-box openssl python3 curl; do
		command -v "$t" >/dev/null 2>&1 || ns_die "missing tool: $t"
	done
	ip netns list >/dev/null 2>&1 || ns_die "'ip netns' unavailable."
}

# netsim_up — build the isolated pair. Refuses if either namespace already exists, so a previous run
# that died mid-way is a loud failure rather than a silently reused, half-configured environment.
netsim_up() {
	netsim_require
	local n
	for n in "$NS_SRV" "$NS_CLI"; do
		ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$n" \
			&& ns_die "namespace '$n' already exists — a previous run did not clean up. Remove it with 'ip netns del $n' after checking nothing is using it."
	done
	NETSIM_ROOT="$(mktemp -d /tmp/myc.netsim.XXXXXX)" || ns_die "mktemp failed"
	trap 'netsim_down' EXIT INT TERM
	NETSIM_STARTED=1

	ip netns add "$NS_SRV" || ns_die "ip netns add $NS_SRV"
	ip netns add "$NS_CLI" || ns_die "ip netns add $NS_CLI"
	ip link add "$VETH_S" type veth peer name "$VETH_C" || ns_die "veth pair"
	ip link set "$VETH_S" netns "$NS_SRV" || ns_die "move $VETH_S"
	ip link set "$VETH_C" netns "$NS_CLI" || ns_die "move $VETH_C"

	ip netns exec "$NS_SRV" ip addr add "$IP_SRV/$PFX" dev "$VETH_S"
	ip netns exec "$NS_SRV" ip link set "$VETH_S" up
	ip netns exec "$NS_SRV" ip link set lo up
	ip netns exec "$NS_CLI" ip addr add "$IP_CLI/$PFX" dev "$VETH_C"
	ip netns exec "$NS_CLI" ip link set "$VETH_C" up
	ip netns exec "$NS_CLI" ip link set lo up

	# THE ISOLATION ASSERTION, before a single packet is impaired. A namespace that inherited a default
	# route would let a scenario's DROP rules and its traffic reach the real network — and the whole
	# safety argument for running this on a live node is that they cannot.
	local routes
	routes="$(ip netns exec "$NS_CLI" ip route show default 2>/dev/null)"
	[ -z "$routes" ] || ns_die "REFUSING: the client namespace has a default route ('$routes'). These scenarios DROP packets and inject RSTs; they must not be able to reach anything outside the fixture."
	ip netns exec "$NS_CLI" ping -c1 -W1 "$IP_SRV" >/dev/null 2>&1 \
		|| ns_die "the namespaces cannot reach each other over the veth — the fixture is not usable."
	ns_log "namespaces up, isolated, veth reachable ($IP_CLI -> $IP_SRV)"
}

netsim_down() {
	[ "$NETSIM_STARTED" -eq 1 ] || return 0
	NETSIM_STARTED=0
	local p
	for p in "$NETSIM_ROOT"/*.pid; do
		[ -f "$p" ] || continue
		kill "$(cat "$p")" 2>/dev/null || true
	done
	ip netns del "$NS_SRV" 2>/dev/null || true
	ip netns del "$NS_CLI" 2>/dev/null || true
	[ -n "$NETSIM_ROOT" ] && rm -rf "$NETSIM_ROOT"
	return 0
}

# netsim_cert — a self-signed cert for the own-cert transports, generated per run inside the fixture
# root. TEST_ONLY by construction: it never leaves the namespace and is destroyed with it (§8.1).
netsim_cert() {
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
		-keyout "$NETSIM_ROOT/key.pem" -out "$NETSIM_ROOT/cert.pem" \
		-subj "/CN=netsim.invalid" -addext "subjectAltName=IP:$IP_SRV" >/dev/null 2>&1 \
		|| ns_die "could not generate the TEST_ONLY certificate"
}

# netsim_origin — the HTTP origin the tunnel carries traffic to, inside the SERVER namespace. Keeping
# it here is what makes a scenario a closed system: success means "the tunnel carried bytes", never
# "the internet happened to be up".
netsim_origin() {
	printf 'netsim-origin-ok\n' > "$NETSIM_ROOT/index.html"
	ip netns exec "$NS_SRV" python3 -m http.server "$ORIGIN_PORT" \
		--bind "$IP_SRV" --directory "$NETSIM_ROOT" >/dev/null 2>&1 &
	echo $! > "$NETSIM_ROOT/origin.pid"
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		ip netns exec "$NS_SRV" curl -s --max-time 1 "http://$IP_SRV:$ORIGIN_PORT/index.html" >/dev/null 2>&1 && return 0
		sleep 0.3
	done
	ns_die "the in-namespace HTTP origin never came up"
}

# netsim_singbox NS CONFIG TAG — start a sing-box in a namespace and wait for it to be live.
netsim_singbox() {
	local ns="$1" cfg="$2" tag="$3"
	ip netns exec "$ns" sing-box check -c "$cfg" >"$NETSIM_ROOT/$tag.check" 2>&1 \
		|| { sed 's/^/    /' "$NETSIM_ROOT/$tag.check" >&2; ns_die "sing-box rejected the $tag config"; }
	ip netns exec "$ns" sing-box run -c "$cfg" >"$NETSIM_ROOT/$tag.log" 2>&1 &
	echo $! > "$NETSIM_ROOT/$tag.pid"
	sleep 1
	kill -0 "$(cat "$NETSIM_ROOT/$tag.pid")" 2>/dev/null || {
		tail -5 "$NETSIM_ROOT/$tag.log" >&2; ns_die "$tag died on start"
	}
}

# --- impairment primitives (§7.3) -------------------------------------------------------------------
# All applied in the SERVER namespace on its own ingress, so they impair what reaches the transport
# without touching the client's own stack — the shape a network-side impairment actually has.

# netsim_drop_udp PORT[:PORT] — silently discard UDP to a port or range (the "port is blocked" case).
#
# raw/PREROUTING, NOT filter/INPUT, and this is load-bearing rather than a style choice. The hop range
# reaches the server through a REDIRECT in nat/PREROUTING, and nat runs BEFORE filter: by the time a
# packet reaches INPUT its destination port has already been rewritten to the served port, so a filter
# rule naming the RANGE can never match. The first version of this fixture used INPUT and every
# impairment was a no-op — the control row is what caught it, and it is worth stating plainly because
# the same arithmetic applies on a real node: a host firewall rule written against the advertised range
# does not do what its author expects. A network-side block happens upstream of all of this, and raw is
# the chain that models that faithfully.
netsim_drop_udp() {
	ip netns exec "$NS_SRV" iptables -t raw -I PREROUTING -i "$VETH_S" -p udp --dport "$1" -j DROP \
		|| ns_die "could not install the UDP DROP for $1"
	ns_log "impairment: UDP $1 DROPped (raw/PREROUTING, upstream of nat)"
}

# netsim_rst_tcp PORT — answer TCP with a RST (injection, not a silent drop: a different signal, and the
# detector must tell them apart).
netsim_rst_tcp() {
	ip netns exec "$NS_SRV" iptables -I INPUT -p tcp --dport "$1" -j REJECT --reject-with tcp-reset \
		|| ns_die "could not install the TCP RST injection for $1"
	ns_log "impairment: TCP $1 answered with RST"
}

# netsim_netem ARGS... — apply a qdisc to the server's veth (loss, delay, rate).
netsim_netem() {
	ip netns exec "$NS_SRV" tc qdisc replace dev "$VETH_S" root netem "$@" \
		|| ns_die "could not apply netem: $*"
	ns_log "impairment: netem $*"
}

# netsim_clear — remove every impairment, returning the fixture to a clean link.
netsim_clear() {
	ip netns exec "$NS_SRV" iptables -F INPUT 2>/dev/null || true
	ip netns exec "$NS_SRV" iptables -t raw -F PREROUTING 2>/dev/null || true
	ip netns exec "$NS_SRV" tc qdisc del dev "$VETH_S" root 2>/dev/null || true
	ns_log "impairments cleared"
}

# --- measurement -------------------------------------------------------------------------------------

# netsim_fetch [TIMEOUT] — one request through the tunnel. Exit 0 iff the origin's bytes came back.
# The BODY is checked, not the status: a proxy that answers 200 with its own error page would otherwise
# read as success, which is the same "reported healthy while carrying nothing" defect this suite exists
# to catch.
netsim_fetch() {
	local t="${1:-5}" body
	body="$(ip netns exec "$NS_CLI" curl -s --max-time "$t" \
		-x "socks5h://127.0.0.1:$SOCKS_PORT" "http://$IP_SRV:$ORIGIN_PORT/index.html" 2>/dev/null)"
	[ "$body" = "netsim-origin-ok" ]
}

# netsim_time_to_recover MAX_SECONDS — poll until the tunnel carries bytes again; print the elapsed
# whole seconds, or "never". This is the §7.3 measurable criterion (recovery time <= SLO).
netsim_time_to_recover() {
	local max="$1" i=0
	while [ "$i" -lt "$max" ]; do
		netsim_fetch 2 && { printf '%s' "$i"; return 0; }
		i=$((i + 1))
		sleep 1
	done
	printf 'never'
	return 1
}
