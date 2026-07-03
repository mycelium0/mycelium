#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# block_endpoint.sh — RP-0013 C2: a scoped, reversible, node-local firewall block of ONE served
# endpoint's port, for the end-to-end client-recovery harness.
# Author: mindicator & silicon bags quartet.
#
# WHAT IT DOES (and does NOT do)
#   Inserts (or removes) a single iptables DROP rule for TCP traffic to --port, OPTIONALLY scoped to a
#   --source address. It NEVER edits the node's served config, params, or the running engine — the node
#   keeps serving exactly what it served; only the *path* to that port (for the scoped source) is dropped,
#   simulating a client-visible block of the active endpoint. This is the "reversible block" half of the
#   recovery harness (the client-side recovery probe is client_recovery_probe.sh).
#
# WHY --source (surgical, production-safe)
#   With --source SRC the DROP matches ONLY connections from SRC, so a real external population on the same
#   port is UNAFFECTED — the block hits only the test client. On a node whose own out→in traffic routes via
#   loopback, SRC = the node's own public IP scopes the block to an on-node test client (verified: own
#   public-IP traffic uses dev lo with src = the public IP). WITHOUT --source the DROP is blanket (every
#   client on that port) — test-only, never on a node with a live population.
#
# REVERSIBILITY / FAIL-SAFE
#   --unblock removes the rule (and is idempotent: it deletes every matching copy, so a doubled add still
#   cleans fully). add is also idempotent (it removes any identical prior rule first, so re-runs never
#   stack duplicates). The rule is INSERTed at the head of INPUT so it wins over ACCEPTs. The harness runs
#   this under a trap so an interrupted run still unblocks.
#
# Exit: 0 = rule applied/removed, 2 = usage/env error.

set -euo pipefail

usage() {
	cat <<'USAGE'
block_endpoint.sh — scoped, reversible node-local block of one endpoint port (RP-0013 C2).

Usage:
  block_endpoint.sh --port PORT [--source SRC] [--proto tcp|udp]     # add the DROP
  block_endpoint.sh --port PORT [--source SRC] [--proto tcp|udp] --unblock   # remove it

  --port     the served endpoint's port to block (required).
  --source   scope the DROP to this source address (surgical; external clients unaffected).
             Omit only in an isolated test — a blanket block hits every client on that port.
  --proto    tcp (default) or udp (hysteria2/tuic/awg live on udp).
  --unblock  remove the rule instead of adding it (idempotent).

Requires root + iptables. Exit: 0 ok, 2 usage/env error.
USAGE
}

port=""
source_addr=""
proto="tcp"
mode="add"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--port)    port="${2:?--port needs a value}"; shift 2 ;;
		--source)  source_addr="${2:?--source needs a value}"; shift 2 ;;
		--proto)   proto="${2:?--proto needs a value}"; shift 2 ;;
		--unblock) mode="del"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'block_endpoint: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

[ -n "$port" ] || { printf 'block_endpoint: --port is required\n' >&2; exit 2; }
case "$proto" in tcp|udp) : ;; *) printf 'block_endpoint: --proto must be tcp or udp\n' >&2; exit 2 ;; esac
command -v iptables >/dev/null 2>&1 || { printf 'block_endpoint: iptables is required\n' >&2; exit 2; }
[ "$(id -u)" = "0" ] || { printf 'block_endpoint: must run as root (iptables)\n' >&2; exit 2; }

# Build the rule spec ONCE so add and delete are exact mirrors (no drift).
rule=(INPUT -p "$proto" --dport "$port" -j DROP)
[ -n "$source_addr" ] && rule=(INPUT -s "$source_addr" -p "$proto" --dport "$port" -j DROP)

scope_desc="all sources (BLANKET — test-only)"
[ -n "$source_addr" ] && scope_desc="source $source_addr (surgical; external clients unaffected)"

# Idempotent delete: remove every matching copy (a doubled prior add cleans fully).
_del_all() { while iptables -C "${rule[@]}" 2>/dev/null; do iptables -D "${rule[@]}"; done; }

if [ "$mode" = "del" ]; then
	_del_all
	printf 'block_endpoint: UNBLOCKED %s/%s for %s (rule removed; node clean)\n' "$proto" "$port" "$scope_desc"
	exit 0
fi

# add: clear any identical prior rule first (no duplicate stacking), then INSERT at the head.
_del_all
iptables -I "${rule[@]}"
printf 'block_endpoint: BLOCKED %s/%s for %s\n' "$proto" "$port" "$scope_desc"
printf '  rule: -A %s\n' "$(printf '%s ' "${rule[@]}" | sed 's/ $//')"
printf '  undo: block_endpoint.sh --port %s%s%s --unblock\n' \
	"$port" "${source_addr:+ --source $source_addr}" "$([ "$proto" = udp ] && printf ' --proto udp')"
exit 0
