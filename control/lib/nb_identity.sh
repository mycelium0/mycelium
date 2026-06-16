# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_identity.sh — node-bootstrap library: per-node identity (key/uuid/shortid/secret generation
# + identity state). Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: produce and persist the node's LOCAL-ONLY identity — the REALITY keypair,
# UUIDs, REALITY shortIds, per-protocol secrets, and the identities.json / identity.json state.
# CLASSIFICATION: OS-glue (thin wrappers around audited generators — sing-box / openssl — per
# ADR-0002; not one byte of key material is produced here directly). This file is meant to be
# SOURCED into scripts/node-bootstrap.sh, never executed directly; it defines functions only and
# relies on the entrypoint's shared globals (SINGBOX_BIN, STATE_DIR, IDENTITIES_JSON,
# IDENTITY_SECRETS, CLIENT_NAMES, TLS_DIR, DRY_RUN, …) and helpers (log/warn/die/have/run/need_root)
# being defined at call time. Behaviour is byte-identical to the inline definitions it replaced.

gen_reality_keypair() {
	# Echo "PRIV<TAB>PUB" from "sing-box generate reality-keypair".
	have "$SINGBOX_BIN" || die "sing-box not installed yet; cannot generate REALITY keypair."
	local out priv pub
	out="$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)" \
		|| die "'sing-box generate reality-keypair' failed."
	priv="$(printf '%s\n' "$out" | sed -n 's/^[Pp]rivate[Kk]ey:[[:space:]]*//p; s/^[Pp]rivate [Kk]ey:[[:space:]]*//p' | head -n1 | tr -d '[:space:]')"
	pub="$(printf '%s\n' "$out"  | sed -n 's/^[Pp]ublic[Kk]ey:[[:space:]]*//p;  s/^[Pp]ublic [Kk]ey:[[:space:]]*//p'  | head -n1 | tr -d '[:space:]')"
	[ -n "$priv" ] && [ -n "$pub" ] || die "could not parse REALITY keypair output."
	printf '%s\t%s\n' "$priv" "$pub"
}

gen_uuid() {
	if have "$SINGBOX_BIN"; then
		"$SINGBOX_BIN" generate uuid 2>/dev/null | tr -d '[:space:]' && return 0
	fi
	# openssl is the sanctioned fallback for randomness; format it as a UUID shape.
	have openssl || die "no UUID source (need sing-box or openssl)."
	local h
	h="$(openssl rand -hex 16 2>/dev/null | tr -d '[:space:]')"
	[ -n "$h" ] || die "'openssl rand' produced no output."
	printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

gen_secret_b64() {
	# 32 random bytes, base64 — suitable for an SS-2022 PSK and protocol passwords.
	if have "$SINGBOX_BIN"; then
		"$SINGBOX_BIN" generate rand --base64 32 2>/dev/null | tr -d '[:space:]' && return 0
	fi
	have openssl || die "no random source (need sing-box or openssl)."
	openssl rand -base64 32 2>/dev/null | tr -d '[:space:]'
}

gen_shortid() {
	# 8 random bytes -> 16 hex chars (a common REALITY shortId length).
	have openssl || die "openssl required for REALITY shortIds."
	openssl rand -hex 8 2>/dev/null | tr -d '[:space:]'
}

ensure_identity() {
	log "ensuring per-node identity exists (generated locally if absent)"
	need_root
	have jq || die "jq required for identity management."
	ensure_singbox_user

	# 1) Client identity list (names -> uuids), via myceliumctl (sing-box/openssl-backed).
	if [ ! -f "$IDENTITIES_JSON" ]; then
		if [ "$DRY_RUN" -eq 0 ]; then
			printf '{"version":1,"clients":[]}\n' >"$IDENTITIES_JSON"
			chmod 0600 "$IDENTITIES_JSON"
		fi
	fi
	local name
	for name in $CLIENT_NAMES; do
		if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] ensure client identity: $name"; continue; fi
		if jq -e --arg n "$name" 'any(.clients[]?; .name==$n)' "$IDENTITIES_JSON" >/dev/null 2>&1; then
			log "client '$name' already present."
		else
			local uuid created tmp
			uuid="$(gen_uuid)"; created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			tmp="$(mktemp "${STATE_DIR}/.id.XXXXXX")"
			jq --arg n "$name" --arg i "$uuid" --arg c "$created" \
				'.clients += [{name:$n,id:$i,created:$c}]' "$IDENTITIES_JSON" >"$tmp"
			mv -f "$tmp" "$IDENTITIES_JSON"; chmod 0600 "$IDENTITIES_JSON"
			log "issued client identity '$name'."
		fi
	done

	# 2) Node-level secrets + REALITY keypair + donor (once).
	if [ -f "$IDENTITY_SECRETS" ]; then
		log "node secrets already present at $IDENTITY_SECRETS; keeping them."
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would generate REALITY keypair, secrets, donor, cert"; return 0; fi

	local kp priv pub sid donor
	kp="$(gen_reality_keypair)"; priv="${kp%%	*}"; pub="${kp##*	}"
	sid="$(gen_shortid)"
	donor="$(pick_donor)"
	log "selected + verified donor SNI (stored locally; never committed)."

	local ss_pw tj_pw hy_pw st_pw clash_pw
	ss_pw="$(gen_secret_b64)"; tj_pw="$(gen_secret_b64)"
	hy_pw="$(gen_secret_b64)"; st_pw="$(gen_secret_b64)"
	# clash_api Bearer secret (loopback /connections auth, defence-in-depth — ADR-0014/Audit-0004 F-003).
	# Generated ONCE here at bootstrap; never regenerated on update (the secrets block is kept if present
	# above), so the live render stays stable. Legacy nodes whose identity predates this field render
	# clash_api WITHOUT a secret (byte-identical to today) — see write_params + render_singbox.
	clash_pw="$(gen_secret_b64)"

	# Per-node SELF-SIGNED cert (CN = donor) for the TLS-cert protocols (HY2/TUIC/Trojan). ADR-0014:
	# certless REALITY/AmneziaWG per-node keypairs; HY2/TUIC use a per-node self-signed cert + a
	# client sha256 pin. openssl (audited) issues it; the key never leaves the node.
	ensure_self_signed_cert "$donor"

	local tmp
	tmp="$(mktemp "${STATE_DIR}/.secrets.XXXXXX")"
	jq -n \
		--arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg donor "$donor" \
		--arg ss "$ss_pw" --arg tj "$tj_pw" --arg hy "$hy_pw" --arg st "$st_pw" \
		--arg clash "$clash_pw" \
		--arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
			version: 1, created: $created,
			reality: { private_key: $priv, public_key: $pub, short_id: $sid },
			donor:   { host: $donor, sni: $donor },
			secrets: { ss_password: $ss, trojan_password: $tj, hysteria2_password: $hy, shadowtls_password: $st, clash_secret: $clash }
		}' >"$tmp"
	mv -f "$tmp" "$IDENTITY_SECRETS"; chmod 0600 "$IDENTITY_SECRETS"
	log "wrote node secrets (0600): $IDENTITY_SECRETS"
}
