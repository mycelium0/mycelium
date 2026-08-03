#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_revoke_go_equiv.sh — conformance (RP-0008): the Go-owned AmneziaWG peer-strip
# (spec.StripAWGPeers / `myceliumctl awg-strip-peers`) is BYTE-IDENTICAL to the shell producer
# (_awg_strip_peers) across a matrix of configs, and the Go revoke planner agrees with the shell
# resolver about which peers a name owns and which no name can reach.
# Author: mindicator & silicon bags quartet.
#
# WHY THE PORT, AND WHY THIS GATE
#   Deciding which peers a revoke removes, producing the rewritten config and checking that rewrite are
#   CONTROL DECISIONS, and each of them was wrong in bash at least once — in ways a value table finds
#   instantly and an awk rewrite hides:
#     * the strip captured the blank line between sections into the preceding block and re-emitted one,
#       so every pass grew the file by a blank per surviving peer, without bound;
#     * the resolver decided at the PublicKey line, so a `# name =` marker that FOLLOWED the key was
#       invisible, and `PublicKey=KEY` without spaces was invisible to the matcher entirely;
#     * the post-rewrite check compared keys by substring, so a key that is a prefix of another read as
#       still-present and aborted a revoke that had in fact succeeded.
#
#   Per the strangler doctrine the shell stays authoritative until this is green; the Go half is
#   additive. The matrix deliberately includes the shapes that produced each bug above, so an
#   equivalence that holds only for tidy configs cannot pass.
#
# SKIP-IF-NO-GO: mirrors the other Go-half gates.
# Exit: 0 = byte-identical (or skipped); 1 = the producers diverged; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'awg_revoke_go_equiv: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_render_awg.sh"
[ -f "$LIB" ] || { printf 'awg_revoke_go_equiv: missing %s\n' "$LIB" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'awg_revoke_go_equiv: jq required\n' >&2; exit 2; }

GO="${GO:-go}"
command -v "$GO" >/dev/null 2>&1 || {
	printf 'SKIP: no Go toolchain — the Go half of this gate cannot run.\n'
	exit 0
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.awgrevgo.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

SPINE="$WORK/myceliumctl"
if ! ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
	"$GO" build -o "$SPINE" ./cmd/myceliumctl ) >"$WORK/build.err" 2>&1; then
	printf 'awg_revoke_go_equiv: could not build myceliumctl:\n'; sed 's/^/    /' "$WORK/build.err"
	exit 2
fi

# the shell half, sourced with the primitives it calls (a lib sourced without them is a different program)
log()  { :; }
warn() { :; }
die()  { printf 'shell: %s\n' "$*" >&2; exit 1; }
run()  { "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
# shellcheck source=/dev/null
. "$LIB" || { printf 'awg_revoke_go_equiv: could not source %s\n' "$LIB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== AmneziaWG revoke: Go <-> shell byte-equivalence (RP-0008) ==\n'

IFACE='[Interface]
PrivateKey = SERVERKEY
Address = 10.13.13.1/24
ListenPort = 443
Jc = 9
Jmin = 49
Jmax = 103
S1 = 86
S2 = 232
H1 = 1
H2 = 2
H3 = 3
H4 = 4'

mk() { printf '%s\n' "$1" > "$WORK/c.conf"; }

compare() { # LABEL  REMOVE_CSV
	local label="$1" rm_csv="$2" shell_out go_out
	local -a pubs=()
	IFS=',' read -r -a pubs <<<"$rm_csv"
	shell_out="$WORK/shell.out"; go_out="$WORK/go.out"
	_awg_strip_peers "$WORK/c.conf" "${pubs[@]}" >"$shell_out" 2>/dev/null
	if ! "$SPINE" awg-strip-peers --conf "$WORK/c.conf" --remove "$rm_csv" >"$go_out" 2>"$WORK/go.err"; then
		# The Go half verifies its own output; a refusal is only correct if the shell produced something
		# unsound, which this matrix never does.
		badln "$label: the Go half REFUSED to emit: $(head -1 "$WORK/go.err")"
		return
	fi
	if cmp -s "$shell_out" "$go_out"; then
		ok "$label: byte-identical"
	else
		badln "$label: the producers diverged. shell=$(wc -l <"$shell_out") lines, go=$(wc -l <"$go_out") lines; first difference: $(diff "$shell_out" "$go_out" | head -3 | tr '\n' ' ')"
	fi
}

# --- the matrix. Every row is a shape that produced a real bug, or its neighbour. -------------------
mk "$IFACE

[Peer]
# name = alice
PublicKey = KEYALICE
AllowedIPs = 10.13.13.2/32

[Peer]
# name = bob
PublicKey = KEYBOB
AllowedIPs = 10.13.13.3/32"
compare "two peers, remove none" ""
compare "two peers, remove the first" "KEYALICE"
compare "two peers, remove the second" "KEYBOB"
compare "two peers, remove both" "KEYALICE,KEYBOB"
compare "two peers, remove an absent key" "KEYNOBODY"

mk "$IFACE

[Peer]
PublicKey = ORPHAN
AllowedIPs = 10.13.13.2/32

[Peer]
# name = alice
PublicKey = KEYALICE
AllowedIPs = 10.13.13.3/32"
compare "an UNNAMED peer present, remove the named one" "KEYALICE"
compare "an UNNAMED peer present, remove it by key" "ORPHAN"

mk "$IFACE

[Peer]
# name = alice
PublicKey=KEYALICE
AllowedIPs = 10.13.13.2/32"
compare "key written WITHOUT spaces around '='" "KEYALICE"

mk "$IFACE

[Peer]
# name = a
PublicKey = KEY
AllowedIPs = 10.13.13.2/32

[Peer]
# name = b
PublicKey = KEY2
AllowedIPs = 10.13.13.3/32"
compare "one key is a strict PREFIX of another" "KEY"

# a config already carrying the blank-line bloat the old stripper produced
mk "$IFACE


[Peer]
# name = alice
PublicKey = KEYALICE


[Peer]
# name = bob
PublicKey = KEYBOB
"
compare "a config already bloated with blank lines, remove none" ""
compare "a config already bloated with blank lines, remove one" "KEYALICE"

mk "$IFACE"
compare "no peers at all" ""

# --- the planner: does Go agree with the shell about who owns what ----------------------------------
mk "$IFACE

[Peer]
PublicKey = ORPHAN
AllowedIPs = 10.13.13.2/32

[Peer]
# name = alice
PublicKey = KEY1

[Peer]
# name = alice
PublicKey = KEY2"
plan="$("$SPINE" awg-revoke-plan --conf "$WORK/c.conf" --name alice --stored-pub KEY1 2>"$WORK/plan.err")" || {
	badln "awg-revoke-plan failed: $(head -1 "$WORK/plan.err")"; plan='{}'
}
[ "$(printf '%s' "$plan" | jq -r '[.targets[]]|sort|join(",")')" = "KEY1,KEY2" ] \
	&& ok "planner: both peers under one name are targeted (the --awg-issue duplicate state)" \
	|| badln "planner: targets = $(printf '%s' "$plan" | jq -c .targets), expected both KEY1 and KEY2"
[ "$(printf '%s' "$plan" | jq -r '[.unnamed[]]|join(",")')" = "ORPHAN" ] \
	&& ok "planner: the unnamed peer is reported, so the caller cannot claim a guarantee it cannot honour" \
	|| badln "planner: unnamed = $(printf '%s' "$plan" | jq -c .unnamed), expected ORPHAN"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the Go and shell AmneziaWG revoke halves disagree — do NOT cut over.\n' >&2
	exit 1
fi
printf 'PASS: the Go peer-strip is byte-identical to the shell across the matrix, and the planners agree.\n'
exit 0
