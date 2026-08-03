#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotate_apply_executes.sh — conformance: the rotation apply path is RUN, over a value table of plans,
# instead of being read. It also refuses a declared rotation move that no code can ever request.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   The rotation apply path had never executed. Not "was not covered by a test" — had never run at all,
#   on any node, ever. The rotate loop fires every 90 seconds and had produced a HOLD every single time
#   for months; a deliberate fault-injection drill on a live node walked the planner through
#   active-clean -> streak-too-short -> no-better-candidate and still never reached an act plan.
#
#   The reason is structural, and it is worth stating precisely because it is invisible from either side
#   alone. The planner emits exactly TWO of the five moves in the closed set: "none" and
#   "promote-sibling". "promote-sibling" writes `<proto>_enabled = true` — and the candidate list is
#   built from measure.config.json, which is built only from ENABLED protos. So the one move the planner
#   can request is, on any node with its transports on, a write of a value that is already there: the
#   rendered candidate comes out byte-identical and the executor short-circuits before promoting. The
#   other three moves — rotate-port, regen-reality, demote-active — appear in production code exactly
#   once each, inside the validity switch. Nothing assigns them.
#
#   Meanwhile the EXECUTOR is not the missing half: apply_rotation_to_params already handles a port move
#   (_rotation_port_key_if_moving), gated on the port key being an operator-toggleable one. The machinery
#   to move a transport to a different port is written, tested by nothing, and never asked for.
#
#   So the risk this gate addresses is not "a bug in rotation". It is that the code which will run for
#   the first time during a real outage has no evidence behind it.
#
# WHAT IT CHECKS
#   A. EXECUTION over a value table — apply_rotation_to_params is called for real against a params
#      fixture, and the resulting params compared:
#        1. a promote-sibling onto an already-enabled proto changes nothing (this documents the no-op
#           that makes the live path unreachable — if it ever stops being a no-op, that is a real change
#           in behaviour and should be a deliberate one);
#        2. a promote-sibling onto a DISABLED proto flips its enable key and nothing else;
#        3. a plan carrying to_port > 0 MOVES the port — the half that exists and has never run;
#        4. a to_port whose port key is NOT operator-toggleable does NOT move the port (fail-safe: a
#           rotation may not reach past the operator's own toggle surface);
#        5. a plan with no .to.proto fails closed rather than writing a partial delta.
#   B. NO PHANTOM MOVES — every member of the RotationAction closed set is either assigned somewhere in
#      production Go, or named in the RESERVED list below with a reason. A move that is declared,
#      validated, and unrequestable is a capability the project believes it has and does not.
#
# OFFLINE. No root. Nothing outside its own mktemp root.
# Exit: 0 = the apply path behaves as tabulated; 1 = it does not; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotate_apply_executes: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
VOCAB="$REPO_ROOT/control/vocab.json"
for f in "$LIB" "$FIXTURE" "$VOCAB"; do
	[ -f "$f" ] || { printf 'rotate_apply_executes: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'rotate_apply_executes: jq required\n' >&2; exit 2; }

# Moves that are deliberately declared but not yet requestable. Each needs a REASON, so removing a move
# from this list is a decision someone makes on purpose rather than a diff nobody notices.
#   rotate-port    — the executor half exists; the planner half does not. Emitting it unattended would
#                    change a served port, and every subscription already in a client's hands names the
#                    OLD port with no live channel to re-fetch (the bundle is rendered but served on
#                    loopback only). Until clients can learn a new port, this must stay unrequestable.
#   regen-reality  — re-keying REALITY invalidates every issued client for that family, same problem.
#   demote-active  — has no defined successor semantics without one of the two above.
RESERVED="rotate-port regen-reality demote-active"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== rotation apply: run the path, and refuse a move nothing can request ==\n'

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }

seed_params() {
	jq -n '{
		node_address: "203.0.113.9", donor_sni: "www.example.invalid", tls_sni: "tls.example.invalid",
		vless_reality_vision_enabled: true,  vless_reality_vision_port: 8443,
		hysteria2_enabled:            true,  hysteria2_port:            8444,
		shadowtls_enabled:            false, shadowtls_port:            8446
	}' > "$1"
}
plan() { # PROTO TO_PORT -> a minimal act plan
	jq -n --arg p "$1" --argjson tp "$2" \
		'{act:true, from:{proto:"vless-reality-vision",action:"none",from_port:8443,to_port:0},
		  to:{proto:$p, action:"promote-sibling", from_port:0, to_port:$tp}, reason:"degraded-active"}'
}

# --- A. execute the apply over the table -------------------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	export MYC_VOCAB="$VOCAB"
	# shellcheck source=/dev/null
	. "$REPO_ROOT/control/lib/nb_render_params.sh" 2>/dev/null || true   # OPERATOR_TOGGLE_KEYS
	# shellcheck source=/dev/null
	. "$LIB"
	need_root() { :; }

	P="$FAKENODE_ROOT/params.json"; PL="$FAKENODE_ROOT/plan.json"

	# 1. already-enabled target -> byte-identical params (the no-op that makes the live path unreachable)
	seed_params "$P"; before="$(cat "$P")"
	plan hysteria2 0 > "$PL"
	( apply_rotation_to_params "$PL" "$P" ) >/dev/null 2>&1 \
		|| badln "apply_rotation_to_params ABORTED on an ordinary promote-sibling plan — the rows below prove nothing"
	[ "$before" = "$(cat "$P")" ] \
		&& ok "promote-sibling onto an ALREADY-ENABLED proto writes no change (this is why the live apply short-circuits)" \
		|| badln "promote-sibling onto an already-enabled proto CHANGED params. That is a real behaviour change: today the identical-candidate short-circuit is what stops an always-on node restarting sing-box for nothing."

	# 2. disabled target -> the enable key flips, and only that
	seed_params "$P"
	plan shadowtls 0 > "$PL"
	( apply_rotation_to_params "$PL" "$P" ) >/dev/null 2>&1 || true
	[ "$(jq -r '.shadowtls_enabled' "$P")" = "true" ] \
		&& ok "promote-sibling onto a DISABLED proto enables it" \
		|| badln "promote-sibling did not enable a disabled proto — the single move the planner can emit does nothing at all"
	[ "$(jq -r '.hysteria2_enabled' "$P")" = "true" ] && [ "$(jq -r '.vless_reality_vision_port' "$P")" = "8443" ] \
		&& ok "it touches nothing else (other toggles and ports intact)" \
		|| badln "the delta altered keys outside the plan's target"

	# 3. a port move — the executor half that exists and has never run
	seed_params "$P"
	plan hysteria2 8455 > "$PL"
	( apply_rotation_to_params "$PL" "$P" ) >/dev/null 2>&1 || true
	got="$(jq -r '.hysteria2_port' "$P")"
	[ "$got" = "8455" ] \
		&& ok "a plan carrying to_port MOVES the served port (8444 -> 8455)" \
		|| badln "to_port was ignored: the port stayed $got. The port-move machinery is written and gated on the port key being operator-toggleable; if it silently does nothing, then when a planner is finally taught to emit rotate-port the move will appear to succeed and change nothing."

	# 4. a to_port whose key is NOT operator-toggleable must NOT move
	seed_params "$P"
	OPERATOR_TOGGLE_KEYS='["vless_reality_vision_enabled"]'
	plan hysteria2 8455 > "$PL"
	( apply_rotation_to_params "$PL" "$P" ) >/dev/null 2>&1 || true
	[ "$(jq -r '.hysteria2_port' "$P")" = "8444" ] \
		&& ok "a port key outside the operator toggle surface is NOT moved (fail-safe)" \
		|| badln "the rotation moved a port key the operator's own toggle surface does not include — an unattended loop must not reach past it"

	# 5. a plan with no target fails closed
	seed_params "$P"; before="$(cat "$P")"
	jq -n '{act:true, to:{action:"promote-sibling"}}' > "$PL"
	if ( apply_rotation_to_params "$PL" "$P" ) >/dev/null 2>&1; then
		badln "a plan with no .to.proto was ACCEPTED — a malformed plan must never reach the params file"
	else
		ok "a plan with no .to.proto fails closed"
	fi
	[ "$before" = "$(cat "$P")" ] \
		&& ok "and it left params byte-unchanged" \
		|| badln "the failed apply still mutated params — a partial delta is worse than none"
	exit "$fail"
) || fail=1

# --- B. no declared move may be unrequestable without saying so --------------------------------------
printf '\n-- declared moves vs moves anything can request --\n'
declared="$(grep -oE 'RotationAction[A-Za-z]+ +RotationAction += +"[a-z-]+"' "$REPO_ROOT/internal/spec/rotate.go" 2>/dev/null \
	| sed -E 's/.*"([a-z-]+)"/\1/' | sort -u)"
[ -n "$declared" ] || { badln "could not read the RotationAction constants — this section would pass vacuously"; declared=""; }

for a in $declared; do
	[ "$a" = "none" ] && continue
	konst="$(grep -oE "RotationAction[A-Za-z]+ +RotationAction += +\"$a\"" "$REPO_ROOT/internal/spec/rotate.go" | awk '{print $1}' | head -1)"
	[ -n "$konst" ] || continue
	# An ASSIGNMENT of the constant anywhere in production Go (not the declaration, not the validity
	# switch, not tests) is what makes a move requestable.
	assigns="$(grep -rn "= *spec\.$konst\|= *$konst" --include='*.go' "$REPO_ROOT/internal" "$REPO_ROOT/cmd" 2>/dev/null \
		| grep -v '_test\.go' | grep -vE 'RotationAction[A-Za-z]+ +RotationAction +=' | wc -l | tr -d ' ')"
	if [ "${assigns:-0}" -gt 0 ]; then
		ok "$a: requestable (assigned in production code)"
	else
		case " $RESERVED " in
			*" $a "*) ok "$a: declared but deliberately not requestable (listed as reserved, with a reason)" ;;
			*) badln "$a is a declared rotation move that NOTHING assigns and that is not listed as reserved. It validates, it round-trips, and no planner can ever ask for it — a capability the project believes it has and does not. Either emit it or add it to RESERVED with the reason it is held back." ;;
		esac
	fi
done

for a in $RESERVED; do
	printf '%s' "$declared" | grep -qx "$a" \
		|| badln "RESERVED names '$a', which is not a declared RotationAction — the list has drifted from the closed set and no longer means anything"
done

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the rotation apply path does not behave as tabulated, or a declared move is unrequestable.\n' >&2
	exit 1
fi
printf 'PASS: the apply path runs as tabulated; every declared move is requestable or explicitly reserved.\n'
exit 0
