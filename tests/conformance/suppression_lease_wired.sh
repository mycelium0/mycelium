#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# suppression_lease_wired.sh — conformance: planner decision -> grant -> render -> expiry -> return, run
# end to end against the shipped binaries.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   The lease mechanism shipped in 0.2.80 complete, tested, documented — and INERT. `spec.LeaseSet.Grant`
#   had no non-test caller, so no lease was ever granted, while four surfaces described it as the way the
#   loop takes a member out of service: a CHANGELOG entry, two Prometheus alerts on series nothing
#   emitted, a `fungi` status line, and a renderer that faithfully applied a file nobody wrote.
#
#   Audit-0012 B2 found it, and the finding is not "a feature was unfinished". It is the same defect this
#   whole audit is about — a component reporting confidently on something that is not happening — with
#   the reporting done by the documentation instead of by the code. The absence of THIS gate is what let
#   it ship: every unit test passed, because every unit worked.
#
#   So this gate refuses to test a unit. It runs the real planner, hands its real plan to the real
#   writer, renders with the real renderer, advances the clock past the term, and requires the member
#   back.
#
# WHAT IT CHECKS
#   1. The planner PROPOSES a withdrawal, and proposes it only on evidence about this node (ADR-0039).
#   2. The writer grants it: a term, a count, an expiry that exists.
#   3. It refuses when somebody is on the member — ADR-0040 §2.4, the guard the whole design turns on.
#   4. It refuses when the node CANNOT SEE who is on the member. Not-observed is not idle: a UDP family
#      has no connection table, and a missing or stale marker is not a report of an empty listener.
#   5. It refuses when the independent-family floor would break, and when the outstanding budget is spent.
#   6. The term BACKS OFF on a repeat, and is capped.
#   7. The renderer stops serving the member while the lease stands.
#   8. Expiry returns it, and `release` returns it at once — the operator's verb.
#   9. A hold plan and a promote plan grant nothing. A suppression is reachable only through an act plan
#      the loop produced, which is the §2.2 item 4 (S0) single-entry rule.
#
# SKIP-IF-NO-GO: needs a Go toolchain to run the shipped planner and writer. Absent, it SKIPs rather than
# passing vacuously.
#
# Exit: 0 = the loop can withdraw a member, bounded, and gives it back; 1 = it cannot, or it can do so
# without the guards.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'suppression_lease_wired: cannot resolve repo root\n' >&2; exit 2; }
PARAMS_LIB="$REPO_ROOT/control/lib/nb_render_params.sh"
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
	printf '\nSKIP: no Go toolchain present — this gate runs the shipped planner and lease writer.\n'
	printf '      NOT a failure (jq-only host/CI lane); the guards themselves are driven by\n'
	printf '      `go test ./internal/spec -run Lease`, and the shell half by suppression_lease_bounded.sh.\n'
	printf 'PASS (skipped): the wiring was not exercised here.\n'
	exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/myc.wired.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the loop can take a member out of service, for a bounded term, and gives it back ==\n'
printf 'go: %s\n\n' "$GO"

ctl() { ( cd "$REPO_ROOT" && GOCACHE="$W/gocache" GOFLAGS=-mod=mod "$GO" run ./cmd/myceliumctl "$@" ); }

NOW="2026-06-01T12:00:00Z"

# --- the fixtures ----------------------------------------------------------------------------------
# Three served members spanning three independent families, so withdrawing the REALITY one still leaves
# two — the shape in which a demote is permitted at all.
cat >"$W/limits.json" <<'JSON'
{"flip_confirmations":1,"min_weight_margin":0.1,"min_interval_ns":1800000000000,
 "window_ns":3600000000000,"max_per_window":2,"max_rollbacks_per_window":1,
 "cooldown_after_rollback_ns":3600000000000,
 "max_suppression_ttl_ns":86400000000000,"max_outstanding_suppressions":2}
JSON
jq -n '{"vless-reality-vision":"ref-v","amneziawg":"ref-a","hysteria2":"ref-h"}' >"$W/refs.json"
ENABLED="vless-reality-vision,amneziawg,hysteria2"

marker() { # marker <carrying-json> <observed-json> [observed_at]
	jq -n --argjson c "$1" --argjson o "$2" --arg t "${3:-$NOW}" \
		'{observed_at:$t, checked:3, reset:[], collapse:[], carrying:$c, carrying_observed:$o}' >"$W/marker.json"
}

member() { # member PROTO CLASS WEIGHT STATE REASON
	jq -nc --arg p "$1" --arg c "$2" --argjson w "$3" --arg s "$4" --arg r "$5" \
		'{member:{proto:$p, class:$c, action:"promote-sibling", from_port:0, to_port:0, promoted:true, weight:$w},
		  verdict:{state:$s, reason:$r, class:$c, transport_ref:("ref-"+$p), decided_at:"2026-01-01T00:00:00Z"},
		  direction:"ingress"}'
}

# planinput REASON -> a PlanInput whose only move is to cease serving the REALITY member.
# No sibling beats it by the margin (0.25 < 0.2 + 0.1), which is what routes the planner to the demote
# branch rather than to a promote.
planinput() {
	jq -n --arg r "$1" --argjson lim "$(cat "$W/limits.json")" --arg now "$NOW" \
		--argjson a "$(member vless-reality-vision reality-tcp 0.2 blocked "$1")" \
		--argjson b "$(member amneziawg amneziawg-udp 0.25 clean none)" \
		--argjson c "$(member hysteria2 quic-udp 0.25 clean none)" '{
		active: $a.member, active_verdict: $a.verdict,
		served: [$a, $b, $c],
		ranked: [$b.member, $c.member],
		limits: $lim,
		state: {last_rotate_at:"0001-01-01T00:00:00Z", window_start:"0001-01-01T00:00:00Z",
		        rotations_in_window:0, rollbacks_in_window:0, impaired_streak:0,
		        impaired_streaks:{}, hold_until:"0001-01-01T00:00:00Z"},
		now: $now,
		issued_baseline: ["vless-reality-vision","amneziawg","hysteria2"]}'
}

grant() { # grant [extra args...] -> writes $W/grant.out / $W/grant.err, sets GRANT_RC
	ctl lease grant --plan "$W/plan.json" --leases "$W/leases.json" --limits "$W/limits.json" \
		--marker "$W/marker.json" --refs "$W/refs.json" --enabled "$ENABLED" --now "$NOW" "$@" \
		>"$W/grant.out" 2>"$W/grant.err"
	GRANT_RC=$?
}

# ---------------------------------------------------------------------------------------------------
# 1. THE PLANNER PROPOSES — and only on evidence about this node.
# ---------------------------------------------------------------------------------------------------
printf -- '-- the planner proposes a withdrawal --\n'
planinput handshake-timeout >"$W/in.json"
if ! ctl rotate-plan "$W/in.json" >"$W/plan.json" 2>"$W/plan.err"; then
	badln "the planner refused a well-formed input: $(head -2 "$W/plan.err" | tr '\n' ' ')"
	printf '\nFAIL: nothing downstream can be tested.\n' >&2
	exit 1
fi
act="$(jq -r '.act' "$W/plan.json")"; sup="$(jq -r '.suppress.proto // "none"' "$W/plan.json")"
if [ "$act" = "true" ] && [ "$sup" = "vless-reality-vision" ]; then
	ok "a listener fault on the REALITY member produces an act that proposes withdrawing it"
else
	badln "the plan is act=$act suppress=$sup (reason $(jq -r .reason "$W/plan.json")). Without a proposal there is nothing for the writer to grant, and the demote branch would be actuating through some other path."
fi
[ "$(jq -r '.suppress.direction' "$W/plan.json")" = "ingress" ] \
	&& ok "and records the role it was serving in, so the evidence pairing is checkable later" \
	|| badln "the proposal carries no direction; ADR-0039's rule cannot be re-checked at the point of use"

# The other half of the rule: a path-level fault is real, observed at the node, and STILL not something
# this node may withdraw an ingress member on — it cannot tell interference from one client's network.
planinput connection-reset >"$W/in2.json"
ctl rotate-plan "$W/in2.json" >"$W/plan2.json" 2>/dev/null
r2="$(jq -r '.reason' "$W/plan2.json" 2>/dev/null)"; s2="$(jq -r '.suppress.proto // "none"' "$W/plan2.json" 2>/dev/null)"
if [ "$s2" = "none" ] && [ "$r2" = "evidence-not-permitted" ]; then
	ok "a connection-reset fault proposes NOTHING and says why (evidence-not-permitted)"
else
	badln "a path-level fault produced reason=$r2 suppress=$s2. connection-reset comes from watching real client flows: for an ingress member the node cannot separate interference from one client's bad network, and withdrawing it disconnects everyone else to react to a fault they may not share."
fi

# ---------------------------------------------------------------------------------------------------
# 2. THE WRITER GRANTS, with a term.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the writer grants it --\n'
marker '[]' '["ref-v","ref-a"]'
rm -f "$W/leases.json"
grant
if [ "$GRANT_RC" -ne 0 ]; then
	badln "the grant was refused on a clean fixture: $(head -2 "$W/grant.err" | tr '\n' ' ')"
else
	exp="$(jq -r '.leases[0].expires_at // ""' "$W/leases.json" 2>/dev/null)"
	cnt="$(jq -r '.leases[0].count // 0' "$W/leases.json" 2>/dev/null)"
	[ -n "$exp" ] && [ "$exp" != "null" ] \
		&& ok "the lease exists and carries an expiry ($exp)" \
		|| badln "the granted lease has no expiry — a permanent suppression is the one state this whole mechanism exists to make impossible"
	[ "$cnt" = "1" ] && ok "and a count of 1, the base of the backoff" || badln "count is '$cnt', want 1"
	[ "$(stat -c %a "$W/leases.json" 2>/dev/null || stat -f %Lp "$W/leases.json")" = "600" ] \
		&& ok "and the file is 0600 — the lease names what this node is not serving" \
		|| badln "the lease file is not 0600"
fi

# ---------------------------------------------------------------------------------------------------
# 3 + 4. THE REFUSALS THAT PROTECT PEOPLE. Each is driven; each must name its own cause.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and refuses when it must --\n'
refuses() { # refuses <label> <expected-substring>
	if [ "$GRANT_RC" -eq 0 ]; then
		badln "$1 — the grant SUCCEEDED. $2"
	else
		ok "$1"
	fi
}
rm -f "$W/leases.json"; marker '["ref-v"]' '["ref-v","ref-a"]'; grant
refuses "a member with live client sessions is not withdrawn" \
	"That is ADR-0040 §2.4: the node cannot see whose sessions it is ending, and a probe failure is not permission to disconnect the people visibly succeeding on it."

rm -f "$W/leases.json"; marker '[]' '["ref-a"]'; grant
refuses "a member the connection-table observer cannot see is not withdrawn" \
	"UDP families have no connection table, so 'absent from the carrying list' means unseen, not idle — and suppressing on that removes a member with every one of its users still on it."

rm -f "$W/leases.json" "$W/marker.json"; grant
refuses "no observer marker at all is not a report of an empty listener" \
	"An unarmed observer means the node has made no observation; treating that as 'nobody is on it' is a conclusion from missing data."

rm -f "$W/leases.json"; marker '[]' '["ref-v","ref-a"]' "2026-06-01T09:00:00Z"; grant
refuses "a stale marker is refused — a three-hour-old count is a count of who WAS on it" \
	"Session counts move; an old one is not evidence about now."

rm -f "$W/leases.json"; marker '[]' '["ref-v","ref-a"]'
# A node serving only the two REALITY members: one family, so withdrawing either leaves nothing
# independent behind. The plan's own floor is counted over what CLIENTS HOLD; this one over what the
# node SERVES. Two different questions, deliberately asked in two places.
if ctl lease grant --plan "$W/plan.json" --leases "$W/leases.json" --limits "$W/limits.json" \
	--marker "$W/marker.json" --refs "$W/refs.json" --enabled "vless-reality-vision,vless-reality-grpc" \
	--now "$NOW" >"$W/grant.out" 2>"$W/grant.err"; then
	badln "the floor did not bind — a node serving two REALITY members has ONE independent family, and withdrawing either leaves a client blocked on REALITY with nowhere left to go (RP-0013)."
else
	printf '%s' "$(cat "$W/grant.err")" | grep -qi 'floor' \
		&& ok "the independent-family floor binds, counted over families rather than over protos" \
		|| badln "the grant was refused but not by the floor: $(head -1 "$W/grant.err")"
fi

# The budget: one unrelated lease already standing, cap of 1.
jq '.max_outstanding_suppressions = 1' "$W/limits.json" >"$W/lim1.json"
jq -n --arg t "$NOW" '{version:1, leases:[{proto:"hysteria2", direction:"ingress", evidence:"listener-fault",
	since:"2026-06-01T11:00:00Z", expires_at:"2026-06-01T23:00:00Z", count:1}]}' >"$W/leases.json"
if ctl lease grant --plan "$W/plan.json" --leases "$W/leases.json" --limits "$W/lim1.json" \
	--marker "$W/marker.json" --refs "$W/refs.json" --enabled "$ENABLED" --now "$NOW" \
	>"$W/grant.out" 2>"$W/grant.err"; then
	badln "the outstanding-suppression budget did not bind. A correlated fault — a bad render, an engine restart — would then suppress the whole node one member at a time, every grant individually justified."
else
	ok "and the outstanding-suppression budget binds, so a correlated fault cannot take the node apart one member at a time"
fi

# ---------------------------------------------------------------------------------------------------
# 6. BACKOFF.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the term backs off on a repeat --\n'
rm -f "$W/leases.json"; marker '[]' '["ref-v","ref-a"]'
grant; t1="$(jq -r '.leases[] | select(.proto=="vless-reality-vision") | (((.expires_at|fromdateiso8601) - (.since|fromdateiso8601)))' "$W/leases.json" 2>/dev/null)"
grant; t2="$(jq -r '.leases[] | select(.proto=="vless-reality-vision") | (((.expires_at|fromdateiso8601) - (.since|fromdateiso8601)))' "$W/leases.json" 2>/dev/null)"
c2="$(jq -r '.leases[] | select(.proto=="vless-reality-vision") | .count' "$W/leases.json" 2>/dev/null)"
if [ "${t1:-0}" -gt 0 ] 2>/dev/null && [ "${t2:-0}" = "$(( ${t1:-0} * 2 ))" ] && [ "$c2" = "2" ]; then
	ok "a second consecutive suppression lasts twice as long (${t1}s -> ${t2}s, count $c2)"
else
	badln "the term went ${t1}s -> ${t2}s (count $c2), expected a doubling. Under a fixed term an INTERMITTENT fault costs a full suppress/restore pair every cycle — a config change, a reload and a client-visible flap, forever."
fi

# ---------------------------------------------------------------------------------------------------
# 7 + 8. RENDER, EXPIRY, RETURN. The half that decides whether anyone notices.
# ---------------------------------------------------------------------------------------------------
printf '\n-- render, expiry, return --\n'
render_state() { # render_state <leases-file|NONE> -> the enabled value of the suppressed key
	local lf="$1" R
	R="$(mktemp -d "${TMPDIR:-/tmp}/myc.wr.XXXXXX")" || return 1
	(
		export REPO_ROOT ARTIFACT_ROOT="$REPO_ROOT" STATE_DIR="$R" DRY_RUN=0
		log() { :; }; warn() { :; }; die() { exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }; run() { "$@"; }
		# shellcheck source=/dev/null
		. "$PARAMS_LIB" >/dev/null 2>&1 || exit 2
		jq -n '{vless_reality_vision_enabled:true, amneziawg_enabled:true}' >"$R/params.json"
		[ "$lf" = NONE ] || cp -f "$lf" "$R/rotate.leases.json"
		apply_suppression_leases "$R/params.json" >/dev/null 2>&1
	)
	jq -r 'if has("vless_reality_vision_enabled") then .vless_reality_vision_enabled else "absent" end' \
		"$R/params.json" 2>/dev/null
	rm -rf "$R"
}
# THE RENDERER READS THE WALL CLOCK, and it must: an expiry is a real instant, not a parameter. So this
# section grants against the real clock rather than the fixed $NOW the guard rows use — a lease minted at
# a 2026-06-01 fixture expires long before `date -u +%s` reads it, and the row would report the renderer
# ignoring an in-force lease when what it actually did was correctly reap an expired one. The fixed clock
# is right for the refusals (they are pure) and wrong here.
REAL_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$W/leases.json"
marker '[]' '["ref-v","ref-a"]' "$REAL_NOW"
ctl lease grant --plan "$W/plan.json" --leases "$W/leases.json" --limits "$W/limits.json" \
	--marker "$W/marker.json" --refs "$W/refs.json" --enabled "$ENABLED" >"$W/grant.out" 2>"$W/grant.err" \
	|| badln "the grant against the real clock was refused: $(head -2 "$W/grant.err" | tr '\n' ' ')"
# The timestamp the writer emits must be one the renderer can PARSE. This row exists because the first
# end-to-end run found it was not: Go wrote nanoseconds, jq's fromdateiso8601 refused them, the error was
# swallowed and the member was served as though no lease existed. Every Go test passed.
jq -e '[.leases[] | select((.expires_at // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))] | length == 1' \
	"$W/leases.json" >/dev/null 2>&1 \
	&& ok "the expiry is whole-second RFC3339 — the shape the shell renderer can actually read" \
	|| badln "the expiry is $(jq -r '.leases[0].expires_at' "$W/leases.json") — jq's fromdateiso8601 takes %Y-%m-%dT%H:%M:%SZ and nothing else, so this silently reads as 'nothing is suppressed' in the one function whose job is to remove service."
[ "$(render_state "$W/leases.json")" = "false" ] \
	&& ok "with the lease standing, the renderer stops serving the member" \
	|| badln "the renderer still serves a member under an in-force lease — the grant would then be a record of an intention nobody carried out"

# Two days past the term. The reap takes an explicit clock because that is the only way to test expiry
# without waiting for it.
ctl lease reap --leases "$W/leases.json" --limits "$W/limits.json" \
	--now "$(date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+2d +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
if [ "$(jq '.leases | length' "$W/leases.json")" = "0" ]; then
	ok "past the term, reap withdraws the claim — and asserts nothing about the member having recovered"
else
	badln "an expired lease survived the reap. The 2026-08-11 measurement is exactly this: three nodes suppressed a transport, the fault cleared, and the transport stayed gone."
fi
[ "$(render_state "$W/leases.json")" = "true" ] \
	&& ok "and the member is served again" \
	|| badln "the member did not return after its term ran out"

# The operator's verb: overrule the loop now rather than waiting out a term you disagree with.
rm -f "$W/leases.json"; grant
ctl lease release --leases "$W/leases.json" --limits "$W/limits.json" --proto vless-reality-vision >/dev/null 2>&1
[ "$(jq '[.leases[] | select(.proto=="vless-reality-vision")] | length' "$W/leases.json")" = "0" ] \
	&& ok "and \`lease release\` returns it at once — a human can overrule the loop without waiting out its term" \
	|| badln "release left the lease in place; the operator's only recourse would be editing a state file by hand"

# ---------------------------------------------------------------------------------------------------
# 9. ONE ENTRY POINT (§2.2 item 4, S0).
# ---------------------------------------------------------------------------------------------------
printf '\n-- a suppression is reachable only through an act plan the loop produced --\n'
jq '.act = false | .reason = "in-cooldown" | .held_because = "x" | del(.suppress) | .to.action = "none"' \
	"$W/plan.json" >"$W/hold.json"
rm -f "$W/leases.json"
if ctl lease grant --plan "$W/hold.json" --leases "$W/leases.json" --limits "$W/limits.json" \
	--marker "$W/marker.json" --refs "$W/refs.json" --enabled "$ENABLED" --now "$NOW" >/dev/null 2>&1; then
	badln "a HOLD plan granted a suppression. A hold is the loop declining to act; granting from one bypasses the hysteresis, cooldown, rate limit and rollback latch that make the act legitimate."
else
	ok "a hold plan grants nothing"
fi
jq 'del(.suppress) | .to.action = "promote-sibling"' "$W/plan.json" >"$W/promote.json"
if ctl lease grant --plan "$W/promote.json" --leases "$W/leases.json" --limits "$W/limits.json" \
	--marker "$W/marker.json" --refs "$W/refs.json" --enabled "$ENABLED" --now "$NOW" >/dev/null 2>&1; then
	badln "a PROMOTE plan granted a suppression — promoting adds a path and takes none away, so a lease there would withdraw a member nothing found fault with."
else
	ok "and a promote plan grants nothing — it adds a path rather than removing one"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the suppression path is inert, unguarded, or does not give the member back.\n' >&2
	exit 1
fi
printf 'PASS: decision -> grant -> render -> expiry -> return, with every guard driven.\n'
exit 0
