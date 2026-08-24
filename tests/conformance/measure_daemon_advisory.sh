#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# measure_daemon_advisory.sh — conformance: the daemon seat that hosts the RP-0010 MEASURE plane
# (cmd/myceliumd) ASSEMBLES + SERVES a rotate.PlanInput but never ACTUATES a rotation (RP-0010 AC-4).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   myceliumd is the long-lived node process that folds the reach snapshot through internal/measure
#   and writes the rotate.PlanInput the GATED rotation loop (RP-0012) consumes. It is the actuation-
#   ADJACENT seat: the moment it spawns a process, invokes the engine, or calls the rotation executor
#   it has stopped being advisory and started to ACT — bypassing the RP-0012 triple gate (dry-run +
#   --apply-rotation + DRY_RUN=0 + the node-local arm sentinel). Unlike the pure planes, the daemon is
#   legitimately impure (it reads/writes files and serves loopback HTTP), so this is a DENYLIST, not an
#   allowlist: it bans only the actuation surfaces. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS (over cmd/myceliumd non-test sources)
#   1. No process-spawn or engine-invocation surface: no os/exec or plugin import, and no exec.Command
#      / os.StartProcess / syscall.{Exec,ForkExec,StartProcess} / plugin.Open / sing-box token — the
#      daemon never runs the engine, loads a plugin, or spawns a shell. (FILE-LOCAL grep; see the 1/1b
#      notes — a fully transitive check would need a Go import-graph gate.)
#   1b. No import of the planner or an actuation/executor package: the daemon reaches the PlanInput TYPE
#      opaquely via internal/measure, so it cannot itself decide or apply a rotation.
#   2. It WIRES the MEASURE plane: it imports internal/measure and internal/reach (it folds the reach
#      snapshot through the assembler).
#   Comments are stripped before any match so a comment can neither add a false hit nor hide a real one.
#
# Exit: 0 = advisory-only (assembles + serves, never actuates), 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'measure_daemon_advisory: cannot resolve repo root\n' >&2; exit 2; }
DIR="$REPO_ROOT/cmd/myceliumd"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

strip_comments() {
	awk '
		{
			line = $0; out = ""
			while (length(line) > 0) {
				if (incmt) {
					e = index(line, "*/"); if (e == 0) { line = ""; break }
					line = substr(line, e + 2); incmt = 0; continue
				}
				s = index(line, "/*"); d = index(line, "//")
				if (d > 0 && (s == 0 || d < s)) { out = out substr(line, 1, d - 1); line = ""; break }
				if (s > 0) { out = out substr(line, 1, s - 1); line = substr(line, s + 2); incmt = 1; continue }
				out = out line; line = ""
			}
			print out
		}
	' "$1"
}

printf '== MEASURE daemon advisory-only check (cmd/myceliumd, RP-0010 AC-4) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

nontest="$(find "$DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null)"
if [ -z "$nontest" ]; then
	printf 'FAIL: cmd/myceliumd has no non-test .go source.\n' >&2
	exit 1
fi
ok "daemon package present: cmd/myceliumd"

imports_measure=0
imports_reach=0
for f in $nontest; do
	rel="${f#"$REPO_ROOT"/}"
	src="$(strip_comments "$f")"
	# 1. actuation-surface denylist: process spawning (every Go spawn primitive, not just os/exec) /
	#    plugin loading / engine invocation. NOTE: this is a FILE-LOCAL grep over cmd/myceliumd/*.go; it
	#    cannot see actuation reached transitively through an imported package — check 1b denylists the
	#    obvious import paths, but a Go-based import-graph gate would be needed to pin that fully.
	banned="$(printf '%s\n' "$src" | grep -nE '"os/exec"|"plugin"|(^|[^[:alnum:]_.])exec\.Command|(^|[^[:alnum:]_.])os\.StartProcess|syscall\.(Exec|ForkExec|StartProcess)|(^|[^[:alnum:]_.])plugin\.Open|sing-?box' || true)"
	if [ -n "$banned" ]; then
		badln "$rel has an actuation surface (process spawn / plugin / engine invocation): $(printf '%s' "$banned" | tr '\n' '|')"
	else
		ok "$rel spawns no process and invokes no engine (advisory: assembles + serves only)"
	fi
	# 1b. import denylist: the daemon must reach the PlanInput TYPE opaquely (via internal/measure), not
	#     import the planner or any actuation/executor package — so it cannot decide or apply a rotation.
	badimp="$(printf '%s\n' "$src" | grep -nE '"github.com/mycelium0/mycelium/internal/(rotate|[a-z]*(exec|actuat|promote|apply)[a-z]*)"' || true)"
	if [ -n "$badimp" ]; then
		badln "$rel imports the planner / an actuation package (it must get PlanInput opaquely from internal/measure): $(printf '%s' "$badimp" | tr '\n' '|')"
	else
		ok "$rel does not import the planner or any actuation/executor package"
	fi
	printf '%s\n' "$src" | grep -qE '"github.com/mycelium0/mycelium/internal/measure"' && imports_measure=1
	printf '%s\n' "$src" | grep -qE '"github.com/mycelium0/mycelium/internal/reach"'   && imports_reach=1
done

# 2. the MEASURE wiring is actually present.
[ "$imports_measure" = 1 ] && ok "consumes internal/measure (the MEASURE assembler)" || badln "cmd/myceliumd does not import internal/measure (the plane is not wired)"
[ "$imports_reach"   = 1 ] && ok "consumes internal/reach (the snapshot the plane folds)" || badln "cmd/myceliumd does not import internal/reach (no snapshot to fold)"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the daemon folds reach->measure into a PlanInput and serves it — no process spawn, no engine, no rotation actuation (AC-4).\n'
	exit 0
fi
printf 'FAIL: the daemon grew an actuation surface or lost the MEASURE wiring — see above.\n' >&2
exit 1
