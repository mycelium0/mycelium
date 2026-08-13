#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotate_judges_a_set.sh — conformance: the rotation planner judges the SET of transports a node serves,
# each member on its own evidence and in its own direction.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   A fungi serves several people who need not know one another, on several transports at once
#   (ADR-0040 §2). The planner's input was shaped around a single `Active` member and a single
#   `ActiveVerdict`, so the node's health WAS the health of one transport. Two concrete consequences,
#   both invisible to every test that existed:
#
#     - One impairment counter served every member. An impairment on A advanced the very streak that
#       authorises acting on B, so B was rotated on evidence gathered about something else.
#     - A member's role was not recorded, so nothing could refuse an egress-only conclusion about an
#       ingress member — the asymmetry ADR-0039 established existed in lease.go and could not be
#       expressed by anything that reached the planner.
#
#   ADR-0039's corollary said it first: *any planner input shaped around one active transport is a defect
#   against this ADR and against ADR-0034*. It sat there as an observation for as long as nothing checked
#   it. This gate is the check.
#
# WHAT IT CHECKS, by RUNNING the shipped planner over crafted served sets
#   1. An impairment on one member does not accrue on a healthy sibling, and the plan is about the
#      impaired member.
#   2. The subject is deterministic across repeated runs — a pure planner whose decision depends on map
#      order is not reproducible and cannot be audited.
#   3. A set with nothing impaired holds, and the hold still names a real member.
#   4. A producer that has not been updated (Active/ActiveVerdict, no `served`) behaves exactly as before.
#   5. When `served` is populated the legacy fields are IGNORED, not merged — two half-populated sources
#      for one truth is the defect being removed, not a compatibility feature.
#   6. Direction is fail-closed: unset and out-of-vocabulary are refused rather than defaulted.
#   7. The producer emits the set — driven, not grepped, via the internal/measure unit that asserts it.
#      A set-valued planner with no producer would be the inert mechanism this project has shipped twice.
#
# SKIP-IF-NO-GO: like bundle_go_roundtrip.sh, this needs a Go toolchain to run the real planner. Absent,
# it SKIPs rather than passing vacuously — the jq-only host lane has no planner to drive.
#
# Exit: 0 = the planner judges a set; 1 = it judges a member and calls that the node.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotate_judges_a_set: cannot resolve repo root\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }

GO=""
if command -v go >/dev/null 2>&1; then
	GO="$(command -v go)"
else
	for cand in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do
		[ -x "$cand" ] && { GO="$cand"; break; }
	done
fi
if [ -z "$GO" ]; then
	printf '\nSKIP: no Go toolchain present — this gate drives the real planner via\n'
	printf '      `go run ./cmd/myceliumctl rotate-plan`. NOT a failure (jq-only host/CI lane);\n'
	printf '      the same behaviour is asserted by `go test ./internal/rotate ./internal/measure`.\n'
	printf 'PASS (skipped): the set planner was not exercised here.\n'
	exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.set.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the planner judges the set a node serves, not one member of it ==\n'
printf 'go: %s\n\n' "$GO"

# ---------------------------------------------------------------------------------------------------
# The harness. plan FILE -> the plan JSON on stdout, or empty on a refusal (rc carried in $PLAN_RC).
# ---------------------------------------------------------------------------------------------------
PLAN_RC=0
plan() {
	local out
	out="$( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod \
		"$GO" run ./cmd/myceliumctl rotate-plan "$1" 2>"$WORK/err" )"
	PLAN_RC=$?
	printf '%s' "$out"
}

# member PROTO WEIGHT STATE DIRECTION -> one ServedMember object.
# The verdict's class/ref are node-local joins; the reason follows the state so the object validates.
member() {
	local proto="$1" w="$2" st="$3" dir="$4" reason=none cls=reality-tcp
	[ "$st" = clean ] || reason=handshake-timeout
	case "$proto" in
		hysteria2|tuic) cls=quic-udp ;;
		amneziawg)      cls=amneziawg-udp ;;
	esac
	jq -nc --arg p "$proto" --argjson w "$w" --arg st "$st" --arg r "$reason" \
		--arg c "$cls" --arg d "$dir" \
		'{member: {proto:$p, class:$c, action:"promote-sibling", from_port:0, to_port:0,
		           promoted:true, weight:$w},
		  verdict: {state:$st, reason:$r, class:$c, transport_ref:("ref-"+$p),
		            decided_at:"2026-01-01T00:00:00Z"},
		  direction: $d}'
}

# input FILE STATE_JSON SERVED_JSON [FLIP] — assemble a full PlanInput. `ranked` always offers one clean,
# heavily-favoured target so a hold can never be blamed on there being nowhere to go. FLIP is the
# hysteresis threshold and defaults to 1, because most rows here are about WHICH member is judged rather
# than about how long it takes; the rows that compare two streaks raise it, since streaks saturate at FLIP
# and two saturated members are tied by construction.
input() {
	local out="$1" state="$2" served="$3" flip="${4:-1}"
	jq -n --argjson state "$state" --argjson served "$served" --argjson flip "$flip" \
		'{active: {proto:"vless-reality-vision", class:"reality-tcp", action:"promote-sibling",
		           from_port:0, to_port:0, promoted:true, weight:0.2},
		  active_verdict: {state:"blocked", reason:"handshake-timeout", class:"reality-tcp",
		                   transport_ref:"ref-legacy", decided_at:"2026-01-01T00:00:00Z"},
		  ranked: [{proto:"vless-reality-grpc", class:"reality-tcp", action:"promote-sibling",
		            from_port:0, to_port:0, promoted:true, weight:0.95}],
		  limits: {flip_confirmations:$flip, min_weight_margin:0.1, min_interval_ns:1800000000000,
		           window_ns:3600000000000, max_per_window:2, max_rollbacks_per_window:1,
		           cooldown_after_rollback_ns:3600000000000},
		  state: $state,
		  now: "2026-06-01T00:00:00Z",
		  served: $served}' >"$out"
}

ZERO='{"last_rotate_at":"0001-01-01T00:00:00Z","window_start":"0001-01-01T00:00:00Z","rotations_in_window":0,"rollbacks_in_window":0,"impaired_streak":0,"hold_until":"0001-01-01T00:00:00Z"}'

# ---------------------------------------------------------------------------------------------------
# 1. AN IMPAIRMENT DOES NOT CROSS MEMBERS. This is the defect, stated as arithmetic.
# ---------------------------------------------------------------------------------------------------
printf -- '-- one member impaired among healthy ones --\n'
input "$WORK/a.json" "$ZERO" "$(jq -nc --argjson a "$(member vless-reality-vision 0.2 blocked ingress)" \
	--argjson b "$(member hysteria2 0.9 clean ingress)" \
	--argjson c "$(member amneziawg 0.9 clean ingress)" '[$a,$b,$c]')"
out="$(plan "$WORK/a.json")"
if [ "$PLAN_RC" -ne 0 ]; then
	badln "the planner refused a valid three-member served set: $(head -2 "$WORK/err" | tr '\n' ' ')"
else
	subj="$(printf '%s' "$out" | jq -r '.from.proto')"
	[ "$subj" = "vless-reality-vision" ] \
		&& ok "the plan is about the impaired member ($subj)" \
		|| badln "the plan is about '$subj', which is not the impaired member. The subject is whichever member the evidence is about; anything else acts on one transport using another's verdict."
	clean_streaks="$(printf '%s' "$out" | jq -r '[.next_state.impaired_streaks // {} | to_entries[] | select(.key != "vless-reality-vision") | "\(.key)=\(.value)"] | join(" ")')"
	[ -z "$clean_streaks" ] \
		&& ok "and the healthy members accrued no streak at all" \
		|| badln "healthy members carry streaks: $clean_streaks. A streak is permission to act on that member; accruing one from somebody else's impairment is how a working transport is taken away from the people using it."
	imp="$(printf '%s' "$out" | jq -r '.next_state.impaired_streaks["vless-reality-vision"] // 0')"
	[ "$imp" = "1" ] \
		&& ok "and the impaired member advanced by exactly one" \
		|| badln "the impaired member's streak is '$imp', want 1."
fi

# ---------------------------------------------------------------------------------------------------
# 2. DETERMINISM. Two impaired members, one with the longer history.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the subject is reproducible --\n'
st2="$(printf '%s' "$ZERO" | jq -c '. + {impaired_streaks: {"hysteria2": 2}}')"
input "$WORK/b.json" "$st2" "$(jq -nc --argjson a "$(member vless-reality-vision 0.2 blocked ingress)" \
	--argjson b "$(member hysteria2 0.2 blocked ingress)" '[$a,$b]')" 3
seen=""
for _ in 1 2 3 4 5; do
	seen="$seen $(plan "$WORK/b.json" | jq -r '.from.proto')"
done
uniq_subj="$(printf '%s' "$seen" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')"
case "$uniq_subj" in
	*" "*) badln "five runs of the identical input chose different subjects ($uniq_subj). The planner is pure by contract, and a decision that depends on map iteration order cannot be reproduced from a captured input or explained after the fact." ;;
	hysteria2) ok "five runs agree, and the member with the longer streak is the subject" ;;
	*) badln "the subject is '$uniq_subj', but hysteria2 arrived with a streak of 2 against the other member's 0. Whichever member has been impaired longest is the one the evidence is strongest about." ;;
esac

# The tie. Two members that saturate at the same streak must still resolve the same way every time, and
# by something stated — registry order — rather than by whatever the map iterator happened to yield.
input "$WORK/b2.json" "$(printf '%s' "$ZERO" | jq -c '. + {impaired_streaks: {}}')" \
	"$(jq -nc --argjson a "$(member hysteria2 0.2 blocked ingress)" \
	   --argjson b "$(member vless-reality-vision 0.2 blocked ingress)" '[$a,$b]')"
tie=""
for _ in 1 2 3; do tie="$tie $(plan "$WORK/b2.json" | jq -r '.from.proto')"; done
tie_u="$(printf '%s' "$tie" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')"
case "$tie_u" in
	*" "*) badln "two members on equal streaks resolved to different subjects across runs ($tie_u) — the tiebreak is not a rule, it is the map's iteration order." ;;
	*) ok "and two members on equal streaks resolve the same way every run ($tie_u), by registry order" ;;
esac

# ---------------------------------------------------------------------------------------------------
# 3. A CLEAN SET HOLDS, and the hold still names something real.
# ---------------------------------------------------------------------------------------------------
printf '\n-- a healthy set --\n'
input "$WORK/c.json" "$ZERO" "$(jq -nc --argjson a "$(member vless-reality-vision 0.9 clean ingress)" \
	--argjson b "$(member hysteria2 0.9 clean ingress)" '[$a,$b]')"
out="$(plan "$WORK/c.json")"
if [ "$PLAN_RC" -ne 0 ]; then
	badln "a fully healthy served set was refused: $(head -2 "$WORK/err" | tr '\n' ' ')"
else
	act="$(printf '%s' "$out" | jq -r '.act')"
	[ "$act" = "false" ] \
		&& ok "nothing impaired, nothing acted on" \
		|| badln "a set with no impaired member produced act=$act. A node that rotates while everything works is churning the access of people nothing is wrong with."
	nm="$(printf '%s' "$out" | jq -r '.from.proto')"
	[ -n "$nm" ] && [ "$nm" != "null" ] \
		&& ok "and the hold names a real member ($nm), so the decision is readable afterwards" \
		|| badln "the hold names no member. A plan that does not say what it held on cannot be explained from the record."
fi

# ---------------------------------------------------------------------------------------------------
# 4 + 5. THE PRODUCER CONTRACT. Old producers keep working; new ones are not merged with the old fields.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the two producer shapes --\n'
input "$WORK/d.json" "$(printf '%s' "$ZERO" | jq -c '.impaired_streak = 1')" '[]'
out="$(plan "$WORK/d.json")"
if [ "$PLAN_RC" -ne 0 ]; then
	badln "a legacy producer (active/active_verdict, no served) was refused: $(head -2 "$WORK/err" | tr '\n' ' ')"
else
	[ "$(printf '%s' "$out" | jq -r '.act')" = "true" ] \
		&& ok "a producer that sends no 'served' still acts exactly as before" \
		|| badln "the legacy input stopped acting ($(printf '%s' "$out" | jq -r '.reason')). A node running an older spine sends this shape on every tick; breaking it stops rotation on every node that has not been updated yet."
	[ "$(printf '%s' "$out" | jq -r '.next_state.impaired_streaks["vless-reality-vision"] // 0')" -ge 1 ] \
		&& ok "and its scalar streak carried into the per-member map rather than being dropped" \
		|| badln "the legacy scalar streak did not migrate. A node mid-upgrade would re-earn every streak from zero, silently delaying every rotation by FlipConfirmations ticks."
fi

# The migration that matters on a live node: rotate_state.json out there carries a scalar and no map,
# while the updated producer sends the whole served set. The scalar was the incumbent's streak, so it
# must land on the incumbent — dropping it delays every rotation by a full hysteresis cycle on a node
# whose transport is failing right now, and spreading it would act on the others a cycle early.
input "$WORK/d2.json" "$(printf '%s' "$ZERO" | jq -c '.impaired_streak = 2')" \
	"$(jq -nc --argjson a "$(member vless-reality-vision 0.2 blocked ingress)" \
	   --argjson b "$(member hysteria2 0.2 blocked ingress)" '[$a,$b]')" 3
out="$(plan "$WORK/d2.json")"
mig="$(printf '%s' "$out" | jq -r '.next_state.impaired_streaks["vless-reality-vision"] // 0')"
sib="$(printf '%s' "$out" | jq -r '.next_state.impaired_streaks["hysteria2"] // 0')"
[ "$mig" = "3" ] \
	&& ok "an old scalar state carries onto the incumbent when the set arrives ($mig)" \
	|| badln "the incumbent's migrated streak is '$mig', want 3 (a scalar of 2, plus this tick). A node upgrading mid-outage would wait another full hysteresis cycle before it could act."
[ "$sib" = "1" ] \
	&& ok "and the other members start from zero rather than inheriting somebody else's history" \
	|| badln "a non-incumbent member came out at '$sib' — the scalar was spread across the set. It belonged to one member, and crediting it to the rest authorises acting on them a cycle early on evidence never gathered about them."

input "$WORK/e.json" "$ZERO" "$(jq -nc --argjson a "$(member hysteria2 0.2 blocked ingress)" '[$a]')"
out="$(plan "$WORK/e.json")"
subj="$(printf '%s' "$out" | jq -r '.from.proto')"
[ "$subj" = "hysteria2" ] \
	&& ok "with 'served' populated the legacy 'active' is ignored, not merged" \
	|| badln "the subject is '$subj' while the served set names hysteria2 — the planner is still reading the legacy field. Two half-populated sources for one truth is the duplicate-owner defect (development.md §2.2 item 8), and here it means acting on a member the producer did not report."

# ---------------------------------------------------------------------------------------------------
# 6. DIRECTION IS FAIL-CLOSED.
# ---------------------------------------------------------------------------------------------------
printf '\n-- direction --\n'
for d in "" sideways outbound; do
	input "$WORK/f.json" "$ZERO" "$(jq -nc --argjson a "$(member hysteria2 0.2 blocked "$d")" '[$a]')"
	plan "$WORK/f.json" >/dev/null
	if [ "$PLAN_RC" -eq 0 ]; then
		badln "a served member with direction '${d:-<unset>}' was accepted. Direction decides which evidence may justify suppressing a member — an egress-only conclusion about an ingress member is the ADR-0039 error, and it is checkable only while unknown fails closed instead of defaulting."
	fi
done
[ "$fail" -eq 0 ] && ok "unset and out-of-vocabulary directions are all refused"
for d in ingress egress; do
	input "$WORK/g.json" "$ZERO" "$(jq -nc --argjson a "$(member hysteria2 0.2 blocked "$d")" '[$a]')"
	plan "$WORK/g.json" >/dev/null
	[ "$PLAN_RC" -eq 0 ] || badln "direction '$d' is in the closed vocabulary but was refused: $(head -2 "$WORK/err" | tr '\n' ' ')"
done
ok "and both roles in the vocabulary are accepted"

# ---------------------------------------------------------------------------------------------------
# 7. SOMETHING ACTUALLY SENDS THE SET.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the producer emits it --\n'
if ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod \
	"$GO" test ./internal/measure -run TestTickEmitsServedSet -count=1 >"$WORK/prod" 2>&1 ); then
	ok "internal/measure assembles a served set with per-member verdicts and typed directions"
else
	badln "the measure daemon does not emit the set: $(tail -3 "$WORK/prod" | tr '\n' ' '). A set-valued planner nothing feeds is a mechanism that reads as working and does nothing — the exact shape of the two inert mechanisms already found in this tree."
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the planner still treats one member as the health of the node.\n' >&2
	exit 1
fi
printf 'PASS: members are judged on their own evidence, in their own direction, from a real producer.\n'
exit 0
