# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_selftest.sh — node-bootstrap library: node-local L7 transport LIVENESS probe (ADR-0036).
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: confirm each CLIENT-FACING transport in the live config is usable at L7 — the
# truth that verify_listen_ports (L4, "is the port bound") cannot see. A bound listener can still be
# client-DEAD: a broken REALITY dest that fails the authenticated handshake-steal (the 2026-07-01
# www.microsoft.com regression), an expired/mismatched own cert. TWO sibling probes: `measure_l7_probe`
# is the ADR-0036 own-cert/cover-path check for the sing-box transports — genuine-TLS = an openssl loopback
# handshake against the node's OWN listener; REALITY = an authenticated ephemeral steal against the node's
# OWN dest/cover host (donor_verify_reality) — probe-side retry-debounce, NO third-party beacon; it writes a
# marker to the path passed as $1 (default the daemon marker $STATE_DIR/l7_selftest.json), folded into the
# rotation loop's DetectorSignal.ActiveProbeOK. `measure_l7_probe_amneziawg` is the AmneziaWG data-plane
# check (a real LOOPBACK WireGuard handshake against awg0 — a separate UDP engine the sing-box probe cannot
# see); it is ADVISORY/ACCEPTANCE ONLY, on its OWN marker (default $STATE_DIR/l7_awg.json), NOT folded into
# rotation (AmneziaWG is not a rotatable member). CALLERS: the cadenced mycelium-l7probe.timer + the
# post-apply acceptance hook in verify_post_apply run measure_l7_probe against DISTINCT markers (the daemon
# vs $STATE_DIR/l7_postapply.json, so acceptance never clobbers the daemon marker — Audit-0007 S2); the
# post-apply hook + the on-demand `--l7-probe-awg` verb run the AmneziaWG probe.
# CLASSIFICATION: OS-glue — spins the engines + probes (sing-box, openssl, amneziawg-go); renders NOTHING,
# decides NO policy. ADVISORY: WARNs + records a marker, NEVER rolls back. SOURCED into
# scripts/node-bootstrap.sh, never executed directly; relies on the entrypoint globals (SINGBOX_BIN,
# SINGBOX_CONFIG, STATE_DIR) + helpers (have/log/warn) at call time.


# measure_l7_probe — node-local, low-fingerprint L7 liveness for the CLIENT-FACING transports, for the
# MEASURE loop (RP-0010 AC-6 clarification: the own-cert/cover-path signal, NOT an external beacon).
# For each enabled client-facing inbound in the LIVE config it does a HANDSHAKE-only liveness check,
# per transport type:
#   * a REALITY listener's failure mode (a broken dest, e.g. www.microsoft.com) completes ordinary TLS
#     and the server's UNAUTHENTICATED fallback relay — only the AUTHENTICATED steal breaks — so a plain
#     openssl handshake would MISS it. We instead run the authenticated ephemeral REALITY handshake
#     against dest (donor_verify_reality — the same steal-viability the live server depends on), which
#     catches the exact broken-dest failure (the 2026-07-01 regression) the L4 reach probe cannot see.
#     It contacts ONLY the node's own cover/dest host (the cover traffic REALITY already produces — the
#     lowest-fingerprint external contact, not a third-party beacon), never a tunnel/third party.
#   * a genuine-TLS listener presents its OWN cert over loopback, so an openssl handshake to
#     127.0.0.1:<port> completes + the cert is non-expired IFF the TLS is healthy — PURE loopback, no
#     external contact at all.
# Emits $STATE_DIR/l7_selftest.json = {observed_at, checked, dead:[REFS]} keyed by MEASURE ref (the
# inbound tag minus its "-in" suffix, matching nb_measure's member refs). The myceliumd measure loop
# reads this marker (fail-safe: absent/stale -> healthy). Best-effort: missing openssl/jq -> no marker
# (the daemon then folds healthy). A member is marked dead only after it fails EVERY retry within the run
# (a probe-side debounce, since the persisted marker would otherwise turn a one-off flake into a
# sustained-blocked verdict downstream). A healthy member passes on the first attempt, so the steady cost
# is one check per inbound; meant to run on a budgeted, jittered cadence (the hyphal-probe invariants,
# VIS-0004), NOT every tick. Self-cleaning.
# COVERAGE (Audit-0007 S2 + RP-0014 chunk A, honest scope): measure_l7_probe covers the sing-box REALITY
# families (vless-reality-vision/-grpc/-xhttp — the authenticated dest steal, identical mechanism), the
# own-cert genuine-TLS families ws-tls and trojan (loopback SAN match — the same own cert, the same
# check; trojan was enumerated late, so it carried an L4-only verdict while its shape was already
# covered), the QUIC families hysteria2/tuic (a real sing-box client
# handshake + protocol auth over loopback — _l7_probe_quic_dial), and ShadowTLS v3 (the real inner-SS-over-
# outer-ShadowTLS handshake, the outer layer relaying the node's cover — _l7_probe_shadowtls_dial). AmneziaWG
# (a separate UDP engine, never in the sing-box config) is covered by the SIBLING probe
# measure_l7_probe_amneziawg (a real loopback WG handshake) — an ADVISORY/ACCEPTANCE signal on its OWN marker,
# NOT folded into the sing-box rotation loop (AmneziaWG is not a rotatable measure member: a standalone
# always-on tunnel with no in-engine sibling to promote). The Xray-served vless-xhttp-tls (a separate config,
# a distinct engine, never a sing-box measure member) is covered by the SIBLING probe measure_l7_probe_xhttp
# — an ADVISORY/ACCEPTANCE own-cert outer-TLS check (openssl loopback to the xray port; a sing-box client
# cannot dial xhttp, so the inner xhttp/VLESS layer is a documented residual).
#
# STANDALONE Shadowsocks-2022 is covered by _l7_probe_shadowsocks_dial, on a criterion no other family
# uses: a DATA ROUND TRIP. SS-2022 completes no observable handshake, so the hold-until-timeout criterion
# every TLS/QUIC family judges by ("the connection was still open when the timeout killed it") reads ALIVE
# against a listener whose key no longer matches — a false-alive on precisely the failure the probe exists
# to catch. Bytes that come BACK through the tunnel cannot be produced by anything but a server that
# decrypted the request, so the probe dials a target that SPEAKS FIRST (this node's own sshd) THROUGH its
# own SS listener and judges on those bytes; when none come back, a CONTROL dial of the SAME target over a
# plain `direct` outbound separates a dead listener (control speaks -> DEAD) from an unusable target
# (control silent -> cannot-judge, NEVER dead). The target is the node's own PUBLIC address, not
# 127.0.0.1: the live config BLOCKS private destinations (route rule `ip_is_private -> block`, a control
# this probe must not weaken), while the address is one the kernel already holds — so the dial is routed
# through `lo` and still puts no packet on the wire (the ADR-0036 boundary, amended there for this
# family). This matters because SS is the LAST-RESORT exposure tier (spec.ExposureNoCover): the axis
# reached when nothing safer is left is the one whose silent death is most expensive.
#
# Coverage is asserted here, never a silent claim, per ADR-0036.
# _l7_singbox_dial OUTBOUNDS_JSON TIMEOUT — the SHARED sing-box-as-client dial + classify used by the QUIC
# and ShadowTLS L7 probes (openssl speaks neither QUIC nor the ShadowTLS/SS layering). OUTBOUNDS_JSON is the
# pre-built outbound ARRAY whose FIRST element is tagged "probe-out"; it is wrapped as {log, outbounds} into
# a 0600 temp config, then `sing-box tools connect -o probe-out 127.0.0.1:1` (a CLOSED loopback target) runs
# under `timeout TIMEOUT`. Classify:
#   * exit 124 — the timeout KILLED a still-open connection: a LIVE data-plane completes the handshake in
#     <1s and stays active (keepalives), so it HOLDS -> ALIVE (0). The caller MUST set TIMEOUT above the
#     engine's handshake/idle deadline so a bound-but-WEDGED listener (accepts, never completes) fails its
#     handshake FIRST rather than being killed mid-attempt -> false-ALIVE.
#   * a FAST exit whose stderr carries an UNAMBIGUOUS server-side handshake/auth-failure signature — the
#     "connect to server" outbound-dial prefix (wedged/down/wrong-port/handshake-deadline) plus tuic's
#     post-handshake "application error" and "authenticat" — -> DEAD (1). NOT bare timeout/refused/reset/EOF,
#     which a HEALTHY dial's refusal of the closed target can also emit.
#   * anything else (a config-schema / tooling error, e.g. a sing-box version bump renaming a field) ->
#     cannot-judge (2), never a spurious dead that would rotate a healthy transport network-wide (ADR-0036).
# The creds transit OUTBOUNDS_JSON + the 0600 temp file (removed after the dial); avoid `set -x` here. Single
# mktemp + single cleanup + single return (a RETURN trap is not function-scoped without functrace). Loopback.
_l7_singbox_dial() {
	local ob="$1" to="$2"
	[ -n "${SINGBOX_BIN:-}" ] && [ -x "$SINGBOX_BIN" ] || return 2
	command -v timeout >/dev/null 2>&1 || return 2   # the ALIVE signal IS the timeout kill (exit 124)
	[ -n "$ob" ] || return 2
	local tmpc err rc verdict=2
	tmpc="$(mktemp 2>/dev/null)" || return 2
	if ( umask 077; printf '{"log":{"level":"error"},"outbounds":%s}\n' "$ob" >"$tmpc" ) 2>/dev/null; then
		rc=0
		err="$(: | timeout "$to" "$SINGBOX_BIN" tools connect -c "$tmpc" -o probe-out 127.0.0.1:1 2>&1 >/dev/null)" || rc=$?
		if [ "$rc" -eq 124 ]; then
			verdict=0
		elif grep -qiE 'connect to server|authenticat|application error|handshake|unreachable|no route' <<<"$err" ; then
			verdict=1
		else
			verdict=2
		fi
	fi
	rm -f "$tmpc" 2>/dev/null
	return "$verdict"
}

# _l7_probe_quic_dial TAG TYPE PORT SNI — QUIC (hysteria2/tuic) L7 liveness. Returns 0 alive / 1 dead /
# 2 cannot-judge. (a) an openssl EXPIRY-ONLY check on the served cert FILE — the shared per-node own-cert is
# self-signed / CN=donor / NO-SAN / sha256-PINNED (ADR-0014), so a SAN/CA check would false-DEAD a HEALTHY
# node, but an EXPIRED served cert breaks every verifying/pinning client -> a definitive per-family dead
# (absent/unreadable cert -> skip, fail-safe). (b) a real QUIC dial via _l7_singbox_dial with tls.insecure=
# true (cert already checked in (a); the pinned own-cert has no CA chain). TIMEOUT 7 > sing-box's ~5s QUIC
# handshake timeout so a bound-but-wedged listener fails its handshake -> DEAD rather than holding -> ALIVE.
_l7_probe_quic_dial() {
	local tag="$1" type="$2" port="$3" sni="$4"
	[ -n "$sni" ] && [ -n "$port" ] || return 2
	local cert
	cert="$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.certificate_path // ""' "$SINGBOX_CONFIG" 2>/dev/null)"
	if [ -n "$cert" ] && [ -f "$cert" ] && have openssl; then
		openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1   # EXPIRED served cert -> DEAD
	fi
	local ob
	if [ "$type" = "tuic" ]; then
		ob="$(jq -c --arg tag "$tag" --arg sni "$sni" --argjson port "$port" \
			'.inbounds[] | select(.tag==$tag) | .users[0] as $u
			 | [{type:"tuic",tag:"probe-out",server:"127.0.0.1",server_port:$port,uuid:$u.uuid,password:($u.password // $u.uuid),congestion_control:"bbr",tls:{enabled:true,server_name:$sni,insecure:true,alpn:["h3"]}}]' \
			"$SINGBOX_CONFIG" 2>/dev/null)"
	else
		ob="$(jq -c --arg tag "$tag" --arg sni "$sni" --argjson port "$port" \
			'.inbounds[] | select(.tag==$tag) | .users[0].password as $pw
			 | [{type:"hysteria2",tag:"probe-out",server:"127.0.0.1",server_port:$port,password:$pw,tls:{enabled:true,server_name:$sni,insecure:true,alpn:["h3"]}}]' \
			"$SINGBOX_CONFIG" 2>/dev/null)"
	fi
	# well-formed iff non-empty AND the credential/port are non-null (a malformed / foreign inbound with
	# missing users or listen_port -> valid-shaped but unusable -> cannot-judge, NOT dead).
	{ [ -n "$ob" ] && printf '%s' "$ob" | jq -e '.[0] | (.password // .uuid) != null and .server_port != null' >/dev/null 2>&1; } || return 2
	_l7_singbox_dial "$ob" 7
}

# _l7_probe_shadowtls_dial TAG PORT — ShadowTLS (v3) L7 liveness. The client-facing shadowtls inbound wraps
# a hidden loopback shadowsocks-2022 detour, and its OUTER TLS handshake is a genuine relay to the node's
# COVER host (handshake.server) — so we reconstruct the real two-outbound client (inner SS-2022 detoured
# through the outer ShadowTLS) from the live config and dial it via _l7_singbox_dial. NO node-cert-expiry
# check: the outer handshake presents the COVER's cert (relayed), not the node's own cert. TIMEOUT 17 >
# sing-box's ~15s TLS handshake deadline so a bound-but-black-holed listener (accepts TCP, never completes
# the handshake) fails -> DEAD, not held -> false-ALIVE. Returns 0 alive / 1 dead / 2 cannot-judge.
_l7_probe_shadowtls_dial() {
	# fp (RP-0015): the client uTLS ClientHello preset the reconstructed probe-client mimics, so the L7
	# handshake reflects what real clients send (a filtered fingerprint reads DEAD here). Default "chrome".
	local tag="$1" port="$2" fp="${3:-chrome}"
	[ -n "$port" ] || return 2
	local ob
	ob="$(jq -c --arg tag "$tag" --argjson port "$port" --arg fp "$fp" \
		'.inbounds as $in
		 | ($in[] | select(.tag==$tag)) as $stls
		 | ($in[] | select(.tag==($stls.detour))) as $ss
		 | [ {type:"shadowsocks",tag:"probe-out",method:$ss.method,password:$ss.password,detour:"probe-stls"},
		     {type:"shadowtls",tag:"probe-stls",server:"127.0.0.1",server_port:$port,version:3,password:$stls.users[0].password,tls:{enabled:true,server_name:$stls.handshake.server,utls:{enabled:true,fingerprint:$fp}}} ]' \
		"$SINGBOX_CONFIG" 2>/dev/null)"
	# well-formed iff both secrets + the port + the cover SNI are present (a legacy/foreign config with an
	# EMPTY ss/shadowtls secret, or a missing detour, -> cannot-judge, NOT dead).
	{ [ -n "$ob" ] && printf '%s' "$ob" | jq -e '(.[0].password // "") != "" and (.[1].password // "") != "" and .[1].server_port != null and (.[1].tls.server_name // "") != ""' >/dev/null 2>&1; } || return 2
	_l7_singbox_dial "$ob" 17
}

# _l7_own_public_addr — echo this node's first LOCALLY-ASSIGNED, PUBLIC address (IPv4 preferred, then
# IPv6 global unicast); empty output + rc 1 when there is none. Two properties make this the only kind of
# address the Shadowsocks probe may aim at, and BOTH are load-bearing:
#   * LOCALLY ASSIGNED — the kernel routes a dial to an address held on one of its OWN interfaces through
#     `lo`, so the probe still puts NO packet on the wire (the ADR-0036 boundary), and it does not depend
#     on the provider hairpinning traffic sent to its own public address.
#   * PUBLIC — the live served config BLOCKS private destinations (`route.rules: ip_is_private -> block`),
#     a deliberate control this probe must not weaken. Were the target a PRIVATE own-address, that rule
#     would block the tunnelled dial while the CONTROL dial (a plain `direct` outbound in the probe's own
#     config, which carries no route rules) still succeeded — manufacturing a FALSE DEAD on a healthy
#     listener. The asymmetry is eliminated by never selecting such an address, not by relaxing the rule.
# The reject list is a strict SUPERSET of sing-box's `ip_is_private` (RFC1918 + loopback + link-local, plus
# CGNAT / benchmarking / IETF-protocol / multicast, and for IPv6 everything outside global unicast
# 2000::/3 — which excludes ULA fc00::/7). Over-rejection is SAFE BY CONSTRUCTION: a rejected candidate
# can only ever cost a cannot-judge verdict, never a false dead. Local detection only, no external service
# contacted. It deliberately does NOT reuse params.node_address: that value is operator-settable and may
# be a HOSTNAME pointing at a front/CDN — i.e. not this host, which would break both properties above.
_l7_own_public_addr() {
	have ip || return 1
	local cand a
	cand="$( { ip -o -4 addr show scope global; ip -o -6 addr show scope global; } 2>/dev/null \
		| awk '{print $4}' | cut -d/ -f1 || true)"
	for a in $cand; do
		case "$a" in
			*:*)
				# IPv6: accept ONLY global unicast 2000::/3 (rejects ULA fd00::/8 and link-local fe80::/10).
				case "$a" in 2*|3*) printf '%s\n' "$a"; return 0 ;; *) continue ;; esac ;;
			*)
				case "$a" in
					0.*|10.*|127.*|169.254.*|192.168.*|192.0.0.*|198.1[89].*)     continue ;;
					172.1[6-9].*|172.2[0-9].*|172.3[01].*)                        continue ;;
					100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) continue ;;
					22[4-9].*|2[3-4][0-9].*|25[0-5].*)                            continue ;;
					*) printf '%s\n' "$a"; return 0 ;;
				esac ;;
		esac
	done
	return 1
}

# _l7_connect_bytes OUTBOUNDS_JSON TARGET — dial TARGET through the FIRST outbound of OUTBOUNDS_JSON
# (tagged "probe-out") with sing-box as the client, send a one-byte payload, hold the connection briefly,
# and report whether the target sent anything BACK: rc 0 = bytes received, rc 1 = none (or setup failed).
#
# WHY A BYTE CRITERION rather than _l7_singbox_dial's hold-until-timeout one: Shadowsocks-2022 completes
# no observable handshake. The client encrypts and sends; a listener whose key no longer matches simply
# never replies, and the connection is HELD OPEN in both the healthy and the key-drifted case — so
# "exit 124 = alive" (correct for the TLS/QUIC families, whose engines answer or fail the handshake) reads
# ALIVE on a dead listener. Only a DATA ROUND TRIP is honest evidence.
#
# WHY THE PAYLOAD IS NOT OPTIONAL: SS-2022 flushes its request header together with the FIRST PAYLOAD, so
# a dial with EMPTY stdin (what every TLS-family probe here passes) never sends the header at all and the
# server logs a bare EOF — the connection looks identical to a dead one. This cost three wrong
# "SS liveness is unmeasurable" verdicts before it was found; the newline is the fix, not a formality.
#
# WHY stdin IS HELD: without the hold the client's own stdin-EOF teardown races the target's reply. A
# loopback banner lands in ~100 ms so 1 s is generous, and the verdict stops depending on that race;
# `timeout` is only the outer bound for a client that never exits at all. The dial's EXIT STATUS is
# deliberately ignored — a healthy dial ends either by the target closing or by the timeout kill, and
# neither is evidence either way. Creds transit OUTBOUNDS_JSON + the 0600 temp config (removed after the
# dial); avoid `set -x` here.
_l7_connect_bytes() {
	local ob="$1" tgt="$2" tmpc tmpo rc=1
	[ -n "${SINGBOX_BIN:-}" ] && [ -x "$SINGBOX_BIN" ] || return 1
	command -v timeout >/dev/null 2>&1 || return 1
	[ -n "$ob" ] && [ -n "$tgt" ] || return 1
	tmpc="$(mktemp 2>/dev/null)" || return 1
	tmpo="$(mktemp 2>/dev/null)" || { rm -f "$tmpc" 2>/dev/null; return 1; }
	if ( umask 077; printf '{"log":{"level":"error"},"outbounds":%s}\n' "$ob" >"$tmpc" ) 2>/dev/null; then
		{ printf '\n'; sleep 1; } \
			| timeout 5 "$SINGBOX_BIN" tools connect -c "$tmpc" -o probe-out "$tgt" >"$tmpo" 2>/dev/null || true
		if [ -s "$tmpo" ]; then rc=0; fi
	fi
	rm -f "$tmpc" "$tmpo" 2>/dev/null
	return "$rc"
}

# _l7_probe_shadowsocks_dial TAG PORT — STANDALONE Shadowsocks-2022 L7 liveness (the LAST-RESORT exposure
# tier, spec.ExposureNoCover). Returns 0 alive / 1 dead / 2 cannot-judge. Three steps:
#
#   (1) TARGET. A family judged by a data round trip needs a target that SPEAKS FIRST — otherwise silence
#       proves nothing. The node's own sshd is the one such service a node always runs, reached at the
#       node's own PUBLIC address (see _l7_own_public_addr for why public and why locally-assigned). The
#       sshd port is read from the running config, falling back to 22; either way step (3) validates the
#       choice before any DEAD verdict, so a wrong guess costs a cannot-judge, not a false dead.
#   (2) PROBE CLIENT, reconstructed from the LIVE inbound so a rotated secret is caught. The password form
#       is the one SS-2022 multi-user detail that silently breaks a probe: an inbound with `users[]` takes
#       `server_psk:user_psk`, and sending the server PSK alone is REJECTED exactly like a wrong key — the
#       "correct" arm then fails for the same reason as the negative arm and the probe proves nothing. A
#       single-user inbound (no `users[]`) takes the bare server PSK.
#   (3) VERDICT. Bytes back through the tunnel -> ALIVE, and no control dial is needed (the round trip
#       already proves the listener decrypted the request), so the healthy path costs ONE dial. No bytes
#       is AMBIGUOUS — a dead listener and an unreachable/silent target look identical from inside the
#       tunnel — so the same target is dialled over a plain `direct` outbound: control speaks -> the
#       tunnel is what failed -> DEAD; control silent (no sshd, a firewalled hairpin, a fail2ban ban on
#       the node's own address) -> cannot-judge. FAIL-SAFE by construction: every precondition failure
#       (no sing-box/timeout/jq, no public own-address, a malformed or secret-less inbound) returns 2, so
#       this probe can only ever mark the last-resort transport dead on POSITIVE evidence that its own
#       target is fine.
#
# LOG NOTE (honest, operator-visible): the newline payload is not a valid SSH identification string, so
# each run leaves one benign line in the node's own sshd log ("banner exchange: ... invalid format") from
# the node's own address. That is the whole footprint; nothing is contacted off-host.
_l7_probe_shadowsocks_dial() {
	local tag="$1" port="$2"
	[ -n "${SINGBOX_BIN:-}" ] && [ -x "$SINGBOX_BIN" ] || return 2
	command -v timeout >/dev/null 2>&1 || return 2
	have jq || return 2
	[ -n "$tag" ] && [ -n "$port" ] || return 2

	# (1) the banner-first target.
	local addr sshport tgt
	addr="$(_l7_own_public_addr)" || return 2
	[ -n "$addr" ] || return 2
	sshport="$(sshd -T 2>/dev/null | sed -n 's/^port[[:space:]]*//p' | head -n1)" || sshport=""
	case "$sshport" in ''|*[!0-9]*) sshport=22 ;; esac
	case "$addr" in *:*) tgt="[$addr]:$sshport" ;; *) tgt="$addr:$sshport" ;; esac

	# (2) the probe client.
	# WHICH USER THE PROBE AUTHENTICATES AS (Audit-0009 F1). The round trip goes through the node's OWN
	# served config, so it is subject to the SERVED ROUTE RULES — including a two-hop overlay, which routes
	# a designated client (`auth_user`) out to an upstream node. Authenticating as that client would send
	# the probe's traffic OFF THIS HOST, silently voiding the ADR-0036 boundary the probe is built on
	# ("no packet on the wire"), and would attribute synthetic traffic to a named person.
	#
	# So the user is CHOSEN, not assumed: the first inbound user that no route rule sends anywhere but
	# direct. The authority is the served config's own route rules, not two_hop.json — the rules are what
	# actually route, and a stale or hand-edited overlay would mislead. If EVERY user is routed off-host,
	# the probe returns cannot-judge below rather than quietly breaking its own invariant: losing coverage
	# on such a node is the correct trade against emitting traffic the ADR says we never emit.
	local ob
	ob="$(jq -c --arg tag "$tag" --argjson port "$port" \
		'([ .route.rules[]? | select(.outbound != "direct" and .outbound != "block")
		    | .auth_user // [] ] | flatten) as $offhost
		 | .inbounds[] | select(.tag==$tag)
		 | ([ (.users // [])[] | select((.name // "") as $n | ($offhost | index($n)) | not) ] | .[0]) as $u
		 | if ((.users // []) | length) > 0 and $u == null then empty else . end
		 | (if ((.users // []) | length) > 0
		    then ((.password // "") + ":" + ($u.password // ""))
		    else (.password // "") end) as $pw
		 | [{type:"shadowsocks",tag:"probe-out",server:"127.0.0.1",server_port:$port,method:.method,password:$pw}]' \
		"$SINGBOX_CONFIG" 2>/dev/null)" || ob=""
	if [ -z "$ob" ]; then
		log "SS probe: every inbound user is routed off-host by a route rule (two-hop); declining to probe rather than emit traffic the ADR-0036 boundary forbids."
		return 2
	fi
	# well-formed iff the method, the port AND every secret in the composed password are present — the
	# `^:|:$` test rejects a multi-user inbound with an empty server OR user PSK, which would otherwise
	# dial with a valid-SHAPED but unusable credential and read DEAD on a healthy listener.
	{ [ -n "$ob" ] && printf '%s' "$ob" | jq -e '.[0]
		| (.method // "") != "" and (.password // "") != ""
		  and ((.password | test("^:|:$")) | not) and .server_port != null' >/dev/null 2>&1; } || return 2

	# (3) the verdict.
	if _l7_connect_bytes "$ob" "$tgt"; then return 0; fi
	if _l7_connect_bytes '[{"type":"direct","tag":"probe-out"}]' "$tgt"; then return 1; fi
	return 2
}

measure_l7_probe() {
	have openssl && have jq || return 0
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local marker="${1:-$STATE_DIR/l7_selftest.json}" dead="" unknown="" tested=0 row
	local TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 8"
	# RP-0015: resolve the client uTLS preset ONCE (single source: params.client_fingerprint, normalised
	# against the closed vocab) so every mimicking probe below (the ShadowTLS reconstruction, the ephemeral
	# REALITY verify-client) dials with the SAME fingerprint real clients send — a filtered fingerprint then
	# reads client-DEAD here. Best-effort: an unreadable/absent params resolves to the "chrome" default.
	local fp; fp="$(myc_client_fingerprint "$(jq -c . "${PARAMS_JSON:-}" 2>/dev/null || printf '{}')")"
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		local tag ref port reality sni dest type drc qrc ok=0 vrc=2 attempt
		tag="$(printf '%s'     "$row" | jq -r '.tag')"
		type="$(printf '%s'    "$row" | jq -r '.type // ""')"
		port="$(printf '%s'    "$row" | jq -r '.port')"
		reality="$(printf '%s' "$row" | jq -r '.reality')"
		sni="$(printf '%s'     "$row" | jq -r '.sni // ""')"
		dest="$(printf '%s'    "$row" | jq -r '.dest // ""')"
		ref="${tag%-in}"
		# RETRY within the run so a SINGLE transient blip (e.g. the cover host briefly unreachable) never
		# writes a dead marker. The marker PERSISTS across many daemon ticks, so downstream anti-flap
		# (which counts ticks, not probe runs) would read a one-off flake as SUSTAINED-blocked and
		# spuriously rotate a healthy transport. A healthy member passes attempt 1 (no retry cost); only a
		# member that fails EVERY attempt is marked dead. This probe-side debounce is the containment the
		# tick-side cannot provide.
		if [ "$type" = "shadowtls" ]; then
			# ShadowTLS (v3): a REAL inner-SS-over-outer-ShadowTLS handshake (the outer TLS relays the node's
			# cover host); _l7_probe_shadowtls_dial reconstructs both layers from the live config. A bound-but-
			# client-DEAD listener (a wedged/black-holed engine, a broken cover relay, a rotated inner/outer
			# secret) is caught here instead of passing the L4-only reach window.
			for attempt in 1 2 3; do
				qrc=0; _l7_probe_shadowtls_dial "$tag" "$port" "$fp" || qrc=$?
				# 0 = alive, 2 = cannot judge (sing-box/timeout absent) -> NOT dead; 1 = dead -> retry-debounce.
				[ "$qrc" -ne 1 ] && { ok=1; vrc="$qrc"; break; }
				sleep 1
			done
		elif [ "$type" = "shadowsocks" ]; then
			# STANDALONE Shadowsocks-2022: a DATA ROUND TRIP through the node's own SS listener to a
			# target that speaks first, with a control dial deciding the ambiguous no-bytes case
			# (_l7_probe_shadowsocks_dial). This family has no observable handshake, so a key-drifted,
			# wedged or down listener is invisible to every other criterion in this probe — and it is the
			# LAST-RESORT tier, the one a planner reaches only when nothing safer is viable.
			for attempt in 1 2 3; do
				qrc=0; _l7_probe_shadowsocks_dial "$tag" "$port" || qrc=$?
				# 0 = alive, 2 = cannot judge (no tooling / no public own-address / control silent) -> NOT
				# dead; 1 = dead -> retry-debounce.
				[ "$qrc" -ne 1 ] && { ok=1; vrc="$qrc"; break; }
				sleep 1
			done
		elif [ "$type" = "hysteria2" ] || [ "$type" = "tuic" ]; then
			# QUIC (hysteria2/tuic): openssl cannot speak QUIC, so we complete a REAL handshake + protocol
			# auth against the own listener with sing-box as the client, plus an expiry check on the served
			# cert file (_l7_probe_quic_dial, loopback-only). A bound-but-client-DEAD QUIC listener (an
			# EXPIRED served cert, wrong/rotated auth, a wedged engine) is caught here instead of passing the
			# L4-only reach window.
			# A SKIP is not a pass (Audit-0009 U1). This incremented `checked` and touched neither list, so a
			# member with no usable SNI counted toward coverage while proving nothing — the same overclaim as
			# the folded cannot-judge, on the sibling path.
			[ -n "$sni" ] || { tested=$(( tested + 1 )); unknown="$unknown $ref"; continue; }
			for attempt in 1 2 3; do
				# `qrc=0; ... || qrc=$?` mirrors the REALITY branch: under `set -e` a bare dead-return (rc 1)
				# would abort before the marker is written. 0 = alive, 2 = cannot judge (sing-box/timeout
				# absent) -> NOT dead; 1 = dead -> retry-debounce (a one-off blip never writes a dead marker).
				qrc=0; _l7_probe_quic_dial "$tag" "$type" "$port" "$sni" || qrc=$?
				[ "$qrc" -ne 1 ] && { ok=1; vrc="$qrc"; break; }
				sleep 1
			done
		elif [ "$reality" = "true" ]; then
			# REALITY: the broken-dest failure (e.g. www.microsoft.com) still completes TLS *and* the
			# server's UNAUTHENTICATED fallback relay — only the AUTHENTICATED steal breaks. A plain openssl
			# handshake rides that fallback and would MISS it. Use the authenticated ephemeral REALITY
			# handshake against dest (donor_verify_reality — the same steal-viability the live server
			# depends on); it contacts only the node's own cover/dest host, not a third party.
			# A skip is not a pass — see the note on the sni skip above (Audit-0009 U1).
			[ -n "$dest" ] || { tested=$(( tested + 1 )); unknown="$unknown $ref"; continue; }
			for attempt in 1 2 3; do
				# `drc=0; ... || drc=$?` is REQUIRED, not stylistic: on the timer/dispatch path this probe
				# runs under `set -e` in a NON-exempt context, so a bare `donor_verify_reality; drc=$?`
				# would trip errexit on a broken-dest return (rc 1) and abort BEFORE the marker is written
				# — silently defeating the very broken-REALITY detection this probe exists for.
				drc=0; donor_verify_reality "$dest" "$fp" || drc=$?
				# 0 = steal-viable, 2 = cannot judge (engine/curl/port) -> NOT dead; 1 = broken -> retry.
				[ "$drc" -ne 1 ] && { ok=1; vrc="$drc"; break; }
				sleep 1
			done
		else
			# genuine-TLS (ws-tls, trojan): own-cert loopback handshake; the presented leaf must be non-expired AND carry
			# $sni in its SAN (pure loopback, no external contact). A dead listener / missing cert yields no
			# leaf; a WRONG-domain cert (a mis-render, or a stale cert for another host) is caught by the SAN
			# match (Audit-0007 S3). We grep the SAN rather than `-verify_hostname -verify_return_error`
			# ON PURPOSE: the latter also demands the leaf chain to a TRUSTED CA, which would false-DEAD a
			# node serving a legitimate SELF-SIGNED own-cert. $parent = $sni minus its first label, so a
			# wildcard SAN (`*.parent`) matches too. Dots are literal-enough for an own-cert loopback probe
			# (no adversary controls this cert); the trailing class anchors the DNS name so a suffix
			# (`$sni.evil.tld`) cannot match.
			# A SKIP is not a pass (Audit-0009 U1). This incremented `checked` and touched neither list, so a
			# member with no usable SNI counted toward coverage while proving nothing — the same overclaim as
			# the folded cannot-judge, on the sibling path.
			[ -n "$sni" ] || { tested=$(( tested + 1 )); unknown="$unknown $ref"; continue; }
# WHY THE OUTPUT IS CAPTURED BEFORE IT IS PARSED, and not piped straight into `openssl x509`.
			#
			# `openssl s_client ... | openssl x509` looks harmless and is not. `x509` exits the moment it has read one
			# certificate, which closes the pipe; `s_client` then takes SIGPIPE mid-session and the kernel tears the
			# socket down with an RST to 127.0.0.1:<served port>.
			#
			# That port is one this node counts. The passive path observer (RP-0014 chunk B) counts inbound RSTs by
			# `tcp dport <served port>` with no interface predicate — deliberately, for the payload-free invariant —
			# so loopback RSTs land in the same counter as wire RSTs, and this probe was manufacturing the very signal
			# the node then reacted to. MEASURED on a live node, five forced runs: 5 RSTs on one served port in one
			# run, 2 on another in another, 0 in three. Five is exactly PATHSIG_RST_FLOOR.
			#
			# The SYN side of the same dials IS discounted (measure_pathsig_probe subtracts the reach prober's rate)
			# and the comment there names the L7 probe as an unsubtracted residual biasing toward FALSE NEGATIVES.
			# Nobody noticed the same dials also feed the RST NUMERATOR, where the bias is the other way.
			#
			# Capturing first removes the SIGPIPE, so the session ends with a close rather than a reset. Fixed at the
			# source rather than compensated for downstream: an estimate subtracted from a counter is a guess, and
			# this project has enough of those.
			local parent="${sni#*.}" leaf san
			local _raw
			for attempt in 1 2 3; do
				# See the note above _l7_probe_leaf_clean: piping s_client into x509 makes x509 close the
				# pipe first, s_client take SIGPIPE, and the kernel RST a served port this node counts.
				_raw="$(echo | $TO openssl s_client -connect "127.0.0.1:$port" -servername "$sni" 2>/dev/null)"
				leaf="$(printf '%s' "$_raw" | openssl x509 2>/dev/null)"
				[ -n "$leaf" ] || { sleep 1; continue; }
				printf '%s' "$leaf" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 || { sleep 1; continue; }
				san="$(printf '%s' "$leaf" | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
				if grep -qiE "DNS:(${sni}|\*\.${parent})([[:space:],]|\$)" <<<"$san" ; then ok=1; vrc=0; break; fi
				sleep 1
			done
		fi
		tested=$(( tested + 1 ))
		if [ "$ok" -ne 1 ]; then
			dead="$dead $ref"
		elif [ "${vrc:-2}" -eq 2 ]; then
			# CANNOT-JUDGE is its own outcome (Audit-0009 B1). It used to be folded into ALIVE here: the
			# member left `dead` empty and incremented `checked`, so a run that PROVED nothing was byte-
			# identical to one that proved health. The probe computes three values and the marker could
			# only express two, so the third was silently rounded toward "fine" — the wrong direction for
			# a signal a planner acts on.
			unknown="$unknown $ref"
		fi
	# The enrolled set. The standalone `shadowsocks` clause is qualified where the others are not: the
	# ShadowTLS inbound carries a SECOND shadowsocks inbound as its hidden inner detour, which is not a
	# served family (it listens on 127.0.0.1 with no listen_port, and its outer layer is probed on its own
	# tag). Requiring a wildcard `listen` + a real port enrols exactly the PUBLIC SS listener — the same
	# predicate nb_measure's `_pathsig_tcp_ports` uses, so the probe and the passive counters observe the
	# same member.
	done <<PROBE_EOF
$(jq -c '.inbounds[]? | select(.tag=="vless-reality-vision-in" or .tag=="vless-reality-grpc-in" or .tag=="vless-reality-xhttp-in" or .tag=="vless-ws-tls-in" or .type=="hysteria2" or .type=="tuic" or .type=="shadowtls" or .type=="trojan"
		or (.type=="shadowsocks" and (.listen_port != null) and ((.listen // "::") | test("^(::|0\\.0\\.0\\.0)$"))))
	| {tag, type:.type, port:.listen_port, reality:((.tls.reality.enabled)//false), sni:(.tls.server_name),
	   dest:(.tls.reality.handshake.server // .tls.server_name)}' "$SINGBOX_CONFIG" 2>/dev/null)
PROBE_EOF
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	# `unknown` is ADDITIVE: the daemon reads .dead and ignores keys it does not know, so the one-producer
	# one-schema rule (ADR-0036) still holds — the schema grew, it did not fork. Rotation behaviour is
	# unchanged: only `dead` faults a member. What changes is that "we could not tell" is now VISIBLE.
	printf '{"observed_at":"%s","checked":%d,"dead":[%s],"unknown":[%s]}\n' "$ts" "$tested" \
		"$(for d in $dead; do printf '"%s",' "$d"; done | sed 's/,$//')" \
		"$(for u in $unknown; do printf '"%s",' "$u"; done | sed 's/,$//')" >"$marker.tmp" 2>/dev/null \
		&& mv -f "$marker.tmp" "$marker" 2>/dev/null || true
	# EXPORT the verdict (Audit-0009 V3). Written here, by the producer, because the metrics generator is
	# authored once at bootstrap and never reconciled — a metric added there would never reach an existing
	# node. Before the caller's early return, so a DEAD verdict is exported too; that is the case that
	# matters most.
	command -v record_l7_verdict >/dev/null 2>&1 && record_l7_verdict "$marker"
	if [ -n "$dead" ]; then
		warn "L7 measure-probe: client-DEAD transport(s):$dead (own-listener handshake failed)."
		return 1
	fi
	if [ -n "$unknown" ]; then
		# Say what was NOT established. The old line claimed every transport "passes", counting members the
		# run could not judge as passing — the overclaim B1 names.
		warn "L7 measure-probe: no member read DEAD, but$unknown could not be judged this run (missing tooling, no usable probe target, or a route that would leave the host). Coverage is $(( tested - $(printf '%s' "$unknown" | wc -w) ))/$tested, not $tested/$tested."
	else
		log "L7 measure-probe: all $tested L7-covered transport(s) (REALITY + genuine-TLS + QUIC + ShadowTLS + Shadowsocks; the Xray-served xhttp-tls is covered by its own sibling probe) verified alive on their own listener."
	fi
	return 0
}

# measure_fp_ab_probe [MARKER] [L7_MARKER] — RP-0015 increment B (producer, ADVISORY, INERT). Decides
# whether a client-DEAD verdict on a fingerprint-CARRYING member is caused by the CURRENT uTLS preset or by
# the transport underneath it, via a SAME-LISTENER A/B. It consumes the L7 marker's dead[] list (the
# current-preset verdict, already retry-debounced) and, for the FIRST dead fingerprint-carrying member (a
# REALITY family via donor_verify_reality, or ShadowTLS via _l7_probe_shadowtls_dial — genuine-TLS is
# openssl/no-uTLS and QUIC is insecure, so both are fingerprint-BLIND and excluded), re-dials the IDENTICAL
# dest/cover/port/engine/auth, changing ONLY the uTLS preset, walking the closed vocabulary
# (control/vocab.json .client_fingerprints, current excluded, canonical order), 3-attempt retry-debounce per
# arm, STOPPING at the first preset that reads ALIVE. Because everything but the ClientHello preset is held
# constant, any transport-wide cause (a filter that also takes ws-tls, a raw-TCP block, a broken dest, an
# expired cert, a black-holed port) affects every arm identically and cancels — only a preset-keyed filter
# yields a DEAD/ALIVE asymmetry. Writes ONLY its OWN advisory marker ($STATE_DIR/fp_probe.json) with NEUTRAL
# verdict tokens; it NEVER rotates and is NOT folded into the transport L7 marker. INERT until the daemon
# fold consumes it (RP-0015 B2/B3).
#   verdict: fingerprint-specific  current DEAD + an alternate ALIVE (target = first-alive)
#            transport-wide        current DEAD + ALL alternates DEAD (defer to the >=2-family backstop)
#            clean                 no fingerprint-carrying member is DEAD
#            cannot-judge          the L7 marker is absent/unreadable (a transient — never a signal)
measure_fp_ab_probe() {
	have openssl && have jq || return 0
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local marker l7marker ts cur verdict target suspect
	marker="${1:-$STATE_DIR/fp_probe.json}"
	l7marker="${2:-$STATE_DIR/l7_selftest.json}"
	ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	cur="$(myc_client_fingerprint "$(jq -c . "${PARAMS_JSON:-}" 2>/dev/null || printf '{}')")"
	verdict="clean"; target=""; suspect=""

	if [ ! -f "$l7marker" ] || ! jq -e '.dead' "$l7marker" >/dev/null 2>&1; then
		# The current-preset verdict source is missing/unreadable -> a transient; emit no actionable signal.
		verdict="cannot-judge"
	else
		local dead rows suspect_ref suspect_dest suspect_tag suspect_port suspect_reality r row
		dead="$(jq -r '.dead[]?' "$l7marker" 2>/dev/null || true)"
		# fingerprint-CARRYING members only (REALITY families + ShadowTLS), keyed by ref (tag minus "-in"),
		# extracted from the live served config exactly as measure_l7_probe does.
		rows="$(jq -c '.inbounds[]? | select(.tag=="vless-reality-vision-in" or .tag=="vless-reality-grpc-in" or .tag=="vless-reality-xhttp-in" or .type=="shadowtls")
			| {ref:(.tag|sub("-in$";"")), tag, type:.type, port:.listen_port,
			   reality:((.tls.reality.enabled)//false),
			   dest:(.tls.reality.handshake.server // .tls.server_name // "")}' "$SINGBOX_CONFIG" 2>/dev/null || true)"
		suspect_ref=""; suspect_dest=""; suspect_tag=""; suspect_port=""; suspect_reality=""
		for r in $dead; do
			row="$(printf '%s\n' "$rows" | jq -c --arg r "$r" 'select(.ref==$r)' 2>/dev/null | head -n1 || true)"
			[ -n "$row" ] || continue
			suspect_ref="$r"
			suspect_dest="$(printf '%s' "$row" | jq -r '.dest // ""' 2>/dev/null || true)"
			suspect_tag="$(printf '%s' "$row" | jq -r '.tag // ""' 2>/dev/null || true)"
			suspect_port="$(printf '%s' "$row" | jq -r '.port // ""' 2>/dev/null || true)"
			suspect_reality="$(printf '%s' "$row" | jq -r '.reality' 2>/dev/null || true)"
			break
		done
		if [ -n "$suspect_ref" ]; then
			suspect="\"$suspect_ref\""
			# The A/B: walk the closed vocab (current excluded, canonical order), SAME listener, alt preset
			# only, 3-attempt retry-debounce per arm, STOP at first ALIVE. Provisional verdict transport-wide,
			# overwritten to fingerprint-specific iff an alternate revives the same member.
			local vocab alts alt arc a
			vocab="${MYC_VOCAB:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/vocab.json}"
			alts="$(jq -r --arg cur "$cur" '.client_fingerprints[]? | select(. != $cur)' "$vocab" 2>/dev/null || true)"
			verdict="transport-wide"
			for alt in $alts; do
				arc=1
				for a in 1 2 3; do
					arc=0
					if [ "$suspect_reality" = "true" ]; then
						donor_verify_reality "$suspect_dest" "$alt" || arc=$?
					else
						_l7_probe_shadowtls_dial "$suspect_tag" "$suspect_port" "$alt" || arc=$?
					fi
					[ "$arc" -eq 0 ] && break   # ALIVE under this alternate preset
					[ "$arc" -eq 2 ] && break   # cannot-judge this arm -> not a target, stop retrying
					sleep 1                      # rc 1 (DEAD) -> retry-debounce
				done
				if [ "$arc" -eq 0 ]; then target="$alt"; verdict="fingerprint-specific"; break; fi
			done
		fi
	fi

	printf '{"observed_at":"%s","current_fingerprint":"%s","verdict":"%s","target_fingerprint":"%s","suspect_refs":[%s]}\n' \
		"$ts" "$cur" "$verdict" "$target" "$suspect" >"$marker.tmp" 2>/dev/null \
		&& mv -f "$marker.tmp" "$marker" 2>/dev/null || true
	if [ "$verdict" = "fingerprint-specific" ]; then
		warn "fp A/B: the current uTLS preset reads client-DEAD on '${suspect//\"/}' but preset '$target' reads ALIVE on the same listener -> fingerprint-specific (advisory; no rotation unless armed)."
	fi
	return 0
}

# measure_l7_probe_amneziawg — node-local L7 liveness for the AmneziaWG (obfuscated-WireGuard) UDP
# data-plane, which measure_l7_probe cannot see: AmneziaWG is served by a SEPARATE engine (amneziawg-go on
# awg0), never appears in $SINGBOX_CONFIG, and its UDP listener defeats the L4 reach probe (a TCP connect to
# a UDP port is meaningless). So today AmneziaWG acceptance is L4-only — a bound UDP/443 with a WEDGED engine
# (crash-looping but holding the socket, or not processing handshakes) passes verify_listen_ports.
#
# The L7 truth for WireGuard is a completed handshake, and WG only answers a CONFIGURED peer, so the probe is
# self-contained (Design A, RP-0014 chunk A): it briefly enrolls an EPHEMERAL dead-end probe-peer on awg0,
# brings up a throwaway userspace client interface (amneziawg-go) with awg0's OWN junk params + a LOOPBACK
# endpoint (127.0.0.1:<port>), triggers a handshake, and reads `awg show <iface> latest-handshakes`. A fresh
# handshake completes IFF the awg0 data-plane is genuinely processing handshakes (engine alive + socket live
# + params internally consistent). It contacts ONLY 127.0.0.1 (pure loopback, no external contact), and it
# NEVER touches a real client's routing: the probe-peer's /32 is drawn from a RESERVED range (10.13.13.240–
# .254) that render_awg0 FAILS CLOSED before assigning to a client (clients start at .2 and render dies
# before reaching .240), so the probe block is guaranteed disjoint from the client block.
#
# SCOPE (honest, ADR-0036): this is an ADVISORY/ACCEPTANCE signal — it writes its OWN marker
# ($STATE_DIR/l7_awg.json by default; a DISTINCT path at deploy-time acceptance) + WARNs on a dead
# data-plane; it is NOT folded into the sing-box rotation loop, because AmneziaWG is not a rotatable measure
# member (no in-engine sibling; cross-engine rotation is out of chunk-A scope). It uses awg0's OWN params, so
# it confirms the data-plane is live — NOT that a distributed client's params match (that is guaranteed at
# render, where render_awg0 derives both from one source, not re-checked here). FAIL-SAFE: absent tools / no
# awg0 / any setup failure -> NOT dead (return 0); only a fully-set-up probe whose handshake never completes
# -> dead (return 1). The mutating region runs under an EXIT-trap teardown so the ephemeral peer + interface
# are ALWAYS removed, even if a step trips `set -e`; a stray peer/iface from a crashed prior run is
# self-healed on the next run (idempotent pre-clean over the reserved range). Self-cleaning; loopback-only.
measure_l7_probe_amneziawg() {
	have awg && have amneziawg-go && have ip || return 0
	local marker="${1:-$STATE_DIR/l7_awg.json}"
	# AmneziaWG served here? (awg0 up). If not, this node does not serve AmneziaWG -> skip (write no marker,
	# so its absence folds healthy — exactly like measure_l7_probe on a missing config).
	awg show awg0 >/dev/null 2>&1 || return 0
	# Serialize: at most one AmneziaWG probe may mutate awg0 (the shared "awgprobe" iface + a reserved-range
	# peer) at a time. A concurrent run SKIPS (fail-safe, return 0) rather than clobbering the other run mid-
	# probe — deleting its iface + removing its just-enrolled peer, which would read as a spurious dead
	# verdict. Best-effort: no flock -> no lock (the probe is not cadenced, so real overlap needs two
	# deliberate concurrent runs); the fixed fd 200 is released when this process exits.
	# NOT `exec 200>file 2>/dev/null`: `exec` applies EVERY redirection on its line to the shell itself,
	# so that 2>/dev/null silences stderr for the REST OF THE PROCESS — every warn and every die after
	# this point, in a probe that verify_post_apply calls on the converge path. Demonstrated: a line
	# written to stderr before the exec appears, the identical line after it does not. Pre-test that the
	# lock file is openable instead, so the exec itself cannot fail (a failed redirection on `exec` is
	# fatal to a non-interactive shell and no `|| true` can catch it).
	local _awg_probe_lock="${STATE_DIR:-/tmp}/l7_awg_probe.lock"
	if have flock && : >>"$_awg_probe_lock" 2>/dev/null; then
		exec 200>>"$_awg_probe_lock"
		flock -n 200 || return 0
	fi
	local show spub port stunip jc jmin jmax s1 s2 h1 h2 h3 h4
	show="$(awg show awg0 2>/dev/null)"                 || return 0
	spub="$(awg show awg0 public-key 2>/dev/null)"      || return 0; [ -n "$spub" ]   || return 0
	port="$(awg show awg0 listen-port 2>/dev/null)"     || return 0; [ -n "$port" ]   || return 0
	stunip="$(ip -o -4 addr show awg0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet"){split($(i+1),a,"/"); print a[1]; exit}}')" || return 0
	[ -n "$stunip" ] || return 0
	# awg0's junk params (the temp client MUST match them for the handshake to complete). Read from the show
	# via a here-string (NOT `printf | awk`): the junk params sit in the interface header at the TOP of the
	# show, so awk's early `exit` would SIGPIPE a `printf` producer on a many-peer node (a large show) — that
	# 141, under pipefail on a plain assignment, would abort the whole node-bootstrap run (ADR-0036 forbids a
	# setup failure faulting the caller). A here-string has no producer process to signal.
	jc="$(  awk -F': ' '/^[[:space:]]*jc:/  {print $2; exit}' <<<"$show")"
	jmin="$(awk -F': ' '/^[[:space:]]*jmin:/{print $2; exit}' <<<"$show")"
	jmax="$(awk -F': ' '/^[[:space:]]*jmax:/{print $2; exit}' <<<"$show")"
	s1="$(  awk -F': ' '/^[[:space:]]*s1:/  {print $2; exit}' <<<"$show")"
	s2="$(  awk -F': ' '/^[[:space:]]*s2:/  {print $2; exit}' <<<"$show")"
	h1="$(  awk -F': ' '/^[[:space:]]*h1:/  {print $2; exit}' <<<"$show")"
	h2="$(  awk -F': ' '/^[[:space:]]*h2:/  {print $2; exit}' <<<"$show")"
	h3="$(  awk -F': ' '/^[[:space:]]*h3:/  {print $2; exit}' <<<"$show")"
	h4="$(  awk -F': ' '/^[[:space:]]*h4:/  {print $2; exit}' <<<"$show")"
	local _v; for _v in "$jc" "$jmin" "$jmax" "$s1" "$s2" "$h1" "$h2" "$h3" "$h4"; do
		[ -n "$_v" ] || return 0   # a missing junk param -> cannot build a matching client -> fail-safe skip
	done
	# Pick a probe /32 from the RESERVED range (.240–.254, which render_awg0 refuses to assign to a client)
	# not currently enrolled by a prior leaked probe-peer. grep reads a here-string (no `printf |` producer
	# to SIGPIPE on a many-peer node -> no mis-select of an in-use /32). No free slot -> fail-safe skip.
	local used ppip="" oct cand
	used="$(awg show awg0 allowed-ips 2>/dev/null | tr '\t ,' '\n')" || return 0
	for oct in 254 253 252 251 250 249 248 247 246 245 244 243 242 241 240; do
		cand="10.13.13.$oct"
		grep -Fqx -- "${cand}/32" <<<"$used" || { ppip="$cand"; break; }
	done
	[ -n "$ppip" ] || return 0

	local iface="awgprobe"
	# The MUTATING probe runs in a subshell with an EXIT-trap teardown so the ephemeral peer + interface are
	# ALWAYS removed — even if a step trips `set -e`. It prints ONE verdict token to stdout (skip|alive|dead);
	# all engine chatter goes to /dev/null. `|| verdict=skip` neutralises set -e on the assignment itself.
	local verdict
	verdict="$(
		set +e
		keydir="$(mktemp -d 2>/dev/null)" || { echo skip; exit 0; }
		ppub=""
		# Teardown body is stdout-silenced so cleanup output can NEVER contaminate the verdict token this
		# subshell prints (a stray line would turn "dead" into "dead\n..." and mask a real dead verdict).
		# Trapped on the fatal signals too, not only EXIT: an EXIT trap does not run on an untrapped
		# SIGINT/SIGTERM/SIGHUP, which would leak the peer + leave amneziawg-go spinning a keepalive handshake.
		_awgprobe_teardown() {
			{
				ip link del "$iface" 2>/dev/null
				pkill -f "amneziawg-go $iface" 2>/dev/null
				[ -n "$ppub" ] && awg set awg0 peer "$ppub" remove 2>/dev/null
				rm -rf "$keydir" 2>/dev/null
			} >/dev/null 2>&1
			return 0
		}
		trap _awgprobe_teardown EXIT INT TERM HUP
		# Idempotent pre-clean: a crashed prior run may have leaked the iface or a probe-peer in the RESERVED
		# range (.240–.254). Remove them so probe-peers never accumulate on awg0. render_awg0 FAILS CLOSED
		# before assigning a client into .240+ (it reserves this block for exactly this probe), so removing a
		# reserved-range peer here can never disturb a real client.
		ip link del "$iface" 2>/dev/null
		awg show awg0 allowed-ips 2>/dev/null | while read -r pk ips; do
			if [[ "$ips" == 10.13.13.25[0-4]/32 || "$ips" == 10.13.13.24[0-9]/32 ]]; then
				awg set awg0 peer "$pk" remove 2>/dev/null
			fi
		done
		# Ephemeral probe keypair (600 in a 700 dir — no key material leaks).
		umask 077
		awg genkey >"$keydir/pk" 2>/dev/null                          || { echo skip; exit 0; }
		ppub="$(awg pubkey <"$keydir/pk" 2>/dev/null)"; [ -n "$ppub" ] || { echo skip; exit 0; }
		# Enrol the dead-end probe-peer on awg0 (a reserved /32 -> real client routing untouched).
		awg set awg0 peer "$ppub" allowed-ips "${ppip}/32" 2>/dev/null || { echo skip; exit 0; }
		# Throwaway userspace client iface using the OWN junk params of awg0 + a loopback endpoint to its socket.
		amneziawg-go "$iface" >/dev/null 2>&1                         || { echo skip; exit 0; }
		awg set "$iface" private-key "$keydir/pk" jc "$jc" jmin "$jmin" jmax "$jmax" s1 "$s1" s2 "$s2" \
			h1 "$h1" h2 "$h2" h3 "$h3" h4 "$h4" 2>/dev/null           || { echo skip; exit 0; }
		awg set "$iface" peer "$spub" endpoint "127.0.0.1:$port" allowed-ips "${stunip}/32" \
			persistent-keepalive 3 2>/dev/null                        || { echo skip; exit 0; }
		ip addr add "${ppip}/32" dev "$iface" 2>/dev/null             || { echo skip; exit 0; }
		ip link set "$iface" up 2>/dev/null                          || { echo skip; exit 0; }
		# Trigger + poll for a completed handshake (~8s). We read latest-handshakes, NOT ping success: the
		# handshake completes on the crypto response from the server even if ICMP to the tunnel IP is filtered
		# (persistent-keepalive alone would also initiate it; the ping just hurries the first packet).
		hs=0
		for _i in 1 2 3 4 5 6 7 8; do
			ping -c1 -W1 -I "$iface" "$stunip" >/dev/null 2>&1
			hs="$(awg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
			if [ -z "$hs" ] || [ "$hs" = 0 ]; then hs=0; else break; fi
			sleep 1
		done
		{ [ "$hs" -gt 0 ] 2>/dev/null && echo alive; } || echo dead
	)" || verdict=skip

	local ts dead="" tested=1 deadjson="[]"
	ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	case "$verdict" in
		skip) tested=0 ;;                                  # could not run -> record nothing dead (fail-safe)
		dead) dead="amneziawg-udp"; deadjson='["amneziawg-udp"]' ;;
	esac
	printf '{"observed_at":"%s","checked":%d,"dead":%s}\n' "$ts" "$tested" "$deadjson" >"$marker.tmp" 2>/dev/null \
		&& mv -f "$marker.tmp" "$marker" 2>/dev/null || true
	if [ "$verdict" = dead ]; then
		warn "L7 AmneziaWG probe: awg0 did not complete a loopback handshake — the UDP data-plane is bound but a real client could not establish the tunnel (engine wedged / not processing handshakes)."
		return 1
	fi
	[ "$verdict" = alive ] && log "L7 AmneziaWG probe: awg0 completed a loopback handshake — the obfuscated-WireGuard data-plane is live at L7."
	return 0
}

# measure_l7_probe_xhttp — node-local L7 liveness for the Xray-served vless-xhttp-tls family, which
# measure_l7_probe cannot cover: it is in the SEPARATE xray config (not $SINGBOX_CONFIG), a sing-box client
# cannot dial the xhttp transport, and it is NOT a sing-box measure member (nb_measure enumerates only
# engine==sing-box protos), so a dead ref in the rotation marker would be inert. Like measure_l7_probe_amneziawg
# this is an ADVISORY/ACCEPTANCE signal on its OWN marker (default $STATE_DIR/l7_xhttp.json), NOT folded into
# rotation. SCOPE (honest, ADR-0036): xhttp-tls presents its OWN cert (genuine-TLS) as its OUTER layer, so we
# reuse the exact ws-tls mechanism — an openssl loopback handshake to 127.0.0.1:<port> whose presented leaf
# must be non-expired AND carry the tls_sni in its SAN (pure loopback, no external contact). That catches an
# xray engine that is DOWN or serving a broken/expired/wrong own cert — the failure modes the L4-only reach
# window (a bare "is 2087 bound") cannot see. It does NOT verify the inner xhttp/VLESS layer (that needs an
# Xray client; a bound-but-xhttp-wedged xray whose TLS still completes reads alive — a documented residual).
# Best-effort: missing openssl/jq, no xray config, or an unidentifiable inbound -> no marker (fail-safe skip,
# folds healthy). Retry-debounce so a one-off blip never writes a dead marker. Self-cleaning; loopback-only.
measure_l7_probe_xhttp() {
	have openssl && have jq || return 0
	[ -n "${XRAY_CONFIG:-}" ] && [ -f "$XRAY_CONFIG" ] || return 0   # xray not serving here -> skip
	local marker="${1:-$STATE_DIR/l7_xhttp.json}" port sni
	# `|| port=""` / `|| sni=""`: a present-but-MALFORMED xray config makes jq exit non-zero, which under
	# `set -euo pipefail` on the bare `--l7-probe-xhttp` verb path would abort the process at the assignment
	# BEFORE the identify-skip guard. Neutralise it so a corrupt config folds to the documented fail-safe skip.
	port="$(jq -r '.inbounds[]? | select(.protocol=="vless" and .streamSettings.network=="xhttp") | .port' "$XRAY_CONFIG" 2>/dev/null | head -1)" || port=""
	sni="$(jq -r '.inbounds[]? | select(.protocol=="vless" and .streamSettings.network=="xhttp") | (.streamSettings.tlsSettings.serverName // .streamSettings.tlsSettings.certificates[0].serverName // empty)' "$XRAY_CONFIG" 2>/dev/null | head -1)" || sni=""
	# The own-cert SNI (tls_sni) is shared with the sing-box genuine-TLS families; fall back to it if the xray
	# tlsSettings does not restate serverName (a cert-only tlsSettings still presents the same leaf).
	[ -n "$sni" ] || sni="$(jq -r '.inbounds[]? | select((.tls.server_name != null) and ((.tls.reality.enabled // false) == false)) | .tls.server_name' "$SINGBOX_CONFIG" 2>/dev/null | head -1)" || sni=""
	[ -n "$port" ] && [ "$port" != "null" ] && [ -n "$sni" ] || return 0   # cannot identify the inbound -> skip
	local parent="${sni#*.}" TO="" leaf san ok=0 attempt
	command -v timeout >/dev/null 2>&1 && TO="timeout 8"
	local _raw
	for attempt in 1 2 3; do
		# Same reason as the sibling probe: capture, then parse. A pipe here RSTs a served port.
		_raw="$(echo | $TO openssl s_client -connect "127.0.0.1:$port" -servername "$sni" 2>/dev/null)"
		leaf="$(printf '%s' "$_raw" | openssl x509 2>/dev/null)"
		[ -n "$leaf" ] || { sleep 1; continue; }
		printf '%s' "$leaf" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 || { sleep 1; continue; }
		san="$(printf '%s' "$leaf" | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
		if grep -qiE "DNS:(${sni}|\*\.${parent})([[:space:],]|\$)" <<<"$san" ; then ok=1; break; fi
		sleep 1
	done
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if [ "$ok" -eq 1 ]; then
		printf '{"observed_at":"%s","checked":1,"dead":[]}\n' "$ts" >"$marker.tmp" 2>/dev/null && mv -f "$marker.tmp" "$marker" 2>/dev/null || true
		log "L7 xhttp-tls probe: the xray xhttp-tls own-cert loopback handshake completes (non-expired, SAN matches tls_sni) — the Xray outer-TLS layer is live."
		return 0
	fi
	printf '{"observed_at":"%s","checked":1,"dead":["vless-xhttp-tls"]}\n' "$ts" >"$marker.tmp" 2>/dev/null && mv -f "$marker.tmp" "$marker" 2>/dev/null || true
	warn "L7 xhttp-tls probe: the xray xhttp-tls own-cert loopback handshake FAILED (no leaf / expired / SAN mismatch) — 2087 is bound but a real client would fail the outer TLS layer."
	return 1
}
