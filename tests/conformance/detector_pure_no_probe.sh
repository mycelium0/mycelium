#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# detector_pure_no_probe.sh — conformance: the Phase-2 classifier (internal/detect, RP-0010 Plane 2)
# is PURE and DETERMINISTIC and adds NO new probing surface (RP-0010 AC-6).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   Detection must be fed from the WRAP'd internal/reach signal only; it adds no new active-probe
#   fingerprint (AC-6) and does not actuate. The cleanest structural guarantee is that the classifier
#   package imports only a small pure ALLOWLIST and reads no wall clock and starts no goroutine — it
#   classifies the spec.DetectorSignal it is handed. An allowlist (not a denylist) is used so a NEW
#   impure import (net/os/syscall, x/sys, unsafe, io, runtime, internal/reach, …) fails by
#   construction. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS (over internal/detect non-test sources)
#   1. The package exists, is flat, and is exactly `package detect`.
#   2. It imports ONLY the ALLOWLIST {fmt, internal/spec} — anything else fails.
#   3. It contains no determinism/actuation tokens: no `time.Now(`/`time.Since(`, no goroutine launch
#      (`go func`/`go <fn>`), no channel (`chan`).
#   Comments (`//` and multi-line `/* */`) are stripped before any match.
#
# Exit: 0 = pure / no new probe surface, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'detector_pure_no_probe: cannot resolve repo root\n' >&2; exit 2; }
DETECT_DIR="$REPO_ROOT/internal/detect"
PKG="detect"
ALLOWED_RE='^"fmt"$|^"github\.com/mindicator/mycelium/internal/spec"$'

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# strip_comments FILE — drop // and multi-line /* */ comments so neither hides nor adds a match.
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

# imports_of FILE — imported package path strings (block, one-line block, single-line w/ optional
# alias), over the comment-stripped source.
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

printf '== detector purity / determinism / no-new-probe-surface check (internal/detect, RP-0010 AC-6) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

nontest="$(find "$DETECT_DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null)"
if [ -z "$nontest" ]; then
	printf 'FAIL: internal/detect has no non-test .go source (the classifier package is the anchor).\n' >&2
	exit 1
fi
ok "classifier package present: internal/detect"

if [ -n "$(find "$DETECT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
	badln "internal/detect grew a subpackage the purity scan does not cover (recurse the scan or keep it flat)"
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
		badln "$rel imports a non-allowlisted package (no probe/I/O/reach in the classifier): $(printf '%s' "$bad" | tr '\n' ' ')"
	else
		ok "$rel imports only the allowlist {fmt, internal/spec}"
	fi
	if printf '%s\n' "$imps" | grep -qE '"github.com/mindicator/mycelium/internal/spec"'; then
		imports_spec=1
	fi
	banned="$(strip_comments "$f" | grep -nE 'time\.(Now|Since)\(|(^|[^[:alnum:]_])go[[:space:]]+(func|[A-Za-z])|(^|[^[:alnum:]_])chan[[:space:]]' || true)"
	if [ -n "$banned" ]; then
		badln "$rel uses a forbidden construct (wall-clock read / goroutine / channel): $(printf '%s' "$banned" | tr '\n' '|')"
	else
		ok "$rel reads no wall clock and launches no goroutine/channel (deterministic, no new probe surface)"
	fi
done
if [ "$imports_spec" = "1" ]; then
	ok "the classifier consumes internal/spec (the typed DetectorSignal/Verdict)"
else
	badln "no internal/detect source imports internal/spec (it must consume the typed signal)"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the classifier imports only the pure allowlist, reads no clock, runs no goroutine — fed only from the typed signal (AC-6).\n'
	exit 0
fi
printf 'FAIL: the classifier grew an impure import, a wall-clock read, or a concurrency surface — see above.\n' >&2
exit 1
