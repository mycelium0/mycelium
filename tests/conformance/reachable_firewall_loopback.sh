#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# reachable_firewall_loopback.sh — conformance (ADR-0034 §3 / RP-0011 chunk D): the FIREWALL half of the
# reachability posture. harden_ufw opens EXACTLY the public-bound ports; a loopback-bound inbound
# (reachable=false rebinds public inbounds to 127.0.0.1; the shadowtls detour is always loopback) is NOT a
# public entry, so its port must NEVER be opened. This pins the pure port-selector myc_firewall_singbox_ports
# (the single source of truth harden_ufw delegates to) on three fixtures:
#   1. a PUBLIC config ("::" binds)        => the public ports ARE opened, the loopback detour is NOT
#      (today's behaviour — no regression on a reachable=true node);
#   2. a LOOPBACK config (127.0.0.1 binds) => NO ports opened (reachable=false holds at the firewall layer);
#   3. a MISSING-listen inbound            => treated as public "::" and opened — NOT a jq test()-on-null
#      hard error (the regression guard for the chunk-D generalisation of the exclusion to all types).
# It also asserts harden_ufw actually DELEGATES to the helper (the gate guards live wiring, not a dead fn).
# OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = the firewall opens public ports only and excludes loopback, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'reachable_firewall_loopback: cannot resolve repo root\n' >&2; exit 2; }
HARDEN="$REPO_ROOT/control/lib/nb_harden.sh"
[ -f "$HARDEN" ] || { printf 'reachable_firewall_loopback: missing %s\n' "$HARDEN" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'reachable_firewall_loopback: jq required\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== reachability firewall: opens public ports only, never a loopback bind (ADR-0034 §3 / RP-0011 D) ==\n'

# Source the library to get the pure helper. nb_harden.sh defines functions only (no source-time effects),
# and myc_firewall_singbox_ports depends on nothing but jq, so this is safe to call standalone.
# shellcheck disable=SC1090
. "$HARDEN" || { badln "could not source nb_harden.sh"; printf 'FAIL\n' >&2; exit 1; }
command -v myc_firewall_singbox_ports >/dev/null 2>&1 \
	|| { badln "myc_firewall_singbox_ports not defined by nb_harden.sh"; printf 'FAIL\n' >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.rfl.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# normalise helper output (newline list) to a sorted, single-spaced string for comparison.
ports() { myc_firewall_singbox_ports "$1" "$2" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }
expect() { # <label> <got> <want>
	if [ "$2" = "$3" ]; then ok "$1 => [$2]"; else badln "$1 => got [$2], want [$3]"; fi
}

# Fixture 1: PUBLIC ("::") binds + a loopback shadowtls detour (always 127.0.0.1).
cat >"$WORK/public.json" <<'JSON'
{ "inbounds": [
  {"type":"vless","tag":"vless-reality-vision-in","listen":"::","listen_port":443},
  {"type":"hysteria2","tag":"hysteria2-in","listen":"::","listen_port":8444},
  {"type":"shadowsocks","tag":"shadowsocks-in","listen":"::","listen_port":8388},
  {"type":"shadowtls","tag":"shadowtls-in","listen":"::","listen_port":8443},
  {"type":"shadowsocks","tag":"shadowtls-ss-in","listen":"127.0.0.1","listen_port":9999}
] }
JSON
expect "public tcp (vless/shadowsocks/shadowtls public; detour excluded)" "$(ports "$WORK/public.json" tcp)" "443 8388 8443"
expect "public udp (hysteria2 + shadowsocks-2022; detour excluded)"        "$(ports "$WORK/public.json" udp)" "8388 8444"

# Fixture 2: LOOPBACK (reachable=false) — every public inbound rebound to 127.0.0.1.
cat >"$WORK/loopback.json" <<'JSON'
{ "inbounds": [
  {"type":"vless","tag":"vless-reality-vision-in","listen":"127.0.0.1","listen_port":443},
  {"type":"hysteria2","tag":"hysteria2-in","listen":"127.0.0.1","listen_port":8444},
  {"type":"shadowsocks","tag":"shadowsocks-in","listen":"127.0.0.1","listen_port":8388},
  {"type":"shadowtls","tag":"shadowtls-in","listen":"127.0.0.1","listen_port":8443},
  {"type":"shadowsocks","tag":"shadowtls-ss-in","listen":"127.0.0.1","listen_port":9999}
] }
JSON
expect "loopback tcp (reachable=false => no public entry)" "$(ports "$WORK/loopback.json" tcp)" ""
expect "loopback udp (reachable=false => no public entry)" "$(ports "$WORK/loopback.json" udp)" ""

# Fixture 3: a MISSING listen key must be treated as public "::" (opened), NOT a jq test()-on-null abort.
cat >"$WORK/nolisten.json" <<'JSON'
{ "inbounds": [
  {"type":"vless","tag":"vless-reality-vision-in","listen_port":443}
] }
JSON
expect "missing-listen tcp (defaults public, no jq null-abort)" "$(ports "$WORK/nolisten.json" tcp)" "443"

# Static wiring: harden_ufw must DELEGATE to the helper (guard against the live path drifting off it).
hf="$(awk '/^harden_ufw\(\)/{f=1} f{print} /^}/{if(f)exit}' "$HARDEN")"
printf '%s' "$hf" | grep -q 'myc_firewall_singbox_ports "\$SINGBOX_CONFIG" tcp' \
	&& printf '%s' "$hf" | grep -q 'myc_firewall_singbox_ports "\$SINGBOX_CONFIG" udp' \
	&& ok "harden_ufw delegates port selection to myc_firewall_singbox_ports (tcp + udp)" \
	|| badln "harden_ufw does not delegate to myc_firewall_singbox_ports — live firewall may bypass the loopback exclusion"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the firewall opens public ports only and never a loopback-bound (reachable=false / detour) port.\n'
	exit 0
fi
printf 'FAIL: the reachability firewall exclusion is not held.\n' >&2
exit 1
