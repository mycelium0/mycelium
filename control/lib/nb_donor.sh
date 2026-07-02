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

_donor_wait_listen() {
	# _donor_wait_listen PORT -> 0 if 127.0.0.1:PORT is accepting within ~3s, else 1. Confirms an
	# ephemeral engine actually BOUND before donor_verify_reality reads a probe failure as a broken
	# donor: a port collision / bind failure is "cannot judge" (rc 2), never "dead" (rc 1). Prefers ss;
	# falls back to a raw bash /dev/tcp connect where ss is absent.
	local p="$1" i
	for i in 1 2 3 4 5 6; do
		if have ss; then
			ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$" && return 0
		elif (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}

donor_verify_reality() {
	# donor_verify_reality HOST -> 0 iff HOST completes a REAL REALITY handshake AS THE DEST, probed from
	# THIS node's egress. THE AUTHORITATIVE donor gate. openssl TLS-level checks CANNOT distinguish a
	# REALITY-viable donor from a TLS-fine-but-REALITY-broken one: www.microsoft.com negotiates
	# TLSv1.3/x25519 (and even passes h2) yet breaks REALITY's handshake-steal, while a KNOWN-GOOD donor
	# (www.samsung.com) does NOT advertise the PQ group the way apple/google do — the two are
	# indistinguishable at the openssl layer, so only the REALITY handshake itself decides. Spins an
	# EPHEMERAL loopback REALITY server (dest=HOST) + client with the SAME uTLS fingerprint clients use,
	# and confirms a request traverses the tunnel.
	#   RETURNS: 0 = steal-viable; 1 = TLS-fine-but-REALITY-BROKEN (dead); 2 = COULD-NOT-JUDGE — the engine
	#   binary or curl is absent, keypair generation failed, or no ephemeral port pair would bind. The two
	#   callers treat rc 2 DIFFERENTLY, by design: the DEPLOY gate (donor_verify) fail-CLOSES on it (a donor
	#   that can't be validated must not be accepted — the engine is present by then, so rc 2 = broken node),
	#   while the DAEMON L7 probe (measure_l7_probe) treats it as NOT-dead (an advisory runtime signal must
	#   never spuriously rotate a healthy transport on a transient can't-judge).
	# Audit-0007 S2: the ephemeral ports are RANDOMIZED per attempt (not the fixed 29443/29444 that two
	# overlapping runs would collide on) and the whole handshake runs under an flock, so a deploy-time
	# donor pick and a timer-fired L7 probe cannot race for ports — a race would false-DEAD a healthy donor
	# and trigger a spurious rotation. A bind failure returns 2 (cannot judge), never 1 (dead). Self-cleaning.
	local host="$1"
	have "$SINGBOX_BIN" || return 2
	# The lock lives under STATE_DIR (node-shared) so a deploy-time donor pick and a timer-fired L7 probe
	# actually serialize — a systemd unit with PrivateTmp= would NOT share a /tmp lock. Falls back to /tmp
	# only if STATE_DIR is unset (pre-entrypoint callers); flock is best-effort either way (a failed open
	# just degrades to unserialized, and the random ports + bind check still contain any race).
	local lockf="${STATE_DIR:-${TMPDIR:-/tmp}}/donor-verify.lock"
	# fd 9 is opened INSIDE the subshell, so it is scoped to the subshell (auto-closed on exit, releasing
	# the flock) and cannot clash with the entrypoint's descriptors. The subshell's EXIT status IS the
	# verdict. flock -w 30 bounds the wait so a wedged holder degrades to unserialized (random ports +
	# the bind check still contain a race) instead of hanging.
	(
		# Declare the cleanup handles + arm the EXIT trap BEFORE anything can exit, so an early `exit 2`
		# (curl/mktemp/keypair) fires a trap that references only already-bound vars (set -u safe).
		local dir="" sp="" cp=""
		trap 'kill ${sp:-} ${cp:-} 2>/dev/null || :; [ -n "${dir:-}" ] && rm -rf "$dir" 2>/dev/null || :' EXIT
		if have flock; then exec 9>"$lockf" 2>/dev/null && flock -w 30 9 2>/dev/null || true; fi
		have curl || exit 2
		dir="$(mktemp -d 2>/dev/null)" || exit 2

		local kp priv pub sid uuid
		kp="$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)" || exit 2
		priv="$(printf '%s' "$kp" | awk 'tolower($0) ~ /private/ {print $NF}')"
		pub="$(printf  '%s' "$kp" | awk 'tolower($0) ~ /public/  {print $NF}')"
		sid="$(openssl rand -hex 8 2>/dev/null || :)"
		uuid="$("$SINGBOX_BIN" generate uuid 2>/dev/null || :)"
		[ -n "$priv" ] && [ -n "$pub" ] && [ -n "$sid" ] && [ -n "$uuid" ] || exit 2

		# Try up to 3 RANDOM ephemeral port pairs, chosen BELOW the OS ephemeral range to dodge the
		# kernel's own outbound sockets. A pair that will not bind is a collision, not a broken donor:
		# retry with fresh ports, and if none binds exit 2 (cannot judge).
		local attempt sport cport rc=1
		for attempt in 1 2 3; do
			sport=$(( 10000 + RANDOM % 20000 ))
			cport=$(( sport + 1 ))
			printf '%s' "{\"log\":{\"level\":\"error\"},\"inbounds\":[{\"type\":\"vless\",\"listen\":\"127.0.0.1\",\"listen_port\":$sport,\"users\":[{\"uuid\":\"$uuid\"}],\"tls\":{\"enabled\":true,\"server_name\":\"$host\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$host\",\"server_port\":443},\"private_key\":\"$priv\",\"short_id\":[\"$sid\"]}}}],\"outbounds\":[{\"type\":\"direct\"}]}" >"$dir/s.json"
			printf '%s' "{\"log\":{\"level\":\"error\"},\"inbounds\":[{\"type\":\"socks\",\"listen\":\"127.0.0.1\",\"listen_port\":$cport}],\"outbounds\":[{\"type\":\"vless\",\"tag\":\"v\",\"server\":\"127.0.0.1\",\"server_port\":$sport,\"uuid\":\"$uuid\",\"tls\":{\"enabled\":true,\"server_name\":\"$host\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},\"reality\":{\"enabled\":true,\"public_key\":\"$pub\",\"short_id\":\"$sid\"}}},{\"type\":\"direct\"}],\"route\":{\"final\":\"v\"}}" >"$dir/c.json"
			"$SINGBOX_BIN" run -c "$dir/s.json" >/dev/null 2>&1 & sp=$!
			"$SINGBOX_BIN" run -c "$dir/c.json" >/dev/null 2>&1 & cp=$!
			# Only read a probe failure as DEAD once BOTH ephemeral engines have actually bound; a bind
			# failure (port taken / crash) is a collision, not a broken donor.
			if _donor_wait_listen "$sport" && _donor_wait_listen "$cport"; then
				curl -s -o /dev/null --max-time 8 --socks5-hostname "127.0.0.1:$cport" "https://$host/" 2>/dev/null && rc=0
				exit "$rc"
			fi
			kill ${sp:-} ${cp:-} 2>/dev/null || :
			wait ${sp:-} ${cp:-} 2>/dev/null || :
			sp=""; cp=""
		done
		exit 2
	)
}

donor_verify() {
	# donor_verify HOST -> 0 iff HOST is a usable REALITY donor FROM THIS NODE. Two gates: a cheap TLSv1.3
	# pre-filter, then the AUTHORITATIVE REALITY handshake. The donor list's "require" also promises h2 ALPN
	# "where offered" — a best-effort PREFERENCE (donor_offers_h2 + pick_donor), not a hard gate. FAIL-CLOSED
	# (Audit-0007 S3, operator decision 2026-07-03): if the REALITY handshake cannot be judged (rc 2 —
	# engine/curl absent, or no ephemeral port would bind), the donor is REJECTED, not accepted on the
	# TLS-only pre-filter. `install_singbox` runs BEFORE donor selection (flow_bootstrap), so rc 2 here
	# signals a genuinely broken node, not a normal pre-engine condition — refusing to bootstrap beats
	# bringing up a node whose REALITY-donor viability could not be authoritatively validated.
	local host="$1"
	donor_verify_tls "$host" || return 1
	donor_verify_reality "$host"
	case "$?" in
		0) return 0 ;;
		2) warn "donor '$host': the REALITY-layer check could not run (engine/curl absent, or no ephemeral port would bind) — REJECTING (fail-closed): a donor whose REALITY viability cannot be authoritatively validated must not be accepted. The engine is installed before donor selection, so this signals a broken node; fix the install/curl and re-run."; return 1 ;;
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
