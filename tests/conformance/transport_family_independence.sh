#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# transport_family_independence.sh — conformance: the transport set provides >=2 INDEPENDENT
# transport FAMILIES so the Phase-0 DoD D2 bar ("at least two independent transport shapes reachable
# at once") is ACHIEVABLE, and every transport toggle is classified into a family.
# Author: mindicator & silicon bags quartet.
#
# WHY FAMILIES, NOT SHAPES (ADR-0020 §5, ADR-0010): VLESS+REALITY Vision/gRPC/XHTTP are ONE
# TLS-over-TCP family — same handshake fingerprint surface, same donor, same keypair — so they are
# not two independent shapes. A genuinely independent second shape must be a DIFFERENT family:
# AmneziaWG over UDP (the canonical Phase-0 second family, ADR-0020 §5), or QUIC (Hysteria2/TUIC), or
# Shadowsocks-2022. This gate checks the CAPABILITY is present and wired in the deployable surface.
#
# NOT ENFORCED HERE (by design): whether >=2 families are actually ENABLED on a given node. The
# shipped default is intentionally minimal-exposure (REALITY only — see per_protocol_toggle.sh); a
# node reaches D2 by ALSO enabling its second family (AmneziaWG per ADR-0020). Per-node enablement is
# a deploy-time acceptance check recorded in the Phase-0 ledger, not an offline gate.
#
# CHECKS
#   1. Every enable_<proto> toggle in group_vars maps to a known transport family (no orphan family).
#   2. The REALITY/TLS-TCP family is available (a vless-reality inbound in the sing-box template).
#   3. The AmneziaWG/UDP family — the canonical second family — is wired END TO END: an
#      enable_amneziawg toggle, the amneziawg Ansible role, AND node-bootstrap.sh renders awg0.conf
#      (so a fresh node can actually bring up the second family; this is the r2 reproducibility fix).
#   4. >=2 distinct families are therefore available.
#
# Exit: 0 = >=2 independent families available and every toggle classified; 1 = an unclassified
#       toggle, a missing family, or the second family not wired; 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for transport_family_independence.sh\n' >&2; exit 2; }

GROUP_VARS="$REPO_ROOT/infra/ansible/group_vars/all.yml.example"
# The DEPLOYED template (node-bootstrap.sh renders this one); GO evidence describes the shipped
# artifact. It is now the only sing-box server template: the superseded server.template.json was
# removed, closing RP-0003 §W5 (Audit-0004 F-002).
TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
BOOTSTRAP="$REPO_ROOT/scripts/node-bootstrap.sh"
AWG_ROLE="$REPO_ROOT/infra/ansible/roles/amneziawg"

[ -f "$GROUP_VARS" ] || { printf 'FAIL: group_vars example not found: %s\n' "$GROUP_VARS" >&2; exit 2; }
[ -f "$TEMPLATE" ]   || { printf 'FAIL: sing-box template not found: %s\n' "$TEMPLATE" >&2; exit 2; }
[ -f "$BOOTSTRAP" ]  || { printf 'FAIL: node-bootstrap.sh not found: %s\n' "$BOOTSTRAP" >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# family_of TOGGLE -> the transport family a toggle belongs to (independent failure surfaces), or
# __UNKNOWN__ if the toggle is not classified (a new transport must be added here).
family_of() {
	case "$1" in
		enable_vless_reality_vision|enable_vless_reality_grpc|enable_vless_reality_xhttp) printf 'reality-tls-tcp' ;;
		enable_vless_xhttp_tls)                                                           printf 'xhttp-tls' ;;
		enable_hysteria2|enable_tuic)                                                     printf 'quic-udp' ;;
		enable_ss2022)                                                                    printf 'shadowsocks-tcp' ;;
		enable_shadowtls)                                                                 printf 'shadowtls-tcp' ;;
		enable_trojan)                                                                    printf 'trojan-tls-tcp' ;;
		enable_amneziawg)                                                                 printf 'amneziawg-udp' ;;
		*)                                                                                printf '__UNKNOWN__' ;;
	esac
}

printf '== transport family independence check ==\n'
printf 'group_vars: %s\n' "${GROUP_VARS#"$REPO_ROOT"/}"

# 1. Classify every enable_<proto> toggle declared in group_vars; collect the distinct families.
FAMILIES=" "
have_family() { case "$FAMILIES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
while IFS= read -r line; do
	tog="${line%%:*}"; tog="$(printf '%s' "$tog" | tr -d '[:space:]')"
	[ -n "$tog" ] || continue
	fam="$(family_of "$tog")"
	if [ "$fam" = "__UNKNOWN__" ]; then
		badln "toggle '$tog' is not classified into a transport family (add it to family_of)"
		continue
	fi
	have_family "$fam" || FAMILIES="$FAMILIES$fam "
done < <(grep -E '^[[:space:]]*enable_[a-z0-9_]+[[:space:]]*:' "$GROUP_VARS" | grep -v '^[[:space:]]*#')

# 2. REALITY/TLS-TCP family available (a vless-reality inbound exists in the template).
if jq -e '[.inbounds[]?.tag // empty] | map(select(test("vless-reality"))) | length > 0' "$TEMPLATE" >/dev/null 2>&1; then
	okln "REALITY/TLS-TCP family available (vless-reality inbound present in the sing-box template)"
else
	badln "no vless-reality inbound in the sing-box template — the primary family is missing"
fi

# 3. AmneziaWG/UDP family wired end to end (toggle + role + bootstrap render = r2).
awg_ok=1
grep -Eq '^[[:space:]]*enable_amneziawg[[:space:]]*:' "$GROUP_VARS" || { badln "enable_amneziawg toggle missing from group_vars"; awg_ok=0; }
[ -d "$AWG_ROLE" ] || { badln "amneziawg Ansible role missing: ${AWG_ROLE#"$REPO_ROOT"/}"; awg_ok=0; }
# The bootstrap MUST render awg0.conf (not merely enable the unit), or a fresh node's second family
# never comes up. Tie the gate to the render function + its config target.
if grep -q 'render_awg0' "$BOOTSTRAP" && grep -q 'awg0.conf' "$BOOTSTRAP"; then
	: # render present
else
	badln "node-bootstrap.sh does not render awg0.conf (the second family would not come up on a fresh node)"
	awg_ok=0
fi
[ "$awg_ok" -eq 1 ] && okln "AmneziaWG/UDP second family wired end to end (toggle + role + bootstrap render)"

# 4. At least two distinct families available.
fam_count="$(printf '%s' "$FAMILIES" | wc -w | tr -d '[:space:]')"
if [ "$fam_count" -ge 2 ]; then
	okln "$fam_count independent transport families available: $(printf '%s' "$FAMILIES" | tr -s ' ' | sed 's/^ //; s/ $//')"
else
	badln "only $fam_count transport family available; D2 needs >=2 independent families"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the transport set does not provide >=2 wired independent families (D2 not achievable).\n' >&2
	exit 1
fi
printf 'PASS: >=2 independent transport families are available and wired; D2 is achievable.\n'
printf '      (Per-node ENABLEMENT of >=2 families is a deploy-time/ledger check, not enforced here.)\n'
exit 0
