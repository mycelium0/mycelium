#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# gen_client_config.sh — RP-0013 C2: turn a node's rendered sing-box subscription into a RUNNABLE
# headless client config for the recovery probe.
# Author: mindicator & silicon bags quartet.
#
# The node's subscription (myceliumctl subscription -> <client>.singbox.json) is an OUTBOUNDS-only
# fragment: the per-endpoint proxies + a `urltest` "auto" group (the auto-failover mechanism a stock
# client uses) + a `selector` + direct + block, but NO inbound and NO route. This wraps it into a
# runnable client:
#   * injects one loopback `mixed` inbound on --proxy-port (what the probe curls through),
#   * routes everything through the `auto` urltest group (pure auto-failover — no manual selection),
#   * optionally rewrites the urltest interval (--urltest-interval) so a drill measures the failover
#     MECHANISM quickly; the SERVED interval still bounds real-world recovery.
#
# PRECONDITION MIRRORS RP-0013 C1 (Bundle.IndependentFallbackOK): it REFUSES a fragment whose proxy
# outbounds do not span >= 2 DISTINCT transport families (REALITY Vision/gRPC/XHTTP are ONE family). A
# recovery test on a single-family subscription is meaningless — there is no independent sibling to fail
# over to — so the harness fails closed here rather than "measuring" a recovery that cannot happen.
#
# Exit: 0 = wrote a runnable client config, 1 = single-family (no independent sibling), 2 = usage/env.

set -euo pipefail

usage() {
	cat <<'USAGE'
gen_client_config.sh — wrap a node subscription fragment into a runnable headless client (RP-0013 C2).

Usage:
  gen_client_config.sh --fragment SUB.singbox.json --proxy-port PP [--urltest-interval 30s] [--out CFG.json]

  --fragment          the node's rendered sing-box subscription (outbounds + urltest "auto").
  --proxy-port        loopback mixed-inbound port the recovery probe curls through (required).
  --urltest-interval  override the urltest interval (e.g. 30s) for a fast drill; default: keep as-is.
  --clash-port        loopback Clash-API port so the probe can read the live selection (default 19090).
  --out               output path (default: <fragment-dir>/client.runnable.json).

Requires jq. Exit: 0 ok, 1 single-family (fails closed), 2 usage/env error.
USAGE
}

fragment=""
proxy_port=""
interval=""
out=""
clash_port="19090"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--fragment)         fragment="${2:?}"; shift 2 ;;
		--proxy-port)       proxy_port="${2:?}"; shift 2 ;;
		--urltest-interval) interval="${2:?}"; shift 2 ;;
		--clash-port)       clash_port="${2:?}"; shift 2 ;;
		--out)              out="${2:?}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'gen_client_config: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

[ -n "$fragment" ] && [ -f "$fragment" ] || { printf 'gen_client_config: --fragment FILE is required\n' >&2; exit 2; }
[ -n "$proxy_port" ] || { printf 'gen_client_config: --proxy-port is required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'gen_client_config: jq is required\n' >&2; exit 2; }
jq -e . "$fragment" >/dev/null 2>&1 || { printf 'gen_client_config: %s is not valid JSON\n' "$fragment" >&2; exit 2; }
[ -n "$out" ] || out="$(dirname "$fragment")/client.runnable.json"

# Family classifier — mirrors the C1 TransportClass contract at the client-outbound level. Applied only
# to the PROXY outbounds (auto/selector/direct/block are excluded by type).
fam_filter='
	def fam:
		if   .type=="vless" and (.tls.reality.enabled // false) then "REALITY"
		elif .type=="vless" then "GENUINE_TLS"
		elif .type=="trojan" then "TROJAN"
		elif .type=="hysteria2" then "HY2"
		elif .type=="tuic" then "TUIC"
		elif .type=="shadowsocks" then "SS"
		else "OTHER" end;
	[ .outbounds[]? | select(.type|IN("urltest","selector","direct","block")|not) | fam ]'

families="$(jq -r "$fam_filter | unique | join(\",\")" "$fragment")"
distinct="$(jq -r "$fam_filter | unique | length" "$fragment")"

printf 'gen_client_config: proxy outbound families = [%s] (%s distinct)\n' "$families" "$distinct"
if [ "${distinct:-0}" -lt 2 ]; then
	printf 'FAIL: the subscription spans only %s independent family — no sibling to fail over to.\n' "$distinct" >&2
	printf '      RP-0013 C1 (IndependentFallbackOK) requires >= 2 distinct families; regenerate the\n' >&2
	printf '      subscription from params that enable a second, independent transport family.\n' >&2
	exit 1
fi

# Wrap: inject a loopback mixed inbound + route everything through the "auto" urltest group + a loopback
# Clash API (so the recovery probe can read which outbound urltest currently selects, block THAT one, and
# confirm the selection actually changes — a deterministic failover, not a lucky already-on-the-sibling
# pass). Optionally rewrite the urltest interval. Log settings on stderr so stdout stays clean if piped.
jq \
	--argjson pp "$proxy_port" \
	--argjson cp "$clash_port" \
	--arg iv "$interval" '
	.inbounds = [ { type: "mixed", tag: "probe-in", listen: "127.0.0.1", listen_port: $pp } ]
	| .route = { final: "auto", rules: [] }
	| .experimental = ((.experimental // {}) + { clash_api: { external_controller: ("127.0.0.1:" + ($cp|tostring)) } })
	| ( .outbounds |= map( if .type=="urltest" and ($iv != "") then .interval = $iv else . end ) )
	' "$fragment" >"$out.tmp" && mv -f "$out.tmp" "$out"

used_iv="$(jq -r '.outbounds[]? | select(.type=="urltest") | .interval' "$out")"
printf 'gen_client_config: wrote %s (mixed 127.0.0.1:%s, route->auto, urltest interval=%s, clash-api 127.0.0.1:%s)\n' \
	"$out" "$proxy_port" "$used_iv" "$clash_port"
exit 0
