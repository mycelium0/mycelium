#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# promote_transaction_atomic.sh — conformance: the live-config promote is ATOMIC (no reader can ever
# observe a torn config or a torn rollback target) and SERIALISED (two concurrent promoters cannot leave
# the rollback net pointing at the wrong generation). EXECUTED, not grepped.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   promote_config and rollback_config are the narrowest point of the whole system: they run as root, on a
#   15-minute unattended timer, on every live node, and they are the only thing standing between a bad
#   push and a node nobody can reach to fix. Two defects were found there by audit and fixed in 5f7aee2 —
#   `cp -f` truncating the rollback target in place, and five flows racing one another through the
#   snapshot/replace window — and NOTHING tested either fix. `grep -rn flock tests/conformance/` returned
#   nothing at all.
#
#   That is not an oversight to correct with another text assertion. Text assertions over this exact path
#   have failed in both directions within one week: a guard whose arithmetic a single token disabled kept
#   nine of them green, and a rename that changed no behaviour turned two of them red. So this gate runs
#   the real functions against a real filesystem, through tests/lab/fakenode.sh, and looks at what they
#   actually leave behind — including at every intermediate step, not just at the end.
#
# THE TWO PROPERTIES
#   ATOMICITY is not "the result is correct". It is "no reader could EVER have observed something else".
#   A concurrent sing-box reload, a validate, or the rollback path can read these files at any instant, so
#   the gate asserts the invariant at every point the transaction touches the filesystem: the live config
#   and the rollback target must each always read as one WHOLE generation, and no temp file may ever be
#   observed sitting AT either published path.
#
#   SERIALISATION is checked by outcome, not by the presence of a lock. Two promoters running the real
#   code against one node root have exactly two valid endings — whichever ran second must have snapshotted
#   what the first published. `live=B, lastgood=OLD` is the G1 defect itself: the rollback net skipping a
#   generation. That state is reachable without the lock and is what this row refuses.
#
# WHAT IT DOES NOT DO
#   It does not modify the functions under test. Every assertion here describes CURRENT behaviour, so the
#   gate can be trusted as a baseline before the transaction is touched again — including by the Go port.
#   Where current behaviour is asymmetric it says so in the assertion text rather than quietly passing.
#
# OFFLINE. No root. Nothing outside its own mktemp root (fakenode_init refuses otherwise).
# Exit: 0 = atomic + serialised, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'promote_transaction_atomic: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_update_apply.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
for f in "$LIB" "$FIXTURE"; do
	[ -f "$f" ] || { printf 'promote_transaction_atomic: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }
skip()  { printf '  skip  %s\n' "$1"; }

printf '== promote transaction: atomic writes, serialised promoters (executed) ==\n'

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# THE SHELL FLAGS ARE PART OF THE CONTRACT, and this gate learned it the hard way.
#
# promote_config's fail-closed refusal is a `die` INSIDE the subshell that the flock/atomic work
# introduced. `die` is `exit 1`, and exit inside `( ... )` leaves only that subshell — so whether the
# refusal actually stops the update depends entirely on the CALLER having `set -e`. scripts/node-bootstrap.sh
# does (`set -euo pipefail`), so on a real node the refusal aborts the tick, which is correct. Run the same
# function without it and promote_config returns 0 and logs "promoted candidate to live config" having
# promoted nothing — the caller then restarts onto the unchanged config and verifies it happily.
#
# The first draft of this gate did not set the flags, watched row 3 not refuse, and was about to be read as
# a defect in the code. It is a defect in the harness — but the coupling it exposed is real and undocumented,
# so `run_under_entrypoint_flags` exists to make the faithful context explicit, and a dedicated row below
# pins that the entrypoint still supplies it.
# IN ITS OWN PROCESS, and that detail is the whole point. The obvious spelling —
#     ( set -euo pipefail; promote_config "$c" ) || rc=$?
# — does NOT work: a compound command on the left of `||` has `set -e` suppressed inside it, so that form
# installs the flag and disables it in the same breath. It reported the refusal as a silent success and
# nearly got logged as a code defect. A child process has its own `set -e`, and its exit status can be read
# without suppressing anything.
run_under_entrypoint_flags() {   # promote_fn ARG... -> rc, with `set -euo pipefail` genuinely active
	local rc=0 out
	out="$(bash -c 'set -euo pipefail
		. "$1"; fakenode_attach; . "$2"; shift 2; "$@"' _ "$FIXTURE" "$LIB" "$@" 2>&1)" || rc=$?
	# rc 2 is the fixture refusing to start. Reading that as "the code refused" is how a row testing a
	# fail-closed path passes against a mutant that deleted the refusal — it happened, so it is now loud.
	case "$out" in
		*"fakenode:"*) printf 'HARNESS: %s' "$out"; return 0 ;;
	esac
	printf '%s' "$rc"
}

# ---------------------------------------------------------------------------
# torn_observations — every point at which a reader would have seen a partial file, or a temp file
# occupying a published path. This is the atomicity invariant, evaluated over the whole transaction.
torn_observations() {
	grep -E 'live=torn|lastgood=torn|live=torn-empty|lastgood=torn-empty' "$FAKENODE_WATCH_LOG" 2>/dev/null || true
}
# published_temp — a `.live.*` / `.lastgood.*` name sitting AT the published path rather than beside it.
published_temp() {
	case "$(basename "$(readlink "$SINGBOX_CONFIG" 2>/dev/null || printf '%s' "$SINGBOX_CONFIG")")" in
		.live.*|.lastgood.*) printf 'yes' ;; *) printf 'no' ;;
	esac
}
newcand() { printf '{"generation":"%s","inbounds":[]}\n' "$1" >"$STATE_DIR/cand.$1.json"; printf '%s' "$STATE_DIR/cand.$1.json"; }

# ===========================================================================
# ROW 1 — the ordinary promote.
# ===========================================================================
( set -u
  fail=0
  fakenode_init
  # shellcheck source=/dev/null
  . "$LIB"
  cand="$(newcand NEW)"
  promote_config "$cand"

  [ "$(fakenode_generation "$SINGBOX_CONFIG")" = "NEW" ] \
	  && ok "promote: the live config becomes the candidate" \
	  || badln "promote: live is '$(fakenode_generation "$SINGBOX_CONFIG")', expected NEW"
  [ "$(fakenode_generation "$LASTGOOD_CONFIG")" = "OLD" ] \
	  && ok "promote: the previous live config becomes the rollback target" \
	  || badln "promote: lastgood is '$(fakenode_generation "$LASTGOOD_CONFIG")', expected OLD — the rollback net must hold exactly the generation being replaced"

  t="$(torn_observations)"
  [ -z "$t" ] \
	  && ok "promote: at NO point in the transaction is either file readable as partial (checked at every filesystem touch)" \
	  || badln "promote: a reader could have observed a TORN file. This is the whole point of the atomic write — a half-written live config is read by a concurrent sing-box reload, and a half-written lastgood is the rollback net failing at the moment it is needed. Observations: $(printf '%s' "$t" | tr '\n' '|')"
  [ "$(published_temp)" = "no" ] \
	  && ok "promote: no .live.*/.lastgood.* temp is left occupying a published path" \
	  || badln "promote: a temp file is sitting at the live path"

  # Both publications must be renames. A rename cannot be observed half-done; a copy can.
  grep -q '^mv .*\.lastgood\..* .*config\.lastgood\.json' "$FAKENODE_ARGV_LOG" \
	  && ok "promote: the rollback target is published by rename, not written in place" \
	  || badln "promote: lastgood is not published by a rename — an in-place write is observable half-done, which is exactly the defect 5f7aee2 closed"
  grep -q '^mv .*\.live\..* .*config\.json' "$FAKENODE_ARGV_LOG" \
	  && ok "promote: the live config is published by rename, not written in place" \
	  || badln "promote: the live config is not published by a rename"

  # The mode and ownership the transaction ASKS for, read off the real argv rather than the source.
  grep -q 'install -m 0640 -o root -g sing-box' "$FAKENODE_ARGV_LOG" \
	  && ok "promote: the live config is installed 0640 root:sing-box (it inlines the REALITY key and every client secret)" \
	  || badln "promote: the live config is not installed 0640 root:<group>. It inlines the REALITY private key, every transport password and every client UUID; world-readable is a secret leak to any co-resident principal. argv: $(grep '^install' "$FAKENODE_ARGV_LOG" | head -1)"
  exit "$fail"
) || fail=1

# ===========================================================================
# ROW 2 — no prior live config. There is nothing to snapshot, and inventing a
# rollback target from the candidate would be worse than having none.
# ===========================================================================
( set -u
  fail=0
  fakenode_init --no-live
  # shellcheck source=/dev/null
  . "$LIB"
  promote_config "$(newcand FIRST)"
  [ "$(fakenode_generation "$SINGBOX_CONFIG")" = "FIRST" ] \
	  && ok "first promote (no prior live config): the candidate is promoted" \
	  || badln "first promote: live is '$(fakenode_generation "$SINGBOX_CONFIG")'"
  [ "$(fakenode_generation "$LASTGOOD_CONFIG")" = "absent" ] \
	  && ok "first promote: no rollback target is fabricated (there was no known-good to snapshot)" \
	  || badln "first promote: a rollback target was created out of nothing ('$(fakenode_generation "$LASTGOOD_CONFIG")') — rolling back to a config that was never verified is worse than refusing to roll back"
  exit "$fail"
) || fail=1

# ===========================================================================
# ROW 3 — the snapshot cannot be taken. Refuse, and leave the live config alone.
# A promote without a rollback target is the one thing this path must not do.
# ===========================================================================
( set -u
  fail=0
  fakenode_init
  # shellcheck source=/dev/null
  . "$LIB"
  before="$(fakenode_generation "$SINGBOX_CONFIG")"
  cand="$(newcand NEW)"
  # Fail the ROLLBACK-TARGET temp specifically, and nothing else: the live temp must still be creatable, so
  # the row proves the promote refuses BECAUSE it has no rollback target — not because nothing worked.
  fakenode_fail_tool mktemp '.lastgood.'
  rc="$(run_under_entrypoint_flags promote_config "$cand")"
  after="$(fakenode_generation "$SINGBOX_CONFIG")"
  case "$rc" in
	  HARNESS:*) badln "snapshot-failure row could not run: ${rc#HARNESS: } — the row proves nothing, which is exactly how it passed against a mutant with the refusal removed"; rc=-1 ;;
  esac
  if [ "$rc" -gt 0 ] 2>/dev/null && [ "$after" = "$before" ]; then
	  ok "snapshot fails -> the promote REFUSES and the live config is untouched (fail-closed)"
  else
	  badln "snapshot fails -> rc=$rc, live went '$before' -> '$after'. The promote must refuse: replacing the live config with no rollback target means the next post-apply failure has nothing to restore, on a node reachable only through the config being replaced."
  fi
  t="$(torn_observations)"
  [ -z "$t" ] && ok "snapshot fails: still nothing torn on the failure path" \
	  || badln "snapshot fails: a torn observation on the FAILURE path: $(printf '%s' "$t" | tr '\n' '|')"
  exit "$fail"
) || fail=1

# ===========================================================================
# ROW 4 — SERIALISATION (Audit-0009 G1). Two promoters, one node root.
# ===========================================================================
if ! command -v flock >/dev/null 2>&1; then
	skip "concurrent promote: flock is absent on this host, so the code takes its documented unserialised path — nothing to assert"
else
( set -u
  fail=0
  fakenode_init
  # shellcheck source=/dev/null
  . "$LIB"
  a="$(newcand A)"; b="$(newcand B)"
  ( promote_config "$a" ) >/dev/null 2>&1 &
  p1=$!
  ( promote_config "$b" ) >/dev/null 2>&1 &
  p2=$!
  wait "$p1" 2>/dev/null; wait "$p2" 2>/dev/null
  live="$(fakenode_generation "$SINGBOX_CONFIG")"; lg="$(fakenode_generation "$LASTGOOD_CONFIG")"
  # Serialised, there are exactly two endings: whoever ran second snapshotted what the first published.
  case "$live/$lg" in
	  A/B|B/A)
		  ok "concurrent promote: the rollback target holds the generation actually replaced (live=$live lastgood=$lg)" ;;
	  */OLD)
		  badln "concurrent promote: live=$live but lastgood=OLD — the second promoter snapshotted BEFORE the first published, so the rollback net skips a whole generation and a rollback would restore a config two revisions stale. This is Audit-0009 G1 exactly, and it is what the bounded flock exists to prevent." ;;
	  *)
		  badln "concurrent promote: ended at live=$live lastgood=$lg, which is neither serialised ending (A/B or B/A)" ;;
  esac
  t="$(torn_observations)"
  [ -z "$t" ] && ok "concurrent promote: nothing torn under contention" \
	  || badln "concurrent promote: a torn observation under contention: $(printf '%s' "$t" | tr '\n' '|')"
  exit "$fail"
) || fail=1
fi

# ===========================================================================
# ROW 5 — rollback restores the target, and reports honestly when there is none.
# ===========================================================================
( set -u
  fail=0
  fakenode_init
  # shellcheck source=/dev/null
  . "$LIB"
  promote_config "$(newcand NEW)"            # live=NEW, lastgood=OLD
  rollback_config
  [ "$(fakenode_generation "$SINGBOX_CONFIG")" = "OLD" ] \
	  && ok "rollback: the live config is restored from the rollback target" \
	  || badln "rollback: live is '$(fakenode_generation "$SINGBOX_CONFIG")', expected OLD"
  exit "$fail"
) || fail=1
( set -u
  fail=0
  fakenode_init --no-live
  # shellcheck source=/dev/null
  . "$LIB"
  rollback_config
  [ "$(fakenode_generation "$SINGBOX_CONFIG")" = "absent" ] \
	  && ok "rollback with no target: nothing is invented, the running service is left alone" \
	  || badln "rollback with no target: something was written ('$(fakenode_generation "$SINGBOX_CONFIG")')"
  exit "$fail"
) || fail=1

# ===========================================================================
# ROW 6 — the refusal's INVISIBLE DEPENDENCY.
#
# promote_config refuses by `die` INSIDE a subshell, so `exit 1` leaves only that subshell and the caller
# carries on. What stops the tick is the caller's `set -e`. That works today because scripts/node-bootstrap.sh
# sets `-euo pipefail` and all ten call sites are plain statements — but bash suppresses `set -e` for a
# command on the left of `&&`/`||`, in an `if` condition, and in a `while`/`until` test. So a single
# `promote_config "$c" || warn "..."` anywhere would silently convert a fail-closed refusal into a logged
# lie: the function returns 0, the caller restarts onto the UNCHANGED config, and post-apply verification
# passes because the old config is fine. Nothing else in the tree would notice.
# ===========================================================================
ep_flags="$(grep -m1 '^set -' "$REPO_ROOT/scripts/node-bootstrap.sh" 2>/dev/null || true)"
case "$ep_flags" in
	*e*) ok "the entrypoint still sets -e ($ep_flags) — the in-subshell refusal actually stops a tick" ;;
	*)   badln "scripts/node-bootstrap.sh no longer sets -e ('${ep_flags:-none}'). promote_config's refusal is an \`exit\` inside a subshell: without -e in the caller it returns 0, logs "promoted candidate to live config" having promoted nothing, and the tick restarts onto the unchanged config and verifies it happily." ;;
esac
suppressed="$(grep -rnE '(^|[^_[:alnum:]])promote(_xray)?_config\b[^|&]*(\|\||&&)' \
	--include='*.sh' "$REPO_ROOT/scripts" "$REPO_ROOT/control" 2>/dev/null \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$suppressed" ]; then
	badln "a caller puts promote_config in a set-e-suppressing position (left of &&/||), which turns its fail-closed refusal into a silent success: $(printf '%s' "$suppressed" | tr '\n' '|')"
else
	ok "no caller wraps promote_config in a set-e-suppressing position (plain statement at all call sites)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the promote transaction can be observed torn, or can leave the rollback net pointing at the wrong generation.\n' >&2
	exit 1
fi
printf 'PASS: promote is atomic at every intermediate step, refuses without a rollback target, and serialises concurrent promoters.\n'
exit 0
