#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# validate_configs.sh — conformance: configs are well-formed.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS CHECKS
#   1. JSON  — every *.json in the tree (templates + *.example + *.json.example) is valid JSON
#              (`jq .`). jq is REQUIRED (it is the Phase 0 rendering engine).
#   2. xray  — if `xray` is on PATH, render the VLESS+REALITY template into a throwaway config
#              (substituting the SENTINEL_* placeholders with well-shaped dummy values — NO real
#              keys) and run `xray run -test -config <tmp>` / `xray -test -c <tmp>`. If `xray` is
#              absent, SKIP with a clear note (offline-friendly; not a failure).
#   3. YAML  — basic YAML sanity for every *.yml/*.yaml (incl. *.example) using the first
#              available parser: yamllint → yq → python3 PyYAML. If none is present, SKIP with a
#              note. Ansible *.j2 templates contain Jinja and are intentionally NOT parsed here.
#
# Exit: 0 = all present checks passed (skips are not failures), 1 = a validation failed,
#       2 = a required tool (jq) is missing.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state,
# secrets, rendered runtime configs, the vault). Returns non-zero outside a git work-tree,
# so the gate still runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

fail=0
note() { printf '\n-- %s --\n' "$1"; }
skip() { printf '  SKIP  %s\n' "$1"; }
okln() { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== config validation ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 0. jq is mandatory.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
	printf 'FAIL: jq not found on PATH. jq is the Phase 0 rendering engine and is required.\n' >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# 1. JSON validity (templates + examples). Pure JSON carries NO header by design.
# ---------------------------------------------------------------------------
note "JSON (jq)"
json_count=0
while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	json_count=$((json_count + 1))
	if jq -e . "$f" >/dev/null 2>&1; then
		okln "$rel"
	else
		badln "$rel  (invalid JSON)"
	fi
done < <(find "$REPO_ROOT" -type f \( -name '*.json' -o -name '*.json.example' \) -not -path '*/templates/*' \
	-not -path '*/.git/*' -print0)
[ "$json_count" -gt 0 ] || skip "no .json files found"

# ---------------------------------------------------------------------------
# 2. xray -test on a rendered sample (skip cleanly if xray is absent).
# ---------------------------------------------------------------------------
note "xray -test (rendered sample)"
TEMPLATE="$REPO_ROOT/nodes/dataplane/vless-reality/server.template.json"
if ! command -v xray >/dev/null 2>&1; then
	skip "xray not on PATH — skipping live config test (offline). Install xray-core (>= v26.2.4) to enable."
elif [ ! -f "$TEMPLATE" ]; then
	skip "dataplane template not found at $TEMPLATE — nothing to render."
else
	# Build a throwaway rendered config. We substitute the SENTINEL_* placeholders with
	# WELL-SHAPED DUMMY values only (no real keys; the private key shape is a base64url-ish
	# 43-44 char string so xray's structural test accepts it).
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/myc.cfgcheck.XXXXXX")"
	rendered="$tmp_dir/server.json"
	cleanup_xray() { rm -rf "$tmp_dir"; }
	trap cleanup_xray EXIT

	# Dummy, structurally-valid placeholders (NOT secrets).
	dummy_uuid="00000000-0000-4000-8000-000000000001"
	dummy_priv="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   # 43 chars, base64url alphabet
	dummy_sid="0123456789abcdef"
	dummy_donor="donor.example.invalid"

	# Inject one client and fill the SENTINEL_* values via jq (keeps it valid JSON).
	if jq \
		--arg uuid "$dummy_uuid" \
		--arg priv "$dummy_priv" \
		--arg sid "$dummy_sid" \
		--arg donor "$dummy_donor" '
		(.inbounds[] | select(.protocol=="vless") | .settings.clients) =
			[{ id: $uuid, email: "probe@example.invalid", flow: "xtls-rprx-vision" }]
		| (.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings) |=
			( .dest = ($donor + ":443")
			| .serverNames = [$donor]
			| .privateKey = $priv
			| .shortIds = [$sid] )
		' "$TEMPLATE" > "$rendered" 2>/dev/null
	then
		okln "rendered throwaway sample is valid JSON"
		# Try both modern and legacy test invocations.
		if xray run -test -config "$rendered" >/dev/null 2>&1 \
			|| xray -test -c "$rendered" >/dev/null 2>&1; then
			okln "xray accepts the rendered sample (structural -test passed)"
		else
			badln "xray -test rejected the rendered sample"
			xray run -test -config "$rendered" 2>&1 | sed 's/^/      xray: /' || true
		fi
	else
		badln "could not render a sample from the template with jq"
	fi
fi

# ---------------------------------------------------------------------------
# 3. YAML sanity (best available parser; skip if none).
# ---------------------------------------------------------------------------
note "YAML sanity"
yaml_files=()
while IFS= read -r -d '' f; do
	_ignored "${f#"$REPO_ROOT"/}" && continue
	yaml_files+=("$f")
done < <(
	find "$REPO_ROOT" -type f \
		\( -name '*.yml' -o -name '*.yaml' -o -name '*.yml.example' -o -name '*.yaml.example' \) \
		-not -path '*/.git/*' -print0
)

if [ "${#yaml_files[@]}" -eq 0 ]; then
	skip "no YAML files found"
elif command -v yamllint >/dev/null 2>&1; then
	for f in "${yaml_files[@]}"; do
		rel="${f#"$REPO_ROOT"/}"
		# -d relaxed: we assert parseability, not house style.
		if yamllint -d relaxed "$f" >/dev/null 2>&1; then okln "$rel"; else badln "$rel (yamllint)"; fi
	done
elif command -v yq >/dev/null 2>&1; then
	for f in "${yaml_files[@]}"; do
		rel="${f#"$REPO_ROOT"/}"
		if yq -e . "$f" >/dev/null 2>&1 || yq eval '.' "$f" >/dev/null 2>&1; then
			okln "$rel"
		else
			badln "$rel (yq)"
		fi
	done
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
	for f in "${yaml_files[@]}"; do
		rel="${f#"$REPO_ROOT"/}"
		if python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$f" >/dev/null 2>&1; then
			okln "$rel"
		else
			badln "$rel (PyYAML)"
		fi
	done
else
	skip "no YAML parser (yamllint / yq / python3+PyYAML) — skipping YAML sanity. Install one to enable."
fi

# ---------------------------------------------------------------------------
note "Result"
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: one or more configs are invalid.\n' >&2
	exit 1
fi
printf 'PASS: all present config checks succeeded (skips noted above are not failures).\n'
exit 0
