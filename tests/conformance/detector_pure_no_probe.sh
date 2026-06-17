#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# detector_pure_no_probe.sh — conformance: the Phase-2 classifier (internal/detect, RP-0010 Plane 2)
# is PURE and adds NO new probing surface (RP-0010 AC-6).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   Detection must be fed from the WRAP'd internal/reach signal only; it must add no new active-probe
#   fingerprint (RP-0010 AC-6) and must not actuate. The cleanest structural guarantee is that the
#   classifier package imports no networking, process, or filesystem packages, and does not reach
#   into the measurement package (it consumes the spec.DetectorSignal handed to it, not internal/
#   reach itself). If a future change pulled in `net`/`os`/`syscall`/`os/exec` or `internal/reach`,
#   the detector could grow a probe or a side effect — this gate fails that by construction. It is
#   OFFLINE + INSPECT-ONLY (it reads import blocks; it does not need a Go toolchain).
#
# WHAT THIS CHECKS
#   1. The classifier package exists (internal/detect has at least one non-test .go file).
#   2. Its non-test sources import internal/spec (they consume the typed signal/verdict).
#   3. Their import blocks contain NO net*/os*/syscall package and NO internal/reach — the no-probe,
#      no-I/O, no-actuation, clean-layering invariant.
#
# Exit: 0 = pure / no new probe surface, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'detector_pure_no_probe: cannot resolve repo root\n' >&2; exit 2; }
DETECT_DIR="$REPO_ROOT/internal/detect"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# imports_of FILE — emit just the imported package path strings. It handles `import (...)` blocks
# (including same-line residue and one-line blocks) AND single-line imports WITH an optional
# alias/dot/underscore token (`import _ "x"`, `import . "x"`, `import al "x"`). It strips // line
# comments first, so a comment mentioning a package cannot add a false hit and a commented-out import
# inside a block cannot trip the scan. A Go import path never contains `//`, so the strip is safe.
imports_of() {
	awk '
		{ sub(/\/\/.*/, "") }                                       # strip line comments
		/^[[:space:]]*import[[:space:]]*\(/ {                        # block open (keep same-line residue)
			sub(/^[[:space:]]*import[[:space:]]*\(/, ""); inblk = 1
		}
		inblk {
			i = index($0, ")")
			if (i > 0) { print substr($0, 1, i - 1); inblk = 0; next }
			print; next
		}
		/^[[:space:]]*import[[:space:]]/ { print }                  # single-line import (alias optional)
	' "$1" | grep -oE '"[^"]+"'
}

printf '== detector purity / no-new-probe-surface check (internal/detect, RP-0010 AC-6) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# 1. package present
nontest="$(find "$DETECT_DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' 2>/dev/null)"
if [ -z "$nontest" ]; then
	printf 'FAIL: internal/detect has no non-test .go source (the classifier package is the anchor).\n' >&2
	exit 1
fi
ok "classifier package present: internal/detect"

# The scan is flat (-maxdepth 1); assert there is no subpackage it would silently skip.
if [ -n "$(find "$DETECT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
	badln "internal/detect grew a subpackage the purity scan does not cover (recurse the scan or keep the package flat)"
else
	ok "internal/detect is a flat package (no unscanned subpackage)"
fi

# Forbidden import packages: anything that probes, touches the OS, or reaches the measurement layer.
# The reach branch is anchored to the project module path so an unrelated third-party path ending in
# "internal/reach" cannot match.
FORBIDDEN_RE='^"(net|os|syscall)(/[^"]*)?"$|^"github\.com/mindicator/mycelium/internal/reach(/[^"]*)?"$'
imports_spec=0
for f in $nontest; do
	rel="${f#"$REPO_ROOT"/}"
	imps="$(imports_of "$f")"
	# 3. forbidden imports
	bad="$(printf '%s\n' "$imps" | grep -E "$FORBIDDEN_RE" || true)"
	if [ -n "$bad" ]; then
		badln "$rel imports a forbidden package (no probe/I/O/reach in the classifier): $(printf '%s' "$bad" | tr '\n' ' ')"
	else
		ok "$rel imports no net*/os*/syscall package and no internal/reach"
	fi
	# 2. must consume the spec types
	if printf '%s\n' "$imps" | grep -qE '"github.com/mindicator/mycelium/internal/spec"'; then
		imports_spec=1
	fi
done
if [ "$imports_spec" = "1" ]; then
	ok "the classifier consumes internal/spec (the typed signal/verdict)"
else
	badln "no internal/detect source imports internal/spec (it must consume the typed DetectorSignal/Verdict)"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the classifier is pure — no networking/process/reach imports, fed only from the typed signal (AC-6).\n'
	exit 0
fi
printf 'FAIL: the classifier grew a probe/I/O/actuation surface (forbidden import) — see above.\n' >&2
exit 1
