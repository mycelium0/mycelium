#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_dialect_go_equiv.sh — conformance (RP-0008 + Audit-0008 S1-4): the Go-owned AmneziaWG dialect
# derivation (spec.DeriveAWGDialect / `myceliumctl awg-dialect`) is BYTE-IDENTICAL to the bash twin
# (derive_awg_dialect in control/lib/nb_render_awg.sh), for the same (key, epoch).
#
# WHY THIS MATTERS MORE THAN A USUAL EQUIVALENCE GATE. Every peer of a node — the server and ALL its
# clients — must carry the SAME nine values or no handshake completes. The server config may be rendered by
# one producer and a client config by the other; if they ever disagree by a single digit the node's whole
# AmneziaWG family goes dark. So the two implementations are pinned exactly, across epochs (rotation) and
# across many keys (including the distinct-header redraw path).
#
# Mirrors the other producer-equivalence gates (share_link / subscription / aggregate / render_server).
# Skips cleanly (exit 0) when Go is unavailable, like the other Go-half gates.
#
# Exit: 0 = byte-identical (or skipped), 1 = the producers diverged, 2 = usage/precondition.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
AWG_LIB="$REPO_ROOT/control/lib/nb_render_awg.sh"

printf '== AmneziaWG dialect: Go <-> shell byte-equivalence (RP-0008 / Audit-0008 S1-4) ==\n'
[ -f "$AWG_LIB" ] || { printf 'FAIL: nb_render_awg.sh missing.\n' >&2; exit 2; }

if ! command -v go >/dev/null 2>&1; then
	printf 'SKIP: no Go toolchain — the Go half of this gate cannot run.\n'
	exit 0
fi

# Minimal host env so the lib can be SOURCED standalone (it expects the entrypoint's helpers at call time).
have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf 'shell-derive FAILED: %s\n' "$*" >&2; exit 1; }
log()  { :; }
warn() { :; }
STATE_DIR="${STATE_DIR:-/nonexistent}"   # only _awg_read_epoch would use it; we pass epochs explicitly
DRY_RUN=0
DO_AMNEZIAWG=1
# shellcheck source=/dev/null
. "$AWG_LIB" 2>/dev/null || { printf 'FAIL: could not source nb_render_awg.sh.\n' >&2; exit 2; }
command -v derive_awg_dialect >/dev/null 2>&1 || { printf 'FAIL: derive_awg_dialect not defined after sourcing.\n' >&2; exit 2; }

# shell_dialect KEY EPOCH -> the nine canonical [Interface] lines, exactly as the renderers emit them.
shell_dialect() {
	derive_awg_dialect "$1" "$2"
	printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2"
	printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
}

# Build the CLI ONCE (a `go run` per vector would recompile-check on every call and needlessly load the
# host); then the Go half runs the same binary the node uses. The key goes in on STDIN — never an argv, so
# it cannot leak into a process listing.
GOBIN_TMP="$(mktemp -d)" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$GOBIN_TMP"' EXIT
if ! ( cd "$REPO_ROOT" && go build -o "$GOBIN_TMP/myceliumctl" ./cmd/myceliumctl ) 2>/dev/null; then
	printf 'SKIP: could not build myceliumctl (no usable Go build env).\n'
	exit 0
fi
go_dialect() { printf '%s' "$1" | "$GOBIN_TMP/myceliumctl" awg-dialect --epoch "$2"; }

fail=0
checked=0

# A spread of keys (shapes a real awg genkey produces, plus edge-ish ones) x epochs (0 = the live network's
# state, then rotation epochs). Keys here are SYNTHETIC test vectors — never a real node key.
KEYS=(
	"aQ7Xk2mZ0pLb9vN3tR8yF6wJ1cH4dS5gT2uV0eB7i="
	"ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHhGgFf0="
	"0000000000000000000000000000000000000000000="
	"////////////////////////////////////////////"
	"kP3sN8vQ2xL7bM1tR6yH9wJ4cF5dG0aZ8eU3iO7pS2="
)
EPOCHS=(0 1 2 5 17)

for k in "${KEYS[@]}"; do
	for e in "${EPOCHS[@]}"; do
		sh_out="$(shell_dialect "$k" "$e" 2>/dev/null)"
		go_out="$(go_dialect "$k" "$e" 2>/dev/null)"
		checked=$((checked + 1))
		if [ -z "$sh_out" ] || [ -z "$go_out" ]; then
			printf '  FAIL  empty output for epoch %s (shell:%s go:%s bytes)\n' "$e" "${#sh_out}" "${#go_out}"
			fail=1
			continue
		fi
		if [ "$sh_out" != "$go_out" ]; then
			printf '  FAIL  DIVERGED at epoch %s\n' "$e"
			diff <(printf '%s\n' "$sh_out") <(printf '%s\n' "$go_out") | sed 's/^/         /' >&2
			fail=1
		fi
	done
done

if [ "$fail" -eq 0 ]; then
	printf '  ok    %d (key, epoch) combinations are byte-identical across both producers\n' "$checked"
fi

# The epoch-0 compatibility pin, stated once more as its own assertion: epoch 0 must equal a derivation with
# NO epoch argument at all (the shell default), because every node migrated before rotation is at epoch 0.
sh_default="$(shell_dialect "${KEYS[0]}" "" 2>/dev/null)"
sh_zero="$(shell_dialect "${KEYS[0]}" 0 2>/dev/null)"
if [ -n "$sh_default" ] && [ "$sh_default" = "$sh_zero" ]; then
	printf '  ok    an absent epoch derives exactly as epoch 0 (live nodes keep their dialect)\n'
else
	printf '  FAIL  an absent epoch does not equal epoch 0 — introducing rotation would re-dialect live nodes\n'
	fail=1
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the Go and shell AmneziaWG dialect producers disagree — a node could render a server config\n' >&2
	printf '      and a client config with different dialects, taking the whole AmneziaWG family down.\n' >&2
	exit 1
fi
printf 'PASS: the Go and shell dialect producers are byte-identical across keys and rotation epochs.\n'
exit 0
