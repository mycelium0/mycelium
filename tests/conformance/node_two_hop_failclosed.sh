#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_two_hop_failclosed.sh — conformance: scripts/node-bootstrap.sh wires the Phase-1-audit
# fail-closed behaviours for the two-hop overlay, operator-toggle persistence, and the served-bundle
# promotion paths. Offline, inspect-only, fail-closed.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE (Phase-1 audit C17/C18/C19/C21/C25)
#   node-bootstrap.sh is the node control plane: it writes params, renders/promotes the server config and
#   the served distribution bundle, revokes clients, and merges the node-local two_hop egress overlay.
#   The audit found fail-OPEN / silent-revert defects on these paths. The fail-closed SHAPE logic itself
#   (a malformed/unknown/non-distinct two_hop is refused) is proved behaviourally by control/selftest.sh
#   against the renderer (render-server + bundle), which shares the exact same checks. This gate locks the
#   node-bootstrap WIRING that the renderer tests cannot reach (root-only flows), by inspecting the source:
#     * C19 — write_params HARD-FAILS (die, not warn) on a PRESENT-but-invalid two_hop.json, via the
#             shared assert_two_hop_shape validator; the old fail-open warn is gone.
#     * C19 — write_params PRESERVES operator-set toggles across regeneration (seed+merge overrides), so an
#             operator enablement is not silently reverted to default on every --update.
#     * C17/C18/C21 — assert_two_hop_shape validates the overlay (well-formed upstream, via_user is a known
#             client, egress distinct from ingress) before it is merged into params.
#     * C25 — flow_revoke (and flow_disable_two_hop) re-render the SERVED bundle on the promotion path, and
#             a bundle_served_age_seconds staleness signal is exposed.
#     * C21 — a documented --disable-two-hop remove path exists.
#
#   INSPECT-ONLY: it reasons about the committed node-bootstrap.sh source, never a live node.
#
# Exit: 0 = all fail-closed behaviours wired, 1 = a regression, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
[ -f "$NB" ] || { printf 'FAIL: node-bootstrap.sh not found: %s\n' "$NB" >&2; exit 2; }

# RP-0009 C2/C3 decomposition: the entrypoint sources its control-logic from control/lib/nb_*.sh. The
# render/serve groups this gate inspects (write_params + the C19 operator-override seed/merge, in
# nb_render_params.sh; render_serve_bundle + bundle_served_age* in nb_serve_bundle.sh) live in those libs;
# C3 then moved the two-hop ROUTING POLICY — assert_two_hop_shape + flow_disable_two_hop — into
# nb_two_hop.sh. The flow_revoke/flow_update dispatchers stay in the entrypoint. Inspect the entrypoint
# AND the sourced libs as one logical source so the wiring assertions follow the code that moved (the
# runtime behaviour is unchanged — everything is sourced into one shared scope on the node).
NB_RENDER_PARAMS="$REPO_ROOT/control/lib/nb_render_params.sh"
NB_SERVE_BUNDLE="$REPO_ROOT/control/lib/nb_serve_bundle.sh"
NB_TWO_HOP="$REPO_ROOT/control/lib/nb_two_hop.sh"
[ -f "$NB_RENDER_PARAMS" ] || { printf 'FAIL: nb_render_params.sh not found: %s\n' "$NB_RENDER_PARAMS" >&2; exit 2; }
[ -f "$NB_SERVE_BUNDLE" ]  || { printf 'FAIL: nb_serve_bundle.sh not found: %s\n'  "$NB_SERVE_BUNDLE"  >&2; exit 2; }
[ -f "$NB_TWO_HOP" ]       || { printf 'FAIL: nb_two_hop.sh not found: %s\n'       "$NB_TWO_HOP"       >&2; exit 2; }
# NB_SRC = the files that make up the node control plane (entrypoint + sourced control-logic libs).
NB_SRC="$NB $NB_RENDER_PARAMS $NB_SERVE_BUNDLE $NB_TWO_HOP"

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# fn_body NAME -> print the body of a shell function NAME from $NB_SRC (from its opener to the next line
# that is a single closing brace at column 0). bash 3.2-safe; used to scope assertions to one function.
# Scans the entrypoint + the sourced libs so a function that moved into a lib (RP-0009) is still found.
fn_body() {
	awk -v fn="$1" '
		FNR==1 { inb=0 }
		$0 ~ ("^"fn"\\(\\) \\{") || $0 ~ ("^"fn"\\(\\)$") { inb=1 }
		inb { print }
		inb && /^\}$/ { inb=0 }
	' $NB_SRC
}

printf '== node-bootstrap two-hop / toggle / served-bundle fail-closed check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# ---------------------------------------------------------------------------
# C19 — write_params hard-fails on a present-but-invalid two_hop (no fail-open warn).
# ---------------------------------------------------------------------------
if grep -q 'params written WITHOUT two-hop' $NB_SRC; then
	badln "C19: the fail-OPEN 'params written WITHOUT two-hop' warn is still present (must hard-fail instead)"
else
	okln "C19: no fail-open 'params written WITHOUT two-hop' warn (the fail-open regression is removed)"
fi
WP="$(fn_body write_params)"
if grep -q 'assert_two_hop_shape "\$STATE_DIR/two_hop.json"' <<<"$WP" ; then
	okln "C19/C17: write_params validates a present two_hop.json fail-closed (assert_two_hop_shape)"
else
	badln "C19/C17: write_params does not call assert_two_hop_shape on a present two_hop.json"
fi
# The two_hop merge-failure branch must die (fail-closed), not warn-and-continue.
wp_two_hop="$(awk '/two_hop.json/,/fi$/' <<<"$WP")"
if grep -q 'die "two_hop.json is present but could not be merged' <<<"$wp_two_hop"; then
	okln "C19: a failed two_hop merge in write_params hard-fails (die; never writes params without the overlay)"
else
	badln "C19: a failed two_hop merge in write_params does not hard-fail (possible fail-open)"
fi

# ---------------------------------------------------------------------------
# C19 — operator-toggle persistence: seed + merge overrides on top of regenerated defaults.
# ---------------------------------------------------------------------------
if grep -q 'seed_operator_overrides "\$tmp"' <<<"$WP" \
   && grep -q 'merge_operator_overrides "\$tmp"' <<<"$WP" ; then
	okln "C19: write_params seeds + merges operator-toggle overrides (operator enablement preserved across --update)"
else
	badln "C19: write_params does not preserve operator toggles (seed/merge_operator_overrides not wired)"
fi
# The override merge must honour ONLY an allowlist of operator-settable keys (identity-derived fields can
# never be smuggled), and identity fields (reality_private_key / secrets) must NOT be in that allowlist.
if grep -q 'OPERATOR_TOGGLE_KEYS=' $NB_SRC; then
	if grep -hA30 'OPERATOR_TOGGLE_KEYS=' $NB_SRC | grep -qE 'reality_private_key|ss_password|shadowtls_password|node_address'; then
		badln "C19: OPERATOR_TOGGLE_KEYS allowlist includes an identity-derived field (it must list ONLY operator toggles)"
	else
		okln "C19: OPERATOR_TOGGLE_KEYS is a closed allowlist of operator toggles (no identity-derived field can be pinned stale)"
	fi
else
	badln "C19: no OPERATOR_TOGGLE_KEYS allowlist (override merge is unbounded)"
fi

# ---------------------------------------------------------------------------
# C17/C18/C21 — assert_two_hop_shape enforces the overlay invariants fail-closed.
# ---------------------------------------------------------------------------
ATS="$(fn_body assert_two_hop_shape)"
if [ -n "$ATS" ]; then
	okln "C17: assert_two_hop_shape validator is defined"
else
	badln "C17: assert_two_hop_shape validator is missing"
fi
# C18: it asserts via_user against the known clients (IDENTITIES_JSON clients[].name).
if grep -q 'IDENTITIES_JSON' <<<"$ATS" \
   && grep -q '.name == \$u' <<<"$ATS" ; then
	okln "C18: assert_two_hop_shape checks via_user against the known clients (no dead auth_user route)"
else
	badln "C18: assert_two_hop_shape does not check via_user against known clients"
fi
# C21: it refuses an egress that equals the ingress (same address or same SNI) and dies.
if grep -q "is THIS node's own address" <<<"$ATS" \
   && grep -q "equals this node's donor_sni" <<<"$ATS" ; then
	okln "C21: assert_two_hop_shape refuses egress == ingress (distinct host AND distinct SNI required)"
else
	badln "C21: assert_two_hop_shape does not enforce ingress/egress distinctness"
fi
# It is fail-closed: every branch is a die.
if grep -q 'server_port is out of range' <<<"$ATS" \
   && grep -q 'server_port is not a positive integer' <<<"$ATS" ; then
	okln "C17: assert_two_hop_shape rejects a malformed server_port (range + integer, fail-closed)"
else
	badln "C17: assert_two_hop_shape does not fully validate server_port"
fi

# ---------------------------------------------------------------------------
# C25 — every config promotion path re-renders the served bundle; staleness is observable.
# ---------------------------------------------------------------------------
FR="$(fn_body flow_revoke)"
if grep -q 'render_serve_bundle' <<<"$FR" ; then
	okln "C25: flow_revoke re-renders the served bundle (render_serve_bundle on the revoke promotion path)"
else
	badln "C25: flow_revoke does NOT call render_serve_bundle (served bundle would point at a revoked UUID)"
fi
# C25: the served bundle must be re-rendered on every exit that leaves the node CONVERGED — not merely
# mentioned somewhere in the body. The previous check was branch-blind: it grepped flow_update for the
# literal `render_serve_bundle` and reported green while the byte-identical path returned early, above
# it, without converging anything. Both promote paths now reach the bundle through the shared
# convergence tail, so assert the tail is called on BOTH: the sing-box-byte-identical path AND the
# apply-success path. Only --staged may return without it (nothing was promoted; flow_ack carries it).
FU="$(fn_body flow_update | grep -vE '^[[:space:]]*#')"
tail_n="$(printf '%s\n' "$FU" | grep -cE '^[[:space:]]*converge_node_tail[[:space:]]*$' || true)"
if [ "$tail_n" -ge 2 ]; then
	okln "C25: flow_update converges on both the no-op and the apply path ($tail_n call sites)"
else
	badln "C25: flow_update calls converge_node_tail $tail_n time(s) (expected >=2: byte-identical AND apply-success) — a path that promotes or skips without converging leaves the xray engine/firewall/bundle behind"
fi
# HERE-STRINGS, not `printf … | grep -q`. Under `set -euo pipefail` that shape MISREPORTS A MATCH AS A FAILURE: `grep -q`
# exits on the first match and closes the pipe, so `printf` can be killed by SIGPIPE (141) and pipefail
# then reports the whole pipeline as FAILED even though the pattern MATCHED. It fails only when grep
# wins the race — deterministic once the unwritten remainder exceeds the pipe buffer: measured 0/20 below it and 20/20 above, which is exactly the "re-run before believing it"
# flake that trains people to ignore a red gate. Same class as the RP-0014 SIGPIPE finding; same remedy.
if grep -q 'render_serve_bundle' <<<"$(fn_body converge_node_tail | grep -vE '^[[:space:]]*#')"; then
	okln "C25: converge_node_tail re-renders the served bundle (served distribution stays current)"
else
	badln "C25: converge_node_tail does NOT render the served bundle"
fi
if grep -q 'converge_node_tail' <<<"$(fn_body flow_ack | grep -vE '^[[:space:]]*#')"; then
	okln "C25: flow_ack converges after promoting a staged candidate"
else
	badln "C25: flow_ack promotes a staged candidate without converging (stale xray/firewall/bundle)"
fi
if grep -q 'bundle_served_age_seconds' $NB_SRC && grep -q 'record_bundle_served_age' $NB_SRC; then
	okln "C25: a bundle_served_age_seconds staleness signal is exposed (a stuck last-known-good is observable)"
else
	badln "C25: no bundle_served_age_seconds staleness signal (a stuck last-known-good would be silent)"
fi

# ---------------------------------------------------------------------------
# C21 — a documented remove-two-hop path exists and re-renders both config + served bundle.
# ---------------------------------------------------------------------------
if grep -q -- '--disable-two-hop' "$NB" && grep -q 'flow_disable_two_hop' "$NB"; then
	# CODE ONLY. fn_body does not strip comments, and the prose inside these functions necessarily
	# NAMES the steps it performs — so an assertion run over the raw body is satisfied by the comment
	# alone and keeps passing after the call is deleted. Proven: removing converge_node_tail from
	# flow_disable_two_hop left this check green.
	FD="$(fn_body flow_disable_two_hop | grep -vE '^[[:space:]]*#')"
	# The bundle is now reached through the SHARED convergence tail, not by a direct call. Assert the
	# tail, not the literal: disabling two-hop is a promote path, so it owes the whole sequence (xray,
	# firewall, bundle) and not just the bundle — that was the gap. Accept a direct render_serve_bundle
	# too, so this check states the REQUIREMENT (the served bundle is refreshed) rather than one spelling
	# of it; promote_paths_converge.sh is what pins the tail specifically.
	# here-strings, not `printf | grep -q`: under the pipefail set at the top of this gate that shape is a
	# SIGPIPE race that reports a MATCH as a failure (~5 runs in 40 — see the C25 note above).
	if grep -q 'rm -f "\$STATE_DIR/two_hop.json"' <<<"$FD" \
	   && { grep -q 'converge_node_tail' <<<"$FD" || grep -q 'render_serve_bundle' <<<"$FD" ; }; then
		okln "C21: --disable-two-hop removes the overlay + re-renders config + converges (served bundle refreshed)"
	else
		badln "C21: flow_disable_two_hop does not fully remove + re-render/converge (incomplete remove path)"
	fi
else
	badln "C21: no --disable-two-hop remove path (disabling two-hop would require manual file surgery)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a node-bootstrap two-hop / toggle / served-bundle fail-closed behaviour regressed.\n' >&2
	exit 1
fi
printf 'PASS: node-bootstrap wires the two-hop / operator-toggle / served-bundle fail-closed behaviours.\n'
exit 0
