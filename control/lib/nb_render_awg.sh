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

# AmneziaWG canonical "dialect": the in-tunnel addressing + obfuscation knobs shared network-wide. Every
# peer (server + all its clients) MUST share Jc/Jmin/Jmax/S1/S2/H1..H4 or the handshake fails. These
# are TUNABLE, NOT secret — and are the SAME values as infra/ansible/roles/amneziawg/defaults/main.yml
# (a node + its clients are one dialect). The render below uses them ONLY when first creating a node's
# awg0.conf; an existing awg0.conf is never overwritten.
AWG_TUNNEL_V4="10.13.13.1/24"      # server in-tunnel v4 (RFC1918); peers get .2, .3, …
AWG_TUNNEL_V6="fd13:13:13::1/64"   # server in-tunnel v6 (RFC4193 ULA); used only if the node has global v6
AWG_PEER_BASE_V4="10.13.13"
AWG_PEER_BASE_V6="fd13:13:13::"
AWG_MTU="1280"
AWG_JC="4"; AWG_JMIN="40"; AWG_JMAX="70"; AWG_S1="51"; AWG_S2="102"
AWG_H1="1148403838"; AWG_H2="1351874800"; AWG_H3="1936608092"; AWG_H4="1830553362"

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
	local n=2 name cpub cpriv cpsk cv6 client_allowed client_dns
	for name in $CLIENT_NAMES; do
		[ -f "$clients_dir/$name.private" ] || ( umask 077; awg genkey >"$clients_dir/$name.private" )
		cpriv="$(cat "$clients_dir/$name.private")"
		cpub="$(awg pubkey <"$clients_dir/$name.private")"
		[ -f "$clients_dir/$name.psk" ] || ( umask 077; awg genpsk >"$clients_dir/$name.psk" )
		cpsk="$(cat "$clients_dir/$name.psk")"
		if [ "$has_v6" -eq 1 ]; then
			cv6=", ${AWG_PEER_BASE_V6}${n}/128"; client_dns="1.1.1.1, 2606:4700:4700::1111"
		else
			cv6=""; client_dns="1.1.1.1"
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
		( umask 077; {
			printf '[Interface]\n'
			printf 'PrivateKey = %s\n' "$cpriv"
			printf 'Address = %s.%s/32%s\n' "$AWG_PEER_BASE_V4" "$n" "$cv6"
			printf 'DNS = %s\n' "$client_dns"
			printf 'MTU = %s\n' "$AWG_MTU"
			printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2"
			printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
			printf '\n[Peer]\n'
			printf 'PublicKey = %s\n' "$spub"
			printf 'PresharedKey = %s\n' "$cpsk"
			printf 'Endpoint = %s:%s\n' "$node_addr" "$port"
			[ -n "$SG_MARKER" ] && printf '%s\n' "$SG_MARKER"
			printf 'AllowedIPs = %s\n' "$client_allowed"
			printf 'PersistentKeepalive = 25\n'
		} > "$clients_dir/$name.conf" )
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
# No upstream prebuilt amneziawg-go release exists, so this builds from source (apt golang-go +
# build-essential). Idempotent: a no-op when awg/awg-quick/amneziawg-go are already present. Also renders
# the custom awg-quick@.service that forces the userspace implementation (the kernel module is not used).
# flow_bootstrap-only (called from setup_amneziawg, which the timer never runs).
install_awg_tools() {
	if have awg && have awg-quick && have amneziawg-go; then
		log "AmneziaWG userspace tools already present; skipping build."
		return 0
	fi
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] would apt-get install golang-go build-essential, build amneziawg-go $AWG_GO_TAG + amneziawg-tools $AWG_TOOLS_TAG from source, install them, and render the userspace awg-quick@ unit."
		return 0
	fi
	have apt-get || die "AmneziaWG tools absent and no apt-get to bootstrap the build toolchain — install golang-go + build-essential + the awg tools by hand, or pass --no-amneziawg."
	log "building AmneziaWG userspace tools from pinned source (amneziawg-go $AWG_GO_TAG, amneziawg-tools $AWG_TOOLS_TAG)"
	env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go build-essential || die "failed to install golang-go + build-essential for the AmneziaWG build."
	local build; build="$(mktemp -d)" || die "mktemp failed for the AmneziaWG build."
	if ! have amneziawg-go; then
		git clone --depth 1 -b "$AWG_GO_TAG" "$AWG_GO_REPO" "$build/awg-go" || die "amneziawg-go clone ($AWG_GO_TAG) failed."
		( cd "$build/awg-go" && go build -trimpath -o amneziawg-go . ) || die "amneziawg-go build failed (check the Go toolchain)."
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
