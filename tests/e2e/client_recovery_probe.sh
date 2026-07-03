#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# client_recovery_probe.sh — RP-0013 C2: the client-side half of the end-to-end recovery harness.
# Author: mindicator & silicon bags quartet.
#
# Starts a HEADLESS stock-equivalent client (a second sing-box, using the runnable client config from
# gen_client_config.sh — the SAME `urltest` auto-failover a stock client uses), proves traffic flows,
# then invokes the reversible block of the active endpoint (block_endpoint.sh) and TIMES the wall-clock
# until traffic flows again on the independent sibling. Emits a JSON verdict with recovery_seconds and a
# pass/fail against the single-digit-minute bound (RP-0013 AC-1 / AC-4).
#
# MEASURED AT THE CLIENT. The proof is "the client curls successfully again", not "the node still serves".
#
# FAIL-SAFE. A trap always UNBLOCKS and stops the client, so an interrupted run leaves the node clean and
# still serving (the block never touched the served config).
#
# Exit: 0 = recovered within bound, 1 = no recovery within bound / setup failed, 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	cat <<'USAGE'
client_recovery_probe.sh — headless client recovery probe (RP-0013 C2).

Usage:
  client_recovery_probe.sh --config CFG.json --proxy-port PP --node-ip IP --active-port AP \
      [--active-proto tcp|udp] [--source SRC] [--url URL] [--bound-sec 360] [--poll-sec 5] \
      [--singbox BIN] [--out RESULT.json]

  --config        runnable client config from gen_client_config.sh (required).
  --proxy-port    the mixed-inbound port in --config to curl through (required).
  --node-ip       the node's reachability IP the client dials (required).
  --active-port   the active endpoint's port to block (optional; default: the live urltest selection read
                  via the Clash API, so the block always hits the ACTUAL active and forces a real failover).
  --active-proto  tcp (default) or udp.
  --clash-port    Clash-API port from gen_client_config.sh (default 19090).
  --source        block scope (default: --node-ip, i.e. an on-node client via loopback — surgical).
  --url           reachability test URL (default: https://www.gstatic.com/generate_204).
  --bound-sec     recovery must complete within this many seconds (default 360 = 6 min).
  --poll-sec      poll cadence in seconds (default 5).
  --singbox       sing-box binary (default: sing-box on PATH).
  --out           write the JSON verdict here (also printed to stdout).

Requires sing-box, curl, jq, iptables (root). Exit: 0 recovered, 1 no-recovery/setup-fail, 2 usage.
USAGE
}

config="" proxy_port="" node_ip="" active_port="" active_proto="tcp" source_addr="" clash_port="19090"
url="https://www.gstatic.com/generate_204" bound_sec=360 poll_sec=5 singbox="sing-box" out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--config)       config="${2:?}"; shift 2 ;;
		--proxy-port)   proxy_port="${2:?}"; shift 2 ;;
		--node-ip)      node_ip="${2:?}"; shift 2 ;;
		--active-port)  active_port="${2:?}"; shift 2 ;;
		--active-proto) active_proto="${2:?}"; shift 2 ;;
		--clash-port)   clash_port="${2:?}"; shift 2 ;;
		--source)       source_addr="${2:?}"; shift 2 ;;
		--url)          url="${2:?}"; shift 2 ;;
		--bound-sec)    bound_sec="${2:?}"; shift 2 ;;
		--poll-sec)     poll_sec="${2:?}"; shift 2 ;;
		--singbox)      singbox="${2:?}"; shift 2 ;;
		--out)          out="${2:?}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'client_recovery_probe: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

[ -n "$config" ] && [ -f "$config" ] || { printf 'client_recovery_probe: --config FILE required\n' >&2; exit 2; }
for v in proxy_port node_ip; do [ -n "${!v}" ] || { printf 'client_recovery_probe: --%s required\n' "${v//_/-}" >&2; exit 2; }; done
for b in "$singbox" curl jq iptables; do command -v "$b" >/dev/null 2>&1 || { printf 'client_recovery_probe: %s required\n' "$b" >&2; exit 2; }; done
[ "$(id -u)" = "0" ] || { printf 'client_recovery_probe: must run as root (the block uses iptables)\n' >&2; exit 2; }
[ -n "$source_addr" ] || source_addr="$node_ip"

BLOCK="$HERE/block_endpoint.sh"
[ -x "$BLOCK" ] || BLOCK="bash $HERE/block_endpoint.sh"

# now_s — monotonic seconds (no Date.now dependency; uses the shell's SECONDS-free `date +%s`).
now_s() { date +%s; }
# curl_ok — does a request through the client proxy return a 2xx/204? (socks5h: resolve via the proxy.)
curl_ok() {
	local code
	code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 \
		--proxy "socks5h://127.0.0.1:$proxy_port" "$url" 2>/dev/null || true)"
	case "$code" in 2*|204) return 0 ;; *) return 1 ;; esac
}
# active_tag — the outbound tag urltest currently selects, via the loopback Clash API (empty if off).
active_tag() {
	curl -fsS --max-time 4 "http://127.0.0.1:$clash_port/proxies/auto" 2>/dev/null | jq -r '.now // empty' 2>/dev/null || true
}
# tag_to_port — the server_port of an outbound tag in the client config (empty if not found).
tag_to_port() {
	jq -r --arg t "$1" '.outbounds[]? | select(.tag==$t) | .server_port // empty' "$config" 2>/dev/null | head -1
}

CLIENT_PID=""
BLOCKED=0
cleanup() {
	[ "$BLOCKED" = "1" ] && $BLOCK --port "$active_port" --source "$source_addr" --proto "$active_proto" --unblock >/dev/null 2>&1 || true
	[ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

printf '== client recovery probe (RP-0013 C2) ==\n'
printf 'node=%s active=%s/%s  proxy=127.0.0.1:%s  url=%s  bound=%ss\n' \
	"$node_ip" "$active_proto" "$active_port" "$proxy_port" "$url" "$bound_sec"

# Validate + start the headless client.
"$singbox" check -c "$config" >/dev/null 2>&1 || { printf 'FAIL: sing-box rejected the client config\n' >&2; exit 1; }
"$singbox" run -c "$config" >/tmp/e2e-client.log 2>&1 &
CLIENT_PID=$!
printf 'client: started sing-box pid=%s\n' "$CLIENT_PID"

# Baseline: the client must carry traffic BEFORE we block (else the measurement is meaningless).
baseline_ok=0
for _ in $(seq 1 12); do
	if kill -0 "$CLIENT_PID" 2>/dev/null && curl_ok; then baseline_ok=1; break; fi
	sleep 2
done
if [ "$baseline_ok" != "1" ]; then
	printf 'FAIL(setup): the client never carried traffic pre-block (no baseline) — check the config/reachability.\n' >&2
	verdict="setup-fail"; recovery_s=-1
	printf '{"verdict":"%s","baseline_ok":false,"recovery_seconds":%s,"bound_sec":%s}\n' "$verdict" "$recovery_s" "$bound_sec"
	[ -n "$out" ] && printf '{"verdict":"%s","baseline_ok":false,"recovery_seconds":%s,"bound_sec":%s}\n' "$verdict" "$recovery_s" "$bound_sec" >"$out"
	exit 1
fi
printf 'baseline: client carries traffic on the active endpoint ✓\n'

# Determine the endpoint the client is ACTUALLY using (urltest's live pick via the Clash API) so the block
# hits the active path and forces a REAL failover — not a lucky already-on-the-sibling pass. Falls back to
# the explicit --active-port if the Clash API is off/unreachable.
sel_before="$(active_tag)"
if [ -n "$sel_before" ]; then
	p="$(tag_to_port "$sel_before")"
	[ -n "$p" ] && active_port="$p"
	printf 'active: urltest currently routes via %s (port %s) — blocking exactly that\n' "$sel_before" "$active_port"
fi
[ -n "$active_port" ] || { printf 'FAIL(setup): no active port (Clash API off AND no --active-port)\n' >&2; exit 1; }

# BLOCK the active endpoint and time recovery on the sibling.
blocked_at="$(now_s)"
$BLOCK --port "$active_port" --source "$source_addr" --proto "$active_proto" >/dev/null
BLOCKED=1
printf 'blocked: %s/%s (source %s) at t0 — timing recovery on the sibling…\n' "$active_proto" "$active_port" "$source_addr"

recovery_s=-1
deadline=$(( blocked_at + bound_sec ))
# Give the block a moment to take effect, then confirm the active path actually went down before timing
# recovery (so we never mis-time a still-working active as an instant "recovery").
sleep 2
while [ "$(now_s)" -lt "$deadline" ]; do
	if curl_ok; then
		recovery_s=$(( $(now_s) - blocked_at ))
		break
	fi
	sleep "$poll_sec"
done

# Read the live selection WHILE STILL BLOCKED so it reflects the failed-over state, then confirm it is a
# DIFFERENT outbound than pre-block (a genuine failover, not a same-endpoint blip).
sel_after="$(active_tag)"
failover=""
if [ -n "$sel_before" ] && [ -n "$sel_after" ]; then
	[ "$sel_after" != "$sel_before" ] && failover="true" || failover="false"
	printf 'selection: %s -> %s (failover_confirmed=%s)\n' "$sel_before" "$sel_after" "$failover"
fi

$BLOCK --port "$active_port" --source "$source_addr" --proto "$active_proto" --unblock >/dev/null
BLOCKED=0
printf 'unblocked: node restored (served config never changed).\n'

if [ "$recovery_s" -ge 0 ]; then
	verdict="pass"
	printf 'RESULT: recovered on the sibling in %ss (bound %ss) — PASS (AC-1/AC-4)\n' "$recovery_s" "$bound_sec"
else
	verdict="fail"
	printf 'RESULT: no recovery within %ss — FAIL\n' "$bound_sec" >&2
fi

result="$(jq -nc --arg v "$verdict" --argjson r "$recovery_s" --argjson b "$bound_sec" \
	--arg node "$node_ip" --argjson ap "$active_port" --arg proto "$active_proto" \
	--arg sb "$sel_before" --arg sa "$sel_after" --arg fo "$failover" \
	'{verdict:$v, baseline_ok:true, recovery_seconds:$r, bound_sec:$b, node:$node,
	  active_port:$ap, active_proto:$proto,
	  selected_before:(if $sb=="" then null else $sb end),
	  selected_after:(if $sa=="" then null else $sa end),
	  failover_confirmed:(if $fo=="" then null else ($fo=="true") end)}')"
printf '%s\n' "$result"
[ -n "$out" ] && printf '%s\n' "$result" >"$out"
[ "$verdict" = "pass" ] && exit 0 || exit 1
