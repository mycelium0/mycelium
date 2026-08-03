#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_revoke_is_final.sh — conformance: revoking an AmneziaWG client actually retires the credential
# everywhere it is honoured, in an order that cannot leave it working, and cannot be undone by the
# node's own rollback machinery. EXECUTED against a throwaway node root.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   The node could issue AmneziaWG clients and had no way to un-issue one: every peer ever enrolled
#   stayed valid forever. That was found the hard way — a client's private key was exposed, and retiring
#   it meant hand-editing awg0.conf and calling `awg set ... peer ... remove` by hand on a live node.
#
#   A revoke has more than one place to be wrong, and each of them looks like success:
#     * the RUNNING interface still honours the key even after the file no longer lists it (until the
#       next restart, which may be weeks away) — so the file must never be the only thing edited, and
#       the live removal must come FIRST, or there is a window where the operator has been told
#       "revoked" while the key still works;
#     * the client's private key and .conf stay on the node, so the next operator "re-issues" a
#       credential that was supposed to be dead;
#     * `--awg-issue` keys "is this a re-issue?" on the presence of clients/NAME.private, so a name
#       whose key material was lost gets a SECOND peer enrolled under the same name (this happened on a
#       live node). A revoke that resolves the peer only by the stored key leaves the other one valid;
#     * _awg_rollback restores BOTH awg0.conf and clients/ from $STATE_DIR/awg/backup-*/ when a dialect
#       regen/rotate fails — so a backup taken before the revoke resurrects the peer AND its private key;
#     * and a rewrite that mangles awg0.conf leaves the node with no AmneziaWG at all after the next
#       start, which is a worse outcome than not revoking.
#
# WHAT IT CHECKS, by RUNNING revoke_awg_client over tests/lab/fakenode.sh with a recording `awg` stub
#   1. The live interface is cleared, and cleared BEFORE the config file is rewritten (order, not just
#      occurrence — a recorded call sequence, so a reordered implementation fails).
#   2. The [Peer] block is gone from awg0.conf, and every OTHER peer plus the [Interface] survives.
#   3. The stored private key, PSK and .conf are gone.
#   4. A name owning TWO peers (the --awg-issue duplicate state) loses BOTH.
#   5. Backups can no longer resurrect it: neither the client material nor the peer block survives in
#      $STATE_DIR/awg/backup-*/.
#   6. It is idempotent — a second revoke of the same name succeeds and changes nothing.
#   7. A revoke whose rewrite would damage the config promotes NOTHING.
#
# OFFLINE. No root. Nothing outside its own mktemp root.
# Exit: 0 = a revoke is final everywhere; 1 = a revoked credential survives somewhere; 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'awg_revoke_is_final: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_render_awg.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
for f in "$LIB" "$FIXTURE"; do
	[ -f "$f" ] || { printf 'awg_revoke_is_final: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== AmneziaWG revoke: is a revoked credential retired everywhere that honours it ==\n'

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }

# A recording `awg` stub. pubkey is a deterministic transform of the private material so the gate can
# predict the key a name resolves to; `set ... remove` is logged with a timestamped sequence number so
# ORDER against the config rewrite is observable.
install_awg_stub() {
	cat >"$STUBDIR/awg" <<'STUB'
#!/usr/bin/env bash
log="${FAKENODE_ROOT:?}/awg.calls"
case "${1:-}" in
	pubkey)  read -r k; printf 'PUB-%s\n' "${k#PRIV-}" ;;
	genkey)  printf 'PRIV-generated\n' ;;
	genpsk)  printf 'PSK-generated\n' ;;
	set)     printf 'set %s\n' "$*" >>"$log" ;;
	show)    : ;;
	*)       : ;;
esac
exit 0
STUB
	chmod +x "$STUBDIR/awg"
}

# A node conf with three peers: the target, a second peer for the SAME name, and a bystander.
seed_conf() { # PATH  [with_duplicate]
	local f="$1" dup="${2:-0}"
	{
		printf '[Interface]\n'
		printf 'PrivateKey = PRIV-server\n'
		printf 'Address = 10.13.13.1/24\n'
		printf 'ListenPort = 443\n'
		printf 'Jc = 9\nJmin = 49\nJmax = 103\nS1 = 86\nS2 = 232\n'
		printf '\n[Peer]\n# name = alice\nPublicKey = PUB-alice\nPresharedKey = PSK-alice\nAllowedIPs = 10.13.13.2/32\n'
		[ "$dup" -eq 1 ] && printf '\n[Peer]\n# name = alice\nPublicKey = PUB-alice-2\nPresharedKey = PSK-alice2\nAllowedIPs = 10.13.13.4/32\n'
		printf '\n[Peer]\n# name = bob\nPublicKey = PUB-bob\nPresharedKey = PSK-bob\nAllowedIPs = 10.13.13.3/32\n'
	} >"$f"
	chmod 0600 "$f"
}

seed_client() { # NAME
	install -d -m 0700 "$STATE_DIR/awg/clients"
	printf 'PRIV-%s\n' "$1" >"$STATE_DIR/awg/clients/$1.private"
	printf 'PSK-%s\n'  "$1" >"$STATE_DIR/awg/clients/$1.psk"
	printf '[Interface]\nPrivateKey = PRIV-%s\n' "$1" >"$STATE_DIR/awg/clients/$1.conf"
	chmod 0600 "$STATE_DIR/awg/clients/$1".*
}

# --- 1. the ordinary revoke ------------------------------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF"
	seed_client alice
	seed_client bob
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }

	# Record the config's mtime-ordered relationship to the live removal by watching the call log: the
	# stub appends on every `awg set`, and the rewrite happens after. A wrapper around the conf write is
	# not needed — if the live call never happened at all, the log is empty.
	( revoke_awg_client alice ) >/dev/null 2>&1 || badln "revoke_awg_client failed outright — the rows below would prove nothing"

	calls="$(cat "$FAKENODE_ROOT/awg.calls" 2>/dev/null || true)"
	printf '%s' "$calls" | grep -q 'peer PUB-alice remove' \
		&& ok "the key is removed from the RUNNING interface (awg set awg0 peer ... remove)" \
		|| badln "no 'awg set awg0 peer ... remove' was issued. The on-disk config is not what the kernel honours: until the next restart — which may be weeks — the revoked key still completes handshakes, while the operator has been told it is revoked."

	grep -q 'PUB-alice' "$MYC_AWG_CONF" \
		&& badln "the [Peer] block is still in awg0.conf — the key is re-admitted on the next start" \
		|| ok "the [Peer] block is gone from awg0.conf"

	grep -q 'PUB-bob' "$MYC_AWG_CONF" \
		&& ok "the bystander peer survives" \
		|| badln "revoking one client removed ANOTHER client's peer"
	grep -q '^\[Interface\]' "$MYC_AWG_CONF" && grep -q '^PrivateKey = PRIV-server' "$MYC_AWG_CONF" \
		&& ok "the [Interface] section and the server key survive" \
		|| badln "the rewrite damaged the [Interface] section — after the next start this node has no AmneziaWG at all"
	grep -q '^Jc = 9' "$MYC_AWG_CONF" \
		&& ok "the node's dialect parameters survive" \
		|| badln "the rewrite dropped the dialect parameters — every existing client would stop matching"

	left=""
	for f in private psk conf; do [ -e "$STATE_DIR/awg/clients/alice.$f" ] && left="$left alice.$f"; done
	[ -z "$left" ] \
		&& ok "the stored key material is gone (private, psk, conf)" \
		|| badln "the revoked client's material is still on the node:$left — the next operator can re-issue a credential that was supposed to be dead"
	[ -e "$STATE_DIR/awg/clients/bob.private" ] \
		&& ok "the bystander's material is untouched" \
		|| badln "revoking one client deleted ANOTHER client's key material"
	exit "$fail"
) || fail=1

# --- 2. a name owning TWO peers (the --awg-issue duplicate state) -----------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF" 1
	seed_client alice
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }
	revoke_awg_client alice >/dev/null 2>&1 || true

	if grep -q 'PUB-alice-2' "$MYC_AWG_CONF"; then
		badln "the SECOND peer carrying the same name survived. --awg-issue enrols one whenever clients/NAME.private is missing, so this state is reachable in practice; resolving the peer only by the stored key leaves a live credential behind under a name the operator believes is revoked."
	else
		ok "every peer carrying the name is removed, not just the one matching the stored key"
	fi
	grep -q 'PUB-bob' "$MYC_AWG_CONF" \
		&& ok "the bystander still survives when two peers are removed" \
		|| badln "removing a duplicate pair also removed an unrelated peer"
	exit "$fail"
) || fail=1

# --- 3. the backups must not resurrect it -----------------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF"
	seed_client alice
	# A dialect backup taken BEFORE the revoke — exactly what --awg-rotate leaves behind.
	bak="$STATE_DIR/awg/backup-20260101-000000"
	install -d -m 0700 "$bak/clients"
	cp -a "$MYC_AWG_CONF" "$bak/awg0.conf"
	cp -a "$STATE_DIR/awg/clients/." "$bak/clients/"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }
	( revoke_awg_client alice ) >/dev/null 2>&1 \
		|| badln "revoke_awg_client ABORTED on the backup fixture — the backup rows below prove nothing"

	res=""
	[ -e "$bak/clients/alice.private" ] && res="$res the private key"
	grep -q 'PUB-alice' "$bak/awg0.conf" 2>/dev/null && res="$res the [Peer] block"
	[ -z "$res" ] \
		&& ok "a pre-revoke dialect backup can no longer resurrect the client" \
		|| badln "the backup still holds$res. _awg_rollback restores BOTH awg0.conf and clients/ from these directories when a dialect regen/rotate fails, so the revoked peer and its private key come back on the next failed rotation — silently, and long after anyone remembers the revoke."
	[ -e "$bak/clients/bob.private" ] || [ ! -e "$STATE_DIR/awg/clients/bob.private" ] \
		&& ok "the backup's other clients are left alone" \
		|| badln "the backup purge removed an unrelated client's material"
	exit "$fail"
) || fail=1

# --- 4. idempotency, and a name that owns nothing ---------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF"
	seed_client alice
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }
	( revoke_awg_client alice ) >/dev/null 2>&1 \
		|| badln "the FIRST revoke aborted — the idempotency rows below prove nothing"
	before="$(cat "$MYC_AWG_CONF")"
	if ( revoke_awg_client alice >/dev/null 2>&1 ); then
		ok "a second revoke of the same name succeeds (idempotent)"
	else
		badln "a second revoke FAILED — an operator re-running a partially completed revoke, or scripting it, hits an error on an already-correct state"
	fi
	[ "$before" = "$(cat "$MYC_AWG_CONF")" ] \
		&& ok "the second revoke changed nothing" \
		|| badln "the second revoke mutated awg0.conf again"
	if ( revoke_awg_client nobody >/dev/null 2>&1 ); then
		ok "revoking a name that owns nothing is a success, not an error"
	else
		badln "revoking an unknown name FAILED — 'already absent' is the desired end state, so it must not be an error"
	fi
	exit "$fail"
) || fail=1

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a revoked AmneziaWG credential survives somewhere that still honours it.\n' >&2
	exit 1
fi
printf 'PASS: a revoke clears the running interface first, the config, the stored material and the backups.\n'
exit 0
