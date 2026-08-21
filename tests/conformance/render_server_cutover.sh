#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render_server_cutover.sh — conformance: the node renders its live data-plane config through the Go
# spine, falls back to the shell only when the spine is ABSENT, and never when it REFUSES.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   RP-0008 P3's cutover is the point where the Go renderer stops being decoration and starts producing
#   the bytes a node serves. Two ways to get that wrong, and only one of them is obvious:
#
#   * losing the fallback — a node whose spine was never built (install_spine warns rather than dies)
#     could then not render at all, and a node that cannot render cannot converge;
#   * keeping the fallback TOO WIDE — falling back when the spine REFUSES. The two producers are pinned
#     byte-identical, so a refusal is not an outage to route around, it is a real disagreement: most
#     likely a server template that no longer matches the structs the spine encodes
#     (spec.CheckServerTemplatePinned). Rendering it the other way would serve the edited template while
#     the spine says it cannot, and the fallback would be hiding precisely the drift the pin exists to
#     surface. Fail closed on a refusal; fall back only on absence.
#
#   And which producer ran must be LOGGED, or "this node renders through Go" is unfalsifiable from the
#   outside — which is the only reason the cutover is safe to make.
#
# WHAT IT CHECKS, by DRIVING the shipped function
#   `run` is stubbed to a recorder, so the trace IS what render_candidate did: which binary it invoked,
#   in which order, and whether it reached the other one.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the cutover has the right shape; 1 = it does not.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
LIB="$REPO_ROOT/control/lib/nb_update_apply.sh"
[ -f "$LIB" ] || { printf 'render_server_cutover: missing %s\n' "$LIB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the live config is rendered by the Go spine, and the fallback is absence-only ==\n\n'

# drive <spine:present|refusing|absent> -> the recorded trace (one command per line, plus die/log marks)
drive() {
	local mode="$1" W
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.rsc.XXXXXX")" || return 1
	mkdir -p "$W/bin"
	: > "$W/template.json"; : > "$W/params.json"; : > "$W/identities.json"
	printf '#!/bin/sh\nexit 0\n' > "$W/bin/myceliumctl"; chmod +x "$W/bin/myceliumctl"
	# The stub answers `version` like the real binary, because render_candidate now refuses a spine whose
	# rev does not match the deployed artifact. ARTIFACT_ROOT points at a git repo the fixture owns, so
	# "matching" and "skewed" are both reachable without touching the real checkout.
	( git init -q "$W/artifact" 2>/dev/null
	  cd "$W/artifact" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null ) >/dev/null 2>&1
	local art_rev; art_rev="$(git -C "$W/artifact" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
	local stub_rev="$art_rev"
	[ "$mode" = skewed ] && stub_rev="deadbeefdead"
	case "$mode" in
		absent) : ;;
		*)
			cat > "$W/bin/myceliumctl-go" <<STUB
#!/bin/sh
[ "\$1" = version ] && { printf 'myceliumctl 0.0.0 (rev %s)\n' "$stub_rev"; exit 0; }
exit $([ "$mode" = refusing ] && printf 1 || printf 0)
STUB
			chmod +x "$W/bin/myceliumctl-go" ;;
	esac
	(
		MYCTL="$W/bin/myceliumctl"
		SPINE_BIN="$W/bin/myceliumctl-go"
		ARTIFACT_ROOT="$W/artifact"
		RENDER_TEMPLATE="$W/template.json"; PARAMS_JSON="$W/params.json"; IDENTITIES_JSON="$W/identities.json"
		TRACE="$W/trace"
		log()  { printf 'LOG %s\n' "$*" >>"$TRACE"; }
		warn() { printf 'WARN %s\n' "$*" >>"$TRACE"; }
		die()  { printf 'DIE %s\n' "$*" >>"$TRACE"; exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }
		# The recorder: every external invocation this function makes goes through run().
		run()  { printf 'RUN %s\n' "$*" >>"$TRACE"; "$@"; }
		# shellcheck source=/dev/null
		. "$LIB" >/dev/null 2>&1 || exit 2
		MYCTL="$W/bin/myceliumctl"; SPINE_BIN="$W/bin/myceliumctl-go"; ARTIFACT_ROOT="$W/artifact"
		RENDER_TEMPLATE="$W/template.json"; PARAMS_JSON="$W/params.json"; IDENTITIES_JSON="$W/identities.json"
		render_candidate "$W/candidate.json"
	) >/dev/null 2>&1
	cat "$W/trace" 2>/dev/null
	rm -rf "$W"
}

# ---------------------------------------------------------------------------------------------------
# 1. THE SPINE RENDERS.
# ---------------------------------------------------------------------------------------------------
printf -- '-- with a working spine --\n'
t="$(drive present)"
if grep -q '^RUN .*myceliumctl-go render-server' <<<"$t" ; then
	ok "the Go spine is the one invoked"
else
	badln "the Go spine was not invoked (trace: $(printf '%s' "$t" | tr '\n' '|' | cut -c1-200)). Without this the cutover has not happened and every gate that pins the two producers equivalent is protecting a renderer nothing runs."
fi
grep -q '^RUN .*bin/myceliumctl render-server' <<<"$t" \
	&& badln "the shell renderer ALSO ran. Two producers writing the same candidate is the duplicate-truth defect with an ordering bug on top." \
	|| ok "and the shell renderer is not invoked as well"
grep -qi '^LOG rendered by the Go spine' <<<"$t" \
	&& ok "and the trace says which producer rendered" \
	|| badln "nothing logged which producer ran. Then 'this node renders through Go' cannot be checked from the outside, which is the only reason the cutover is safe to make."

# ---------------------------------------------------------------------------------------------------
# 2. A REFUSAL IS FATAL — the row this gate exists for.
# ---------------------------------------------------------------------------------------------------
printf '\n-- when the spine REFUSES --\n'
t2="$(drive refusing)"
if grep -q '^RUN .*bin/myceliumctl render-server' <<<"$t2" ; then
	badln "the shell renderer was used after the spine refused. The two are pinned byte-identical, so a refusal is a real disagreement — most likely a server template that no longer matches the structs the spine encodes — and rendering it the other way SERVES the thing the spine just said it could not, with the fallback hiding the drift."
else
	ok "the shell renderer is not used to route around a refusal"
fi
grep -q '^DIE ' <<<"$t2" \
	&& ok "and the converge fails closed, promoting nothing" \
	|| badln "a refusing spine did not fail closed (trace: $(printf '%s' "$t2" | tr '\n' '|' | cut -c1-200))"

# ---------------------------------------------------------------------------------------------------
# 3. ABSENCE STILL FALLS BACK — a node that cannot render cannot converge.
# ---------------------------------------------------------------------------------------------------
printf '\n-- when the spine was never built --\n'
t3="$(drive absent)"
if grep -q '^RUN .*bin/myceliumctl render-server' <<<"$t3" ; then
	ok "the shell producer still renders when no spine exists"
else
	badln "a node with no spine could not render at all (trace: $(printf '%s' "$t3" | tr '\n' '|' | cut -c1-200)). install_spine WARNs rather than dies when there is no Go toolchain, so this is a reachable state, and degrading beats bricking."
fi
grep -q '^WARN .*spine is not present' <<<"$t3" \
	&& ok "and the degradation is announced, not silent" \
	|| badln "the fallback happened silently — an operator cannot tell a spine-rendered node from a shell-rendered one"

# ---------------------------------------------------------------------------------------------------
# 4. A SPINE THAT DOES NOT MATCH THE DEPLOYED ARTIFACT MAY NOT RENDER.
#
# MEASURED on all three nodes at the first converge after the cutover: the checkout was one rev ahead of
# the binary that rendered the live config, and nothing said so. flow_node_apply does not install the
# tooling — only bootstrap and --update do — so the attended path renders through whatever is on disk.
# A stale spine is not a slower spine: it can be MISSING a check this artifact relies on (the server
# template pin) and would pass it by not having it.
# ---------------------------------------------------------------------------------------------------
printf '\n-- when the spine is a different rev from the artifact --\n'
t4="$(drive skewed)"
if printf '%s' "$t4" | grep -q '^RUN .*myceliumctl-go render-server'; then
	badln "a spine built from another rev rendered the live config anyway. It can be missing checks this artifact relies on — the server-template pin arrived in one rev and would simply not exist in the other — so the check passes by being absent."
else
	ok "a rev-skewed spine is not used to render"
fi
printf '%s' "$t4" | grep -q '^DIE ' \
	&& ok "and the converge fails closed rather than falling back" \
	|| badln "a rev-skewed spine neither rendered nor failed closed (trace: $(printf '%s' "$t4" | tr '\n' '|' | cut -c1-200)); falling back to the shell here would hide the skew instead of reporting it"
printf '%s' "$t4" | grep -q '^RUN .*bin/myceliumctl render-server' \
	&& badln "the shell renderer was used to route around the skew — that turns 'your tooling is stale' into a silent downgrade" \
	|| ok "and the shell renderer is not used to paper over it"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the render cutover does not have the shape it claims.\n' >&2
	exit 1
fi
printf 'PASS: the spine renders, a refusal is fatal, absence degrades loudly.\n'
exit 0
