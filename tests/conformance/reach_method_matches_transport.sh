#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# reach_method_matches_transport.sh — conformance: the reachability anchor generated for a transport is
# probed by a method that CAN express that transport, and a transport with no such method fails the
# generator closed rather than receiving one that cannot.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   generate_measure_configs emitted `method: "tcp"` for every member unconditionally. For hysteria2 and
#   tuic — QUIC, therefore UDP-only — a TCP connect to their port is refused every single time, so all
#   three live nodes reported both at 0 successes against 8 failures, permanently, since the day the
#   plane was enabled.
#
#   That is not a weak signal, it is a confident false negative, and the difference matters: the
#   assembler carries an explicit guard so an EMPTY window is never read as a black-hole (measure.go —
#   "a zero-sample window carries NO information"). Eight real failures are not an empty window, so the
#   guard never fired. The tuner floored both weights, the planner marked the pair `promoted:false`, and
#   the two families most likely to survive a block became the two the failover mechanism could never
#   select — while a real off-host client carried HTTP 204 through both, and the node's own L7 probe
#   (which does speak QUIC) reported them alive the whole time. Three signals, and the wrong one won.
#
# WHAT IT CHECKS, by RUNNING the real generator over a throwaway node root
#   1. Every enabled member gets an anchor, and every quic-udp member's method is one that speaks UDP.
#   2. TCP-family members keep the TCP method — a "fix" that switched everything to the QUIC probe would
#      be just as wrong, so this is not a one-sided check.
#   3. A member whose class is UDP but is NOT quic-udp (a future AmneziaWG-style member) FAILS the
#      generator closed. Emitting a measurement known to be wrong is worse than emitting none: a wrong
#      one is indistinguishable downstream from a real outage, which is precisely how this hid.
#
# The Go side pins the same seam from its end (internal/reach TestMethodQUICIsCanonical + the three-way
# probe test), so a wire-value drift is caught on both sides of the generator/consumer boundary.
#
# OFFLINE. No root. Nothing outside its own mktemp root.
# Exit: 0 = every anchor's method fits its transport; 1 = a violation; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'reach_method_matches_transport: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_measure.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
VOCAB="$REPO_ROOT/control/vocab.json"
for f in "$LIB" "$FIXTURE" "$VOCAB"; do
	[ -f "$f" ] || { printf 'reach_method_matches_transport: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'reach_method_matches_transport: jq required\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== reach anchors: is each transport probed by a method that can express it ==\n'

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }

# The classes the generator is allowed to probe with "tcp". Derived from the vocab, not listed here, so
# a new TCP family is covered the day it is added and a new UDP family is not silently absorbed.
udp_classes="$(jq -r '[.protos[]? | select(.engine=="sing-box") | select((.class|tostring)|endswith("-udp")) | .class] | unique | join(" ")' "$VOCAB")"
[ -n "$udp_classes" ] || badln "the vocab lists no sing-box UDP transport class at all — either the registry changed shape or this gate is reading the wrong file; it would pass vacuously"

seed_params() { # PARAMS_PATH
	jq -n '{
		node_address: "203.0.113.9", donor_sni: "www.example.invalid", tls_sni: "tls.example.invalid",
		reality_public_key: "PUB", reality_private_key: "PRIV", short_ids: ["0123abcd"],
		ss_password: "SS", hysteria2_password: "HY", shadowtls_password: "ST", trojan_password: "TR",
		vless_reality_vision_enabled: true, vless_reality_vision_port: 8443,
		vless_ws_tls_enabled:         true, vless_ws_tls_port:         443,
		hysteria2_enabled:            true, hysteria2_port:            8444,
		tuic_enabled:                 true, tuic_port:                 8445,
		shadowsocks_enabled:          true, shadowsocks_port:          8388,
		shadowtls_enabled:            true, shadowtls_port:            8446
	}' > "$1"
}

# --- 1/2. the real generator over the real vocab ----------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	PARAMS_JSON="$STATE_DIR/params.json"; seed_params "$PARAMS_JSON"
	export MYC_VOCAB="$VOCAB"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }   # the generator only writes inside the throwaway root
	generate_measure_configs >/dev/null 2>&1 || { badln "generate_measure_configs failed in the fixture — the rows below would prove nothing"; exit "$fail"; }

	cfg="$STATE_DIR/reach.config.json"
	[ -s "$cfg" ] || { badln "no reach.config.json was written"; exit "$fail"; }

	# Every enabled member must have an anchor — a family with no anchor at all is invisible, which is a
	# different way to lose the same information.
	want="$(jq -r '[.protos[]?|select(.engine=="sing-box")|.proto]|sort|join(" ")' "$VOCAB")"
	for ref in $(jq -r '.targets[].ref' "$cfg"); do
		case " $want " in *" $ref "*) ;; *) badln "anchor '$ref' is not a sing-box transport in the registry" ;; esac
	done

	# The mapping, checked per member against the member's OWN class from the vocab.
	while IFS='|' read -r ref method; do
		[ -n "$ref" ] || continue
		cls="$(jq -r --arg p "$ref" '(.protos[]?|select(.proto==$p)|.class) // ""' "$VOCAB")"
		case " $udp_classes " in
			*" $cls "*)
				if [ "$method" = "tcp" ] || [ "$method" = "tls" ]; then
					badln "$ref is class '$cls' (UDP) but its anchor uses method '$method'. A TCP connect to a UDP-only port is REFUSED every time, so this member reports a permanent 0-successes/N-failures — real failures, not an empty window, so the assembler's zero-sample guard cannot save it. The tuner floors the weight and the rotation planner marks the transport ineligible forever."
				else
					ok "$ref (class $cls) is probed by '$method', a method that speaks UDP"
				fi ;;
			*)
				if [ "$method" = "tcp" ] || [ "$method" = "tls" ]; then
					ok "$ref (class $cls) keeps the TCP-family method '$method'"
				else
					badln "$ref is class '$cls' (a TCP family) but its anchor uses '$method'. Probing a TCP listener with the QUIC datagram probe never gets a reply, so this would invert the very defect it was meant to fix."
				fi ;;
		esac
	done < <(jq -r '.targets[] | .ref + "|" + .method' "$cfg")
	exit "$fail"
) || fail=1

# --- 3. an unexpressible UDP family must fail the generator CLOSED -----------------------------------
(
	set -u
	fail=0
	fakenode_init
	PARAMS_JSON="$STATE_DIR/params.json"; seed_params "$PARAMS_JSON"
	# A vocab in which one enabled member is a UDP class the probe has no method for.
	v2="$FAKENODE_ROOT/vocab.udp.json"
	jq '(.protos[] | select(.proto=="shadowsocks") | .class) = "wireguard-udp"' "$VOCAB" > "$v2" \
		|| { badln "could not build the mutated vocab; this row proves nothing"; exit "$fail"; }
	export MYC_VOCAB="$v2"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	# die must not take the gate down with it.
	if ( generate_measure_configs >/dev/null 2>&1 ); then
		badln "a member whose class is UDP but has NO probe method that can express it was accepted, and it will have been given a TCP anchor — a permanent false negative that is indistinguishable downstream from a real outage. The generator must refuse."
	else
		ok "a UDP transport class with no expressible probe method fails the generator closed"
	fi
	exit "$fail"
) || fail=1

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a reachability anchor is probed by a method that cannot express its transport.\n' >&2
	exit 1
fi
printf 'PASS: every anchor is probed by a method that fits its transport, and an inexpressible one fails closed.\n'
exit 0
