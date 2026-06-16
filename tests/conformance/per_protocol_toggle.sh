#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# per_protocol_toggle.sh — conformance: every protocol is individually toggleable and OFF by
# default, except the single primary transport (VLESS+REALITY+XTLS-Vision).
# Author: mindicator & silicon bags quartet.
#
# POLICY (nodes/dataplane/singbox/protocols.md, infra/ansible/group_vars/all.yml.example)
#   The sing-box (PRIMARY) engine exposes one inbound per protocol; an operator exposes only the
#   subset they choose. Each protocol MUST be gated by an `enable_<proto>` toggle in group_vars,
#   and every NON-primary protocol MUST default to OFF (false). The ONLY protocol that is on by
#   default is VLESS+REALITY+XTLS-Vision (`enable_vless_reality_vision: true`) — the primary,
#   maximally-HTTPS-indistinguishable transport.
#
# HOW IT WORKS
#   1. Reads the sing-box server template's inbound `tag`s (jq).
#   2. Maps each inbound to its canonical `enable_<proto>` toggle (the internal loopback ShadowTLS
#      detour inbound is part of `enable_shadowtls`, not a separate toggle).
#   3. For each toggle, asserts it is declared in group_vars/all.yml.example with a boolean default:
#        * vless_reality_vision  -> MUST default true  (the single default-on primary)
#        * every other protocol  -> MUST default false (off until the operator opts in)
#      and that NO non-primary toggle is true.
#
# Parses with jq (template) + grep (the example YAML); no yq / python needed.
#
# Exit: 0 = every protocol is toggleable and correctly defaulted, 1 = a toggle is missing or has
#       the wrong default, 2 = usage/env error (missing tool or input file).

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for per_protocol_toggle.sh\n' >&2; exit 2; }

# Point at the DEPLOYED template — node-bootstrap.sh renders server.template.renderer.json into the
# live config, so the GO/NO-GO conformance evidence describes THAT artifact. It is now the only
# sing-box server template: the superseded server.template.json was removed, closing RP-0003 §W5.
TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
GROUP_VARS="$REPO_ROOT/infra/ansible/group_vars/all.yml.example"

[ -f "$TEMPLATE" ]   || { printf 'FAIL: sing-box template not found: %s\n' "$TEMPLATE" >&2; exit 2; }
[ -f "$GROUP_VARS" ] || { printf 'FAIL: group_vars example not found: %s\n' "$GROUP_VARS" >&2; exit 2; }
jq -e . "$TEMPLATE" >/dev/null 2>&1 || { printf 'FAIL: sing-box template is not valid JSON\n' >&2; exit 2; }

# The single primary protocol (the only one allowed to default ON).
PRIMARY_TOGGLE="enable_vless_reality_vision"

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== per-protocol toggle check ==\n'
printf 'template:   %s\n' "${TEMPLATE#"$REPO_ROOT"/}"
printf 'group_vars: %s\n' "${GROUP_VARS#"$REPO_ROOT"/}"

# tag_to_toggle TAG -> echo the canonical enable_<proto> toggle name, or empty if the inbound is
# an internal helper (the ShadowTLS loopback detour) that has no toggle of its own.
tag_to_toggle() {
	case "$1" in
		vless-reality-vision-in|vless-reality-vision)  printf 'enable_vless_reality_vision' ;;
		vless-reality-grpc-in|vless-reality-grpc)      printf 'enable_vless_reality_grpc' ;;
		vless-reality-xhttp-in|vless-reality-xhttp)    printf 'enable_vless_reality_xhttp' ;;
		# VLESS+XHTTP over GENUINE single-layer TLS (own cert; NO reality) — distinct from the
		# XHTTP-in-REALITY (TLS-in-TLS) inbound above; default-off like every non-primary transport.
		vless-xhttp-tls-in|vless-xhttp-tls)            printf 'enable_vless_xhttp_tls' ;;
		# VLESS+WebSocket over GENUINE single-layer TLS (own cert; NO reality) — SERVABLE on sing-box
		# (native ws transport), unlike the xhttp-tls inbound; default-off like every non-primary transport.
		vless-ws-tls-in|vless-ws-tls)                  printf 'enable_vless_ws_tls' ;;
		hysteria2-in|hysteria2)                        printf 'enable_hysteria2' ;;
		tuic-v5-in|tuic-in|tuic)                       printf 'enable_tuic' ;;
		shadowsocks-2022-in|shadowsocks-in|shadowsocks) printf 'enable_ss2022' ;;
		shadowtls-v3-in|shadowtls-in|shadowtls)        printf 'enable_shadowtls' ;;
		# Internal loopback Shadowsocks behind ShadowTLS — governed by enable_shadowtls, no toggle.
		shadowtls-shadowsocks-in|shadowtls-ss-in)      printf '' ;;
		trojan-tls-in|trojan-in|trojan)                printf 'enable_trojan' ;;
		*)                                             printf '__UNKNOWN__' ;;
	esac
}

# toggle_default TOGGLE -> echo the boolean default from group_vars (true/false), or empty if the
# key is absent. Reads a non-comment `enable_x: <bool>` line; strips inline comments.
toggle_default() {
	local key val
	key="$1"
	# The pipeline is `|| true`-guarded: when the key is ABSENT an inner grep exits non-zero on
	# empty input, which would otherwise trip `set -e` / `pipefail` instead of letting the caller
	# report the missing toggle. We want empty -> "toggle missing", not a crash.
	val="$({ grep -E "^[[:space:]]*${key}[[:space:]]*:" "$GROUP_VARS" 2>/dev/null \
		| grep -v '^[[:space:]]*#' \
		| head -n1 \
		| sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//"; } || true)"
	printf '%s' "$val"
}

# Collect inbound tags from the template (newline-separated; bash 3.2-safe, no mapfile).
TAGS="$(jq -r '.inbounds[]?.tag // empty' "$TEMPLATE")"
[ -n "$TAGS" ] || { printf 'FAIL: template declares no inbound tags\n' >&2; exit 2; }

# Track which toggles we have already asserted (space-padded string; bash 3.2-safe).
SEEN_TOGGLES=" "
seen() { case "$SEEN_TOGGLES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

primary_default_on=0

while IFS= read -r tag; do
	[ -n "$tag" ] || continue
	toggle="$(tag_to_toggle "$tag")"

	if [ "$toggle" = "__UNKNOWN__" ]; then
		badln "inbound '$tag' has no known enable_<proto> mapping (unrecognised protocol)"
		continue
	fi
	# Internal helper inbound (no toggle of its own).
	[ -z "$toggle" ] && continue
	# Assert each toggle once.
	seen "$toggle" && continue
	SEEN_TOGGLES="$SEEN_TOGGLES$toggle "

	def="$(toggle_default "$toggle")"
	if [ -z "$def" ]; then
		badln "inbound '$tag' is NOT gated by a group_vars toggle ($toggle missing)"
		continue
	fi
	case "$def" in
		true|false) : ;;
		*) badln "$toggle has a non-boolean default '$def' (must be true/false)"; continue ;;
	esac

	if [ "$toggle" = "$PRIMARY_TOGGLE" ]; then
		if [ "$def" = "true" ]; then
			okln "$toggle defaults ON (the single primary transport) [inbound: $tag]"
			primary_default_on=1
		else
			badln "$toggle (primary) must default true, found '$def'"
		fi
	else
		if [ "$def" = "false" ]; then
			okln "$toggle defaults OFF [inbound: $tag]"
		else
			badln "$toggle must default false (only vless_reality_vision is default-on), found '$def'"
		fi
	fi
done < <(printf '%s\n' "$TAGS")

# The primary toggle must exist and be ON (it gates the default transport).
if [ "$primary_default_on" -ne 1 ]; then
	badln "the primary toggle $PRIMARY_TOGGLE was not found ON in group_vars"
fi

# Belt-and-suspenders: scan ALL enable_* protocol toggles in group_vars and ensure none other than
# the primary is true (guards against a default-on toggle for a protocol not in the template).
while IFS= read -r line; do
	# line is "enable_x: <val>"
	k="${line%%:*}"; k="$(printf '%s' "$k" | tr -d '[:space:]')"
	v="$(printf '%s' "${line#*:}" | sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]//g')"
	# Skip the non-protocol amneziawg path toggle? AmneziaWG is a separate UDP path that must ALSO
	# default off, so we include it in the "nothing but vision may be true" rule.
	[ "$k" = "$PRIMARY_TOGGLE" ] && continue
	if [ "$v" = "true" ]; then
		badln "$k defaults true, but only $PRIMARY_TOGGLE may be default-on"
	fi
done < <(grep -E '^[[:space:]]*enable_[a-z0-9_]+[[:space:]]*:' "$GROUP_VARS" | grep -v '^[[:space:]]*#')

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a protocol is not toggleable or has the wrong default (only vless_reality_vision\n' >&2
	printf '      may default ON; every other protocol must default OFF).\n' >&2
	exit 1
fi
printf 'PASS: every protocol is gated by an enable_* toggle; only vless_reality_vision is default-on.\n'
exit 0
