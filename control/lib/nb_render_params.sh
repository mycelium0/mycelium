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
#
# RP-0008: this allowlist is GO-OWNED — internal/spec.OperatorToggleKeys() (the registry enable/port keys
# + the tunable knobs), emitted into control/vocab.json (.operator_toggle_keys). We READ it from there,
# the single source, rather than restating it (the same allowlist the auto-rotation executor validates
# against — one owner for two callers). Best-effort at source time; write_params fail-closes if it is
# empty on a real write. The committed vocab.json ships with control/ via install_tooling, and the
# two-tick update rule lands node-bootstrap + vocab.json together, so a real write always sees it.
OPERATOR_TOGGLE_KEYS="$(jq -ec '.operator_toggle_keys // empty' "${MYC_VOCAB:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/vocab.json}" 2>/dev/null || true)"

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
		# NB: the jq slurpfile var is `base`, NOT `def` — `def` is a jq KEYWORD, and jq 1.6 (still shipped
		# on some nodes) fails to parse `$def` ("unexpected def, expecting IDENT"), which silently broke
		# this merge on those nodes while newer jq (1.7+) tolerated it.
		seeded="$(jq -n \
			--slurpfile prev "$PARAMS_JSON" \
			--slurpfile base "$defaults_file" \
			--argjson keys "$OPERATOR_TOGGLE_KEYS" \
			'($prev[0] // {}) as $p | ($base[0] // {}) as $d
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
	# NB: the jq slurpfile var is `base`, NOT `def` — `def` is a jq KEYWORD; jq 1.6 fails to parse `$def`
	# ("unexpected def, expecting IDENT"), which silently failed this merge on jq-1.6 nodes (the update
	# died here every tick and rolled back) while jq 1.7+ accepted it. Keep all jq var names non-reserved.
	merged="$(jq -n \
		--slurpfile base "$defaults_file" \
		--slurpfile ovr "$OPERATOR_OVERRIDES" \
		--argjson keys "$OPERATOR_TOGGLE_KEYS" \
		'($base[0] // {}) as $d | ($ovr[0] // {}) as $o
		 | reduce $keys[] as $k ($d;
			 if ($o|has($k)) then . + { ($k): $o[$k] } else . end)' \
		2>/dev/null)" \
		|| die "could not merge operator overrides into params (fail-closed)."
	[ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1 \
		|| die "operator-override merge produced invalid JSON (fail-closed)."
	printf '%s\n' "$merged" >"$defaults_file"
	log "params: applied operator-set toggle overrides on top of regenerated defaults (C19: operator enablement preserved across --update)."
}

# node_profile_harden — echo the HOST-FIREWALL posture for this node: "on" or "off". Never dies; the
# firewall step's own guards fail closed on their own terms.
#
# THREE SOURCES, IN ORDER (Audit-0009 I1):
#   1. node.config.json `.harden` — the operator's DECLARED posture (Go: NodeProfile.Harden). Authoritative.
#   2. $STATE_DIR/harden.posture — the posture the last ATTENDED invocation was given on argv, remembered.
#   3. ON — today's default, and the fail-safe direction for a firewall.
#
# WHY NOT ARGV. converge_node_tail used to read `${DO_HARDEN:-1}`, which is set only from argv. That was
# coherent while the tail ran only under an operator's hand; the unattended timer then began calling it
# with no flags at all, and the default silently became the posture. A node deliberately bootstrapped
# `--no-harden` had ufw force-enabled on its first tick — every non-mycelium inbound service on that host
# blocked, anti-lockout preserving only SSH, and nothing recording that a posture decision had been
# overridden. A posture is node state; an invocation's argv is not.
node_profile_harden() {
	local cfg="$STATE_DIR/node.config.json" v
	if [ -f "$cfg" ] && have jq; then
		v="$(jq -r 'if has("harden") then (if (.harden|type)=="boolean" then (.harden|tostring) else "bad" end) else "absent" end' "$cfg" 2>/dev/null || printf 'absent')"
		case "$v" in
			true)  printf 'on';  return 0 ;;
			false) printf 'off'; return 0 ;;
			bad)   warn "node.config.json: .harden must be a JSON boolean; ignoring it and using the remembered posture." ;;
		esac
	fi
	if [ -f "$STATE_DIR/harden.posture" ]; then
		v="$(head -n 1 "$STATE_DIR/harden.posture" 2>/dev/null | tr -dc 'a-z')"
		case "$v" in on|off) printf '%s' "$v"; return 0 ;; esac
	fi
	printf 'on'
}

# remember_harden_posture — record the posture THIS invocation was given on argv, so an unattended tick
# can honour it later. Written only by flows that carry a coherent argv (bootstrap and the operator's
# --node-apply); the timer never writes it, because the timer has no posture to express.
remember_harden_posture() {
	[ "${DRY_RUN:-0}" -eq 0 ] || return 0
	# Callers that are not the establishing bootstrap pass "explicit-only": record nothing unless the
	# operator actually stated a posture on this command line.
	if [ "${1:-}" = "explicit-only" ] && [ "${HARDEN_EXPLICIT:-0}" -ne 1 ]; then return 0; fi
	[ -n "${STATE_DIR:-}" ] && [ -d "$STATE_DIR" ] || return 0
	if [ "${DO_HARDEN:-1}" -eq 1 ]; then printf 'on
'  >"$STATE_DIR/harden.posture" 2>/dev/null || true
	else                                 printf 'off
' >"$STATE_DIR/harden.posture" 2>/dev/null || true
	fi
	chmod 0644 "$STATE_DIR/harden.posture" 2>/dev/null || true
}

# apply_node_profile <params_tmp> — ADR-0034 / RP-0011 chunk B2: translate a node-local node.config.json
# descriptor's declared transports[] into params enable-key toggles and set them ON, additively on top of
# the defaults + operator overrides. The enable_key for each transport is looked up from the Go-owned
# vocab.json (never a restated "<proto>_enabled" naming rule) and is honoured ONLY if it is in the
# operator_toggle_keys allowlist (the same fail-closed discipline as merge_operator_overrides).
#
# ABSENT descriptor => no-op => params render BYTE-IDENTICALLY (every node that has not adopted a
# descriptor is unchanged; zero blast radius under auto-pull). READ-ONLY on the descriptor (it is
# operator-supplied; this never writes it). FAIL-CLOSED: a present-but-malformed descriptor, an unknown
# transport, or a non-allowlisted key hard-fails — we never silently write params that ignore the
# operator's declared profile.
apply_node_profile() {
	local tmp="$1"
	local cfg="$STATE_DIR/node.config.json"
	[ -f "$cfg" ] || return 0   # DEFAULT: no descriptor => unchanged (the byte-identical guard)
	local vocab="${MYC_VOCAB:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/vocab.json}"
	[ -f "$vocab" ] || die "node.config.json present but the Go-owned vocab.json is missing ($vocab)."
	jq -e 'type == "object"' "$cfg" >/dev/null 2>&1 \
		|| die "node.config.json present but not a JSON object (fail-closed; fix or remove $cfg)."
	# Reachability posture (RP-0011 chunk D / ADR-0034 §3): reachable:false -> stamp node_bind=127.0.0.1
	# so the renderer binds every PUBLIC inbound to loopback (the node is provisioned + converged but NOT
	# a public entry; harden_ufw then skips the loopback-bound ports). ABSENT/true -> stamp NOTHING -> the
	# renderer default "::" holds -> byte-identical. Read .reachable as a STRICT JSON boolean (parity with
	# Go ParseNodeProfile, which type-rejects a non-bool): a string "false"/number/etc. must hit the
	# fail-closed arm, not silently match a case. ABSENT key => "true" => default "::" holds.
	local reachable
	reachable="$(jq -r 'if has("reachable") then (if (.reachable|type)=="boolean" then (.reachable|tostring) else "not-a-boolean" end) else "true" end' "$cfg" 2>/dev/null)" \
		|| die "node.config.json: cannot read .reachable (fail-closed; fix or remove $cfg)."
	case "$reachable" in
		true) ;;
		false)
			if jq '.node_bind = "127.0.0.1"' "$tmp" >"$tmp.rb"; then
				mv -f "$tmp.rb" "$tmp"
				log "node.config.json: reachable=false -> public inbounds bind loopback (not a public entry)."
			else
				rm -f "$tmp.rb"; die "node.config.json: failed to set loopback bind for reachable=false."
			fi ;;
		*) die "node.config.json: .reachable must be a JSON boolean true or false (fix or remove $cfg)." ;;
	esac
	local transports
	transports="$(jq -r '(.transports // [])[]' "$cfg" 2>/dev/null)" \
		|| die "node.config.json: cannot read .transports (fail-closed; fix or remove $cfg)."
	if [ -n "$transports" ]; then
		local t key
		while IFS= read -r t; do
			[ -n "$t" ] || continue
			key="$(jq -r --arg t "$t" '.protos[] | select(.proto == $t) | .enable_key' "$vocab" 2>/dev/null)"
			[ -n "$key" ] && [ "$key" != "null" ] \
				|| die "node.config.json: transport '$t' is unknown or not operator-toggleable (no enable_key in the Go-owned vocab.json)."
			printf '%s' "$OPERATOR_TOGGLE_KEYS" | jq -e --arg k "$key" 'index($k) != null' >/dev/null 2>&1 \
				|| die "node.config.json: transport '$t' resolves to '$key', which is not in the operator_toggle_keys allowlist (fail-closed)."
			if jq --arg k "$key" '.[$k] = true' "$tmp" >"$tmp.np"; then
				mv -f "$tmp.np" "$tmp"
			else
				rm -f "$tmp.np"; die "node.config.json: failed to enable transport '$t' (key '$key') in params."
			fi
		done <<NODE_PROFILE_EOF
$transports
NODE_PROFILE_EOF
		log "params: applied node.config.json descriptor — enabled transports: $(printf '%s' "$transports" | tr '\n' ' ')."
	else
		log "node.config.json present with no transports[] — keeping the default-on set."
	fi

	# Foreign-engine reachability guard (RP-0011 chunk D, fail-closed). node_bind is a sing-box-only
	# mechanism: the Xray engine renders to a SEPARATE config (and AmneziaWG to its own surface) that the
	# loopback rebind never reaches (ADR-0034 §4; dual-engine reachability is a tracked follow-up). So a
	# reachable=false node with an enabled non-sing-box-engine transport would STILL be a public entry on
	# that engine's port. Refuse rather than give a false sense of privacy. (AmneziaWG carries no params
	# enable_key, so it is governed separately per ADR-0034 §4 — documented, not guarded here.)
	if [ "$reachable" = "false" ]; then
		local foreign_keys fk
		foreign_keys="$(jq -r '.protos[] | select(.engine != "sing-box") | .enable_key | select(. != null and . != "")' "$vocab" 2>/dev/null)"
		for fk in $foreign_keys; do
			if [ "$(jq -r --arg k "$fk" '(.[$k] // false)' "$tmp" 2>/dev/null)" = "true" ]; then
				die "node.config.json: reachable=false does not yet cover the non-sing-box-engine transport keyed '$fk' — it renders to a separate config the loopback rebind cannot reach, so the node would stay a public entry (tracked: dual-engine reachability). Disable that transport or keep the node reachable."
			fi
		done
	fi
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
	# GENUINE-TLS SNI (the own-cert families: vless-ws-tls / vless-xhttp-tls). It is the node's OWN domain
	# — a hostname under its served wildcard cert — NEVER the donor (the donor is the REALITY cover, a
	# SEPARATE field donor_sni). Derive it from the served wildcard cert's SAN: *.ZONE -> m.ZONE (the
	# mycelium convention), else the first concrete (non-wildcard) DNS SAN — so the rendered genuine-TLS
	# server_name AND the subscription's own-cert outbound SNI both agree with the presented cert (C03).
	# We NEVER fall back to the REALITY donor: serving the node's OWN cert under the donor SNI is a
	# cert/SNI-mismatch active-probe tell AND correlates the genuine-TLS family with REALITY by shared SNI
	# (Audit-0007 S2). If no own-cert domain is derivable, tls_domain stays EMPTY and the C03 guard in
	# render_singbox.sh fail-closes an ENABLED own-cert family; a REALITY-only node has no own-cert family,
	# so an empty tls_sni is fine for it.
	local tls_domain tls_san
	# These run under `set -euo pipefail`. A REALITY-only default node presents a CN=donor cover cert
	# with NO subjectAltName, so `openssl -ext subjectAltName` yields empty and the `grep` below finds
	# nothing → exit 1 → pipefail makes the bare assignment abort the ENTIRE deploy silently (grep
	# prints nothing). (A multi-SAN cert would instead SIGPIPE `grep` via `head -1`.) An EMPTY tls_domain
	# is the intended, handled result here (the C03 note above: a REALITY-only node has no own-cert SAN),
	# so `|| true` keeps the no-match/SIGPIPE case from failing the deploy.
	tls_san="$(openssl x509 -in "$TLS_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)"
	tls_domain="$(printf '%s' "$tls_san" | grep -oE 'DNS:\*\.[A-Za-z0-9.-]+' | head -1 | sed 's/^DNS:\*\./m./' || true)"
	[ -n "$tls_domain" ] || tls_domain="$(printf '%s' "$tls_san" | grep -oE 'DNS:[A-Za-z0-9.-]+' | grep -vE 'DNS:\*' | head -1 | sed 's/^DNS://' || true)"
	# SWEEP FIRST, THEN WRITE RESTRICTIVELY. Both halves are needed and both were missing.
	#
	# The leftover: this function has no trap, and three of the helpers it hands $tmp to (merge_operator_
	# overrides, apply_node_profile, the two_hop merge) `die` on malformed input. Any such death left the
	# temp behind — a complete params file, every transport password, every client UUID and the REALITY
	# private key. Found on ALL THREE live nodes dated 26-27 July, still there weeks later.
	#
	# The mode: mktemp creates 0600, but those helpers rewrite the file as `jq ... > "$tmp.np"` followed by
	# `mv -f`, and a shell redirection creates its file under the UMASK — 0644 on these nodes. The final
	# params.json is chmod 0600 at the end of this function, so the live file was always right; the
	# abandoned temp inherited 0644 and kept it. `node_exporter` is a real unprivileged local account on
	# these hosts, so that was a genuine local exposure, not a theoretical one.
	#
	# umask 077 for the whole body makes every intermediate 0600 whoever writes it, and the sweep bounds
	# the lifetime of anything that still escapes to one converge — 15 minutes on an armed node. Saved and
	# restored because write_params is not the last thing a flow does.
	rm -f "$STATE_DIR"/.params.* 2>/dev/null || true
	local _params_umask; _params_umask="$(umask)"
	umask 077
	local tmp
	tmp="$(mktemp "${STATE_DIR}/.params.XXXXXX")"
	jq -n \
		--arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg donor "$donor" \
		--arg ss "$ss" --arg tj "$tj" --arg hy "$hy" --arg st "$st" \
		--arg clash "$clash" \
		--arg node_address "$node_address" \
		--arg tls_cert "$TLS_DIR/fullchain.pem" --arg tls_key "$TLS_DIR/privkey.pem" \
		--arg tls_domain "$tls_domain" \
		'{
			node_address: $node_address,
			donor_host: $donor, donor_sni: $donor,
			reality_private_key: $priv, reality_public_key: $pub,
			short_ids: [ $sid ],
			tls_sni: $tls_domain,
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
	# FAIL-CLOSED: the allowlist is Go-owned (read from control/vocab.json above); an empty value means a
	# missing/stale vocab. Refuse to seed/merge with no allowlist (it would silently drop operator toggles).
	printf '%s' "$OPERATOR_TOGGLE_KEYS" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 \
		|| die "params: operator_toggle_keys is empty/invalid — regenerate control/vocab.json from the Go spine (RP-0008; the override allowlist is Go-owned)."
	seed_operator_overrides "$tmp"
	merge_operator_overrides "$tmp"
	# Optional unified node-profile descriptor (ADR-0034 / RP-0011 chunk B2): if a node-local
	# node.config.json is present, enable its declared transports[] (additively, on top of the defaults +
	# operator overrides). ABSENT on every node that has not adopted it -> no-op -> params render
	# byte-identically (zero blast radius under auto-pull). Read-only on the descriptor; fail-closed.
	apply_node_profile "$tmp"
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
	umask "$_params_umask"
	# Mirror the clash secret to a 0600 file so the loopback data-plane stats exporter can authenticate
	# to clash_api (--clash-secret-file). Empty on legacy nodes: leave no file (the exporter then reads
	# the still-open loopback clash_api exactly as today).
	if [ -n "$clash" ] && [ "$DRY_RUN" -eq 0 ]; then
		( umask 077; printf '%s' "$clash" >"$STATE_DIR/clash.secret" )
	fi
	log "wrote $PARAMS_JSON (0600, local-only)."
}

# flow_node_apply — ADR-0034 / RP-0011 chunk B2b: apply the unified node profile to the LIVE node.
# Local-only (NO fetch): re-render params from the current node-local state (write_params reads
# node.config.json via apply_node_profile) -> render candidate -> validate ('sing-box check', fail-closed)
# -> NO-OP short-circuit if the candidate is byte-identical to the live config (protects live client
# connections; a no-descriptor / no-change node does nothing) -> promote -> reload -> verify -> rollback
# on failure. It reuses the SAME render->validate->promote->verify->rollback spine as
# flow_update/flow_disable_two_hop, and is reachable ONLY via the explicit --node-apply mode (never an
# auto-run from bootstrap/update). It does NOT mutate the firewall (no lockout surface); enabling a
# transport on a new port also needs the listen port opened (harden_ufw on a full bootstrap) — tracked.
# apply_node_xray_engine — ADR-0032 dual-engine: serve/refresh the OPTIONAL xray engine iff an xray-ENGINE
# transport (vless-xhttp-tls) is enabled, using the SAME fail-closed spine as flow_bootstrap: ensure xray is
# installed -> render candidate -> 'xray run -test' -> NO-OP if byte-identical to the live xray config ->
# promote (known-good backup) -> unit -> restart. Node-local (no fetch); reached only from flow_node_apply.
# A stock node (node_needs_xray false) is a no-op, so this can be called unconditionally. Without it,
# enabling an xray-engine transport via --node-apply silently leaves the sing-box config byte-identical and
# never serves xray.
apply_node_xray_engine() {
	# TEARDOWN (Audit-0009 K2). Disabling the xray family reached the RENDER and stopped there: nothing
	# ever stopped xray.service, disabled it, or removed its config, so a "disabled" transport kept
	# serving its last config indefinitely — and the revocation path inherited that, since a client
	# removed from identities.json stays valid on an inbound nobody re-rendered. `transport disable` was
	# a statement of intent that the node never carried out.
	#
	# Gated on node_xray_disabled, the POSITIVE determination — never on `! node_needs_xray`, which is
	# also true when params or jq are merely unreadable. Stopping a live engine because state was briefly
	# unavailable, unattended, every 15 minutes, would be a far worse defect than the one being fixed.
	if node_xray_disabled; then
		if [ "$DRY_RUN" -eq 1 ]; then
			systemctl is-active --quiet xray 2>/dev/null && log "[dry-run] xray family disabled; WOULD stop + disable xray.service and retire its config."
			return 0
		fi
		if systemctl is-active --quiet xray 2>/dev/null || systemctl is-enabled --quiet xray 2>/dev/null || [ -f "$XRAY_CONFIG" ]; then
			need_root
			log "xray family is disabled in params; retiring the secondary engine (stop + disable + retire config)."
			run systemctl disable --now xray 2>/dev/null || warn "could not stop/disable xray.service; the config is retired below, so a restart would serve nothing."
			# Keep the retired config next to the last-known-good rather than deleting it: re-enabling the
			# family re-renders from identities anyway, and an operator investigating a revocation wants to
			# see what the engine was last serving. 0600, same class of secrets as the live config.
			if [ -f "$XRAY_CONFIG" ]; then
				run install -m 0600 "$XRAY_CONFIG" "$STATE_DIR/xray.config.retired.json" 2>/dev/null || true
				run rm -f "$XRAY_CONFIG"
			fi
		fi
		return 0
	fi
	node_needs_xray || return 0
	if [ "$DRY_RUN" -eq 0 ]; then install_xray; fi
	local xray_candidate="$STATE_DIR/xray.config.candidate.json"
	render_xray_candidate "$xray_candidate"
	if ! validate_xray_config "$xray_candidate"; then
		rm -f "$xray_candidate" 2>/dev/null || true
		die "xray candidate failed 'xray run -test' applying the node profile (fail-closed; nothing promoted)."
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		# NO rm here. Under --dry-run render_xray_candidate wrote NOTHING (its myceliumctl call goes
		# through run()) and validate_xray_config returned early, so this path never created the file.
		# The rm could therefore ONLY ever unlink a CONCURRENT REAL RUN's candidate — a preview
		# sabotaging a live timer tick, which is now reachable: the update timer fires every 15 minutes
		# and an operator runs --dry-run by hand whenever they want to look. --dry-run mutates nothing,
		# deletion included. A candidate left behind by a crashed real run is overwritten, then removed,
		# by the next real run.
		log "[dry-run] xray-engine transport enabled; candidate validates + WOULD be served."
		return 0
	fi
	if [ -f "$XRAY_CONFIG" ] && cmp -s "$xray_candidate" "$XRAY_CONFIG"; then
		rm -f "$xray_candidate" 2>/dev/null || true
		log "xray config byte-identical to the live one; secondary engine left untouched."
		return 0
	fi
	promote_xray_config "$xray_candidate"
	rm -f "$xray_candidate" 2>/dev/null || true
	install_xray_unit
	# ACCEPT-OR-ROLL-BACK (Audit-0009 K1). The primary engine has had a verify/rollback/failure-memory
	# triad since the beginning; the secondary engine had a promote and a restart, and rollback_xray_config
	# sat in nb_update_apply.sh with NO caller — the safety net was written and never hung. That mattered
	# little while xray moved only under an operator's hand; converge_node_tail put this path on the
	# unattended 15-minute timer, and an unaccepted promote there persists until somebody looks.
	#
	# `restart_xray` returning 0 only means systemd accepted the start. Assert the unit is actually ACTIVE
	# after it, since a config xray parses but refuses at runtime exits moments later and would otherwise
	# read as applied. On failure: restore the last known-good config, restart onto it, and fail — the same
	# shape as the sing-box path, no cleverer.
	restart_xray
	if [ "$DRY_RUN" -eq 0 ] && ! systemctl is-active --quiet xray 2>/dev/null; then
		warn "xray did not stay active after the restart; rolling back the secondary engine (fail-closed)."
		# Remember the rejected bytes before the rollback overwrites them — the operator-evidence peer of
		# the primary engine's failed-candidate snapshot, and the only copy once lastgood is restored.
		if [ -f "$XRAY_CONFIG" ]; then
			run install -m 0600 "$XRAY_CONFIG" "$STATE_DIR/xray.config.failed.json" 2>/dev/null || true
		fi
		rollback_xray_config
		restart_xray || warn "xray could not restart onto the restored config — operator attention needed."
		die "xray engine rolled back (fail-closed): the promoted config did not stay running. The rejected bytes are kept at $STATE_DIR/xray.config.failed.json (0600)."
	fi
	log "xray engine applied (ADR-0032 dual-engine): config promoted + xray.service restarted + confirmed active."
	# Advisory L7 acceptance for the xray family: verify_post_apply is skipped on an xray-ONLY --node-apply
	# (the sing-box config is unchanged), so run the outer-TLS own-cert probe here whenever xray is (re)served.
	# Advisory — WARN, never rolls back (ADR-0036); a distinct marker so it never clobbers the daemon/verb one.
	measure_l7_probe_xhttp "$STATE_DIR/l7_xhttp_postapply.json" || warn "post-apply L7 xhttp-tls liveness flagged a dead outer-TLS layer (marker: $STATE_DIR/l7_xhttp_postapply.json) — the xray xhttp-tls listener is bound but a real client would fail the outer TLS layer."
}

# converge_node_tail — the SHARED convergence tail EVERY path that promotes a config must end with.
# Extracted from flow_node_apply because the other promote paths each carried a DIFFERENT subset of it,
# and the gaps were invisible: flow_update reconciled sing-box and the bundle but never the xray engine
# (ADR-0032) or the firewall (Audit-0008 S1-2); flow_ack promoted a staged candidate and converged
# NOTHING; flow_revoke re-rendered sing-box and the bundle but left the REVOKED client's UUID live on
# the xray inbound (render_xray_candidate keys on identities.json — nb_update_apply.sh:198). Three
# call sites, three different answers to the same question, is how a node ends up half-converged.
#
# ORDER IS LOAD-BEARING: xray FIRST, because harden_ufw reads $XRAY_CONFIG's inbound ports
# (nb_harden.sh:180-183) — hardening before the xray promote would open the PREVIOUS port set and leave
# a newly-served port ufw-blocked. Firewall SECOND. Bundle LAST, so the served distribution only ever
# describes a node that is already live and already reachable.
#
# Every step no-ops when there is nothing to do, which is what makes it safe on a cadence:
# apply_node_xray_engine returns immediately on a node with no xray family enabled (`node_needs_xray ||
# return 0`) and skips the restart when the rendered xray config is byte-identical; harden_ufw computes a
# delta against the rules ufw already admits and issues only that (it is additive + anti-lockout, and never
# removes a rule); render_serve_bundle is fail-closed (keeps last-known-good rather than serving an invalid
# bundle). The firewall step's claim was previously "idempotent", which was true of the OUTCOME and not of
# the ACTIONS — it re-issued its whole sequence every tick, so a transient failure in any of them could
# fail a tick with nothing to converge (Audit-0009 N1).
# FAILURE CONTRACT (Audit-0009 J1): run ALL THREE steps, then report. The tail used to be three bare
# calls, and its first step is the only one that can `die` — so on an xray-serving node an xray fault
# aborted the process and silently took the firewall and the served bundle with it. The steps are
# INDEPENDENT (a broken secondary engine says nothing about whether the firewall admits the primary's
# ports), so one failing must not cancel the others; that ordering accident turned a single-engine fault
# into a three-way non-convergence.
#
# Each step is SUBSHELL-wrapped so its `die` is catchable — the same idiom rotate_apply_live already uses
# for write_params. A subshell loses variable assignments, not side effects, and no step here exports
# state the others read, so nothing is lost by running them isolated.
#
# The tail then returns NON-ZERO naming what failed. Under the entrypoint's `set -e` that makes the
# calling flow fail loudly AFTER convergence was fully attempted — which is the intended shape: a
# half-converged node must be visible (the unit goes red), and nothing here rolls back a sing-box config
# that already promoted and verified. Reporting the failure and undoing a good promote are different
# things; only the first is wanted.
# _report_loop_drift — reconcile what node.config.json DECLARES against what the node actually runs.
#
# The profile's loops field is a request that nothing consumes: arming is a node-local sentinel, never a
# committable file (the RP-0012 triple gate). Correct — and it lets the file drift into saying something
# untrue. All three live nodes declared every loop false while all three were running, and nothing
# anywhere noticed, because nothing reads the field at all.
#
# Advisory, never fatal (ADR-0030). The point is that an operator reading the file is not misled; it must
# not become a reason a converge fails.
_report_loop_drift() {
	local spine="${SPINE_BIN:-${TOOLING_DIR:-/usr/local/lib/mycelium}/bin/myceliumctl-go}"
	local cfg="$STATE_DIR/node.config.json"
	[ -x "$spine" ] && [ -f "$cfg" ] || return 0
	# Ask each loop's OWNING module; do not name a unit here. Two gates enforce that and both are right —
	# a second file naming a unit is a second thing that could arm or stop it.
	#
	# The update loop is deliberately NOT probed: its unit has no in-tree owner today, and
	# update_unit_template_shape refuses any tracked reference to it precisely so that nothing claims one
	# by accident. Its declared value is passed straight through, so it can never register as drift here.
	# When that unit gains a real owner, give it a predicate too and this line becomes a probe.
	local u r=false m=false
	u="$(jq -r '.loops.update // false' "$cfg" 2>/dev/null)"; [ "$u" = "true" ] || u=false
	command -v rotate_loop_running  >/dev/null 2>&1 && rotate_loop_running  && r=true
	command -v measure_loop_running >/dev/null 2>&1 && measure_loop_running && m=true
	local out
	out="$("$spine" loop-drift --profile "$cfg" --update="$u" --rotate="$r" --measure="$m" 2>/dev/null)" && return 0
	[ -n "$out" ] || return 0
	warn "node.config.json disagrees with what this node is running:"
	printf '%s\n' "$out" | while IFS= read -r _l; do [ -n "$_l" ] && warn "  $_l"; done
	return 0
}

converge_node_tail() {
	local failed=""
	_report_loop_drift
	# The promise every issued hysteria2 config makes is kept by a firewall rule that no other check on
	# this node can see. Verify it here, where a failure is reported rather than assumed away.
	if command -v verify_hy2_hop_nat >/dev/null 2>&1; then
		verify_hy2_hop_nat || failed="$failed hysteria2-hop-redirect"
	fi
	# Every caller reaches here only after a promote was applied AND verified (or after establishing there
	# was nothing to promote), so the previous run's failure snapshots are stale by definition. Retiring
	# them here rather than in flow_update alone is what bounds their lifetime on the operator-driven paths
	# — revoke, node-apply, rotate, disable-two-hop — which is where a deliberately retired credential used
	# to survive indefinitely (Audit-0009 R1). Runs FIRST: the xray step below writes its own failure
	# snapshot, and that one belongs to this run.
	clear_retired_config_snapshots
	( apply_node_xray_engine ) || failed="$failed xray-engine"
	# Respects --no-harden. The `if` form, not `[ ] && harden_ufw`: under `set -e` the && form is only
	# safe because another statement follows it, and that is too subtle to leave as a trap for the next edit.
	# The posture comes from NODE STATE, not from this invocation's argv (Audit-0009 I1) — the tail runs
	# unattended from the timer, where argv carries no posture at all.
	if [ "$(node_profile_harden)" = "on" ]; then
		( harden_ufw ) || failed="$failed firewall"
	else
		log "host firewall: posture is OFF for this node (node.config.json .harden, or the remembered --no-harden bootstrap); leaving ufw untouched."
	fi
	( render_serve_bundle ) || failed="$failed served-bundle"
	if [ -n "$failed" ]; then
		warn "convergence INCOMPLETE — step(s) failed:$failed"
		warn "  The other steps still ran: one failing step no longer cancels the rest. The primary engine's"
		warn "  config is untouched by this failure (it promoted and verified before the tail ran); what is"
		warn "  stale is the step named above. Fix it and re-run '$0 --node-apply'."
		return 1
	fi
	return 0
}

flow_node_apply() {
	log "=== apply node profile (local re-render -> validate -> promote -> reload) ==="
	need_root
	# Attended, so it may state a posture — but only if it actually did (Audit-0009 I1). A plain
	# --node-apply must not flip a --no-harden node back on just because DO_HARDEN defaults to 1. To turn
	# the firewall back ON for good, declare it in node.config.json (`"harden": true`), which outranks this.
	remember_harden_posture explicit-only
	[ -f "$IDENTITY_SECRETS" ] || die "no local identity; cannot apply a node profile (bootstrap first)."
	write_params
	local candidate="$STATE_DIR/config.candidate.node-apply.json"
	render_candidate "$candidate"
	if ! validate_config "$candidate"; then
		rm -f "$candidate" 2>/dev/null || true
		die "candidate failed 'sing-box check' applying the node profile (fail-closed; nothing promoted)."
	fi
	# Does the SING-BOX config change? A restart drops live client connections on an always-on PPN, so we
	# promote/reload the primary engine ONLY when its config actually changed. This is NOT an early return:
	# an xray-only change (e.g. enabling vless-xhttp-tls) leaves the sing-box config byte-identical, yet the
	# xray engine below must still be served.
	local sb_changed=1
	if [ "$DRY_RUN" -eq 0 ] && [ -f "$SINGBOX_CONFIG" ] && cmp -s "$candidate" "$SINGBOX_CONFIG"; then sb_changed=0; fi
	if [ "$DRY_RUN" -eq 1 ]; then
		# NO rm here — same reason as apply_node_xray_engine above: under --dry-run nothing created this
		# file, so removing it can only destroy a concurrent real run's candidate.
		log "[dry-run] node profile validates and WOULD be applied (not promoted)."
		apply_node_xray_engine
		return 0
	fi
	if [ "$sb_changed" -eq 1 ]; then
		promote_config "$candidate"
		install_singbox_unit
		if apply_singbox && verify_post_apply; then
			:
		else
			warn "post-apply verification failed applying the node profile; rolling back."
			rollback_config
			apply_singbox || true
			verify_post_apply || warn "service still unhealthy after rollback — operator attention needed."
			rm -f "$candidate" 2>/dev/null || true
			die "node-apply rolled back (fail-closed) — the previous known-good config was restored."
		fi
	else
		log "sing-box config byte-identical to the live one; primary engine left untouched."
	fi
	rm -f "$candidate" 2>/dev/null || true
	# ADR-0032 dual-engine + Audit-0008 S1-2 firewall reconcile + served bundle, in that order. Runs
	# independently of the sing-box change above: an xray-only change (enabling vless-xhttp-tls) leaves the
	# sing-box config byte-identical, and a family enabled on a NEW port would otherwise bind a ufw-BLOCKED
	# listener while verify_post_apply (L4 bind + loopback L7 — both firewall-blind) reports "applied +
	# verified", a phantom fallback the operator would treat as a live path. See converge_node_tail.
	converge_node_tail
	log "node profile applied + verified; firewall reconciled; config reloaded + served bundle refreshed."
}
