#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# a_verdict_is_not_a_fault.sh — conformance: a mode whose non-zero return REPORTS something is not
# announced as a bug, and does not claim the node may be half-converged.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   `measure_pathsig_probe` returns non-zero to say a threshold was crossed — after printing a warn that
#   names the class and states that the origin is unknown. Dispatched bare, that return reached the ERR
#   trap, which printed:
#
#       node-bootstrap: error: UNEXPECTED failure (exit 1) at .../node-bootstrap.sh:NNNN
#       node-bootstrap: error: This is a bug, not a refusal — a fail-closed refusal prints a reason.
#       node-bootstrap: error: The node may be PARTLY converged; re-run after the fix.
#
#   Both sentences were false. The reason WAS printed, one line earlier. And nothing was converging — the
#   probe is an observer; it actuates nothing.
#
#   MEASURED on the live network: 21 / 32 / 41 of these blocks per node per day, four lines each, plus a
#   systemd unit reporting FAILURE for an observation it completed successfully. The cost is not the
#   noise: it is that a REAL fault on this path would have been indistinguishable from it, and that an
#   operator reading "may be PARTLY converged" goes looking for damage that does not exist.
#
# WHAT IT CHECKS
#   1. The probe still HAS a verdict to report — a mode that always returns 0 would pass row 2 by having
#      nothing to say, which is the vacuous pass this suite refuses.
#   2. The dispatcher reads that verdict WITHOUT the ERR trap firing. Asserted by driving the real trap
#      against the real dispatch idiom, not by reading the source: the exemption is a bash property
#      (conditions are exempt from ERR), and a gate that greps for `if` would pass a version that greps
#      right and behaves wrong.
#
# OFFLINE. No root, no network, no node. Exit: 0 = a verdict is reported as a verdict; 1 = as a bug.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
LIB="$REPO_ROOT/control/lib/nb_measure.sh"
for f in "$NB" "$LIB"; do
	[ -f "$f" ] || { printf 'a_verdict_is_not_a_fault: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== a mode that reports something is not announced as a bug ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1. THERE IS A VERDICT TO REPORT.
# ---------------------------------------------------------------------------------------------------
body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$LIB")"
if grep -qE 'hit.*-eq 1.*return 1|return 1[[:space:]]*$' <<<"$(awk '/^measure_pathsig_probe\(\)/,/^}/' "$LIB")"; then
	ok "measure_pathsig_probe still returns non-zero when a threshold is crossed"
else
	badln "the probe no longer reports a crossed threshold by its return at all. Row 2 would then pass by having nothing to observe — the vacuous pass this suite refuses. If the verdict moved somewhere else, move this row with it."
fi

# ---------------------------------------------------------------------------------------------------
# 2. THE DISPATCH READS IT WITHOUT THE TRAP FIRING — driven against the real trap.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and the dispatcher reads it without the ERR trap --\n'
DISPATCH="$(awk '/pathsig-probe\)/,/;;/' "$NB" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' | grep -v '^[[:space:]]*$')"
if [ -z "$DISPATCH" ]; then
	badln "could not find the pathsig-probe dispatch arm in $NB"
else
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.vnf.XXXXXX")" || exit 2
	trap 'rm -rf "$W"' EXIT
	# The REAL trap text, driven against the REAL dispatch arm, with the probe standing in for one that
	# crossed its threshold. If the arm lets the return reach the trap, the words appear.
	{
		printf 'set -Eeuo pipefail\n'
		printf '_myc_err_trap() { printf "UNEXPECTED failure\\n" >&2; printf "This is a bug, not a refusal\\n" >&2; printf "The node may be PARTLY converged\\n" >&2; }\n'
		printf 'trap %s ERR\n' "'_myc_err_trap'"
		printf 'log() { printf "log: %%s\\n" "$*"; }\n'
		printf 'warn() { printf "warn: %%s\\n" "$*" >&2; }\n'
		printf 'measure_pathsig_probe() { warn "path-signal: inbound-RST rate on served class(es) x exceeds the threshold. ORIGIN UNKNOWN"; return 1; }\n'
		printf 'MODE=pathsig-probe\n'
		printf 'case "$MODE" in\n'
		printf '%s\n' "$DISPATCH"
		printf 'esac\n'
	} > "$W/drive.sh"
	out="$(bash "$W/drive.sh" 2>&1)"; rc=$?
	if grep -q 'This is a bug' <<<"$out"; then
		badln "the verdict reached the ERR trap: the node announces 'This is a bug, not a refusal' and 'The node may be PARTLY converged' for an observation that already explained itself and converged nothing. Measured at 21-41 blocks per node per day."
	else
		ok "a crossed threshold does not print 'This is a bug' or 'PARTLY converged'"
	fi
	grep -qi 'ORIGIN UNKNOWN' <<<"$out" \
		&& ok "and the observation itself still reaches the operator" \
		|| badln "the warn that explains the verdict is gone — silencing the trap must not silence the finding (out: $(tr -d '\n' <<<"$out" | cut -c1-160))"
	[ "$rc" -eq 0 ] \
		&& ok "and the unit does not report failure for an observation it completed" \
		|| badln "the dispatch still exits non-zero ($rc), so systemd marks the unit failed for a successful observation and unit-state monitoring cannot tell it from a real fault"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a verdict is being reported as a bug.\n' >&2
	exit 1
fi
printf 'PASS: the observation is reported, the trap stays out of it, and the unit stays green.\n'
exit 0
