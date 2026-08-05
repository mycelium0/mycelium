#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# run.sh — the netsim driver (development.md §7.3, §7.5).
# Author: mindicator & silicon bags quartet.
#
# DELIBERATELY NOT IN tests/run.sh. The offline suite must stay runnable by anyone on any host; these
# scenarios need Linux, root, network namespaces, tc and iptables. §7.5 is explicit that socket- and
# netem-bound suites are run in a developer/node environment and their result RECORDED in the RP report —
# not treated as failed because a sandbox forbids them, and equally not silently skipped so that a green
# offline suite implies coverage that never ran.
#
# Every scenario is self-contained: it builds its own isolated namespace pair, asserts the isolation
# before impairing anything, and tears it down on every exit path. Nothing here can reach a real client.
#
# USAGE (on a node):
#   sudo bash tests/netsim/run.sh              # all scenarios
#   sudo bash tests/netsim/run.sh hop_range    # substring filter
#
# Exit: 0 = every selected scenario passed; 1 = one or more failed; 2 = the environment refused.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

printf '== netsim: network-condition scenarios (development.md §7.3) ==\n'

if [ "$(uname -s)" != "Linux" ]; then
	printf 'REFUSED: Linux only (this host is %s).\n' "$(uname -s)" >&2
	printf '  These scenarios build network namespaces and drive tc/iptables. Run them on a node and\n' >&2
	printf '  record the result in the RP report (§7.5). They are not part of the offline suite.\n' >&2
	exit 2
fi
if [ "$(id -u)" != "0" ]; then
	printf 'REFUSED: root required (network namespaces + tc + iptables).\n' >&2
	exit 2
fi

pass=0
fail=0
skipped=0
failed_names=""

for s in "$HERE"/scenarios/*.sh; do
	[ -f "$s" ] || continue
	name="$(basename "$s" .sh)"
	if [ -n "$FILTER" ]; then
		case "$name" in *"$FILTER"*) ;; *) continue ;; esac
	fi
	printf '\n--- %s ---\n' "$name"
	bash "$s"
	rc=$?
	case "$rc" in
		0) pass=$((pass + 1)) ;;
		2) skipped=$((skipped + 1)); printf '  (environment refused — NOT a pass)\n' ;;
		*) fail=$((fail + 1)); failed_names="$failed_names $name" ;;
	esac
done

printf '\n== summary ==\n'
printf '  passed: %d   failed: %d   refused: %d\n' "$pass" "$fail" "$skipped"
if [ "$fail" -ne 0 ]; then
	printf '\nNETSIM FAILED:%s\n' "$failed_names" >&2
	exit 1
fi
if [ "$pass" -eq 0 ]; then
	printf '\nNo scenario ran. That is not a pass — check the filter and the environment.\n' >&2
	exit 2
fi
printf '\nnetsim: all selected scenarios passed.\n'
exit 0
