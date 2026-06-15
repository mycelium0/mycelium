#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# active_probe_owncert.sh — conformance: the genuine single-layer-TLS XHTTP transport family
# (RP-0007-a, AC-a3) is shaped so an active probe sees an honest own-cert HTTPS endpoint, NEVER a
# REALITY donor-cover masquerade. Probe-safety, fail-closed.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE (ADR-0010, RP-0007 §AC-a3, threat DISTINGUISHABLE_TRANSPORT / S0)
#   The new VLESS+XHTTP-over-genuine-TLS inbound is single-layer HTTPS: the node presents its OWN
#   publicly-valid certificate (per ADR-0014), NOT a REALITY donor-borrowed handshake. That is the
#   whole point — TLS-in-TLS (XHTTP framing inside REALITY) is DPI-blocked on some mobile links; a
#   genuine single-TLS endpoint survives. But "own cert, no reality" must be shaped CORRECTLY or it
#   becomes a tell: an own-cert TLS inbound that looks like a reality cover (donor handshake), or one
#   that squats on a confirmed-fingerprinted port (8443), or one that collides with the REALITY-XHTTP
#   tag, is an active-probe distinguisher. The donor-relay probe (`cover_site_probe.sh`) applies ONLY
#   to REALITY inbounds; THIS gate is the probe-safety contract for the own-cert family.
#
#   This gate is OFFLINE + INSPECT-ONLY: it reasons about the DEPLOYED renderer template's SHAPE, not
#   a live handshake. For EVERY inbound that is the genuine-single-TLS shape — i.e.
#     tls.enabled == true  AND  no `reality` block  AND  an xhttp/http transport —
#   it asserts:
#     (a) the inbound carries its OWN certificate_path AND key_path (it serves a real cert; it is NOT
#         a donor/reality cover that would borrow a third party's handshake);
#     (b) its listen_port is NOT 8443 (a confirmed per-path mobile tell — RP-0007 §AC-a4);
#     (c) its tag is DISTINCT from vless-reality-xhttp-in (the TLS-in-TLS inbound) so the two families
#         never collapse into one.
#
#   It PASSES when every such inbound satisfies (a)+(b)+(c). It FAILS CLOSED if a future edit makes an
#   own-cert TLS inbound look like a reality cover (drops its own cert), squats on 8443, or reuses the
#   REALITY-XHTTP tag. At least one genuine-single-TLS inbound MUST exist (the family is wired).
#
# Parses with jq only (the template). bash 3.2-safe: no mapfile, no associative arrays.
#
# Exit: 0 = every own-cert single-TLS inbound is probe-safe, 1 = a violation (or the family is
#       missing), 2 = usage/env error (jq missing or template not found/invalid).

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for active_probe_owncert.sh\n' >&2; exit 2; }

# The DEPLOYED template (node-bootstrap.sh renders this one). The probe-safety evidence must describe
# the shipped artifact, not the superseded server.template.json (Audit-0004 F-002).
TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
# The REALITY-XHTTP inbound (TLS-in-TLS) the own-cert family must stay DISTINCT from.
REALITY_XHTTP_TAG="vless-reality-xhttp-in"
# Confirmed per-path mobile tell — the own-cert family must not squat here (RP-0007 §AC-a4).
FORBIDDEN_PORT="8443"

[ -f "$TEMPLATE" ] || { printf 'FAIL: sing-box template not found: %s\n' "$TEMPLATE" >&2; exit 2; }
jq -e . "$TEMPLATE" >/dev/null 2>&1 || { printf 'FAIL: sing-box template is not valid JSON\n' >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== active-probe own-cert (genuine single-TLS) safety check ==\n'
printf 'template: %s\n' "${TEMPLATE#"$REPO_ROOT"/}"

# Select the tags of every inbound that is the GENUINE-SINGLE-TLS shape:
#   tls.enabled == true  AND  no reality block  AND  an xhttp/http transport.
# Emitted one tag per line (newline-separated; bash 3.2-safe, no mapfile).
GENUINE_TAGS="$(jq -r '
	.inbounds[]?
	| select(
		(.tls? != null)
		and (.tls.enabled == true)
		and ((.tls.reality?) == null)
		and ((.transport?.type) == "xhttp" or (.transport?.type) == "http")
	)
	| .tag // empty
' "$TEMPLATE")"

if [ -z "$GENUINE_TAGS" ]; then
	badln "no genuine-single-TLS inbound found (tls.enabled, no reality, xhttp/http transport) — the own-cert family is not wired (fail-closed)"
	printf '\n-- Result --\n'
	printf 'FAIL: the genuine single-TLS XHTTP family is missing from the deployed template.\n' >&2
	exit 1
fi

# Inspect each genuine-single-TLS inbound.
while IFS= read -r tag; do
	[ -n "$tag" ] || continue

	# (c) distinct tag from the REALITY-XHTTP (TLS-in-TLS) inbound.
	if [ "$tag" = "$REALITY_XHTTP_TAG" ]; then
		badln "$tag: an own-cert single-TLS inbound reuses the REALITY-XHTTP tag '$REALITY_XHTTP_TAG' — the two families must stay DISTINCT"
		continue
	fi

	# Pull this inbound's cert/key/port in one jq pass.
	cert="$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .tls.certificate_path // ""' "$TEMPLATE")"
	key="$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .tls.key_path // ""' "$TEMPLATE")"
	port="$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen_port // empty' "$TEMPLATE")"

	# (a) serves its OWN certificate (not a donor/reality cover that borrows a third party's handshake).
	if [ -n "$cert" ] && [ -n "$key" ]; then
		okln "$tag: serves its own certificate_path + key_path (own-cert, not a donor/reality cover)"
	else
		badln "$tag: missing own certificate_path/key_path (cert='$cert' key='$key') — an own-cert TLS inbound that borrows a donor handshake is a reality-cover masquerade (fail-closed)"
	fi

	# (b) listen_port is NOT the confirmed mobile-tell port 8443.
	if [ -z "$port" ]; then
		badln "$tag: has no listen_port (an own-cert public inbound must bind a port)"
	elif [ "$port" = "$FORBIDDEN_PORT" ]; then
		badln "$tag: listens on $FORBIDDEN_PORT (a confirmed per-path mobile tell) — the own-cert family must NOT squat on 8443"
	else
		okln "$tag: listen_port $port is non-8443 (avoids the confirmed mobile tell)"
	fi

	# (c) restated as an ok line for the non-colliding case.
	okln "$tag: tag is distinct from the REALITY-XHTTP inbound '$REALITY_XHTTP_TAG' (families do not collapse)"
done <<EOF
$GENUINE_TAGS
EOF

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a genuine single-TLS inbound is not probe-safe (reality-cover masquerade, 8443 squat,\n' >&2
	printf '      or REALITY-XHTTP tag collision). Violation = DISTINGUISHABLE_TRANSPORT (S0).\n' >&2
	exit 1
fi
printf 'PASS: every genuine single-TLS XHTTP inbound serves its own cert, avoids 8443, and stays\n'
printf '      distinct from the REALITY-XHTTP (TLS-in-TLS) inbound — probe-safe (RP-0007 §AC-a3).\n'
exit 0
