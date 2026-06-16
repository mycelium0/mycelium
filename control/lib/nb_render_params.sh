# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_render_params.sh — node-bootstrap library: build params.json (the FLAT render schema) from the
# LOCAL identity + canonical port map, plus the C19 operator-override seed/merge and the two-hop
# egress overlay merge.
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: turn the node's LOCAL identity + the canonical port map into the flat
# params.json the renderer consumes, while (C19) preserving operator-set transport toggles across
# every --update (seed + merge a closed allowlist of operator-settable keys ON TOP of the regenerated
# identity-derived defaults) and (ADR-0029) merging a node-local two_hop egress overlay fail-closed.
# CLASSIFICATION: CONTROL-LOGIC — this is the operator-override allowlist + two-hop-merge decision
# logic the audit named C19; it is EARMARKED for the RP-0008 Go migration (internal/spec), where the
# typed params contract will own the override allowlist and the overlay merge. Until then it stays
# bash, byte-identical. This file is meant to be SOURCED into scripts/node-bootstrap.sh, never
# executed directly; it defines functions + their dedicated constants only and relies on the
# entrypoint's shared globals (STATE_DIR, PARAMS_JSON, IDENTITY_SECRETS, IDENTITIES_JSON, TLS_DIR,
# NODE_ADDRESS, NODE_ADDRESS_PLACEHOLDER, DRY_RUN) and helpers (log/warn/die/have/need_root) being
# defined at call time. assert_two_hop_shape (still in the entrypoint; C3) is resolved at call time
# from the shared sourced scope. Behaviour is byte-identical to the inline definitions it replaced.

# C19: operator-set TOGGLE overrides, persisted SEPARATELY from identity-derived fields. write_params
# regenerates the identity-derived fields every run (keys/secrets/ports/paths from local identity), but
# an operator who turns a transport ON (e.g. setting the hysteria2 enable flag) must NOT have that
# silently reverted to default-OFF on the next --update. This 0600 file records ONLY the operator-settable
# toggles (the *_enable* flags + the few operator-tunable knobs); it is merged ON TOP of the regenerated
# defaults so an operator enablement survives every re-render. Local-only / gitignored; absent on a node
# whose operator never overrode anything (then defaults apply, byte-identically to today).
OPERATOR_OVERRIDES="$STATE_DIR/operator-overrides.json"

# ---------------------------------------------------------------------------
# Build params.json (the FLAT render schema) from LOCAL identity + canonical port map.
# Ports come from the canonical map (PORTS.md / renderer defaults), NOT from params.example.json
# (whose port values drift — see the map-phase notes).
# ---------------------------------------------------------------------------
# resolve_node_address — echo this node's OWN reachable address for client subscriptions.
# Order: explicit --node-address > a previously stored value > best-effort auto-detect of the
# primary public/global address > the documented loud placeholder. The chosen value is LOCAL-ONLY
# (params.json, 0600) — a real IP/host is NEVER committed (the placeholder is the only committed
# default, and it is non-functional by design).
resolve_node_address() {
	if [ -n "$NODE_ADDRESS" ]; then printf '%s\n' "$NODE_ADDRESS"; return 0; fi
	# Reuse a value already recorded in params.json across re-runs (idempotent; respects an operator
	# who set a real address once).
	if [ -f "$PARAMS_JSON" ] && have jq; then
		local prev
		prev="$(jq -r '.node_address // empty' "$PARAMS_JSON" 2>/dev/null)"
		if [ -n "$prev" ] && [ "$prev" != "$NODE_ADDRESS_PLACEHOLDER" ]; then
			printf '%s\n' "$prev"; return 0
		fi
	fi
	# Best-effort auto-detect of the primary GLOBAL-scope address (no external service contacted).
	local addr=""
	if have ip; then
		addr="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
		[ -n "$addr" ] || addr="$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
	fi
	if [ -n "$addr" ]; then printf '%s\n' "$addr"; return 0; fi
	# Fail-closed fallback: the documented placeholder, with a loud warning at the call site.
	printf '%s\n' "$NODE_ADDRESS_PLACEHOLDER"
	return 0
}

# ---------------------------------------------------------------------------
# OPERATOR-TOGGLE OVERRIDES (C19 defect 2). write_params regenerates the FLAT params from the LOCAL
# identity + canonical ports every run, so any operator-set toggle (e.g. enabling a transport) would be
# silently reverted to its default on each --update. To preserve operator intent WITHOUT making the
# whole params file operator-owned (the keys/secrets/ports MUST stay identity-derived + canonical), we
# persist ONLY the operator-settable toggle subset in a dedicated 0600 overrides file and merge it ON
# TOP of the regenerated defaults.
#
# OPERATOR_TOGGLE_KEYS is the closed allowlist of keys an operator may override (the *_enabled flags +
# the handful of operator-tunable knobs). Identity-derived fields (keys, secrets, node_address, cert
# paths, short_ids) are DELIBERATELY excluded so they can never be pinned stale by an override.
OPERATOR_TOGGLE_KEYS='[
	"vless_reality_vision_enabled","vless_reality_grpc_enabled","vless_reality_xhttp_enabled",
	"vless_xhttp_tls_enabled","vless_ws_tls_enabled","hysteria2_enabled","tuic_enabled","shadowsocks_enabled",
	"shadowtls_enabled","trojan_enabled",
	"vless_reality_vision_port","vless_reality_grpc_port","vless_reality_xhttp_port",
	"vless_xhttp_tls_port","vless_ws_tls_port","hysteria2_port","tuic_port","shadowsocks_port","shadowtls_port",
	"trojan_port","xhttp_path","xhttp_path_tls","ws_path","grpc_service_name","region_bucket"
]'

# seed_operator_overrides DEFAULTS_FILE — on the FIRST write under this logic (no overrides file yet),
# capture any operator toggles that DIFFER from the freshly-generated defaults from the PRIOR params.json
# (so an operator who enabled a transport before this change is not reverted on the upgrade). If there is
# no prior params or nothing differs, write an empty {} so subsequent reads are stable. Idempotent.
seed_operator_overrides() {
	local defaults_file="$1"
	[ -f "$OPERATOR_OVERRIDES" ] && return 0
	local seeded='{}'
	if [ -f "$PARAMS_JSON" ]; then
		# Keep only allowlisted keys whose PRIOR value differs from the freshly-generated default.
		seeded="$(jq -n \
			--slurpfile prev "$PARAMS_JSON" \
			--slurpfile def "$defaults_file" \
			--argjson keys "$OPERATOR_TOGGLE_KEYS" \
			'($prev[0] // {}) as $p | ($def[0] // {}) as $d
			 | reduce $keys[] as $k ({};
				 if ($p|has($k)) and ($p[$k] != $d[$k]) then . + { ($k): $p[$k] } else . end)' \
			2>/dev/null || printf '{}')"
		[ -n "$seeded" ] || seeded='{}'
	fi
	( umask 077; printf '%s\n' "$seeded" | jq . >"$OPERATOR_OVERRIDES" ) \
		|| die "could not write operator overrides file $OPERATOR_OVERRIDES (fail-closed)."
	if [ "$seeded" != '{}' ]; then
		log "operator overrides seeded from prior params (preserving operator-set toggles across --update): $OPERATOR_OVERRIDES"
	fi
}

# merge_operator_overrides DEFAULTS_FILE — merge the persisted operator toggles ON TOP of the freshly
# generated defaults, in place. Only allowlisted keys are honoured (a stray key in the overrides file is
# IGNORED, never injected), so the overrides file can never smuggle an identity-derived field.
merge_operator_overrides() {
	local defaults_file="$1"
	[ -f "$OPERATOR_OVERRIDES" ] || return 0
	jq -e 'type == "object"' "$OPERATOR_OVERRIDES" >/dev/null 2>&1 \
		|| die "operator overrides file $OPERATOR_OVERRIDES is not a JSON object (fail-closed; fix or remove it)."
	local merged
	merged="$(jq -n \
		--slurpfile def "$defaults_file" \
		--slurpfile ovr "$OPERATOR_OVERRIDES" \
		--argjson keys "$OPERATOR_TOGGLE_KEYS" \
		'($def[0] // {}) as $d | ($ovr[0] // {}) as $o
		 | reduce $keys[] as $k ($d;
			 if ($o|has($k)) then . + { ($k): $o[$k] } else . end)' \
		2>/dev/null)" \
		|| die "could not merge operator overrides into params (fail-closed)."
	[ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1 \
		|| die "operator-override merge produced invalid JSON (fail-closed)."
	printf '%s\n' "$merged" >"$defaults_file"
	log "params: applied operator-set toggle overrides on top of regenerated defaults (C19: operator enablement preserved across --update)."
}

write_params() {
	log "writing params.json (local-only render input) from node identity + canonical ports"
	need_root
	have jq || die "jq required to write params."
	[ -f "$IDENTITY_SECRETS" ] || die "node secrets missing; run identity step first."
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would write $PARAMS_JSON"; return 0; fi

	# Resolve this node's own reachable address for subscriptions (NEVER hardcoded to the placeholder).
	local node_address
	node_address="$(resolve_node_address)"
	if [ "$node_address" = "$NODE_ADDRESS_PLACEHOLDER" ]; then
		warn "node_address is the placeholder '$NODE_ADDRESS_PLACEHOLDER': generated client"
		warn "subscriptions will NOT connect. Set the real value with --node-address ADDR (or fix"
		warn "auto-detection) before generating subscriptions from this node's params.json."
	else
		log "recording node_address for subscriptions (local-only): $node_address"
	fi

	local s priv pub sid donor ss tj hy st
	s="$(cat "$IDENTITY_SECRETS")"
	priv="$(printf '%s' "$s" | jq -r '.reality.private_key')"
	pub="$(printf '%s'  "$s" | jq -r '.reality.public_key')"
	sid="$(printf '%s'  "$s" | jq -r '.reality.short_id')"
	donor="$(printf '%s' "$s" | jq -r '.donor.host')"
	ss="$(printf '%s'   "$s" | jq -r '.secrets.ss_password')"
	tj="$(printf '%s'   "$s" | jq -r '.secrets.trojan_password')"
	hy="$(printf '%s'   "$s" | jq -r '.secrets.hysteria2_password')"
	st="$(printf '%s'   "$s" | jq -r '.secrets.shadowtls_password')"
	# // "" so a legacy identity.json without clash_secret yields EMPTY (not the string "null"):
	# write_params then renders clash_api WITHOUT a secret, byte-identical to today (no-op update).
	clash="$(printf '%s' "$s" | jq -r '.secrets.clash_secret // ""')"

	# DEFAULT-ON SET (friends alpha, "Variant A" — recorded in ADR-0022 + THREAT-MODEL port posture):
	# the two certless REALITY transports — VLESS+REALITY+XTLS-Vision (443) and VLESS+REALITY+gRPC
	# (8443). NOTE: gRPC is the SAME reality-tls-tcp FAMILY as Vision (not a second independent family
	# for D2 — AmneziaWG/UDP is, ADR-0020 §5); it is a second always-on port for client failover, and
	# the only default-on set above single-443. This live default differs from the conservative
	# group_vars/Ansible default (Vision only) by design; pinned by
	# tests/conformance/live_artifact_posture.sh so it cannot silently grow. Everything else = OFF.
	#
	# HY2/TUIC are DEFAULT-OFF here, even though they are part of the broader canonical set, because
	# they present a per-node SELF-SIGNED cert (ADR-0014) that the client MUST verify via a SHA-256
	# cert pin. The client/subscription renderer does not yet EMIT that pin, and blanket
	# `insecure: true` trust is FORBIDDEN (ADR-0014 — it would accept any certificate / MITM-open).
	# So shipping HY2/TUIC on by default would yield clients that either cannot connect or only
	# connect insecurely. Re-enabling them requires the cert-pin client path (tracked follow-up);
	# until then keep them OFF. An operator can still override per node (the toggles below + the
	# firewall/render pipeline honour whatever is set here).
	local tmp
	tmp="$(mktemp "${STATE_DIR}/.params.XXXXXX")"
	jq -n \
		--arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg donor "$donor" \
		--arg ss "$ss" --arg tj "$tj" --arg hy "$hy" --arg st "$st" \
		--arg clash "$clash" \
		--arg node_address "$node_address" \
		--arg tls_cert "$TLS_DIR/fullchain.pem" --arg tls_key "$TLS_DIR/privkey.pem" \
		'{
			node_address: $node_address,
			donor_host: $donor, donor_sni: $donor,
			reality_private_key: $priv, reality_public_key: $pub,
			short_ids: [ $sid ],
			tls_sni: $donor,
			tls_certificate_path: $tls_cert, tls_key_path: $tls_key,
			grpc_service_name: "grpc.health.v1.Health",
			xhttp_path: "/",
			shadowtls_handshake_server: $donor, shadowtls_handshake_port: 443,
			ss_password: $ss, trojan_password: $tj, hysteria2_password: $hy, shadowtls_password: $st,
			clash_secret: $clash,

			vless_reality_vision_enabled: true,  vless_reality_vision_port: 443,
			vless_reality_grpc_enabled:   true,  vless_reality_grpc_port:   8443,
			vless_reality_xhttp_enabled:  false, vless_reality_xhttp_port:  2096,
			# vless-xhttp-tls: XHTTP over GENUINE single-layer TLS (own cert; NO reality). Default OFF
			# (fail-closed; rendered only when enabled). Canonical port 2087 (deliberately not 8443).
			vless_xhttp_tls_enabled:      false, vless_xhttp_tls_port:      2087,
			# vless-ws-tls: VLESS over native WebSocket over GENUINE single-layer TLS (own cert; NO reality).
			# Unlike xhttp-tls this IS servable on sing-box (native ws transport). Default OFF; canonical
			# port 2089 (deliberately not 8443). ws_path is the per-family WebSocket path (default "/ws").
			vless_ws_tls_enabled:         false, vless_ws_tls_port:         2089,
			ws_path: "/ws",
			# HY2/TUIC default OFF: need a client cert pin the renderer does not yet emit (ADR-0014).
			hysteria2_enabled:            false, hysteria2_port:            8444,
			tuic_enabled:                 false, tuic_port:                 8445,
			shadowsocks_enabled:          false, shadowsocks_port:          8388,
			shadowtls_enabled:            false, shadowtls_port:            8446,
			trojan_enabled:               false, trojan_port:               8447
		}' >"$tmp"
	# C19 (defect 2): preserve operator-set toggles across regeneration. The block above is the
	# identity-derived + canonical DEFAULT. seed_operator_overrides captures (once) any pre-existing
	# operator enablement from the prior params; merge_operator_overrides then re-applies the persisted
	# operator toggles ON TOP of these defaults so an enablement set on a previous run is NOT reverted by
	# this --update. Only the allowlisted toggle keys are honoured; identity-derived fields stay as
	# regenerated. A node whose operator never overrode anything keeps an empty {} and renders identically.
	seed_operator_overrides "$tmp"
	merge_operator_overrides "$tmp"
	# Optional two-hop egress overlay (ADR-0029): a node acting as an in-region INGRESS for an
	# out-of-region egress drops a local-only two_hop.json into STATE_DIR; merge it into params so the
	# renderer (render_singbox.sh) emits the upstream outbound + auth_user route. Node-local + never
	# committed -> survives the fetch/re-render cycle; absent on every other node -> params render
	# byte-identically (gated, zero blast radius). See render_singbox.sh `.two_hop` handling.
	#
	# C19 FAIL-CLOSED: an ABSENT two_hop.json means the feature is OFF (fine — every other node). But a
	# PRESENT-yet-malformed two_hop.json (invalid JSON, wrong shape, or empty via_user) is operator error
	# that MUST hard-fail here, never silently write params WITHOUT the overlay. Writing fail-OPEN would
	# diverge from render_singbox.sh (which is fail-CLOSED on the same overlay): params would advertise a
	# node with no egress while the operator believes the egress is live. So: present => it must be a
	# well-formed object with a non-empty via_user and a well-formed upstream, or we `die`.
	if [ -f "$STATE_DIR/two_hop.json" ]; then
		assert_two_hop_shape "$STATE_DIR/two_hop.json"
		if jq --slurpfile th "$STATE_DIR/two_hop.json" '.two_hop = $th[0]' "$tmp" >"$tmp.th"; then
			mv -f "$tmp.th" "$tmp"
			log "params: merged node-local two_hop egress overlay (ADR-0029 in-region ingress)."
		else
			rm -f "$tmp.th" "$tmp"
			die "two_hop.json is present but could not be merged into params (fail-closed; refusing to write params WITHOUT the operator's two-hop overlay). Fix or remove $STATE_DIR/two_hop.json (see --disable-two-hop)."
		fi
	fi
	mv -f "$tmp" "$PARAMS_JSON"; chmod 0600 "$PARAMS_JSON"
	# Mirror the clash secret to a 0600 file so the loopback data-plane stats exporter can authenticate
	# to clash_api (--clash-secret-file). Empty on legacy nodes: leave no file (the exporter then reads
	# the still-open loopback clash_api exactly as today).
	if [ -n "$clash" ] && [ "$DRY_RUN" -eq 0 ]; then
		( umask 077; printf '%s' "$clash" >"$STATE_DIR/clash.secret" )
	fi
	log "wrote $PARAMS_JSON (0600, local-only)."
}
