#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# aggregate_tolerates_heterogeneity.sh — conformance: a member the client engine cannot dial costs that
# MEMBER, never the other nodes; and the fail-closed line sits on the RESULT, not on the inputs.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   MEASURED 2026-08-19 against two live nodes. `aggregate` refused BOTH of them outright — it died on the
#   first ShadowTLS endpoint before xhttp even mattered — so the multi-node client profile that is the
#   whole point of the merge could not be produced at all, from any pair of real nodes in the population.
#
#   The refusals themselves were right. An ss:// ShadowTLS share-link carries only the INNER shadowsocks
#   material, not the v3 handshake password/version, so a bare shadowsocks outbound rebuilt from it would
#   dial the ShadowTLS port with the wrong credential. And sing-box has no xhttp transport at all, so one
#   xhttp outbound makes it reject the WHOLE profile. What was wrong is that each refusal was fatal to the
#   entire fold: one member the client cannot represent took every other node down with it.
#
#   A fungi network is heterogeneous BY DESIGN — different nodes offer different channels to clients, and
#   reach each other over different ones again. An aggregate that only works when every member happens to
#   be representable is an aggregate that does not work.
#
# THE CONTRACT THIS PINS
#   1. A heterogeneous fold SUCCEEDS. Two bundles that both carry ShadowTLS and xhttp still produce a
#      profile.
#   2. What cannot be dialled is ABSENT — no xhttp transport, no outbound derived from a ShadowTLS link.
#   3. What was dropped is NAMED. Silent truncation is the worse failure: the operator would hand out a
#      profile believing it covers transports it does not.
#   4. The survivors still clear the RP-0013 independent-family floor, and a fold that does NOT clear it is
#      REFUSED. This is where fail-closed belongs: dropping an undialable member is safe, handing back a
#      single-family profile is not — one block then takes the client's last path.
#   5. Go and shell agree on exactly which members were dropped. Two producers that disagree about what a
#      client can dial is the same defect wearing a second hat.
#
#   Every row DRIVES the shipped producer over rendered bundles. On the pre-fix tree row 1 fails outright,
#   which is the point: a gate that reads the source for a `myc_die` would have passed the broken version
#   just as happily as the fixed one.
#
# OFFLINE. No node, no network, no root. Exit: 0 = the aggregate tolerates a heterogeneous network;
# 1 = it does not; 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
CTL="$REPO_ROOT/control/myceliumctl"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== a member the client cannot dial costs that member, not the network ==\n'
printf 'repo: %s\n\n' "$REPO_ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.aggh.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

jq -n '{ version:1, clients:[ { name:"alice", id:"a1b2c3d4-e5f6-7890-abcd-ef0123456789",
	created:"2026-01-01T00:00:00Z", password:"idpw/1" } ] }' > "$WORK/identities.json"

# ---------------------------------------------------------------------------------------------------
# The fixtures. Both nodes serve ShadowTLS and xhttp — the two shapes a sing-box client cannot be handed
# — alongside transports it can. This is the shape the live population actually has: measured on two real
# nodes, 7 endpoints each, 2 of them unrepresentable, on BOTH.
# ---------------------------------------------------------------------------------------------------
mkparams() { # mkparams <file> <addr> <extra-json>
	jq -n --arg a "$2" --argjson x "$3" '{
		node_address:$a, donor_host:"www.example.invalid", donor_sni:"www.example.invalid",
		reality_public_key:"PUBKEY_aB-cd12", short_ids:["0123abcd"], tls_sni:($a),
		grpc_service_name:"grpc.health.v1.Health", xhttp_path:"/x?a=1", xhttp_path_tls:"/xt#y", ws_path:"/ws&z",
		ss_password:"ss/pw+1", trojan_password:"tr&pw#3", hysteria2_password:"hy2:pw@2",
		shadowtls_password:"stls&pw/4", shadowtls_handshake_server:"www.example.invalid",
		shadowtls_handshake_port:443
	} * $x' > "$1"
}
# Heterogeneous, and rich enough that the survivors span more than one family.
mkparams "$WORK/pA.json" "nodeA.example.invalid" '{
	"vless_reality_vision_enabled":true, "vless_xhttp_tls_enabled":true, "vless_ws_tls_enabled":true,
	"hysteria2_enabled":true, "tuic_enabled":true, "shadowsocks_enabled":true, "shadowtls_enabled":true }'
mkparams "$WORK/pB.json" "nodeB.example.invalid" '{
	"vless_reality_vision_enabled":true, "vless_reality_xhttp_enabled":true, "hysteria2_enabled":true,
	"shadowtls_enabled":true }'
# Single-family-after-drop: everything these two serve is either REALITY (one family) or undialable.
mkparams "$WORK/pC.json" "nodeC.example.invalid" '{
	"vless_reality_vision_enabled":true, "vless_reality_xhttp_enabled":true, "shadowtls_enabled":true }'
mkparams "$WORK/pD.json" "nodeD.example.invalid" '{
	"vless_reality_vision_enabled":true, "shadowtls_enabled":true }'

for n in A B C D; do
	if ! bash "$CTL" bundle --params "$WORK/p$n.json" --state "$WORK/identities.json" \
		--out "$WORK/b$n.json" 2>"$WORK/e"; then
		printf 'FAIL: could not render fixture bundle %s: %s\n' "$n" "$(cut -c1-200 "$WORK/e")" >&2; exit 2
	fi
done

# The fixtures are only worth what they contain: assert the undialable shapes are actually PRESENT, or
# every row below would pass by measuring nothing (§2.2 item 12).
have_stls="$(jq -r '[.endpoints[]|select(.link|test("plugin=shadow-tls"))]|length' "$WORK/bA.json")"
have_xh="$(jq -r '[.endpoints[]|select(.link|test("type=xhttp"))]|length' "$WORK/bA.json")"
if [ "${have_stls:-0}" -lt 1 ] || [ "${have_xh:-0}" -lt 1 ]; then
	printf 'FAIL: the fixture does not contain the shapes under test (shadowtls=%s xhttp=%s) — this gate would pass vacuously.\n' \
		"$have_stls" "$have_xh" >&2; exit 2
fi
printf '  ..    fixture node A carries %s ShadowTLS and %s xhttp endpoint(s) the client cannot dial\n' "$have_stls" "$have_xh"

# ---------------------------------------------------------------------------------------------------
# 1 + 2 + 3. The fold survives, the undialable members are gone, and their loss is stated.
# ---------------------------------------------------------------------------------------------------
printf '\n-- a heterogeneous pair still produces a profile --\n'
if bash "$CTL" aggregate --bundle "$WORK/bA.json" --name nodeA \
	--bundle "$WORK/bB.json" --name nodeB --out "$WORK/sh.json" 2>"$WORK/she"; then
	ok "two nodes that both serve ShadowTLS and xhttp still fold into one client profile"
else
	badln "the fold was REFUSED: $(tr -d '\n' < "$WORK/she" | cut -c1-220). A network whose nodes deliberately offer different transports is the design, not an error — one member the client cannot represent must cost that member, not every other node."
fi

if [ -s "$WORK/sh.json" ]; then
	n_xh="$(jq '[.outbounds[]?|select(.transport.type=="xhttp")]|length' "$WORK/sh.json")"
	[ "${n_xh:-1}" -eq 0 ] \
		&& ok "no xhttp outbound survived — sing-box has no such transport and one would void the whole profile" \
		|| badln "$n_xh xhttp outbound(s) are in the merged profile; sing-box refuses the entire config on the first one, so every other node in the fold becomes undialable too"

	# A ShadowTLS endpoint would land as a bare shadowsocks outbound on the ShadowTLS port. Compare
	# against the port the fixture declares rather than against a tag, so a renamed tag cannot hide it.
	stls_port="$(jq -r '.shadowtls_port // 8446' "$WORK/pA.json")"
	n_stls="$(jq --argjson p "${stls_port:-8446}" \
		'[.outbounds[]?|select(.type=="shadowsocks" and .server_port==$p)]|length' "$WORK/sh.json")"
	[ "${n_stls:-1}" -eq 0 ] \
		&& ok "no bare shadowsocks outbound points at the ShadowTLS port ($stls_port)" \
		|| badln "the merged profile has $n_stls shadowsocks outbound(s) on the ShadowTLS port $stls_port — the share-link never carried the v3 handshake password, so that outbound dials a ShadowTLS listener with the wrong credential and can only fail"

	for want in shadowtls xhttp; do
		grep -qi "$want" "$WORK/she" \
			&& ok "the dropped $want member is named to the operator" \
			|| badln "nothing on stderr names the dropped $want member. Silent truncation is worse than the refusal it replaced: the operator hands out a profile believing it covers a transport it does not."
	done

	n_out="$(jq '[.outbounds[]?|select(.type|test("^(urltest|selector|direct|block)$")|not)]|length' "$WORK/sh.json")"
	[ "${n_out:-0}" -ge 2 ] \
		&& ok "$n_out dialable outbound(s) survived across the two nodes" \
		|| badln "only ${n_out:-0} dialable outbound(s) survived — dropping the undialable members must not empty the profile"
else
	badln "no profile was written at all"
fi

# ---------------------------------------------------------------------------------------------------
# 4. The fail-closed line, moved to the result.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and refuses when what survives is not enough --\n'
if bash "$CTL" aggregate --bundle "$WORK/bC.json" --name nodeC \
	--bundle "$WORK/bD.json" --name nodeD --out "$WORK/sh2.json" 2>"$WORK/she2"; then
	fams="$(jq -r --slurpfile v "$REPO_ROOT/control/vocab.json" '
		[ .outbounds[]|select((.type|test("^(urltest|selector|direct|block)$"))|not)
		  | .tag as $t | ($v[0].protos[]| . as $pr |select($t|endswith("."+$pr.proto))|$pr.class)
		  | ($v[0].block_families[.]//empty) ]|unique|join(" ")' "$WORK/sh2.json" 2>/dev/null)"
	badln "a fold whose survivors span only [$fams] was ACCEPTED. Tolerating an undialable member must not become tolerating a profile with no independent second path — one block would take the client's last route (RP-0013)."
else
	if grep -qi 'RP-0013\|floor\|famil' "$WORK/she2"; then
		ok "a fold that falls below the independent-family floor is refused, and says so"
	else
		badln "the single-family fold was refused, but for an unstated reason: $(tr -d '\n' < "$WORK/she2" | cut -c1-200). The message has to name the floor, or the operator cannot tell a real family shortfall from a parse error."
	fi
fi

# ---------------------------------------------------------------------------------------------------
# 5. Both producers drop the same members.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and both producers agree on what the client cannot dial --\n'
GO=""
if command -v go >/dev/null 2>&1; then GO="$(command -v go)"; else
	for c in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do [ -x "$c" ] && { GO="$c"; break; }; done
fi
if [ -z "$GO" ]; then
	printf '  SKIP  no Go toolchain here; the Go/CI lane runs this row (aggregate_render_go_equiv covers byte-equality)\n'
elif ( cd "$REPO_ROOT" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
		"$GO" build -o "$WORK/spine" ./cmd/myceliumctl ) >/dev/null 2>&1; then
	if "$WORK/spine" aggregate --bundle "$WORK/bA.json" --name nodeA \
		--bundle "$WORK/bB.json" --name nodeB --out "$WORK/go.json" 2>"$WORK/goe"; then
		a="$(jq -S -c '[.outbounds[].tag]|sort' "$WORK/sh.json" 2>/dev/null)"
		b="$(jq -S -c '[.outbounds[].tag]|sort' "$WORK/go.json" 2>/dev/null)"
		[ -n "$a" ] && [ "$a" = "$b" ] \
			&& ok "Go and shell keep exactly the same members" \
			|| badln "the two producers disagree about what survives — shell=$a go=$b. A client would get a different network depending on which binary rendered its profile."
		# Agreeing on the OUTCOME is not enough: a producer that drops silently hands the operator a
		# profile they believe is complete. Both must SAY what they left out.
		for want in shadowtls xhttp; do
			grep -qi "$want" "$WORK/goe" \
				&& ok "the Go producer names its dropped $want member too" \
				|| badln "the Go fold dropped the $want member without telling anyone (stderr: $(tr -d '\n' < "$WORK/goe" | cut -c1-160)). Silent truncation is the failure this change must not introduce."
		done
	else
		badln "the Go fold refused the heterogeneous pair: $(tr -d '\n' < "$WORK/goe" | cut -c1-200)"
	fi
	if "$WORK/spine" aggregate --bundle "$WORK/bC.json" --name nodeC \
		--bundle "$WORK/bD.json" --name nodeD --out "$WORK/go2.json" 2>/dev/null; then
		badln "the Go fold ACCEPTED the single-family pair the shell refuses — the floor must hold on both sides"
	else
		ok "and both refuse the single-family fold"
	fi
else
	printf '  SKIP  the Go spine did not build here; CI runs this row\n'
fi

# ---------------------------------------------------------------------------------------------------
# 6. THE PREDICATE ITSELF — the two producers must agree on ADVERSARIAL links, not just on real ones.
#
# The shell used to decide this with `case "$link" in *plugin=shadow-tls*|*type=xhttp*)`, a glob that
# matches ANYWHERE in the link: inside the #fragment, inside a percent-encoded value. Go strips the
# fragment first and requires BOTH the scheme and the PARSED query key (OutboundSkipReason). Two owners
# of one predicate, and nothing had ever driven them with an input that separates them — every fixture
# used links where the two happen to agree. No real bundle triggers it (tags come from the closed proto
# vocabulary, paths are percent-encoded), which is exactly when it is cheap to close and worth pinning.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the two producers agree on what "undialable" MEANS --\n'
# link | expect: skip|keep
ADVERSARIAL='ss://YWVzOnB3@h.example.invalid:8446?plugin=shadow-tls&sni=x#tag|skip
vless://11111111-2222-3333-4444-555555555555@h.example.invalid:443?type=xhttp&path=%2Fx#tag|skip
vless://11111111-2222-3333-4444-555555555555@h.example.invalid:443?type=tcp&security=reality#type=xhttp|keep
vless://11111111-2222-3333-4444-555555555555@h.example.invalid:443?type=ws&path=%2Ftype%3Dxhttp#tag|keep
ss://YWVzOnB3@h.example.invalid:8388?sni=x#plugin=shadow-tls|keep
hysteria2://pw@h.example.invalid:8444?sni=x#tag|keep'

shell_skip() { # -> "skip" | "keep"
	local r
	r="$(
		MYC_ROOT="$REPO_ROOT/control" ARTIFACT_ROOT="$REPO_ROOT" bash -c '
			. "$1/common.sh"; . "$1/jqlib.sh"; . "$1/vocab.sh"; . "$1/render_aggregate.sh"
			myc_agg_outbound_skip_reason "$2"' _ "$REPO_ROOT/control/lib" "$1" 2>/dev/null
	)"
	[ -n "$r" ] && printf 'skip' || printf 'keep'
}

if ! MYC_ROOT="$REPO_ROOT/control" ARTIFACT_ROOT="$REPO_ROOT" bash -c '
		. "$1/common.sh"; . "$1/jqlib.sh"; . "$1/vocab.sh"; . "$1/render_aggregate.sh"
		command -v myc_agg_outbound_skip_reason >/dev/null' _ "$REPO_ROOT/control/lib" 2>/dev/null; then
	badln "there is no myc_agg_outbound_skip_reason — the shell still decides 'undialable' inline, so the fold and the single-link verb are two owners of one predicate and nothing compares them"
else
	while IFS='|' read -r lnk want; do
		[ -n "$lnk" ] || continue
		got="$(shell_skip "$lnk")"
		[ "$got" = "$want" ] \
			&& ok "shell: $want — $(printf '%s' "$lnk" | cut -c1-58)" \
			|| badln "shell said '$got', expected '$want', for: $lnk. A glob over the whole link matches inside the #fragment and inside percent-encoded values; Go strips the fragment and requires the scheme plus the parsed query key. Whichever is wrong, the two producers hand a client different networks."
	done <<EOF
$ADVERSARIAL
EOF
fi

if [ -n "$GO" ] && [ -x "$WORK/spine" ]; then
	while IFS='|' read -r lnk want; do
		[ -n "$lnk" ] || continue
		# The single-link verb REFUSES exactly the links the fold drops, and for the same reason.
		if "$WORK/spine" link-outbound --tag t --link "$lnk" >/dev/null 2>"$WORK/lo.err"; then got=keep; else got=skip; fi
		[ "$got" = "$want" ] \
			&& ok "Go:    $want — $(printf '%s' "$lnk" | cut -c1-58)" \
			|| badln "Go said '$got', expected '$want', for: $lnk ($(tr -d '\n' < "$WORK/lo.err" | cut -c1-110))"
	done <<EOF
$ADVERSARIAL
EOF
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the aggregate does not tolerate a heterogeneous network.\n' >&2
	exit 1
fi
printf 'PASS: undialable members are dropped and named; the survivors still clear the RP-0013 floor.\n'
exit 0
