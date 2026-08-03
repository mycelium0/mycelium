# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_render_awg.sh — node-bootstrap library: the AmneziaWG/UDP second transport family — split-tunnel
# AllowedIPs policy (compute_client_allowed + sg_allowed_join), the awg0.conf + per-client render
# (render_awg0), and the userspace build/bring-up (install_awg_tools + setup_amneziawg).
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: own the AmneziaWG second-family path — render the server awg0.conf + a
# ready-to-import client config per identity (first-time only; a live config is never clobbered), and
# build + bring up the kernel-independent userspace implementation (amneziawg-go + awg/awg-quick) from
# pinned source.
# CLASSIFICATION: MIXED. The Selective-Growth split-tunnel AllowedIPs decision (compute_client_allowed +
# sg_allowed_join; VIS-0009/ADR-0027 — never silently full-tunnel) is CONTROL-LOGIC, EARMARKED for the
# RP-0008 Go migration; the userspace build + awg-quick@ setup (install_awg_tools + setup_amneziawg) and
# the awg0.conf rendering are OS-glue that stays bash by design. This file is meant to be SOURCED into
# scripts/node-bootstrap.sh, never executed directly; it defines functions + their dedicated AmneziaWG
# constants (the in-tunnel dialect, the split-tunnel knobs, and the pinned userspace source repos/tags)
# and relies on the entrypoint's shared globals (STATE_DIR, CLIENT_NAMES, DO_AMNEZIAWG, DRY_RUN,
# AWG_BIN_DIR, AWG_REGION_EXCLUDE_FILE, AWG_FULL_TUNNEL_OPTOUT, NODE_ADDRESS_PLACEHOLDER) and helpers
# (log/warn/die/have/run/need_root) being defined at call time. resolve_node_address (in
# nb_render_params.sh) is resolved at call time from the shared sourced scope. AWG_REGION_EXCLUDE_FILE +
# AWG_FULL_TUNNEL_OPTOUT stay in the entrypoint (they are set by arg-parse and propagated through the
# --update re-exec); AWG_BIN_DIR stays in the entrypoint's canonical-paths block. Behaviour is
# byte-identical to the inline definitions it replaced.

# AmneziaWG userspace sources (public; built from source — kernel-independent).
AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go"
AWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools"
# Pinned source tags for the userspace build. There is NO upstream prebuilt amneziawg-go release, so a
# from-zero node builds these from source (apt golang-go + build-essential). amneziawg-go matches the
# network; amneziawg-tools is the current tag. Bumping these is a separate, verified change.
AWG_GO_TAG="v0.2.18"
AWG_TOOLS_TAG="v1.0.20260223"

# AmneziaWG in-tunnel addressing. The obfuscation "dialect" (Jc/Jmin/Jmax/S1/S2/H1..H4) is NOT a committed
# constant — see derive_awg_dialect below (Audit-0008 S1-4). Every peer (server + all its clients) MUST
# share the dialect or the handshake fails; we get that for free by deriving it deterministically from the
# node's own AmneziaWG key at render time, so server + every client of ONE node compute the SAME dialect
# while DIFFERENT nodes get DIFFERENT dialects. The render below uses these ONLY when first creating a
# node's awg0.conf; an existing awg0.conf is never overwritten.
AWG_TUNNEL_V4="10.13.13.1/24"      # server in-tunnel v4 (RFC1918); peers get .2, .3, …
AWG_TUNNEL_V6="fd13:13:13::1/64"   # server in-tunnel v6 (RFC4193 ULA); used only if the node has global v6
AWG_PEER_BASE_V4="10.13.13"
AWG_PEER_BASE_V6="fd13:13:13::"
AWG_MTU="1280"
# The dialect vars (AWG_JC/AWG_JMIN/AWG_JMAX/AWG_S1/AWG_S2/AWG_H1..AWG_H4) are set by derive_awg_dialect
# at render time — NOT hardcoded here. A hardcoded network-wide dialect committed in a public repo is a
# free network-wide block (one passive UDP payload-match rule keyed on the published H1 drops the AWG
# family on every node at once); per-node derivation removes that single point (Audit-0008 S1-4).

# _awg_digest INPUT SALT — emit 64 hex chars = SHA-256("<INPUT>|mycelium-awg-dialect-v1|<SALT>"), via the
# audited sha256sum (universal on Linux nodes) or openssl as a fallback. Domain-separated + salted so a
# caller can re-draw (the distinct-header retry) deterministically. Reads no files; touches no network.
_awg_digest() {
	if have sha256sum; then
		printf '%s|mycelium-awg-dialect-v1|%s' "$1" "$2" | sha256sum | cut -d' ' -f1
	else
		printf '%s|mycelium-awg-dialect-v1|%s' "$1" "$2" | openssl dgst -sha256 -r | cut -d' ' -f1
	fi
}

# derive_awg_dialect INPUT — Audit-0008 S1-4: set the per-node AmneziaWG obfuscation dialect
# (AWG_H1..AWG_H4 + AWG_JC/AWG_JMIN/AWG_JMAX/AWG_S1/AWG_S2) DETERMINISTICALLY from INPUT (the node's own
# AmneziaWG private key). Deterministic ⇒ server + every client of THIS node get the SAME dialect (the
# handshake matches); keyed on a per-node value ⇒ DIFFERENT nodes get DIFFERENT dialects and the repo
# discloses none. Constraints held by construction: H1..H4 are distinct uint32 all > 4 (never collide with
# WireGuard's message types 1..4); Jmin < Jmax; (S1 + 56) != S2.
#
# ADR-0002 note: this is HEADER RANDOMIZATION + junk-packet sizing — obfuscation the ADR EXPLICITLY permits
# ("shaping, padding, junk packets, header randomization ... permitted — but not a confidentiality
# boundary"). It produces NO key material and is not a confidentiality boundary; SHA-256 is used only as an
# off-the-shelf digest from the audited sha256sum/openssl. No custom primitive is introduced.
derive_awg_dialect() {
	local input="$1" epoch="${2:-0}" salt=0 dg
	[ -n "$input" ] || die "AWG dialect derivation: empty node value (cannot derive a per-node dialect)."
	# Rotation epoch (RP/Audit-0008 S1-4 follow-up): epoch 0 — the default, and the state of every node
	# migrated before rotation existed — derives from the key ALONE, so introducing rotation reproduces a
	# node's original dialect byte-for-byte. Each bump (--awg-rotate) folds the counter in and yields a
	# completely different dialect from the SAME key, so a node can move off a known/blocked dialect
	# without touching any key or peer.
	case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
	[ "$epoch" -eq 0 ] || input="$input|epoch$epoch"
	have sha256sum || have openssl || die "AWG dialect derivation needs sha256sum or openssl (neither found)."
	# Headers: 4 distinct uint32 in [5, 2^32-1]. 4294967291 = 2^32-5, so (word % 4294967291) + 5 ∈ [5, 2^32-1].
	# Collisions among 4 draws are ~1e-9; on the off chance, bump the salt and re-draw (deterministic).
	while :; do
		dg="$(_awg_digest "$input" "$salt")"
		[ "${#dg}" -ge 42 ] || die "AWG dialect derivation: short digest (sha256 tool misbehaved)."
		AWG_H1=$(( 5 + (16#${dg:0:8} % 4294967291) ))
		AWG_H2=$(( 5 + (16#${dg:8:8} % 4294967291) ))
		AWG_H3=$(( 5 + (16#${dg:16:8} % 4294967291) ))
		AWG_H4=$(( 5 + (16#${dg:24:8} % 4294967291) ))
		if [ "$AWG_H1" -ne "$AWG_H2" ] && [ "$AWG_H1" -ne "$AWG_H3" ] && [ "$AWG_H1" -ne "$AWG_H4" ] \
			&& [ "$AWG_H2" -ne "$AWG_H3" ] && [ "$AWG_H2" -ne "$AWG_H4" ] && [ "$AWG_H3" -ne "$AWG_H4" ]; then
			break
		fi
		salt=$(( salt + 1 ))
		[ "$salt" -lt 16 ] || die "AWG dialect derivation: could not obtain 4 distinct headers (unexpected)."
	done
	# Jitter within tight, known-good bounds (each a fresh byte of the same digest): Jc 3..10, Jmin 24..64,
	# Jmax = Jmin+16..Jmin+64 (so Jmin<Jmax with margin), S1 24..96, S2 = S1+57..S1+160 (so (S1+56)!=S2, S2>S1).
	AWG_JC=$((   3 + (16#${dg:32:2} % 8)  ))
	AWG_JMIN=$(( 24 + (16#${dg:34:2} % 41) ))
	AWG_JMAX=$(( AWG_JMIN + 16 + (16#${dg:36:2} % 49) ))
	AWG_S1=$((   24 + (16#${dg:38:2} % 73) ))
	AWG_S2=$((   AWG_S1 + 57 + (16#${dg:40:2} % 104) ))
	log "derived per-node AmneziaWG dialect from the node key (Audit-0008 S1-4: not a committed network-wide constant)."
}

# --- Selective Growth: client-side split-tunnel defaults (VIS-0009; ADR-0027; closed-by-default lineage
# ADR-0026) -------------------------------------------------------------------------------------------
# "The mycelium does not grow where it is not needed." A generated CLIENT config carries ONLY traffic
# whose native path is impaired; natively-reachable destinations route DIRECT (split-tunnel). The
# WireGuard-class transport is CIDR-only, so it can only APPROXIMATE this via a region-exclude
# AllowedIPs route set (domain-aware split is the xray-class engine's job, not this path's). These
# knobs touch ONLY the generated client config(s); the server awg0.conf is never affected.
# AWG_REGION_EXCLUDE_FILE + AWG_FULL_TUNNEL_OPTOUT are operator-settable via arg-parse (and propagated
# through the --update re-exec), so they stay in the entrypoint; the split-tunnel-on default + the
# opt-out marker below are dedicated to this path and live here.
AWG_SPLIT_TUNNEL=1                 # 1 = split-tunnel by default (Selective Growth); 0 only with the opt-out below
AWG_SG_OPTOUT_MARKER="# selective-growth: opt-out (full-tunnel)"  # exact marker the gate look-behinds for

# compute_client_allowed HAS_V6 -> set SG_ALLOWED_LINES (one CIDR/line) + SG_MARKER. Selective Growth
# (VIS-0009/ADR-0027): the generated CLIENT tunnel carries ONLY impaired-path traffic; we NEVER silently
# full-tunnel. Resolution order:
#   1. AWG_FULL_TUNNEL_OPTOUT=1            -> deliberate full tunnel: marker + default route(s).
#   2. split-tunnel ON + non-empty list   -> that file's region-exclude route set, verbatim.
#   3. split-tunnel ON + no/empty list    -> SAFE NARROW: in-tunnel range(s) only; warn loudly.
#   4. split-tunnel OFF without opt-out    -> refuse (return 1).
compute_client_allowed() {
	local has_v6="$1" line v4net
	SG_ALLOWED_LINES=""; SG_MARKER=""
	if [ "$AWG_FULL_TUNNEL_OPTOUT" -eq 1 ]; then
		SG_MARKER="$AWG_SG_OPTOUT_MARKER"
		if [ "$has_v6" -eq 1 ]; then SG_ALLOWED_LINES="0.0.0.0/0
::/0"; else SG_ALLOWED_LINES="0.0.0.0/0"; fi
		warn "AWG_FULL_TUNNEL_OPTOUT=1 — emitting a DELIBERATE full-tunnel client (marker recorded). Prefer a region-exclude list (Selective Growth)."
		return 0
	fi
	if [ "$AWG_SPLIT_TUNNEL" -eq 0 ]; then
		warn "AWG_SPLIT_TUNNEL=0 with no AWG_FULL_TUNNEL_OPTOUT — refusing an undocumented full-tunnel client."
		return 1
	fi
	if [ -n "$AWG_REGION_EXCLUDE_FILE" ] && [ -f "$AWG_REGION_EXCLUDE_FILE" ]; then
		while IFS= read -r line; do
			line="${line%%#*}"
			line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
			[ -n "$line" ] || continue
			case "$line" in
				0.0.0.0/0|::/0) warn "region-exclude file lists a default route ($line) — that is a full tunnel; ignoring that entry."; continue ;;
			esac
			if [ -z "$SG_ALLOWED_LINES" ]; then SG_ALLOWED_LINES="$line"; else SG_ALLOWED_LINES="$SG_ALLOWED_LINES
$line"; fi
		done < "$AWG_REGION_EXCLUDE_FILE"
		if [ -n "$SG_ALLOWED_LINES" ]; then
			# IPv6-leak guard (ADR-0027): a region-exclude list that carries NO v6 route leaves the client's
			# PUBLIC IPv6 outside the tunnel — the client still gets an in-tunnel v6 ULA AND the host keeps its
			# own v6 default route, so v6 egresses DIRECT, defeating the split (impaired-path destinations leak
			# over v6). If the list is v4-only, capture all v6 into the tunnel (::/0): the node routes it when it
			# has global v6, otherwise it is dropped and apps fall back to (tunnelled) IPv4. Never leak v6.
			if ! printf '%s\n' "$SG_ALLOWED_LINES" | grep -q ':'; then
				SG_ALLOWED_LINES="$SG_ALLOWED_LINES
::/0"
				log "split-tunnel: region-exclude list is IPv4-only — appended ::/0 to stop an IPv6 leak."
			fi
			log "split-tunnel: AllowedIPs from region-exclude file $AWG_REGION_EXCLUDE_FILE (Selective Growth)."
			return 0
		fi
		warn "region-exclude file $AWG_REGION_EXCLUDE_FILE yielded no usable CIDRs — falling back to the safe narrow default."
	fi
	v4net="$(printf '%s' "$AWG_TUNNEL_V4" | sed -E 's#\.[0-9]+/[0-9]+$#.0/24#')"
	SG_ALLOWED_LINES="$v4net"
	if [ "$has_v6" -eq 1 ]; then SG_ALLOWED_LINES="$SG_ALLOWED_LINES
${AWG_PEER_BASE_V6}/64"; fi
	warn "no region-exclude list configured (AWG_REGION_EXCLUDE_FILE unset/empty) — emitting a SAFE NARROW client (tunnel ranges only). It will NOT carry out-of-region impaired-path traffic until you supply a region-exclude AllowedIPs file. Intentional: we never silently full-tunnel."
	return 0
}

# sg_allowed_join -> echo SG_ALLOWED_LINES as 'a, b, c' (pure bash; no paste dependency).
sg_allowed_join() {
	local out="" line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ -z "$out" ]; then out="$line"; else out="$out, $line"; fi
	done < <(printf '%s\n' "$SG_ALLOWED_LINES")
	printf '%s' "$out"
}

# render_awg_client_conf CPRIV HOST HAS_V6 SPUB CPSK ENDPOINT ALLOWED MARKER — emit ONE complete,
# ready-to-import AmneziaWG client config on stdout. This is the SINGLE shell client renderer: both the
# first-time render (render_awg0) and the live issue path (issue_awg_client) go through it, so the two can
# never drift. It is the byte-twin of Go spec.RenderAWGClientConfig, pinned by
# tests/conformance/awg_client_conf_go_equiv.sh. Uses the AWG_* dialect vars set by derive_awg_dialect.
# Pure text emission: no files, no network (the caller redirects + chmods).
render_awg_client_conf() {
	local cpriv="$1" host="$2" has_v6="$3" spub="$4" cpsk="$5" endpoint="$6" allowed="$7" marker="$8"
	local cv6="" cdns="1.1.1.1"
	if [ "$has_v6" -eq 1 ]; then
		cv6=", ${AWG_PEER_BASE_V6}${host}/128"; cdns="1.1.1.1, 2606:4700:4700::1111"
	fi
	printf '[Interface]\n'
	printf 'PrivateKey = %s\n' "$cpriv"
	printf 'Address = %s.%s/32%s\n' "$AWG_PEER_BASE_V4" "$host" "$cv6"
	printf 'DNS = %s\n' "$cdns"
	printf 'MTU = %s\n' "$AWG_MTU"
	printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2"
	printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
	printf '\n[Peer]\n'
	printf 'PublicKey = %s\n' "$spub"
	printf 'PresharedKey = %s\n' "$cpsk"
	printf 'Endpoint = %s\n' "$endpoint"
	[ -n "$marker" ] && printf '%s\n' "$marker"
	printf 'AllowedIPs = %s\n' "$allowed"
	printf 'PersistentKeepalive = 25\n'
}

# render_awg0 — FIRST-TIME render of the AmneziaWG server config (awg0.conf) + one [Peer] per client,
# plus a ready-to-import client config per identity. Mirrors the audited amneziawg Ansible role
# (templates/awg0.conf.j2 + defaults). The CALLER invokes this ONLY when awg0.conf is ABSENT, so a
# live/hand-tuned config (a node already in service) is NEVER clobbered. Per-client awg keypairs are
# generated once (0600) and reused. The node is v4-only unless it has a global IPv6 address, in which
# case it is dual-stack with NAT66 — matching the live network. No custom crypto: keys come only from
# awg genkey|pubkey|genpsk (ADR-0002).
render_awg0() {
	local out="$1"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would render $out + per-client AmneziaWG configs"; return 0; fi
	local awg_state="$STATE_DIR/awg" clients_dir
	clients_dir="$awg_state/clients"
	run install -d -m 0700 "$clients_dir"
	local spriv spub port wan has_v6 addr postup postdown
	spriv="$(cat "$awg_state/private.key")"
	spub="$(cat "$awg_state/public.key")"
	# Audit-0008 S1-4: set the per-node obfuscation dialect (H1..H4 + jitter) from THIS node's key before
	# writing either the server awg0.conf or any client config, so both sides of every handshake match and
	# no two nodes share a dialect. The key was just read (spriv) — derivation cannot fail on a real node.
	# Per-node dialect at this node's CURRENT rotation epoch (0 on a fresh node) — so a re-render after an
	# --awg-rotate keeps the rotated dialect instead of reverting to the epoch-0 one.
	derive_awg_dialect "$spriv" "$(_awg_read_epoch)"
	port="$(cat "$STATE_DIR/awg.port" 2>/dev/null || echo 51820)"
	wan="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
	[ -n "$wan" ] || { warn "could not detect the WAN interface; using 'eth0' in awg0.conf — verify it."; wan="eth0"; }
	has_v6=0; ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' && has_v6=1
	if [ "$has_v6" -eq 1 ]; then
		addr="$AWG_TUNNEL_V4, $AWG_TUNNEL_V6"
		postup="sysctl -w net.ipv4.ip_forward=1; sysctl -w net.ipv6.conf.all.forwarding=1; iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $wan -j MASQUERADE; ip6tables -t nat -A POSTROUTING -o $wan -j MASQUERADE"
		postdown="iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $wan -j MASQUERADE; ip6tables -t nat -D POSTROUTING -o $wan -j MASQUERADE"
	else
		addr="$AWG_TUNNEL_V4"
		postup="sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $wan -j MASQUERADE"
		postdown="iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $wan -j MASQUERADE"
	fi
	( umask 077; {
		printf '[Interface]\n'
		printf 'PrivateKey = %s\n' "$spriv"
		printf 'Address = %s\n' "$addr"
		printf 'ListenPort = %s\n' "$port"
		printf 'MTU = %s\n' "$AWG_MTU"
		printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2"
		printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
		printf 'PostUp = %s\n' "$postup"
		printf 'PostDown = %s\n' "$postdown"
	} > "$out" )
	# One [Peer] per client; generate the client's keypair+psk once and emit a ready client config.
	local node_addr; node_addr="$(resolve_node_address 2>/dev/null || printf '%s' "$NODE_ADDRESS_PLACEHOLDER")"
	local n=2 name cpub cpriv cpsk cv6 client_allowed
	for name in $CLIENT_NAMES; do
		# 10.13.13.240–.254 is RESERVED for the node-local L7 liveness probe (nb_selftest.sh
		# measure_l7_probe_amneziawg enrols an ephemeral probe-peer in that block). Fail CLOSED before a
		# client could be assigned into it, so the probe's reserved-range pre-clean can never remove a real
		# client peer. A /24 tunnel addresses .2–.239 for clients (238); split the node or widen
		# AWG_TUNNEL_V4 beyond /24 to serve more.
		[ "$n" -lt 240 ] || die "AmneziaWG client count exceeds the addressable client range (.2–.239 on a /24); .240–.254 is reserved for the L7 liveness probe. Split the node or widen AWG_TUNNEL_V4 beyond a /24."
		[ -f "$clients_dir/$name.private" ] || ( umask 077; awg genkey >"$clients_dir/$name.private" )
		cpriv="$(cat "$clients_dir/$name.private")"
		cpub="$(awg pubkey <"$clients_dir/$name.private")"
		[ -f "$clients_dir/$name.psk" ] || ( umask 077; awg genpsk >"$clients_dir/$name.psk" )
		cpsk="$(cat "$clients_dir/$name.psk")"
		if [ "$has_v6" -eq 1 ]; then
			cv6=", ${AWG_PEER_BASE_V6}${n}/128"
		else
			cv6=""
		fi
		# Selective Growth (VIS-0009/ADR-0027): the client tunnel carries ONLY impaired-path traffic by default.
		compute_client_allowed "$has_v6" || die "AmneziaWG client AllowedIPs unresolved — set AWG_FULL_TUNNEL_OPTOUT=1 to deliberately full-tunnel, or supply AWG_REGION_EXCLUDE_FILE."
		client_allowed="$(sg_allowed_join)"
		{
			printf '\n[Peer]\n# name = %s\n' "$name"
			printf 'PublicKey = %s\n' "$cpub"
			printf 'PresharedKey = %s\n' "$cpsk"
			printf 'AllowedIPs = %s.%s/32%s\n' "$AWG_PEER_BASE_V4" "$n" "$cv6"
		} >> "$out"
		( umask 077; render_awg_client_conf "$cpriv" "$n" "$has_v6" "$spub" "$cpsk" \
			"$node_addr:$port" "$client_allowed" "$SG_MARKER" > "$clients_dir/$name.conf" )
		run chmod 0600 "$clients_dir/$name.conf"
		n=$((n + 1))
	done
	run chmod 0600 "$out"
	log "rendered $out + $(set -- $CLIENT_NAMES; printf '%s' "$#") AmneziaWG client config(s) under $clients_dir (0600, local — hand off out-of-band, like subscriptions)."
}

# ---------------------------------------------------------------------------
# AmneziaWG userspace path (amneziawg-go, kernel-independent). Built from source; brought up via
# awg-quick@ forcing the userspace implementation. Keys from awg genkey|pubkey|genpsk (ADR-0002).
# Out-of-band of the sing-box render (AmneziaWG is NOT a sing-box inbound).
# ---------------------------------------------------------------------------
# install_awg_tools — build + install the AmneziaWG userspace tools from pinned source when absent, so a
# fresh-VPS bootstrap brings up the second transport family with no manual fixups (Audit-0004 D4 / F-006).
# No upstream prebuilt amneziawg-go release exists, so this builds from source (the PINNED Go from
# install_go_toolchain + apt build-essential). Idempotent: a no-op when awg/awg-quick/amneziawg-go are already present. Also renders
# the custom awg-quick@.service that forces the userspace implementation (the kernel module is not used).
# flow_bootstrap-only (called from setup_amneziawg, which the timer never runs).
install_awg_tools() {
	if have awg && have awg-quick && have amneziawg-go; then
		log "AmneziaWG userspace tools already present; skipping build."
		return 0
	fi
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] would apt-get install build-essential + fetch the pinned Go toolchain (install_go_toolchain), build amneziawg-go $AWG_GO_TAG + amneziawg-tools $AWG_TOOLS_TAG from source, install them, and render the userspace awg-quick@ unit."
		return 0
	fi
	have apt-get || die "AmneziaWG tools absent and no apt-get to bootstrap the build toolchain — install build-essential + the awg tools by hand (the Go toolchain is pinned + fetched by install_go_toolchain), or pass --no-amneziawg."
	log "building AmneziaWG userspace tools from pinned source (amneziawg-go $AWG_GO_TAG, amneziawg-tools $AWG_TOOLS_TAG)"
	env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential || die "failed to install build-essential for the AmneziaWG build."
	# The AmneziaWG userspace build needs Go too — use the SAME pinned, non-distro toolchain as the spine.
	# No fallback here (unlike install_spine): AmneziaWG is a required transport family, so a missing/
	# unverifiable toolchain is fatal (matches this builder's existing die-not-degrade contract).
	install_go_toolchain || die "AmneziaWG build needs the pinned Go toolchain and it could not be fetched/verified — check egress + control/engines.manifest.json (toolchains.go), or pass --no-amneziawg."
	local build; build="$(mktemp -d)" || die "mktemp failed for the AmneziaWG build."
	if ! have amneziawg-go; then
		git clone --depth 1 -b "$AWG_GO_TAG" "$AWG_GO_REPO" "$build/awg-go" || die "amneziawg-go clone ($AWG_GO_TAG) failed."
		( cd "$build/awg-go" && GOTOOLCHAIN=local "$MYC_GO_BIN" build -trimpath -o amneziawg-go . ) || die "amneziawg-go build failed (check the Go toolchain)."
		install -m 0755 "$build/awg-go/amneziawg-go" "$AWG_BIN_DIR/amneziawg-go" || die "amneziawg-go install failed."
		log "built + installed amneziawg-go -> $AWG_BIN_DIR/amneziawg-go"
	fi
	if ! have awg || ! have awg-quick; then
		git clone --depth 1 -b "$AWG_TOOLS_TAG" "$AWG_TOOLS_REPO" "$build/awg-tools" || die "amneziawg-tools clone ($AWG_TOOLS_TAG) failed."
		make -C "$build/awg-tools/src" >/dev/null || die "amneziawg-tools build failed."
		make -C "$build/awg-tools/src" install >/dev/null || die "amneziawg-tools install failed."
		log "built + installed awg + awg-quick (amneziawg-tools $AWG_TOOLS_TAG)"
	fi
	rm -rf "$build" 2>/dev/null || true
	# Custom awg-quick@ unit forcing the userspace implementation (the kernel module is never used).
	local unit="/etc/systemd/system/awg-quick@.service"
	if [ ! -f "$unit" ]; then
		printf '%s\n' \
			'[Unit]' \
			'Description=AmneziaWG (userspace) via awg-quick for %i' \
			'After=network-online.target nss-lookup.target' \
			'Wants=network-online.target' \
			'' \
			'[Service]' \
			'Type=oneshot' \
			'RemainAfterExit=yes' \
			"Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=$AWG_BIN_DIR/amneziawg-go" \
			'ExecStart=/usr/bin/awg-quick up %i' \
			'ExecStop=/usr/bin/awg-quick down %i' \
			'' \
			'[Install]' \
			'WantedBy=multi-user.target' >"$unit"
		systemctl daemon-reload 2>/dev/null || true
		log "rendered custom awg-quick@.service (forces userspace amneziawg-go)."
	fi
}

setup_amneziawg() {
	[ "$DO_AMNEZIAWG" -eq 1 ] || { log "AmneziaWG step skipped (--no-amneziawg)."; return 0; }
	log "setting up the userspace AmneziaWG path (amneziawg-go)"
	need_root
	install_awg_tools
	if ! have awg || ! have awg-quick || ! have amneziawg-go; then
		warn "AmneziaWG userspace tools not all present. Build them from source (kernel-independent):"
		warn "  $AWG_GO_REPO        (amneziawg-go: the userspace implementation)"
		warn "  $AWG_TOOLS_REPO     (awg / awg-quick)"
		warn "Install them under $AWG_BIN_DIR and ensure awg-quick@ forces WG_QUICK_USERSPACE_IMPLEMENTATION."
		# Fail-closed (Audit-0004 F-006): AmneziaWG/UDP is the Phase-0 SECOND transport family
		# (ADR-0020 §5). Silently completing with only the REALITY family leaves the node one block away
		# from total loss — the exact failure D2 exists to prevent. Refuse, unless the operator opted out.
		die "AmneziaWG tools missing — refusing to report bootstrap complete with a single transport family. Install the tools above and re-run, or pass --no-amneziawg to deliberately ship a one-family node."
	fi
	# Identity: per-node keypair (+ optional psk). Generated once, kept local.
	local awg_state="$STATE_DIR/awg"
	run install -d -m 0700 "$awg_state"
	if [ ! -f "$awg_state/private.key" ] && [ "$DRY_RUN" -eq 0 ]; then
		( umask 077; awg genkey >"$awg_state/private.key" )
		awg pubkey <"$awg_state/private.key" >"$awg_state/public.key"
		awg genpsk >"$awg_state/preshared.key" 2>/dev/null || true
		log "generated AmneziaWG per-node keypair (local, 0700 dir)."
	fi
	# The actual listen port is an operator/runtime value (PORTS.md canon is 51820/udp). We record it
	# locally so the firewall step can open it; we do not hardcode a port into any committed file.
	[ -f "$STATE_DIR/awg.port" ] || { [ "$DRY_RUN" -eq 0 ] && printf '51820\n' >"$STATE_DIR/awg.port"; }
	# Render awg0.conf ONLY if absent — a live/hand-tuned config is never clobbered. The timer-driven
	# --update path (flow_update) NEVER calls setup_amneziawg (only flow_bootstrap does), so this render
	# cannot fire on an auto-pull; it runs only on an explicit bootstrap of a node whose awg0.conf does
	# not yet exist. Rotation/edits of an existing config are a deliberate manual action.
	local awg_conf_dir="/etc/amnezia/amneziawg" awg_conf
	awg_conf="$awg_conf_dir/awg0.conf"
	run install -d -m 0700 "$awg_conf_dir"
	if [ -f "$awg_conf" ]; then
		log "awg0.conf already present — leaving it untouched (idempotent; never clobber a live config)."
	else
		render_awg0 "$awg_conf"
	fi
	run systemctl enable awg-quick@awg0 2>/dev/null || warn "could not enable awg-quick@awg0."
	if [ "$DRY_RUN" -eq 0 ] && [ -f "$awg_conf" ] && ! systemctl is-active --quiet awg-quick@awg0; then
		run systemctl start awg-quick@awg0 2>/dev/null || true
	fi
	# Fail-closed (Audit-0004 F-006): the second family MUST be active before bootstrap reports success.
	if [ "$DRY_RUN" -eq 0 ] && ! systemctl is-active --quiet awg-quick@awg0; then
		die "awg-quick@awg0 is not active — the AmneziaWG/UDP second family failed to come up. Inspect 'journalctl -u awg-quick@awg0' (is amneziawg-go on PATH and the unit forcing WG_QUICK_USERSPACE_IMPLEMENTATION?). Fix and re-run, or --no-amneziawg to opt out."
	fi
}

# _awg_dialect_lines FILE — count the [Interface] obfuscation lines (Jc/Jmin/Jmax/S1/S2/H1..H4) present in
# FILE. A standard rendered awg config carries exactly 9. Pure read.
_awg_dialect_lines() { grep -cE '^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4) = ' "$1" 2>/dev/null || printf '0'; }

# _awg_swap_dialect FILE — rewrite ONLY the 9 [Interface] obfuscation lines of FILE to the derived AWG_*
# values, leaving every [Peer], key, address and route untouched. Verifies the 9 lines exist BEFORE (a
# non-standard/hand-tuned config is refused, not mangled) and that the rewrite kept exactly 9. Writes in
# place via a temp file so FILE keeps its owner + 0600 mode. Fail-closed.
_awg_swap_dialect() {
	local f="$1" tmp n
	n="$(_awg_dialect_lines "$f")"
	[ "$n" -eq 9 ] || die "awg-regen: $f is not a standard rendered config (expected 9 dialect lines, found $n) — refusing to edit it. Regenerate this node manually."
	tmp="$(mktemp)" || die "awg-regen: mktemp failed."
	sed -E \
		-e "s/^Jc = .*/Jc = $AWG_JC/" \
		-e "s/^Jmin = .*/Jmin = $AWG_JMIN/" \
		-e "s/^Jmax = .*/Jmax = $AWG_JMAX/" \
		-e "s/^S1 = .*/S1 = $AWG_S1/" \
		-e "s/^S2 = .*/S2 = $AWG_S2/" \
		-e "s/^H1 = .*/H1 = $AWG_H1/" \
		-e "s/^H2 = .*/H2 = $AWG_H2/" \
		-e "s/^H3 = .*/H3 = $AWG_H3/" \
		-e "s/^H4 = .*/H4 = $AWG_H4/" \
		"$f" > "$tmp" || { rm -f "$tmp"; die "awg-regen: sed rewrite of $f failed."; }
	n="$(_awg_dialect_lines "$tmp")"
	[ "$n" -eq 9 ] || { rm -f "$tmp"; die "awg-regen: post-swap sanity failed for $f (found $n dialect lines, want 9) — NOT applied."; }
	# Truncate-and-write to preserve FILE's inode metadata (owner + 0600); never mv (would reset perms).
	cat "$tmp" > "$f" || { rm -f "$tmp"; die "awg-regen: could not write $f."; }
	rm -f "$tmp"
}

# regen_awg_dialect — Audit-0008 S1-4 MIGRATION: swap a LIVE node's AmneziaWG obfuscation dialect from the
# old committed network-wide constant to this node's PER-NODE derived dialect (derive_awg_dialect), in
# place, on the live awg0.conf + every rendered client config. SURGICAL: it rewrites ONLY the 9 [Interface]
# obfuscation lines — every server/client keypair, PSK, tunnel address, AllowedIPs and [Peer] is preserved,
# so no client identity changes; each client only needs to re-import its refreshed .conf (same keys, new
# dialect). Backup-first + restore-on-failure (reversible). This is the deliberate manual action the
# renderer's never-clobber design defers to (setup_amneziawg leaves a live awg0.conf untouched). Root-only.
#
# NOTE the migration window: once the SERVER is restarted onto the new dialect, already-deployed clients
# (still on the old dialect) cannot handshake until they import the refreshed client .conf — hand them out
# out-of-band (the paths are logged). Do it one node at a time.
# _awg_epoch_file -> echo the path of the node-local dialect-epoch file. The epoch is the ROTATION counter
# folded into the derivation (see derive_awg_dialect): epoch 0 (the file absent) reproduces the node's
# ORIGINAL per-node dialect, so introducing rotation never disturbs an already-migrated node.
_awg_epoch_file() { printf '%s\n' "$STATE_DIR/awg/dialect.epoch"; }

# _awg_read_epoch -> echo the current rotation epoch as an integer (0 when absent/unreadable/non-numeric).
_awg_read_epoch() {
	local f v
	f="$(_awg_epoch_file)"
	v="$(cat "$f" 2>/dev/null | tr -dc '0-9')"
	[ -n "$v" ] || v=0
	printf '%s\n' "$v"
}

# _awg_apply_dialect EPOCH TAG — the SHARED migrate/rotate machinery: derive this node's dialect AT EPOCH
# from the server PrivateKey carried IN awg0.conf, back up, surgically swap it into the live server config +
# every client config, restart awg0, and L7-verify with a real loopback handshake. Fail-safe: a failed
# bring-up OR a DEAD L7 selftest restores the backup, reverts the epoch file, restarts, and dies — so the
# node never sits on a dialect it cannot serve. TAG ("awg-regen"/"awg-rotate") only labels the log lines.
#
# The key is read from awg0.conf (not $STATE_DIR/awg/private.key): it is the authoritative key the running
# interface uses and is ALWAYS present, whereas the state-dir key exists only on a setup_amneziawg-
# bootstrapped node (a node provisioned another way carries a self-contained awg0.conf). On a
# setup_amneziawg node the two are identical, so the derived dialect matches a fresh render. The key never
# leaves the node.
_awg_apply_dialect() {
	local epoch="$1" tag="$2"
	need_root
	[ "$DO_AMNEZIAWG" -eq 1 ] || die "$tag: AmneziaWG is disabled on this node (--no-amneziawg); nothing to do."
	have awg && have awg-quick || die "$tag: AmneziaWG tools missing — bootstrap the node first."
	local awg_conf="/etc/amnezia/amneziawg/awg0.conf" awg_state="$STATE_DIR/awg"
	[ -f "$awg_conf" ] || die "$tag: no live awg0.conf at $awg_conf — this node has no AmneziaWG (bootstrap it first)."

	local srv_key
	srv_key="$(grep -E '^PrivateKey = ' "$awg_conf" | head -1 | sed -E 's/^PrivateKey = //; s/[[:space:]]*$//')"
	[ -n "$srv_key" ] || die "$tag: could not read the server PrivateKey from $awg_conf — cannot derive the per-node dialect."
	derive_awg_dialect "$srv_key" "$epoch"
	log "$tag: derived per-node dialect (epoch $epoch) H1=$AWG_H1 H2=$AWG_H2 H3=$AWG_H3 H4=$AWG_H4 Jc=$AWG_JC Jmin=$AWG_JMIN Jmax=$AWG_JMAX S1=$AWG_S1 S2=$AWG_S2"

	# Enumerate the client configs to refresh alongside the server config.
	local clients_dir="$awg_state/clients" cfgs=("$awg_conf") c
	if [ -d "$clients_dir" ]; then
		for c in "$clients_dir"/*.conf; do [ -f "$c" ] && cfgs+=("$c"); done
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] $tag would back up + swap the dialect (epoch $epoch) in ${#cfgs[@]} file(s):"
		for c in "${cfgs[@]}"; do log "[dry-run]   $c (dialect lines: $(_awg_dialect_lines "$c"))"; done
		log "[dry-run] then: systemctl restart awg-quick@awg0 + L7 selftest. No changes made."
		return 0
	fi

	# Backup the live server + client configs + the current epoch (fully reversible).
	local stamp bak prev_epoch
	prev_epoch="$(_awg_read_epoch)"
	stamp="$(date +%Y%m%d-%H%M%S)"
	bak="$awg_state/backup-$stamp"
	install -d -m 0700 "$bak" || die "$tag: could not create backup dir $bak."
	cp -a "$awg_conf" "$bak/awg0.conf" || die "$tag: could not back up $awg_conf."
	[ -d "$clients_dir" ] && cp -a "$clients_dir" "$bak/clients"
	printf '%s\n' "$prev_epoch" > "$bak/dialect.epoch" 2>/dev/null || true
	log "$tag: backed up the live awg0.conf + client configs + epoch ($prev_epoch) to $bak"

	# Swap the dialect in every config (server first). Each swap is fail-closed on a non-standard file.
	for c in "${cfgs[@]}"; do _awg_swap_dialect "$c"; done
	log "$tag: swapped the dialect in ${#cfgs[@]} config(s) (peers/keys/addresses untouched)."

	# Persist the new epoch BEFORE bring-up so a crash leaves the epoch matching the on-disk config; the
	# rollback below reverts it in lockstep with the config.
	install -d -m 0700 "$awg_state" 2>/dev/null || true
	printf '%s\n' "$epoch" > "$(_awg_epoch_file)" 2>/dev/null || warn "$tag: could not persist the dialect epoch (a later re-render may re-derive the previous dialect)."

	# _awg_rollback REASON — restore config + epoch, restart, and die (single fail-safe exit).
	_awg_rollback() {
		warn "$tag: $1 — RESTORING the previous config + epoch from $bak."
		cp -a "$bak/awg0.conf" "$awg_conf" 2>/dev/null || true
		[ -d "$bak/clients" ] && cp -a "$bak/clients/." "$clients_dir/" 2>/dev/null || true
		printf '%s\n' "$prev_epoch" > "$(_awg_epoch_file)" 2>/dev/null || true
		systemctl restart awg-quick@awg0 2>/dev/null || true
		die "$tag: FAILED ($1); restored the previous dialect from $bak. Inspect 'journalctl -u awg-quick@awg0'."
	}

	# Apply: restart the interface onto the new dialect.
	if ! systemctl restart awg-quick@awg0 || ! systemctl is-active --quiet awg-quick@awg0; then
		_awg_rollback "awg-quick@awg0 did not come up on the new dialect"
	fi
	log "$tag: awg-quick@awg0 is up on the new per-node dialect (epoch $epoch)."

	# L7 SELFTEST — a real loopback WireGuard handshake against awg0 on the NEW dialect. Fail-closed: a DEAD
	# data-plane rolls back automatically (a dialect the node cannot actually serve is never left live).
	if command -v measure_l7_probe_amneziawg >/dev/null 2>&1; then
		if measure_l7_probe_amneziawg "$STATE_DIR/l7_awg_${tag#awg-}.json"; then
			log "$tag: L7 selftest OK — the data-plane completes handshakes on the new dialect."
		else
			_awg_rollback "the L7 selftest found the data-plane DEAD on the new dialect"
		fi
	else
		warn "$tag: the L7 AmneziaWG probe is unavailable here — applied WITHOUT a handshake selftest."
	fi

	log "$tag: DONE (epoch $epoch). Refresh every AmneziaWG CLIENT with this dialect or it cannot handshake:"
	log "$tag:   Jc = $AWG_JC / Jmin = $AWG_JMIN / Jmax = $AWG_JMAX / S1 = $AWG_S1 / S2 = $AWG_S2"
	log "$tag:   H1 = $AWG_H1 / H2 = $AWG_H2 / H3 = $AWG_H3 / H4 = $AWG_H4"
	log "$tag: node-held client configs (if any): $clients_dir/*.conf ; backup: $bak"
}

regen_awg_dialect() { _awg_apply_dialect "$(_awg_read_epoch)" "awg-regen"; }

# issue_awg_client NAME — issue (or RE-issue) a ready-to-import AmneziaWG CLIENT config on a LIVE node.
# This is the server doing its job: the node mints the client's keypair + PSK, enrols it as a [Peer] in the
# live awg0.conf, and renders a COMPLETE client .conf at the node's CURRENT dialect (epoch-aware) — so an
# operator never hand-edits a client file, and a dialect regen/rotation is followed by simply re-issuing.
#
# Idempotent: an existing NAME reuses its stored keypair/PSK + its already-assigned tunnel address and only
# RE-RENDERS the .conf (the usual path after --awg-regen/--awg-rotate). A new NAME gets the next free
# address in .2–.239 (.240–.254 stays reserved for the L7 probe, matching render_awg0's fail-closed rule).
#
# Selective Growth (VIS-0009/ADR-0027) is honoured exactly as in render_awg0: the client carries only
# impaired-path traffic by default; a deliberate full tunnel needs AWG_FULL_TUNNEL_OPTOUT=1, and a
# region-exclude set comes from AWG_REGION_EXCLUDE_FILE. We never silently full-tunnel.
issue_awg_client() {
	local name="$1"
	need_root
	[ -n "$name" ] || die "awg-issue: a client NAME is required (--awg-issue NAME)."
	case "$name" in *[!A-Za-z0-9._-]*) die "awg-issue: client NAME '$name' has characters outside [A-Za-z0-9._-]." ;; esac
	have awg || die "awg-issue: the awg tools are missing — bootstrap the node first."
	local awg_conf="/etc/amnezia/amneziawg/awg0.conf" awg_state="$STATE_DIR/awg"
	[ -f "$awg_conf" ] || die "awg-issue: no live awg0.conf at $awg_conf (bootstrap the node first)."

	# The node's own dialect at its CURRENT epoch, from the key in the live config (see _awg_apply_dialect).
	local srv_key srv_pub port node_addr has_v6 epoch
	srv_key="$(grep -E '^PrivateKey = ' "$awg_conf" | head -1 | sed -E 's/^PrivateKey = //; s/[[:space:]]*$//')"
	[ -n "$srv_key" ] || die "awg-issue: could not read the server PrivateKey from $awg_conf."
	epoch="$(_awg_read_epoch)"
	derive_awg_dialect "$srv_key" "$epoch"
	# here-string, never a pipe: a pipeline into awg can SIGPIPE under set -o pipefail (RP-0014 lesson).
	srv_pub="$(awg pubkey <<<"$srv_key")" || die "awg-issue: could not derive the server public key."
	port="$(grep -E '^ListenPort = ' "$awg_conf" | head -1 | sed -E 's/^ListenPort = //; s/[[:space:]]*$//')"
	[ -n "$port" ] || port="$(cat "$STATE_DIR/awg.port" 2>/dev/null || echo 51820)"
	node_addr="$(resolve_node_address 2>/dev/null || printf '%s' "$NODE_ADDRESS_PLACEHOLDER")"
	has_v6=0; grep -qE '^Address = .*,' "$awg_conf" && has_v6=1

	local clients_dir="$awg_state/clients"
	install -d -m 0700 "$clients_dir" || die "awg-issue: could not create $clients_dir."

	# Keys: reuse this client's stored material when present (re-issue), else mint it once.
	local cpriv cpub cpsk reissue=0
	[ -f "$clients_dir/$name.private" ] && reissue=1
	[ -f "$clients_dir/$name.private" ] || ( umask 077; awg genkey >"$clients_dir/$name.private" )
	cpriv="$(cat "$clients_dir/$name.private")"
	cpub="$(awg pubkey <<<"$cpriv")" || die "awg-issue: could not derive the client public key."
	[ -f "$clients_dir/$name.psk" ] || ( umask 077; awg genpsk >"$clients_dir/$name.psk" )
	cpsk="$(cat "$clients_dir/$name.psk")"

	# Address: keep this client's existing one (matched by its public key), else take the next free slot.
	local n existing
	existing="$(awk -v pub="$cpub" '
		/^\[Peer\]/{p=""; a=""}
		/^PublicKey = /{p=$3}
		/^AllowedIPs = /{a=$3; if (p==pub) {print a; exit}}' "$awg_conf" 2>/dev/null | head -1)"
	if [ -n "$existing" ]; then
		n="$(printf '%s' "$existing" | sed -E 's#^[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)/.*#\1#')"
	else
		n=2
		while grep -qE "^AllowedIPs = ${AWG_PEER_BASE_V4//./\\.}\.$n/32" "$awg_conf"; do n=$(( n + 1 )); done
	fi
	[ "$n" -lt 240 ] || die "awg-issue: no free client address (.2–.239 exhausted; .240–.254 is reserved for the L7 probe)."

	local cv6=""
	if [ "$has_v6" -eq 1 ]; then cv6=", ${AWG_PEER_BASE_V6}${n}/128"; fi

	# Selective Growth: the same policy render_awg0 applies — never a silent full tunnel.
	local client_allowed
	compute_client_allowed "$has_v6" || die "awg-issue: client AllowedIPs unresolved — set AWG_FULL_TUNNEL_OPTOUT=1 to deliberately full-tunnel, or supply AWG_REGION_EXCLUDE_FILE."
	client_allowed="$(sg_allowed_join)"

	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] awg-issue would $( [ "$reissue" -eq 1 ] && printf 're-issue' || printf 'issue' ) client '$name' at ${AWG_PEER_BASE_V4}.$n (dialect epoch $epoch) -> $clients_dir/$name.conf"
		[ -n "$existing" ] || log "[dry-run]   and enrol a new [Peer] in $awg_conf"
		return 0
	fi

	# Enrol the peer when it is not already in the live config (re-issue leaves the server config untouched).
	# The pre-enrolment backup lives in the state dir (like the regen/rotate backups) and is REAL: if the
	# interface will not come back up with the new peer, we restore it rather than leave the live config
	# mutated behind a warning.
	local enrol_bak="$awg_state/awg0.pre-issue.conf"
	if [ -z "$existing" ]; then
		cp -a "$awg_conf" "$enrol_bak" 2>/dev/null || die "awg-issue: could not back up $awg_conf before enrolling the peer."
		{
			printf '\n[Peer]\n# name = %s\n' "$name"
			printf 'PublicKey = %s\n' "$cpub"
			printf 'PresharedKey = %s\n' "$cpsk"
			printf 'AllowedIPs = %s.%s/32%s\n' "$AWG_PEER_BASE_V4" "$n" "$cv6"
		} >> "$awg_conf" || die "awg-issue: could not append the [Peer] to $awg_conf."
		log "awg-issue: enrolled '$name' as a new peer at ${AWG_PEER_BASE_V4}.$n"
	else
		log "awg-issue: '$name' is already a peer at ${AWG_PEER_BASE_V4}.$n — re-rendering its config only."
	fi

	# Render the COMPLETE client config at the node's current dialect.
	( umask 077; render_awg_client_conf "$cpriv" "$n" "$has_v6" "$srv_pub" "$cpsk" \
		"$node_addr:$port" "$client_allowed" "$SG_MARKER" > "$clients_dir/$name.conf" ) \
		|| die "awg-issue: could not write $clients_dir/$name.conf."
	chmod 0600 "$clients_dir/$name.conf"

	# Apply the peer change to the running interface, then L7-verify the data-plane.
	if [ -z "$existing" ]; then
		if ! systemctl restart awg-quick@awg0 2>/dev/null || ! systemctl is-active --quiet awg-quick@awg0; then
			warn "awg-issue: awg0 did not come back up with the new peer — RESTORING the pre-enrolment config."
			cp -a "$enrol_bak" "$awg_conf" 2>/dev/null || true
			rm -f "$clients_dir/$name.conf" 2>/dev/null || true
			systemctl restart awg-quick@awg0 2>/dev/null || true
			die "awg-issue: FAILED to enrol '$name' (awg0 would not come up); restored the previous config. Inspect 'journalctl -u awg-quick@awg0'."
		fi
		rm -f "$enrol_bak" 2>/dev/null || true
	fi
	if command -v measure_l7_probe_amneziawg >/dev/null 2>&1; then
		measure_l7_probe_amneziawg "$STATE_DIR/l7_awg_issue.json" \
			&& log "awg-issue: L7 selftest OK — the data-plane completes handshakes." \
			|| warn "awg-issue: the L7 selftest flagged the data-plane DEAD — inspect 'journalctl -u awg-quick@awg0'."
	fi
	local route_mode="split-tunnel (safe narrow)"
	case "$client_allowed" in
		*0.0.0.0/0*) route_mode="FULL TUNNEL (deliberate opt-out)" ;;
		*) [ -n "$AWG_REGION_EXCLUDE_FILE" ] && route_mode="split-tunnel (region-exclude list)" ;;
	esac
	log "awg-issue: client '$name' ready (dialect epoch $epoch, routes: $route_mode): $clients_dir/$name.conf"
	log "awg-issue:   AllowedIPs = $client_allowed"
	log "awg-issue: hand it over out-of-band; it is a complete ready-to-import config (0600, node-local)."
}

# _awg_strip_peers FILE PUBKEYS... — rewrite FILE without the [Peer] blocks whose PublicKey is listed.
# Pure text surgery on a copy; the caller validates and promotes. Blocks are matched on the KEY, never on
# position, so a hand-edited or reordered conf is handled the same way.
_awg_strip_peers() {
	local file="$1"; shift
	local kill="$*"
	# SEPARATOR HANDLING IS THE WHOLE DIFFICULTY. A blank line between sections belongs to neither, but a
	# naive reader captures it into the PRECEDING block and then re-adds one when emitting — so every pass
	# grows the file by one blank per surviving peer, without bound. That is not hypothetical: five no-op
	# passes over a live 31-line conf produced 41 lines, and a shipped revoke had already left five blank
	# lines in a two-peer file. A no-op strip MUST be byte-identical to its input, or "idempotent" is a
	# word rather than a property. So: trailing blanks are trimmed off every section and exactly one
	# separator is re-emitted before each kept block.
	#
	# The PublicKey match is normalised too — `PublicKey=KEY` with no spaces is legal config syntax, and a
	# rule anchored on "PublicKey = " silently fails to see such a peer, which here means failing to
	# revoke it while reporting success.
	awk -v kill="$kill" '
		function emit(b) { sub(/\n+$/, "\n", b); printf "\n%s", b }
		function flush_pre() { sub(/\n+$/, "\n", pre); printf "%s", pre; pre="" }
		BEGIN { n=split(kill, K, " "); for (i=1;i<=n;i++) if (K[i] != "") kills[K[i]]=1 }
		/^[[:space:]]*\[Peer\][[:space:]]*$/ {
			if (inpeer) { if (!(pub in kills)) emit(buf) } else flush_pre()
			inpeer=1; buf=$0 "\n"; pub=""; next
		}
		inpeer {
			buf = buf $0 "\n"
			if ($0 ~ /^[[:space:]]*PublicKey[[:space:]]*=/) {
				v=$0; sub(/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); pub=v
			}
			next
		}
		{ pre = pre $0 "\n" }
		END { if (inpeer) { if (!(pub in kills)) emit(buf) } else flush_pre() }
	' "$file"
}

# revoke_awg_client NAME — REVOKE an AmneziaWG client: the credential stops working immediately and does
# not come back.
#
# WHY THIS EXISTS. The node could issue AmneziaWG clients and had no way to un-issue one. Every peer ever
# enrolled stayed valid forever, and there was no sanctioned way to retire a leaked or superseded key —
# on a live node the only recourse was hand-editing awg0.conf, which is exactly the operation most likely
# to leave the interface unable to come up.
#
# ORDER IS THE DESIGN. The live interface is cleared FIRST, with `awg set ... peer ... remove`: after that
# single call the key cannot complete a handshake, even if every later step fails. Only then are files
# touched. The reverse order would leave a window in which the operator has been told "revoked" while the
# credential still works until the next restart.
#
# NO RESTART. Enrolment restarts awg-quick@awg0, which drops every other peer's session. A revoke has no
# need to: the live removal is immediate and the conf edit only has to survive the NEXT start.
#
# IT RESOLVES THE PEER TWO WAYS, and this is not belt-and-braces:
#   * by the public key derived from the stored private key — the normal case; and
#   * by the "# name = NAME" marker in awg0.conf — because --awg-issue keys "is this a re-issue?" on the
#     presence of clients/NAME.private, so a name whose key material was lost gets a SECOND peer enrolled
#     at a new address under the same name. That state is reachable in practice (it was hit on a live
#     node), and a revoke that only knew about the stored key would leave the other peer valid forever.
# Every matching peer is removed, and a name with nothing to remove is a success, not an error.
#
# IT ALSO PURGES THE BACKUPS. _awg_rollback restores BOTH awg0.conf and clients/ from $STATE_DIR/awg/
# backup-*/ when a dialect regen/rotate fails. A backup taken before the revoke would therefore resurrect
# the peer AND its private key on the next failed rotation. Revoked has to mean revoked.
revoke_awg_client() {
	local name="$1"
	need_root
	[ -n "$name" ] || die "awg-revoke: a client NAME is required (--awg-revoke NAME)."
	case "$name" in *[!A-Za-z0-9._-]*) die "awg-revoke: client NAME '$name' has characters outside [A-Za-z0-9._-]." ;; esac
	have awg || die "awg-revoke: the awg tools are missing — bootstrap the node first."
	# The default is the live path, unchanged; the override exists so the conformance gate can EXECUTE
	# this function against a throwaway node root instead of asserting its source text. A revoke that is
	# only read, never run, is exactly the kind of code that fails the first time an operator needs it.
	local awg_conf="${MYC_AWG_CONF:-/etc/amnezia/amneziawg/awg0.conf}" awg_state="$STATE_DIR/awg"
	local clients_dir="$awg_state/clients"
	[ -f "$awg_conf" ] || die "awg-revoke: no live awg0.conf at $awg_conf (bootstrap the node first)."

	# --- resolve every peer this name owns -----------------------------------------------------------
	local pubs="" p
	if [ -f "$clients_dir/$name.private" ]; then
		p="$(awg pubkey <<<"$(cat "$clients_dir/$name.private")" 2>/dev/null || true)"
		[ -n "$p" ] && pubs="$p"
	fi
	# Any block carrying this name's marker, whatever key it holds.
	# Evaluate each block AS A WHOLE: the marker may follow the key, and the key may be written without
	# spaces. Deciding at the PublicKey line only sees a marker that happens to precede it.
	local by_name
	by_name="$(awk -v want="$name" '
		function flush() { if (nm == want && pk != "") print pk; nm=""; pk="" }
		/^[[:space:]]*\[Peer\][[:space:]]*$/ { flush(); next }
		/^[[:space:]]*#[[:space:]]*name[[:space:]]*=/ { v=$0; sub(/^[[:space:]]*#[[:space:]]*name[[:space:]]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); nm=v; next }
		/^[[:space:]]*PublicKey[[:space:]]*=/ { v=$0; sub(/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); pk=v; next }
		END { flush() }' "$awg_conf" 2>/dev/null)"
	for p in $by_name; do
		case " $pubs " in *" $p "*) ;; *) pubs="${pubs:+$pubs }$p" ;; esac
	done

	local n_peers=0
	for p in $pubs; do n_peers=$(( n_peers + 1 )); done

	if [ "$n_peers" -eq 0 ] && [ ! -f "$clients_dir/$name.private" ] && [ ! -f "$clients_dir/$name.conf" ]; then
		log "awg-revoke: '$name' has no peer in $awg_conf and no stored material — nothing to revoke (already clean)."
		return 0
	fi
	# A peer with no "# name =" marker cannot be reached by NAME at all. On a live node one such peer
	# existed, holding a key whose private half was still on the same host — a by-name revoke would have
	# removed the OTHER peer and reported success. Count them; they gate the closing guarantee below.
	local unnamed
	unnamed="$(awk '
		function flush() { if (started && !named && pk != "") print pk; named=0; pk="" }
		/^[[:space:]]*\[Peer\][[:space:]]*$/ { flush(); started=1; next }
		/^[[:space:]]*#[[:space:]]*name[[:space:]]*=/ { named=1; next }
		/^[[:space:]]*PublicKey[[:space:]]*=/ { v=$0; sub(/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); pk=v; next }
		END { flush() }' "$awg_conf" 2>/dev/null)"
	[ "$n_peers" -le 1 ] || warn "awg-revoke: '$name' owns $n_peers peers — removing ALL of them. (--awg-issue enrols a second peer under the same name when the stored key material is missing; this is that state.)"

	if [ "${DRY_RUN:-0}" -eq 1 ]; then
		log "[dry-run] awg-revoke would remove $n_peers peer(s) for '$name' from the live interface and $awg_conf, and shred $clients_dir/$name.{private,psk,conf}"
		return 0
	fi

	# --- 1. the live interface FIRST: the credential dies here ----------------------------------------
	local removed_live=0 still_live=""
	for p in $pubs; do
		awg set awg0 peer "$p" remove 2>/dev/null && removed_live=$(( removed_live + 1 ))
	done
	# ASSERT it, do not assume it. The previous form counted successes and downgraded every failure to a
	# warning whose own text pre-excused it ("it may already be absent") — after which the closing
	# guarantee printed regardless, including when nothing at all had been removed. Read the interface
	# back instead: if the key is still listed while awg0 is up, the credential still works.
	if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
		local live_keys
		live_keys="$(awg show awg0 peers 2>/dev/null || true)"
		for p in $pubs; do
			printf '%s\n' "$live_keys" | grep -qxF "$p" && still_live="${still_live:+$still_live }$p"
		done
	fi
	[ -z "$still_live" ] \
		|| die "awg-revoke: a peer is STILL on the running awg0 interface after the remove call — the credential continues to work RIGHT NOW. Nothing on disk was touched. Investigate before retrying."
	[ "$removed_live" -eq 0 ] || log "awg-revoke: removed $removed_live peer(s) for '$name' from the RUNNING interface — the key can no longer complete a handshake."

	# --- 2. the on-disk config, validated before it is promoted ---------------------------------------
	if [ "$n_peers" -gt 0 ]; then
		install -d -m 0700 "$awg_state" 2>/dev/null || true
		local bak="$awg_state/awg0.pre-revoke.conf" tmp="$awg_conf.revoke.$$"
		cp -a "$awg_conf" "$bak" || die "awg-revoke: could not back up $awg_conf before editing."
		_awg_strip_peers "$awg_conf" $pubs > "$tmp" || { rm -f "$tmp"; die "awg-revoke: could not rewrite $awg_conf."; }
		# Fail-closed sanity: the result must still be a usable server config, and must no longer name the
		# revoked keys. A truncated or mangled file here means no AmneziaWG at all after the next restart.
		local ok=1
		grep -q '^\[Interface\]'  "$tmp" || ok=0
		grep -q '^PrivateKey = '  "$tmp" || ok=0
		grep -q '^ListenPort = '  "$tmp" || ok=0
		# ANCHORED, not a substring search: one key can contain another as a prefix, and a substring
		# match then reports a key as "still present" when it is not — aborting a revoke that in fact
		# succeeded. (Caught by mutation-testing the gate: the duplicate-peer fixture has keys where one
		# is a prefix of the other, and the revoke died on its own sanity check.)
		for p in $pubs; do grep -qE "^PublicKey = ${p}[[:space:]]*$" "$tmp" && ok=0; done
		if [ "$ok" -ne 1 ]; then
			rm -f "$tmp"
			die "awg-revoke: the rewritten $awg_conf failed its sanity check — NOTHING was changed on disk (the peer is already off the running interface). Backup kept at $bak."
		fi
		chmod 0600 "$tmp"; mv -f "$tmp" "$awg_conf" || die "awg-revoke: could not promote the rewritten $awg_conf (backup at $bak)."
		log "awg-revoke: removed $n_peers [Peer] block(s) for '$name' from $awg_conf (backup: $bak)."
	fi

	# --- 3. the stored client material ----------------------------------------------------------------
	local f gone=0
	for f in "$clients_dir/$name.private" "$clients_dir/$name.psk" "$clients_dir/$name.conf"; do
		[ -e "$f" ] || continue
		rm -f "$f" && gone=$(( gone + 1 ))
	done
	[ "$gone" -eq 0 ] || log "awg-revoke: deleted $gone stored client file(s) for '$name'."

	# --- 4. the backups, or a failed dialect rollback resurrects both peer and key --------------------
	local b purged=0
	for b in "$awg_state"/backup-*; do
		[ -d "$b" ] || continue
		for f in "$b/clients/$name.private" "$b/clients/$name.psk" "$b/clients/$name.conf"; do
			[ -e "$f" ] && { rm -f "$f"; purged=$(( purged + 1 )); }
		done
		if [ -f "$b/awg0.conf" ] && [ "$n_peers" -gt 0 ]; then
			local btmp="$b/awg0.conf.revoke.$$"
			if _awg_strip_peers "$b/awg0.conf" $pubs > "$btmp" 2>/dev/null && grep -q '^\[Interface\]' "$btmp"; then
				# Only promote a backup that actually CHANGED. Rewriting an untouched restore source
				# churns its mtime and hides which backups a revoke really reached.
				if cmp -s "$btmp" "$b/awg0.conf"; then rm -f "$btmp"; else
				chmod 0600 "$btmp"; mv -f "$btmp" "$b/awg0.conf"; purged=$(( purged + 1 )); fi
			else
				rm -f "$btmp"
				warn "awg-revoke: could not strip '$name' from $b/awg0.conf — a dialect ROLLBACK from that backup would re-enrol this peer. Remove the backup by hand."
			fi
		fi
	done
	[ "$purged" -eq 0 ] || log "awg-revoke: purged $purged backup artefact(s) so a dialect rollback cannot resurrect '$name'."

	# The verb's own pre-revoke snapshot holds the server PrivateKey and every peer block. --awg-issue
	# deletes its equivalent on success; this one used to keep it forever. Remove it once the rewrite is
	# promoted and verified.
	rm -f "$awg_state/awg0.pre-revoke.conf" 2>/dev/null || true

	# THE GUARANTEE IS EARNED, NOT PRINTED. An unnamed [Peer] cannot be reached by name, so on a config
	# that has one, "revoked" would be a claim about peers this call never even saw. Say what is true and
	# hand over the command that finishes the job.
	if [ -n "$unnamed" ]; then
		warn "awg-revoke: this config contains [Peer] block(s) with NO '# name =' marker, which a by-name revoke cannot reach. What was found under the name '$name' has been removed, but the following peer(s) remain and may belong to it:"
		for p in $unnamed; do warn "awg-revoke:   $p"; done
		warn "awg-revoke: finish with:  $0 --awg-revoke-peer <PUBKEY>   (per peer)"
		printf '%s\n' $unnamed > "$STATE_DIR/awg/REVOKE_INCOMPLETE" 2>/dev/null || true
		return 1
	fi
	rm -f "$STATE_DIR/awg/REVOKE_INCOMPLETE" 2>/dev/null || true
	log "awg-revoke: '$name' is revoked. Its key cannot handshake now and will not be re-admitted on restart."
	log "awg-revoke: the client's own copy of the config is NOT recallable — treat the address ${AWG_PEER_BASE_V4:-10.13.13}.x it held as reusable only after you are content the holder is retired."
}

# revoke_awg_peer PUBKEY — revoke ONE peer by its public key, whatever it is called.
#
# This is the only way to reach a [Peer] with no "# name =" marker, and such blocks exist on real nodes:
# one was found holding a key whose private half was still stored on the same host. revoke_awg_client
# cannot see it — neither the stored-key path nor the name-marker path matches — so without this verb the
# operator's only recourse is hand-editing awg0.conf, which is the operation this whole file exists to
# avoid. Same order as the by-name form: the running interface first, then the config, then the backups.
# There is no client material to delete, because a peer with no name has no clients/ entry to find.
revoke_awg_peer() {
	local pub="$1"
	need_root
	[ -n "$pub" ] || die "awg-revoke-peer: a PUBKEY is required (--awg-revoke-peer PUBKEY)."
	case "$pub" in *[!A-Za-z0-9+/=]*) die "awg-revoke-peer: '$pub' is not a base64 public key." ;; esac
	have awg || die "awg-revoke-peer: the awg tools are missing — bootstrap the node first."
	local awg_conf="${MYC_AWG_CONF:-/etc/amnezia/amneziawg/awg0.conf}" awg_state="$STATE_DIR/awg"
	[ -f "$awg_conf" ] || die "awg-revoke-peer: no live awg0.conf at $awg_conf."

	local in_conf=0
	grep -qE "^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*${pub}[[:space:]]*$" "$awg_conf" && in_conf=1
	if [ "$in_conf" -eq 0 ]; then
		log "awg-revoke-peer: $pub is not a peer in $awg_conf — nothing to revoke (already clean)."
		return 0
	fi
	if [ "${DRY_RUN:-0}" -eq 1 ]; then
		log "[dry-run] awg-revoke-peer would remove $pub from the live interface, $awg_conf and the dialect backups."
		return 0
	fi

	awg set awg0 peer "$pub" remove 2>/dev/null || true
	if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
		awg show awg0 peers 2>/dev/null | grep -qxF "$pub" \
			&& die "awg-revoke-peer: $pub is STILL on the running interface after the remove call — the credential works RIGHT NOW and nothing on disk was touched."
	fi
	log "awg-revoke-peer: removed $pub from the RUNNING interface."

	install -d -m 0700 "$awg_state" 2>/dev/null || true
	local bak="$awg_state/awg0.pre-revoke.conf" tmp="$awg_conf.revoke.$$"
	cp -a "$awg_conf" "$bak" || die "awg-revoke-peer: could not back up $awg_conf."
	_awg_strip_peers "$awg_conf" "$pub" > "$tmp" || { rm -f "$tmp"; die "awg-revoke-peer: could not rewrite $awg_conf."; }
	local ok=1
	grep -q '^\[Interface\]' "$tmp" || ok=0
	grep -q '^PrivateKey = ' "$tmp" || ok=0
	grep -q '^ListenPort = ' "$tmp" || ok=0
	grep -qE "^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*${pub}[[:space:]]*$" "$tmp" && ok=0
	[ "$ok" -eq 1 ] || { rm -f "$tmp"; die "awg-revoke-peer: the rewritten $awg_conf failed its sanity check — nothing promoted (the peer is already off the running interface, but it WILL be re-admitted on the next start until this is resolved). Backup: $bak"; }
	chmod 0600 "$tmp"; mv -f "$tmp" "$awg_conf" || die "awg-revoke-peer: could not promote the rewritten $awg_conf (backup: $bak)."
	log "awg-revoke-peer: removed the [Peer] block from $awg_conf."

	local b btmp purged=0
	for b in "$awg_state"/backup-*; do
		[ -d "$b" ] && [ -f "$b/awg0.conf" ] || continue
		btmp="$b/awg0.conf.revoke.$$"
		if _awg_strip_peers "$b/awg0.conf" "$pub" > "$btmp" 2>/dev/null && grep -q '^\[Interface\]' "$btmp"; then
			if cmp -s "$btmp" "$b/awg0.conf"; then rm -f "$btmp"; else
				chmod 0600 "$btmp"; mv -f "$btmp" "$b/awg0.conf"; purged=$(( purged + 1 )); fi
		else
			rm -f "$btmp"
			warn "awg-revoke-peer: could not strip $pub from $b/awg0.conf — a dialect ROLLBACK from that backup would re-enrol it."
		fi
	done
	[ "$purged" -eq 0 ] || log "awg-revoke-peer: purged $purged backup copy(ies)."
	rm -f "$awg_state/awg0.pre-revoke.conf" 2>/dev/null || true
	log "awg-revoke-peer: $pub is revoked."
}

# rotate_awg_dialect — ROTATE this node's AmneziaWG dialect to a FRESH one: bump the rotation epoch and
# re-derive, so the node moves to a completely different H1..H4 + jitter WITHOUT touching any key or peer.
# Unlike --awg-regen (idempotent: it re-derives the CURRENT epoch, used to migrate a node onto its per-node
# dialect), this deliberately changes the on-the-wire dialect — the response to "this node's dialect became
# known/blocked." Fail-closed via the shared machinery: a failed bring-up or a DEAD L7 selftest rolls the
# config AND the epoch back. Every client must be refreshed with the new dialect (logged).
rotate_awg_dialect() {
	local cur next
	cur="$(_awg_read_epoch)"
	next=$(( cur + 1 ))
	log "awg-rotate: rotating the AmneziaWG dialect (epoch $cur -> $next); keys, peers and addresses are untouched."
	_awg_apply_dialect "$next" "awg-rotate"
}
