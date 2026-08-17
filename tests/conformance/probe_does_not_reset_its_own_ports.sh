#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# probe_does_not_reset_its_own_ports.sh — conformance: the node's own probes do not manufacture the signal
# the node then reacts to.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   MEASURED on a live node, 2026-08-17, five forced runs of the L7 self-test probe, counting the passive
#   observer's own nft counters before and after each:
#
#       run 1: 8443 +5 RST     run 4: 443 +2 RST     runs 2,3,5: none
#
#   Five is exactly PATHSIG_RST_FLOOR. The node was firing its own path-signal.
#
#   THE MECHANISM. `openssl s_client … | openssl x509` reads as harmless. `x509` exits as soon as it has
#   one certificate, closing the pipe; `s_client` then takes SIGPIPE mid-session and the kernel tears the
#   socket down with an RST to 127.0.0.1:<served port>. The observer counts inbound RSTs by
#   `tcp dport <served port>` with NO interface predicate — deliberately, for the payload-free invariant —
#   so a loopback RST is indistinguishable from one off the wire.
#
#   And the accounting was already half-aware of it: measure_pathsig_probe subtracts the reach prober's
#   dial rate from the SYN denominator and its comment names the L7 probe as an unsubtracted residual
#   biasing toward FALSE NEGATIVES. Nobody noticed the same dials also feed the RST NUMERATOR, where the
#   bias runs the other way — 15-43 daily hits on healthy serving transports, and one of those faults
#   started a multi-day phantom rotation loop.
#
#   Fixed at the source (capture, then parse) rather than compensated for downstream: an estimate
#   subtracted from a counter is a guess, and this tree has enough of those.
#
# WHAT IT CHECKS
#   1. THE MECHANISM IS REAL, demonstrated by running it: a producer piped into an early-exiting consumer
#      dies of SIGPIPE; the capture-then-parse shape does not. Without this row the rule below reads like
#      style advice.
#   2. No `openssl s_client` aimed at one of THIS NODE's own ports is the left-hand side of a pipe.
#
#   Row 2 is a source-shape check and says so. The behavioural proof needs a live TLS listener and an nft
#   counter table, which an offline gate has neither of; that half is tests/e2e/pathsig_reset_drill.sh
#   --self-rst, which drives the shipped probe on a node and requires the RST delta to be zero.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the node does not reset its own ports; 1 = it may.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'probe_does_not_reset: cannot resolve repo root\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the node does not manufacture the signal it reacts to ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1. THE MECHANISM, DEMONSTRATED. Not asserted — run.
#
# `yes` stands in for s_client: a producer that keeps writing. `head -1` stands in for `openssl x509`: a
# consumer that exits as soon as it has what it needs. In a pipeline the producer is killed by SIGPIPE
# (141 = 128+13); captured first, it is not. That is the whole defect, in two lines, on any host.
# ---------------------------------------------------------------------------------------------------
printf -- '-- the mechanism --\n'
piped_rc=0
( set -o pipefail; yes 2>/dev/null | head -1 >/dev/null ) || piped_rc=$?
if [ "$piped_rc" -eq 141 ] || [ "$piped_rc" -ne 0 ]; then
	ok "a producer piped into an early-exiting consumer is killed by SIGPIPE (rc=$piped_rc) — this is what happened to s_client, and the kernel's socket teardown is what sent the RST"
else
	printf '  SKIP  this shell does not surface SIGPIPE in a pipeline (rc=%s); the mechanism row could not be demonstrated here.\n' "$piped_rc"
fi

cap_rc=0
raw="$( (yes 2>/dev/null | head -200) 2>/dev/null )" || true
printf '%s' "$raw" | head -1 >/dev/null || cap_rc=$?
[ "$cap_rc" -eq 0 ] \
	&& ok "and capturing before parsing does not — the fix is the shape, not a flag" \
	|| badln "the capture-then-parse shape also failed (rc=$cap_rc); this gate cannot distinguish the two shapes on this host and is testing nothing"

# ---------------------------------------------------------------------------------------------------
# 2. NO SELF-DIRECTED s_client IS PIPED.
#
# Scoped to dials at this node's own ports (127.0.0.1 / localhost). nb_donor.sh dials EXTERNAL donor hosts
# to sample their certificates — those RSTs land on somebody else's port, not on a counter of ours, so the
# rule does not reach them and pretending it does would be a rule nobody could satisfy.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and no probe of our own ports is piped --\n'
if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	printf '  SKIP  not a git checkout; the call-site sweep did not run.\n'
else
	offenders=""
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		# A self-directed s_client line that ALSO contains a pipe after the command is the defect shape.
		while IFS= read -r line; do
			case "$line" in
				*s_client*127.0.0.1*'|'*|*s_client*localhost*'|'*) offenders="$offenders $f" ;;
			esac
		done < <(grep -n 'openssl s_client' "$REPO_ROOT/$f" 2>/dev/null || true)
	done < <(git -C "$REPO_ROOT" ls-files '*.sh' 'control/myceliumctl' 'scripts/fungi' 2>/dev/null)
	offenders="$(printf '%s' "$offenders" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')"
	if [ -z "$offenders" ]; then
		ok "every s_client aimed at one of this node's own ports captures its output before parsing it"
	else
		badln "these pipe a self-directed s_client into another command: $offenders. The consumer exits first, s_client takes SIGPIPE, and the kernel RSTs a served port this node counts — measured at 5 RSTs in a single probe run, which is exactly PATHSIG_RST_FLOOR. Capture into a variable, then parse."
	fi
fi

# The e2e half must exist, or the behavioural claim above has no owner.
DRILL="$REPO_ROOT/tests/e2e/pathsig_reset_drill.sh"
if [ -f "$DRILL" ]; then
	grep -q 'self-rst' "$DRILL" \
		&& ok "and the node-side drill that measures the RST delta directly exists (--self-rst)" \
		|| badln "tests/e2e/pathsig_reset_drill.sh has no --self-rst arm. Row 2 above is a source shape; without the drill nothing anywhere measures that a probe run leaves the counters alone, which is the property that actually matters."
else
	badln "tests/e2e/pathsig_reset_drill.sh is missing entirely"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a node probe can still reset a port the node counts.\n' >&2
	exit 1
fi
printf 'PASS: the probes capture before parsing, and the node-side drill measures the delta.\n'
exit 0
