#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# bundle_family_floor_both_renderers.sh — conformance: the independent-family floor is enforced by the
# renderer that actually runs on a node, not only by the one that does not.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   RP-0013's floor — a served bundle must span >= 2 independent block families — is the precondition for
#   end-to-end client recovery: a single-family block must never take away a client's last path. It was
#   enforced in internal/spec/bundle_render.go, and NOT in control/lib/render_bundle.sh.
#
#   The shell renderer is the one that runs. nb_install.sh keeps MYCTL as the shell tool and installs
#   myceliumctl-go non-load-bearing. So on a real node, one enabled proto produced a one-endpoint bundle
#   at rc=0 and it was served — while QUICKSTART told the reader the node refuses exactly that. Measured
#   in Audit-0012: two tools named `myceliumctl` disagreed about whether the DEFAULT profile is
#   publishable, and no fixture anywhere drove the default profile through either of them.
#
#   That is §2.2 item 8 — one truth type, one owner — with the added twist that the copy which did NOT
#   hold the invariant is the copy in production.
#
# WHAT IT CHECKS
#   1. The equivalence (class -> block family) and the threshold are emitted by Go into
#      control/vocab.json, so the shell compares rather than re-deriving (ADR-0038). A second hand-kept
#      mapping is the defect, not the fix.
#   2. The emitted map covers EVERY class in the closed vocabulary. A class the map does not know would
#      otherwise count as its own family and inflate the total — a gap that fails open.
#   3. The floor predicate, driven: one family refused, two accepted, an unknown class refused rather
#      than counted.
#   4. The shell renderer contains the check at all, reading the vocab.
#   5. THE DEFAULT PROFILE, driven through the predicate — the fixture neither renderer had.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the floor holds where it runs; 1 = it does not.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'bundle_family_floor: cannot resolve repo root\n' >&2; exit 2; }
VOCAB="$REPO_ROOT/control/vocab.json"
SHELL_RENDER="$REPO_ROOT/control/lib/render_bundle.sh"
GO_RENDER="$REPO_ROOT/internal/spec/bundle_render.go"
for f in "$VOCAB" "$SHELL_RENDER" "$GO_RENDER"; do
	[ -f "$f" ] || { printf 'bundle_family_floor: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf '  SKIP  jq unavailable; nothing can be driven.\nPASS (skipped)\n'; exit 0; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the family floor is enforced where the render happens ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1 + 2. THE EMITTED EQUIVALENCE, and that it is complete.
# ---------------------------------------------------------------------------------------------------
floor="$(jq -r '.independent_family_floor // empty' "$VOCAB")"
[ -n "$floor" ] && [ "$floor" -ge 2 ] 2>/dev/null \
	&& ok "the floor is emitted by Go and is $floor" \
	|| badln "control/vocab.json carries no usable .independent_family_floor (got '${floor:-nothing}'). The shell renderer falls back to a literal, which is a second copy of a Go-owned number — the thing ADR-0038 exists to prevent."

classes="$(jq -r '.transport_classes[]?' "$VOCAB")"
mapped="$(jq -r '.block_families // {} | keys[]?' "$VOCAB")"
missing=""
for c in $classes; do
	printf '%s\n' "$mapped" | grep -qx "$c" || missing="$missing $c"
done
if [ -z "$missing" ]; then
	ok "and every class in the closed vocabulary has a block family ($(printf '%s' "$classes" | wc -w | tr -d ' ') classes)"
else
	badln "these classes have no block family in the emitted map:$missing. An unmapped class counts as its own family, inflating the total — so the gap FAILS OPEN, letting a single-family bundle through the very check that exists to stop it."
fi

# The map must actually collapse something, or the floor is just "two endpoints".
distinct_fams="$(jq -r '[.block_families // {} | to_entries[] | .value] | unique | length' "$VOCAB")"
n_classes="$(printf '%s' "$classes" | wc -w | tr -d ' ')"
[ "$distinct_fams" -lt "$n_classes" ] 2>/dev/null \
	&& ok "and it collapses $n_classes classes into $distinct_fams families — families, not endpoints" \
	|| badln "the map is one-to-one ($n_classes classes, $distinct_fams families). Then 'independent families' means nothing beyond 'distinct classes', and two transports that a single own-TLS-SNI block takes out together would count as independent."

# ---------------------------------------------------------------------------------------------------
# 3 + 5. THE PREDICATE, DRIVEN — including the default profile, the fixture nobody had.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the predicate, driven --\n'
verdict() { # verdict <bundle-json> -> refused-unmapped | refused-floor | accepted
	local b="$1" un fam
	un="$(printf '%s' "$b" | jq -r --slurpfile v "$VOCAB" \
		'[.endpoints[].transport_class | select((($v[0].block_families)//{})[.] == null)] | unique | join(" ")')"
	[ -n "$un" ] && { printf 'refused-unmapped'; return; }
	fam="$(printf '%s' "$b" | jq -r --slurpfile v "$VOCAB" \
		'[.endpoints[].transport_class | (($v[0].block_families)//{})[.]] | unique | length')"
	[ "${fam:-0}" -lt "${floor:-2}" ] && printf 'refused-floor' || printf 'accepted'
}
mk() { # mk <class>... -> a bundle json
	local eps="" c i=0
	for c in "$@"; do
		i=$((i+1))
		eps="$eps{\"tag\":\"e$i\",\"transport_class\":\"$c\",\"region\":\"unspecified\",\"priority\":0,\"health\":\"unknown\",\"link\":\"x://y\"},"
	done
	printf '{"version":1,"generated_at":"2026-01-01T00:00:00Z","endpoints":[%s]}' "${eps%,}"
}

got="$(verdict "$(mk reality-tcp)")"
[ "$got" = refused-floor ] \
	&& ok "one family is refused" \
	|| badln "a single-family bundle was '$got'. That is the state RP-0013 forbids: one block and the client has nowhere left."

# THE DEFAULT PROFILE. ADR-0022 defaults on {vless_reality_vision, vless_reality_grpc} — both
# reality-tcp, i.e. ONE family. This is the fixture the audit found missing from both renderers, and it
# is the profile every fresh node ships with.
got="$(verdict "$(mk reality-tcp reality-tcp)")"
if [ "$got" = refused-floor ]; then
	ok "and the DEFAULT profile (two REALITY protos, one family) is refused — the fixture neither renderer had"
else
	badln "the default profile rendered as '$got'. Both default protos are reality-tcp, so they collapse to ONE family and a REALITY block removes the client's last path. Either the floor is not counted over families, or the default profile needs a second family before a bundle may be served."
fi

got="$(verdict "$(mk reality-tcp amneziawg-udp)")"
[ "$got" = accepted ] \
	&& ok "two genuinely independent families are accepted" \
	|| badln "a two-family bundle was '$got' — the floor now refuses valid configurations, which is a different outage"

got="$(verdict "$(mk quic-udp ws-tls)")"
[ "$got" = refused-floor ] \
	&& ok "and two classes that collapse to one family (own-TLS-SNI) are refused, not counted as two" \
	|| badln "quic-udp + ws-tls was '$got'. Both map to own-tls-sni: one block on the node's own TLS SNI takes both, so counting them as independent is the failure the equivalence exists to prevent."

got="$(verdict "$(mk no-such-class reality-tcp)")"
[ "$got" = refused-unmapped ] \
	&& ok "an unknown class is refused rather than counted as its own family" \
	|| badln "an unmapped class produced '$got' instead of a refusal — it was counted, which fails open exactly where a new transport is most likely to be added."

# ---------------------------------------------------------------------------------------------------
# 4. THE SHELL RENDERER HAS THE CHECK, and reads the vocab for it.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the renderer that runs on a node enforces it --\n'
body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$SHELL_RENDER")"
printf '%s' "$body" | grep -q 'block_families' \
	&& ok "control/lib/render_bundle.sh reads .block_families from the Go-owned vocab" \
	|| badln "the shell bundle renderer has no family check. It is the one that runs — nb_install.sh keeps MYCTL as the shell tool — so the floor being present only in Go means it is not present on any node."
printf '%s' "$body" | grep -q 'independent_family_floor' \
	&& ok "and reads the threshold from there too, rather than restating it" \
	|| badln "the shell renderer does not read .independent_family_floor. A literal 2 here is a second copy of a Go-owned number, and the two drift the moment the floor changes."
grep -q 'IndependentFallbackOK' "$GO_RENDER" \
	&& ok "and the Go renderer still enforces the same floor — both, not one" \
	|| badln "internal/spec/bundle_render.go no longer enforces the floor. Moving the check rather than mirroring it leaves the Go path — used by deploy-plan and the equivalence gates — able to emit what the node would refuse."

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a bundle that leaves a client one block away from nothing can still be served.\n' >&2
	exit 1
fi
printf 'PASS: the floor is Go-owned, complete, driven, and enforced by the renderer that runs.\n'
exit 0
