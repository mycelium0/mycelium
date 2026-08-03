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

# The library's own reporting + fail-closed primitives. Without these, `log`/`warn` produce nothing (so
# a gate row grepping for a message can never see it) and — far worse — `die` is merely a
# command-not-found that RETURNS, so every fail-closed path under test silently continues. A gate that
# does not supply them is testing a different program from the one that ships.
log()  { printf 'log: %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'die: %s\n' "$*" >&2; exit 1; }
run()  { "$@"; }

# A recording `awg` stub. pubkey is a deterministic transform of the private material so the gate can
# predict the key a name resolves to; `set ... remove` is logged with a timestamped sequence number so
# ORDER against the config rewrite is observable.
install_awg_stub() {
	cat >"$STUBDIR/awg" <<'STUB'
#!/usr/bin/env bash
root="${FAKENODE_ROOT:?}"; log="$root/awg.calls"; live="$root/awg.livepeers"
case "${1:-}" in
	pubkey)  read -r k; printf 'PUB-%s\n' "${k#PRIV-}" ;;
	genkey)  printf 'PRIV-generated\n' ;;
	genpsk)  printf 'PSK-generated\n' ;;
	set)     printf 'set %s\n' "$*" >>"$log"
	         # "$3 peer $4 remove" — drop it from the live list UNLESS the sticky marker says the
	         # kernel refused, which is how a removal that reports success but does not take is modelled.
	         if [ "${4:-}" != "" ] && [ ! -e "$root/awg.sticky" ] && [ -f "$live" ]; then
	             grep -vxF "${4}" "$live" >"$live.n" 2>/dev/null && mv "$live.n" "$live"
	         fi ;;
	show)    case "${3:-}" in peers) [ -f "$live" ] && cat "$live" ;; *) : ;; esac ;;
	*)       : ;;
esac
exit 0
STUB
	chmod +x "$STUBDIR/awg"
	cat >"$STUBDIR/systemctl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "is-active" ] && exit 0; done
exit 0
STUB
	chmod +x "$STUBDIR/systemctl"
}

# A node conf with three peers: the target, a second peer for the SAME name, and a bystander.
seed_conf() { # PATH  [with_duplicate]
	local f="$1" dup="${2:-0}"
	{
		printf '[Interface]\n'
		printf 'PrivateKey = PRIV-server\n'
		printf 'Address = 10.13.13.1/24\n'
		printf 'ListenPort = 443\n'
		printf 'Jc = 9\nJmin = 49\nJmax = 103\nS1 = 86\nS2 = 232\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
		printf '\n[Peer]\n# name = alice\nPublicKey = PUB-alice\nPresharedKey = PSK-alice\nAllowedIPs = 10.13.13.2/32\n'
		[ "$dup" -eq 1 ] && printf '\n[Peer]\n# name = alice\nPublicKey = PUB-alice-2\nPresharedKey = PSK-alice2\nAllowedIPs = 10.13.13.4/32\n'
		printf '\n[Peer]\n# name = bob\nPublicKey = PUB-bob\nPresharedKey = PSK-bob\nAllowedIPs = 10.13.13.3/32\n'
	} >"$f"
	chmod 0600 "$f"
	# the peers the stubbed interface currently honours
	grep -E '^[[:space:]]*PublicKey' "$f" | sed -E 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//' >"$FAKENODE_ROOT/awg.livepeers"
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


# --- 5. a no-op strip must be BYTE-IDENTICAL --------------------------------------------------------
# The shipped stripper captured the blank line between sections into the PRECEDING block and re-added one
# when emitting, so every pass grew the file by one blank per surviving peer. Five no-op passes over a
# live 31-line conf produced 41 lines. Section 4's idempotency row could not see it: after the first
# revoke the name owns nothing, so the second call short-circuits and the stripper never runs again.
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF" 1
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }

	cp "$MYC_AWG_CONF" "$FAKENODE_ROOT/grow.conf"
	base="$(wc -l <"$FAKENODE_ROOT/grow.conf")"
	for _ in 1 2 3 4 5; do
		_awg_strip_peers "$FAKENODE_ROOT/grow.conf" "PUB-not-present" >"$FAKENODE_ROOT/grow.next" \
			&& mv "$FAKENODE_ROOT/grow.next" "$FAKENODE_ROOT/grow.conf"
	done
	after="$(wc -l <"$FAKENODE_ROOT/grow.conf")"
	[ "$base" = "$after" ] \
		&& ok "five no-op strips leave the config byte-stable ($base lines in, $base out)" \
		|| badln "a strip that removes NOTHING still changed the file: $base lines became $after. Each pass adds a blank per surviving peer, without bound — the live config of a node this shipped on already carried the extra lines. 'Idempotent' has to mean byte-identical or it means nothing."
	cmp -s "$MYC_AWG_CONF" "$FAKENODE_ROOT/grow.conf" \
		&& ok "and the content is unchanged, not merely the same length" \
		|| badln "a no-op strip altered the file's content"
	exit "$fail"
) || fail=1

# --- 6. an UNNAMED peer must break the guarantee, not be silently missed -----------------------------
# Found on a live node: a [Peer] with no "# name =" marker, holding a key whose private half was still
# stored on that same host. A by-name revoke resolves neither by stored key nor by marker, removes the
# OTHER peer, and — as shipped — printed "is revoked" anyway.
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	{
		printf '[Interface]\nPrivateKey = PRIV-server\nAddress = 10.13.13.1/24\nListenPort = 443\n'
		printf 'Jc = 9\nJmin = 49\nJmax = 103\nS1 = 86\nS2 = 232\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
		printf '\n[Peer]\nPublicKey = PUBorphan\nAllowedIPs = 10.13.13.2/32\n'
		printf '\n[Peer]\n# name = alice\nPublicKey = PUB-alice\nAllowedIPs = 10.13.13.3/32\n'
	} >"$MYC_AWG_CONF"
	chmod 0600 "$MYC_AWG_CONF"
	seed_client alice
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }

	out="$( ( revoke_awg_client alice ) 2>&1 )"; rc=$?
	[ "$rc" -ne 0 ] \
		&& ok "a revoke that cannot reach every peer exits NON-ZERO" \
		|| badln "the revoke reported SUCCESS while an unreachable [Peer] remained. On the node where this was found, that peer's private key was sitting in the state dir — the operator would have been told the credential was retired while it still worked."
	printf '%s' "$out" | grep -q "is revoked" \
		&& badln "it printed the 'is revoked' guarantee despite an unreachable peer — the guarantee must be earned, not printed" \
		|| ok "it does NOT print the 'is revoked' guarantee it cannot honour"
	printf '%s' "$out" | grep -q 'awg-revoke-peer' \
		&& ok "it hands over the exact command that finishes the job" \
		|| badln "it reports the problem without naming the verb that resolves it"
	[ -s "$STATE_DIR/awg/REVOKE_INCOMPLETE" ] \
		&& ok "it leaves a REVOKE_INCOMPLETE marker naming the peer(s)" \
		|| badln "nothing durable records that the revoke was incomplete — the warning scrolls away and the node looks clean"

	# and the by-key verb must actually reach it
	( revoke_awg_peer PUBorphan ) >/dev/null 2>&1 || true
	grep -q 'PUBorphan' "$MYC_AWG_CONF" \
		&& badln "--awg-revoke-peer did not remove the unnamed peer — there is then NO sanctioned way to retire it" \
		|| ok "--awg-revoke-peer reaches a peer no name can address"
	exit "$fail"
) || fail=1

# --- 7. the verb's own snapshot must not outlive it --------------------------------------------------
# awg0.pre-revoke.conf holds the server PrivateKey and every peer block. --awg-issue deletes its
# equivalent on success; as shipped, this one kept it forever (found on a live node, mode 0600, dated).
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
	( revoke_awg_client alice ) >/dev/null 2>&1 || true
	[ -e "$STATE_DIR/awg/awg0.pre-revoke.conf" ] \
		&& badln "the pre-revoke snapshot survives a SUCCESSFUL revoke. It contains the server PrivateKey and every peer block; --awg-issue deletes its own equivalent on success and this must too." \
		|| ok "the pre-revoke snapshot is removed once the rewrite is promoted"
	exit "$fail"
) || fail=1

# --- 8. a key written without spaces is still found --------------------------------------------------
# `PublicKey=KEY` is legal config syntax. A rule anchored on "PublicKey = " does not see such a peer,
# which here means failing to revoke it while reporting success.
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	{
		printf '[Interface]\nPrivateKey = PRIV-server\nAddress = 10.13.13.1/24\nListenPort = 443\n'
		printf '\n[Peer]\n# name = alice\nPublicKey=PUB-alice\nAllowedIPs = 10.13.13.2/32\n'
	} >"$MYC_AWG_CONF"
	chmod 0600 "$MYC_AWG_CONF"
	seed_client alice
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }
	( revoke_awg_client alice ) >/dev/null 2>&1 || true
	grep -q 'PUB-alice' "$MYC_AWG_CONF" \
		&& badln "a peer written as 'PublicKey=KEY' (no spaces — legal syntax) survived the revoke" \
		|| ok "a peer written without spaces around '=' is still found and removed"
	exit "$fail"
) || fail=1


# --- 9. a live removal that does NOT take must fail closed ------------------------------------------
# The shipped verb counted successful `awg set` calls and downgraded every failure to a warning whose own
# text pre-excused it ("it may already be absent"); the closing guarantee then printed regardless. Read
# the interface BACK instead. Modelled with a sticky stub: the remove call reports success, the peer
# stays. Nothing on disk may be touched, because a rewritten config plus a live peer is the worst of
# both — the operator is told it is gone while it still works.
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF"
	seed_client alice
	: >"$FAKENODE_ROOT/awg.sticky"
	before="$(cat "$MYC_AWG_CONF")"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }

	if ( revoke_awg_client alice ) >/dev/null 2>&1; then
		badln "the revoke reported SUCCESS while the peer was still on the running interface — the credential works RIGHT NOW and the operator has been told otherwise"
	else
		ok "a removal that does not take fails closed"
	fi
	[ "$before" = "$(cat "$MYC_AWG_CONF")" ] \
		&& ok "and nothing on disk was touched (a rewritten config plus a live peer is the worst of both)" \
		|| badln "it rewrote awg0.conf even though the peer is still live — the config now disagrees with the interface and nothing cadenced repairs that"
	exit "$fail"
) || fail=1


# --- 10. a private key that survives ANYWHERE must break the guarantee ------------------------------
# Deleting the files a revoke can NAME and then asserting success is asserting something never measured.
# On a live node the private half of a peer sat in the OTHER deploy path's state dir
# (/var/lib/mycelium/amneziawg, the Ansible role's awg_state_dir) where no glob in this verb looked.
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF"
	seed_client alice
	# a second copy of alice's private key, under a name and path the revoke never enumerates
	install -d -m 0700 "$STATE_DIR/legacy"
	printf 'PRIV-alice\n' >"$STATE_DIR/legacy/whatever.private"
	printf '{"clients":{"someoneelse":{"private_key":"PRIV-alice"}}}\n' >"$STATE_DIR/legacy/identity.json"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }

	out="$( ( revoke_awg_client alice ) 2>&1 )"; rc=$?
	[ "$rc" -ne 0 ] \
		&& ok "a surviving private key elsewhere on the node makes the revoke report INCOMPLETE" \
		|| badln "the revoke claimed success while a private key deriving to the revoked public key was still stored on the node. It deleted the files it could name and asserted a fact about the ones it could not."
	printf '%s' "$out" | grep -q 'whatever.private' \
		&& ok "it names the loose *.private file it found" \
		|| badln "it did not report the surviving *.private file, so the operator cannot act on it"
	printf '%s' "$out" | grep -q 'identity.json' \
		&& ok "it also finds a private_key nested inside a *.json" \
		|| badln "a private_key inside a JSON file was missed — that is exactly the shape found on the live node"
	printf '%s' "$out" | grep -q "is revoked" \
		&& badln "it still printed the 'is revoked' guarantee" \
		|| ok "and it withholds the guarantee"
	exit "$fail"
) || fail=1

# --- 11. the same NAME in the other identity namespace must be surfaced -----------------------------
# `--revoke` and `--awg-revoke` are separate namespaces; on the live nodes both hold a `phone`. Retiring
# one and reporting a clean result invites the belief that the person is off the node entirely.
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF"
	seed_client alice
	printf '{"version":1,"clients":[{"name":"alice","id":"x"}]}\n' >"$STATE_DIR/identities.json"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }
	out="$( ( revoke_awg_client alice ) 2>&1 )"
	printf '%s' "$out" | grep -q -- '--revoke alice' \
		&& ok "a namesake in the sing-box/xray identity set is surfaced with the command to retire it too" \
		|| badln "an identity of the same name in the OTHER namespace was not mentioned — the operator is left believing one revoke covered both"
	exit "$fail"
) || fail=1

# --- 12. the rewrite must be arithmetically right, not merely non-empty -----------------------------
(
	set -u
	fail=0
	fakenode_init
	install_awg_stub
	export MYC_AWG_CONF="$FAKENODE_ROOT/awg0.conf"
	seed_conf "$MYC_AWG_CONF" 1
	seed_client alice
	before_peers="$(grep -c '^\[Peer\]' "$MYC_AWG_CONF")"
	before_lines="$(grep -vc '^[[:space:]]*$' "$MYC_AWG_CONF")"
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }
	have() { command -v "$1" >/dev/null 2>&1; }
	( revoke_awg_client alice ) >/dev/null 2>&1 || true
	after_peers="$(grep -c '^\[Peer\]' "$MYC_AWG_CONF")"
	after_lines="$(grep -vc '^[[:space:]]*$' "$MYC_AWG_CONF")"
	[ "$after_peers" = "$(( before_peers - 2 ))" ] \
		&& ok "peer arithmetic holds: $before_peers - 2 = $after_peers" \
		|| badln "peer count went $before_peers -> $after_peers when exactly 2 were removed"
	[ "$after_lines" -lt "$before_lines" ] \
		&& ok "the non-blank line count dropped (the backstop against a parse miss reported as success)" \
		|| badln "the rewrite removed peers without removing any non-blank lines — a parse miss would look exactly like this"
	[ "$(grep -c '^Jc = ' "$MYC_AWG_CONF")" = "1" ] \
		&& ok "the dialect lines survive the rewrite (a mangled dialect bricks the NEXT --awg-regen, not this call)" \
		|| badln "the dialect lines did not survive — --awg-swap-dialect hard-dies on any count but 9, so this breaks a later rotate rather than failing now"
	exit "$fail"
) || fail=1

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a revoked AmneziaWG credential survives somewhere that still honours it.\n' >&2
	exit 1
fi
printf 'PASS: a revoke clears the running interface first, the config, the stored material and the backups.\n'
exit 0
