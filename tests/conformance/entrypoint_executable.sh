#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# entrypoint_executable.sh — conformance: scripts/node-bootstrap.sh MUST stay executable (git mode
# 100755). The autonomous systemd units invoke it DIRECTLY — `ExecStart=$NB_SELF --l7-probe …`
# (control/lib/nb_measure.sh) and `ExecStart=$NB_SELF --rotate --apply-rotation …`
# (control/lib/nb_rotate_apply.sh) — and `git clone` / `merge --ff-only` / a `make dist` tarball all
# PRESERVE the committed file mode. If the bit is lost (as it silently was at 281429b — a history
# rewrite dropped 100755 → 100644, Audit-0007 S1), a FRESH deploy's l7probe + rotate timers fail
# `203/EXEC`, the L7 marker is never written, the daemon fail-safes to "healthy", and the unattended
# self-drive loop this project builds silently never runs — masked by hand-deploys that call
# `bash node-bootstrap.sh …` (bash ignores the exec bit). This gate makes the regression fail the build.
#
# Exit: 0 = executable; 1 = not 100755; 2 = env error.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
cd "$REPO_ROOT" || { printf 'entrypoint_executable: cannot cd to repo root\n' >&2; exit 2; }

command -v git >/dev/null 2>&1 || { printf 'SKIP: git not available.\n'; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { printf 'SKIP: not a git checkout.\n'; exit 0; }

printf '== node-bootstrap.sh entrypoint stays executable in git (100755) ==\n'

fail=0
# The entrypoint the units ExecStart directly, plus its sibling that a caller may invoke similarly.
for f in scripts/node-bootstrap.sh scripts/bootstrap.sh scripts/fungi; do
	[ -e "$f" ] || continue
	mode="$(git ls-files -s -- "$f" 2>/dev/null | awk '{print $1}')"
	[ -n "$mode" ] || { printf '  FAIL  %s is not tracked by git\n' "$f" >&2; fail=1; continue; }
	if [ "$mode" != "100755" ]; then
		printf '  FAIL  %s is git mode %s, want 100755 (a systemd unit ExecStarts it directly; 100644 -> 203/EXEC on a fresh deploy)\n' "$f" "$mode" >&2
		fail=1
	else
		printf '  ok    %s is 100755\n' "$f"
	fi
done

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: an entrypoint lost its executable bit. Fix: git update-index --chmod=+x <path>\n' >&2
	exit 1
fi
printf 'PASS: the node-bootstrap entrypoint(s) are executable (100755) in git.\n'
exit 0
