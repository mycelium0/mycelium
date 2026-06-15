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

# myc_bundle_class_of PROTO -> the closed-vocab transport CLASS for a protocol token, matching
# internal/spec/edgereport.go (TransportClass*) and tests/conformance family_of(). One family per
# protocol; the three vless-reality-* shapes collapse to the single reality-tcp family (same
# handshake surface — ADR-0010/0020), exactly as the spec taxonomy requires.
myc_bundle_class_of() {
	case "$1" in
		vless-reality-vision|vless-reality-grpc|vless-reality-xhttp) printf 'reality-tcp' ;;
		vless-xhttp-tls)                                            printf 'xhttp-tls' ;;
		hysteria2|tuic)                                             printf 'quic-udp' ;;
		shadowsocks)                                                printf 'shadowsocks-tcp' ;;
		shadowtls)                                                  printf 'shadowtls-tcp' ;;
		trojan)                                                     printf 'trojan-tls' ;;
		amneziawg)                                                  printf 'amneziawg-udp' ;;
		*)                                                          printf '' ;;
	esac
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
	printf '9999'
}

# myc_bundle_link PROTO SERVER PORT UUID DSNI PUB SID TSNI SSPW HY2PW TRPW TUICPW GRPC XPATH
# -> the per-endpoint dialable client config STRING (a share-link URI) for PROTO. This is the
# Bundle's opaque Link: the same connection coordinates the sing-box/Clash subscription dials,
# rendered as the standard scheme:// URI a client imports. Never empty for a known protocol.
#
# The node/port/SNI live ONLY inside this opaque string (per bundle.go: the coarse class/region at
# the typed level, the dialable detail opaquely in Link). All values are passed in already-resolved
# (the caller reuses the subscription's resolution) so there is ONE source of connection truth.
myc_bundle_link() {
	local proto server port uuid dsni pub sid tsni sspw hy2pw trpw tuicpw grpc xpath frag
	proto="$1"; server="$2"; port="$3"; uuid="$4"; dsni="$5"; pub="$6"; sid="$7"; tsni="$8"
	sspw="$9"; hy2pw="${10}"; trpw="${11}"; tuicpw="${12}"; grpc="${13}"; xpath="${14}"
	frag="mycelium-${proto}"
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
			printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2,http/1.1&type=xhttp&path=%s#%s' \
				"$uuid" "$server" "$port" "$tsni" "$xpath" "$frag" ;;
		hysteria2)
			printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3#%s' \
				"$hy2pw" "$server" "$port" "$tsni" "$frag" ;;
		tuic)
			printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr#%s' \
				"$uuid" "$tuicpw" "$server" "$port" "$tsni" "$frag" ;;
		shadowsocks)
			# ss://method:password@host:port (userinfo unencoded; sing-box/Clash accept this form).
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
	tls_sni="$(myc_params_get "$params" '.tls_sni' "${donor_sni:-localhost}")"
	short_first="$(printf '%s' "$params" | jq -r '.short_ids[0] // empty')"

	local ss_password trojan_password hysteria2_password shadowtls_password grpc_service xhttp_path
	ss_password="$(myc_params_get "$params" '.ss_password' '')"
	trojan_password="$(myc_params_get "$params" '.trojan_password' '')"
	hysteria2_password="$(myc_params_get "$params" '.hysteria2_password' '')"
	shadowtls_password="$(myc_params_get "$params" '.shadowtls_password' '')"
	grpc_service="$(myc_params_get "$params" '.grpc_service_name' 'grpc')"
	xhttp_path="$(myc_params_get "$params" '.xhttp_path' '/')"

	# The node identity used as the endpoint credential (first client).
	local id ipw
	id="$(printf '%s' "$clients" | jq -r '.[0].id')"
	ipw="$(printf '%s' "$clients" | jq -r '.[0].password // ""')"

	# Per-identity password falls back to the shared protocol secret (subscription parity).
	local hy2_pw ss_pw stls_pw trojan_pw tuic_pw
	hy2_pw="${ipw:-$hysteria2_password}"
	ss_pw="${ipw:-$ss_password}"
	stls_pw="${ipw:-$shadowtls_password}"
	trojan_pw="${ipw:-$trojan_password}"
	tuic_pw="${ipw:-$id}"

	# Per-protocol ports (MUST match the server render + subscription defaults — phase0 port canon).
	local p_vision p_grpc p_xhttp p_xhttp_tls p_hy2 p_tuic p_ss p_stls p_trojan
	p_vision="$(myc_params_get "$params" '.vless_reality_vision_port' '443')"
	p_grpc="$(myc_params_get "$params"   '.vless_reality_grpc_port'   '8443')"
	p_xhttp="$(myc_params_get "$params"  '.vless_reality_xhttp_port'  '2096')"
	p_xhttp_tls="$(myc_params_get "$params" '.vless_xhttp_tls_port'   '2087')"
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
		link="$(myc_bundle_link "$proto" "$node_addr" "$port" "$id" "$donor_sni" "$pub" "$short_first" \
			"$tls_sni" "$ss_pw" "$hy2_pw" "$trojan_pw" "$tuic_pw" "$grpc_service" "$xhttp_path")"
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
	if ! printf '%s' "$bundle" | jq -e '
		.endpoints | all(
			.transport_class == "reality-tcp" or .transport_class == "xhttp-tls"
			or .transport_class == "quic-udp" or .transport_class == "shadowsocks-tcp"
			or .transport_class == "shadowtls-tcp" or .transport_class == "trojan-tls"
			or .transport_class == "amneziawg-udp"
		)' >/dev/null 2>&1; then
		myc_die "bundle: a transport_class outside the closed vocab leaked."
	fi

	printf '%s\n' "$bundle" | jq . | myc_atomic_write "$out"
	myc_assert_json "$out" "rendered bundle"
	myc_log "wrote bundle: $out ($(printf '%s' "$bundle" | jq '.endpoints | length') endpoint(s), version $MYC_BUNDLE_VERSION)"
}
