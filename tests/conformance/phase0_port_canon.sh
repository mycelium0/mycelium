#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# phase0_port_canon.sh — conformance: the canonical per-protocol port map is consistent
# everywhere it is declared. There is exactly ONE source of truth; every reference must agree.
# Author: mindicator & silicon bags quartet.
#
# CANONICAL PORT MAP (Phase 0)
#   vless_reality_vision  443   / tcp   (primary, default-on)
#   vless_reality_grpc    8443  / tcp
#   vless_reality_xhttp   2096  / tcp
#   hysteria2             8444  / udp
#   tuic                  8445  / udp
#   shadowsocks2022       8388  / tcp+udp
#   shadowtls             8446  / tcp   (NOTE: must be 8446, not any other value)
#   trojan                8447  / tcp
#   amneziawg             51820 / udp
#
# SOURCES CHECKED (each must agree with the canon above; a source that is absent is SKIPPED with
# a note, not failed — so the gate is robust to optional docs):
#   * infra/ansible/group_vars/all.yml.example         (singbox_port_* / awg_listen_port)
#   * infra/ansible/roles/singbox/defaults/main.yml    (singbox_port_*)
#   * nodes/dataplane/singbox/server.template.json     (inbound listen_port by tag, via jq)
#   * nodes/dataplane/PORTS.md                          (a "<proto> ... <port>" table, if present)
#   * control/lib/render_singbox.sh                     (per-protocol myc_params_get defaults)
#
# Parses with jq (the template) + grep/sed (everything else). bash + jq only.
#
# Exit: 0 = every present source agrees with the canon, 1 = a mismatch (drift) was found,
#       2 = usage/env error (jq missing).

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for phase0_port_canon.sh\n' >&2; exit 2; }

GROUP_VARS="$REPO_ROOT/infra/ansible/group_vars/all.yml.example"
ROLE_DEFAULTS="$REPO_ROOT/infra/ansible/roles/singbox/defaults/main.yml"
# The DEPLOYED template (node-bootstrap.sh renders this one); the GO evidence must describe the
# shipped artifact, not the superseded server.template.json (Audit-0004 F-002; unify in RP-0003 §W5).
SB_TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
PORTS_MD="$REPO_ROOT/nodes/dataplane/PORTS.md"
RENDER_SB="$REPO_ROOT/control/lib/render_singbox.sh"

fail=0
okln()   { printf '  ok    %s\n' "$1"; }
badln()  { printf '  FAIL  %s\n' "$1"; fail=1; }
skipln() { printf '  SKIP  %s\n' "$1"; }
note()   { printf '\n-- %s --\n' "$1"; }

printf '== phase 0 port canon check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# Canonical protocol -> port (the single source of truth, embedded here).
# Space-separated "proto=port" pairs; iterated in a fixed order.
CANON="vless_reality_vision=443 vless_reality_grpc=8443 vless_reality_xhttp=2096 \
hysteria2=8444 tuic=8445 shadowsocks2022=8388 shadowtls=8446 trojan=8447 amneziawg=51820"

canon_port() {
	# canon_port PROTO -> echo the canonical port.
	local p
	for p in $CANON; do
		case "$p" in "$1="*) printf '%s' "${p#*=}"; return 0 ;; esac
	done
	printf ''
}

# assert SOURCE PROTO GOT — compare an extracted value against the canon.
assert() {
	local src proto got want
	src="$1"; proto="$2"; got="$3"
	want="$(canon_port "$proto")"
	if [ -z "$got" ]; then
		badln "$src: $proto port not found (expected $want)"
	elif [ "$got" = "$want" ]; then
		okln "$src: $proto = $got"
	else
		badln "$src: $proto = $got  (CANON is $want)"
	fi
}

# yaml_port FILE KEY -> echo the integer value of a `key: <int>` line (comment-stripped), or empty
# if the key is absent. The whole pipeline is `|| true`-guarded so a legitimate no-match (e.g. the
# amneziawg port, which lives only in group_vars) — where an inner `grep` exits non-zero on empty
# input — does not trip `set -e` / `pipefail`.
yaml_port() {
	local file key
	file="$1"; key="$2"
	{ grep -E "^[[:space:]]*${key}[[:space:]]*:" "$file" 2>/dev/null \
		| grep -v '^[[:space:]]*#' \
		| head -n1 \
		| sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//; s/[^0-9].*$//"; } || true
}

# ---------------------------------------------------------------------------
# group_vars/all.yml.example and roles/singbox/defaults/main.yml share the singbox_port_* keys
# (and awg_listen_port for the AmneziaWG path). Map canon proto -> the var key used in YAML.
# ---------------------------------------------------------------------------
yaml_key_for() {
	case "$1" in
		vless_reality_vision) printf 'singbox_port_vless_vision' ;;
		vless_reality_grpc)   printf 'singbox_port_vless_grpc' ;;
		vless_reality_xhttp)  printf 'singbox_port_vless_xhttp' ;;
		hysteria2)            printf 'singbox_port_hysteria2' ;;
		tuic)                 printf 'singbox_port_tuic' ;;
		shadowsocks2022)      printf 'singbox_port_ss2022' ;;
		shadowtls)            printf 'singbox_port_shadowtls' ;;
		trojan)               printf 'singbox_port_trojan' ;;
		amneziawg)            printf 'awg_listen_port' ;;
		*)                    printf '' ;;
	esac
}

check_yaml_source() {
	local label file proto key got
	label="$1"; file="$2"
	if [ ! -f "$file" ]; then
		skipln "$label not present (${file#"$REPO_ROOT"/}) — skipping"
		return 0
	fi
	for proto in vless_reality_vision vless_reality_grpc vless_reality_xhttp hysteria2 tuic \
		shadowsocks2022 shadowtls trojan amneziawg; do
		key="$(yaml_key_for "$proto")"
		[ -n "$key" ] || continue
		got="$(yaml_port "$file" "$key")"
		# amneziawg lives only in group_vars; the singbox role defaults legitimately omit it.
		if [ "$proto" = "amneziawg" ] && [ -z "$got" ] && [ "$label" = "roles/singbox/defaults/main.yml" ]; then
			skipln "$label: amneziawg port not declared here (separate role) — skipping"
			continue
		fi
		assert "$label" "$proto" "$got"
	done
}

note "group_vars/all.yml.example"
check_yaml_source "group_vars/all.yml.example" "$GROUP_VARS"

note "roles/singbox/defaults/main.yml"
check_yaml_source "roles/singbox/defaults/main.yml" "$ROLE_DEFAULTS"

# ---------------------------------------------------------------------------
# sing-box server template (JSON): inbound listen_port keyed by tag, read with jq.
# ---------------------------------------------------------------------------
note "nodes/dataplane/singbox/server.template.renderer.json"
if [ ! -f "$SB_TEMPLATE" ]; then
	skipln "sing-box template not present — skipping"
elif ! jq -e . "$SB_TEMPLATE" >/dev/null 2>&1; then
	badln "nodes/dataplane/singbox/server.template.json: not valid JSON"
else
	tmpl_port_for_tags() {
		# echo the listen_port of the FIRST inbound whose tag matches any of the given tags.
		local t
		for t in "$@"; do
			jq -r --arg t "$t" '
				.inbounds[]? | select(.tag == $t) | .listen_port // empty
			' "$SB_TEMPLATE" 2>/dev/null | head -n1 | grep -E '^[0-9]+$' && return 0
		done
		printf ''
	}
	assert "singbox template" "vless_reality_vision" "$(tmpl_port_for_tags vless-reality-vision-in vless-reality-vision)"
	assert "singbox template" "vless_reality_grpc"   "$(tmpl_port_for_tags vless-reality-grpc-in vless-reality-grpc)"
	assert "singbox template" "vless_reality_xhttp"  "$(tmpl_port_for_tags vless-reality-xhttp-in vless-reality-xhttp)"
	assert "singbox template" "hysteria2"            "$(tmpl_port_for_tags hysteria2-in hysteria2)"
	assert "singbox template" "tuic"                 "$(tmpl_port_for_tags tuic-v5-in tuic-in tuic)"
	assert "singbox template" "shadowsocks2022"      "$(tmpl_port_for_tags shadowsocks-2022-in shadowsocks-in)"
	assert "singbox template" "shadowtls"            "$(tmpl_port_for_tags shadowtls-v3-in shadowtls-in)"
	assert "singbox template" "trojan"               "$(tmpl_port_for_tags trojan-tls-in trojan-in)"
fi

# ---------------------------------------------------------------------------
# nodes/dataplane/PORTS.md (optional doc table): "<proto words> ... <port>". We look for the
# canonical port appearing on a line that also names the protocol. Skipped entirely if absent.
# ---------------------------------------------------------------------------
note "nodes/dataplane/PORTS.md"
if [ ! -f "$PORTS_MD" ]; then
	skipln "PORTS.md not present — skipping (optional doc)"
else
	md_has() {
		# md_has REGEX PORT -> 0 if a line matches REGEX (case-insensitive) and contains PORT.
		grep -iE "$1" "$PORTS_MD" 2>/dev/null | grep -qE "(^|[^0-9])$2([^0-9]|$)"
	}
	check_md() {
		local proto regex want
		proto="$1"; regex="$2"; want="$(canon_port "$proto")"
		if md_has "$regex" "$want"; then
			okln "PORTS.md: $proto = $want"
		else
			badln "PORTS.md: $proto port $want not found on a line naming the protocol"
		fi
	}
	check_md "vless_reality_vision" 'vision'
	check_md "vless_reality_grpc"   'grpc'
	check_md "vless_reality_xhttp"  'xhttp'
	check_md "hysteria2"            'hysteria'
	check_md "tuic"                 'tuic'
	check_md "shadowsocks2022"      'shadowsocks|ss-?2022|ss2022'
	check_md "shadowtls"           'shadowtls'
	check_md "trojan"               'trojan'
	check_md "amneziawg"            'amnezia|awg'
fi

# ---------------------------------------------------------------------------
# control/lib/render_singbox.sh: per-protocol myc_params_get defaults, e.g.
#   p_stls="$(myc_params_get "$params" '.shadowtls_port' '8446')"
#   --argjson stls "$(myc_params_get "$params" '.shadowtls_port' '8446')" \
# We extract the default that follows each '.<proto>_port' params path.
# ---------------------------------------------------------------------------
note "control/lib/render_singbox.sh"
if [ ! -f "$RENDER_SB" ]; then
	skipln "render_singbox.sh not present — skipping"
else
	render_default_for() {
		# render_default_for PARAMSPATH -> the FIRST integer default after that params path.
		# Matches:  '.<path>'  '<int>'   (single-quoted default), possibly with spaces between.
		# `|| true`-guarded so a no-match (or a head SIGPIPE) yields empty instead of tripping
		# `set -e` / `pipefail`; an empty result is reported by assert() as "port not found".
		local path
		path="$1"
		{ grep -oE "'\.${path}'[[:space:]]*'[0-9]+'" "$RENDER_SB" 2>/dev/null \
			| head -n1 \
			| sed -E "s/.*'([0-9]+)'.*/\1/"; } || true
	}
	assert "render_singbox.sh" "vless_reality_vision" "$(render_default_for 'vless_reality_vision_port')"
	assert "render_singbox.sh" "vless_reality_grpc"   "$(render_default_for 'vless_reality_grpc_port')"
	assert "render_singbox.sh" "vless_reality_xhttp"  "$(render_default_for 'vless_reality_xhttp_port')"
	assert "render_singbox.sh" "hysteria2"            "$(render_default_for 'hysteria2_port')"
	assert "render_singbox.sh" "tuic"                 "$(render_default_for 'tuic_port')"
	assert "render_singbox.sh" "shadowsocks2022"      "$(render_default_for 'shadowsocks_port')"
	assert "render_singbox.sh" "shadowtls"            "$(render_default_for 'shadowtls_port')"
	assert "render_singbox.sh" "trojan"               "$(render_default_for 'trojan_port')"
fi

# ---------------------------------------------------------------------------
note "Result"
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: port-map drift detected — a source disagrees with the canonical port map\n' >&2
	printf '      (shadowtls MUST be 8446; ss2022 8388; trojan 8447; etc.). Align every reference.\n' >&2
	exit 1
fi
printf 'PASS: every present source agrees with the canonical Phase-0 port map.\n'
exit 0
