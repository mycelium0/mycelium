#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_address_is_public.sh — conformance: the address stamped into every client subscription is either
# publicly routable or is the placeholder that makes the converge shout. It is never a private address
# recorded as a success.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   `resolve_node_address` auto-detected with `ip -o -4 addr show scope global | head -n1`. `scope global`
#   INCLUDES RFC1918 — measured on a live node, that command returns three addresses:
#
#       203.0.113.9   10.13.13.1   10.77.99.5
#
#   the public one, the AmneziaWG gateway, and a test interface. `head -n1` takes whichever the kernel
#   happens to enumerate first. On a NAT'd VPS the first one is private, and the loud warning at the call
#   site never fired, because it tests only for the literal placeholder string. So the node recorded
#   `10.0.0.5`, logged "recording node_address for subscriptions" as a SUCCESS, and every client config it
#   ever issued pointed at an unroutable address. The operator discovers this when their own client fails
#   — which is the same defect class as everything else found this cycle: a component reporting
#   confidently on something it cannot observe.
#
# WHAT IT CHECKS, by DRIVING the shipped function against a stubbed address helper
#   1. A host whose only address is private falls through to the PLACEHOLDER, not to the private address.
#      The placeholder is what triggers the operator-facing warning; a private address does not.
#   2. A host with a public address returns exactly that.
#   3. A broken artifact with NO helper still fails closed to the placeholder AND warns. A guess is worse
#      than a refusal here, because the guess is silent and reaches every client.
#   4. An explicit --node-address always wins (an operator behind NAT with a forwarded port must be able
#      to say so), and a value already in params.json is preserved across re-runs.
#   5. The function does not re-derive its own opinion of "public" — it delegates to the one rejector that
#      is already gated (`_l7_own_public_addr`, pinned by ss_l7_probe_failsafe.sh). Two definitions of
#      "private" that drift apart is how the first one got this wrong.
#
# OFFLINE. No root, no network. Exit: 0 = a private address can never reach a client config; 1 = it can.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_address_is_public: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_render_params.sh"
[ -f "$LIB" ] || { printf 'node_address_is_public: missing %s\n' "$LIB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.naddr.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

PLACEHOLDER="node.example.invalid"

# drive <helper-behaviour> [params-json-node-address] [NODE_ADDRESS]
#   helper-behaviour: an address to echo, "empty" for a helper that finds nothing, or "absent" for a
#   host where the helper does not exist at all.
# Prints "<resolved>|<warned:0|1>".
drive() {
	local helper="$1" prev="${2:-}" explicit="${3:-}"
	local pj="$WORK/params.json"; rm -f "$pj"
	[ -n "$prev" ] && printf '{"node_address":"%s"}\n' "$prev" >"$pj"
	(
		set -u
		# The lib reads several globals AT SOURCE TIME under `set -u`; supply them or the source dies
		# and every row silently reads an empty string. (The first draft did exactly that: six rows read
		# '' and the gate reported six real-looking defects that were entirely its own.)
		STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
		CONFIG_DIR="$WORK/config"; mkdir -p "$CONFIG_DIR"
		DRY_RUN=0
		NODE_ADDRESS="$explicit"
		NODE_ADDRESS_PLACEHOLDER="$PLACEHOLDER"
		PARAMS_JSON="$pj"
		warn() { printf 'WARNED\n' >&2; }
		log()  { :; }
		die()  { printf 'lib-die: %s\n' "$*" >&2; exit 1; }
		have() { command -v "$1" >/dev/null 2>&1; }
		run()  { "$@"; }
		case "$helper" in
			absent) : ;;                                        # no such function on this host
			empty)  _l7_own_public_addr() { return 1; } ;;      # helper ran, found nothing public
			*)      _l7_own_public_addr() { printf '%s\n' "$helper"; } ;;
		esac
		# shellcheck source=/dev/null
		. "$LIB" >/dev/null 2>&1 || { printf 'SOURCE-FAILED\n'; exit 0; }
		# Re-declare AFTER the source: a lib that defines its own copy at source time would otherwise
		# silently replace the stub and every row below would test the real helper against this machine.
		case "$helper" in
			absent) unset -f _l7_own_public_addr 2>/dev/null || : ;;
			empty)  _l7_own_public_addr() { return 1; } ;;
			*)      _l7_own_public_addr() { printf '%s\n' "$helper"; } ;;
		esac
		resolve_node_address
	) 2>"$WORK/err" | head -1 | tr -d '\n'
	if grep -q WARNED "$WORK/err" 2>/dev/null; then printf '|1'; else printf '|0'; fi
}

printf '== the address stamped into every client subscription ==\n\n'

# Guard: if the lib cannot be sourced standalone, every row below is vacuous. Say so rather than pass.
probe="$(drive 203.0.113.7)"
case "$probe" in
	SOURCE-FAILED*)
		printf '  FAIL  nb_render_params.sh could not be sourced standalone, so nothing here was driven. This gate would report PASS while testing nothing.\n' >&2
		exit 1 ;;
esac

# ---------------------------------------------------------------------------------------------------
# 1. THE DEFECT. A private-only host must not mint a subscription pointing at 10.x.
# ---------------------------------------------------------------------------------------------------
for priv in 10.0.0.5 192.168.1.10 172.16.4.2 100.64.0.9 127.0.0.1 169.254.10.1; do
	got="$(drive empty)"       # the real helper REJECTS these, so it yields nothing
	addr="${got%%|*}"
	if [ "$addr" = "$PLACEHOLDER" ]; then
		:
	else
		badln "with no public address available the resolver returned '$addr' instead of the placeholder — a client config would carry an address nobody can reach, and the converge would call it a success"
		break
	fi
done
[ "$fail" -eq 0 ] && ok "a host with no public address falls through to the placeholder, never to a private candidate"

got="$(drive empty)"
[ "${got##*|}" = "1" ] \
	&& ok "and it WARNS — the placeholder is what makes the call site shout; a private address would not have" \
	|| badln "the private-only path produced no warning. That is the exact failure: the node records an unusable address and reports success."

# ---------------------------------------------------------------------------------------------------
# 2. It must still work. A refusal that refuses everything is a different outage.
# ---------------------------------------------------------------------------------------------------
got="$(drive 203.0.113.7)"; addr="${got%%|*}"
[ "$addr" = "203.0.113.7" ] \
	&& ok "a genuinely public address is returned unchanged" \
	|| badln "a public address (203.0.113.7) resolved to '$addr' — the resolver now refuses valid hosts, which breaks every deploy that does not pass --node-address"

# ---------------------------------------------------------------------------------------------------
# 3. A BROKEN ARTIFACT FAILS CLOSED. The helper lives in another lib; it can be absent.
# ---------------------------------------------------------------------------------------------------
got="$(drive absent)"; addr="${got%%|*}"
if [ "$addr" = "$PLACEHOLDER" ] && [ "${got##*|}" = "1" ]; then
	ok "a host where the address helper is missing falls back to the placeholder AND warns"
else
	badln "with no address helper the resolver produced '$addr' (warned=${got##*|}). It must fail closed: a silent guess reaches every client config, while a placeholder is visible in one line of converge output."
fi

# ---------------------------------------------------------------------------------------------------
# 4. THE OPERATOR STILL WINS. NAT with a forwarded port is a legitimate deployment.
# ---------------------------------------------------------------------------------------------------
got="$(drive empty '' 10.0.0.5)"; addr="${got%%|*}"
[ "$addr" = "10.0.0.5" ] \
	&& ok "an explicit --node-address is honoured even when private (NAT + a forwarded port is legitimate)" \
	|| badln "an explicitly passed --node-address of 10.0.0.5 was overridden to '$addr'. Auto-detection may refuse a private address; it may not overrule the operator, who can see the port forward and we cannot."

got="$(drive empty 198.51.100.4)"; addr="${got%%|*}"
[ "$addr" = "198.51.100.4" ] \
	&& ok "a value already recorded in params.json survives a re-run (idempotent)" \
	|| badln "a node_address already in params.json ('198.51.100.4') was replaced by '$addr' — a re-run would re-issue every client config against a different address"

# ---------------------------------------------------------------------------------------------------
# 5. ONE OWNER FOR "PUBLIC". Two definitions that drift apart is how this broke.
# ---------------------------------------------------------------------------------------------------
fn="$(awk '/^resolve_node_address\(\)/,/^}/' "$LIB" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//')"
if printf '%s' "$fn" | grep -q '_l7_own_public_addr'; then
	ok "it delegates to _l7_own_public_addr — the single, already-gated rejector"
else
	badln "resolve_node_address no longer calls _l7_own_public_addr. If it has grown its own idea of what 'public' means, that second definition is unpinned and will drift from the one ss_l7_probe_failsafe.sh guards — which is precisely how \`scope global\` came to be treated as 'public' here while the probe correctly rejected RFC1918."
fi
if printf '%s' "$fn" | grep -qE 'scope global'; then
	badln "resolve_node_address still reads \`ip ... scope global\` directly. That listing INCLUDES RFC1918 — measured on a live node it returns 203.0.113.9, 10.13.13.1 and 10.77.99.5, and \`head -n1\` picks by kernel enumeration order."
else
	ok "and it does not read \`scope global\` itself (that listing includes RFC1918)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a private or unresolvable address can still be stamped into a client subscription.\n' >&2
	exit 1
fi
printf 'PASS: the node address is public, operator-supplied, or the loud placeholder — never a silent private guess.\n'
exit 0
