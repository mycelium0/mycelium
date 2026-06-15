#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# sub_channel_not_single_point.sh — conformance: the subscription/bundle delivery channel is NEVER a
# single point of block. Offline, inspect-only, fail-closed.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE (RP-0007-b, ADR-0020 §1, threat SINGLE_POINT_OF_BLOCK)
#   The matured distribution channel is a self-replenishing Bundle (internal/spec/bundle.go) a node
#   SERVES over HTTPS and a client self-polls (profile-update-interval). The danger is that a
#   deployable config pins ONE hardcoded subscription URL as the SOLE way a client ever reaches the
#   network: block that one URL and the channel is dead. That collapses the whole reach story into a
#   single chokepoint — exactly what the multi-family transport design (transport_family_independence)
#   exists to avoid. The reach surface must stay PLURAL at BOTH layers:
#     (1) the DELIVERY of the bundle must not be a lone hardcoded URL with no alternative, AND
#     (2) the CONTENT of the bundle must span >=2 independent transport families, so even one
#         delivered bundle is not itself a single point of block.
#
#   This gate is OFFLINE + INSPECT-ONLY: it reasons about COMMITTED files, never a live fetch.
#
# CHECKS
#   1. No committed deployable config declares exactly ONE hardcoded subscription URL as the sole
#      client delivery path with NO alternative. Concretely: scan tracked deploy surfaces
#      (infra/ansible, scripts/, nodes/, control/) for hardcoded sub/profile URLs (http(s):// values
#      bound to a subscription/profile key). If a file pins exactly one such URL and offers no
#      sibling/fallback URL, it is a single point of block -> FAIL. Since no served-sub artifact is
#      committed yet, there are zero such pins and this PASSES (gates-first); it FAILS CLOSED the
#      moment a single-point sub config lands.
#   2. The bundle's transport-class mapping (control/lib/render_bundle.sh myc_bundle_class_of) spans
#      >=2 INDEPENDENT transport families, mirroring transport_family_independence — so a single
#      delivered bundle carries >=2 reach paths and is itself not a single point of block.
#
# bash 3.2-safe: no mapfile, no associative arrays, no process substitution into arrays.
#
# Exit: 0 = the sub channel is plural (no lone hardcoded sub URL; bundle spans >=2 families),
#       1 = a single-point sub config exists or the bundle collapses to <2 families,
#       2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

BUNDLE_LIB="$REPO_ROOT/control/lib/render_bundle.sh"
[ -f "$BUNDLE_LIB" ] || { printf 'FAIL: render_bundle.sh not found: %s\n' "$BUNDLE_LIB" >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== sub-channel-not-single-point check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. No committed deployable config pins exactly ONE hardcoded subscription URL as the sole path.
# ---------------------------------------------------------------------------
# Deploy surfaces a single-point sub URL could realistically land in. We inspect tracked files only
# (so generated runtime state under gitignored paths is out of scope by construction).
SCAN_DIRS="infra/ansible scripts nodes control"

# A "subscription/profile URL pin" is a line that binds an http(s) URL to a subscription/profile key,
# e.g.  subscription_url: "https://..."  |  profile_url = "https://..."  |  "sub_url": "https://...".
# The key must name a subscription/profile delivery endpoint (not an arbitrary URL like an APT repo
# or a donor host), so the pattern is anchored on sub/subscription/profile + url near an http(s):// .
URL_KEY_RE='(subscription|sub|profile)[_-]?url'

# Collect candidate files (tracked, under the scan dirs) that contain such a pin. bash 3.2-safe: a
# newline-delimited string, not an array.
PIN_FILES=""
for d in $SCAN_DIRS; do
	[ -d "$REPO_ROOT/$d" ] || continue
	# Match a sub/profile *_url key on the same line as an http(s):// literal. -I skips binaries.
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		# Only consider files git tracks (committed deploy surface), not local scratch.
		if git -C "$REPO_ROOT" ls-files --error-unmatch -- "${f#"$REPO_ROOT"/}" >/dev/null 2>&1; then
			case "$PIN_FILES" in
				*"$f"*) ;;            # already recorded
				*) PIN_FILES="$PIN_FILES$f"$'\n' ;;
			esac
		fi
	done <<EOF
$(grep -RIlE "$URL_KEY_RE" "$REPO_ROOT/$d" 2>/dev/null | grep -vE '/(\.git|node_modules)/' || true)
EOF
done

if [ -z "$(printf '%s' "$PIN_FILES" | tr -d '[:space:]')" ]; then
	okln "no committed file pins a subscription/profile delivery URL (no served-sub artifact yet; gates-first)"
else
	# Every such file must offer >=2 distinct hardcoded sub/profile http(s) URLs (a primary + at least
	# one alternative). Exactly ONE distinct URL == a single point of block -> FAIL CLOSED.
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		rel="${f#"$REPO_ROOT"/}"
		# Distinct http(s):// URLs appearing on lines that also carry a sub/profile *_url key.
		n_urls="$(grep -IE "$URL_KEY_RE" "$f" 2>/dev/null \
			| grep -oE 'https?://[^"'"'"' )]+' \
			| sort -u | wc -l | tr -d '[:space:]')"
		if [ "${n_urls:-0}" -ge 2 ]; then
			okln "$rel: declares $n_urls distinct sub/profile delivery URLs (has an alternative; not a single point of block)"
		elif [ "${n_urls:-0}" -eq 1 ]; then
			badln "$rel: pins exactly ONE hardcoded subscription/profile URL with no alternative — that is a single point of block (provide >=2 independent delivery URLs, or serve the multi-family bundle)"
		else
			# A sub/profile *_url key with no literal URL (e.g. a Jinja/template placeholder) is not a
			# committed hardcoded single point; the rendered value is deploy-time, out of scope here.
			okln "$rel: references a sub/profile URL key but pins no hardcoded literal (templated/deferred; not a committed single point)"
		fi
	done <<EOF
$PIN_FILES
EOF
fi

# ---------------------------------------------------------------------------
# 2. The bundle content itself spans >=2 INDEPENDENT transport families (mirrors
#    transport_family_independence): even one delivered bundle is not a single point of block.
# ---------------------------------------------------------------------------
# Source the renderer lib in a subshell-safe way: it defines myc_bundle_class_of (pure, no I/O).
# shellcheck source=/dev/null
. "$BUNDLE_LIB"

if ! command -v myc_bundle_class_of >/dev/null 2>&1 && ! type myc_bundle_class_of >/dev/null 2>&1; then
	badln "render_bundle.sh does not define myc_bundle_class_of (cannot prove the bundle spans >=2 families)"
else
	# Every protocol the bundle can emit, mapped to its closed-vocab transport family. We enumerate the
	# canonical protocol set (the same tokens render_bundle classifies) and collect the DISTINCT
	# families. amneziawg is included because it is the canonical independent second family (ADR-0020).
	PROTOS="vless-reality-vision vless-reality-grpc vless-reality-xhttp vless-xhttp-tls hysteria2 tuic shadowsocks shadowtls trojan amneziawg"
	FAMILIES=" "
	have_fam() { case "$FAMILIES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
	unclassified=0
	for p in $PROTOS; do
		fam="$(myc_bundle_class_of "$p")"
		if [ -z "$fam" ]; then
			badln "bundle protocol '$p' has no transport-class mapping (a new transport must be classified)"
			unclassified=1
			continue
		fi
		have_fam "$fam" || FAMILIES="$FAMILIES$fam "
	done
	fam_count="$(printf '%s' "$FAMILIES" | wc -w | tr -d '[:space:]')"
	if [ "$unclassified" -eq 0 ] && [ "$fam_count" -ge 2 ]; then
		okln "the bundle spans $fam_count independent transport families: $(printf '%s' "$FAMILIES" | tr -s ' ' | sed 's/^ //; s/ $//')"
	elif [ "$fam_count" -lt 2 ]; then
		badln "the bundle's transport-class mapping yields only $fam_count family; a single delivered bundle would be a single point of block (need >=2)"
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the subscription/bundle delivery channel is (or could become) a single point of block.\n' >&2
	exit 1
fi
printf 'PASS: no committed config pins a lone subscription URL, and the bundle spans >=2 independent\n'
printf '      transport families — the sub channel is not a single point of block (RP-0007-b).\n'
exit 0
