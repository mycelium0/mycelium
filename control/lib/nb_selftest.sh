# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_selftest.sh — node-bootstrap library: L7 transport ACCEPTANCE self-test.
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: confirm each CLIENT-FACING transport in the live config actually completes a
# REAL client handshake from the node's own loopback — the L7 truth that verify_listen_ports (L4, "is
# the port bound") cannot see. A bound listener can still be client-DEAD: a REALITY donor that breaks
# the handshake-steal (the 2026-07-01 www.microsoft.com regression), an expired/unreadable own cert, an
# engine mismatch. CLASSIFICATION: OS-glue — it spins the engine + probes over loopback (sing-box, curl)
# and reads the live config (jq); it renders NOTHING and decides NO policy. ADVISORY: the entrypoint's
# verify_post_apply WARNs + records a marker on a dead transport, and NEVER rolls back (a transient probe
# blip must not revert a healthy config; promotable to fail-closed once field-trusted). This file is
# meant to be SOURCED into scripts/node-bootstrap.sh, never executed directly; it defines functions only
# and relies on the entrypoint's shared globals (SINGBOX_BIN, SINGBOX_CONFIG, STATE_DIR) and helpers
# (have/log/warn) being defined at call time.

# x25519_pub_from_priv PRIV -> echoes the base64url x25519 PUBLIC key derived from a REALITY private key
# (needed to build a matching REALITY *client* for the L7 self-test; the live config stores only the
# private key). Uses python3+cryptography; echoes nothing + returns non-zero when unavailable.
x25519_pub_from_priv() {
	have python3 || return 1
	python3 - "$1" 2>/dev/null <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey as K
from cryptography.hazmat.primitives import serialization as S
r = sys.argv[1]; r += "=" * (-len(r) % 4)
k = K.from_private_bytes(base64.urlsafe_b64decode(r))
print(base64.urlsafe_b64encode(k.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw)).rstrip(b"=").decode())
PY
}

# verify_transports_l7 — L7 acceptance for the CLIENT-FACING transports. For each enabled reality/ws-tls
# inbound in the LIVE config, spin an EPHEMERAL matching sing-box CLIENT against the node's OWN loopback
# listener (the live server), with the SAME creds + uTLS fingerprint a real client uses, and confirm a
# request traverses the tunnel to a neutral 204 endpoint. Records a marker with any dead transports and
# returns non-zero iff >=1 is dead. Best-effort (missing engine/jq/curl -> pass, never a false failure).
# Self-cleaning.
verify_transports_l7() {
	have "$SINGBOX_BIN" && have jq && have curl || return 0
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local marker="$STATE_DIR/l7_selftest.json" probe_url="https://www.gstatic.com/generate_204"
	local dead="" tested=0 row
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		local tag port net uuid flow sni sid priv pub svc wp
		tag="$(printf '%s'  "$row" | jq -r '.tag')"
		port="$(printf '%s' "$row" | jq -r '.port')"
		net="$(printf '%s'  "$row" | jq -r '.net')"
		uuid="$(printf '%s' "$row" | jq -r '.uuid')"
		flow="$(printf '%s' "$row" | jq -r '.flow // ""')"
		sni="$(printf '%s'  "$row" | jq -r '.sni')"
		local reality_block="" transport_block="" flow_kv=""
		if [ "$(printf '%s' "$row" | jq -r '.reality')" = "true" ]; then
			sid="$(printf  '%s' "$row" | jq -r '.sid')"
			priv="$(printf '%s' "$row" | jq -r '.priv')"
			pub="$(x25519_pub_from_priv "$priv")"
			[ -n "$pub" ] || { warn "L7 self-test: cannot derive the REALITY pubkey for '$tag' (python3/cryptography?) — skipping it."; continue; }
			reality_block=",\"reality\":{\"enabled\":true,\"public_key\":\"$pub\",\"short_id\":\"$sid\"}"
		fi
		[ -n "$flow" ] && [ "$flow" != "null" ] && flow_kv="\"flow\":\"$flow\","
		case "$net" in
			grpc) svc="$(printf '%s' "$row" | jq -r '.svc // "grpc.health.v1.Health"')"; transport_block=",\"transport\":{\"type\":\"grpc\",\"service_name\":\"$svc\"}" ;;
			ws)   wp="$(printf  '%s' "$row" | jq -r '.wspath // "/ws"')";                 transport_block=",\"transport\":{\"type\":\"ws\",\"path\":\"$wp\"}" ;;
		esac
		local dir cport cp rc
		dir="$(mktemp -d)" || continue
		cport=$(( 30000 + port % 3000 ))
		printf '%s' "{\"log\":{\"level\":\"error\"},\"inbounds\":[{\"type\":\"socks\",\"listen\":\"127.0.0.1\",\"listen_port\":$cport}],\"outbounds\":[{\"type\":\"vless\",\"tag\":\"v\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"uuid\":\"$uuid\",${flow_kv}\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}${reality_block}}${transport_block}},{\"type\":\"direct\"}],\"route\":{\"final\":\"v\"}}" >"$dir/c.json"
		"$SINGBOX_BIN" run -c "$dir/c.json" >/dev/null 2>&1 &
		cp=$!
		sleep 2
		rc=1
		curl -s -o /dev/null --max-time 6 --socks5-hostname "127.0.0.1:$cport" "$probe_url" 2>/dev/null && rc=0
		kill "$cp" 2>/dev/null
		wait "$cp" 2>/dev/null
		rm -rf "$dir"
		tested=$(( tested + 1 ))
		[ "$rc" -eq 0 ] || dead="$dead $tag"
	done <<PROBE_EOF
$(jq -c '.inbounds[]? | select(.tag=="vless-reality-vision-in" or .tag=="vless-reality-grpc-in" or .tag=="vless-ws-tls-in")
	| {tag, port:.listen_port, net:(.transport.type // "tcp"), uuid:(.users[0].uuid), flow:(.users[0].flow),
	   sni:.tls.server_name, sid:(.tls.reality.short_id[0]?), priv:(.tls.reality.private_key?),
	   reality:((.tls.reality.enabled) // false), svc:(.transport.service_name?), wspath:(.transport.path?)}' "$SINGBOX_CONFIG" 2>/dev/null)
PROBE_EOF
	printf '{"checked":%d,"dead":[%s]}\n' "$tested" "$(for d in $dead; do printf '"%s",' "$d"; done | sed 's/,$//')" >"$marker" 2>/dev/null || true
	if [ -n "$dead" ]; then
		warn "L7 self-test: client-DEAD transport(s):$dead (listener bound but a real client could not handshake)."
		return 1
	fi
	log "L7 self-test: all $tested client-facing transport(s) accept a real client handshake."
	return 0
}

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
measure_l7_probe() {
	have openssl && have jq || return 0
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local marker="$STATE_DIR/l7_selftest.json" dead="" tested=0 row
	local TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 8"
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		local tag ref port reality sni dest drc ok=0 attempt
		tag="$(printf '%s'     "$row" | jq -r '.tag')"
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
		if [ "$reality" = "true" ]; then
			# REALITY: the broken-dest failure (e.g. www.microsoft.com) still completes TLS *and* the
			# server's UNAUTHENTICATED fallback relay — only the AUTHENTICATED steal breaks. A plain openssl
			# handshake rides that fallback and would MISS it. Use the authenticated ephemeral REALITY
			# handshake against dest (donor_verify_reality — the same steal-viability the live server
			# depends on); it contacts only the node's own cover/dest host, not a third party.
			[ -n "$dest" ] || { tested=$(( tested + 1 )); continue; }
			for attempt in 1 2 3; do
				donor_verify_reality "$dest"; drc=$?
				# 0 = steal-viable, 2 = engine unavailable (cannot judge) -> NOT dead; 1 = broken -> retry.
				[ "$drc" -ne 1 ] && { ok=1; break; }
				sleep 1
			done
		else
			# genuine-TLS: own-cert loopback handshake + non-expired cert (pure loopback, no external
			# contact). A missing/expired own-cert or a dead listener yields no cert -> x509 fails.
			[ -n "$sni" ] || { tested=$(( tested + 1 )); continue; }
			for attempt in 1 2 3; do
				if echo | $TO openssl s_client -connect "127.0.0.1:$port" -servername "$sni" 2>/dev/null \
					| openssl x509 -noout -checkend 0 >/dev/null 2>&1; then ok=1; break; fi
				sleep 1
			done
		fi
		tested=$(( tested + 1 ))
		[ "$ok" -eq 1 ] || dead="$dead $ref"
	done <<PROBE_EOF
$(jq -c '.inbounds[]? | select(.tag=="vless-reality-vision-in" or .tag=="vless-reality-grpc-in" or .tag=="vless-ws-tls-in")
	| {tag, port:.listen_port, reality:((.tls.reality.enabled)//false), sni:(.tls.server_name),
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
	log "L7 measure-probe: all $tested client-facing transport(s) complete the own-listener handshake."
	return 0
}
