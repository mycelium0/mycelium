#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_full_tunnel_default.sh — conformance: a generated/templated AmneziaWG CLIENT config never
# routes ALL traffic by default. Inspect-only.
# Author: mindicator & silicon bags quartet.
#
# POLICY (Selective Growth — VIS-0008 doctrine; ADR-0026 closed-by-default; ADR-0021 vantage)
#   "The mycelium does not grow where it is not needed." A client tunnel carries ONLY the traffic
#   whose native path is impaired; natively-reachable destinations route direct (split-tunnel by
#   default). A WireGuard-class (AmneziaWG) transport can only approximate this with a CIDR
#   region-exclude AllowedIPs set; a full-tunnel default (AllowedIPs = 0.0.0.0/0 or ::/0) is the
#   opposite posture and must NEVER be the silent default.
#
#   A full-route line is allowed ONLY when an operator has deliberately opted out, marked in the
#   SAME file by the documented opt-out marker on the nearest non-blank line above:
#
#       # selective-growth: opt-out (full-tunnel)
#       AllowedIPs = 0.0.0.0/0, ::/0
#
# WHAT THIS CHECKS (inspect-only; no node, no network)
#   Scans the AmneziaWG client-config surface for an  AllowedIPs = ... 0.0.0.0/0 ... (or ::/0)
#   line that is NOT preceded by the opt-out marker:
#     * committed *.conf / *.conf.example  whose body looks like an AmneziaWG config ([Interface]),
#     * the AmneziaWG client Jinja template(s) (*client*.j2) IF they hard-code a default route as a
#       LITERAL on an AllowedIPs line (a `{{ ... }}`-driven value is a runtime decision, not a
#       hard-coded default, and is NOT flagged here — its default lives in role defaults/group_vars
#       and is governed elsewhere),
#     * an optional extra scan directory (MYC_AWG_SCAN_DIR) so this gate is negative-testable
#       against a fixture (point it at a dir containing a violating *.conf and the gate must FAIL).
#   Comment lines (leading '#') are never themselves flagged — prose that NAMES 0.0.0.0/0 is fine.
#   The SERVER config (awg0.conf) is out of scope: its per-peer AllowedIPs are tunnel-range routes,
#   never a client default route.
#
# EXCLUSIONS: .git/, gitignored paths (git check-ignore: local tooling/state, rendered ./out/
# client configs, secrets, the vault), and this conformance directory.
#
# Exit: 0 = no undocumented full-tunnel default anywhere, 1 = a client config full-tunnels without
#       the opt-out marker, 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# _ignored REL -> 0 if git would ignore this repo-relative path (rendered ./out/ client configs,
# local state, secrets, the vault). Non-zero outside a git work-tree, so the gate still runs on a
# plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

OPT_OUT_MARKER='selective-growth: opt-out'

fail=0
report() {
	# report DISPLAYPATH LINENO TEXT
	printf '  FULLTUN  %s:%s  %s\n' "$1" "$2" \
		"$(printf '%s' "$3" | sed 's/^[[:space:]]*//')"
	fail=1
}

printf '== no full-tunnel default check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# looks_like_awg_client FILE -> 0 if the file body looks like an AmneziaWG/WireGuard CLIENT config
# (an [Interface] section). awg0.conf (the SERVER) also has [Interface]; we exclude it by name.
looks_like_awg_client() {
	case "${1##*/}" in
		awg0.conf) return 1 ;;
	esac
	grep -q '^[[:space:]]*\[Interface\]' "$1" 2>/dev/null
}

# scan_conf FILE DISPLAYPATH — flag an AllowedIPs line carrying a default route (0.0.0.0/0 or ::/0)
# unless the nearest non-blank line above it carries the opt-out marker. bash 3.2-safe: a while-read
# over grep -n output (line-numbered), tracking the last non-blank line for the marker look-behind.
# No mapfile/readarray/timeout.
scan_conf() {
	local f disp prev_nonblank lineno text body
	f="$1"; disp="$2"
	# prev_nonblank holds the most recent NON-BLANK line seen above the current one. We look behind to
	# it (not to the literal previous physical line) so an opt-out marker still counts when separated
	# from its AllowedIPs line by blank line(s) — common in AmneziaWG configs.
	prev_nonblank=""
	# grep -n gives "LINENO:CONTENT" for every line (including blanks), so the line number is exact.
	body="$(grep -n '' "$f" 2>/dev/null || true)"
	[ -n "$body" ] || return 0
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		# A blank / whitespace-only line never carries a marker or a route, and must NOT erase the
		# marker recorded above it.
		case "$text" in
			*[![:space:]]*) : ;;   # has at least one non-space char -> a real line
			*) continue ;;         # empty or whitespace-only -> skip without touching prev_nonblank
		esac
		# Comment lines are prose, never a configured route. A comment can be the opt-out marker for a
		# LATER line, so it updates prev_nonblank (below) but is itself never flagged.
		case "$text" in
			\#*|[[:space:]]*\#*)
				prev_nonblank="$text"
				continue
				;;
		esac
		# Is THIS a configured AllowedIPs line with a default route?
		if printf '%s' "$text" \
			| grep -Eq '^[[:space:]]*AllowedIPs[[:space:]]*=' 2>/dev/null \
			&& printf '%s' "$text" | grep -Eq '(^|[[:space:],=])(0\.0\.0\.0/0|::/0)([[:space:],]|$)' 2>/dev/null
		then
			case "$prev_nonblank" in
				*"$OPT_OUT_MARKER"*)
					: # documented operator opt-out on the nearest line above — allowed.
					;;
				*)
					report "$disp" "$lineno" "$text"
					;;
			esac
		fi
		prev_nonblank="$text"
	done < <(printf '%s\n' "$body")
}

# 1) Committed *.conf / *.conf.example that are AmneziaWG CLIENT configs.
while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	looks_like_awg_client "$f" || continue
	scan_conf "$f" "$rel"
done < <(find "$REPO_ROOT" -type f \
	\( -name '*.conf' -o -name '*.conf.example' \) \
	-not -path '*/.git/*' -not -path '*/tests/conformance/*' -print0)

# 2) AmneziaWG client Jinja template(s): only flag a LITERAL default route on an AllowedIPs line.
#    A {{ ... }}-driven AllowedIPs value is a runtime decision (its default is governed by the
#    per-protocol-toggle / role-defaults surface), so a templated line is NOT a hard-coded default.
while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	case "${f##*/}" in *client*) : ;; *) continue ;; esac
	scan_conf "$f" "$rel"
done < <(find "$REPO_ROOT" -type f -name '*.j2' \
	-not -path '*/.git/*' -not -path '*/tests/conformance/*' -print0)

# 3) Optional fixture dir for negative testing (any *.conf/*.j2 under it; no gitignore filtering).
if [ -n "${MYC_AWG_SCAN_DIR:-}" ] && [ -d "${MYC_AWG_SCAN_DIR}" ]; then
	printf 'extra scan dir: %s\n' "$MYC_AWG_SCAN_DIR"
	while IFS= read -r -d '' f; do
		case "${f##*/}" in awg0.conf) continue ;; esac
		scan_conf "$f" "$f"
	done < <(find "$MYC_AWG_SCAN_DIR" -type f \( -name '*.conf' -o -name '*.j2' \) -print0)
fi

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: an AmneziaWG client config routes ALL traffic by default (AllowedIPs = 0.0.0.0/0\n' >&2
	printf '      or ::/0) without the documented Selective-Growth opt-out marker on the line above.\n' >&2
	printf '      A client tunnel must carry only impaired-path traffic by default (split-tunnel via a\n' >&2
	printf '      region-exclude AllowedIPs set). To deliberately full-tunnel, put this on the line\n' >&2
	printf '      immediately above the AllowedIPs line:\n' >&2
	printf '          # selective-growth: opt-out (full-tunnel)\n' >&2
	exit 1
fi

printf 'PASS: no AmneziaWG client config full-tunnels by default (Selective Growth holds).\n'
exit 0

