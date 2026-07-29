#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# promote_paths_converge.sh — conformance: EVERY path that promotes a sing-box config converges the whole
# node through the one shared tail, and none of them re-implements a fragment of it.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   There are seven functions that promote a config, spread across the entrypoint and three libs. Each
#   used to end with its own idea of "and then finish up", and the differences were invisible because
#   every one of them logged success:
#     * flow_update reconciled sing-box and the bundle but never xray or the firewall, and reached even
#       the bundle only on the apply branch — returning early on the byte-identical path, which on a
#       timer is MOST ticks.
#     * flow_ack — the stricter, operator-gated mode — converged nothing at all.
#     * flow_revoke re-rendered sing-box and the bundle but not the xray config, which is rendered from
#       identities.json and carries client UUIDs. A revoked client stayed VALID on the xray inbound of
#       every xray-serving node until someone happened to run --node-apply, while that same code path
#       logged that the UUID was "gone from every inbound".
#     * flow_bootstrap carried an inlined copy in the inverse order, so every improvement to the shared
#       tail silently missed the FIRST-TIME deploy — the one path where a gap strands a new node.
#     * flow_disable_two_hop and rotate_apply_live rendered only the bundle. Rotation is the worst of
#       these: it promotes a SIBLING transport, routinely on a DIFFERENT port, unattended. Without the
#       firewall step the node rotates onto a port ufw does not admit and every check still passes,
#       because verify_post_apply is firewall-blind at each layer (service active, socket bound,
#       LOOPBACK handshake). The planner then counts a phantom path as the live one.
#   Seven implementations of one sequence is how that keeps happening. This gate pins the invariant
#   itself: promote implies converge, through converge_node_tail, and nowhere else.
#
# WHAT THIS CHECKS (offline, inspect-only, over comment-STRIPPED code so prose cannot satisfy a check)
#   1. converge_node_tail exists and performs all three steps in the load-bearing order:
#      xray -> firewall -> bundle. (harden_ufw reads the xray config's ports, so hardening before the
#      xray promote opens the PREVIOUS port set; the bundle is last so the served distribution only ever
#      describes a node that is already live and already reachable.)
#   2. Every function that calls promote_config also calls converge_node_tail.
#   3. No such function renders the bundle directly INSTEAD of converging — a bare bundle render is the
#      fragment the tail replaced, and stopping at it is how a path silently drops the other two steps.
#      Rendering it in ADDITION to converging is legitimate (the fp rotation does, on purpose).
#   4. No exemptions. Every promote path converges, including the fingerprint rotation — see the note on
#      EXEMPT below for why the one reasoned exception was removed rather than kept and re-verified.
#
# Exit: 0 = every promote path converges, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'promote_paths_converge: cannot resolve repo root\n' >&2; exit 2; }

# Every file that can define a promote path.
SRC="$REPO_ROOT/scripts/node-bootstrap.sh
$REPO_ROOT/control/lib/nb_render_params.sh
$REPO_ROOT/control/lib/nb_two_hop.sh
$REPO_ROOT/control/lib/nb_rotate_apply.sh
$REPO_ROOT/control/lib/nb_update_apply.sh"

# NO EXEMPTIONS. There was one — rotate_apply_fp_live, on the premise that a client fingerprint moves
# no port and appears nowhere in the served xray config, so converging would be a no-op. The premise was
# true and the exemption was still wrong: it holds only while the fingerprint never threads into the xray
# render or a port, so it had to be re-verified forever by whoever remembered it existed. The path now
# converges unconditionally (the steps are idempotent and no-op there anyway) and the special case is
# gone. If a future path genuinely cannot converge, say why in ITS code — do not add a name here.

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== every promote path converges through the shared tail ==\n'

while IFS= read -r f; do
	[ -n "$f" ] || continue
	[ -f "$f" ] || { printf 'FAIL: source not found: %s\n' "$f" >&2; exit 2; }
done <<EOF
$SRC
EOF

# body FN FILE — the function body, comments stripped, so a comment naming a step cannot satisfy a check.
body() {
	awk -v n="$1" 'index($0,n"()")==1{s=1} s{print} s&&/^\}/{exit}' "$2" 2>/dev/null | grep -vE '^[[:space:]]*#'
}
calls() { grep -cE "(^|[^_[:alnum:]])$1([^_[:alnum:]]|\$)" <<<"$2" || true; }

# 1. The tail itself: all three steps, in order.
tail_body=""
while IFS= read -r f; do
	[ -n "$f" ] || continue
	b="$(body converge_node_tail "$f")"
	[ -n "$b" ] && tail_body="$b"
done <<EOF
$SRC
EOF
if [ -z "$tail_body" ]; then
	bad "converge_node_tail is not defined anywhere — the shared tail is gone and every promote path is on its own again"
else
	x=$(grep -nE '(^|[^_[:alnum:]])apply_node_xray_engine' <<<"$tail_body" | head -1 | cut -d: -f1)
	u=$(grep -nE '(^|[^_[:alnum:]])harden_ufw'             <<<"$tail_body" | head -1 | cut -d: -f1)
	s=$(grep -nE '(^|[^_[:alnum:]])render_serve_bundle'    <<<"$tail_body" | head -1 | cut -d: -f1)
	if [ -n "$x" ] && [ -n "$u" ] && [ -n "$s" ]; then
		if [ "$x" -lt "$u" ] && [ "$u" -lt "$s" ]; then
			ok "converge_node_tail runs xray -> firewall -> bundle (the load-bearing order)"
		else
			bad "converge_node_tail's steps are out of order (xray@$x firewall@$u bundle@$s): harden_ufw reads the xray config's ports, so hardening first opens the PREVIOUS port set; the bundle must be last so it never advertises a node that is not yet reachable"
		fi
	else
		bad "converge_node_tail is missing a step (xray=${x:-absent} firewall=${u:-absent} bundle=${s:-absent}) — a path that calls it would silently stop converging that half"
	fi
fi

# 2+3. Every promote_config caller converges, and none renders the bundle directly.
found=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	while IFS= read -r fn; do
		[ -n "$fn" ] || continue
		# Skip the PRIMITIVE itself: promote_config's own body necessarily contains its own name, and it is
		# the thing being called, not a path that calls it. Nothing else is skipped — a real caller that
		# happened to be named promote_* would still be audited.
		[ "$fn" = "promote_config" ] && continue
		b="$(body "$fn" "$f")"
		[ "$(calls promote_config "$b")" -ge 1 ] || continue
		found=$((found + 1))
		short="${f#"$REPO_ROOT"/}"
		converges=0
		[ "$(calls converge_node_tail "$b")" -ge 1 ] && converges=1
		if [ "$converges" -eq 1 ]; then
			ok "$fn ($short): promotes and converges"
		else
			bad "$fn ($short): calls promote_config but NEVER converge_node_tail — it promotes a config and leaves the xray engine, the firewall and the served bundle describing the previous one"
		fi
		# A DIRECT bundle render is the fragment the tail replaced. It is a defect only when it stands IN
		# PLACE OF converging — which is exactly how every instance of this bug looked. As a supplement to
		# converging it is legitimate: rotate_apply_fp_live renders the bundle early on purpose, because a
		# fingerprint change is client-facing and must reach clients even when nothing restarts.
		if [ "$(calls render_serve_bundle "$b")" -ge 1 ] && [ "$converges" -eq 0 ]; then
			bad "$fn ($short): renders the served bundle DIRECTLY and never converges — that is the fragment converge_node_tail replaced, and a path that stops at it has dropped the xray and firewall steps with it"
		fi
	done <<INNER
$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$f" | sed 's/()//')
INNER
done <<EOF
$SRC
EOF

if [ "$found" -ge 6 ]; then
	ok "audited $found promote paths across the entrypoint and its libs"
else
	bad "only $found promote paths found (expected at least 6) — the discovery sweep is not seeing them, so this gate would pass vacuously"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a promote path does not converge the node. Every one of these has shipped a real defect\n' >&2
	printf '      before — a revoked client left live on the xray inbound, a first-time deploy missing the\n' >&2
	printf '      firewall, a rotation onto a ufw-blocked port that every check reported as healthy.\n' >&2
	exit 1
fi
printf 'PASS: every promote path converges through converge_node_tail, in the load-bearing order, with no\n'
printf '      exemptions.\n'
exit 0
