#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# cover_site_probe.sh — POST-DEPLOY active-probe gate for a live node.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS CHECKS (requires a LIVE node — this is NOT an offline test)
#   A REALITY-fronted node borrows the TLS handshake of a real donor site. To an active probe
#   that simply connects to the node and inspects the response, the node MUST be indistinguishable
#   from ordinary HTTPS to that donor: the presented certificate chain belongs to the donor, and a
#   plain HTTPS request returns a genuine donor-shaped response (not a tell-tale signature).
#
#   This gate connects to NODE:PORT and asserts the TLS/HTTP response looks like the DONOR:
#     1. TLS handshake against NODE using the donor SNI completes.
#     2. The leaf certificate's Subject/SAN matches the expected donor host.
#     3. (best-effort) A plain HTTPS GET to NODE with the donor Host returns a normal status,
#        consistent with a benign web server — never an obvious tunnel signature.
#
#   PASS (exit 0) = the node answers an active probe as the donor would.
#   FAIL (exit 1) = the probe sees something other than the expected donor (a distinguishing tell).
#
# WORDING: neutral throughout — "active probing", "network adversary", "indistinguishability".
#          The point is reachability/resilience under probing, not any specific scenario.
#
# USAGE
#   cover_site_probe.sh --node NODE_HOST --donor DONOR_HOST [--port 443] [--sni SNI] [--timeout 10]
#     --node    reachability address of the node under test (IP or DNS name).
#     --donor   the expected donor site whose handshake the node borrows.
#     --port    node TLS port (default 443).
#     --sni     SNI to present (default: the donor host).
#     --timeout per-connection timeout in seconds (default 10).
#
# REQUIREMENTS: openssl (TLS inspection, REQUIRED). curl is OPTIONAL (HTTP-shape check; the
#               HTTP step is skipped with a note if curl is absent).
#
# Exit: 0 = looks like the donor, 1 = distinguishing tell / unreachable, 2 = usage/env error.

set -euo pipefail

usage() {
	cat <<'USAGE'
cover_site_probe.sh — POST-DEPLOY active-probe gate (requires a LIVE node).

Connects to NODE:PORT and asserts the TLS/HTTP response looks like the expected DONOR,
i.e. the node is indistinguishable from ordinary HTTPS to that donor under active probing.

Usage:
  cover_site_probe.sh --node NODE_HOST --donor DONOR_HOST [--port 443] [--sni SNI] [--timeout 10]

  --node     reachability address of the node under test (IP or DNS name).
  --donor    the expected donor site whose handshake the node borrows.
  --port     node TLS port (default 443).
  --sni      SNI to present (default: the donor host).
  --timeout  per-connection timeout in seconds (default 10).

Requires openssl (TLS inspection). curl is optional (HTTP-shape check).
Exit: 0 = looks like the donor, 1 = distinguishing tell / unreachable, 2 = usage/env error.
USAGE
}

node=""
donor=""
port="443"
sni=""
timeout_s="10"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--node)    node="${2:?--node needs a value}"; shift 2 ;;
		--donor)   donor="${2:?--donor needs a value}"; shift 2 ;;
		--port)    port="${2:?--port needs a value}"; shift 2 ;;
		--sni)     sni="${2:?--sni needs a value}"; shift 2 ;;
		--timeout) timeout_s="${2:?--timeout needs a value}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'cover_site_probe: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

[ -n "$node" ]  || { printf 'cover_site_probe: --node is required (the live node under test)\n' >&2; exit 2; }
[ -n "$donor" ] || { printf 'cover_site_probe: --donor is required (the expected donor host)\n' >&2; exit 2; }
[ -n "$sni" ] || sni="$donor"

command -v openssl >/dev/null 2>&1 || {
	printf 'cover_site_probe: openssl is required for TLS inspection.\n' >&2; exit 2; }

# Portable per-connection timeout wrapper (timeout/gtimeout if present; else best-effort).
run_to() {
	if command -v timeout >/dev/null 2>&1; then timeout "$timeout_s" "$@";
	elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$timeout_s" "$@";
	else "$@"; fi
}

fail=0
printf '== active-probe gate (live node) ==\n'
printf 'node=%s:%s  donor=%s  sni=%s  timeout=%ss\n' "$node" "$port" "$donor" "$sni" "$timeout_s"

# ---------------------------------------------------------------------------
# 1+2. TLS handshake + certificate identity must match the donor.
# ---------------------------------------------------------------------------
printf '\n-- TLS handshake + certificate identity --\n'
cert_pem="$(printf '' | run_to openssl s_client -connect "$node:$port" -servername "$sni" 2>/dev/null \
	| openssl x509 2>/dev/null || true)"

if [ -z "$cert_pem" ]; then
	printf '  FAIL  no certificate retrieved from %s:%s (handshake failed / node unreachable)\n' "$node" "$port"
	fail=1
else
	printf '  ok    TLS handshake completed; leaf certificate retrieved\n'

	subject="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -subject 2>/dev/null || true)"
	san="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
		|| printf '%s\n' "$cert_pem" | openssl x509 -noout -text 2>/dev/null \
			| grep -A1 'Subject Alternative Name' || true)"

	# The donor host (or its registrable parent, for a wildcard cert) must appear in Subject/SAN.
	parent="${donor#*.}"   # e.g. donor "www.example.com" -> "example.com"
	if printf '%s\n%s\n' "$subject" "$san" | grep -qiE "(^|[^a-z0-9.])($donor|\*\.$parent|$parent)([^a-z0-9.]|$)"; then
		printf '  ok    certificate identity matches the donor (%s)\n' "$donor"
	else
		printf '  FAIL  certificate identity does NOT match the donor (%s)\n' "$donor"
		printf '        subject: %s\n' "${subject:-<none>}"
		printf '        san    : %s\n' "$(printf '%s' "$san" | tr '\n' ' ')"
		fail=1
	fi
fi

# ---------------------------------------------------------------------------
# 3. HTTP shape (best-effort). A plain HTTPS GET should look like a benign web server.
# ---------------------------------------------------------------------------
printf '\n-- HTTP response shape (best-effort) --\n'
if ! command -v curl >/dev/null 2>&1; then
	printf '  SKIP  curl not on PATH — TLS-only probe. Install curl to enable the HTTP-shape check.\n'
else
	# --resolve pins the donor name to the node's address so SNI/Host match the donor while the
	# socket goes to the node. -k: we already validated identity above; here we look at the SHAPE.
	status="$(run_to curl -ksS -o /dev/null -w '%{http_code}' \
		--resolve "$donor:$port:$node" "https://$donor:$port/" 2>/dev/null || true)"
	if [ -z "$status" ] || [ "$status" = "000" ]; then
		printf '  WARN  no HTTP status returned (donor may not serve plain HTTP on this path)\n'
		printf '        TLS identity above is the authoritative signal; not failing on HTTP alone.\n'
	elif printf '%s' "$status" | grep -qE '^[1-5][0-9][0-9]$'; then
		printf '  ok    HTTP status %s — a normal web-server response (no tunnel tell)\n' "$status"
	else
		printf '  FAIL  unexpected HTTP response: %s\n' "$status"
		fail=1
	fi
fi

# ---------------------------------------------------------------------------
printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the node did NOT answer an active probe as the donor would. Investigate the\n' >&2
	printf '      REALITY dest/serverNames and donor reachability before exposing the node.\n' >&2
	exit 1
fi
printf 'PASS: the node answers an active probe as the donor (indistinguishable from ordinary HTTPS).\n'
exit 0
