# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_two_hop.sh — node-bootstrap library: the two-hop egress ROUTING POLICY — fail-closed shape
# validation of a node-local two_hop.json overlay (assert_two_hop_shape) + the supported remove path
# (flow_disable_two_hop).
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: own the node-side two-hop egress decisions — (1) assert_two_hop_shape, the
# fail-closed invariant check (C17/C18/C21) write_params runs before merging a present two_hop.json
# into params, and (2) flow_disable_two_hop, the documented --disable-two-hop remove path (C21) that
# deletes the overlay, re-renders the server config fail-closed, and refreshes the served bundle.
# CLASSIFICATION: CONTROL-LOGIC (routing policy) — the overlay invariants + the egress==ingress refusal
# mirror render_singbox.sh's `.two_hop` guard, and are EARMARKED for the RP-0008 Go migration
# (internal/spec), where the typed two-hop contract will own the shape check. Until then it stays bash,
# byte-identical. This file is meant to be SOURCED into scripts/node-bootstrap.sh, never executed
# directly; it defines functions only and relies on the entrypoint's shared globals (STATE_DIR,
# PARAMS_JSON, IDENTITIES_JSON, IDENTITY_SECRETS) and helpers (log/warn/die/have/run/need_root) being
# defined at call time. resolve_node_address (in nb_render_params.sh), write_params, render_candidate,
# validate_config, promote_config, rollback_config, install_singbox_unit, apply_singbox,
# verify_post_apply and render_serve_bundle are all resolved at call time from the shared sourced scope.
# The dispatch `case` in the entrypoint calls flow_disable_two_hop; that call likewise resolves at
# runtime. Behaviour is byte-identical to the inline definitions it replaced.

# ---------------------------------------------------------------------------
# assert_two_hop_shape FILE — fail-closed shape validation of a node-local two_hop.json overlay
# (C17/C18/C21). Mirrors render_singbox.sh's fail-closed `.two_hop` guard so a malformed overlay is
# caught at the SAME consistency bar at params-write time, not only deep in the renderer. Any failure
# is a hard `die` (the caller has already decided the file is PRESENT, so absence is not this function's
# concern). Checks, in order:
#   * valid JSON object (not an array/scalar)                                  — well-formedness
#   * non-empty via_user                                                        (C17/C18 precondition)
#   * well-formed upstream: non-empty tag, non-empty server, integer server_port in 1..65535, non-empty
#     sni                                                                       (C17 well-formed upstream)
#   * via_user names an EXISTING identity (clients[].name in IDENTITIES_JSON)   (C18 unknown-user refusal)
#   * egress upstream is DISTINCT from this ingress node — server != node_address AND sni != donor_sni
#     (C21 ingress==egress refusal: a two-hop whose egress is the ingress itself is no second hop)
assert_two_hop_shape() {
	local file="$1" th ingress_addr ingress_sni
	have jq || die "jq required to validate the two_hop overlay (fail-closed)."
	jq -e 'type == "object"' "$file" >/dev/null 2>&1 \
		|| die "two_hop.json ($file) is not a JSON object (fail-closed; a two-hop overlay must be an object)."
	th="$(jq -c . "$file" 2>/dev/null)" \
		|| die "two_hop.json ($file) is not valid JSON (fail-closed)."
	# via_user must be present and non-empty (an unscoped egress no route selects is refused upstream too).
	local th_via; th_via="$(printf '%s' "$th" | jq -r '.via_user // ""')"
	[ -n "$th_via" ] || die "two_hop.json: via_user is empty (fail-closed; a two-hop must name the designated client that egresses out-of-region)."
	# Well-formed upstream: tag, server, sni non-empty; server_port an integer in range.
	local th_tag th_server th_sni th_port
	th_tag="$(printf '%s' "$th" | jq -r '.tag // ""')"
	th_server="$(printf '%s' "$th" | jq -r '.server // ""')"
	th_sni="$(printf '%s' "$th" | jq -r '.sni // ""')"
	th_port="$(printf '%s' "$th" | jq -r '.server_port // empty')"
	[ -n "$th_tag" ]    || die "two_hop.json: tag is empty (fail-closed; the upstream outbound needs a tag)."
	[ -n "$th_server" ] || die "two_hop.json: server is empty (fail-closed; the upstream needs an address)."
	[ -n "$th_sni" ]    || die "two_hop.json: sni is empty (fail-closed; the upstream TLS needs a server_name)."
	case "$th_port" in
		''|*[!0-9]*) die "two_hop.json: server_port is not a positive integer ('$th_port'); must be 1..65535 (fail-closed)." ;;
	esac
	if [ "$th_port" -lt 1 ] || [ "$th_port" -gt 65535 ]; then
		die "two_hop.json: server_port is out of range ('$th_port'); must be 1..65535 (fail-closed)."
	fi
	# C18: via_user must match an existing identity (clients[].name). An auth_user route for an unknown
	# user renders fine but NEVER matches — a dead, unscoped egress rule. Refuse it here.
	if [ -f "$IDENTITIES_JSON" ]; then
		if ! jq -e --arg u "$th_via" 'any(.clients[]?; .name == $u)' "$IDENTITIES_JSON" >/dev/null 2>&1; then
			die "two_hop.json: via_user '$th_via' is not a known client in $IDENTITIES_JSON (fail-closed; the auth_user route would never match — add the identity or fix via_user)."
		fi
	else
		die "two_hop.json: cannot verify via_user '$th_via' — $IDENTITIES_JSON is missing (fail-closed; bootstrap an identity before configuring two-hop)."
	fi
	# C21: the egress upstream must be DISTINCT from this ingress node, or the "two hops" are one. Compare
	# against this node's own reachable address and its donor_sni. Same host OR same SNI => die.
	ingress_addr="$(resolve_node_address)"
	if [ -f "$PARAMS_JSON" ] && have jq; then
		ingress_sni="$(jq -r '.donor_sni // ""' "$PARAMS_JSON" 2>/dev/null)"
	fi
	if [ -n "$ingress_addr" ] && [ "$th_server" = "$ingress_addr" ]; then
		die "two_hop.json: egress server '$th_server' is THIS node's own address (fail-closed; ingress and egress must be distinct nodes — a two-hop to itself is no second hop). See --disable-two-hop to remove the overlay."
	fi
	if [ -n "$ingress_sni" ] && [ "$th_sni" = "$ingress_sni" ]; then
		die "two_hop.json: egress sni '$th_sni' equals this node's donor_sni (fail-closed; egress must be a distinct node, not the ingress SNI). See --disable-two-hop to remove the overlay."
	fi
	log "two_hop overlay validated (via_user='$th_via', egress tag='$th_tag', distinct from ingress)."
}

# flow_disable_two_hop — C21 documented remove-two-hop path: delete the node-local two_hop.json overlay,
# regenerate params WITHOUT it, re-render + validate the server config fail-closed, promote + reload, and
# re-render the served bundle. This is the supported way to turn two-hop OFF — no manual file surgery, and
# every promotion path (server config + served bundle) is refreshed so nothing keeps a stale unscoped
# egress. Idempotent: if no overlay is present, it reports so and exits 0 (nothing to disable).
flow_disable_two_hop() {
	log "=== disable two-hop egress overlay (remove + re-render + reload) ==="
	need_root
	if [ ! -f "$STATE_DIR/two_hop.json" ]; then
		log "no two_hop.json present at $STATE_DIR — two-hop is already disabled (nothing to do)."
		return 0
	fi
	[ -f "$IDENTITY_SECRETS" ] || die "no local identity; cannot re-render after disabling two-hop (bootstrap first)."
	run rm -f "$STATE_DIR/two_hop.json"
	log "removed the node-local two_hop overlay ($STATE_DIR/two_hop.json)."
	# Regenerate params WITHOUT the overlay (write_params no longer finds two_hop.json -> no .two_hop key).
	write_params
	local candidate="$STATE_DIR/config.candidate.json"
	render_candidate "$candidate"
	if ! validate_config "$candidate"; then
		rm -f "$candidate" 2>/dev/null || true
		die "candidate failed 'sing-box check' after disabling two-hop (fail-closed; nothing promoted)."
	fi
	promote_config "$candidate"
	rm -f "$candidate" 2>/dev/null || true
	install_singbox_unit
	if apply_singbox && verify_post_apply; then
		# Re-render the served bundle so the served distribution reflects the now-two-hop-free config.
		render_serve_bundle
		log "two-hop disabled; config re-rendered + sing-box reloaded + served bundle refreshed."
	else
		warn "post-apply verification failed after disabling two-hop; rolling back."
		rollback_config
		apply_singbox || true
		die "disable-two-hop rolled back (fail-closed) — the prior config is restored."
	fi
}
