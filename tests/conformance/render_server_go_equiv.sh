#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render_server_go_equiv.sh — conformance: the Go server renderer (spec.RenderServer, `myceliumctl
# render-server --engine singbox`) is BYTE-IDENTICAL to the shell producer (control/myceliumctl
# render-server --engine singbox -> myc_sb_render_server) for the same template + params + identities
# (RP-0008 P3-e, the last strangler equivalence gate). The Go renderer encodes the template structure in
# typed structs (the only way to reproduce jq's template-preserving key order in Go); this gate keeps the
# structs in lockstep with the SHIPPED template by diffing against the shell, which reads it. The server
# config carries NO live clock, so it is a straight byte diff. Fixtures exercise the dual-engine filter
# (vless-xhttp-tls enabled MUST be dropped from the sing-box server), the clash_api Bearer secret on/off,
# and the two-hop via_user egress + route rule (P3-e). Until green the shell stays authoritative.
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-GO: the offline jq-only host cannot run the Go side (mirrors the other *_go_equiv gates);
# the Go-node/CI lane runs the diff, and TestRenderServerShape pins the structure where Go is unavailable.
#
# Exit: 0 = byte-identical (or skipped without Go); 1 = the rendered config diverged; 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
CTL="$REPO_ROOT/control/myceliumctl"
TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }
[ -f "$TEMPLATE" ] || { printf 'FAIL: server template not found: %s\n' "$TEMPLATE" >&2; exit 2; }

printf '== render-server Go↔shell byte-equivalence (RP-0008 P3-e) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

GO=""
if command -v go >/dev/null 2>&1; then GO="$(command -v go)"; else
	for c in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do [ -x "$c" ] && { GO="$c"; break; }; done
fi
if [ -z "$GO" ]; then
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the render-server byte-equivalence (TestRenderServerShape mirrors it).\n'
	exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.rsge.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
SPINE="$WORK/spine"
if ! ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 "$GO" build -o "$SPINE" ./cmd/myceliumctl ) >/dev/null 2>&1; then
	printf 'FAIL: could not build the Go spine.\n' >&2; exit 2
fi

fail=0
compare() { # NAME PARAMS STATE
	local name="$1" params="$2" state="$3"
	if ! bash "$CTL" render-server --engine singbox --template "$TEMPLATE" --params "$params" --state "$state" --out "$WORK/sh.json" 2>"$WORK/sh.err"; then
		printf '  FAIL  [%s] shell render failed: %s\n' "$name" "$(tr -d '\n' < "$WORK/sh.err" | cut -c1-200)"; fail=1; return
	fi
	if ! "$SPINE" render-server --engine singbox --params "$params" --state "$state" --out "$WORK/go.json" 2>"$WORK/go.err"; then
		printf '  FAIL  [%s] Go render failed: %s\n' "$name" "$(tr -d '\n' < "$WORK/go.err" | cut -c1-200)"; fail=1; return
	fi
	if diff -u "$WORK/sh.json" "$WORK/go.json" > "$WORK/diff.out" 2>&1; then
		printf '  ok    [%s] byte-identical (%s inbound(s))\n' "$name" "$(jq '.inbounds|length' "$WORK/sh.json")"
	else
		printf '  FAIL  [%s] server config diverged:\n' "$name"; sed 's/^/    /' "$WORK/diff.out" | head -50; fail=1
	fi
}

# Fixture A: ALL params-toggled transports enabled (incl. vless-xhttp-tls — dropped by the dual-engine
# filter), REALITY material + own-cert tls_sni + a clash_api secret, 2 clients (one with a per-identity
# password → the jq `//` fallback branches), distinct per-family paths.
PA="$WORK/a.params.json"; SA="$WORK/a.state.json"
jq -n '{
	node_address:"node.example.invalid", donor_host:"www.example.invalid", donor_sni:"www.example.invalid",
	reality_private_key:"PRIVKEY_aBcD", reality_public_key:"PUB", short_ids:["0123abcd","feed0001"],
	tls_sni:"tls.example.invalid", tls_certificate_path:"/c/full.pem", tls_key_path:"/c/key.pem",
	grpc_service_name:"grpc.health.v1.Health", xhttp_path:"/x?a=1", xhttp_path_tls:"/xt#y", ws_path:"/ws&z",
	ss_password:"ss/pw+1", trojan_password:"tr&pw", hysteria2_password:"hy2:pw", shadowtls_password:"stls@pw",
	shadowtls_handshake_server:"hs.example.invalid", shadowtls_handshake_port:443, clash_secret:"CLASH&SECRET",
	vless_reality_vision_enabled:true, vless_reality_vision_port:443,
	vless_reality_grpc_enabled:true, vless_reality_grpc_port:8443,
	vless_reality_xhttp_enabled:true, vless_reality_xhttp_port:2096,
	vless_xhttp_tls_enabled:true, vless_xhttp_tls_port:2087,
	vless_ws_tls_enabled:true, vless_ws_tls_port:2089,
	hysteria2_enabled:true, hysteria2_port:8444, tuic_enabled:true, tuic_port:8445,
	shadowsocks_enabled:true, shadowsocks_port:8388, shadowtls_enabled:true, shadowtls_port:8446,
	trojan_enabled:true, trojan_port:8447
}' > "$PA"
jq -n '{version:1,clients:[
	{name:"alice", id:"a1b2c3d4-e5f6-7890-abcd-ef0123456789", created:"2026-01-01T00:00:00Z", password:"idpw/1"},
	{name:"bob",   id:"b0b00000-0000-4000-8000-000000000000", created:"2026-01-01T00:00:00Z"}
]}' > "$SA"

# Fixture B: REALITY vision only, NO clash_secret (the experimental block stays template-identical → no
# secret field), default ports, one client.
PB="$WORK/b.params.json"; SB="$WORK/b.state.json"
jq -n '{ node_address:"n2.invalid", donor_host:"d2.invalid", donor_sni:"d2.invalid",
	reality_private_key:"PK2", reality_public_key:"PUB2", short_ids:["feed0002"],
	vless_reality_vision_enabled:true }' > "$PB"
jq -n '{version:1,clients:[{name:"carol", id:"ca501000-0000-4000-8000-000000000000", created:"2026-01-01T00:00:00Z"}]}' > "$SB"

# Fixture C: the TWO-HOP egress (P3-e) — REALITY vision ingress + a two_hop upstream to a DISTINCT node,
# via_user names an existing client. Exercises the appended outbound + auth_user route rule + defaults.
PC="$WORK/c.params.json"; SC="$WORK/c.state.json"
jq -n '{ node_address:"ingress.invalid", donor_host:"www.example.invalid", donor_sni:"www.example.invalid",
	reality_private_key:"PK3", reality_public_key:"PUB3", short_ids:["feed0003"],
	vless_reality_vision_enabled:true, vless_reality_vision_port:443,
	two_hop:{ tag:"to-egress", server:"egress.invalid", server_port:443, uuid:"e9e90000-0000-4000-8000-000000000000",
	          sni:"egress.sni.invalid", via_user:"nl-exit", ws_path:"/ws", ws_host:"egress.sni.invalid" } }' > "$PC"
jq -n '{version:1,clients:[
	{name:"home", id:"40400000-0000-4000-8000-000000000000", created:"2026-01-01T00:00:00Z"},
	{name:"nl-exit", id:"a1e02b65-0000-4000-8000-000000000000", created:"2026-01-01T00:00:00Z"}
]}' > "$SC"

# Fixture D (RP-0011 chunk D / ADR-0034 §3): reachable=false -> node_bind "127.0.0.1" -> every PUBLIC
# inbound binds loopback (the hidden shadowtls detour SS inbound stays 127.0.0.1 regardless). Pins that
# the shell jq rewrite + the Go bind parameterization are byte-identical on the loopback case.
PD="$WORK/d.params.json"; SD="$WORK/d.state.json"
jq -n '{ node_address:"loop.invalid", donor_host:"www.example.invalid", donor_sni:"www.example.invalid",
	reality_private_key:"PK4", reality_public_key:"PUB4", short_ids:["feed0004"],
	tls_sni:"tls.example.invalid", tls_certificate_path:"/c/full.pem", tls_key_path:"/c/key.pem",
	ss_password:"sspw", shadowtls_password:"stlspw", shadowtls_handshake_server:"hs.example.invalid",
	node_bind:"127.0.0.1",
	vless_reality_vision_enabled:true, vless_reality_vision_port:443,
	vless_reality_grpc_enabled:true, vless_reality_grpc_port:8443,
	shadowsocks_enabled:true, shadowsocks_port:8388,
	shadowtls_enabled:true, shadowtls_port:8446 }' > "$PD"
jq -n '{version:1,clients:[{name:"d1", id:"d1d10000-0000-4000-8000-000000000000", created:"2026-01-01T00:00:00Z"}]}' > "$SD"

compare "A: all transports + clash secret + 2 clients (xhttp-tls dropped)" "$PA" "$SA"
compare "B: vision only, no clash secret" "$PB" "$SB"
compare "C: two-hop via_user egress (P3-e)" "$PC" "$SC"
compare "D: reachable=false (node_bind 127.0.0.1) — public inbounds loopback, detour stays loopback" "$PD" "$SD"

printf '\n-- Result --\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS: spec.RenderServer is byte-identical to the shell server renderer (all fixtures, incl. two-hop).\n'
	exit 0
fi
printf 'FAIL: the Go server renderer is not byte-identical — do NOT cut over (RP-0008 P3 equivalence).\n' >&2
exit 1
