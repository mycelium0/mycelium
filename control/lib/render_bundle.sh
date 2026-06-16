# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render_bundle.sh — render a typed distribution Bundle (internal/spec/bundle.go) for a node:
# one Endpoint per ENABLED transport, each carrying a coarse transport CLASS, a coarse region
# bucket, a priority hint, an advisory health label (PHASE-1: always "unknown"), and the opaque
# dialable client config string (Link). The matured, self-replenishing form of the Phase-0
# hand-rendered subscription (ADR-0020 §1, RP-0007-b).
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl. Depends on common.sh, jqlib.sh, identity.sh, render_singbox.sh
# (it reuses MYC_SB_PROTOS / myc_sb_enabled_list and the per-protocol port + connection params
# the subscription path already establishes — the Bundle's Link is the SAME dialable config the
# subscription emits, never a second source of truth).
#
# PHASE DISCIPLINE (bundle.go): this command renders the INERT, typed shape only. health is
# advisory-only and Validate() rejects anything but "unknown" in Phase 1, so EVERY endpoint here
# is emitted with health == "unknown". region is a COARSE opaque bucket from params
# (.region_bucket // "unspecified") — never a precise location/ASN. The bundle carries no node IP
# or port at top level; those live opaquely inside each Link.
#
# The schema version is NetworkStateVersion (internal/spec/network.go == 1). The emitted JSON is
# structured to round-trip through internal/spec.Bundle.Validate() unchanged.

# Bundle schema version. MUST equal internal/spec.NetworkStateVersion (network.go). Bundle.Validate
# rejects any other value, so this is pinned here and Go-verified on a node.
MYC_BUNDLE_VERSION=1

# C34: named priority sentinel for a protocol absent from the MYC_SB_PROTOS registry. It is far larger
# than any real index so an unregistered protocol always sorts LAST in the selector/urltest order
# (defensive — a known protocol always has a real 0-based index). Bundle.Validate only requires
# priority >= 0, so this large value is still a valid (if last-ranked) priority.
MYC_BUNDLE_PRIORITY_UNRANKED=9999

# MYC_VOCAB -> the Go-owned control vocabulary file (control/vocab.json, emitted by `myceliumctl
# vocab` from internal/spec). The proto->class table and the closed transport-class vocabulary are
# READ from here, never re-declared in this shell (RP-0008 P2): Go owns them and the
# vocab_single_source gate keeps the committed file byte-identical to the Go emission. Overridable for
# tests; ships to nodes with the rest of control/ via install_tooling.
MYC_VOCAB="${MYC_VOCAB:-$MYC_ROOT/vocab.json}"

# _MYC_VOCAB_CLASSMAP caches the "proto<TAB>class" rows from MYC_VOCAB so the file is parsed once per
# render. myc_vocab_load is fail-closed: a missing/empty/unreadable vocab file is a hard error, never a
# silent fall-back to an inline copy of the table (the inline copy is exactly what P2 removed).
_MYC_VOCAB_CLASSMAP=""
myc_vocab_load() {
	[ -n "$_MYC_VOCAB_CLASSMAP" ] && return 0
	[ -f "$MYC_VOCAB" ] || myc_die "render-bundle: control/vocab.json not found ($MYC_VOCAB) — the Go-owned transport vocabulary is required (RP-0008 P2)."
	_MYC_VOCAB_CLASSMAP="$(jq -r '.protos[] | "\(.proto)\t\(.class)"' "$MYC_VOCAB" 2>/dev/null)" \
		|| myc_die "render-bundle: could not read the proto->class map from $MYC_VOCAB."
	[ -n "$_MYC_VOCAB_CLASSMAP" ] || myc_die "render-bundle: $MYC_VOCAB has an empty proto registry."
	return 0
}

# myc_bundle_class_of PROTO -> the closed-vocab transport CLASS for a protocol token, looked up from the
# Go-owned registry in MYC_VOCAB (internal/spec, TransportClass*). One family per protocol; the three
# vless-reality-* shapes collapse to the single reality-tcp family (same handshake surface,
# ADR-0010/0020). An unregistered proto yields the empty string, exactly as before.
myc_bundle_class_of() {
	local target="$1" p c
	myc_vocab_load
	while IFS="$(printf '\t')" read -r p c; do
		[ "$p" = "$target" ] && { printf '%s' "$c"; return 0; }
	done <<MYC_VOCAB_EOF
$_MYC_VOCAB_CLASSMAP
MYC_VOCAB_EOF
	printf ''
}

# myc_bundle_priority_of PROTO -> the 0-based order index of PROTO in MYC_SB_PROTOS (lower = more
# preferred), reusing the SAME priority order the subscription selector/urltest applies. Returns the
# index; a protocol not in the registry yields a large sentinel so it sorts last (defensive).
myc_bundle_priority_of() {
	local target p idx
	target="$1"; idx=0
	for p in $MYC_SB_PROTOS; do
		if [ "$p" = "$target" ]; then
			printf '%s' "$idx"
			return 0
		fi
		idx=$((idx + 1))
	done
	printf '%s' "$MYC_BUNDLE_PRIORITY_UNRANKED"
}

# myc_bundle_link PROTO SERVER PORT UUID DSNI PUB SID TSNI SSPW HY2PW TRPW TUICPW GRPC XPATH XPATH_TLS
# -> the per-endpoint dialable client config STRING (a share-link URI) for PROTO. This is the
# Bundle's opaque Link: the same connection coordinates the sing-box/Clash subscription dials,
# rendered as the standard scheme:// URI a client imports. Never empty for a known protocol.
#
# ARG ORDER (15 positional, all already-resolved by the caller; C34 arity-guarded below):
#   $1  PROTO       protocol token (e.g. vless-reality-vision)
#   $2  SERVER      node address
#   $3  PORT        per-protocol port
#   $4  UUID        endpoint credential (first identity)
#   $5  DSNI        donor SNI (REALITY families only)
#   $6  PUB         REALITY public key
#   $7  SID         REALITY shortId
#   $8  TSNI        own-cert TLS SNI (xhttp-tls / hysteria2 / tuic / trojan)
#   $9  SSPW        Shadowsocks / ShadowTLS inner password
#   $10 HY2PW       Hysteria2 password
#   $11 TRPW        Trojan password
#   $12 TUICPW      TUIC password
#   $13 GRPC        gRPC service name
#   $14 XPATH       xhttp path for the REALITY-XHTTP family (C06)
#   $15 XPATH_TLS   xhttp path for the genuine-TLS xhttp-tls family (C06: a per-family path so an
#                   on-path observer cannot correlate the two "independent" XHTTP families by an
#                   identical path)
#   $16 WS_PATH     ws path for the genuine-TLS ws-tls family (its own per-family path; default "/ws")
#
# The node/port/SNI live ONLY inside this opaque string (per bundle.go: the coarse class/region at
# the typed level, the dialable detail opaquely in Link). All values are passed in already-resolved
# (the caller reuses the subscription's resolution) so there is ONE source of connection truth.
# myc_uri_encode VALUE -> VALUE percent-encoded per RFC-3986 (jq @uri): every character outside the
# unreserved set [A-Za-z0-9-_.~] becomes %XX. C07: applied to every DYNAMIC value spliced into a Link
# so a value like "/api?x=1#frag" cannot shift the URI's ?/#/&/=/@/: boundaries. The structural
# delimiters of the URI itself (the literal scheme://, the @, the host:port colon, ?, &, =, #) are
# written by the printf template and are NEVER passed through this function, so they stay literal.
# render_aggregate.sh's parser @uri-DECODES every parsed value, so the value round-trips exactly.
myc_uri_encode() {
	printf '%s' "$1" | jq -sRr '@uri'
}

myc_bundle_link() {
	# C34: arity guard — a positional-count mismatch must fail loud, not silently fall through to the
	# empty-default link (which would surface only as a downstream empty-Link die with no cause).
	[ "$#" -eq 16 ] || myc_die "myc_bundle_link: expected 16 args, got $# (see ARG ORDER above)."
	local proto server port uuid dsni pub sid tsni sspw hy2pw trpw tuicpw grpc xpath xpath_tls ws_path frag
	proto="$1"; server="$2"; port="$3"; uuid="$4"; dsni="$5"; pub="$6"; sid="$7"; tsni="$8"
	sspw="$9"; hy2pw="${10}"; trpw="${11}"; tuicpw="${12}"; grpc="${13}"; xpath="${14}"; xpath_tls="${15}"; ws_path="${16}"
	frag="mycelium-${proto}"
	# C07: percent-encode every dynamic value before it is interpolated into the URI. server/port are
	# structural authority components (a hostname/integer port carry no reserved chars), so they are left
	# literal; every credential, SNI, key, path, service-name and the fragment is encoded. jq @uri turns
	# a trailing %0a into nothing here because jq -sRr keeps the raw bytes; the values never contain a
	# newline (params are single-line jq strings).
	uuid="$(myc_uri_encode "$uuid")"
	dsni="$(myc_uri_encode "$dsni")"
	pub="$(myc_uri_encode "$pub")"
	sid="$(myc_uri_encode "$sid")"
	tsni="$(myc_uri_encode "$tsni")"
	sspw="$(myc_uri_encode "$sspw")"
	hy2pw="$(myc_uri_encode "$hy2pw")"
	trpw="$(myc_uri_encode "$trpw")"
	tuicpw="$(myc_uri_encode "$tuicpw")"
	grpc="$(myc_uri_encode "$grpc")"
	xpath="$(myc_uri_encode "$xpath")"
	xpath_tls="$(myc_uri_encode "$xpath_tls")"
	ws_path="$(myc_uri_encode "$ws_path")"
	frag="$(myc_uri_encode "$frag")"
	case "$proto" in
		vless-reality-vision)
			printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
				"$uuid" "$server" "$port" "$dsni" "$pub" "$sid" "$frag" ;;
		vless-reality-grpc)
			printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=grpc&serviceName=%s#%s' \
				"$uuid" "$server" "$port" "$dsni" "$pub" "$sid" "$grpc" "$frag" ;;
		vless-reality-xhttp)
			printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%s#%s' \
				"$uuid" "$server" "$port" "$dsni" "$pub" "$sid" "$xpath" "$frag" ;;
		vless-xhttp-tls)
			# genuine single-layer TLS (own cert, verified — NO reality donor): security=tls, no pbk/sid.
			# C06: use the per-family path ($xpath_tls), NOT the REALITY-XHTTP path ($xpath), so the two
			# XHTTP families can carry distinct paths and are not path-correlatable by an on-path observer.
			printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2,http/1.1&type=xhttp&path=%s#%s' \
				"$uuid" "$server" "$port" "$tsni" "$xpath_tls" "$frag" ;;
		vless-ws-tls)
			# genuine single-layer TLS over native WebSocket (own cert, verified — NO reality donor):
			# security=tls, type=ws, no pbk/sid. alpn=http%2F1.1 (single ALPN, percent-encoded literal so
			# the '/' cannot shift the query boundaries). host carries the own-cert SNI ($tsni). path is the
			# per-family ws path ($ws_path), already percent-encoded above.
			printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s' \
				"$uuid" "$server" "$port" "$tsni" "$tsni" "$ws_path" "$frag" ;;
		hysteria2)
			printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3#%s' \
				"$hy2pw" "$server" "$port" "$tsni" "$frag" ;;
		tuic)
			printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr#%s' \
				"$uuid" "$tuicpw" "$server" "$port" "$tsni" "$frag" ;;
		shadowsocks)
			# ss://method:password@host:port (C07: password percent-encoded so a reserved char in the
			# secret cannot shift the @/: authority boundaries; the aggregate parser @uri-decodes it back).
			printf 'ss://2022-blake3-aes-256-gcm:%s@%s:%s#%s' \
				"$sspw" "$server" "$port" "$frag" ;;
		shadowtls)
			# ShadowTLS wraps Shadowsocks; the shareable hint carries the SS material + the TLS SNI it
			# masquerades behind. (Clients import the full sing-box config for the v3 handshake detour.)
			printf 'ss://2022-blake3-aes-256-gcm:%s@%s:%s?plugin=shadow-tls&sni=%s#%s' \
				"$sspw" "$server" "$port" "$tsni" "$frag" ;;
		trojan)
			printf 'trojan://%s@%s:%s?sni=%s&fp=chrome&alpn=h2,http/1.1&type=tcp#%s' \
				"$trpw" "$server" "$port" "$tsni" "$frag" ;;
		*)
			printf '' ;;
	esac
}

# ---------------------------------------------------------------------------
# render-bundle
# ---------------------------------------------------------------------------
#
# Emit ONE Bundle JSON (bundle.go shape) for the node: one Endpoint per enabled transport, in
# priority order. The node's distribution bundle is per-NODE, so the endpoint credential is the
# node's FIRST identity (a node with no identities cannot hand out a dialable endpoint).
#
# C30 — PER-NODE SCOPE (NOT a network map). This producer emits THIS ONE node's OWN subscription: the
# endpoints are this single node's enabled transports, dialing this node's address. It is the matured,
# self-replenishing form of the per-node hand-rendered subscription (RP-0007-b), and nothing more. It
# is NOT a network/topology map, NOT a cross-node aggregate, and carries NO node-id/issuer/signature — by
# design (bundle.go schema). The invariant is "every node serves its OWN bundle"; a served cross-node
# aggregator would be a forbidden topology centralisation + single point of block. The only place
# multiple nodes' bundles meet is the LOCAL, at-rest `aggregate` merge an operator runs over THEIR OWN
# nodes' bundles on THEIR OWN device (render_aggregate.sh) — never a network service. Read a bundle as
# "one node's endpoints", never as a view of the network.
#
# myc_render_bundle PARAMS_FILE STATE OUT
myc_render_bundle() {
	local params_file state out
	params_file="$1"; state="$2"; out="$3"

	[ -n "$params_file" ] || myc_die "bundle: --params is required"
	[ -n "$state" ]       || myc_die "bundle: --state is required"
	[ -n "$out" ]         || myc_die "bundle: --out is required"

	local params clients count
	params="$(myc_params_to_json "$params_file")"
	myc_state_init "$state"
	clients="$(myc_identity_clients_json "$state")"
	count="$(printf '%s' "$clients" | jq 'length')"
	# The bundle hands out a dialable endpoint; that requires a node identity to dial as. Fail-closed:
	# a bundle with zero usable endpoints would not pass Bundle.Validate (>=1 endpoint) anyway.
	[ "$count" -ge 1 ] || myc_die "bundle: identity state has zero clients; cannot render a dialable endpoint (add an identity first)."

	# C17/C18 fail-closed: if the node-local params carry a two_hop overlay, validate its SHAPE at
	# bundle-render too — the SAME fail-closed bar render_singbox.sh applies at server-render. The bundle
	# does not itself emit a two-hop endpoint, but a node whose params declare a malformed two_hop would
	# fail the server render while the bundle still advertised its (non-two-hop) endpoints — a producer
	# that emits a bundle for a config that cannot render is a CONFLICTING_SOURCE_OF_TRUTH. Catching the
	# malformed overlay here keeps the two producers consistent. An ABSENT two_hop is fine (feature off).
	local two_hop
	two_hop="$(printf '%s' "$params" | jq -c '.two_hop // empty' 2>/dev/null)"
	if [ -n "$two_hop" ]; then
		# Must be a JSON object with a non-empty via_user and a well-formed upstream (C17).
		printf '%s' "$two_hop" | jq -e 'type == "object"' >/dev/null 2>&1 \
			|| myc_die "bundle: params.two_hop is not an object (fail-closed; a two-hop overlay must be an object)."
		local th_via th_server th_sni th_port
		th_via="$(printf '%s' "$two_hop" | jq -r '.via_user // ""')"
		th_server="$(printf '%s' "$two_hop" | jq -r '.server // ""')"
		th_sni="$(printf '%s' "$two_hop" | jq -r '.sni // ""')"
		th_port="$(printf '%s' "$two_hop" | jq -r '.server_port // empty')"
		[ -n "$th_via" ]    || myc_die "bundle: params.two_hop.via_user is empty (fail-closed; a two-hop must name the designated client)."
		[ -n "$th_server" ] || myc_die "bundle: params.two_hop.server is empty (fail-closed; the upstream needs an address)."
		[ -n "$th_sni" ]    || myc_die "bundle: params.two_hop.sni is empty (fail-closed; the upstream TLS needs a server_name)."
		case "$th_port" in
			''|*[!0-9]*) myc_die "bundle: params.two_hop.server_port is not a positive integer ('$th_port'); must be 1..65535 (fail-closed)." ;;
		esac
		if [ "$th_port" -lt 1 ] || [ "$th_port" -gt 65535 ]; then
			myc_die "bundle: params.two_hop.server_port is out of range ('$th_port'); must be 1..65535 (fail-closed)."
		fi
		# C18: via_user must match an existing identity (clients[].name) or the auth_user route never matches.
		if ! printf '%s' "$clients" | jq -e --arg u "$th_via" 'any(.[]; .name == $u)' >/dev/null 2>&1; then
			myc_die "bundle: params.two_hop.via_user '$th_via' is not a known client (fail-closed; the server's auth_user route would never match this user)."
		fi
	fi

	local enabled
	enabled="$(myc_sb_enabled_list "$params")"
	[ -n "$enabled" ] || myc_die "bundle: no protocols enabled in params (set at least one <proto>_enabled: true)"
	myc_log "bundle: enabled transports: $enabled"

	# Coarse region bucket — opaque, never a precise location (bundle.go: region is a coarse bucket so
	# the bundle is not itself a precise-location map). Default "unspecified".
	local region
	region="$(myc_params_get "$params" '.region_bucket' 'unspecified')"

	# Connection coordinates — IDENTICAL resolution to the subscription path so the Link is the SAME
	# dialable config (one source of truth). The endpoint credential is the node's first identity.
	local node_addr donor_sni pub tls_sni short_first
	node_addr="$(myc_params_get "$params" '.node_address')"
	donor_sni="$(myc_params_get "$params" '.donor_sni' '')"
	pub="$(myc_params_get "$params" '.reality_public_key' '')"
	# tls_sni is the SNI the genuine-TLS (own-cert) families dial. It keeps the donor_sni/localhost
	# fallback HERE so the non-xhttp-tls own-cert families (hysteria2/tuic/trojan) resolve identically to
	# the subscription producer (render_singbox.sh) — the two producers of the same client config must
	# not diverge (CONFLICTING_SOURCE_OF_TRUTH). The xhttp-tls family is the ONE exception: it is
	# fail-closed below via a separate explicit-presence probe, never this fallback.
	tls_sni="$(myc_params_get "$params" '.tls_sni' "${donor_sni:-localhost}")"
	short_first="$(printf '%s' "$params" | jq -r '.short_ids[0] // empty')"

	# C03 fail-closed: the xhttp-tls (own-cert genuine-TLS) family REQUIRES its own tls_sni. Never fall
	# back to donor_sni/localhost for it — that would present a cert for the node's own domain while the
	# share-link claims the donor SNI, a DISTINGUISHABLE_TRANSPORT cert/SNI-mismatch tell on a probe.
	# Probe the param's EXPLICIT presence (a separate read, so the donor fallback in `tls_sni` above does
	# not mask a missing value); refuse rather than emit a mismatched Link.
	case " $enabled " in
		*" vless-xhttp-tls "*|*" vless-ws-tls "*)
			local _tls_sni_explicit; _tls_sni_explicit="$(myc_params_get "$params" '.tls_sni' '')"
			[ -n "$_tls_sni_explicit" ] || myc_die "bundle: an own-cert genuine-TLS family (vless-xhttp-tls/vless-ws-tls) is enabled but params.tls_sni is empty — the own-cert family must carry its OWN SNI (never fall back to donor_sni; that is a cert/SNI mismatch tell). Set params.tls_sni." ;;
	esac

	local ss_password trojan_password hysteria2_password shadowtls_password grpc_service xhttp_path xhttp_path_tls ws_path
	ss_password="$(myc_params_get "$params" '.ss_password' '')"
	trojan_password="$(myc_params_get "$params" '.trojan_password' '')"
	hysteria2_password="$(myc_params_get "$params" '.hysteria2_password' '')"
	shadowtls_password="$(myc_params_get "$params" '.shadowtls_password' '')"
	grpc_service="$(myc_params_get "$params" '.grpc_service_name' 'grpc')"
	xhttp_path="$(myc_params_get "$params" '.xhttp_path' '/')"
	# C06 INVARIANT: the REALITY-XHTTP family (xhttp_path) and the genuine-TLS xhttp-tls family
	# (xhttp_path_tls) MUST be able to carry DISTINCT paths so an on-path observer cannot correlate the
	# two "independent" families by an identical plaintext path. xhttp_path_tls defaults to xhttp_path
	# only when unset (back-compat); an operator running both XHTTP families should set them apart.
	xhttp_path_tls="$(myc_params_get "$params" '.xhttp_path_tls' "$xhttp_path")"
	# vless-ws-tls dials $ws_path (native WebSocket; default "/ws"). Its own per-family path so the ws-tls
	# endpoint is not path-correlatable with the XHTTP families. MUST match render_singbox.sh's resolution
	# so the served inbound and the bundle Link agree.
	ws_path="$(myc_params_get "$params" '.ws_path' '/ws')"

	# The node identity used as the endpoint credential (first client).
	local id ipw
	id="$(printf '%s' "$clients" | jq -r '.[0].id // ""')"
	ipw="$(printf '%s' "$clients" | jq -r '.[0].password // ""')"
	# N4 fail-closed: an empty/null first-client id would splice into the Link as `vless://@server:port`
	# — a non-dialable endpoint that still passes the non-empty-Link check and Bundle.Validate (Link is
	# non-empty). Refuse before building any link so a malformed identity can never produce a
	# valid-looking but undialable bundle.
	[ -n "$id" ] || myc_die "bundle: first identity has an empty id (clients[0].id) — cannot build a dialable endpoint credential. Re-add the identity with a valid UUID."

	# Per-identity password falls back to the shared protocol secret (subscription parity).
	local hy2_pw ss_pw stls_pw trojan_pw tuic_pw
	hy2_pw="${ipw:-$hysteria2_password}"
	ss_pw="${ipw:-$ss_password}"
	stls_pw="${ipw:-$shadowtls_password}"
	trojan_pw="${ipw:-$trojan_password}"
	tuic_pw="${ipw:-$id}"

	# Per-protocol ports (MUST match the server render + subscription defaults — phase0 port canon).
	local p_vision p_grpc p_xhttp p_xhttp_tls p_ws_tls p_hy2 p_tuic p_ss p_stls p_trojan
	p_vision="$(myc_params_get "$params" '.vless_reality_vision_port' '443')"
	p_grpc="$(myc_params_get "$params"   '.vless_reality_grpc_port'   '8443')"
	p_xhttp="$(myc_params_get "$params"  '.vless_reality_xhttp_port'  '2096')"
	p_xhttp_tls="$(myc_params_get "$params" '.vless_xhttp_tls_port'   '2087')"
	p_ws_tls="$(myc_params_get "$params"  '.vless_ws_tls_port'        '2089')"
	p_hy2="$(myc_params_get "$params"    '.hysteria2_port'            '8444')"
	p_tuic="$(myc_params_get "$params"   '.tuic_port'                 '8445')"
	p_ss="$(myc_params_get "$params"     '.shadowsocks_port'          '8388')"
	p_stls="$(myc_params_get "$params"   '.shadowtls_port'            '8446')"
	p_trojan="$(myc_params_get "$params" '.trojan_port'               '8447')"

	myc_bundle_port_of() {
		case "$1" in
			vless-reality-vision) printf '%s' "$p_vision" ;;
			vless-reality-grpc)   printf '%s' "$p_grpc" ;;
			vless-reality-xhttp)  printf '%s' "$p_xhttp" ;;
			vless-xhttp-tls)      printf '%s' "$p_xhttp_tls" ;;
			vless-ws-tls)         printf '%s' "$p_ws_tls" ;;
			hysteria2)            printf '%s' "$p_hy2" ;;
			tuic)                 printf '%s' "$p_tuic" ;;
			shadowsocks)          printf '%s' "$p_ss" ;;
			shadowtls)            printf '%s' "$p_stls" ;;
			trojan)               printf '%s' "$p_trojan" ;;
			*)                    printf '' ;;
		esac
	}

	# Build the endpoints array one Endpoint at a time, appending each as a compact JSON object via jq
	# (every dynamic value flows through --arg/--argjson — nothing is string-spliced into the filter).
	local endpoints_json proto class prio port link
	endpoints_json='[]'
	for proto in $enabled; do
		class="$(myc_bundle_class_of "$proto")"
		if [ -z "$class" ]; then
			myc_die "bundle: protocol '$proto' has no transport class mapping (add it to myc_bundle_class_of)."
		fi
		prio="$(myc_bundle_priority_of "$proto")"
		port="$(myc_bundle_port_of "$proto")"
		[ -n "$port" ] || myc_die "bundle: no port resolved for protocol '$proto'."
		# C09 fail-closed: a port MUST be an integer in 1..65535. A missing/non-numeric/out-of-range port
		# would otherwise be spliced raw into the Link (e.g. server:0), producing a non-dialable endpoint
		# that still passes the non-empty checks. Refuse it here rather than emit an invalid port.
		case "$port" in
			''|*[!0-9]*) myc_die "bundle: port for protocol '$proto' is not a positive integer ('$port'); a server_port must be in 1..65535." ;;
		esac
		if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
			myc_die "bundle: port for protocol '$proto' is out of range ('$port'); a server_port must be in 1..65535."
		fi
		link="$(myc_bundle_link "$proto" "$node_addr" "$port" "$id" "$donor_sni" "$pub" "$short_first" \
			"$tls_sni" "$ss_pw" "$hy2_pw" "$trojan_pw" "$tuic_pw" "$grpc_service" "$xhttp_path" "$xhttp_path_tls" "$ws_path")"
		[ -n "$link" ] || myc_die "bundle: produced an empty Link for protocol '$proto' (bundle.go rejects empty links)."

		# Endpoint fields EXACTLY per bundle.go: tag, transport_class, region, priority, health, link.
		# health is hard-pinned to "unknown" (Phase-1 invariant; Bundle.Validate rejects anything else).
		endpoints_json="$(printf '%s' "$endpoints_json" | jq -c \
			--arg tag "mycelium-${proto}" \
			--arg class "$class" \
			--arg region "$region" \
			--argjson prio "$prio" \
			--arg link "$link" \
			'. + [{
				tag: $tag,
				transport_class: $class,
				region: $region,
				priority: $prio,
				health: "unknown",
				link: $link
			}]')"
	done

	# Top-level Bundle: version (NetworkStateVersion), endpoints[], generated_at (RFC-3339 UTC).
	local generated_at bundle
	generated_at="$(myc_now_utc)"
	bundle="$(jq -nc \
		--argjson version "$MYC_BUNDLE_VERSION" \
		--argjson endpoints "$endpoints_json" \
		--arg generated_at "$generated_at" \
		'{ version: $version, endpoints: $endpoints, generated_at: $generated_at }')"

	if [ -z "$bundle" ] || ! printf '%s' "$bundle" | jq -e . >/dev/null 2>&1; then
		myc_die "bundle: rendering produced invalid JSON (internal error)."
	fi
	# Structural fail-closed (mirrors Bundle.Validate's coarse shape checks; the authoritative
	# round-trip is Go-side on a node): >=1 endpoint, every health unknown, every link non-empty,
	# every class in the closed vocab.
	if [ "$(printf '%s' "$bundle" | jq '.endpoints | length')" -lt 1 ]; then
		myc_die "bundle: zero endpoints rendered (Bundle.Validate requires >=1)."
	fi
	if ! printf '%s' "$bundle" | jq -e '.endpoints | all(.health == "unknown")' >/dev/null 2>&1; then
		myc_die "bundle: a non-unknown health label leaked (Phase-1 invariant; Bundle.Validate rejects it)."
	fi
	if ! printf '%s' "$bundle" | jq -e '.endpoints | all((.link | length) > 0)' >/dev/null 2>&1; then
		myc_die "bundle: an empty Link leaked (bundle.go rejects empty links)."
	fi
	# The closed transport-class vocabulary is the Go-owned list in MYC_VOCAB (.transport_classes),
	# not an inline copy: every endpoint's class must be a member (RP-0008 P2).
	myc_vocab_load
	local _vtc
	_vtc="$(jq -c '.transport_classes' "$MYC_VOCAB" 2>/dev/null)"
	[ -n "$_vtc" ] || myc_die "render-bundle: could not read .transport_classes from $MYC_VOCAB."
	if ! printf '%s' "$bundle" | jq -e --argjson v "$_vtc" \
		'.endpoints | all((.transport_class) as $tc | ($v | index($tc)) != null)' >/dev/null 2>&1; then
		myc_die "bundle: a transport_class outside the closed vocab leaked."
	fi

	printf '%s\n' "$bundle" | jq . | myc_atomic_write "$out"
	myc_assert_json "$out" "rendered bundle"
	myc_log "wrote bundle: $out ($(printf '%s' "$bundle" | jq '.endpoints | length') endpoint(s), version $MYC_BUNDLE_VERSION)"
}
