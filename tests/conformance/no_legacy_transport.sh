#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_legacy_transport.sh — conformance: disabled-legacy transports are never CONFIGURED.
# Author: mindicator & silicon bags quartet.
#
# POLICY (docs/adr/0010-phase0-transport-set.md, nodes/dataplane/singbox/protocols.md)
#   The Phase-0 transport set deliberately uses only modern, hard-to-fingerprint protocols and
#   EXCLUDES the easily-fingerprinted / legacy ones below. None of them may appear as a CONFIGURED
#   inbound / protocol in the deployable surface (templates, role-defaults, group_vars):
#
#       vmess, plain shadowsocks (NON-2022 method), plain wireguard (NON-amnezia),
#       openvpn, l2tp, pptp, sstp, ikev2
#
#   They MAY still be NAMED in prose (docs / *.md and the comments of an .example) that explicitly
#   EXCLUDES them — calling something out as "not offered" is not configuring it.
#
# HOW IT WORKS
#   Scans only the CONFIG surface (NOT prose .md docs):
#     * JSON templates ......... a legacy protocol CONFIGURED as  "type": "<legacy>"  or
#                                "protocol": "<legacy>".  shadowsocks is allowed ONLY as the
#                                2022 AEAD variant (a "2022-..." method on the same inbound);
#                                a shadowsocks inbound WITHOUT a 2022 method is "plain" -> FAIL.
#     * Jinja (*.j2) templates . same JSON-shape rules (the rendered config is JSON).
#     * YAML group_vars / role defaults ... an  enable_<legacy>: ...  toggle, or a bare
#                                "type:" / "protocol:" legacy value (CODE lines, not comments).
#   Comment lines (leading '#') and prose .md files are NOT scanned for configured protocols, so
#   the "we EXCLUDE vmess/openvpn/..." sentences stay green.
#
# EXCLUSIONS: .git/, gitignored paths (git check-ignore: local tooling/state, secrets, rendered
# configs, the vault), all *.md (prose), this conformance directory, and the AmneziaWG component
# (its WireGuard data protocol is the SANCTIONED obfuscated path, not "plain wireguard").
#
# Exit: 0 = clean, 1 = a legacy transport is configured somewhere, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for no_legacy_transport.sh\n' >&2; exit 2; }

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state,
# secrets, rendered runtime configs, the vault). Returns non-zero outside a git work-tree,
# so the gate still runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

fail=0
report() {
	# report FILE LINENO REASON TEXT
	printf '  LEGACY   %s:%s  [%s]  %s\n' "$1" "$2" "$3" \
		"$(printf '%s' "$4" | sed 's/^[[:space:]]*//')"
	fail=1
}

printf '== no legacy transport check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# Legacy protocol tokens that must never be configured (word-boundary matched).
# NOTE: shadowsocks and wireguard are handled specially (2022 / amnezia carve-outs).
LEGACY_TYPES_RE='vmess|openvpn|l2tp|pptp|sstp|ikev2'

# is_amnezia_path REL -> 0 if the path is the sanctioned AmneziaWG component (skip wireguard rules).
is_amnezia_path() {
	case "$1" in
		*amneziawg*) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# JSON + Jinja config templates (the rendered output is JSON).
# ---------------------------------------------------------------------------
# For each candidate file we extract every "type"/"protocol" string value (with its line number)
# via grep, then classify. shadowsocks requires a sibling 2022-* method in the SAME file; plain
# wireguard is forbidden outside the amneziawg component.
scan_json_like() {
	local f rel has_2022
	f="$1"; rel="${f#"$REPO_ROOT"/}"

	# Does this file commit to the 2022 AEAD family for its shadowsocks inbound(s)? A shadowsocks
	# inbound is allowed ONLY as the 2022 variant. We accept either a literal "2022-..." method or
	# a 2022-named method on a "method" line (Jinja templates set it via {{ ..._ss2022_method }} /
	# {{ singbox_ss2022_method }} rather than a literal). A "method" line that is present but shows
	# NO 2022 signal would be plain (legacy) Shadowsocks.
	if grep -Eq '"method"[[:space:]]*:[[:space:]]*"2022-' "$f" 2>/dev/null \
		|| grep -Eiq '"method"[[:space:]]*:.*2022' "$f" 2>/dev/null; then
		has_2022=1
	else
		has_2022=0
	fi

	# Hard-forbidden protocol types/protocols.
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "configured-legacy" "$text"
	done < <(grep -niE '"(type|protocol)"[[:space:]]*:[[:space:]]*"('"$LEGACY_TYPES_RE"')"' "$f" 2>/dev/null || true)

	# Plain (non-2022) shadowsocks: a shadowsocks type with NO 2022 method in the file.
	if [ "$has_2022" -eq 0 ]; then
		while IFS=: read -r lineno text; do
			[ -n "${lineno:-}" ] || continue
			report "$rel" "$lineno" "plain-shadowsocks" "$text"
		done < <(grep -niE '"(type|protocol)"[[:space:]]*:[[:space:]]*"shadowsocks"' "$f" 2>/dev/null || true)
	fi

	# Plain wireguard (outside the sanctioned AmneziaWG component).
	if ! is_amnezia_path "$rel"; then
		while IFS=: read -r lineno text; do
			[ -n "${lineno:-}" ] || continue
			report "$rel" "$lineno" "plain-wireguard" "$text"
		done < <(grep -niE '"(type|protocol)"[[:space:]]*:[[:space:]]*"wireguard"' "$f" 2>/dev/null || true)
	fi
}

while IFS= read -r -d '' f; do
	_ignored "${f#"$REPO_ROOT"/}" && continue
	scan_json_like "$f"
done < <(find "$REPO_ROOT" -type f \
	\( -name '*.template.json' -o -name '*.json' -o -name '*.json.example' -o -name '*.j2' \) \
	-not -path '*/.git/*' -not -path '*/tests/conformance/*' -print0)

# ---------------------------------------------------------------------------
# YAML group_vars + role defaults (CODE lines only; comments are prose).
# ---------------------------------------------------------------------------
# A configured legacy transport here is either:
#   * an  enable_<legacy>: ...  toggle (offering the protocol), or
#   * a bare  type: <legacy>  /  protocol: <legacy>  value on a non-comment line.
# Lines whose first non-space char is '#' are comments (the "we exclude ..." sentences) -> ignored.
scan_yaml() {
	local f rel
	f="$1"; rel="${f#"$REPO_ROOT"/}"

	# Comment-stripped, line-numbered view: each line is "LINENO:CONTENT" (grep -n adds the prefix;
	# -v drops comment lines but the ORIGINAL line numbers are preserved). The match regexes below
	# therefore allow the "LINENO:" prefix before the YAML indentation, and we split on the FIRST
	# colon to recover the original line number — no second -n.
	local body
	body="$(grep -nIv '^[[:space:]]*#' "$f" 2>/dev/null || true)"
	[ -n "$body" ] || return 0

	# enable_<legacy>: toggles (vmess/openvpn/l2tp/pptp/sstp/ikev2).
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "legacy-toggle" "$text"
	done < <(printf '%s\n' "$body" \
		| grep -E '^[0-9]+:[[:space:]]*enable_('"$LEGACY_TYPES_RE"')[[:space:]]*:' || true)

	# enable_shadowsocks (plain, NOT _ss2022 / _2022) and enable_wireguard (plain, NOT amnezia):
	# the project uses enable_ss2022 and enable_amneziawg, so a bare enable_shadowsocks /
	# enable_wireguard toggle would be legacy drift.
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "plain-ss-toggle" "$text"
	done < <(printf '%s\n' "$body" \
		| grep -E '^[0-9]+:[[:space:]]*enable_shadowsocks([^_A-Za-z0-9]|:)' || true)
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "plain-wg-toggle" "$text"
	done < <(printf '%s\n' "$body" \
		| grep -E '^[0-9]+:[[:space:]]*enable_wireguard([^_A-Za-z0-9]|:)' || true)

	# Bare type:/protocol: legacy values.
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "legacy-yaml-type" "$text"
	done < <(printf '%s\n' "$body" \
		| grep -EI '^[0-9]+:[[:space:]]*(type|protocol)[[:space:]]*:[[:space:]]*"?('"$LEGACY_TYPES_RE"')"?[[:space:]]*$' || true)
}

while IFS= read -r -d '' f; do
	_ignored "${f#"$REPO_ROOT"/}" && continue
	scan_yaml "$f"
done < <(find "$REPO_ROOT" -type f \
	\( -name '*.yml' -o -name '*.yaml' -o -name '*.yml.example' -o -name '*.yaml.example' \) \
	-not -path '*/.git/*' -not -path '*/tests/conformance/*' -print0)

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a disabled-legacy transport is CONFIGURED as an inbound/protocol/toggle.\n' >&2
	printf '      Allowed only as words in docs (*.md) / comments that EXCLUDE them. The Phase-0\n' >&2
	printf '      set excludes vmess, plain shadowsocks, plain wireguard, openvpn, l2tp, pptp,\n' >&2
	printf '      sstp, ikev2 (see docs/adr/0010-phase0-transport-set.md).\n' >&2
	exit 1
fi

printf 'PASS: no disabled-legacy transport is configured anywhere in the deployable surface.\n'
exit 0
