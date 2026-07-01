# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_donor.sh — node-bootstrap library: REALITY donor-SNI selection + runtime verification.
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: choose ONE verified donor SNI for this node (RANDOM per node from the
# committed candidate list), enforcing TLSv1.3-over-x25519 as the hard gate and h2 ALPN as a soft
# preference. CLASSIFICATION: OS-glue — it probes a REAL external host over the network (openssl
# s_client) and reads the committed candidate list (jq); the chosen value is stored in LOCAL
# identity state, never committed. This file is meant to be SOURCED into scripts/node-bootstrap.sh,
# never executed directly; it defines functions only and relies on the entrypoint's shared globals
# (DONOR_LIST, FORCE_DONOR, DRY_RUN) and helpers (log/warn/die/have) being defined at call time.
# Behaviour is byte-identical to the inline definitions it replaced.

donor_candidates() {
	have jq || die "jq required to read the donor candidate list."
	[ -f "$DONOR_LIST" ] || die "donor candidate list not found: $DONOR_LIST"
	jq -r '.candidates[]?' "$DONOR_LIST"
}

donor_verify_tls() {
	# donor_verify_tls HOST -> 0 if HOST negotiates TLSv1.3 over an x25519 group. This is a CHEAP
	# PRE-FILTER only (rejects dead / non-TLSv1.3 hosts before the heavier REALITY handshake); it is
	# NOT sufficient on its own — a TLS-fine host can still break REALITY (see donor_verify_reality).
	local host="$1"
	have openssl || { warn "openssl missing; cannot pre-filter donor '$host' — treating as unverified."; return 1; }
	echo | openssl s_client -groups x25519 -tls1_3 \
		-servername "$host" -connect "$host:443" 2>/dev/null \
		| grep -q 'TLSv1.3'
}

donor_verify_reality() {
	# donor_verify_reality HOST -> 0 iff HOST completes a REAL REALITY handshake AS THE DEST, probed from
	# THIS node's egress. THE AUTHORITATIVE donor gate. openssl TLS-level checks CANNOT distinguish a
	# REALITY-viable donor from a TLS-fine-but-REALITY-broken one: www.microsoft.com negotiates
	# TLSv1.3/x25519 (and even passes h2) yet breaks REALITY's handshake-steal, while a KNOWN-GOOD donor
	# (www.samsung.com) does NOT advertise the PQ group the way apple/google do — the two are
	# indistinguishable at the openssl layer, so only the REALITY handshake itself decides. Spins an
	# EPHEMERAL loopback REALITY server (dest=HOST) + client on 127.0.0.1 spare ports (the main engine
	# service is not yet running at donor-pick time) with the SAME uTLS fingerprint clients use, and
	# confirms a request traverses the tunnel. Returns 2 (not 1) when the engine binary is absent, so the
	# caller can degrade to the TLS-only pre-filter instead of hard-failing. Self-cleaning.
	local host="$1"
	have "$SINGBOX_BIN" || return 2
	local dir; dir="$(mktemp -d 2>/dev/null)" || return 1
	local kp priv pub sid uuid sport=29443 cport=29444 sp cp rc=1
	kp="$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)" || { rm -rf "$dir"; return 1; }
	priv="$(printf '%s' "$kp" | awk 'tolower($0) ~ /private/ {print $NF}')"
	pub="$(printf  '%s' "$kp" | awk 'tolower($0) ~ /public/  {print $NF}')"
	sid="$(openssl rand -hex 8 2>/dev/null)"
	uuid="$("$SINGBOX_BIN" generate uuid 2>/dev/null)"
	printf '%s' "{\"log\":{\"level\":\"error\"},\"inbounds\":[{\"type\":\"vless\",\"listen\":\"127.0.0.1\",\"listen_port\":$sport,\"users\":[{\"uuid\":\"$uuid\"}],\"tls\":{\"enabled\":true,\"server_name\":\"$host\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$host\",\"server_port\":443},\"private_key\":\"$priv\",\"short_id\":[\"$sid\"]}}}],\"outbounds\":[{\"type\":\"direct\"}]}" >"$dir/s.json"
	printf '%s' "{\"log\":{\"level\":\"error\"},\"inbounds\":[{\"type\":\"socks\",\"listen\":\"127.0.0.1\",\"listen_port\":$cport}],\"outbounds\":[{\"type\":\"vless\",\"tag\":\"v\",\"server\":\"127.0.0.1\",\"server_port\":$sport,\"uuid\":\"$uuid\",\"tls\":{\"enabled\":true,\"server_name\":\"$host\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},\"reality\":{\"enabled\":true,\"public_key\":\"$pub\",\"short_id\":\"$sid\"}}},{\"type\":\"direct\"}],\"route\":{\"final\":\"v\"}}" >"$dir/c.json"
	"$SINGBOX_BIN" run -c "$dir/s.json" >/dev/null 2>&1 &
	sp=$!
	"$SINGBOX_BIN" run -c "$dir/c.json" >/dev/null 2>&1 &
	cp=$!
	sleep 3
	curl -s -o /dev/null --max-time 8 --socks5-hostname "127.0.0.1:$cport" "https://$host/" 2>/dev/null && rc=0
	kill "$sp" "$cp" 2>/dev/null
	wait "$sp" "$cp" 2>/dev/null
	rm -rf "$dir"
	return "$rc"
}

donor_verify() {
	# donor_verify HOST -> 0 iff HOST is a usable REALITY donor FROM THIS NODE. Two gates: a cheap TLSv1.3
	# pre-filter, then the AUTHORITATIVE REALITY handshake. The donor list's "require" also promises h2 ALPN
	# "where offered" — a best-effort PREFERENCE (donor_offers_h2 + pick_donor), not a hard gate. Degrades to
	# the TLS-only result ONLY when the engine binary is unavailable (rc 2), loudly, so a pre-engine caller
	# still bootstraps instead of hard-failing.
	local host="$1"
	donor_verify_tls "$host" || return 1
	donor_verify_reality "$host"
	case "$?" in
		0) return 0 ;;
		2) warn "donor '$host': engine unavailable for the REALITY-layer check — accepting on the TLSv1.3 pre-filter ALONE (weaker; cannot catch a REALITY-broken dest such as www.microsoft.com)."; return 0 ;;
		*) warn "donor candidate '$host' passes TLSv1.3 but FAILS the REALITY handshake (a TLS-fine-but-REALITY-broken dest); rejecting."; return 1 ;;
	esac
}

donor_offers_h2() {
	# donor_offers_h2 HOST -> 0 if HOST negotiates the h2 ALPN. Best-effort PREFERENCE only: a donor
	# that lacks h2 is still acceptable (the JSON promises h2 "where offered"), so a non-zero here
	# never rejects a donor — it only de-prioritises it in pick_donor. REALITY mirrors whatever the
	# donor actually negotiates, so preferring an h2 donor keeps the borrowed fingerprint realistic.
	local host="$1"
	have openssl || return 1
	echo | openssl s_client -alpn h2,http/1.1 -tls1_3 \
		-servername "$host" -connect "$host:443" 2>/dev/null \
		| grep -Eq '^[[:space:]]*ALPN protocol:[[:space:]]*h2[[:space:]]*$'
}

pick_donor() {
	# Echo a verified donor host. Honors --donor (still verified). Tries candidates in random order.
	if [ -n "$FORCE_DONOR" ]; then
		if [ "$DRY_RUN" -eq 1 ] || donor_verify "$FORCE_DONOR"; then
			printf '%s\n' "$FORCE_DONOR"; return 0
		fi
		die "forced donor '$FORCE_DONOR' did not negotiate TLSv1.3 over x25519 (fail-closed)."
	fi
	local shuffled host
	# Shuffle without external deps: number, sort -R if available, else awk rand-tag.
	if have shuf; then
		shuffled="$(donor_candidates | shuf)"
	elif sort -R </dev/null >/dev/null 2>&1; then
		shuffled="$(donor_candidates | sort -R)"
	else
		shuffled="$(donor_candidates | awk 'BEGIN{srand()} {printf "%f\t%s\n", rand(), $0}' | sort | cut -f2-)"
	fi
	# Two-pass selection that keeps the JSON's "h2 ALPN where offered" promise honest WITHOUT
	# over-promising: TLSv1.3+x25519 is the HARD gate (donor_verify); h2 is a soft PREFERENCE. Pass 1
	# returns the first candidate that passes the hard gate AND offers h2; if none does, pass 2 falls
	# back to the first candidate that merely passes the hard gate. So a network with only non-h2 donors
	# still bootstraps (no false failure), but an h2 donor wins when one exists.
	local first_hard_ok=""
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		if [ "$DRY_RUN" -eq 1 ]; then printf '%s\n' "$host"; return 0; fi
		if donor_verify "$host"; then
			[ -n "$first_hard_ok" ] || first_hard_ok="$host"   # remember for the fallback pass
			if donor_offers_h2 "$host"; then printf '%s\n' "$host"; return 0; fi
			warn "donor candidate '$host' passes TLSv1.3/x25519 but did not offer h2 ALPN; preferring an h2 donor if available."
		else
			warn "donor candidate '$host' failed verification; trying the next."
		fi
	done <<EOF
$shuffled
EOF
	if [ -n "$first_hard_ok" ]; then
		warn "no candidate offered h2 ALPN; using '$first_hard_ok' (TLSv1.3/x25519 verified — the hard requirement)."
		printf '%s\n' "$first_hard_ok"; return 0
	fi
	die "no donor candidate negotiated TLSv1.3 over x25519 (fail-closed). Update the candidate list."
}
