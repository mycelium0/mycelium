#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# tuner_pure_advisory.sh — conformance: the Phase-2 self-tuner (internal/tune, RP-0010 Plane 3) is a
# PURE, DETERMINISTIC scoring layer that never actuates (RP-0010 AC-4 / ADR-0025).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The self-tuner maintains a per-(class,path) weight (the Physarum reinforce-and-evaporate law on
#   spec.DecayPolicy). That weight is a RANKING INPUT only: it must never auto-ban, force-route, hard-
#   trust, rotate, probe, or read the wall clock (time is a parameter, never `time.Now`). The package
#   doc promises purity + determinism + no goroutines; this gate pins those promises structurally so
#   "not yet wired" cannot drift into "accidentally live". OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS (over internal/tune non-test sources)
#   1. The package exists, is flat, and is exactly `package tune`.
#   2. It imports ONLY an ALLOWLIST {fmt, math, time, internal/spec} — anything else (net/os/syscall,
#      x/sys, unsafe, io, runtime, sync, context, math/rand, internal/reach|detect, …) fails. An
#      allowlist (not a denylist) is used so a NEW impure import fails by construction.
#   3. It contains no determinism/actuation tokens: no `time.Now(`/`time.Since(` (the clock is a
#      parameter), no goroutine launch (`go func`/`go <fn>`), no channel (`chan`).
#   Comments (`//` and multi-line `/* */`) are stripped before any match, so a comment can neither
#   add a false hit nor hide a real one.
#
# Exit: 0 = pure / deterministic / advisory-only, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'tuner_pure_advisory: cannot resolve repo root\n' >&2; exit 2; }
TUNE_DIR="$REPO_ROOT/internal/tune"
PKG="tune"
ALLOWED_RE='^"(fmt|math|time)"$|^"github\.com/mycelium0/mycelium/internal/spec"$'

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

printf '== self-tuner purity / determinism / advisory-only check (internal/tune, RP-0010 AC-4) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

nontest="$(find "$TUNE_DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null)"
if [ -z "$nontest" ]; then
	printf 'FAIL: internal/tune has no non-test .go source (the tuner package is the anchor).\n' >&2
	exit 1
fi
ok "tuner package present: internal/tune"

if [ -n "$(find "$TUNE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
	badln "internal/tune grew a subpackage the purity scan does not cover (recurse the scan or keep it flat)"
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
	# 2. allowlist — flag any imported path not on the allowlist
	bad="$(printf '%s\n' "$imps" | grep -E '^"' | grep -vE "$ALLOWED_RE" || true)"
	if [ -n "$bad" ]; then
		badln "$rel imports a non-allowlisted package (purity/advisory-only): $(printf '%s' "$bad" | tr '\n' ' ')"
	else
		ok "$rel imports only the allowlist {fmt, math, time, internal/spec}"
	fi
	if printf '%s\n' "$imps" | grep -qE '"github.com/mycelium0/mycelium/internal/spec"'; then
		imports_spec=1
	fi
	# 3. determinism / actuation token bans (over comment-stripped source)
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
if [ "$imports_spec" = "1" ]; then
	ok "the tuner consumes internal/spec (the typed Verdict + DecayPolicy)"
else
	badln "no internal/tune source imports internal/spec (it must score the typed spec.Verdict)"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the self-tuner imports only the pure allowlist, reads no clock, runs no goroutine — a deterministic ranking input only (AC-4).\n'
	exit 0
fi
printf 'FAIL: the self-tuner grew an impure import, a wall-clock read, or a concurrency/actuation surface — see above.\n' >&2
exit 1
