#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotator_pure_planner.sh — conformance: the Phase-2 rotation PLANNER (internal/rotate, RP-0012,
# executing the RP-0010 Plane-3 ADAPT decision) is a PURE, DETERMINISTIC decision that never actuates
# and never consumes a global signal.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The planner decides WHETHER and WHERE to rotate; the apply path is elsewhere. The planner must be
#   pure (so the decision is testable + auditable, and "not yet wired" cannot become "accidentally
#   live"), deterministic (the clock is a parameter, never time.Now), and fed only node-LOCAL signals.
#   An allowlist (not a denylist) is used so a NEW impure import fails by construction. OFFLINE +
#   INSPECT-ONLY.
#
# WHAT THIS CHECKS (over internal/rotate non-test sources)
#   1. The package exists, is flat, and is exactly `package rotate`.
#   2. It imports ONLY the ALLOWLIST {fmt, time, internal/spec} — anything else (net/os/syscall,
#      internal/reach|detect|tune, x/sys, unsafe, …) fails. The planner consumes the OUTPUT types of
#      detect/tune (via internal/spec), never those packages, so the data flow is one-way.
#   3. It contains no determinism/actuation tokens: no `time.Now(`/`time.Since(`, no goroutine launch
#      (`go func`/`go <fn>`), no channel (`chan`).
#   Comments (`//` and multi-line `/* */`) are stripped before any match.
#
# Exit: 0 = pure / deterministic / local-only, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotator_pure_planner: cannot resolve repo root\n' >&2; exit 2; }
ROT_DIR="$REPO_ROOT/internal/rotate"
PKG="rotate"
ALLOWED_RE='^"(fmt|time)"$|^"github\.com/mycelium0/mycelium/internal/spec"$'

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
imports_of() {
	strip_comments "$1" | awk '
		/^[[:space:]]*import[[:space:]]*\(/ { sub(/^[[:space:]]*import[[:space:]]*\(/, ""); inblk = 1 }
		inblk {
			i = index($0, ")")
			if (i > 0) { print substr($0, 1, i - 1); inblk = 0; next }
			print; next
		}
		/^[[:space:]]*import[[:space:]]/ { print }
	' | grep -oE '"[^"]+"'
}

printf '== rotation-planner purity / determinism / local-only check (internal/rotate, RP-0012) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

nontest="$(find "$ROT_DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null)"
if [ -z "$nontest" ]; then
	printf 'FAIL: internal/rotate has no non-test .go source (the planner package is the anchor).\n' >&2
	exit 1
fi
ok "planner package present: internal/rotate"

if [ -n "$(find "$ROT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
	badln "internal/rotate grew a subpackage the purity scan does not cover (recurse the scan or keep it flat)"
fi
pkgs="$(awk '/^package[[:space:]]/ { print $2; exit }' $nontest | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$pkgs" = "$PKG" ]; then
	ok "flat single package: $PKG"
else
	badln "expected exactly 'package $PKG', found: ${pkgs:-<none>}"
fi

imports_spec=0
for f in $nontest; do
	rel="${f#"$REPO_ROOT"/}"
	imps="$(imports_of "$f")"
	bad="$(printf '%s\n' "$imps" | grep -E '^"' | grep -vE "$ALLOWED_RE" || true)"
	if [ -n "$bad" ]; then
		badln "$rel imports a non-allowlisted package (purity/local-only): $(printf '%s' "$bad" | tr '\n' ' ')"
	else
		ok "$rel imports only the allowlist {fmt, time, internal/spec}"
	fi
	if printf '%s\n' "$imps" | grep -qE '"github.com/mycelium0/mycelium/internal/spec"'; then
		imports_spec=1
	fi
	banned="$(strip_comments "$f" | grep -nE 'time\.(Now|Since)\(|(^|[^[:alnum:]_])go[[:space:]]+(func|[A-Za-z])|(^|[^[:alnum:]_])chan[[:space:]]' || true)"
	if [ -n "$banned" ]; then
		badln "$rel uses a forbidden construct (wall-clock read / goroutine / channel): $(printf '%s' "$banned" | tr '\n' '|')"
	else
		ok "$rel reads no wall clock and launches no goroutine/channel (deterministic, no background actuation)"
	fi
	# a dot-import pulls symbols into scope UNPREFIXED, evading the time.Now / allowlist token bans
	if strip_comments "$f" | grep -qE '^[[:space:]]*(import[[:space:]]+)?\.[[:space:]]+"'; then
		badln "$rel uses a dot-import (symbols enter scope unprefixed, evading the determinism token bans)"
	fi
done
if [ "$imports_spec" = "1" ]; then
	ok "the planner consumes internal/spec (the typed Verdict / RotationCandidate / RotationPlan)"
else
	badln "no internal/rotate source imports internal/spec (it must operate on the typed shapes)"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the rotation planner imports only the pure allowlist, reads no clock, runs no goroutine — a deterministic, node-local decision.\n'
	exit 0
fi
printf 'FAIL: the rotation planner grew an impure import, a wall-clock read, or a concurrency surface — see above.\n' >&2
exit 1
