#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# client_server_credential_agreement.sh — conformance: for ONE set of params + identities, the client
# subscription the node hands out and the server config the node runs AGREE — every credential the client
# presents is one the server accepts, every SNI the client verifies is one the server presents, and no
# outbound carries a TLS option its transport cannot use.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   A protocol matrix run from a second host (tests/e2e/protocol_matrix_probe.sh, client m1 -> target m2)
#   found FOUR of six served protocols carrying no traffic at all, while the node's own L7 probe reported
#   six of six ALIVE. The probe was not lying: every listener really did complete a handshake. What was
#   broken was the config the node EMITS, and nothing anywhere compared the two halves.
#
#     * hysteria2 + tuic — the client renderer used one shared plainTLS() helper for the TCP families and
#       the QUIC families alike, so both QUIC outbounds carried `tls.utls`. uTLS rewrites a TCP TLS
#       ClientHello and has no QUIC path; sing-box REFUSES the outbound ("unsupported usage for uTLS")
#       rather than ignoring the key. Two protocols dead in every subscription ever issued.
#     * shadowtls — the handshake outbound verified the donor's certificate against the node's own
#       tls_sni. ShadowTLS presents the DONOR's real certificate, so this is x509 mismatch every time.
#     * shadowsocks — the public inbound is SS-2022 multi-user (a server PSK *and* a users list), so the
#       client password must be the pair "<serverPSK>:<userPSK>". A bare PSK is not rejected: the server
#       cannot derive the key and drops the connection silently, with no error on either side.
#
#   Three different mistakes, one shape: the two renderers are separate pure functions of the same params,
#   and nothing asserted they agree. `sing-box check` passes on all of it — these are runtime contracts,
#   not schema violations — and the byte-equivalence gate could not help either, because the shell
#   renderer emits no QUIC family at all, so there was no counterpart to diverge from.
#
# THE RULE IT ENCODES
#   Expectations are DERIVED FROM THE RENDERED SERVER CONFIG, never hardcoded here. The shadowsocks row is
#   the reason: whether the client owes a bare PSK or the pair form depends on whether that inbound
#   carries a users list, and both shapes are live at once on every node (the public inbound is
#   multi-user; the loopback inbound behind ShadowTLS is single-user and takes the bare PSK). A gate that
#   pinned either literal would be wrong for the other and would go stale the moment the server form
#   moves. So this reads what the server will accept and asserts the client sends exactly that.
#
# SKIP-IF-NO-GO: mirrors the other Go-side gates — the jq-only offline host skips, the Go/CI lane runs it.
#
# Exit: 0 = the two halves agree; 1 = a client would be refused (or silently dropped) by its own node;
#       2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'client_server_credential_agreement: cannot resolve repo root\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'client_server_credential_agreement: jq required\n' >&2; exit 2; }

GO="${GO:-go}"
command -v "$GO" >/dev/null 2>&1 || {
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the client/server credential agreement.\n'
	exit 0
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.credagree.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

CTL="$WORK/myceliumctl"
if ! ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
	"$GO" build -o "$CTL" ./cmd/myceliumctl ) >"$WORK/build.err" 2>&1; then
	printf 'client_server_credential_agreement: could not build myceliumctl:\n'; sed 's/^/    /' "$WORK/build.err"
	exit 2
fi

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== client subscription vs server config: do the two halves the node emits agree ==\n'

# QUIC outbound types. uTLS is a TCP-ClientHello library; sing-box refuses a QUIC outbound that carries
# it. Keyed by outbound TYPE, not tag, so a renamed transport is still covered.
is_quic() { case "$1" in hysteria2|tuic) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------------------------------
# check_fixture NAME PARAMS STATE CLIENTNAME
# Renders both halves from the SAME inputs and cross-checks them.
# ---------------------------------------------------------------------------------------------------
check_fixture() {
	local label="$1" params="$2" state="$3" who="$4"
	local d="$WORK/${label// /_}"; mkdir -p "$d/sub"
	local srv="$d/server.json" sub

	printf '\n-- fixture: %s --\n' "$label"
	# --template is REQUIRED by the verb: it does not read the file, it verifies it against the structs
	# it encodes, and naming it is how the caller states which template it believes is in effect.
	if ! "$CTL" render-server --engine singbox --template "$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json" \
		--params "$params" --state "$state" --out "$srv" 2>"$d/srv.err"; then
		badln "render-server failed, so nothing below could be checked: $(head -1 "$d/srv.err")"; return
	fi
	if ! "$CTL" subscription --engine singbox --params "$params" --state "$state" --out "$d/sub" 2>"$d/sub.err"; then
		badln "subscription render failed, so nothing below could be checked: $(head -1 "$d/sub.err")"; return
	fi
	sub="$d/sub/$who.singbox.json"
	[ -f "$sub" ] || { badln "no subscription emitted for client '$who' (looked for $(basename "$sub"))"; return; }

	# The dialable client outbounds, one record per line: tag|type|password|uuid|sni|has_utls.
	#
	# The separator is US (0x1f), NOT a tab, and that is load-bearing. Tab is an IFS *whitespace*
	# character, so `IFS=$'\t' read` collapses runs of it and drops leading ones — a vless row, whose
	# password field is empty, then shifts its SNI into the uuid variable and every assertion below tests
	# the wrong value. It read as four real defects on already-fixed code. US is not whitespace, so empty
	# fields survive.
	local rows
	rows="$(jq -r '.outbounds[]?
		| select((.type|test("selector|urltest|direct|block"))|not)
		| [ .tag, .type, (.password // ""), (.uuid // ""),
		    (.tls.server_name // ""), (if .tls == null then "n/a" else (.tls|has("utls")|tostring) end) ]
		| join("\u001f")' "$sub")"
	[ -n "$rows" ] || { badln "the subscription has no dialable outbound at all — this fixture proves nothing"; return; }

	local checked=0
	while IFS=$'\037' read -r tag typ cpw cuuid csni cutls; do
		[ -n "$tag" ] || continue
		checked=$(( checked + 1 ))

		# ---- 1. transport-class TLS options ---------------------------------------------------------
		if [ "$cutls" != "n/a" ]; then
			if is_quic "$typ"; then
				[ "$cutls" = "false" ] \
					&& ok "$tag: QUIC outbound carries no utls" \
					|| badln "$tag [$typ] carries tls.utls on a QUIC transport. uTLS rewrites a TCP TLS ClientHello and has no QUIC path — sing-box REFUSES the outbound with \"unsupported usage for uTLS\", so this protocol is dead for every client holding this subscription. \`sing-box check\` passes on it and the node's own L7 probe still reports the listener alive. Use the QUIC TLS helper, not the shared plain-TLS one."
			else
				[ "$cutls" = "true" ] \
					&& ok "$tag: TCP TLS outbound carries the uTLS ClientHello preset" \
					|| badln "$tag [$typ] has a TLS block with NO utls. Every TCP TLS family must carry the uTLS preset (RP-0015) — dropping it here silently reverts this transport to Go's stock ClientHello, which is itself a distinguishing fingerprint."
			fi
		fi

		# ---- 2. the credential the server will actually accept for this outbound --------------------
		# Find the inbound this outbound dials. shadowtls-handshake fronts the loopback SS inbound; the
		# routable `shadowtls` outbound IS that loopback SS. Everything else matches on port.
		local inb=""
		case "$tag" in
			shadowtls)           inb="$(jq -c '.inbounds[]?|select(.tag=="shadowtls-ss-in")' "$srv")" ;;
			shadowtls-handshake) inb="$(jq -c '.inbounds[]?|select(.type=="shadowtls")' "$srv")" ;;
			*)
				local cport; cport="$(jq -r --arg t "$tag" '.outbounds[]?|select(.tag==$t)|.server_port // ""' "$sub")"
				[ -n "$cport" ] && inb="$(jq -c --argjson p "${cport:-0}" '.inbounds[]?|select(.listen_port==$p)' "$srv")" ;;
		esac
		if [ -z "$inb" ]; then
			badln "$tag: no server inbound corresponds to this client outbound — the client dials a port the node does not serve"
			continue
		fi

		local spw susers suserpw
		spw="$(printf '%s' "$inb"     | jq -r '.password // ""')"
		susers="$(printf '%s' "$inb"  | jq -r '[.users[]?]|length')"
		suserpw="$(printf '%s' "$inb" | jq -r --arg n "$who" '(.users[]?|select(.name==$n)|.password) // ""')"

		# vless authenticates by UUID, not password.
		if [ "$typ" = "vless" ]; then
			local suuid; suuid="$(printf '%s' "$inb" | jq -r --arg n "$who" '(.users[]?|select(.name==$n)|.uuid) // ""')"
			[ -n "$suuid" ] && [ "$cuuid" = "$suuid" ] \
				&& ok "$tag: the client's UUID is one the server admits" \
				|| badln "$tag: the client presents uuid '$cuuid' but the server admits '${suuid:-<no such user>}' for '$who'"
			continue
		fi

		# Shadowsocks-2022: the accepted form is DERIVED from the inbound's own shape.
		if [ "$typ" = "shadowsocks" ]; then
			local want form
			if [ "$susers" -gt 0 ]; then
				want="$spw:$suserpw"; form="multi-user, so the pair <serverPSK>:<userPSK>"
			else
				want="$spw";         form="single-user, so the bare server PSK"
			fi
			[ "$cpw" = "$want" ] \
				&& ok "$tag: SS-2022 credential matches the inbound's form ($form)" \
				|| badln "$tag: this inbound is $form, but the client sends a different value. SS-2022 does not REJECT a wrong PSK — the server cannot derive the session key and drops the connection with no error on either side, so the transport looks alive from every angle except a real client's."
			continue
		fi

		# Everything else authenticates by password against a per-client user entry.
		if [ "$susers" -gt 0 ]; then
			[ -n "$suserpw" ] && [ "$cpw" = "$suserpw" ] \
				&& ok "$tag: the client's password is the one the server holds for '$who'" \
				|| badln "$tag: the client presents a password the server does not hold for '$who' (server has ${suserpw:+a different value}${suserpw:-no entry for this client})"
		else
			[ "$cpw" = "$spw" ] \
				&& ok "$tag: the client's password matches the inbound's server password" \
				|| badln "$tag: the client's password does not match this single-user inbound's password"
		fi
	done <<<"$rows"

	# ---- 3. the SNI a TLS client verifies must be the one the server will present -------------------
	# ShadowTLS is the case that bit us: the node hands the client the DONOR's certificate, obtained by
	# handshaking to donor_host, so verifying it against the node's own tls_sni fails x509 every time.
	local donor csni_stls
	donor="$(jq -r '(.inbounds[]?|select(.type=="shadowtls")|.handshake.server) // ""' "$srv")"
	csni_stls="$(jq -r '(.outbounds[]?|select(.tag=="shadowtls-handshake")|.tls.server_name) // ""' "$sub")"
	if [ -n "$donor" ] || [ -n "$csni_stls" ]; then
		[ -n "$donor" ] && [ "$csni_stls" = "$donor" ] \
			&& ok "shadowtls-handshake: the client verifies the donor's name ($donor), which is the certificate the node presents" \
			|| badln "shadowtls-handshake: the client verifies '${csni_stls:-<unset>}' but the node presents the certificate of '${donor:-<no donor>}'. ShadowTLS relays the DONOR's real certificate — verifying it against the node's own tls_sni is an x509 mismatch on every single connection."
	fi

	[ "$checked" -gt 0 ] && printf '  (%d client outbounds cross-checked against the rendered server config)\n' "$checked"
}

# --- Fixture A: every sing-box family on, client WITH a per-identity password ------------------------
# The per-identity password is load-bearing: it is what makes the client's secret differ from the shared
# protocol secret, so a renderer that reaches for the wrong one of the two is visible here and invisible
# in fixture B.
PA="$WORK/pa.json"; SA="$WORK/sa.json"
jq -n '{
	node_address: "node.example.invalid",
	donor_host: "www.example.invalid", donor_sni: "www.example.invalid",
	reality_public_key: "PUB", reality_private_key: "PRIVDUMMY", short_ids: [ "0123abcd" ],
	tls_sni: "tls.example.invalid",
	ss_password: "SSPW", trojan_password: "TRPW", hysteria2_password: "HYPW", shadowtls_password: "STPW",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_ws_tls_enabled:         true, vless_ws_tls_port:         2089,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	tuic_enabled:                 true, tuic_port:                 8445,
	shadowsocks_enabled:          true, shadowsocks_port:          8388,
	shadowtls_enabled:            true, shadowtls_port:            8446,
	trojan_enabled:               true, trojan_port:               8447
}' > "$PA"
jq -n '{ version: 1, clients: [
	{ name: "alice", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z", password: "IDPW" }
] }' > "$SA"
check_fixture "A: all families, per-identity password" "$PA" "$SA" "alice"

# --- Fixture B: the shared-secret fallback path (no per-identity password) ---------------------------
# A DIFFERENT code path on both sides (pwOr / or), and the one where the SS pair form degenerates to
# "<serverPSK>:<serverPSK>" — still the pair, which a naive "if they're equal, send one" would break.
PB="$WORK/pb.json"; SB="$WORK/sb.json"
jq -n '{
	node_address: "node2.example.invalid",
	donor_host: "donor.example.invalid", donor_sni: "donor.example.invalid",
	reality_public_key: "PUB2", reality_private_key: "PRIVDUMMY2", short_ids: [ "feed0001" ],
	ss_password: "SS_SECRET", hysteria2_password: "HY_SECRET", shadowtls_password: "STLS_SECRET", trojan_password: "TR_SECRET",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	tuic_enabled:                 true, tuic_port:                 8445,
	shadowsocks_enabled:          true, shadowsocks_port:          8388,
	shadowtls_enabled:            true, shadowtls_port:            8446
}' > "$PB"
jq -n '{ version: 1, clients: [
	{ name: "carol", id: "ca501000-0000-4000-8000-000000000000", created: "2026-01-01T00:00:00Z" }
] }' > "$SB"
check_fixture "B: shared-secret fallback, no per-identity password" "$PB" "$SB" "carol"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the subscription the node hands out disagrees with the config the node runs — a client\n' >&2
	printf 'holding it would be refused or silently dropped on at least one advertised protocol.\n' >&2
	exit 1
fi
printf 'PASS: every credential, SNI and TLS option in the emitted subscription agrees with the served config.\n'
exit 0
