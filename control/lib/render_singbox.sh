# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render_singbox.sh — render the multi-protocol sing-box SERVER config by jq path,
# and emit per-client sing-box / Clash-Meta subscriptions for the enabled protocols.
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl. Depends on common.sh, jqlib.sh, identity.sh.
#
# sing-box is the PRIMARY engine for the Mycelium node: ONE server process speaks
# many protocols (VLESS+REALITY with Vision/gRPC/XHTTP, Hysteria2, TUIC v5,
# Shadowsocks-2022, ShadowTLS v3, Trojan). Each protocol is individually toggleable
# via the params file so an operator exposes only a chosen subset. The legacy Xray
# engine (render.sh) is left untouched and remains available via --engine xray.
#
# As with the Xray path, NO secret material is invented here. REALITY keys / shortIds
# come from `sing-box generate reality-keypair` or `xray x25519` + `openssl rand`;
# protocol passwords come from `sing-box generate rand` / `openssl rand`; UUIDs come
# from `sing-box generate uuid` / `xray uuid`. This file only places those values by
# jq path. See docs/adr/0002-no-custom-cryptography.md.
#
# Pinned engine: sing-box >= v1.11.x (record the exact deployed tag at deploy time).

# ---------------------------------------------------------------------------
# Protocol registry
# ---------------------------------------------------------------------------
#
# The canonical, priority-ordered list of protocols this engine understands. Priority order doubles as
# the failover preference for the client selector: REALITY/TCP (most survivable) first, UDP/QUIC paths
# next, then SS/ShadowTLS, Trojan last. Each token is matched against an inbound's `tag` in the template
# and against a `<token>_enabled` flag in params.
#
# The list is the Go-owned registry (control/vocab.json, minus the standalone amneziawg dataplane), read
# through the shared vocab accessor (RP-0008 P2) — never a hand-maintained copy. It spans the FULL
# servable registry (both the sing-box and Xray engines) because it is also the source for the BUNDLE,
# which advertises every node endpoint regardless of engine. The sing-box SERVER + SUBSCRIPTION render
# intersect their enabled set with the sing-box-engine protos via myc_sb_singbox_only (below) so an
# enabled xray-only proto (vless-xhttp-tls) is delegated to the Xray engine, not fatally rendered into a
# sing-box config (ADR-0032 dual-engine). vocab.sh is sourced before this lib, resolved once at source time.
MYC_SB_PROTOS="$(myc_vocab_protos)"

# myc_sb_singbox_only LIST -> LIST with the xray-engine protos removed (keep only what the sing-box engine
# can actually serve/dial). Used by the sing-box server + subscription render to drop e.g. vless-xhttp-tls
# (the xhttp transport is Xray-core only) while the BUNDLE keeps the full list. (ADR-0032 dual-engine.)
myc_sb_singbox_only() {
	local sb_set keep="" p
	sb_set=" $(myc_vocab_protos_singbox) "
	for p in $1; do
		case "$sb_set" in *" $p "*) keep="$keep $p" ;; esac
	done
	printf '%s' "${keep# }"
}

# ---------------------------------------------------------------------------
# urltest anti-flapping calibration (C22)
# ---------------------------------------------------------------------------
# The client `urltest` outbound (subscription + aggregate) auto-selects the lowest-latency endpoint. With
# a tight tolerance and a short interval it THRASHES between near-equal endpoints on ordinary jitter, and
# auto-rotation that flaps becomes its own blocking signal (THREAT-MODEL §6.1.6/§6.1.8). sing-box urltest
# supports three hysteresis knobs; we set all three to anti-flap defaults (single source of truth, used by
# BOTH the subscription render below and render_aggregate.sh):
#   * interval (5m): how often urltest re-probes. Wider than the old 3m so transient jitter between probes
#     does not drive a switch; still responsive enough to notice a genuinely dead endpoint within minutes.
#   * tolerance (150ms): the NEW endpoint must beat the current one by >150ms before urltest switches.
#     Widened from 50ms (which flips on sub-perceptible latency noise) into the audit's 100-200ms band, so
#     two endpoints within ~150ms of each other are treated as equivalent and the client stays put.
#   * idle_timeout (30m): how long an unused endpoint's last result is trusted before a forced re-probe.
#     Set well above the interval so a momentarily idle endpoint is not re-ranked on stale data.
# Calibration rationale lives here so a future change is a single, reviewed edit.
MYC_URLTEST_INTERVAL="5m"
MYC_URLTEST_TOLERANCE=150
MYC_URLTEST_IDLE_TIMEOUT="30m"

# myc_sb_proto_enabled PARAMS_JSON PROTO -> 0 if enabled, 1 otherwise.
# A protocol is enabled when params.<proto>_enabled is exactly true. The dash in a
# token maps to an underscore in the params flag name (jq keys avoid dashes here).
myc_sb_proto_enabled() {
	local json proto flag
	json="$1"; proto="$2"
	flag="$(printf '%s' "$proto" | tr '-' '_')_enabled"
	[ "$(printf '%s' "$json" | jq -r --arg f "$flag" '.[$f] // false')" = "true" ]
}

# myc_sb_enabled_list PARAMS_JSON -> space-separated enabled protocols in priority order.
myc_sb_enabled_list() {
	local json out p
	json="$1"; out=""
	for p in $MYC_SB_PROTOS; do
		if myc_sb_proto_enabled "$json" "$p"; then
			out="$out $p"
		fi
	done
	printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
# render-server (sing-box engine)
# ---------------------------------------------------------------------------
#
# Fills the sentinels in the sing-box template BY JQ PATH and keeps only the
# inbounds whose protocol is enabled in params. Inbounds are located by their
# `tag` (robust to ordering), never by numeric index. Every dynamic value flows
# through --arg/--argjson — nothing is string-spliced into the filter.
#
# Sentinels filled (per matching inbound):
#   tls.reality.private_key                <- reality_private_key
#   tls.reality.short_id[]                  <- short_ids[]
#   tls.reality.handshake.server           <- donor_host
#   tls.server_name / tls.reality.server_name? -> server_name = donor_sni (reality)
#   tls.server_name (h2/quic protocols)    <- tls_sni
#   listen_port                             <- <proto>_port (per protocol)
#   shadowsocks .password                   <- ss_password
#   trojan users[].password                 <- trojan_password
#   transport.service_name (grpc)           <- grpc_service_name
#   transport.path (xhttp)                  <- xhttp_path
#   shadowtls.handshake.server              <- shadowtls_handshake_server (default donor_host)
#   users[]                                 <- from identity state, per-protocol shape
#
# myc_sb_render_server TEMPLATE PARAMS_FILE STATE OUT
myc_sb_render_server() {
	local template params_file state out
	template="$1"; params_file="$2"; state="$3"; out="$4"

	[ -n "$template" ]    || myc_die "render-server: --template is required"
	[ -n "$params_file" ] || myc_die "render-server: --params is required"
	[ -n "$state" ]       || myc_die "render-server: --state is required"
	[ -n "$out" ]         || myc_die "render-server: --out is required"

	myc_assert_json "$template" "sing-box template"

	local params clients
	params="$(myc_params_to_json "$params_file")"
	myc_state_init "$state"
	clients="$(myc_identity_clients_json "$state")"

	if [ "$(printf '%s' "$clients" | jq 'length')" -eq 0 ]; then
		myc_warn "render-server: identity state has zero clients; inbounds will accept no one"
	fi

	# Which protocols did the operator turn on?
	local enabled
	enabled="$(myc_sb_enabled_list "$params")"
	[ -n "$enabled" ] || myc_die "render-server: no protocols enabled in params (set at least one <proto>_enabled: true)"
	# Drop xray-engine protos (e.g. vless-xhttp-tls): the sing-box engine cannot serve them — the Xray
	# engine does (ADR-0032). The enabled set spans the full registry (shared with the bundle); the
	# sing-box SERVER render keeps only its own engine's protos here, so enabling vless-xhttp-tls renders
	# the sing-box config for its OTHER protocols (no xhttp inbound) instead of failing the whole render.
	enabled="$(myc_sb_singbox_only "$enabled")"
	[ -n "$enabled" ] || myc_die "render-server: no sing-box-servable protocols enabled (only xray-engine protos were on; the sing-box engine has nothing to render)."
	myc_log "render-server (singbox): enabled protocols: $enabled"

	# ENGINE-COMPATIBILITY backstop. The `xhttp` transport with genuine TLS (vless-xhttp-tls) is Xray-core
	# ONLY — `sing-box check` rejects it with FATAL "unknown transport type: xhttp" and would crash on load.
	# vless-xhttp-tls is an xray-ENGINE proto (ADR-0032) and myc_sb_singbox_only above already removed it
	# from $enabled, so this guard is unreachable in normal operation; it stays as a fail-closed defence so
	# a future regression that leaked an xray-only proto back into the sing-box enabled set refuses LOUDLY
	# rather than shipping a config that crashes.
	case " $enabled " in
		*" vless-xhttp-tls "*)
			myc_die "render-server: vless-xhttp-tls leaked into the sing-box enabled set — the xhttp transport is Xray-core only (sing-box rejects transport.type \"xhttp\" with 'unknown transport type: xhttp' and would crash on load). This is unreachable in normal operation (myc_sb_singbox_only drops it); it is served by the Xray engine via 'render-server --engine xray --proto vless-xhttp-tls' (ADR-0032)." ;;
	esac

	# REALITY material is required as soon as any vless-reality-* protocol is on.
	local need_reality priv donor_sni donor_host short_ids_json
	need_reality=0
	case " $enabled " in *" vless-reality-"*) need_reality=1 ;; esac
	priv=""; donor_sni=""; donor_host=""; short_ids_json="[]"
	if [ "$need_reality" -eq 1 ]; then
		priv="$(myc_params_get "$params" '.reality_private_key')"
		donor_sni="$(myc_params_get "$params" '.donor_sni')"
		donor_host="$(myc_params_get "$params" '.donor_host')"
		short_ids_json="$(printf '%s' "$params" | jq -c '.short_ids // []')"
		if [ "$(printf '%s' "$short_ids_json" | jq 'length')" -eq 0 ]; then
			myc_die "render-server: params.short_ids must contain at least one shortId (a vless-reality-* protocol is enabled)"
		fi
	fi

	# TLS-cert protocols (hysteria2/tuic/trojan) share a server certificate + SNI.
	local tls_sni tls_cert tls_key
	tls_sni="$(myc_params_get "$params" '.tls_sni' "${donor_sni:-localhost}")"
	tls_cert="$(myc_params_get "$params" '.tls_certificate_path' '/etc/mycelium/tls/fullchain.pem')"
	tls_key="$(myc_params_get "$params" '.tls_key_path' '/etc/mycelium/tls/privkey.pem')"

	# C03 fail-closed: the genuine-single-TLS own-cert families (xhttp-tls AND ws-tls) present the node's
	# OWN certificate. Their server_name MUST be the node's own domain — never the donor SNI/localhost
	# fallback, which would make the served cert (own domain) disagree with the SNI a client dials, a
	# cert/SNI-mismatch active-probe tell (DISTINGUISHABLE_TRANSPORT). If either own-cert family is enabled,
	# require an explicit, non-donor tls_sni.
	case " $enabled " in
		*" vless-xhttp-tls "*|*" vless-ws-tls "*)
			local _tls_sni_explicit _donor_sni
			_tls_sni_explicit="$(myc_params_get "$params" '.tls_sni' '')"
			_donor_sni="$(myc_params_get "$params" '.donor_sni' '')"
			[ -n "$_tls_sni_explicit" ] || myc_die "render-server: an own-cert genuine-TLS family (vless-xhttp-tls/vless-ws-tls) is enabled but params.tls_sni is empty — the own-cert family must carry its OWN SNI (never the donor_sni/localhost fallback; that is a cert/SNI mismatch tell). Set params.tls_sni."
			[ -n "$_donor_sni" ] && [ "$_tls_sni_explicit" = "$_donor_sni" ] && myc_die "render-server: an own-cert genuine-TLS family is enabled but params.tls_sni EQUALS donor_sni ($_donor_sni) — serving the node's OWN cert under the REALITY donor SNI is a cert/SNI-mismatch tell AND correlates the genuine-TLS family with REALITY (Audit-0007 S2). Set params.tls_sni to the node's own cert domain." ;;
	esac

	# Protocol secrets (placeholders in params; real values from sing-box/openssl).
	# ShadowTLS wraps Shadowsocks, so its inner SS reuses ss_password; the ShadowTLS
	# handshake password is distinct (shadowtls_password).
	local ss_password trojan_password hysteria2_password shadowtls_password
	ss_password="$(myc_params_get "$params" '.ss_password' '')"
	trojan_password="$(myc_params_get "$params" '.trojan_password' '')"
	hysteria2_password="$(myc_params_get "$params" '.hysteria2_password' '')"
	shadowtls_password="$(myc_params_get "$params" '.shadowtls_password' '')"

	# clash_api secret (optional). When non-empty it is injected into experimental.clash_api so the
	# loopback /connections metadata endpoint requires a Bearer token (defence-in-depth on top of the
	# loopback bind). When EMPTY (legacy nodes whose identity predates the secret), the clash_api block
	# is left exactly as the template ships it, so the rendered config is byte-identical and the
	# updater's no-op short-circuit keeps the live service untouched.
	local clash_secret
	clash_secret="$(myc_params_get "$params" '.clash_secret' '')"

	# Transport-shaping values.
	local grpc_service xhttp_path xhttp_path_tls ws_path stls_handshake stls_handshake_port
	grpc_service="$(myc_params_get "$params" '.grpc_service_name' 'grpc')"
	xhttp_path="$(myc_params_get "$params" '.xhttp_path' '/')"
	# vless-ws-tls (genuine single-layer TLS over native WebSocket) serves $ws_path. Its own per-family
	# path so the ws-tls endpoint is not path-correlatable with the XHTTP families. Default "/ws".
	ws_path="$(myc_params_get "$params" '.ws_path' '/ws')"
	# C06: per-family XHTTP path. The REALITY-XHTTP inbound serves $xhttp_path; the genuine-TLS xhttp-tls
	# inbound serves $xhttp_path_tls so the two "independent" XHTTP families can carry DISTINCT paths and
	# are not correlatable by an identical plaintext path. Defaults to xhttp_path only when unset
	# (back-compat); MUST match render_bundle.sh's resolution so server and Link agree.
	xhttp_path_tls="$(myc_params_get "$params" '.xhttp_path_tls' "$xhttp_path")"
	# ShadowTLS does a GENUINE outer TLS handshake to (and relays from) this host — so it must be a
	# TLS-solid, ubiquitous site. It defaults to the node's picked REALITY donor when present; the bare
	# fallback is a curated ubiquitous host, NOT www.microsoft.com (dropped from the REALITY donor set as
	# steal-breaking — a stale reference here would re-endorse it; Audit-0007 S3). Ideally this draws from
	# the curated donor-candidate list (donor_candidates) rather than a literal — a follow-up.
	stls_handshake="$(myc_params_get "$params" '.shadowtls_handshake_server' "${donor_host:-www.apple.com}")"
	# Reachability posture (RP-0011 chunk D / ADR-0034 §3): node_bind is the listen address for every
	# PUBLIC inbound. Default "::" (byte-identical to today); apply_node_profile stamps "127.0.0.1" only
	# when the descriptor declares reachable:false. The hidden detour SS inbound stays 127.0.0.1.
	local node_bind; node_bind="$(myc_params_get "$params" '.node_bind' '::')"
	stls_handshake_port="$(myc_params_get "$params" '.shadowtls_handshake_port' '443')"

	# Per-protocol listen ports. The DEFAULT for each is the Go-owned canonical port from the registry
	# (control/vocab.json via myc_vocab_port, RP-0008 P2) — not a second hardcoded copy of 443/8443/...;
	# an operator override in params still wins. xhttp-tls (2087) and ws-tls (2089) are the genuine
	# single-layer-TLS families (own cert, NO reality); ws-tls is sing-box-servable, xhttp-tls is not.
	local p_vision p_grpc p_xhttp p_xhttp_tls p_ws_tls p_hy2 p_tuic p_ss p_stls p_trojan
	p_vision="$(myc_params_get "$params" '.vless_reality_vision_port' "$(myc_vocab_port vless-reality-vision)")"
	p_grpc="$(myc_params_get "$params"   '.vless_reality_grpc_port'   "$(myc_vocab_port vless-reality-grpc)")"
	p_xhttp="$(myc_params_get "$params"  '.vless_reality_xhttp_port'  "$(myc_vocab_port vless-reality-xhttp)")"
	p_xhttp_tls="$(myc_params_get "$params" '.vless_xhttp_tls_port'   "$(myc_vocab_port vless-xhttp-tls)")"
	p_ws_tls="$(myc_params_get "$params"   '.vless_ws_tls_port'       "$(myc_vocab_port vless-ws-tls)")"
	p_hy2="$(myc_params_get "$params"    '.hysteria2_port'            "$(myc_vocab_port hysteria2)")"
	p_tuic="$(myc_params_get "$params"   '.tuic_port'                 "$(myc_vocab_port tuic)")"
	p_ss="$(myc_params_get "$params"     '.shadowsocks_port'          "$(myc_vocab_port shadowsocks)")"
	p_stls="$(myc_params_get "$params"   '.shadowtls_port'            "$(myc_vocab_port shadowtls)")"
	p_trojan="$(myc_params_get "$params" '.trojan_port'               "$(myc_vocab_port trojan)")"

	# Build per-protocol users arrays from identity state (shape differs by protocol).
	# - vless (vision): { name, uuid, flow:"xtls-rprx-vision" }
	# - vless (grpc/xhttp): { name, uuid, flow:"" }  (Vision is TCP-only)
	# - tuic: { name, uuid, password }   (password defaults to the uuid if absent)
	# - hysteria2/trojan/shadowtls: { name, password }
	# - shadowsocks-2022 multi-user: { name, password }
	# A per-identity password override may be supplied via state .secret/.password;
	# otherwise the shared per-protocol password from params is used.
	local users_vision users_plain users_tuic users_hy2 users_trojan users_stls users_ss
	users_vision="$(printf '%s' "$clients" | jq -c 'map({ name: .name, uuid: .id, flow: "xtls-rprx-vision" })')"
	users_plain="$(printf '%s'  "$clients" | jq -c 'map({ name: .name, uuid: .id, flow: "" })')"
	users_tuic="$(printf '%s'   "$clients" | jq -c 'map({ name: .name, uuid: .id, password: (.password // .id) })')"
	# Password-based protocols: prefer a per-identity password, else the protocol secret.
	users_hy2="$(printf '%s'    "$clients" | jq -c --arg pw "$hysteria2_password" 'map({ name: .name, password: (.password // $pw) })')"
	users_trojan="$(printf '%s' "$clients" | jq -c --arg pw "$trojan_password" 'map({ name: .name, password: (.password // $pw) })')"
	users_stls="$(printf '%s'   "$clients" | jq -c --arg pw "$shadowtls_password" 'map({ name: .name, password: (.password // $pw) })')"
	users_ss="$(printf '%s'     "$clients" | jq -c --arg pw "$ss_password" 'map({ name: .name, password: (.password // $pw) })')"

	# A jq map: protocol token -> the listen port chosen for it.
	local ports_json
	ports_json="$(jq -nc \
		--argjson vision "$p_vision" --argjson grpc "$p_grpc" --argjson xhttp "$p_xhttp" \
		--argjson xhttptls "$p_xhttp_tls" --argjson wstls "$p_ws_tls" \
		--argjson hy2 "$p_hy2" --argjson tuic "$p_tuic" --argjson ss "$p_ss" \
		--argjson stls "$p_stls" --argjson trojan "$p_trojan" \
		'{
			"vless-reality-vision": $vision,
			"vless-reality-grpc":   $grpc,
			"vless-reality-xhttp":  $xhttp,
			"vless-xhttp-tls":      $xhttptls,
			"vless-ws-tls":         $wstls,
			"hysteria2":            $hy2,
			"tuic":                 $tuic,
			"shadowsocks":          $ss,
			"shadowtls":            $stls,
			"trojan":               $trojan
		}')"

	# A jq array of enabled tokens (so the filter can prune disabled inbounds).
	local enabled_json
	enabled_json="$(printf '%s\n' $enabled | jq -R . | jq -sc .)"

	# Render. Inbounds are matched by tag. We:
	#   1) set per-inbound dynamic values (keyed by tag),
	#   2) drop inbounds whose tag is not enabled (keeping the hidden shadowtls
	#      detour SS inbound whenever shadowtls is enabled),
	#   3) leave outbounds/route as-is from the template.
	local rendered
	rendered="$(jq \
		--arg priv "$priv" \
		--argjson shortids "$short_ids_json" \
		--arg dsni "$donor_sni" \
		--arg dhost "$donor_host" \
		--arg tsni "$tls_sni" \
		--arg tcert "$tls_cert" \
		--arg tkey "$tls_key" \
		--arg sspw "$ss_password" \
		--arg trpw "$trojan_password" \
		--arg grpc "$grpc_service" \
		--arg xpath "$xhttp_path" \
		--arg xpathtls "$xhttp_path_tls" \
		--arg wspath "$ws_path" \
		--arg bind "$node_bind" \
		--arg stlshs "$stls_handshake" \
		--arg clash_secret "$clash_secret" \
		--argjson stlshp "$stls_handshake_port" \
		--argjson ports "$ports_json" \
		--argjson enabled "$enabled_json" \
		--argjson uvision "$users_vision" \
		--argjson uplain "$users_plain" \
		--argjson utuic "$users_tuic" \
		--argjson uhy2 "$users_hy2" \
		--argjson utrojan "$users_trojan" \
		--argjson ustls "$users_stls" \
		--argjson uss "$users_ss" \
		'
		# setport maps a protocol token to its SERVER inbound tag (always
		# "<proto>-in" in the sing-box template) and applies the per-protocol
		# port from $ports (which is keyed by the bare protocol token). Matching
		# the proto token directly against .tag would never hit, because the
		# template tags carry the "-in" suffix — the custom port would then be
		# silently dropped on the server side while clients dial the new port.
		def setport($proto): if .tag == ($proto + "-in") and ($ports[$proto] != null) then .listen_port = $ports[$proto] else . end;
		def reality_fill:
			if (.tls? and .tls.reality? and .tls.reality.enabled == true) then
				  .tls.server_name = $dsni
				| .tls.reality.private_key = $priv
				| .tls.reality.short_id = $shortids
				| .tls.reality.handshake.server = $dhost
			else . end;
		def cert_fill:
			if (.tls? and (.tls.reality? | not)) then
				  .tls.server_name = $tsni
				| .tls.certificate_path = $tcert
				| .tls.key_path = $tkey
			else . end;
		.inbounds = (
			.inbounds
			# fill dynamic values on every inbound first
			| map(
				reality_fill
				| cert_fill
				| setport("vless-reality-vision")
				| setport("vless-reality-grpc")
				| setport("vless-reality-xhttp")
				| setport("vless-xhttp-tls")
				| setport("vless-ws-tls")
				| setport("hysteria2")
				| setport("tuic")
				| setport("shadowsocks")
				| setport("shadowtls")
				| setport("trojan")
				# Reachability posture (RP-0011 D): rebind the listen of every PUBLIC inbound to $bind
				# ("::" by default = byte-identical; "127.0.0.1" when the descriptor sets reachable:false).
				# The hidden detour SS inbound (shadowtls-ss-in) stays loopback regardless.
				| if (.tag != "shadowtls-ss-in" and (.listen != null)) then .listen = $bind else . end
				# per-protocol payloads, keyed by tag
				| if .tag == "vless-reality-vision-in" then .users = $uvision else . end
				| if .tag == "vless-reality-grpc-in"   then .users = $uplain  | .transport.service_name = $grpc else . end
				| if .tag == "vless-reality-xhttp-in"  then .users = $uplain  | .transport.path = $xpath else . end
				| if .tag == "vless-xhttp-tls-in"      then .users = $uplain  | .transport.path = $xpathtls else . end
				| if .tag == "vless-ws-tls-in"         then .users = $uplain  | .transport.path = $wspath else . end
				| if .tag == "hysteria2-in"            then .users = $uhy2 else . end
				| if .tag == "tuic-in"                 then .users = $utuic else . end
				| if .tag == "shadowsocks-in"          then .users = $uss | .password = $sspw else . end
				| if .tag == "shadowtls-in"            then .users = $ustls | .handshake.server = $stlshs | .handshake.server_port = $stlshp else . end
				| if .tag == "shadowtls-ss-in"         then .password = $sspw else . end
				| if .tag == "trojan-in"               then .users = $utrojan else . end
			)
			# prune inbounds whose protocol is not enabled. The internal shadowtls
			# detour SS inbound (tag "shadowtls-ss-in", no public listen_port) is
			# kept iff shadowtls itself is enabled.
			| map(select(
				( .tag == "vless-reality-vision-in" and ($enabled | index("vless-reality-vision")) )
				or ( .tag == "vless-reality-grpc-in"   and ($enabled | index("vless-reality-grpc")) )
				or ( .tag == "vless-reality-xhttp-in"  and ($enabled | index("vless-reality-xhttp")) )
				or ( .tag == "vless-xhttp-tls-in"      and ($enabled | index("vless-xhttp-tls")) )
				or ( .tag == "vless-ws-tls-in"         and ($enabled | index("vless-ws-tls")) )
				or ( .tag == "hysteria2-in"            and ($enabled | index("hysteria2")) )
				or ( .tag == "tuic-in"                 and ($enabled | index("tuic")) )
				or ( .tag == "shadowsocks-in"          and ($enabled | index("shadowsocks")) )
				or ( .tag == "shadowtls-in"            and ($enabled | index("shadowtls")) )
				or ( .tag == "shadowtls-ss-in"         and ($enabled | index("shadowtls")) )
				or ( .tag == "trojan-in"               and ($enabled | index("trojan")) )
			))
		)
		# Inject the clash_api Bearer secret only when one was provisioned (non-empty). Empty -> leave
		# experimental untouched so legacy nodes render byte-identically (no-op update, no restart).
		| if ($clash_secret != "" and (.experimental?.clash_api? != null))
			then .experimental.clash_api.secret = $clash_secret else . end
		' "$template" 2>/dev/null)"

	if [ -z "$rendered" ] || ! printf '%s' "$rendered" | jq -e . >/dev/null 2>&1; then
		myc_die "render-server: sing-box rendering produced invalid JSON (check template shape)"
	fi

	# Optional two-hop egress (ADR-0029, RP-0007 in-region-ingress topology): when the node-local params
	# declare a `two_hop` upstream, append a VLESS+WS+TLS outbound to that out-of-region node plus an
	# auth_user route rule, so a designated client egresses through it (in-region ingress -> out-of-region
	# egress, carried node-to-node — never user-direct). Gated on the param being present, so every node
	# WITHOUT `two_hop` renders byte-identically (no-op for the whole network; zero blast radius).
	local two_hop
	two_hop="$(printf '%s' "$params" | jq -c '.two_hop // empty' 2>/dev/null)"
	if [ -n "$two_hop" ]; then
		# Fail-closed: a two_hop with no designated client (empty via_user) would add an upstream outbound
		# that NO route rule selects — an unscoped, silently-unused egress. Refuse it: a two-hop must name
		# exactly which client egresses out-of-region; everyone else stays on the in-region final route.
		local th_via; th_via="$(printf '%s' "$two_hop" | jq -r '.via_user // ""')"
		[ -n "$th_via" ] || myc_die "render-server: params.two_hop.via_user is empty — refusing an unscoped two-hop egress (set the designated client name)."
		# C17 fail-closed: the overlay must be a well-formed upstream — non-empty tag/server/sni and an
		# integer server_port in 1..65535. A malformed upstream (e.g. server_port 0) would otherwise be
		# spliced into a non-dialable outbound. Validate the shape at the SAME bar render_bundle applies.
		printf '%s' "$two_hop" | jq -e 'type == "object"' >/dev/null 2>&1 \
			|| myc_die "render-server: params.two_hop is not an object (fail-closed)."
		local th_tag th_srv th_sn th_pt
		th_tag="$(printf '%s' "$two_hop" | jq -r '.tag // ""')"
		th_srv="$(printf '%s' "$two_hop" | jq -r '.server // ""')"
		th_sn="$(printf '%s' "$two_hop" | jq -r '.sni // ""')"
		th_pt="$(printf '%s' "$two_hop" | jq -r '.server_port // empty')"
		[ -n "$th_tag" ] || myc_die "render-server: params.two_hop.tag is empty (fail-closed; the upstream outbound needs a tag)."
		[ -n "$th_srv" ] || myc_die "render-server: params.two_hop.server is empty (fail-closed; the upstream needs an address)."
		[ -n "$th_sn" ]  || myc_die "render-server: params.two_hop.sni is empty (fail-closed; the upstream TLS needs a server_name)."
		case "$th_pt" in
			''|*[!0-9]*) myc_die "render-server: params.two_hop.server_port is not a positive integer ('$th_pt'); must be 1..65535 (fail-closed)." ;;
		esac
		if [ "$th_pt" -lt 1 ] || [ "$th_pt" -gt 65535 ]; then
			myc_die "render-server: params.two_hop.server_port is out of range ('$th_pt'); must be 1..65535 (fail-closed)."
		fi
		# C18 fail-closed: via_user MUST name an EXISTING client (clients[].name). The auth_user route rule
		# below keys on this exact name; an unknown user renders fine but the rule NEVER matches — a dead,
		# unscoped egress whose designated traffic silently falls through to the in-region final route.
		if ! printf '%s' "$clients" | jq -e --arg u "$th_via" 'any(.[]; .name == $u)' >/dev/null 2>&1; then
			myc_die "render-server: params.two_hop.via_user '$th_via' is not a known client (fail-closed; the auth_user route would never match — add the identity or fix via_user)."
		fi
		# C21 fail-closed: the egress upstream must be DISTINCT from this ingress node, or the "two hops"
		# collapse to one. Refuse when the upstream server equals this node's own address OR the upstream
		# SNI equals this node's donor_sni (same host or same TLS identity => not a second hop). Reuses the
		# th_srv/th_sn read above.
		local ingress_addr ingress_sni
		ingress_addr="$(printf '%s' "$params" | jq -r '.node_address // ""')"
		ingress_sni="$(printf '%s' "$params" | jq -r '.donor_sni // ""')"
		if [ -n "$th_srv" ] && [ -n "$ingress_addr" ] && [ "$th_srv" = "$ingress_addr" ]; then
			myc_die "render-server: params.two_hop.server '$th_srv' is THIS node's own address — refusing a two-hop whose egress is the ingress (fail-closed; ingress and egress must be distinct nodes)."
		fi
		if [ -n "$th_sn" ] && [ -n "$ingress_sni" ] && [ "$th_sn" = "$ingress_sni" ]; then
			myc_die "render-server: params.two_hop.sni '$th_sn' equals this node's donor_sni — refusing a two-hop whose egress shares the ingress SNI (fail-closed; egress must be a distinct node)."
		fi
		# Audit-0008 S2-3: normalize the two-hop egress uTLS preset against the closed vocab (byte-twin of
		# Go spec.NormalizeClientFingerprint via myc_client_fingerprint) so a typo/stale value in the signed
		# two_hop overlay renders as the default, never as an invalid uTLS token that fail-serves the egress.
		local th_fp
		th_fp="$(myc_client_fingerprint "$(printf '%s' "$two_hop" | jq -c '{client_fingerprint: (.fingerprint // "")}')")"
		rendered="$(printf '%s' "$rendered" | jq --argjson th "$two_hop" --arg thfp "$th_fp" '
			.outbounds += [{
				type: "vless", tag: $th.tag, server: $th.server,
				server_port: ($th.server_port | tonumber), uuid: $th.uuid, flow: "",
				tls: { enabled: true, server_name: $th.sni,
				       utls: { enabled: true, fingerprint: $thfp },
				       alpn: [ ($th.alpn // "http/1.1") ] },
				transport: { type: "ws", path: ($th.ws_path // "/ws"),
				             headers: { Host: ($th.ws_host // $th.sni) } }
			}]
			| .route.rules = ((.route.rules // []) + [{ auth_user: [ $th.via_user ], outbound: $th.tag }])
		' 2>/dev/null)"
		if [ -z "$rendered" ] || ! printf '%s' "$rendered" | jq -e . >/dev/null 2>&1; then
			myc_die "render-server: two_hop injection produced invalid JSON (check params.two_hop schema)"
		fi
		myc_log "render-server: appended two-hop egress (params.two_hop.tag=$(printf '%s' "$two_hop" | jq -r '.tag'))"
	fi

	printf '%s\n' "$rendered" | jq . | myc_atomic_write "$out"
	myc_assert_json "$out" "rendered sing-box server config"
	myc_log "wrote sing-box server config: $out ($(printf '%s' "$rendered" | jq '.inbounds | length') inbound(s))"
}

# ---------------------------------------------------------------------------
# subscription (sing-box engine)
# ---------------------------------------------------------------------------
#
# Per client, emit:
#   <name>.singbox.json  — one outbound per ENABLED protocol + a `selector` and a
#                          `urltest` outbound that prefer them in priority order.
#   <name>.clash.yaml    — one proxy per Clash-supported enabled protocol + a
#                          `select` and a `url-test` proxy-group.
#
# Only the REALITY *public* key reaches clients (never the private key).
#
# myc_sb_render_subscription PARAMS_FILE STATE OUT_DIR
myc_sb_render_subscription() {
	local params_file state out_dir
	params_file="$1"; state="$2"; out_dir="$3"

	[ -n "$params_file" ] || myc_die "subscription: --params is required"
	[ -n "$state" ]       || myc_die "subscription: --state is required"
	[ -n "$out_dir" ]     || myc_die "subscription: --out is required"

	local params clients count
	params="$(myc_params_to_json "$params_file")"
	myc_state_init "$state"
	clients="$(myc_identity_clients_json "$state")"
	count="$(printf '%s' "$clients" | jq 'length')"
	if [ "$count" -eq 0 ]; then
		myc_warn "subscription: identity state has zero clients; nothing to emit"
	fi

	local enabled
	enabled="$(myc_sb_enabled_list "$params")"
	[ -n "$enabled" ] || myc_die "subscription: no protocols enabled in params"
	# Drop xray-engine protos: a sing-box CLIENT cannot DIAL the xhttp transport either, so a sing-box
	# subscription emits no vless-xhttp-tls outbound (the Xray client dials it instead — ADR-0032). The
	# enabled set spans the full registry (shared with the bundle); keep only the sing-box-engine protos.
	enabled="$(myc_sb_singbox_only "$enabled")"
	[ -n "$enabled" ] || myc_die "subscription: no sing-box-dialable protocols enabled (only xray-engine protos were on)."
	myc_log "subscription (singbox): enabled protocols: $enabled"

	# ENGINE-COMPATIBILITY backstop (mirror of the render-server guard): the genuine-TLS `xhttp` transport
	# (vless-xhttp-tls) is Xray-core ONLY — a sing-box outbound with `transport.type: "xhttp"` is rejected
	# with "unknown transport type: xhttp". myc_sb_singbox_only above already removed it, so this guard is
	# unreachable in normal operation and stays only as a fail-closed defence against a future regression.
	case " $enabled " in
		*" vless-xhttp-tls "*)
			myc_die "subscription: vless-xhttp-tls is enabled but the sing-box engine cannot dial it — the xhttp transport is Xray-core only (a sing-box client rejects transport.type \"xhttp\"). Do NOT enable vless-xhttp-tls on the sing-box engine; it will be served via the Xray engine in a future RP." ;;
	esac

	# Shared connection parameters (clients dial node_address on each protocol port).
	local node_addr donor_sni pub tls_sni short_first
	node_addr="$(myc_params_get "$params" '.node_address')"
	donor_sni="$(myc_params_get "$params" '.donor_sni' '')"
	pub="$(myc_params_get "$params" '.reality_public_key' '')"
	tls_sni="$(myc_params_get "$params" '.tls_sni' "${donor_sni:-localhost}")"
	short_first="$(printf '%s' "$params" | jq -r '.short_ids[0] // empty')"

	# C03 fail-closed: when an own-cert genuine-TLS family (xhttp-tls or ws-tls) is in the subscription, its
	# client Link MUST carry the node's OWN SNI — never the donor_sni/localhost fallback (a cert/SNI-mismatch
	# tell). Require an explicit tls_sni so the subscription's own-cert outbound dials the right own-cert name.
	case " $enabled " in
		*" vless-xhttp-tls "*|*" vless-ws-tls "*)
			local _tls_sni_explicit; _tls_sni_explicit="$(myc_params_get "$params" '.tls_sni' '')"
			[ -n "$_tls_sni_explicit" ] || myc_die "subscription: an own-cert genuine-TLS family (vless-xhttp-tls/vless-ws-tls) is enabled but params.tls_sni is empty — the own-cert family must carry its OWN SNI (never the donor_sni/localhost fallback). Set params.tls_sni." ;;
	esac

	local ss_password trojan_password hysteria2_password shadowtls_password grpc_service xhttp_path xhttp_path_tls ws_path client_fingerprint
	ss_password="$(myc_params_get "$params" '.ss_password' '')"
	trojan_password="$(myc_params_get "$params" '.trojan_password' '')"
	hysteria2_password="$(myc_params_get "$params" '.hysteria2_password' '')"
	shadowtls_password="$(myc_params_get "$params" '.shadowtls_password' '')"
	grpc_service="$(myc_params_get "$params" '.grpc_service_name' 'grpc')"
	xhttp_path="$(myc_params_get "$params" '.xhttp_path' '/')"
	# C06: per-family XHTTP path (see render-server). The xhttp-tls outbound dials $xhttp_path_tls; the
	# REALITY-XHTTP outbound dials $xhttp_path. Defaults to xhttp_path when unset (back-compat).
	xhttp_path_tls="$(myc_params_get "$params" '.xhttp_path_tls' "$xhttp_path")"
	# vless-ws-tls dials $ws_path (native WebSocket; default "/ws"). Its own per-family path so the ws-tls
	# endpoint is not path-correlatable with the XHTTP families.
	ws_path="$(myc_params_get "$params" '.ws_path' '/ws')"
	# RP-0015: the client uTLS ClientHello preset, threaded into every TLS-carrying outbound below (and
	# mirrored by the donor-verify / L7 probe), normalised against the closed vocab (default "chrome").
	client_fingerprint="$(myc_client_fingerprint "$params")"

	# Per-protocol ports (must match the server render defaults).
	local ports_json
	ports_json="$(jq -nc \
		--argjson vision "$(myc_params_get "$params" '.vless_reality_vision_port' '443')" \
		--argjson grpc   "$(myc_params_get "$params" '.vless_reality_grpc_port' '8443')" \
		--argjson xhttp  "$(myc_params_get "$params" '.vless_reality_xhttp_port' '2096')" \
		--argjson xhttptls "$(myc_params_get "$params" '.vless_xhttp_tls_port' '2087')" \
		--argjson wstls  "$(myc_params_get "$params" '.vless_ws_tls_port' '2089')" \
		--argjson hy2    "$(myc_params_get "$params" '.hysteria2_port' '8444')" \
		--argjson tuic   "$(myc_params_get "$params" '.tuic_port' '8445')" \
		--argjson ss     "$(myc_params_get "$params" '.shadowsocks_port' '8388')" \
		--argjson stls   "$(myc_params_get "$params" '.shadowtls_port' '8446')" \
		--argjson trojan "$(myc_params_get "$params" '.trojan_port' '8447')" \
		'{
			"vless-reality-vision": $vision, "vless-reality-grpc": $grpc, "vless-reality-xhttp": $xhttp,
			"vless-xhttp-tls": $xhttptls, "vless-ws-tls": $wstls,
			"hysteria2": $hy2, "tuic": $tuic, "shadowsocks": $ss, "shadowtls": $stls, "trojan": $trojan
		}')"

	local enabled_json
	enabled_json="$(printf '%s\n' $enabled | jq -R . | jq -sc .)"

	myc_mkdir_p "$out_dir"

	# Iterate clients; build each file with a single jq -n invocation.
	printf '%s' "$clients" | jq -r '.[] | [.name, .id, (.password // "")] | @tsv' \
		| while IFS="$(printf '\t')" read -r name id ipw; do
			[ -n "$name" ] || continue
			local safe sb_path clash_path
			safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
			sb_path="${out_dir}/${safe}.singbox.json"
			clash_path="${out_dir}/${safe}.clash.yaml"

			# Per-identity password falls back to the shared protocol secret.
			local hy2_pw trojan_pw ss_pw stls_pw tuic_pw
			hy2_pw="${ipw:-$hysteria2_password}"
			ss_pw="${ipw:-$ss_password}"
			stls_pw="${ipw:-$shadowtls_password}"
			trojan_pw="${ipw:-$trojan_password}"
			tuic_pw="${ipw:-$id}"

			# --- sing-box CLIENT config ---
			# Build the candidate outbound for each protocol, then keep only enabled
			# ones, then append a urltest + selector that reference them by tag.
			jq -n \
				--arg name "$name" \
				--arg server "$node_addr" \
				--arg uuid "$id" \
				--arg dsni "$donor_sni" \
				--arg pub "$pub" \
				--arg sid "$short_first" \
				--arg tsni "$tls_sni" \
				--arg sspw "$ss_pw" \
				--arg hy2pw "$hy2_pw" \
				--arg trpw "$trojan_pw" \
				--arg stlspw "$stls_pw" \
				--arg tuicpw "$tuic_pw" \
				--arg grpc "$grpc_service" \
				--arg xpath "$xhttp_path" \
				--arg xpathtls "$xhttp_path_tls" \
				--arg wspath "$ws_path" \
				--arg fp "$client_fingerprint" \
				--arg utinterval "$MYC_URLTEST_INTERVAL" \
				--argjson uttolerance "$MYC_URLTEST_TOLERANCE" \
				--arg utidle "$MYC_URLTEST_IDLE_TIMEOUT" \
				--argjson ports "$ports_json" \
				--argjson enabled "$enabled_json" \
				'
				def reality_tls: { enabled: true, server_name: $dsni, utls: { enabled: true, fingerprint: $fp }, reality: { enabled: true, public_key: $pub, short_id: $sid } };
				def plain_tls($alpn): { enabled: true, server_name: $tsni, utls: { enabled: true, fingerprint: $fp }, alpn: $alpn };
				# tag -> candidate outbound
				{
					"vless-reality-vision": { type: "vless", tag: "vless-reality-vision", server: $server, server_port: $ports["vless-reality-vision"], uuid: $uuid, flow: "xtls-rprx-vision", packet_encoding: "xudp", tls: reality_tls },
					"vless-reality-grpc":   { type: "vless", tag: "vless-reality-grpc",   server: $server, server_port: $ports["vless-reality-grpc"],   uuid: $uuid, flow: "", packet_encoding: "xudp", tls: reality_tls, transport: { type: "grpc", service_name: $grpc } },
					"vless-reality-xhttp":  { type: "vless", tag: "vless-reality-xhttp",  server: $server, server_port: $ports["vless-reality-xhttp"],  uuid: $uuid, flow: "", packet_encoding: "xudp", tls: reality_tls, transport: { type: "xhttp", path: $xpath } },
					# vless-xhttp-tls: genuine single-layer TLS (own cert, verified by the client — NO reality donor).
					# transport.type matches the server template ("xhttp") so there is no server/client naming mismatch.
					"vless-xhttp-tls":      { type: "vless", tag: "vless-xhttp-tls",      server: $server, server_port: $ports["vless-xhttp-tls"],      uuid: $uuid, flow: "", packet_encoding: "xudp", tls: plain_tls(["h2","http/1.1"]), transport: { type: "xhttp", path: $xpathtls } },
					# vless-ws-tls: genuine single-layer TLS over native WebSocket (own cert, verified — NO reality
					# donor). transport.type "ws" matches the server template; sing-box CAN dial it (native ws),
					# so unlike xhttp-tls this outbound is emitted on the sing-box engine, not refused.
					"vless-ws-tls":         { type: "vless", tag: "vless-ws-tls",         server: $server, server_port: $ports["vless-ws-tls"],         uuid: $uuid, flow: "", packet_encoding: "xudp", tls: plain_tls(["http/1.1"]), transport: { type: "ws", path: $wspath, headers: { Host: $tsni } } },
					"hysteria2":            { type: "hysteria2", tag: "hysteria2",        server: $server, server_port: $ports["hysteria2"], password: $hy2pw, tls: plain_tls(["h3"]) },
					"tuic":                 { type: "tuic", tag: "tuic",                  server: $server, server_port: $ports["tuic"], uuid: $uuid, password: $tuicpw, congestion_control: "bbr", tls: plain_tls(["h3"]) },
					"shadowsocks":          { type: "shadowsocks", tag: "shadowsocks",    server: $server, server_port: $ports["shadowsocks"], method: "2022-blake3-aes-256-gcm", password: $sspw },
					"shadowtls":            { type: "shadowsocks", tag: "shadowtls",        method: "2022-blake3-aes-256-gcm", password: $sspw, detour: "shadowtls-handshake" },
					"trojan":               { type: "trojan", tag: "trojan",              server: $server, server_port: $ports["trojan"], password: $trpw, tls: plain_tls(["h2","http/1.1"]) }
				} as $cand
				| ($enabled | map($cand[.])) as $proxies
				# ShadowTLS routes Shadowsocks over a TLS handshake: the routable
				# outbound (tag "shadowtls") is Shadowsocks with a detour to the
				# hidden "shadowtls-handshake" outbound that performs the v3 handshake.
				| (if ($enabled | index("shadowtls")) then
						[ { type: "shadowtls", tag: "shadowtls-handshake", server: $server, server_port: $ports["shadowtls"], version: 3, password: $stlspw, tls: { enabled: true, server_name: $tsni, utls: { enabled: true, fingerprint: $fp } } } ]
					else [] end) as $detours
				| ($enabled | map($cand[.].tag)) as $tags
				| {
					outbounds: (
						$proxies
						+ $detours
						+ [
							{ type: "urltest", tag: "auto", outbounds: $tags, url: "https://www.gstatic.com/generate_204", interval: $utinterval, tolerance: $uttolerance, idle_timeout: $utidle },
							{ type: "selector", tag: "mycelium", outbounds: (["auto"] + $tags), default: "auto" },
							{ type: "direct", tag: "direct" },
							{ type: "block", tag: "block" }
						]
					)
				}
				' | myc_atomic_write "$sb_path"
			myc_assert_json "$sb_path" "sing-box client config for $name"

			# --- Clash-Meta config (only the protocols Clash-Meta supports) ---
			myc_sb_emit_clash \
				"$clash_path" "$name" "$node_addr" "$id" \
				"$donor_sni" "$pub" "$short_first" "$tls_sni" \
				"$ss_pw" "$hy2_pw" "$trojan_pw" "$grpc_service" "$xhttp_path" \
				"$ports_json" "$enabled"

			myc_log "wrote sing-box subscription for '$name': $sb_path, $clash_path"
		done
}

# myc_sb_emit_clash PATH NAME SERVER UUID DSNI PUB SID TSNI SSPW HY2PW TRPW GRPC XPATH PORTS_JSON ENABLED
# Hand-emit a Clash-Meta YAML doc: a `proxies:` list (one entry per Clash-supported
# enabled protocol) plus a `proxy-groups:` block with a `select` and a `url-test`
# group. jq has no YAML output, so we emit by printf; every value is quoted so any
# special characters are inert. Clash-Meta does NOT support ShadowTLS or XHTTP, so
# those protocols are intentionally skipped here (they remain in the sing-box file).
myc_sb_emit_clash() {
	local path name server uuid dsni pub sid tsni sspw hy2pw trpw grpc xpath ports enabled
	path="$1"; name="$2"; server="$3"; uuid="$4"; dsni="$5"; pub="$6"; sid="$7"; tsni="$8"
	sspw="$9"; hy2pw="${10}"; trpw="${11}"; grpc="${12}"; xpath="${13}"; ports="${14}"; enabled="${15}"

	local port_of names p
	port_of() { printf '%s' "$ports" | jq -r --arg t "$1" '.[$t]'; }

	{
		printf '# Copyright © 2026 mindicator & silicon bags quartet.\n'
		printf '# SPDX-License-Identifier: AGPL-3.0-or-later\n'
		printf '# This file is part of Mycelium, licensed under the GNU Affero General Public\n'
		printf '# License v3.0 or later. See the LICENSE file in the repository root.\n'
		printf '#\n'
		printf '# Clash-Meta proxies + groups for client "%s". Generated by myceliumctl (engine: singbox).\n' "$name"
		printf '# Merge "proxies" and "proxy-groups" into your Clash-Meta config. ShadowTLS and XHTTP\n'
		printf '# are not represented here (Clash-Meta lacks support); use the sing-box config for those.\n'
		printf 'proxies:\n'

		names=""
		for p in $enabled; do
			case "$p" in
				vless-reality-vision)
					printf '  - name: "mycelium-%s-vision"\n' "$name"
					printf '    type: vless\n'
					printf '    server: "%s"\n' "$server"
					printf '    port: %s\n' "$(port_of vless-reality-vision)"
					printf '    uuid: "%s"\n' "$uuid"
					printf '    network: tcp\n'
					printf '    udp: true\n'
					printf '    flow: xtls-rprx-vision\n'
					printf '    tls: true\n'
					printf '    servername: "%s"\n' "$dsni"
					printf '    client-fingerprint: %s\n' "$client_fingerprint"
					printf '    reality-opts:\n'
					printf '      public-key: "%s"\n' "$pub"
					printf '      short-id: "%s"\n' "$sid"
					names="${names}, \"mycelium-$name-vision\""
					;;
				vless-reality-grpc)
					printf '  - name: "mycelium-%s-grpc"\n' "$name"
					printf '    type: vless\n'
					printf '    server: "%s"\n' "$server"
					printf '    port: %s\n' "$(port_of vless-reality-grpc)"
					printf '    uuid: "%s"\n' "$uuid"
					printf '    network: grpc\n'
					printf '    udp: true\n'
					printf '    tls: true\n'
					printf '    servername: "%s"\n' "$dsni"
					printf '    client-fingerprint: %s\n' "$client_fingerprint"
					printf '    grpc-opts:\n'
					printf '      grpc-service-name: "%s"\n' "$grpc"
					printf '    reality-opts:\n'
					printf '      public-key: "%s"\n' "$pub"
					printf '      short-id: "%s"\n' "$sid"
					names="${names}, \"mycelium-$name-grpc\""
					;;
				hysteria2)
					printf '  - name: "mycelium-%s-hysteria2"\n' "$name"
					printf '    type: hysteria2\n'
					printf '    server: "%s"\n' "$server"
					printf '    port: %s\n' "$(port_of hysteria2)"
					printf '    password: "%s"\n' "$hy2pw"
					printf '    sni: "%s"\n' "$tsni"
					printf '    alpn:\n'
					printf '      - h3\n'
					names="${names}, \"mycelium-$name-hysteria2\""
					;;
				tuic)
					printf '  - name: "mycelium-%s-tuic"\n' "$name"
					printf '    type: tuic\n'
					printf '    server: "%s"\n' "$server"
					printf '    port: %s\n' "$(port_of tuic)"
					printf '    uuid: "%s"\n' "$uuid"
					printf '    password: "%s"\n' "$uuid"
					printf '    sni: "%s"\n' "$tsni"
					printf '    congestion-controller: bbr\n'
					printf '    alpn:\n'
					printf '      - h3\n'
					names="${names}, \"mycelium-$name-tuic\""
					;;
				shadowsocks)
					printf '  - name: "mycelium-%s-ss2022"\n' "$name"
					printf '    type: ss\n'
					printf '    server: "%s"\n' "$server"
					printf '    port: %s\n' "$(port_of shadowsocks)"
					printf '    cipher: 2022-blake3-aes-256-gcm\n'
					printf '    password: "%s"\n' "$sspw"
					printf '    udp: true\n'
					names="${names}, \"mycelium-$name-ss2022\""
					;;
				trojan)
					printf '  - name: "mycelium-%s-trojan"\n' "$name"
					printf '    type: trojan\n'
					printf '    server: "%s"\n' "$server"
					printf '    port: %s\n' "$(port_of trojan)"
					printf '    password: "%s"\n' "$trpw"
					printf '    sni: "%s"\n' "$tsni"
					printf '    client-fingerprint: %s\n' "$client_fingerprint"
					printf '    alpn:\n'
					printf '      - h2\n'
					printf '      - http/1.1\n'
					names="${names}, \"mycelium-$name-trojan\""
					;;
				*)
					# shadowtls / xhttp: not represented in Clash-Meta (see header note).
					;;
			esac
		done

		# Proxy groups: a url-test (auto) over all emitted proxies, and a manual select.
		# $names is a leading-comma list (", \"a\", \"b\""); strip the leading ", ".
		if [ -n "$names" ]; then
			local names_clean
			names_clean="${names#, }"
			printf 'proxy-groups:\n'
			printf '  - name: "mycelium-auto"\n'
			printf '    type: url-test\n'
			printf '    url: "https://www.gstatic.com/generate_204"\n'
			# C22 anti-flapping (Clash-Meta url-test): interval in SECONDS (300=5m), tolerance in ms (150),
			# lazy so an idle group is not re-probed on stale data — the Clash-Meta analogue of the sing-box
			# MYC_URLTEST_* hysteresis defaults; keeps the client from thrashing between near-equal endpoints.
			printf '    interval: 300\n'
			printf '    tolerance: 150\n'
			printf '    lazy: true\n'
			printf '    proxies: [ %s ]\n' "$names_clean"
			printf '  - name: "mycelium"\n'
			printf '    type: select\n'
			printf '    proxies: [ "mycelium-auto", %s ]\n' "$names_clean"
		fi
	} | myc_atomic_write "$path"
}
