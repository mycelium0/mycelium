#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# suppression_lease_bounded.sh — conformance: what the rotation loop takes out of service, it gives back
# — and says so while it is gone.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Measured on three live nodes on 2026-08-11, not imagined. A deliberate loopback-only fault against
#   each node's active transport produced textbook behaviour on the way down — verdict clean -> throttled
#   -> shutdown, impaired_streak to flip_confirmations=3, an unattended rotation applied, the inbound
#   removed, then a correct in-cooldown refusal to rotate again. And then the fault was removed, the
#   verdict returned to clean within a minute, and the transport STAYED SUPPRESSED on all three, with no
#   metric, no alert and no line in any status output. The closed RotationAction set has demote-active
#   and no inverse; revert_rotation_overlay runs only on a FAILED apply. The loop could take service away
#   and had no move that returned it.
#
#   Restoring "when the verdict goes clean" would be worse: internal/measure seeds every registry member
#   ConnStateClean at construction, so a clean verdict for a member the node is NOT SERVING is
#   manufacturable rather than observed (ADR-0039). So the loop never asserts recovery — its write is a
#   LEASE with a term, and expiry is the restore path. Withdrawing your own claim needs no evidence.
#
# WHAT IT CHECKS, by DRIVING the shipped code — never by reading it
#   1. A lease in force suppresses its member and nothing else.
#   2. An EXPIRED lease returns the member AND is reaped. This is the whole fix; if only this row
#      survives, the defect is closed.
#   3. A lease with NO expiry is refused, fail-closed. A permanent suppression is the state the whole
#      mechanism exists to make impossible, and a file that contains one did not come from the writer.
#   4. Malformed state and an unknown proto are refused rather than guessed at.
#   5. An absent lease file is a no-op — every node that has never rotated must render byte-identically.
#   6. The suppression is PUBLISHED: counts, the oldest age, the next expiry, and a per-proto row whose
#      evidence is a closed-vocab integer, with no error text and no address anywhere in the file (§8.5).
#   7. Ordering: leases compose AFTER the node descriptor. apply_node_profile writes `.[$k] = true` for
#      every declared transport and has no branch that writes false, so a claim applied earlier was
#      silently re-enabled — which is why demote-active could not actuate on a node whose descriptor
#      listed the demoted proto, and reported success anyway.
#
# OFFLINE. No root, no network, no node. Exit: 0 = a suppression is bounded and visible; 1 = it is not.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'suppression_lease_bounded: cannot resolve repo root\n' >&2; exit 2; }
PARAMS_LIB="$REPO_ROOT/control/lib/nb_render_params.sh"
OBS_LIB="$REPO_ROOT/control/lib/nb_observability.sh"
VOCAB="$REPO_ROOT/control/vocab.json"
for f in "$PARAMS_LIB" "$OBS_LIB" "$VOCAB"; do
	[ -f "$f" ] || { printf 'suppression_lease_bounded: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf '  SKIP  jq unavailable; nothing here can be driven.\nPASS (skipped)\n'; exit 0; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

NOW="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# A proto that is genuinely in the shipped registry — a fixture that drifts from the registry would test
# a string rather than the closed-set anchor.
PROTO="$(jq -r '[.protos[] | select(.enable_key != null and .enable_key != "") | .proto][0] // empty' "$VOCAB")"
OTHER="$(jq -r '[.protos[] | select(.enable_key != null and .enable_key != "") | .proto][1] // empty' "$VOCAB")"
KEY="$(jq -r --arg p "$PROTO" '.protos[] | select(.proto == $p) | .enable_key' "$VOCAB")"
OKEY="$(jq -r --arg p "$OTHER" '.protos[] | select(.proto == $p) | .enable_key' "$VOCAB")"
if [ -z "$PROTO" ] || [ -z "$OTHER" ] || [ -z "$KEY" ] || [ -z "$OKEY" ]; then
	printf '  FAIL  could not resolve two toggleable protos from control/vocab.json — every row below would test a fixture instead of the registry.\n' >&2
	exit 1
fi

printf '== what the loop takes out of service, it gives back — and says so while it is gone ==\n'
printf 'driving with proto=%s (key=%s), control proto=%s\n\n' "$PROTO" "$KEY" "$OTHER"

# drive <lease-json|NONE> -> "<rc>|<enabled-of-PROTO>|<enabled-of-OTHER>|<leases-remaining>"
drive() {
	local body="$1" W rc
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.lease.XXXXXX")" || return 1
	(
		export REPO_ROOT ARTIFACT_ROOT="$REPO_ROOT" STATE_DIR="$W" DRY_RUN=0
		log() { :; }; warn() { :; }; die() { exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }; run() { "$@"; }
		# shellcheck source=/dev/null
		. "$PARAMS_LIB" >/dev/null 2>&1 || exit 2
		jq -n --arg a "$KEY" --arg b "$OKEY" '{($a): true, ($b): true}' >"$W/params.json"
		[ "$body" = NONE ] || printf '%s\n' "$body" >"$W/rotate.leases.json"
		# `die` is already isolated: drive() runs its whole body in the subshell above, so a fail-closed
		# exit ends that subshell and `rc=$?` catches it. Measured — removing the redundant inner
		# subshell that used to be here changes nothing, 12 rows either way.
		#
		# CORRECTION, recorded rather than quietly dropped: the commit that introduced this gate claimed
		# an earlier draft of it "lost every row after the first refusal". That truncation happened in a
		# throwaway scratch harness used to drive the executor on a node, NOT here. Two harnesses were
		# conflated and the provenance went into a commit message as measured fact. The rule it breaks is
		# this project's own (refactoring.md §2.7): a conclusion is worth what its evidence is worth.
		apply_suppression_leases "$W/params.json" >/dev/null 2>&1
	)
	rc=$?
	printf '%s|%s|%s|%s|%s' "$rc" \
		"$(jq -r --arg k "$KEY" '.[$k]' "$W/params.json" 2>/dev/null)" \
		"$(jq -r --arg k "$OKEY" '.[$k]' "$W/params.json" 2>/dev/null)" \
		"$( [ -f "$W/rotate.leases.json" ] && jq '.leases|length' "$W/rotate.leases.json" 2>/dev/null || printf 'n/a')" \
		"$( [ -f "$W/rotate.leases.json.rejected" ] && printf 'quarantined' || printf 'no' )"
	rm -rf "$W"
}

lease() { # lease <since-offset> <expiry-offset> [proto]
	printf '{"version":1,"leases":[{"proto":"%s","direction":"ingress","evidence":"listener-fault","since":"%s","expires_at":"%s","count":1}]}' \
		"${3:-$PROTO}" "$(iso $((NOW + $1)))" "$(iso $((NOW + $2)))"
}

# --- 1. in force -----------------------------------------------------------------------------------
r="$(drive "$(lease -60 3600)")"
case "$r" in
	0\|false\|true\|*) ok "a lease in force suppresses its member and leaves the others alone" ;;
	*) badln "a lease in force did not suppress cleanly (rc|proto|other|remaining = $r). If the member is still enabled the loop cannot take a broken transport out of service at all." ;;
esac

# --- 2. THE FIX: expiry returns the member and reaps the record ------------------------------------
r="$(drive "$(lease -7200 -60)")"
case "$r" in
	0\|true\|true\|0\|no) ok "an EXPIRED lease returns the member AND is reaped — the restore path, with nothing asserting recovery" ;;
	0\|false\|*) badln "an expired lease still suppresses (got $r). This is the measured defect returning: a transport removed on 2026-08-11 was still gone after the fault cleared, because the loop had no move that gave it back." ;;
	*) badln "expiry handling is wrong (rc|proto|other|remaining = $r); expected 0|true|true|0" ;;
esac

# --- 3. a permanent suppression is refused ---------------------------------------------------------
perm="$(printf '{"version":1,"leases":[{"proto":"%s","direction":"ingress","evidence":"listener-fault","since":"%s","count":1}]}' "$PROTO" "$(iso $((NOW - 60)))")"
r="$(drive "$perm")"
case "$r" in
	0\|true\|true\|*\|quarantined) ok "a lease with NO expiry is refused — the member is served, the file is quarantined, the converge continues" ;;
	*\|false\|*) badln "a lease with no expiry was APPLIED (got $r). That is a claim nothing ever withdraws — the exact state the lease mechanism exists to remove, reintroduced." ;;
	*) badln "a lease with no expiry produced $r; expected the member served and the file quarantined." ;;
esac

# --- 4. a bad file is quarantined, and the converge is NOT wedged -----------------------------------
#
# THIS ROW WAS INVERTED, and the inversion is the point. It used to require rc=7 — `die` — which is the
# fail-closed reflex applied to the wrong subject. A die here stops EVERY converge on the node: the one
# that would repair the file, the unattended update, the next render. Weigh the two failures. Serving a
# member the loop wanted withdrawn offers one possibly-broken transport, and a client's urltest group
# moves off it unaided. Refusing to converge freezes the whole node for everyone, indefinitely, with no
# recovery that does not need a human on the box.
#
# So the guard now quarantines and continues — loudly, leaving the rejected file in place. What must
# never happen is the silent version: applying a claim nobody can account for, or dropping the evidence.
r="$(drive 'not json at all')"
case "$r" in
	0\|true\|true\|*\|quarantined) ok "malformed lease state is quarantined and the render continues with no loop claims" ;;
	7\|*) badln "a malformed lease file still fails the converge (got $r). Every converge on the node then stops, including the one that would fix the file and the unattended update — the failure mode is far worse than the one being guarded against." ;;
	*) badln "a malformed lease file produced $r; expected the members served and the file quarantined" ;;
esac
r="$(drive "$(lease -60 3600 'no-such-proto')")"
case "$r" in 7\|*) ok "a lease naming a proto outside the registry is refused" ;;
	*) badln "a lease for an unknown proto was accepted (got $r); the closed-set anchor is gone" ;; esac

# The ADR-0039 category error, in the artefact rather than on the path: egress-only evidence paired with
# an ingress member. spec.SuppressionLease.Validate refuses to construct it, so a file containing one was
# hand-edited or written by a spine that predates the rule — and the renderer is the last place to catch
# it before a member is withdrawn on a conclusion this node may not draw.
bad_ev="$(printf '{"version":1,"leases":[{"proto":"%s","direction":"ingress","evidence":"egress-unreachable","since":"%s","expires_at":"%s","count":1}]}' "$PROTO" "$(iso $((NOW - 60)))" "$(iso $((NOW + 3600)))")"
r="$(drive "$bad_ev")"
case "$r" in
	0\|true\|true\|*\|quarantined) ok "an ingress member with egress-only evidence is refused at the point of use, not only at the writer" ;;
	*\|false\|*) badln "an ingress member was suppressed on egress-unreachable evidence (got $r) — the node is the client only for an EGRESS member; for an ingress one it cannot tell its own fault from the client's network (ADR-0039)." ;;
	*) badln "the evidence/direction pairing produced $r; expected the member served and the file quarantined" ;;
esac

# --- 5. absent file is a no-op ---------------------------------------------------------------------
r="$(drive NONE)"
case "$r" in
	0\|true\|true\|n/a\|no) ok "no lease file is a no-op — a node that has never rotated renders byte-identically" ;;
	*) badln "an absent lease file changed the render (got $r); every node that has never rotated would drift" ;;
esac

# --- 6. it is PUBLISHED ------------------------------------------------------------------------------
printf '\n-- a suppression is never silent --\n'
W="$(mktemp -d "${TMPDIR:-/tmp}/myc.leaseprom.XXXXXX")"
(
	export STATE_DIR="$W" NODE_EXPORTER_TEXTFILE_DIR="$W"
	log() { :; }; warn() { :; }; die() { exit 1; }
	have() { command -v "$1" >/dev/null 2>&1; }; run() { "$@"; }
	# shellcheck source=/dev/null
	. "$OBS_LIB" >/dev/null 2>&1 || exit 2
	STATE_DIR="$W"; NODE_EXPORTER_TEXTFILE_DIR="$W"
	printf '%s\n' "$(printf '{"version":1,"leases":[{"proto":"%s","direction":"ingress","evidence":"listener-fault","since":"%s","expires_at":"%s","count":2}]}' "$PROTO" "$(iso $((NOW - 7200)))" "$(iso $((NOW + 1800)))")" >"$W/rotate.leases.json"
	publish_suppression_leases
) >/dev/null 2>&1
PROM="$W/mycelium_suppression.prom"
if [ ! -f "$PROM" ]; then
	badln "publish_suppression_leases wrote no metric file — a suppression that nothing publishes is the 2026-08-11 state exactly"
else
	v() { sed -n "s/^$1 //p" "$PROM" | head -1; }
	[ "$(v mycelium_rotate_suppressed_transports)" = "1" ] \
		&& ok "the count of suppressed transports is published" \
		|| badln "suppressed-transport count is '$(v mycelium_rotate_suppressed_transports)', expected 1 — an operator cannot alert on what is not emitted"
	[ "$(v mycelium_rotate_suppression_oldest_age_seconds)" -ge 7000 ] 2>/dev/null \
		&& ok "and how long the oldest has stood (the signal that a claim has outlived its fault)" \
		|| badln "oldest-age is '$(v mycelium_rotate_suppression_oldest_age_seconds)'; without it a stuck lease is indistinguishable from a fresh one"
	[ "$(v mycelium_rotate_suppression_next_expiry_seconds)" -gt 0 ] 2>/dev/null \
		&& ok "and when the next one lapses, so the operator knows whether to wait or act" \
		|| badln "next-expiry is '$(v mycelium_rotate_suppression_next_expiry_seconds)'"
	grep -q "^mycelium_rotate_suppressed{proto=\"$PROTO\",evidence=\"1\"}" "$PROM" \
		&& ok "with a per-proto row whose evidence is a closed-vocab integer, not a string" \
		|| badln "no per-proto row for $PROTO with an integer evidence code — the operator cannot tell a listener fault from a render refusal"
	if grep -qiE 'error|failed|https?://|([0-9]{1,3}\.){3}[0-9]{1,3}' "$PROM"; then
		badln "the metric file carries error text or an address. node_exporter reads it (§8.5), and an error string can carry a path, a ref or a hostname."
	else
		ok "and no error text and no address anywhere in it (§8.5)"
	fi
fi
rm -rf "$W"

# --- 6b. IT IS PUBLISHED ON EVERY CONVERGE, not only after an unattended update -----------------
#
# The publish call first lived in record_converge_ok, which is reached ONLY from flow_update. Measured
# on a live node: `fungi apply` completed rc=0 and mycelium_update.prom was never touched — so a node
# converged by deploy or apply, which is every node before its first unattended update, published the
# series never. The CHANGELOG said "on every converge"; the apply path was not one of them.
#
# So the call belongs to converge_node_tail, the shared tail EVERY converge path runs. This row asserts
# that, and that it is not ALSO in record_converge_ok — two callers would be two owners of one fact.
printf '\n-- the publish is on the converge path, and on exactly one of them --\n'
tail_body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$PARAMS_LIB" | awk '/^converge_node_tail\(\)/,/^}/')"
obs_lib="$REPO_ROOT/control/lib/nb_observability.sh"
obs_rc="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$obs_lib" | awk '/^record_converge_ok\(\)/,/^}/')"

grep -q 'publish_suppression_leases' <<<"$tail_body" \
	&& ok "converge_node_tail publishes the suppression state — the tail every converge path runs" \
	|| badln "converge_node_tail does not publish. If the call sits in record_converge_ok instead, it is reached only from flow_update, and a node converged by deploy or apply never emits the series — measured exactly that on a live node."
grep -q 'publish_suppression_leases' <<<"$obs_rc" \
	&& badln "record_converge_ok publishes too. Two callers for one fact is two owners (§2.2 item 8) — and the update path would emit a second, differently-timed sample of the same state." \
	|| ok "and record_converge_ok does not — one fact, one place that knows it"

# --- 7. THE COMPOSITION, DRIVEN: a suppressed member STAYS suppressed ------------------------------
#
# THIS ROW WAS A PIN, and this is the commit that inverts it. It used to compare SOURCE LINE NUMBERS of
# three function calls — and so it certified the composition fix while the defect was live. Audit-0012 B2
# named it: the layer moved after apply_node_profile was the lease layer, which nothing populated; what
# actually removed service was persist_rotation_to_overlay writing an expiry-free `<proto>_enabled:false`
# into the OPERATOR overlay, merged BEFORE apply_node_profile writes `.[k] = true` unconditionally.
#
# Now there is a writer, so the assertion can be the behaviour: run the three composition steps in the
# order write_params runs them, over a node descriptor that DECLARES the suppressed proto — the exact
# shape where the old ordering silently re-enabled it — and require the member to still be off at the end.
printf '\n-- the composition, end to end --\n'

compose() { # compose <lease-json|NONE> -> "<rc>|<enabled-of-PROTO>|<enabled-of-OTHER>"
	local body="$1" W rc
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.compose.XXXXXX")" || return 1
	(
		export REPO_ROOT ARTIFACT_ROOT="$REPO_ROOT" STATE_DIR="$W" DRY_RUN=0
		log() { :; }; warn() { :; }; die() { exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }; run() { "$@"; }
		# shellcheck source=/dev/null
		. "$PARAMS_LIB" >/dev/null 2>&1 || exit 2
		OPERATOR_OVERRIDES="$W/overrides.json"
		jq -n --arg a "$KEY" --arg b "$OKEY" '{($a): false, ($b): false}' >"$W/params.json"
		printf '{}\n' >"$W/overrides.json"
		# The descriptor DECLARES both protos — the shape in which apply_node_profile's unconditional
		# `.[k] = true` used to undo the loop's claim.
		jq -n --arg a "$PROTO" --arg b "$OTHER" '{transports: [$a, $b]}' >"$W/node.config.json"
		[ "$body" = NONE ] || printf '%s\n' "$body" >"$W/rotate.leases.json"
		merge_operator_overrides "$W/params.json" >/dev/null 2>&1
		apply_node_profile "$W/params.json"        >/dev/null 2>&1
		apply_suppression_leases "$W/params.json"  >/dev/null 2>&1
	)
	rc=$?
	# `.[$k] // "absent"` would be wrong here and wrong in the one way that matters: jq's // yields the
	# right-hand side for FALSE as well as null, so a correctly-suppressed member reads as "absent".
	printf '%s|%s|%s' "$rc" \
		"$(jq -r --arg k "$KEY" 'if has($k) then .[$k] else "absent" end' "$W/params.json" 2>/dev/null)" \
		"$(jq -r --arg k "$OKEY" 'if has($k) then .[$k] else "absent" end' "$W/params.json" 2>/dev/null)"
	rm -rf "$W"
}

base="$(compose NONE)"
case "$base" in
	*\|true\|true) ok "with no lease, the descriptor enables both protos (the baseline the claim must beat)" ;;
	*) printf '  SKIP  the descriptor did not enable both protos in this harness (got %s); the ordering row below is inconclusive rather than green.\n' "$base" ;;
esac
r="$(compose "$(lease -60 3600)")"
case "$r" in
	0\|false\|true) ok "and a lease in force SURVIVES the descriptor: $PROTO stays out of service, $OTHER keeps serving" ;;
	0\|true\|*) badln "the descriptor re-enabled the suppressed member (got $r). apply_node_profile writes \`.[\$k] = true\` for every declared transport and has no branch that writes false, so a claim applied before it is silently undone — which is how demote-active came to actuate nothing and report success." ;;
	*) badln "the composition produced $r; expected 0|false|true" ;;
esac

# AND THE WRITER EXISTS. The pin above was self-inverting: it went red the moment a writer appeared,
# which is what brought this row into being. Keep asserting it, so the wiring cannot quietly come out
# again — a lease layer with no producer is a mechanism that reads as working and does nothing.
writers="$(grep -rln '\.Grant(' "$REPO_ROOT"/cmd "$REPO_ROOT"/internal 2>/dev/null \
	| grep -v '_test\.go$' | grep -v '/spec/lease\.go$' | head -3)"
callers="$(grep -rln 'lease grant' "$REPO_ROOT"/control "$REPO_ROOT"/scripts 2>/dev/null | head -2)"
[ -n "$writers" ] \
	&& ok "a non-test caller of spec.LeaseSet.Grant exists ($(printf '%s' "$writers" | tr '\n' ' '))" \
	|| badln "nothing calls spec.LeaseSet.Grant outside its own package and tests. The lease layer would then remove no service at all, and every surface describing it would be describing a mechanism with no producer."
[ -n "$callers" ] \
	&& ok "and the shell executor drives it ($(printf '%s' "$callers" | tr '\n' ' '))" \
	|| badln "no shell path invokes \`lease grant\`. The Go verb existing is not the same as the loop reaching it — the executor would still be writing the operator overlay, which is the unbounded write this replaces."

# ONE SUPPRESSION PATH, not two (§2.2 item 4, S0), ESTABLISHED BY RUNNING THE EXECUTOR.
#
# The overlay write may still ENABLE a promoted sibling — additive, it takes nothing from anyone — but it
# must no longer be how a member is WITHDRAWN, or the loop has two ways to remove service and only one of
# them expires. An earlier draft of this row grepped a few lines around the call and asked whether
# `_suppress` appeared nearby, which is the source-text assertion this project keeps catching itself
# making: it passes on code that reads right and says nothing about which branch runs.
#
# So: source the real library, stub every helper to record that it was called, and run rotate_apply_live
# over two real plans. What is asserted is the TRACE.
printf '\n-- which write path the executor actually takes --\n'
APPLY_LIB="$REPO_ROOT/control/lib/nb_rotate_apply.sh"
if [ ! -f "$APPLY_LIB" ]; then
	badln "control/lib/nb_rotate_apply.sh is missing; the executor cannot be driven"
else
trace_apply() { # trace_apply <plan-json> -> the space-joined call trace
	local plan_body="$1" W
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.exec.XXXXXX")" || return 1
	printf '%s\n' "$plan_body" >"$W/plan.json"
	(
		export STATE_DIR="$W" DRY_RUN=0 TRACE="$W/trace"
		PARAMS_JSON="$W/params.json"; SINGBOX_CONFIG="$W/config.json"
		printf '{}\n' >"$PARAMS_JSON"
		log() { :; }; warn() { :; }; die() { printf 'die ' >>"$TRACE"; exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }; run() { "$@"; }
		# shellcheck source=/dev/null
		. "$APPLY_LIB" >/dev/null 2>&1 || exit 2
		# Every helper the live path reaches, stubbed to record itself. The two that matter are
		# rotate_lease_grant and persist_rotation_to_overlay; the rest exist so the function can run.
		apply_rotation_to_params() { :; }
		render_candidate() { printf '{}\n' >"$1"; }
		validate_config() { return 0; }
		persist_rotation_state_preapply() { :; }
		persist_rotation_state() { :; }
		update_measure_active_ref() { :; }
		write_params() { :; }
		promote_config() { :; }
		install_singbox_unit() { :; }
		apply_singbox() { return 0; }
		verify_post_apply() { return 0; }
		converge_node_tail() { :; }
		rotate_lease_grant() { printf 'lease_grant ' >>"$TRACE"; return 0; }
		rotate_lease_release() { printf 'lease_release ' >>"$TRACE"; return 0; }
		persist_rotation_to_overlay() { printf 'overlay ' >>"$TRACE"; }
		revert_rotation_overlay() { printf 'revert_overlay ' >>"$TRACE"; }
		rotate_apply_live "$W/plan.json" >/dev/null 2>&1
	)
	cat "$W/trace" 2>/dev/null
	rm -rf "$W"
}

mkplan() { # mkplan <action> <with-suppress:yes|no>
	local action="$1" sup="$2"
	jq -nc --arg a "$action" --arg p "$PROTO" --arg o "$OTHER" --argjson s "$( [ "$sup" = yes ] && printf 'true' || printf 'false' )" '
		{act:true, reason:"degraded-active",
		 from:{proto:$p, class:"reality-tcp", action:"none", from_port:0, to_port:0, promoted:true, weight:0.2},
		 to:{proto:(if $a == "demote-active" then $p else $o end), class:"reality-tcp", action:$a,
		     from_port:0, to_port:0, promoted:true, weight:0.9},
		 next_state:{}, decided_at:"2026-01-01T00:00:00Z"}
		| if $s then .suppress = {proto:$p, direction:"ingress", evidence:"listener-fault"} else . end'
}

t_dem="$(trace_apply "$(mkplan demote-active yes)")"
case "$t_dem" in
	*lease_grant*) : ;;
	*) badln "a demote plan carrying .suppress never reached rotate_lease_grant (trace: '${t_dem:-<empty>}'). The withdrawal would then be written by whatever else runs, without a term." ;;
esac
case "$t_dem" in
	*overlay*) badln "a demote plan ALSO wrote the operator overlay (trace: '$t_dem'). Two write paths for one suppression is the state §2.2 item 4 forbids, and only one of them expires — the overlay entry outlives the lease and the member never comes back." ;;
	*lease_grant*) ok "a demote goes through the lease writer and does NOT touch the operator overlay (trace: $t_dem)" ;;
esac

t_pro="$(trace_apply "$(mkplan promote-sibling no)")"
case "$t_pro" in
	*lease_grant*) badln "a PROMOTE plan granted a suppression lease (trace: '$t_pro'). Promoting adds a path and takes none away; a lease there would withdraw a member nothing found fault with." ;;
	*overlay*) ok "and a promote still persists its enable through the overlay, where a durable operator-visible enable belongs (trace: $t_pro)" ;;
	*) badln "a promote plan took neither path (trace: '${t_pro:-<empty>}') — the rotation would report success having persisted nothing." ;;
esac
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a suppression can be permanent, silent, or inert.\n' >&2
	exit 1
fi
printf 'PASS: a suppression is bounded, reaped on expiry, published while it stands, and outranks the descriptor.\n'
exit 0
