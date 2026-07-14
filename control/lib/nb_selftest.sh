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
# www.microsoft.com regression), an expired/mismatched own cert. The one probe — `measure_l7_probe` —
# is the ADR-0036 own-cert/cover-path check: genuine-TLS = an openssl loopback handshake against the
# node's OWN listener; REALITY = an authenticated ephemeral steal against the node's OWN dest/cover host
# (donor_verify_reality) — probe-side retry-debounce, NO third-party beacon. It writes a marker to the
# path passed as $1 (default the daemon marker $STATE_DIR/l7_selftest.json). TWO callers: the cadenced
# mycelium-l7probe.timer (daemon marker) and the post-apply acceptance hook in verify_post_apply (a
# DISTINCT $STATE_DIR/l7_postapply.json, so it never clobbers the daemon marker — Audit-0007 S2).
# CLASSIFICATION: OS-glue — spins the engine + probes (sing-box, openssl); renders NOTHING, decides NO
# policy. ADVISORY: WARNs + records a marker, NEVER rolls back. SOURCED into scripts/node-bootstrap.sh,
# never executed directly; relies on the entrypoint globals (SINGBOX_BIN, SINGBOX_CONFIG, STATE_DIR) +
# helpers (have/log/warn) at call time.


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
# COVERAGE (Audit-0007 S2 + RP-0014 chunk A, honest scope): this probe covers the sing-box REALITY families
# (vless-reality-vision/-grpc/-xhttp — the authenticated dest steal, identical mechanism) and the own-cert
# genuine-TLS ws-tls (loopback SAN match) — the tags whose L7 failure the L4 reach window cannot see. STILL
# L4-only, each needing a PROTOCOL-SPECIFIC probe (RP-0014 chunk A follow-on): the QUIC families
# (hysteria2/tuic — a QUIC dial), shadowtls (an inner-auth probe, since the outer TLS relays a cover host),
# the Xray-served vless-xhttp-tls (a separate config), and AmneziaWG (a WG handshake, served by a separate
# engine — not in this sing-box config). Coverage is asserted here, never a silent claim, per ADR-0036.
measure_l7_probe() {
	have openssl && have jq || return 0
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local marker="${1:-$STATE_DIR/l7_selftest.json}" dead="" tested=0 row
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
$(jq -c '.inbounds[]? | select(.tag=="vless-reality-vision-in" or .tag=="vless-reality-grpc-in" or .tag=="vless-reality-xhttp-in" or .tag=="vless-ws-tls-in")
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
	log "L7 measure-probe: all $tested L7-covered transport(s) (REALITY + genuine-TLS; other families are L4-only) complete the own-listener handshake."
	return 0
}
