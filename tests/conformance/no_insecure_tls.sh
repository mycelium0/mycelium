#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_insecure_tls.sh — conformance: TLS certificate verification is never disabled.
# Author: mindicator & silicon bags quartet.
#
# POLICY (docs/adr/0014-per-operator-node-credentials.md)
#   Self-signed Hysteria2 / TUIC / Trojan certs are trusted ONLY by an explicit per-node
#   certificate/SPKI pin. A blanket "skip TLS verification" flag accepts ANY certificate and is
#   MITM-open; it is FORBIDDEN. The Ansible Jinja fallback and the myceliumctl subscription/render
#   paths must NEVER emit one. This gate is the fail-closed guard that PREVENTS such a flag from
#   returning to the deployable surface.
#
# WHAT THIS CHECKS  (FAIL = exit 1 if found, as a CONFIG VALUE, anywhere in the deploy surface)
#       * sing-box ...... "insecure": true            (JSON)  / insecure: true        (YAML)
#       * Go crypto/tls . insecure_skip_verify: true  (YAML/JSON — blackbox probes, generic Go TLS)
#       * xray .......... "allowInsecure": true        (JSON)  / allowInsecure: true   (YAML)
#       * clash ......... skip-cert-verify: true       (clash YAML) and the JSON form
#   The match requires a KEY = TRUE config assignment. Prose mentions and comments that merely NAME
#   the flag (to forbid it) are NOT a configured value and do not trip the gate — comment lines are
#   stripped before matching and *.md docs are excluded entirely.
#
# WHAT IS SCANNED — only the deployable CONFIG / TEMPLATE surface:
#       *.json  *.json.example   (sing-box / xray / clash configs, client subscriptions)
#       *.j2                     (Jinja config templates; rendered output is JSON/YAML)
#       *.yml  *.yaml  + .example (group_vars, role defaults, clash configs)
#       *.conf  *.template       (wireguard / generic rendered config templates)
#       *.tf                     (terraform; defensive)
#       Caddyfile                (cover-site web server config)
#
# WHAT IS EXCLUDED
#   * .git/                  — version-control internals.
#   * gitignored paths       — local tooling/state, secrets, rendered runtime configs, the vault
#                              (honored via `git check-ignore`).
#   * *.md                   — prose docs (ADR-0014, proposals, runbooks) legitimately NAME the flag
#                              to forbid it; describing a rule is not configuring it.
#   * *.sh                   — shell sources (their comments describe the rule); not a config value.
#   * this script itself     — it necessarily names the forbidden flags as patterns.
#   * the conformance dir    — sibling gates likewise carry the patterns by design.
#   * comment lines          — within scanned files, comment lines (#, //, Jinja {# #}) are stripped
#                              before matching, so a "NEVER insecure:true" comment stays green.
#   * explicit counter-examples — a scanned file may opt out by carrying the literal marker
#                              "conformance:no_insecure_tls=counter-example" (used by an *.example
#                              that deliberately shows the forbidden value as a teaching artifact, and
#                              by the blackbox reachability-probe config, whose insecure_skip_verify
#                              measures handshake completion and is not a confidentiality boundary).
#
# Exit: 0 = clean, 1 = at least one skip-verify flag is configured true, 2 = usage/env error.

set -euo pipefail

# Resolve the repository root (this file lives at <root>/tests/conformance/).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state, secrets,
# rendered runtime configs, the vault). Returns non-zero outside a git work-tree, so the gate still
# runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

# Marker a deliberate counter-example file may carry to opt out (kept as split fragments so the gate
# does not match its own source as a counter-example).
COUNTER_MARKER='conformance:no'"_insecure_tls=counter-example"

# --- Forbidden config-value patterns ---------------------------------------
# Each requires a KEY then ': '/'= ' then a truthy literal (true / "true" / yes / 1 / on), so a bare
# mention without an assignment is not flagged. The key tokens:
#     insecure              (sing-box client TLS skip-verify)
#     insecure_skip_verify  (Go crypto/tls — blackbox_exporter, generic Go TLS configs)
#     allowInsecure         (xray / clash outbound TLS skip-verify)
#     skip-cert-verify      (clash TLS skip-verify)
# A legitimate measurement-probe use of insecure_skip_verify (the blackbox reachability prober, which
# is NOT a confidentiality boundary) opts out via the counter-example marker — see WHAT IS EXCLUDED.
TRUTHY='([Tt]rue|"[Tt]rue"|[Yy]es|"[Yy]es"|1|"1"|[Oo]n|"[Oo]n")'
# Key may be quoted ("insecure") or bare, separated by either ':' (JSON / YAML / clash) or '='
# (defensive for ini-like surfaces), with optional spaces. insecure_skip_verify is listed BEFORE the
# shorter `insecure` so it matches the full token regardless of the regex engine's longest-match rule.
FLAG_RE='("?(insecure_skip_verify|insecure|allowInsecure|skip-cert-verify)"?[[:space:]]*[:=][[:space:]]*'"$TRUTHY"')'

fail=0
report() {
	# report FILE LINENO MATCHTEXT
	printf '  INSECURE %s:%s  %s\n' "$1" "$2" \
		"$(printf '%s' "$3" | sed 's/^[[:space:]]*//')"
	fail=1
}

printf '== no insecure TLS check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# scan_file FILE — strip comment lines, then flag any KEY=TRUE skip-verify assignment.
scan_file() {
	local f rel body
	f="$1"; rel="${f#"$REPO_ROOT"/}"

	# Skip binary files defensively.
	grep -Iq . "$f" 2>/dev/null || return 0

	# Opt-out: an explicit counter-example file.
	if grep -Fq "$COUNTER_MARKER" "$f" 2>/dev/null; then
		printf '  skip (counter-example) %s\n' "$rel"
		return 0
	fi

	# Comment-stripped, line-numbered view. grep -n keeps ORIGINAL line numbers; -v drops:
	#   * '#'  YAML / conf / Caddyfile comments,
	#   * '//' JSONC / xray-style comments,
	#   * '{#' / '#}' Jinja comment delimiters (the template header block and inline {# ... #}).
	# A KEY=TRUE assignment that is the payload of a comment line is therefore not seen.
	body="$(grep -nIvE '^[[:space:]]*(#|//|\{#|#\})' "$f" 2>/dev/null || true)"
	[ -n "$body" ] || return 0

	# Match the forbidden assignment. The grep -n prefix is "LINENO:CONTENT"; split on FIRST colon to
	# recover the original line number (no second -n).
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "$text"
	done < <(printf '%s\n' "$body" | grep -nE "$FLAG_RE" \
		| sed -E 's/^[0-9]+:([0-9]+):/\1:/' || true)
}

# Walk the config/template surface only. *.md and *.sh are NOT included (prose / shell describe the
# rule but do not configure a value).
while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	case "$rel" in
		.git/*) continue ;;
		tests/conformance/"$SELF_NAME") continue ;;
		tests/conformance/*) continue ;;
	esac
	scan_file "$f"
done < <(find "$REPO_ROOT" -type f \
	\( -name '*.json' -o -name '*.json.example' \
	   -o -name '*.j2' \
	   -o -name '*.yml' -o -name '*.yaml' \
	   -o -name '*.yml.example' -o -name '*.yaml.example' \
	   -o -name '*.conf' -o -name '*.template' \
	   -o -name '*.tf' \
	   -o -name 'Caddyfile' \) \
	-not -path '*/.git/*' -not -path '*/tests/conformance/*' -print0)

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a TLS skip-verify flag is set true in the deployable surface.\n' >&2
	printf '      Self-signed HY2/TUIC/Trojan certs are trusted ONLY by an explicit per-node pin;\n' >&2
	printf '      a blanket skip-verify (insecure / allowInsecure / skip-cert-verify = true) accepts\n' >&2
	printf '      ANY certificate and is MITM-open. Remove it (see docs/adr/0014-per-operator-node-\n' >&2
	printf '      credentials.md). Prose that NAMES the flag to forbid it belongs in *.md / comments.\n' >&2
	exit 1
fi

printf 'PASS: no TLS skip-verify flag is configured in the deployable surface (documented measurement-probe counter-examples excepted).\n'
exit 0
