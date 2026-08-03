#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# private_destinations_blocked.sh — conformance: EVERY engine a node serves refuses to forward a client's
# traffic to a private, loopback, link-local or otherwise internal destination, and does so without
# depending on an external geo-asset file.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Measured on all three live nodes: a client holding a `vless-xhttp-tls` subscription reached the
#   TARGET NODE'S OWN loopback services from the public internet —
#     http://127.0.0.1:9100/metrics -> HTTP 200, 59868 bytes of real node_exporter output
#     http://127.0.0.1:9551/        -> HTTP 404 (myceliumd, the control-plane daemon, answering)
#     http://127.0.0.1:9090/        -> HTTP 401 (the sing-box Clash API, answering; only its secret stood
#                                     between a stranger and the proxy's control surface)
#   169.254.169.254 — the cloud metadata endpoint — was reachable by the same path.
#
#   The sing-box engine was never affected: its rendered config carries {"ip_is_private":true,
#   "outbound":"block"} and refuses these in ~20ms. The xray engine's template simply had no `routing`
#   key at all and a single untagged `freedom` outbound, so it forwarded everything, everywhere. Two
#   engines serve the same clients from the same node and only one had the guard.
#
#   The signal was there the whole time and was read as noise: `validate_configs` FAILED on every node
#   because the OTHER xray template blocked private destinations via "geoip:private", which needs a
#   geoip.dat that no node has. That failure was treated as an environment quirk. It was pointing
#   straight at the control that the live path had silently dropped.
#
# WHAT IT CHECKS — behaviour, not text
#   Per engine, from a rendered server config:
#     1. a rule routes internal destinations at a blocking outbound;
#     2. that outbound TAG ACTUALLY EXISTS in the config (a rule pointing at a tag nothing defines is a
#        no-op that reads exactly like a guard);
#     3. the rule needs NO external asset (`geoip:` / `geosite:` tokens) — an asset the node does not
#        have is how this hole opened: the config becomes unloadable and the control silently leaves;
#     4. COVERAGE, computed not asserted: every address in a value table of things that must never be
#        reachable is contained in the blocked set, and every address in a table of ordinary public
#        destinations is NOT — so "block 0.0.0.0/0" cannot pass this gate either.
#
# OFFLINE. Renders through the node's own `control/myceliumctl render-server`, so it tests the real path.
# Exit: 0 = every engine blocks internal destinations; 1 = an engine would forward them; 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'private_destinations_blocked: cannot resolve repo root\n' >&2; exit 2; }
CTL="$REPO_ROOT/control/myceliumctl"
[ -f "$CTL" ] || { printf 'private_destinations_blocked: control/myceliumctl not found\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'private_destinations_blocked: jq required\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || {
	printf 'SKIP: python3 (ipaddress) is required to COMPUTE prefix coverage; a text check would be exactly\n'
	printf '      the kind of assertion that missed this defect. Install python3 to run this gate.\n'
	exit 0
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.privblock.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== private destinations: does every served engine refuse to forward inward ==\n'

# --- the value table -------------------------------------------------------------------------------
# MUST be blocked. Each of these is something a client reached, or could have reached, on a live node.
MUST_BLOCK="127.0.0.1 127.0.0.53 169.254.169.254 10.0.0.1 172.16.0.1 172.31.255.254 192.168.1.1 100.64.0.1 0.0.0.0 ::1 fe80::1 fc00::1"
# MUST NOT be blocked — a guard that swallows the ordinary internet is not a guard, it is an outage.
MUST_PASS="1.1.1.1 8.8.8.8 142.250.185.100 93.184.216.34 2606:4700:4700::1111"

PARAMS="$WORK/params.json"; STATE="$WORK/identities.json"
jq -n '{
	node_address: "203.0.113.9",
	donor_host: "www.example.invalid", donor_sni: "www.example.invalid",
	reality_public_key: "PUB", reality_private_key: "PRIVDUMMY", short_ids: [ "0123abcd" ],
	tls_sni: "tls.example.invalid",
	ss_password: "SSPW", trojan_password: "TRPW", hysteria2_password: "HYPW", shadowtls_password: "STPW",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 8443,
	vless_ws_tls_enabled:         true, vless_ws_tls_port:         443,
	vless_xhttp_tls_enabled:      true, vless_xhttp_tls_port:      2087,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	tuic_enabled:                 true, tuic_port:                 8445,
	shadowsocks_enabled:          true, shadowsocks_port:          8388,
	shadowtls_enabled:            true, shadowtls_port:            8446
}' > "$PARAMS"
jq -n '{ version: 1, clients: [
	{ name: "alice", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z" }
] }' > "$STATE"

# coverage CFG BLOCKED_JSON — prints one "addr verdict" line per value-table entry.
# Containment is COMPUTED with ipaddress, so a prefix list that merely looks right but omits, say,
# 169.254.0.0/16 fails on the address rather than on a missing string.
coverage() {
	python3 - "$1" "$2" "$3" <<-'PY'
		import ipaddress, sys
		prefixes = [p for p in sys.argv[1].split() if p]
		nets = []
		for p in prefixes:
		    try:
		        nets.append(ipaddress.ip_network(p, strict=False))
		    except ValueError:
		        print("BADPREFIX %s" % p)
		for group, addrs in (("BLOCK", sys.argv[2].split()), ("PASS", sys.argv[3].split())):
		    for a in addrs:
		        ip = ipaddress.ip_address(a)
		        hit = any(ip.version == n.version and ip in n for n in nets)
		        print("%s %s %s" % (group, a, "covered" if hit else "uncovered"))
	PY
}

# --- xray -------------------------------------------------------------------------------------------
check_xray() {
	# Two statements, not one: `local a="$1" b="...$a..."` declares BOTH names local before it assigns
	# either, so the interpolation of $a reads the fresh unset local and trips `set -u`.
	local tmpl="$1" label="$2"
	local cfg="$WORK/xray.$label.json"
	if ! bash "$CTL" render-server --engine xray --proto vless-xhttp-tls --template "$tmpl" \
		--params "$PARAMS" --state "$STATE" --out "$cfg" >"$WORK/x.$label.err" 2>&1; then
		badln "xray/$label: render-server failed, so nothing below could be checked: $(head -1 "$WORK/x.$label.err")"
		return
	fi

	# The rule set that sends traffic at a blocking outbound, and the tags it names.
	local btags rules_ip
	btags="$(jq -r '[.routing.rules[]? | select((.ip // []) | length > 0) | .outboundTag] | unique | .[]' "$cfg" 2>/dev/null | tr '\n' ' ')"
	if [ -z "$btags" ]; then
		badln "xray/$label: the rendered config has NO routing rule keyed on destination IP at all. Every destination a client names is forwarded, including this node's own 127.0.0.1 (proven on live nodes: node_exporter answered HTTP 200 with 59868 bytes to a client on another continent) and 169.254.169.254."
		return
	fi

	# 2. every named outbound tag must exist, and reach a BLACKHOLE — a rule aimed at a tag nothing
	#    defines, or at a `freedom`, forwards while looking like a guard.
	local t missing="" notblock=""
	for t in $btags; do
		local proto
		proto="$(jq -r --arg t "$t" '(.outbounds[]? | select(.tag==$t) | .protocol) // ""' "$cfg")"
		[ -n "$proto" ] || { missing="$missing $t"; continue; }
		[ "$proto" = "blackhole" ] || notblock="$notblock $t($proto)"
	done
	[ -z "$missing" ] \
		&& ok "xray/$label: every ip rule names an outbound the config actually defines" \
		|| badln "xray/$label: ip rule(s) point at outbound tag(s)$missing that NO outbound defines — xray falls through to the default outbound, so the rule forwards while reading exactly like a block."
	[ -z "$notblock" ] \
		&& ok "xray/$label: the destination-IP rule terminates in a blackhole" \
		|| badln "xray/$label: destination-IP rule(s) terminate in$notblock, not a blackhole — that FORWARDS."

	# 3. no external geo asset.
	local assets
	assets="$(jq -r '[.routing.rules[]? | (.ip // [])[], (.domain // [])[]] | map(select(test("^geoip:|^geosite:"))) | unique | join(", ")' "$cfg" 2>/dev/null)"
	[ -z "$assets" ] \
		&& ok "xray/$label: the guard needs no external geo asset" \
		|| badln "xray/$label: the guard depends on external asset token(s): $assets. No live node carries geoip.dat/geosite.dat, so xray REFUSES to load the config ('failed to open file: geoip.dat') and the node runs whatever was there before — which is how this control silently disappeared from the served path. Express the set as literal CIDRs."

	# 4. coverage, computed.
	rules_ip="$(jq -r '[.routing.rules[]? | select((.ip // []) | length > 0) | (.ip // [])[]] | map(select(test("^geoip:|^geosite:") | not)) | join(" ")' "$cfg" 2>/dev/null)"
	local out uncovered="" leaked=""
	out="$(coverage "$rules_ip" "$MUST_BLOCK" "$MUST_PASS")"
	while read -r grp addr verdict; do
		case "$grp" in
			BADPREFIX) badln "xray/$label: '$addr' is not a valid CIDR — xray will reject or silently ignore it" ;;
			BLOCK) [ "$verdict" = "covered" ] || uncovered="$uncovered $addr" ;;
			PASS)  [ "$verdict" = "uncovered" ] || leaked="$leaked $addr" ;;
		esac
	done <<<"$out"
	[ -z "$uncovered" ] \
		&& ok "xray/$label: every internal address in the value table is inside the blocked set" \
		|| badln "xray/$label: these internal addresses are NOT covered by any blocked prefix:$uncovered — a client can reach them through this node."
	[ -z "$leaked" ] \
		&& ok "xray/$label: ordinary public destinations are not swallowed by the guard" \
		|| badln "xray/$label: the guard also blocks ordinary public address(es):$leaked — that is an outage, not a guard."
}

# --- sing-box ---------------------------------------------------------------------------------------
# sing-box expresses the same control as a PREDICATE (ip_is_private), which the engine evaluates itself,
# so there are no prefixes to compute over. Assert the predicate is present and terminates in a real
# block outbound — the two ways this control silently dies are that it is absent, or that it names an
# outbound nothing defines.
check_singbox() {
	local cfg="$WORK/singbox.json"
	if ! bash "$CTL" render-server --engine singbox --params "$PARAMS" --state "$STATE" --out "$cfg" \
		>"$WORK/sb.err" 2>&1; then
		badln "singbox: render-server failed, so nothing below could be checked: $(head -1 "$WORK/sb.err")"
		return
	fi
	local tag
	tag="$(jq -r '(.route.rules[]? | select(.ip_is_private == true) | .outbound) // ""' "$cfg" | head -1)"
	if [ -z "$tag" ]; then
		badln "singbox: no route rule carries ip_is_private — the sing-box-served protocols would forward a client's traffic to this node's own loopback and to 169.254.169.254, exactly as the xray engine did."
		return
	fi
	ok "singbox: a route rule matches private destinations (ip_is_private)"
	local kind
	kind="$(jq -r --arg t "$tag" '((.outbounds[]? | select(.tag==$t) | .type) // "") ' "$cfg" | head -1)"
	case "$kind" in
		block) ok "singbox: private destinations terminate in the block outbound" ;;
		"")    badln "singbox: the ip_is_private rule routes at '$tag', which NO outbound defines — sing-box falls through and the rule forwards while reading like a block." ;;
		*)     badln "singbox: the ip_is_private rule routes at '$tag' of type '$kind', not a block outbound — that forwards." ;;
	esac
}

printf '\n-- xray engine (vless-xhttp-tls: the template the live nodes render) --\n'
check_xray "$REPO_ROOT/nodes/dataplane/vless-xhttp-tls/xray.server.template.json" "xhttp-tls"

printf '\n-- xray engine (the REALITY template) --\n'
check_xray "$REPO_ROOT/nodes/dataplane/vless-reality/server.template.json" "reality"

printf '\n-- sing-box engine --\n'
check_singbox

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: at least one served engine would forward a client to an internal destination.\n' >&2
	exit 1
fi
printf 'PASS: every served engine blocks internal destinations, with no external asset dependency.\n'
exit 0
