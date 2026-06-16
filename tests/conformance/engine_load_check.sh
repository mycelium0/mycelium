#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# engine_load_check.sh — conformance: a representative sing-box SERVER config, rendered by the SHELL
# producer (control/myceliumctl render-server --engine singbox), actually LOADS in the sing-box engine
# (`sing-box check -c <rendered>`). The rest of the offline suite checks template STRUCTURE but never
# engine-LOADS a rendered config — which is exactly how the xhttp/sing-box incompatibility slipped
# through: the `xhttp` transport is Xray-core ONLY, so `sing-box check` rejects a config carrying
# `transport.type: "xhttp"` (FATAL "unknown transport type: xhttp"). This gate closes that blind spot:
#   1. render the realistic default set (vless-reality-vision + vless-reality-grpc) and prove
#      `sing-box check` LOADS it — the engine can actually serve what we render.
#   2. render with vless-xhttp-tls ENABLED and prove the shell render FAILS CLOSED (the render-guard in
#      control/lib/render_singbox.sh — `render-server` exits non-zero), so the bug can never reach a node:
#      enabling xhttp-tls on the sing-box engine is a loud refusal, not a crash on load.
#
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-BINARY: the offline suite runs on hosts without a sing-box binary (the maintainer's macOS
# host; the jq-only CI lane). There the `sing-box check` HALF SKIPs (a printed note) — it is NOT a
# failure, exactly like bundle_go_roundtrip skips when no Go toolchain is present. The render-guard
# fail-closed HALF needs only bash + jq and ALWAYS runs. Where sing-box IS present (a node) the load
# check runs for real.
#
# Exit: 0 = the rendered config loads (or the load half was skipped, no sing-box) AND the guard refuses
#       xhttp-tls; 1 = a rendered config sing-box rejects OR the render-guard is missing (xhttp-tls was
#       rendered instead of refused); 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
CTL="$REPO_ROOT/control/myceliumctl"

printf '== engine load check (shell render -> sing-box check loads it) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -x "$CTL" ] || [ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.elc.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# Minimal render fixtures (same pattern as bundle_go_roundtrip.sh). Dummy reality material + a single
# identity: render-server PLACES these by jq path. NOTE `sing-box check` does MORE than parse — it
# VALIDATES the reality private key (a stub base64 string fails FATAL "invalid private key"), so when
# sing-box is present the fixture must carry a GENUINE X25519 key (minted just below). A realistic
# DEFAULT set is enabled: VLESS+REALITY Vision (TCP) + gRPC, the documented Variant-A default-on set.

# --- Resolve a sing-box binary FIRST: PATH then the well-known node install locations. Its presence
#     decides BOTH whether the load-check runs AND whether the fixture needs a real reality key. ---
SB=""
if command -v sing-box >/dev/null 2>&1; then
	SB="$(command -v sing-box)"
else
	for cand in /usr/local/bin/sing-box /usr/bin/sing-box; do
		[ -x "$cand" ] && { SB="$cand"; break; }
	done
fi

REALITY_PRIV="cHJpdmF0ZS1rZXktc3R1Yi1iYXNlNjR1cmwtdmFsdWUtMDAx"  # stub; only used when sing-box is absent
if [ -n "$SB" ]; then
	_kp="$("$SB" generate reality-keypair 2>/dev/null)"
	_priv="$(printf '%s\n' "$_kp" | awk '/PrivateKey/{print $2; exit}')"
	[ -n "$_priv" ] && REALITY_PRIV="$_priv"
fi

PARAMS="$WORK/params.json"
STATE="$WORK/identities.json"
jq -n --arg rpriv "$REALITY_PRIV" '{
	node_address: "node.example.invalid",
	donor_host: "www.example.invalid", donor_sni: "www.example.invalid",
	reality_private_key: $rpriv,
	reality_public_key: "cHVibGljLWtleS1zdHViLWJhc2U2NHVybC12YWx1ZS0wMDAwMQ",
	short_ids: [ "0123abcd" ],
	tls_sni: "tls.example.invalid",
	grpc_service_name: "grpc.health.v1.Health", xhttp_path: "/",
	ss_password: "x", trojan_password: "x", hysteria2_password: "x", shadowtls_password: "x",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_reality_grpc_enabled:   true, vless_reality_grpc_port:   8443
}' > "$PARAMS"
jq -n '{ version: 1, clients: [ { name: "alice", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z" } ] }' > "$STATE"

# --- Render the realistic default config (engine: sing-box, against the DEPLOYED template default). ---
SERVER="$WORK/server.json"
if ! bash "$CTL" render-server --engine singbox --params "$PARAMS" --state "$STATE" --out "$SERVER" 2>"$WORK/render.err"; then
	badln "shell render of the default set FAILED: $(tr -d '\n' < "$WORK/render.err" | cut -c1-200)"
	printf '\n-- Result --\nFAIL: could not render a default sing-box config to load-check.\n' >&2
	exit 1
fi
jq -e . "$SERVER" >/dev/null 2>&1 || { badln "rendered config is not valid JSON"; printf '\n-- Result --\nFAIL\n' >&2; exit 1; }
okln "shell render produced a default sing-box config ($(jq '.inbounds | length' "$SERVER") inbound(s): vision+grpc)"

# --- The load check: the engine must actually LOAD what we render (SB was resolved above; absent => the
#     load half SKIPs, NOT a failure, and the render-guard half below still runs). ---
if [ -z "$SB" ]; then
	printf '\nSKIP (load half): no sing-box binary present (PATH or /usr/local/bin, /usr/bin) — `sing-box check`\n'
	printf '      cannot run here. This is NOT a failure (jq-only host/CI lane); on a node with sing-box it\n'
	printf '      runs the real load check. The render-guard fail-closed half below still runs.\n'
else
	printf 'sing-box: %s\n' "$SB"
	# The decisive assertion: the engine LOADS the rendered config. `sing-box check` parses + validates
	# the whole config (transports included) without binding ports or touching the network.
	if "$SB" check -c "$SERVER" >"$WORK/check.out" 2>&1; then
		okln "sing-box check LOADS the rendered default config (engine can serve what we render)"
	else
		badln "sing-box check REJECTED the rendered default config: $(tr -d '\n' < "$WORK/check.out" | cut -c1-300)"
	fi
fi

# --- Render-guard fail-closed (ALWAYS runs; bash + jq only): enabling vless-xhttp-tls on the sing-box
#     engine MUST be REFUSED by the shell render, because xhttp is Xray-core only and sing-box would
#     crash on load. This proves the guard in control/lib/render_singbox.sh is present and effective —
#     the positive assertion of the bug fix. If the render SUCCEEDS, the guard is missing/broken and a
#     crash-on-load config would have shipped: that is a FAIL. ---
XH_PARAMS="$WORK/params.xhttptls.json"
XH_OUT="$WORK/server.xhttptls.json"; rm -f "$XH_OUT"
jq '. + { vless_xhttp_tls_enabled: true, vless_xhttp_tls_port: 2087, xhttp_path_tls: "/owncert-tls", tls_sni: "tls.example.invalid" }' "$PARAMS" > "$XH_PARAMS"
if bash "$CTL" render-server --engine singbox --params "$XH_PARAMS" --state "$STATE" --out "$XH_OUT" >"$WORK/xh.err" 2>&1 && [ -s "$XH_OUT" ]; then
	badln "vless-xhttp-tls was RENDERED on the sing-box engine (the render-guard is MISSING — this config would crash sing-box on load with 'unknown transport type: xhttp')"
else
	okln "vless-xhttp-tls is REFUSED on the sing-box engine (render-guard fail-closed; xhttp is Xray-core only — no crash-on-load config ships)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a rendered sing-box config did not load, or the xhttp-tls render-guard is missing.\n' >&2
	exit 1
fi
printf 'PASS: the default sing-box config loads (or load-half skipped, no binary) and xhttp-tls is refused fail-closed.\n'
exit 0
