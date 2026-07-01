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
