# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_engine_manifest.sh — node-bootstrap library: resolve DEFAULT engine pins from the committed
# control/engines.manifest.json (RP-0011 chunk C).
#
# SINGLE RESPONSIBILITY: read-only lookup of {version, sha256, dl_base} for an engine on the running
# host's architecture, so install_singbox / install_xray can FILL an absent --singbox-*/--xray-* pin
# from the manifest instead of failing closed. PURELY ADDITIVE: when the operator passes an explicit
# pin, or the manifest / jq / the host arch is unavailable, this returns NOTHING and the caller keeps
# its existing required-flag behaviour — so a flag-passing caller is byte-identical. Defines functions
# only (safe to source standalone) and depends on nothing but jq. CLASSIFICATION: pure read.

# Resolve the manifest path (overridable for tests; defaults under the artifact/repo root).
_myc_engine_manifest_path() {
	printf '%s\n' "${MYC_ENGINE_MANIFEST:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/engines.manifest.json}"
}

# Normalise the host machine arch to the manifest's key space (amd64 / arm64). armv7 is intentionally
# NOT a manifest key (it stays a required flag), so it normalises to "armv7" which the lookup misses.
_myc_engine_norm_arch() {
	case "${1:-$(uname -m 2>/dev/null)}" in
		x86_64|amd64)  printf 'amd64\n' ;;
		aarch64|arm64) printf 'arm64\n' ;;
		armv7l|armv7)  printf 'armv7\n' ;;
		*)             printf '\n' ;;
	esac
}

# manifest_engine_pins <singbox|xray> [arch] — print "<version>\t<sha256>\t<dl_base>" (TAB-separated)
# for the engine on the given (default: host) normalised arch, or NOTHING if the manifest, jq, the
# engine entry, or the per-arch sha is unavailable. Read-only; never fails the caller.
manifest_engine_pins() {
	local engine="${1:?engine required}" arch mf
	arch="$(_myc_engine_norm_arch "${2:-}")"
	[ -n "$arch" ] || return 0
	mf="$(_myc_engine_manifest_path)"
	[ -f "$mf" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -er --arg e "$engine" --arg a "$arch" '
		(.engines[$e]) as $x
		| ($x.sha256[$a]) as $s
		| select($x != null and $x.version != null and $x.dl_base != null and $s != null and $s != "")
		| [$x.version, $s, $x.dl_base] | @tsv' "$mf" 2>/dev/null || return 0
}
