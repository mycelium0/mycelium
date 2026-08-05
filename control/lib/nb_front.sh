#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_front.sh — ADR-0033 P2 deploy wiring for the OPTIONAL operator CDN/ingress front
# (bring-your-own-domain). CLASSIFICATION: control-glue. DEFAULT-OFF + INERT: front_setup is a no-op
# unless a node-local front.config.json EXISTS and carries enabled=true. A node without that file (the
# default) renders byte-identically to no front — nothing here ever enables a front on its own.
#
# When enabled (and the Go spine is present — the front render/compile is Go-only, a P2 NEW capability):
#   (1) compiles the operator's EDGE nginx config (myceliumctl-go front-render) into $FRONT_DIR — the
#       operator deploys THAT on their own edge host and points DNS for the front domain at it; and
#   (2) re-renders the SERVED bundle WITH the fronted endpoint (myceliumctl-go bundle --front),
#       fail-closed (keeps the non-fronted served bundle if the fronted render fails).
# The front is COMPLEMENTARY / last-resort (THREAT-MODEL / ADR-0027); relay (TLS-passthrough) is the
# doctrine-clean default, terminate is the ack-gated metadata trade-off — both enforced in the Go spine.

FRONT_CONFIG="${FRONT_CONFIG:-$STATE_DIR/front.config.json}"   # operator-placed, node-local; default-absent
FRONT_DIR="${FRONT_DIR:-$STATE_DIR/front}"                     # where the compiled edge config is written

# front_setup — apply the operator front when configured + enabled; otherwise a silent no-op. Called at the
# tail of render_serve_bundle so it tracks every bundle render, and is idempotent.
front_setup() {
	have jq || return 0
	# node.config.json IS the node profile (ADR-0034), and it carries a `.front` object that
	# spec.NodeProfile declares and Validate() checks — so an operator who configures the front THERE gets
	# it accepted, reported by `node plan` / `node validate`, and consumed by nothing at all: this function
	# only ever read the standalone front.config.json. Two files, one of them silently inert, and the inert
	# one is the one the unified profile tells an operator to use.
	#
	# The standalone file still WINS when present (it is the older, explicit, node-local placement and an
	# operator who put it there means it). The profile is the fallback, materialised into the same shape the
	# rest of this function already consumes, so there is exactly one code path below.
	local profile="${NODE_CONFIG_JSON:-$STATE_DIR/node.config.json}"
	if [ ! -f "$FRONT_CONFIG" ] && [ -f "$profile" ] \
	   && jq -e '.front | objects | select(.enabled == true)' "$profile" >/dev/null 2>&1; then
		# The PROFILE ITSELF is handed to the spine — no derived copy. spec.LoadFrontConfig accepts either
		# shape, so the discrimination happens once, in Go, and node.config.json stays the single owner of
		# front configuration (ADR-0034, ADR-0038 §2). Materialising `.front` into a third file, as the
		# first attempt did, is the same one-truth-two-locations defect this work exists to remove.
		FRONT_CONFIG="$profile"
		log "front: configuration taken from the node profile ($profile .front); no standalone $STATE_DIR/front.config.json is present."
	fi
	[ -f "$FRONT_CONFIG" ] || return 0          # default-off: no config anywhere => inert
	# SHAPE-AWARE, because $FRONT_CONFIG may now be the node profile, whose flag lives at .front.enabled
	# rather than at the root. Reading only the root would silently report "disabled" for every operator
	# who configured the front where ADR-0034 tells them to — the same class of quiet no-op this change
	# removes, reintroduced one line lower. The Go side discriminates the same way (spec.LoadFrontConfig).
	local enabled
	enabled="$(jq -r 'if has("front") then (.front.enabled // false) else (.enabled // false) end' "$FRONT_CONFIG" 2>/dev/null)"
	if [ "$enabled" != "true" ]; then
		log "front config present but disabled (enabled!=true); no fronting (default-off)."
		return 0
	fi
	if [ "${DRY_RUN:-0}" -eq 1 ]; then
		log "[dry-run] would compile the edge config + re-render the served bundle WITH the front from $FRONT_CONFIG"
		return 0
	fi
	local goctl="${SPINE_BIN:-$TOOLING_DIR/bin/myceliumctl-go}"
	if [ ! -x "$goctl" ]; then
		warn "front enabled but the Go spine ($goctl) is absent — the front render/compile is Go-only; skipping (install the spine / a Go toolchain)."
		return 0
	fi
	[ -f "$PARAMS_JSON" ] || { warn "params.json missing; skipping front setup."; return 0; }
	[ -f "$IDENTITIES_JSON" ] || { warn "identities.json missing; skipping front setup."; return 0; }

	# (1) compile the operator's EDGE proxy config. Fail-closed: a disabled/non-frontable/invalid front
	# config makes front-render exit non-zero — we then do NOT front the bundle (and never half-apply).
	run mkdir -p "$FRONT_DIR"
	if ! "$goctl" front-render --front "$FRONT_CONFIG" --params "$PARAMS_JSON" --out "$FRONT_DIR/edge.nginx.conf" 2>"$FRONT_DIR/.front.err"; then
		warn "front edge-config compile failed: $(tr -d '\n' < "$FRONT_DIR/.front.err" 2>/dev/null | cut -c1-200) — NOT fronting the served bundle."
		rm -f "$FRONT_DIR/.front.err" 2>/dev/null || true
		return 0
	fi
	rm -f "$FRONT_DIR/.front.err" 2>/dev/null || true
	log "edge proxy config written: $FRONT_DIR/edge.nginx.conf — deploy this on YOUR OWN edge host and point DNS for the front domain at it (the front is complementary/last-resort; the in-region two-hop stays primary)."

	# (2) re-render the SERVED bundle WITH the fronted endpoint, fail-closed: a failed/invalid fronted
	# render leaves the already-promoted non-fronted served bundle in place (never serve an invalid bundle).
	local cand="$STATE_DIR/bundle.front.candidate.json"
	if "$goctl" bundle --front "$FRONT_CONFIG" --params "$PARAMS_JSON" --state "$IDENTITIES_JSON" --out "$cand" 2>/dev/null \
		&& jq -e '.endpoints | length >= 1' "$cand" >/dev/null 2>&1; then
		run install -m 0644 "$cand" "$BUNDLE_SERVED"
		rm -f "$cand" 2>/dev/null || true
		log "served bundle re-rendered WITH the fronted endpoint: $BUNDLE_SERVED ($(jq '.endpoints | length' "$BUNDLE_SERVED" 2>/dev/null || echo '?') endpoint(s))."
	else
		rm -f "$cand" 2>/dev/null || true
		warn "fronted bundle render failed; keeping the non-fronted served bundle (fail-closed)."
	fi
}
