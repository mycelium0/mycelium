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
# own-cert genuine-TLS ws-tls (loopback SAN match), the QUIC families hysteria2/tuic (a real sing-box client
# handshake + protocol auth over loopback — _l7_probe_quic_dial), and ShadowTLS v3 (the real inner-SS-over-
# outer-ShadowTLS handshake, the outer layer relaying the node's cover — _l7_probe_shadowtls_dial). AmneziaWG
# (a separate UDP engine, never in the sing-box config) is covered by the SIBLING probe
# measure_l7_probe_amneziawg (a real loopback WG handshake) — an ADVISORY/ACCEPTANCE signal on its OWN marker,
# NOT folded into the sing-box rotation loop (AmneziaWG is not a rotatable measure member: a standalone
# always-on tunnel with no in-engine sibling to promote). STILL L4-only, needing a PROTOCOL-SPECIFIC probe
# (RP-0014 chunk A follow-on): the Xray-served vless-xhttp-tls (a separate config, a distinct engine).
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
		elif printf '%s' "$err" | grep -qiE 'connect to server|authenticat|application error|handshake|unreachable|no route'; then
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
	local tag="$1" port="$2"
	[ -n "$port" ] || return 2
	local ob
	ob="$(jq -c --arg tag "$tag" --argjson port "$port" \
		'.inbounds as $in
		 | ($in[] | select(.tag==$tag)) as $stls
		 | ($in[] | select(.tag==($stls.detour))) as $ss
		 | [ {type:"shadowsocks",tag:"probe-out",method:$ss.method,password:$ss.password,detour:"probe-stls"},
		     {type:"shadowtls",tag:"probe-stls",server:"127.0.0.1",server_port:$port,version:3,password:$stls.users[0].password,tls:{enabled:true,server_name:$stls.handshake.server,utls:{enabled:true,fingerprint:"chrome"}}} ]' \
		"$SINGBOX_CONFIG" 2>/dev/null)"
	# well-formed iff both secrets + the port + the cover SNI are present (a legacy/foreign config with an
	# EMPTY ss/shadowtls secret, or a missing detour, -> cannot-judge, NOT dead).
	{ [ -n "$ob" ] && printf '%s' "$ob" | jq -e '(.[0].password // "") != "" and (.[1].password // "") != "" and .[1].server_port != null and (.[1].tls.server_name // "") != ""' >/dev/null 2>&1; } || return 2
	_l7_singbox_dial "$ob" 17
}

measure_l7_probe() {
	have openssl && have jq || return 0
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local marker="${1:-$STATE_DIR/l7_selftest.json}" dead="" tested=0 row
	local TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 8"
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		local tag ref port reality sni dest type drc qrc ok=0 attempt
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
				qrc=0; _l7_probe_shadowtls_dial "$tag" "$port" || qrc=$?
				# 0 = alive, 2 = cannot judge (sing-box/timeout absent) -> NOT dead; 1 = dead -> retry-debounce.
				[ "$qrc" -ne 1 ] && { ok=1; break; }
				sleep 1
			done
		elif [ "$type" = "hysteria2" ] || [ "$type" = "tuic" ]; then
			# QUIC (hysteria2/tuic): openssl cannot speak QUIC, so we complete a REAL handshake + protocol
			# auth against the own listener with sing-box as the client, plus an expiry check on the served
			# cert file (_l7_probe_quic_dial, loopback-only). A bound-but-client-DEAD QUIC listener (an
			# EXPIRED served cert, wrong/rotated auth, a wedged engine) is caught here instead of passing the
			# L4-only reach window.
			[ -n "$sni" ] || { tested=$(( tested + 1 )); continue; }
			for attempt in 1 2 3; do
				# `qrc=0; ... || qrc=$?` mirrors the REALITY branch: under `set -e` a bare dead-return (rc 1)
				# would abort before the marker is written. 0 = alive, 2 = cannot judge (sing-box/timeout
				# absent) -> NOT dead; 1 = dead -> retry-debounce (a one-off blip never writes a dead marker).
				qrc=0; _l7_probe_quic_dial "$tag" "$type" "$port" "$sni" || qrc=$?
				[ "$qrc" -ne 1 ] && { ok=1; break; }
				sleep 1
			done
		elif [ "$reality" = "true" ]; then
			# REALITY: the broken-dest failure (e.g. www.microsoft.com) still completes TLS *and* the
			# server's UNAUTHENTICATED fallback relay — only the AUTHENTICATED steal breaks. A plain openssl
			# handshake rides that fallback and would MISS it. Use the authenticated ephemeral REALITY
			# handshake against dest (donor_verify_reality — the same steal-viability the live server
			# depends on); it contacts only the node's own cover/dest host, not a third party.
			[ -n "$dest" ] || { tested=$(( tested + 1 )); continue; }
			for attempt in 1 2 3; do
				# `drc=0; ... || drc=$?` is REQUIRED, not stylistic: on the timer/dispatch path this probe
				# runs under `set -e` in a NON-exempt context, so a bare `donor_verify_reality; drc=$?`
				# would trip errexit on a broken-dest return (rc 1) and abort BEFORE the marker is written
				# — silently defeating the very broken-REALITY detection this probe exists for.
				drc=0; donor_verify_reality "$dest" || drc=$?
				# 0 = steal-viable, 2 = cannot judge (engine/curl/port) -> NOT dead; 1 = broken -> retry.
				[ "$drc" -ne 1 ] && { ok=1; break; }
				sleep 1
			done
		else
			# genuine-TLS: own-cert loopback handshake; the presented leaf must be non-expired AND carry
			# $sni in its SAN (pure loopback, no external contact). A dead listener / missing cert yields no
			# leaf; a WRONG-domain cert (a mis-render, or a stale cert for another host) is caught by the SAN
			# match (Audit-0007 S3). We grep the SAN rather than `-verify_hostname -verify_return_error`
			# ON PURPOSE: the latter also demands the leaf chain to a TRUSTED CA, which would false-DEAD a
			# node serving a legitimate SELF-SIGNED own-cert. $parent = $sni minus its first label, so a
			# wildcard SAN (`*.parent`) matches too. Dots are literal-enough for an own-cert loopback probe
			# (no adversary controls this cert); the trailing class anchors the DNS name so a suffix
			# (`$sni.evil.tld`) cannot match.
			[ -n "$sni" ] || { tested=$(( tested + 1 )); continue; }
			local parent="${sni#*.}" leaf san
			for attempt in 1 2 3; do
				leaf="$(echo | $TO openssl s_client -connect "127.0.0.1:$port" -servername "$sni" 2>/dev/null \
					| openssl x509 2>/dev/null)"
				[ -n "$leaf" ] || { sleep 1; continue; }
				printf '%s' "$leaf" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 || { sleep 1; continue; }
				san="$(printf '%s' "$leaf" | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
				if printf '%s' "$san" | grep -qiE "DNS:(${sni}|\*\.${parent})([[:space:],]|\$)"; then ok=1; break; fi
				sleep 1
			done
		fi
		tested=$(( tested + 1 ))
		[ "$ok" -eq 1 ] || dead="$dead $ref"
	done <<PROBE_EOF
$(jq -c '.inbounds[]? | select(.tag=="vless-reality-vision-in" or .tag=="vless-reality-grpc-in" or .tag=="vless-reality-xhttp-in" or .tag=="vless-ws-tls-in" or .type=="hysteria2" or .type=="tuic" or .type=="shadowtls")
	| {tag, type:.type, port:.listen_port, reality:((.tls.reality.enabled)//false), sni:(.tls.server_name),
	   dest:(.tls.reality.handshake.server // .tls.server_name)}' "$SINGBOX_CONFIG" 2>/dev/null)
PROBE_EOF
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '{"observed_at":"%s","checked":%d,"dead":[%s]}\n' "$ts" "$tested" \
		"$(for d in $dead; do printf '"%s",' "$d"; done | sed 's/,$//')" >"$marker.tmp" 2>/dev/null \
		&& mv -f "$marker.tmp" "$marker" 2>/dev/null || true
	if [ -n "$dead" ]; then
		warn "L7 measure-probe: client-DEAD transport(s):$dead (own-listener handshake failed)."
		return 1
	fi
	log "L7 measure-probe: all $tested L7-covered transport(s) (REALITY + genuine-TLS + QUIC + ShadowTLS; xhttp-tls remains L4-only) complete the own-listener handshake."
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
	if have flock; then
		exec 200>"${STATE_DIR:-/tmp}/l7_awg_probe.lock" 2>/dev/null || true
		flock -n 200 2>/dev/null || return 0
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
