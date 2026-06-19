# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render.sh — rendering of the dataplane server config and per-client subscriptions.
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl. Depends on common.sh, jqlib.sh, identity.sh.
#
# This is the single rendering engine for Phase 0: it takes (1) the dataplane
# VLESS+REALITY server template, (2) a params file with deploy-time values, and
# (3) the identity state, and produces concrete configs by editing JSON BY PATH
# with jq. No secret material is invented here — it is read from params/state.

# ---------------------------------------------------------------------------
# render-server
# ---------------------------------------------------------------------------
#
# Sets, by jq path, on the first VLESS inbound found in the template:
#   .inbounds[I].port                                            <- listen_port
#   .inbounds[I].settings.clients                                <- from state,
#        each { id, email:name, flow:"xtls-rprx-vision" }
#   .inbounds[I].streamSettings.realitySettings.privateKey       <- reality_private_key
#   .inbounds[I].streamSettings.realitySettings.shortIds         <- short_ids[]
#   .inbounds[I].streamSettings.realitySettings.serverNames      <- [donor_sni]
#   .inbounds[I].streamSettings.realitySettings.dest             <- donor_host:443
#
# The result is validated as JSON and written to --out (a gitignored path).

# myc_render_server TEMPLATE PARAMS_FILE STATE OUT
myc_render_server() {
	local template params_file state out
	template="$1"; params_file="$2"; state="$3"; out="$4"

	[ -n "$template" ] || myc_die "render-server: --template is required"
	[ -n "$params_file" ] || myc_die "render-server: --params is required"
	[ -n "$state" ]    || myc_die "render-server: --state is required"
	[ -n "$out" ]      || myc_die "render-server: --out is required"

	myc_assert_json "$template" "template"

	local params clients
	params="$(myc_params_to_json "$params_file")"
	myc_state_init "$state"
	clients="$(myc_identity_clients_json "$state")"

	if [ "$(printf '%s' "$clients" | jq 'length')" -eq 0 ]; then
		myc_warn "render-server: identity state has zero clients; the inbound will accept no one"
	fi

	# Pull deploy-time values from params (fail fast on missing required ones).
	local priv listen_port donor_sni donor_host dest
	priv="$(myc_params_get "$params" '.reality_private_key')"
	listen_port="$(myc_params_get "$params" '.listen_port' '443')"
	donor_sni="$(myc_params_get "$params" '.donor_sni')"
	donor_host="$(myc_params_get "$params" '.donor_host')"
	# REALITY dest defaults to the donor host on 443 unless params override it.
	dest="$(myc_params_get "$params" '.dest' "${donor_host}:443")"

	# shortIds: array in params. Required and non-empty (active probing needs at
	# least one valid shortId; "" empty-shortId acceptance is a deliberate policy
	# choice we do not enable by default).
	local short_ids_json
	short_ids_json="$(printf '%s' "$params" | jq -c '.short_ids // []')"
	if [ "$(printf '%s' "$short_ids_json" | jq 'length')" -eq 0 ]; then
		myc_die "render-server: params.short_ids must contain at least one shortId"
	fi

	# Locate the VLESS inbound index in the template.
	local idx
	idx="$(jq -r '
		[.inbounds // [] | to_entries[]
		 | select(.value.protocol == "vless")][0].key // empty
	' "$template")"
	if [ -z "$idx" ]; then
		myc_die "render-server: template has no inbound with protocol \"vless\": $template"
	fi

	# Build the clients array in Xray inbound shape from identity state.
	# Xray uses .email as the human label; flow is XTLS-Vision for every client.
	local xray_clients
	xray_clients="$(printf '%s' "$clients" | jq -c '
		map({ id: .id, email: .name, flow: "xtls-rprx-vision" })
	')"

	# Render by jq path. We feed every dynamic value through --arg/--argjson so
	# nothing is string-spliced into the filter.
	local rendered
	rendered="$(jq \
		--argjson i "$idx" \
		--argjson port "$listen_port" \
		--arg priv "$priv" \
		--argjson shortids "$short_ids_json" \
		--arg sni "$donor_sni" \
		--arg dest "$dest" \
		--argjson clients "$xray_clients" \
		'
		.inbounds[$i].port = $port
		| .inbounds[$i].protocol = "vless"
		| .inbounds[$i].settings.clients = $clients
		| .inbounds[$i].settings.decryption = (.inbounds[$i].settings.decryption // "none")
		| .inbounds[$i].streamSettings.network = (.inbounds[$i].streamSettings.network // "tcp")
		| .inbounds[$i].streamSettings.security = "reality"
		| .inbounds[$i].streamSettings.realitySettings.show = (.inbounds[$i].streamSettings.realitySettings.show // false)
		| .inbounds[$i].streamSettings.realitySettings.dest = $dest
		| .inbounds[$i].streamSettings.realitySettings.serverNames = [$sni]
		| .inbounds[$i].streamSettings.realitySettings.privateKey = $priv
		| .inbounds[$i].streamSettings.realitySettings.shortIds = $shortids
		' "$template" 2>/dev/null)"

	if [ -z "$rendered" ] || ! printf '%s' "$rendered" | jq -e . >/dev/null 2>&1; then
		myc_die "render-server: rendering produced invalid JSON (check template shape)"
	fi

	printf '%s\n' "$rendered" | jq . | myc_atomic_write "$out"
	myc_assert_json "$out" "rendered server config"
	myc_log "wrote server config: $out (inbound index $idx, $(printf '%s' "$xray_clients" | jq 'length') client(s))"
}

# ---------------------------------------------------------------------------
# render-server (Xray engine, vless-xhttp-tls) — ADR-0032 prototype (P1)
# ---------------------------------------------------------------------------
#
# Renders the Xray-only transport `vless-xhttp-tls` (VLESS + XHTTP over genuine
# single-layer TLS, own certificate, NO REALITY — ADR-0010 transport #10) from a
# template + params + identity state, BY jq PATH. No secret material is invented
# here; the certificate/key paths and SNI come from params, the client ids from
# state. INERT prototype: this renders a config and is proven loadable by the
# `xray_engine_load_check` gate; it is not yet wired into a live apply (that is the
# follow-on RP per ADR-0032). Sets, on the first VLESS inbound:
#   .port                                            <- vless_xhttp_tls_port (def 2087)
#   .settings.clients                                <- from state, { id, email }
#        (NO flow: xtls-rprx-vision is a REALITY/TCP shape, not XHTTP)
#   .streamSettings.network                          <- "xhttp"
#   .streamSettings.security                         <- "tls"
#   .streamSettings.tlsSettings.serverName           <- tls_sni (own domain; C03)
#   .streamSettings.tlsSettings.certificates         <- [{certificateFile,keyFile}]
#   .streamSettings.xhttpSettings.path               <- xhttp_path_tls (def "/")

# myc_render_xray_xhttp_tls TEMPLATE PARAMS_FILE STATE OUT
myc_render_xray_xhttp_tls() {
	local template params_file state out
	template="$1"; params_file="$2"; state="$3"; out="$4"

	[ -n "$template" ] || myc_die "render-xray-xhttp-tls: TEMPLATE is required"
	[ -n "$params_file" ] || myc_die "render-xray-xhttp-tls: PARAMS is required"
	[ -n "$state" ]    || myc_die "render-xray-xhttp-tls: STATE is required"
	[ -n "$out" ]      || myc_die "render-xray-xhttp-tls: OUT is required"

	myc_assert_json "$template" "template"

	local params clients
	params="$(myc_params_to_json "$params_file")"
	myc_state_init "$state"
	clients="$(myc_identity_clients_json "$state")"
	if [ "$(printf '%s' "$clients" | jq 'length')" -eq 0 ]; then
		myc_warn "render-xray-xhttp-tls: identity state has zero clients; the inbound will accept no one"
	fi

	local port tls_sni tls_cert tls_key xhttp_path
	port="$(myc_params_get "$params" '.vless_xhttp_tls_port' '2087')"
	# C03 (own-cert genuine-TLS): vless-xhttp-tls presents the node's OWN certificate, so its serverName
	# MUST be the node's own domain — never the donor SNI / localhost fallback (that is a cert/SNI
	# mismatch active-probe tell). Require an explicit tls_sni, exactly as the sing-box own-cert path does.
	tls_sni="$(myc_params_get "$params" '.tls_sni')"
	[ -n "$tls_sni" ] || myc_die "render-xray-xhttp-tls: params.tls_sni is empty — the own-cert genuine-TLS family must carry its OWN SNI (never the donor_sni/localhost fallback; that is a cert/SNI-mismatch tell). Set params.tls_sni."
	tls_cert="$(myc_params_get "$params" '.tls_certificate_path' '/etc/mycelium/tls/fullchain.pem')"
	# Canonical param key is tls_key_path (the same one render_singbox.sh's own-cert path + write_params
	# emit); the earlier prototype read a non-canonical tls_private_key_path that write_params never sets,
	# so on a real node the key path silently fell back to the wrong default. Align to the single vocabulary.
	tls_key="$(myc_params_get "$params" '.tls_key_path' '/etc/mycelium/tls/privkey.pem')"
	xhttp_path="$(myc_params_get "$params" '.xhttp_path_tls' '/')"

	# Xray VLESS clients for XHTTP carry NO flow (xtls-rprx-vision is a REALITY/TCP shape).
	local xray_clients
	xray_clients="$(printf '%s' "$clients" | jq -c 'map({ id: .id, email: .name })')"

	local idx
	idx="$(jq -r '
		[.inbounds // [] | to_entries[]
		 | select(.value.protocol == "vless")][0].key // empty
	' "$template")"
	if [ -z "$idx" ]; then
		myc_die "render-xray-xhttp-tls: template has no inbound with protocol \"vless\": $template"
	fi

	local rendered
	rendered="$(jq \
		--argjson i "$idx" \
		--argjson port "$port" \
		--arg sni "$tls_sni" \
		--arg cert "$tls_cert" \
		--arg key "$tls_key" \
		--arg path "$xhttp_path" \
		--argjson clients "$xray_clients" \
		'
		.inbounds[$i].port = $port
		| .inbounds[$i].protocol = "vless"
		| .inbounds[$i].settings.clients = $clients
		| .inbounds[$i].settings.decryption = "none"
		| .inbounds[$i].streamSettings.network = "xhttp"
		| .inbounds[$i].streamSettings.security = "tls"
		| .inbounds[$i].streamSettings.tlsSettings.serverName = $sni
		| .inbounds[$i].streamSettings.tlsSettings.certificates = [{ certificateFile: $cert, keyFile: $key }]
		| .inbounds[$i].streamSettings.xhttpSettings.path = $path
		' "$template" 2>/dev/null)"

	if [ -z "$rendered" ] || ! printf '%s' "$rendered" | jq -e . >/dev/null 2>&1; then
		myc_die "render-xray-xhttp-tls: rendering produced invalid JSON (check template shape)"
	fi

	printf '%s\n' "$rendered" | jq . | myc_atomic_write "$out"
	myc_assert_json "$out" "rendered xray xhttp-tls config"
	myc_log "wrote xray xhttp-tls config: $out (inbound index $idx, $(printf '%s' "$xray_clients" | jq 'length') client(s))"
}

# ---------------------------------------------------------------------------
# subscription
# ---------------------------------------------------------------------------
#
# Emits, per client, two files into OUT_DIR:
#   <name>.singbox.json  — a sing-box outbound config (type "vless").
#   <name>.clash.yaml    — a single Clash-Meta proxy entry (under "proxies:").
#
# All connection parameters come from params/state — no secret invented here.
# Note: the REALITY *public* key (not the private key) goes to clients.

# myc_render_subscription PARAMS_FILE STATE OUT_DIR
myc_render_subscription() {
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

	# Connection parameters shared by every client config.
	local node_addr listen_port donor_sni pub short_first
	node_addr="$(myc_params_get "$params" '.node_address')"
	listen_port="$(myc_params_get "$params" '.listen_port' '443')"
	donor_sni="$(myc_params_get "$params" '.donor_sni')"
	pub="$(myc_params_get "$params" '.reality_public_key')"
	# Clients present a single shortId; use the first from the pool.
	short_first="$(printf '%s' "$params" | jq -r '.short_ids[0] // empty')"
	[ -n "$short_first" ] || myc_die "subscription: params.short_ids must contain at least one shortId"

	myc_mkdir_p "$out_dir"

	# Iterate clients. We read name+id as TSV and render each file with jq/printf.
	printf '%s' "$clients" | jq -r '.[] | [.name, .id] | @tsv' \
		| while IFS="$(printf '\t')" read -r name id; do
			[ -n "$name" ] || continue
			local safe sb_path clash_path
			# Sanitize the name for use as a filename (keep it boring & portable).
			safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
			sb_path="${out_dir}/${safe}.singbox.json"
			clash_path="${out_dir}/${safe}.clash.yaml"

			# --- sing-box outbound (type "vless") ---
			jq -n \
				--arg tag "mycelium-${name}" \
				--arg server "$node_addr" \
				--argjson port "$listen_port" \
				--arg uuid "$id" \
				--arg sni "$donor_sni" \
				--arg pub "$pub" \
				--arg sid "$short_first" \
				'{
					outbounds: [
						{
							type: "vless",
							tag: $tag,
							server: $server,
							server_port: $port,
							uuid: $uuid,
							flow: "xtls-rprx-vision",
							packet_encoding: "xudp",
							tls: {
								enabled: true,
								server_name: $sni,
								utls: { enabled: true, fingerprint: "chrome" },
								reality: {
									enabled: true,
									public_key: $pub,
									short_id: $sid
								}
							}
						}
					]
				}' | myc_atomic_write "$sb_path"
			myc_assert_json "$sb_path" "sing-box config for $name"

			# --- Clash-Meta proxy entry (YAML) ---
			# Hand-emitted YAML (jq has no YAML output); values are quoted so any
			# special characters are inert. This is a single proxy under "proxies:".
			{
				printf '# Copyright © 2026 mindicator & silicon bags quartet.\n'
				printf '# SPDX-License-Identifier: AGPL-3.0-or-later\n'
				printf '# This file is part of Mycelium, licensed under the GNU Affero General Public\n'
				printf '# License v3.0 or later. See the LICENSE file in the repository root.\n'
				printf '#\n'
				printf '# Clash-Meta proxy entry for client "%s". Generated by myceliumctl.\n' "$name"
				printf '# Merge this entry into your Clash-Meta config under the top-level "proxies:" key.\n'
				printf 'proxies:\n'
				printf '  - name: "mycelium-%s"\n' "$name"
				printf '    type: vless\n'
				printf '    server: "%s"\n' "$node_addr"
				printf '    port: %s\n' "$listen_port"
				printf '    uuid: "%s"\n' "$id"
				printf '    network: tcp\n'
				printf '    udp: true\n'
				printf '    flow: xtls-rprx-vision\n'
				printf '    tls: true\n'
				printf '    servername: "%s"\n' "$donor_sni"
				printf '    client-fingerprint: chrome\n'
				printf '    reality-opts:\n'
				printf '      public-key: "%s"\n' "$pub"
				printf '      short-id: "%s"\n' "$short_first"
			} | myc_atomic_write "$clash_path"

			myc_log "wrote subscription for '$name': $sb_path, $clash_path"
		done
}
