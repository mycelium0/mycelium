#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# engine_manifest_shape.sh — conformance (RP-0011 chunk C-1): the committed engine manifest is
# well-formed and SAFE to read as default pins. control/engines.manifest.json must:
#   1. be a JSON object with CLOSED top-level keys (_comment? / version / engines / toolchains?);
#   2. carry exactly the singbox + xray engines, each with a SemVer-tagged version, a dl_base, and a
#      sha256 map;
#   3. key sha256 only by NORMALISED arches {amd64, arm64} (armv7 intentionally uncovered), each a
#      64-hex digest;
#   4. have dl_base EQUAL to node-bootstrap's SINGBOX_DL_BASE / XRAY_DL_BASE constants — the
#      byte-identity guard: a flag-omitting caller must download from the SAME base it does today;
#   5. resolve correctly through control/lib/nb_engine_manifest.sh (manifest_engine_pins returns the
#      version/sha/dl_base tuple for a covered arch, and NOTHING for an uncovered arch like armv7).
#   6. (optional) carry a toolchains.go build-toolchain pin — a goX.Y[.Z] version, {amd64,arm64} 64-hex
#      sha256, dl_base == node-bootstrap GO_DL_BASE, and a Go minor >= the go.mod floor — so the node
#      builds the spine from a PINNED, non-distro Go (same resolver contract, manifest_toolchain_pins).
# OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = manifest well-formed + resolver correct, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'engine_manifest_shape: cannot resolve repo root\n' >&2; exit 2; }
MF="$REPO_ROOT/control/engines.manifest.json"
LIB="$REPO_ROOT/control/lib/nb_engine_manifest.sh"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
for f in "$MF" "$LIB" "$NB"; do [ -f "$f" ] || { printf 'engine_manifest_shape: missing %s\n' "$f" >&2; exit 2; }; done
command -v jq >/dev/null 2>&1 || { printf 'engine_manifest_shape: jq required\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== engine manifest is well-formed + safe to read as default pins (RP-0011 C-1) ==\n'

# 1. valid JSON + closed top-level keys
jq -e . "$MF" >/dev/null 2>&1 && ok "valid JSON" || { badln "not valid JSON"; printf 'FAIL\n' >&2; exit 1; }
if [ -z "$(jq -r 'keys[] | select(. != "_comment" and . != "version" and . != "engines" and . != "toolchains")' "$MF" 2>/dev/null)" ]; then
	ok "top-level keys are closed (_comment? / version / engines / toolchains?)"
else badln "unexpected top-level key(s): $(jq -rc 'keys' "$MF")"; fi

# 2. exactly singbox + xray
engines="$(jq -r '.engines | keys | sort | join(",")' "$MF" 2>/dev/null)"
[ "$engines" = "singbox,xray" ] && ok "engines == {singbox, xray}" || badln "engines should be {singbox,xray}, got [$engines]"

# 3. per-engine structure + arch-key set + hex digests
for e in singbox xray; do
	ver="$(jq -r --arg e "$e" '.engines[$e].version // ""' "$MF")"
	printf '%s' "$ver" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' \
		&& ok "$e.version is SemVer-tagged ($ver)" || badln "$e.version not a vX.Y.Z tag: '$ver'"
	archs="$(jq -r --arg e "$e" '.engines[$e].sha256 | keys[]' "$MF" 2>/dev/null)"
	bad=""
	for a in $archs; do [ "$a" = "amd64" ] || [ "$a" = "arm64" ] || bad="$bad $a"; done
	[ -z "$bad" ] && ok "$e sha256 arch keys ⊆ {amd64,arm64}" || badln "$e has non-normalised arch key(s):$bad"
	for a in $archs; do
		dg="$(jq -r --arg e "$e" --arg a "$a" '.engines[$e].sha256[$a]' "$MF")"
		printf '%s' "$dg" | grep -qE '^[0-9a-f]{64}$' || badln "$e.sha256.$a is not a 64-hex digest"
	done
done

# 4. dl_base == node-bootstrap constants (byte-identity guard)
sb_const="$(grep -E '^SINGBOX_DL_BASE=' "$NB" | head -1 | sed -E 's/^[^=]*="([^"]*)".*/\1/')"
xr_const="$(grep -E '^XRAY_DL_BASE=' "$NB" | head -1 | sed -E 's/^[^=]*="([^"]*)".*/\1/')"
[ "$(jq -r '.engines.singbox.dl_base' "$MF")" = "$sb_const" ] \
	&& ok "singbox.dl_base == node-bootstrap SINGBOX_DL_BASE" \
	|| badln "singbox.dl_base != SINGBOX_DL_BASE ($sb_const) — flag-omitting callers would change download source"
[ "$(jq -r '.engines.xray.dl_base' "$MF")" = "$xr_const" ] \
	&& ok "xray.dl_base == node-bootstrap XRAY_DL_BASE" \
	|| badln "xray.dl_base != XRAY_DL_BASE ($xr_const)"

# 5. build toolchain (go) pins — same shape as an engine, plus a go.mod currency floor. The toolchains
#    block is OPTIONAL (absent => skipped), but when present must be well-formed so the node builds the
#    spine from a PINNED, non-distro Go.
if [ "$(jq -r 'has("toolchains")' "$MF")" = "true" ]; then
	tc_names="$(jq -r '.toolchains | keys | sort | join(",")' "$MF" 2>/dev/null)"
	[ "$tc_names" = "go" ] && ok "toolchains == {go}" || badln "toolchains should be {go}, got [$tc_names]"
	gover="$(jq -r '.toolchains.go.version // ""' "$MF")"
	printf '%s' "$gover" | grep -qE '^go1\.[0-9]+(\.[0-9]+)?$' \
		&& ok "toolchains.go.version is a Go release tag ($gover)" || badln "toolchains.go.version not a goX.Y[.Z] tag: '$gover'"
	tc_archs="$(jq -r '.toolchains.go.sha256 | keys[]' "$MF" 2>/dev/null)"
	tbad=""
	for a in $tc_archs; do [ "$a" = "amd64" ] || [ "$a" = "arm64" ] || tbad="$tbad $a"; done
	[ -z "$tbad" ] && ok "toolchains.go sha256 arch keys ⊆ {amd64,arm64}" || badln "toolchains.go has non-normalised arch key(s):$tbad"
	for a in $tc_archs; do
		dg="$(jq -r --arg a "$a" '.toolchains.go.sha256[$a]' "$MF")"
		printf '%s' "$dg" | grep -qE '^[0-9a-f]{64}$' || badln "toolchains.go.sha256.$a is not a 64-hex digest"
	done
	go_const="$(grep -E '^GO_DL_BASE=' "$NB" | head -1 | sed -E 's/^[^=]*="([^"]*)".*/\1/')"
	[ "$(jq -r '.toolchains.go.dl_base' "$MF")" = "$go_const" ] \
		&& ok "toolchains.go.dl_base == node-bootstrap GO_DL_BASE" \
		|| badln "toolchains.go.dl_base != GO_DL_BASE ($go_const)"
	gomod="$REPO_ROOT/go.mod"
	if [ -f "$gomod" ]; then
		mod_minor="$(grep -E '^go[[:space:]]+1\.[0-9]+' "$gomod" | head -1 | sed -E 's/^go[[:space:]]+1\.([0-9]+).*/\1/')"
		pin_minor="$(printf '%s' "$gover" | sed -E 's/^go1\.([0-9]+).*/\1/')"
		if [ -n "$mod_minor" ] && [ -n "$pin_minor" ]; then
			{ [ "$pin_minor" -ge "$mod_minor" ] 2>/dev/null; } \
				&& ok "toolchains.go pin (1.$pin_minor) >= go.mod floor (1.$mod_minor)" \
				|| badln "toolchains.go pin 1.$pin_minor is BELOW the go.mod floor 1.$mod_minor — bump the pin"
		fi
	fi
else
	ok "no toolchains block (optional; spine build falls back to distro go)"
fi

# 6. resolver correctness (engines + the pinned go toolchain)
probe="$(mktemp "${TMPDIR:-/tmp}/myc.emf.XXXXXX")" || { badln "mktemp failed"; printf 'FAIL\n' >&2; exit 2; }
# shellcheck disable=SC1090
( MYC_ENGINE_MANIFEST="$MF"; . "$LIB" || exit 3
  command -v manifest_engine_pins >/dev/null 2>&1 || { echo "NO_FN"; exit 0; }
  printf 'AMD64=%s\n' "$(manifest_engine_pins singbox amd64)"
  printf 'ARMV7=%s\n' "$(manifest_engine_pins singbox armv7)"
  if command -v manifest_toolchain_pins >/dev/null 2>&1; then
    printf 'GOAMD64=%s\n' "$(manifest_toolchain_pins go amd64)"
    printf 'GOARMV7=%s\n' "$(manifest_toolchain_pins go armv7)"
  fi
) >"$probe" 2>/dev/null
if grep -q NO_FN "$probe" 2>/dev/null; then
	badln "nb_engine_manifest.sh does not define manifest_engine_pins"
else
	amd="$(sed -n 's/^AMD64=//p' "$probe")"
	armv7="$(sed -n 's/^ARMV7=//p' "$probe")"
	exp="$(jq -r '[.engines.singbox.version, .engines.singbox.sha256.amd64, .engines.singbox.dl_base] | @tsv' "$MF")"
	[ "$amd" = "$exp" ] && ok "resolver returns the amd64 singbox tuple from the manifest" \
		|| badln "resolver amd64 tuple mismatch: got [$amd] want [$exp]"
	[ -z "$armv7" ] && ok "resolver returns NOTHING for an uncovered arch (armv7 → required-flag fallback)" \
		|| badln "resolver should return nothing for armv7, got [$armv7]"
fi
if [ "$(jq -r 'has("toolchains")' "$MF")" = "true" ]; then
	goamd="$(sed -n 's/^GOAMD64=//p' "$probe")"
	goarmv7="$(sed -n 's/^GOARMV7=//p' "$probe")"
	goexp="$(jq -r '[.toolchains.go.version, .toolchains.go.sha256.amd64, .toolchains.go.dl_base] | @tsv' "$MF")"
	[ "$goamd" = "$goexp" ] && ok "resolver returns the amd64 go toolchain tuple from the manifest" \
		|| badln "toolchain resolver amd64 tuple mismatch: got [$goamd] want [$goexp]"
	[ -z "$goarmv7" ] && ok "toolchain resolver returns NOTHING for armv7 (→ distro-go fallback)" \
		|| badln "toolchain resolver should return nothing for armv7, got [$goarmv7]"
fi
rm -f "$probe"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: engine manifest is well-formed, dl_base matches the bootstrap constants, and the resolver is correct.\n'
	exit 0
fi
printf 'FAIL: engine manifest / resolver is not sane.\n' >&2
exit 1
