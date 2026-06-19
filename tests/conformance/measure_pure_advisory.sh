#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# measure_pure_advisory.sh — conformance: the Phase-2 MEASURE plane (internal/measure, RP-0010
# Plane 1) WRAPs the existing reach signal into a rotate.PlanInput without adding a measurement
# surface (RP-0010 AC-6) and without actuating (RP-0010 AC-4 / ADR-0025).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The MEASURE plane folds reach's fast-class spec.TransportHealth through the detector and the
#   self-tuner and assembles a rotate.PlanInput. That is the whole adaptivity loop's input seam, so
#   it is exactly where an "advisory" component could quietly grow teeth: open a socket and it has
#   become a NEW probe (AC-6 breach); import the executor / shell out and it has begun to ACTUATE
#   (AC-4 breach); read the wall clock and it stops being a deterministic fold of its inputs. This
#   gate pins all three structurally so "not yet wired" cannot drift into "accidentally live".
#   OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS (over internal/measure non-test sources)
#   1. The package exists, is flat, and is exactly `package measure`.
#   2. It imports ONLY an ALLOWLIST {fmt, sort, time, internal/detect, internal/rotate,
#      internal/spec, internal/tune} — anything else (net/os/os-exec/syscall/io/runtime/context/
#      math-rand, x/sys, unsafe, …) fails. An allowlist (not a denylist) is used so a NEW impure
#      import — a socket, a file, a process — fails by construction.
#   3. It actually WIRES the loop: it consumes internal/detect, internal/tune and internal/spec, and
#      produces internal/rotate's PlanInput. A MEASURE plane that imports none of detect/tune is not
#      folding anything.
#   4. It contains no determinism/actuation tokens: no `time.Now(`/`time.Since(` (the clock is a
#      parameter), no goroutine launch (`go func`/`go <fn>`), no channel (`chan`).
#   Comments (`//` and multi-line `/* */`) are stripped before any match, so a comment can neither
#   add a false hit nor hide a real one.
#
# Exit: 0 = pure / deterministic / advisory-only, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'measure_pure_advisory: cannot resolve repo root\n' >&2; exit 2; }
MEASURE_DIR="$REPO_ROOT/internal/measure"
PKG="measure"
ALLOWED_RE='^"(fmt|sort|time)"$|^"github\.com/mycelium0/mycelium/internal/(detect|rotate|spec|tune)"$'

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# strip_comments FILE — emit the source with // line-comments and /* */ block comments (incl.
# multi-line) removed, so neither a comment hint nor a commented-out import/token affects a match.
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

# imports_of FILE — emit imported package path strings (block, one-line block, and single-line with
# optional alias/dot/underscore), over the comment-stripped source.
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

printf '== MEASURE plane purity / determinism / advisory-only check (internal/measure, RP-0010 AC-6/AC-4) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

nontest="$(find "$MEASURE_DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null)"
if [ -z "$nontest" ]; then
	printf 'FAIL: internal/measure has no non-test .go source (the MEASURE plane is the anchor).\n' >&2
	exit 1
fi
ok "measure package present: internal/measure"

if [ -n "$(find "$MEASURE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
	badln "internal/measure grew a subpackage the purity scan does not cover (recurse the scan or keep it flat)"
fi
pkgs="$(awk '/^package[[:space:]]/ { print $2; exit }' $nontest | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$pkgs" = "$PKG" ]; then
	ok "flat single package: $PKG"
else
	badln "expected exactly 'package $PKG', found: ${pkgs:-<none>}"
fi

imports_detect=0
imports_tune=0
imports_spec=0
imports_rotate=0
for f in $nontest; do
	rel="${f#"$REPO_ROOT"/}"
	imps="$(imports_of "$f")"
	# 2. allowlist — flag any imported path not on the allowlist
	bad="$(printf '%s\n' "$imps" | grep -E '^"' | grep -vE "$ALLOWED_RE" || true)"
	if [ -n "$bad" ]; then
		badln "$rel imports a non-allowlisted package (no probe/IO/actuation surface): $(printf '%s' "$bad" | tr '\n' ' ')"
	else
		ok "$rel imports only the allowlist {fmt, sort, time, internal/detect|rotate|spec|tune}"
	fi
	printf '%s\n' "$imps" | grep -qE '"github.com/mycelium0/mycelium/internal/detect"' && imports_detect=1
	printf '%s\n' "$imps" | grep -qE '"github.com/mycelium0/mycelium/internal/tune"'   && imports_tune=1
	printf '%s\n' "$imps" | grep -qE '"github.com/mycelium0/mycelium/internal/spec"'   && imports_spec=1
	printf '%s\n' "$imps" | grep -qE '"github.com/mycelium0/mycelium/internal/rotate"' && imports_rotate=1
	# 4. determinism / actuation token bans (over comment-stripped source)
	banned="$(strip_comments "$f" | grep -nE 'time\.(Now|Since)\(|(^|[^[:alnum:]_])go[[:space:]]+(func|[A-Za-z])|(^|[^[:alnum:]_])chan[[:space:]]' || true)"
	if [ -n "$banned" ]; then
		badln "$rel uses a forbidden construct (wall-clock read / goroutine / channel): $(printf '%s' "$banned" | tr '\n' '|')"
	else
		ok "$rel reads no wall clock and launches no goroutine/channel (deterministic, no background actuation)"
	fi
	if strip_comments "$f" | grep -qE '^[[:space:]]*(import[[:space:]]+)?\.[[:space:]]+"'; then
		badln "$rel uses a dot-import (symbols enter scope unprefixed, evading the determinism token bans)"
	fi
done

# 3. the loop is actually wired: detect + tune + spec consumed, rotate.PlanInput produced.
[ "$imports_detect" = 1 ] && ok "consumes internal/detect (the connectivity classifier)" || badln "internal/measure does not import internal/detect (it must fold health through the detector)"
[ "$imports_tune"   = 1 ] && ok "consumes internal/tune (the self-tuner weight)"          || badln "internal/measure does not import internal/tune (it must reinforce per-member weights)"
[ "$imports_spec"   = 1 ] && ok "consumes internal/spec (typed TransportHealth/Verdict)"  || badln "internal/measure does not import internal/spec (it must consume the typed reach signal)"
[ "$imports_rotate" = 1 ] && ok "produces internal/rotate.PlanInput (the planner's input)" || badln "internal/measure does not import internal/rotate (it must assemble a rotate.PlanInput)"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the MEASURE plane folds reach->detect->tune->PlanInput with no socket/file/process/clock — advisory input only (AC-6/AC-4).\n'
	exit 0
fi
printf 'FAIL: the MEASURE plane grew a probe/IO/actuation surface or a non-deterministic construct — see above.\n' >&2
exit 1
