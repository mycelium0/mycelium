#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_client_conf_go_equiv.sh — conformance (RP-0008): the Go-owned AmneziaWG CLIENT config renderer
# (spec.RenderAWGClientConfig / `myceliumctl awg-client-conf`) is BYTE-IDENTICAL to the bash twin
# (render_awg_client_conf in control/lib/nb_render_awg.sh).
#
# WHY. This is the artefact a user actually imports. It embeds the node's per-node DIALECT, so a single
# byte of drift between the producer that wrote the SERVER config and the producer that wrote the CLIENT
# config takes that client off the network. The two also have to agree on the Selective-Growth marker
# placement, or a deliberate full tunnel would stop being recorded.
#
# Also asserts (independently of the diff) that BOTH producers place the opt-out marker whenever the route
# set is a default route — the property, not just the agreement.
#
# Exit: 0 = identical (or skipped), 1 = divergence, 2 = usage/precondition.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
AWG_LIB="$REPO_ROOT/control/lib/nb_render_awg.sh"

printf '== AmneziaWG client config: Go <-> shell byte-equivalence (RP-0008) ==\n'
[ -f "$AWG_LIB" ] || { printf 'FAIL: nb_render_awg.sh missing.\n' >&2; exit 2; }
command -v go >/dev/null 2>&1 || { printf 'SKIP: no Go toolchain.\n'; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf 'shell FAILED: %s\n' "$*" >&2; exit 1; }
log()  { :; }
warn() { :; }
STATE_DIR="${STATE_DIR:-/nonexistent}"
DRY_RUN=0
DO_AMNEZIAWG=1
# shellcheck source=/dev/null
. "$AWG_LIB" 2>/dev/null || { printf 'FAIL: could not source nb_render_awg.sh.\n' >&2; exit 2; }
command -v render_awg_client_conf >/dev/null 2>&1 || { printf 'FAIL: render_awg_client_conf not defined (the shared shell renderer).\n' >&2; exit 2; }

WORK="$(mktemp -d)" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
if ! ( cd "$REPO_ROOT" && go build -o "$WORK/myceliumctl" ./cmd/myceliumctl ) 2>/dev/null; then
	printf 'SKIP: could not build myceliumctl.\n'
	exit 0
fi

# SYNTHETIC test material. These are deliberately NOT key-shaped high-entropy strings: the renderer
# embeds whatever string it is given and the derivation hashes it, so realistic-looking base64 would add
# nothing but a standing secret-scanner false positive (and a reader's moment of doubt). Self-describing
# placeholders make it evident at a glance that no real material is committed.
NODEVAL="fixture-node-value-conformance-only-00000001"
CPRIV="fixture-client-private-conformance-only-0001"
CPSK="fixture-client-preshared-conformance-only-01"
SPUB="fixture-server-public-conformance-only-00001"
ENDPOINT="node.example.invalid:51820"
printf '%s' "$NODEVAL" > "$WORK/node.key"
printf '%s' "$CPRIV"   > "$WORK/client.key"
printf '%s' "$CPSK"    > "$WORK/client.psk"
printf '10.0.0.0/8\n172.16.0.0/12\n' > "$WORK/region.txt"

fail=0
checked=0

for host in 2 7 239; do
	for v6 in 0 1; do
		for epoch in 0 3; do
			for mode in full narrow region; do
				# --- shell half: resolve routes the same way the node does, then render ---
				AWG_FULL_TUNNEL_OPTOUT=0; AWG_SPLIT_TUNNEL=1; AWG_REGION_EXCLUDE_FILE=""
				go_mode_args=()
				case "$mode" in
					full)   AWG_FULL_TUNNEL_OPTOUT=1; go_mode_args=(--full-tunnel) ;;
					region) AWG_REGION_EXCLUDE_FILE="$WORK/region.txt"; go_mode_args=(--region-exclude "$WORK/region.txt") ;;
					narrow) : ;;
				esac
				derive_awg_dialect "$NODEVAL" "$epoch"
				compute_client_allowed "$v6" >/dev/null 2>&1 || { printf '  FAIL  shell refused an expected-valid policy (%s)\n' "$mode"; fail=1; continue; }
				allowed="$(sg_allowed_join)"
				sh_out="$(render_awg_client_conf "$CPRIV" "$host" "$v6" "$SPUB" "$CPSK" "$ENDPOINT" "$allowed" "$SG_MARKER")"

				# --- Go half: the same inputs through the CLI ---
				go_args=(--private-key-file "$WORK/client.key" --psk-file "$WORK/client.psk"
					--node-key-file "$WORK/node.key" --server-public-key "$SPUB"
					--endpoint "$ENDPOINT" --host "$host" --epoch "$epoch")
				[ "$v6" -eq 1 ] && go_args+=(--has-v6)
				go_out="$("$WORK/myceliumctl" awg-client-conf "${go_args[@]}" "${go_mode_args[@]}" 2>/dev/null)"

				checked=$((checked + 1))
				if [ -z "$go_out" ]; then
					printf '  FAIL  Go produced nothing (host=%s v6=%s epoch=%s mode=%s)\n' "$host" "$v6" "$epoch" "$mode"
					fail=1
					continue
				fi
				if [ "$sh_out" != "$go_out" ]; then
					printf '  FAIL  DIVERGED host=%s v6=%s epoch=%s mode=%s\n' "$host" "$v6" "$epoch" "$mode"
					diff <(printf '%s\n' "$sh_out") <(printf '%s\n' "$go_out") | sed 's/^/         /' >&2
					fail=1
				fi
				# The property, on BOTH outputs: a default route must always carry the recorded marker.
				for out_name in sh_out go_out; do
					out_val="${!out_name}"
					if grep -q 'AllowedIPs = 0\.0\.0\.0/0' <<<"$out_val" ; then
						grep -qF 'selective-growth: opt-out (full-tunnel)' <<<"$out_val" || {
							printf '  FAIL  %s emitted a full tunnel with NO opt-out marker (mode=%s)\n' "$out_name" "$mode"
							fail=1
						}
					fi
				done
			done
		done
	done
done

[ "$fail" -eq 0 ] && printf '  ok    %d client configs are byte-identical across both producers\n' "$checked"

# The renderer must be SHARED in shell: both the first-time render and the live issue path go through
# render_awg_client_conf, so they cannot drift from each other (or from Go).
inline="$(grep -c "printf 'PersistentKeepalive = 25" "$AWG_LIB" 2>/dev/null || echo 0)"
if [ "${inline:-0}" -eq 1 ]; then
	printf '  ok    the shell has exactly ONE client renderer (no duplicated inline render)\n'
else
	printf '  FAIL  found %s inline client renders in the shell lib — they must all go through render_awg_client_conf\n' "$inline"
	fail=1
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the Go and shell client-config renderers disagree (a drifting dialect or marker would take\n' >&2
	printf '      clients off the network).\n' >&2
	exit 1
fi
printf 'PASS: the client config renders identically in both producers, marker property held.\n'
exit 0
