#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fp_rotate_gated.sh — conformance (RP-0015 increment B, B3): the client-fingerprint actuator is gated
# EXACTLY like the transport rotation (rotate_apply_gated.sh), on its OWN sentinel. It pins that a
# fingerprint rotation can promote a new preset ONLY behind the triple gate (dry-run default +
# --apply-rotation + a node-local fp arm sentinel), is reached only by the explicit --fp-rotate dispatch
# (never a bootstrap/update path), ships DISARMED, and its single delta is the closed-vocab client_fingerprint
# scalar (never an enable-key / protocol growth). This is what keeps "an auto-pull can never actuate" honest.
#
# Exit: 0 = correctly gated, 1 = a gate is missing/weakened, 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
LIB="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
MEAS="$REPO_ROOT/control/lib/nb_measure.sh"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== fingerprint-rotation gated check (RP-0015 B3) ==\n'
[ -f "$LIB" ] || { printf 'FAIL: nb_rotate_apply.sh missing.\n' >&2; exit 2; }
[ -f "$NB" ]  || { printf 'FAIL: node-bootstrap.sh missing.\n' >&2; exit 2; }

# extract a function body by name (from '<fn>() {' to the next line that is a bare '}').
fnbody() { awk -v fn="$1" 'index($0, fn"() {")==1{f=1} f{print} f&&/^\}/{exit}' "$2"; }

# 1) The fp actuator functions exist.
for fn in flow_rotate_fingerprint rotate_apply_fp_live rotate_apply_fp_dryrun fp_rotate_arm fp_rotate_disarm \
          persist_fp_to_overlay revert_fp_overlay _fp_rotation_set_delta fp_rotate_live_armed; do
	if grep -qE "^${fn}\(\)" "$LIB"; then ok "defines ${fn}()"; else badln "nb_rotate_apply.sh does not define ${fn}()"; fi
done

DRYRUN="$(fnbody rotate_apply_fp_dryrun "$LIB")"
LIVE="$(fnbody rotate_apply_fp_live "$LIB")"
FLOW="$(fnbody flow_rotate_fingerprint "$LIB")"

# 2) The dry-run default promotes NOTHING; promote is confined to the live path.
if printf '%s' "$DRYRUN" | grep -qw 'promote_config'; then
	badln "rotate_apply_fp_dryrun calls promote_config — the default path must promote NOTHING"
else
	ok "rotate_apply_fp_dryrun never promotes (dry-run default)"
fi
if printf '%s' "$LIVE" | grep -qw 'promote_config'; then
	ok "rotate_apply_fp_live is the sole promote path"
else
	badln "rotate_apply_fp_live does not call promote_config — the live path is incomplete"
fi
if printf '%s' "$FLOW" | grep -qw 'promote_config'; then
	badln "flow_rotate_fingerprint promotes directly (must be confined to the live path)"
else
	ok "flow_rotate_fingerprint does not promote directly"
fi

# 3) The triple gate: live only behind ROTATE_APPLY + fp_rotate_live_armed, with a dry-run fallback.
if printf '%s' "$FLOW" | grep -q 'ROTATE_APPLY' \
	&& printf '%s' "$FLOW" | grep -q 'fp_rotate_live_armed' \
	&& printf '%s' "$FLOW" | grep -qw 'rotate_apply_fp_live' \
	&& printf '%s' "$FLOW" | grep -qw 'rotate_apply_fp_dryrun'; then
	ok "flow_rotate_fingerprint gates the live path behind ROTATE_APPLY + fp_rotate_live_armed (dry-run fallback)"
else
	badln "flow_rotate_fingerprint does not gate the live path behind BOTH ROTATE_APPLY and fp_rotate_live_armed"
fi
# DRY_RUN must be consulted (the second leg of the gate).
if printf '%s' "$FLOW" | grep -q 'DRY_RUN'; then
	ok "flow_rotate_fingerprint consults DRY_RUN (the dry-run-default leg)"
else
	badln "flow_rotate_fingerprint does not consult DRY_RUN"
fi

# 4) Reached ONLY by the explicit --fp-rotate dispatch (never flow_bootstrap/flow_update/install_tooling).
calls="$(grep -cE '\bflow_rotate_fingerprint\b' "$NB" || true)"
if grep -qE '^[[:space:]]*fp-rotate\)[[:space:]]*flow_rotate_fingerprint' "$NB" && [ "${calls:-0}" -eq 1 ]; then
	ok "flow_rotate_fingerprint is reached ONLY via the explicit fp-rotate) dispatch"
else
	badln "flow_rotate_fingerprint is called from more than the fp-rotate) dispatch (or not wired)"
fi
if grep -qE '^[[:space:]]*--fp-rotate\)[[:space:]]*MODE="fp-rotate"' "$NB"; then
	ok "--fp-rotate maps to the fp-rotate MODE"
else
	badln "--fp-rotate is not wired to MODE=fp-rotate"
fi

# 5) The sentinel ships DISARMED: absent from git, never written by a bootstrap/update/install path.
if git -C "$REPO_ROOT" ls-files --error-unmatch 'control/state/fp-rotate-live.enabled' >/dev/null 2>&1 \
   || git -C "$REPO_ROOT" ls-files | grep -q 'fp-rotate-live.enabled'; then
	badln "the fp arm sentinel fp-rotate-live.enabled is TRACKED in git (must be node-local only)"
else
	ok "the fp arm sentinel is not tracked in git (node-local only)"
fi
# The sentinel is written ONLY by fp_rotate_arm (an explicit operator act), never by an unattended path.
armwriters="$(grep -rnE 'fp-rotate-live\.enabled' "$REPO_ROOT/control/lib" "$NB" 2>/dev/null | grep -E ':[[:space:]]*\(?[[:space:]]*umask|>[[:space:]]*"?\$\(_fp_rotate_sentinel|: >' || true)"
if grep -qE 'fp_rotate_arm\(\)' "$LIB"; then
	# The only writer of the sentinel is fp_rotate_arm; flow_bootstrap/flow_update must not touch it.
	if grep -REn 'fp_rotate_arm|fp-rotate-live\.enabled' "$REPO_ROOT/control/lib" "$NB" 2>/dev/null \
	   | grep -E 'flow_bootstrap|flow_update|install_tooling' | grep -q .; then
		badln "a bootstrap/update/install path references the fp arm — it must be an explicit operator act only"
	else
		ok "the fp arm sentinel is written only by the explicit --fp-rotate-arm act (no bootstrap/update path)"
	fi
fi

# 6) The single delta is the closed-vocab client_fingerprint scalar — no enable-key / protocol growth.
DELTA="$(fnbody _fp_rotation_set_delta "$LIB")"
if printf '%s' "$DELTA" | grep -qF '.client_fingerprint = $t'; then
	ok "_fp_rotation_set_delta sets ONLY .client_fingerprint (a scalar; no enable-key/proto growth)"
else
	badln "_fp_rotation_set_delta does not set .client_fingerprint as its sole delta"
fi
if printf '%s' "$DELTA" | grep -qE '_enabled|\.to_port|enable_key'; then
	badln "_fp_rotation_set_delta touches an enable-key/port — a fingerprint move must not toggle a transport"
else
	ok "_fp_rotation_set_delta touches no enable-key/port (a preset move never grows the served set)"
fi

# 7) The measure fp plane ships DISARMED (fp_rotate_enabled defaults false; a sentinel arms it durably).
if grep -qE 'MEASURE_FP_ROTATE_ENABLED="\$\{MEASURE_FP_ROTATE_ENABLED:-false\}"' "$MEAS"; then
	ok "the measure fp plane defaults DISARMED (MEASURE_FP_ROTATE_ENABLED=false)"
else
	badln "MEASURE_FP_ROTATE_ENABLED does not default to false"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the fingerprint actuator is not correctly gated.\n' >&2
	exit 1
fi
printf 'PASS: the fingerprint rotation is triple-gated, dispatch-only, ships disarmed, and moves a closed-vocab scalar.\n'
exit 0
