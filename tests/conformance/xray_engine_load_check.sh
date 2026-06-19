#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# xray_engine_load_check.sh — conformance (ADR-0032 prototype, P1): the Xray engine render path for the
# Xray-only transport `vless-xhttp-tls` (VLESS + XHTTP over genuine single-layer TLS, own cert, NOT
# REALITY) produces a config that ACTUALLY LOADS in `xray run -test`. This is the Xray peer of the
# sing-box `engine_load_check` gate, and lands BEFORE the render path is wired into any live apply
# (gates-first / inert-before-behaviour). It proves the dual-engine capability is real: the engine can
# serve what the toolchain renders.
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-XRAY: the offline suite runs on hosts without an xray binary (the maintainer's macOS host;
# the jq-only CI lane; a sing-box-only node). There the `xray run -test` LOAD half SKIPs (a printed
# note) — NOT a failure, exactly like engine_load_check skips without sing-box. The RENDER + SHAPE half
# (bash + jq only) ALWAYS runs. Where xray IS present (the xray node) the load check runs for real.
#
# Exit: 0 = the rendered xhttp-tls config has the right shape AND loads in xray (or the load half was
#       skipped, no xray); 1 = a broken render / wrong shape / a config xray rejects; 2 = usage/env err.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
LIB="$REPO_ROOT/control/lib"

printf '== xray engine load check (shell render of vless-xhttp-tls -> xray run -test loads it) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.xelc.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# Source the render libs standalone (the xhttp-tls render fn is an INERT prototype not yet exposed via
# the myceliumctl CLI dispatch — ADR-0032). Order mirrors myceliumctl's loader. The libs expect
# MYC_ROOT/MYC_LIB (myceliumctl sets them); provide them so a standalone source under `set -u` does not
# trip on an unbound MYC_ROOT (e.g. vocab.sh references it at source time).
MYC_ROOT="$REPO_ROOT/control"
MYC_LIB="$LIB"
export MYC_ROOT MYC_LIB
# shellcheck disable=SC1090
for l in common.sh jqlib.sh vocab.sh identity.sh render.sh; do
	. "$LIB/$l" 2>/dev/null || { printf 'FAIL: cannot source control/lib/%s\n' "$l" >&2; exit 2; }
done

# Resolve an xray binary: PATH then the well-known node install locations. Absent => the LOAD half SKIPs.
XRAY=""
if command -v xray >/dev/null 2>&1; then
	XRAY="$(command -v xray)"
else
	for cand in /usr/local/bin/xray /usr/bin/xray; do
		[ -x "$cand" ] && { XRAY="$cand"; break; }
	done
fi

# Own-cert family: `xray run -test` READS the TLS cert/key files off disk. When xray + openssl are present,
# mint a short-lived self-signed cert and point params at it (a real node has a provisioned cert here);
# without xray the load half SKIPs, so the files are moot.
mkdir -p "$WORK/tls"
CERT="$WORK/tls/fullchain.pem"; KEY="$WORK/tls/privkey.pem"
if [ -n "$XRAY" ] && command -v openssl >/dev/null 2>&1; then
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" \
		-days 1 -subj "/CN=tls.example.invalid" >/dev/null 2>&1 || true
fi

PARAMS="$WORK/params.json"; STATE="$WORK/identities.json"; OUT="$WORK/xray.server.json"
jq -n --arg cert "$CERT" --arg key "$KEY" '{
	vless_xhttp_tls_port: 2087,
	tls_sni: "tls.example.invalid",
	tls_certificate_path: $cert, tls_private_key_path: $key,
	xhttp_path_tls: "/xhttp"
}' > "$PARAMS"
jq -n '{ version: 1, clients: [ { name: "alice", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z" } ] }' > "$STATE"

TEMPLATE="$REPO_ROOT/nodes/dataplane/vless-xhttp-tls/xray.server.template.json"
[ -f "$TEMPLATE" ] || { badln "xray xhttp-tls template missing: $TEMPLATE"; printf '\n-- Result --\nFAIL\n' >&2; exit 1; }

# --- RENDER half (always runs: bash + jq only). Subshell-wrap: the render fn uses myc_die (exit 1). ---
if ( myc_render_xray_xhttp_tls "$TEMPLATE" "$PARAMS" "$STATE" "$OUT" ) >"$WORK/render.err" 2>&1; then
	okln "shell rendered a vless-xhttp-tls xray config"
else
	badln "render FAILED: $(tr -d '\n' < "$WORK/render.err" | cut -c1-200)"
	printf '\n-- Result --\nFAIL: could not render a vless-xhttp-tls config to load-check.\n' >&2
	exit 1
fi
jq -e . "$OUT" >/dev/null 2>&1 || { badln "rendered config is not valid JSON"; printf '\n-- Result --\nFAIL\n' >&2; exit 1; }

# --- SHAPE assertions (always): the Xray-only XHTTP genuine-TLS shape, NOT REALITY. ---
net="$(jq -r '.inbounds[0].streamSettings.network' "$OUT")"
sec="$(jq -r '.inbounds[0].streamSettings.security' "$OUT")"
hascert="$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile // empty' "$OUT")"
hasreality="$(jq -r '.inbounds[0].streamSettings.realitySettings // empty' "$OUT")"
sni="$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName // empty' "$OUT")"
[ "$net" = "xhttp" ]   && okln "transport network is xhttp (Xray-core only)"            || badln "network is '$net', want xhttp"
[ "$sec" = "tls" ]     && okln "security is genuine tls (own cert, not reality)"         || badln "security is '$sec', want tls"
[ -n "$hascert" ]      && okln "own certificate is set (genuine single-layer TLS)"       || badln "no own certificate in tlsSettings"
[ -z "$hasreality" ]   && okln "no realitySettings (own-cert family, not REALITY)"       || badln "unexpected realitySettings present"
[ -n "$sni" ]          && okln "serverName (own SNI) is set: $sni"                       || badln "serverName is empty (C03 own-SNI must be set)"

# --- LOAD half (skip-if-no-xray). The decisive proof: the engine LOADS what we render. ---
if [ -z "$XRAY" ]; then
	printf '\nSKIP (load half): no xray binary present (PATH or /usr/local/bin, /usr/bin) — `xray run -test`\n'
	printf '      cannot run here. NOT a failure (jq-only host / sing-box-only node); on the xray node it runs\n'
	printf '      the real load check. The render + shape half above ran.\n'
else
	printf 'xray: %s\n' "$XRAY"
	# `xray run -test -c` parses + validates the whole config (transport + TLS cert files) WITHOUT binding
	# ports or touching the network, then exits.
	if "$XRAY" run -test -c "$OUT" >"$WORK/test.out" 2>&1; then
		okln "xray run -test LOADS the rendered vless-xhttp-tls config (the engine can serve what we render)"
	else
		badln "xray run -test REJECTED the rendered config: $(tr -d '\n' < "$WORK/test.out" | cut -c1-300)"
	fi
fi

if [ "$fail" -eq 0 ]; then
	printf '\n-- Result --\nPASS: the Xray engine render path produces a vless-xhttp-tls config of the right shape that loads (or the load half was skipped, no xray).\n'
	exit 0
fi
printf '\n-- Result --\nFAIL: the Xray xhttp-tls render path is broken — see above.\n' >&2
exit 1
