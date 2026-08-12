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
		# The call is subshelled so a fail-closed `die` cannot take the harness with it — an earlier
		# draft of this gate lost every row after the first refusal for exactly that reason.
		( apply_suppression_leases "$W/params.json" ) >/dev/null 2>&1
	)
	rc=$?
	printf '%s|%s|%s|%s' "$rc" \
		"$(jq -r --arg k "$KEY" '.[$k]' "$W/params.json" 2>/dev/null)" \
		"$(jq -r --arg k "$OKEY" '.[$k]' "$W/params.json" 2>/dev/null)" \
		"$( [ -f "$W/rotate.leases.json" ] && jq '.leases|length' "$W/rotate.leases.json" 2>/dev/null || printf 'n/a')"
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
	0\|true\|true\|0) ok "an EXPIRED lease returns the member AND is reaped — the restore path, with nothing asserting recovery" ;;
	0\|false\|*) badln "an expired lease still suppresses (got $r). This is the measured defect returning: a transport removed on 2026-08-11 was still gone after the fault cleared, because the loop had no move that gave it back." ;;
	*) badln "expiry handling is wrong (rc|proto|other|remaining = $r); expected 0|true|true|0" ;;
esac

# --- 3. a permanent suppression is refused ---------------------------------------------------------
perm="$(printf '{"version":1,"leases":[{"proto":"%s","direction":"ingress","evidence":"listener-fault","since":"%s","count":1}]}' "$PROTO" "$(iso $((NOW - 60)))")"
r="$(drive "$perm")"
case "$r" in
	7\|*) ok "a lease with NO expiry is refused fail-closed — a permanent suppression is unrepresentable, not merely discouraged" ;;
	*) badln "a lease with no expiry was accepted (got $r). That is a claim nothing ever withdraws — the exact state the lease mechanism exists to remove, reintroduced." ;;
esac

# --- 4. malformed state and unknown members are refused, not guessed at -----------------------------
r="$(drive 'not json at all')"
case "$r" in 7\|*) ok "malformed lease state is refused rather than rendered around" ;;
	*) badln "a malformed lease file did not fail closed (got $r) — the node would render a served set nobody can account for" ;; esac
r="$(drive "$(lease -60 3600 'no-such-proto')")"
case "$r" in 7\|*) ok "a lease naming a proto outside the registry is refused" ;;
	*) badln "a lease for an unknown proto was accepted (got $r); the closed-set anchor is gone" ;; esac

# --- 5. absent file is a no-op ---------------------------------------------------------------------
r="$(drive NONE)"
case "$r" in
	0\|true\|true\|n/a) ok "no lease file is a no-op — a node that has never rotated renders byte-identically" ;;
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

# --- 7. ordering: leases compose AFTER the descriptor ------------------------------------------------
printf '\n-- the loop claim outranks the descriptor, or demote cannot actuate --\n'
body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$PARAMS_LIB")"
np="$(printf '%s' "$body" | grep -n 'apply_node_profile "\$tmp"' | tail -1 | cut -d: -f1)"
sl="$(printf '%s' "$body" | grep -n 'apply_suppression_leases "\$tmp"' | tail -1 | cut -d: -f1)"
if [ -z "$np" ] || [ -z "$sl" ]; then
	badln "could not locate both composition calls in write_params (node_profile=${np:-missing} leases=${sl:-missing}) — this row cannot judge the ordering it exists for"
elif [ "$sl" -gt "$np" ]; then
	ok "suppression leases are applied after apply_node_profile (line $sl > $np)"
else
	badln "leases are applied BEFORE apply_node_profile (line $sl < $np). That function writes \`.[\$k] = true\` for every declared transport and has no branch that writes false, so the claim is silently re-enabled: the demote then validates a byte-identical candidate, the no-op short-circuit fires, and the run logs success for a demote that actuated nothing while spending its rotation budget."
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a suppression can be permanent, silent, or inert.\n' >&2
	exit 1
fi
printf 'PASS: a suppression is bounded, reaped on expiry, published while it stands, and outranks the descriptor.\n'
exit 0
