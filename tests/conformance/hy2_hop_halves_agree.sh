#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# hy2_hop_halves_agree.sh — conformance: the three deciders of a hysteria2 hop range give the SAME verdict
# on the same value, and the range an operator sets SURVIVES the next converge.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   A hysteria2 hop range is a promise the CLIENT CONFIG makes and the FIREWALL keeps. Three separate
#   pieces of code decide whether a given value is usable:
#     1. spec.ValidHysteria2HopRange      — Go, the subscription renderer
#     2. render_singbox.sh                — the shell client renderer
#     3. _hy2_hop_range (nb_harden.sh)    — the nat/PREROUTING REDIRECT that delivers the range
#   If any two disagree the node ships a config advertising a range with no rule behind it, and NOTHING on
#   the node reports it: verify_post_apply checks the service, the bind and a LOOPBACK handshake, and
#   loopback traffic never traverses PREROUTING. Every light stays green while hysteria2 is dead for the
#   whole population.
#
#   They DID disagree. Go rejected "2000:3000:4000"; both shell halves accepted it, because `${r%%:*}` and
#   `${r##*:}` take the OUTER fields — lo=2000, hi=4000, both in range, lo<hi. The value then reached
#   iptables as `--dport 2000:3000:4000`, which iptables refuses, so the rule silently failed to install
#   while the renderer had already advertised the range to every client.
#
#   The second half of this gate is a different failure of the same feature. The range shipped as
#   "off by default" and was in fact UNSETTABLE: write_params regenerates params.json from identity +
#   canonical ports, and merge_operator_overrides honours only the Go-owned operator_toggle_keys allowlist.
#   `hysteria2_hop_ports` was in neither, so a hand-set value was erased on the next converge — every timer
#   tick. A capability the repo believed it had and no operator could reach.
#
# WHAT IT CHECKS, by RUNNING each decider over one shared value table
#   1. All three verdicts agree on every row (valid ranges, malformed ones, out-of-bounds, multi-colon).
#   2. Every params key the renderers READ is either emitted by write_params or operator-settable — the
#      general form of the second defect, so the next knob added cannot repeat it.
#   3. An operator-set range survives merge_operator_overrides on top of regenerated defaults.
#
# The Go half is SKIPPED (not passed) without a toolchain; the shell halves always run.
# Exit: 0 = the halves agree and the knob is reachable; 1 = they do not; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'hy2_hop_halves_agree: cannot resolve repo root\n' >&2; exit 2; }
HARDEN="$REPO_ROOT/control/lib/nb_harden.sh"
RENDER="$REPO_ROOT/control/lib/render_singbox.sh"
PARAMS_LIB="$REPO_ROOT/control/lib/nb_render_params.sh"
VOCAB="$REPO_ROOT/control/vocab.json"
for f in "$HARDEN" "$RENDER" "$PARAMS_LIB" "$VOCAB"; do
	[ -f "$f" ] || { printf 'hy2_hop_halves_agree: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'hy2_hop_halves_agree: jq required\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.hop.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

printf '== hysteria2 hop range: one value, three deciders, one verdict ==\n'

# ---------------------------------------------------------------------------------------------------
# THE VALUE TABLE. Each row: VALUE|EXPECTED  (EXPECTED empty = the range must be REFUSED by all three).
# ---------------------------------------------------------------------------------------------------
ROWS='20000:21000|20000:21000
1024:65535|1024:65535
2000:2001|2000:2001
|
abc|
20000|
:20000|
20000:|
0:100|
1023:2000|
20000:70000|
5000:4000|
5000:5000|
2000:3000:4000|
20000:21000:5|
 20000:21000|
20000:21000 |
-1:500|
1e4:2e4|'

# ---------------------------------------------------------------------------------------------------
# 1. The FIREWALL half — _hy2_hop_range, executed.
# ---------------------------------------------------------------------------------------------------
log()  { :; }
warn() { :; }
die()  { printf 'lib: %s\n' "$*" >&2; exit 1; }
run()  { "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
# shellcheck source=/dev/null
. "$HARDEN" || { printf 'FAIL: could not source nb_harden.sh\n' >&2; exit 2; }

fw_verdict() { # VALUE -> the range it would install, or empty
	PARAMS_JSON="$WORK/p.json"
	jq -n --arg r "$1" '{hysteria2_enabled:true, hysteria2_port:8444, hysteria2_hop_ports:$r}' >"$PARAMS_JSON"
	_hy2_hop_range
}

# ---------------------------------------------------------------------------------------------------
# 2. The SHELL CLIENT RENDERER half. render_singbox.sh calls myc_vocab_protos at top level and dies when
#    sourced alone, so the validation block is EXTRACTED verbatim and driven — and the extraction itself is
#    checked below, because a gate that runs a copy of the code is only as good as the copy being current.
# ---------------------------------------------------------------------------------------------------
BLOCK="$(sed -n '/# VALIDATE, with the same rule as _hy2_hop_range/,/^			esac$/p' "$RENDER")"
if [ -z "$BLOCK" ]; then
	badln "could not extract the client renderer's hop-range validation from render_singbox.sh — this whole section would compare nothing"
	BLOCK='hysteria2_hop_ports=""'
fi
cat >"$WORK/render_half.sh" <<EOF
hysteria2_hop_ports="\$1"
$BLOCK
printf '%s' "\$hysteria2_hop_ports"
EOF
render_verdict() { bash "$WORK/render_half.sh" "$1"; }

# ---------------------------------------------------------------------------------------------------
# 3. The GO half — spec.ValidHysteria2HopRange, via a throwaway program.
# ---------------------------------------------------------------------------------------------------
GO_OUT=""
if command -v go >/dev/null 2>&1; then
	mkdir -p "$WORK/go"
	cat >"$WORK/go/main.go" <<'GOSRC'
package main

import (
	"bufio"
	"fmt"
	"os"

	"github.com/mycelium0/mycelium/internal/spec"
)

func main() {
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		v := sc.Text()
		if v != "" && spec.ValidHysteria2HopRange(v) {
			fmt.Println(v)
		} else {
			fmt.Println("")
		}
	}
}
GOSRC
	MOD="$(awk '/^module /{print $2; exit}' "$REPO_ROOT/go.mod" 2>/dev/null)"
	[ -n "$MOD" ] && sed -i.bak "s|github.com/mycelium0/mycelium|$MOD|" "$WORK/go/main.go" 2>/dev/null
	rm -f "$WORK/go/main.go.bak" 2>/dev/null || true
	mkdir -p "$REPO_ROOT/.hopprobe" && cp "$WORK/go/main.go" "$REPO_ROOT/.hopprobe/main.go"
	if ( cd "$REPO_ROOT" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
	     go build -o "$WORK/hopprobe" ./.hopprobe ) 2>"$WORK/go.err"; then
		GO_OUT="$WORK/hopprobe"
	else
		badln "the Go half FAILED TO BUILD, so the three-way comparison is really a two-way one: $(tail -1 "$WORK/go.err" 2>/dev/null)"
	fi
	rm -rf "$REPO_ROOT/.hopprobe"
else
	printf '  SKIP  no Go toolchain (jq-only lane): spec.ValidHysteria2HopRange is not compared here. The two\n'
	printf '        SHELL halves are still driven against each other over the full table below.\n'
fi

go_verdicts() { # reads the whole table at once; one line of output per input line
	[ -n "$GO_OUT" ] || return 0
	printf '%s\n' "$1" | "$GO_OUT"
}

# ---------------------------------------------------------------------------------------------------
# Drive the table.
# ---------------------------------------------------------------------------------------------------
printf '\n-- one value, three verdicts --\n'
VALUES="$(printf '%s\n' "$ROWS" | sed 's/|.*$//')"
GOV="$(go_verdicts "$VALUES")"
i=0
while IFS='|' read -r value want; do
	i=$((i + 1))
	fw="$(fw_verdict "$value")"
	rn="$(render_verdict "$value")"
	label="$(printf '%s' "${value:-<пусто>}" | sed 's/ /␣/g')"

	if [ "$fw" = "$want" ] && [ "$rn" = "$want" ]; then
		ok "'$label' -> ${want:-refused} (firewall + client renderer agree)"
	else
		badln "'$label': the client renderer says '${rn:-refused}' and the firewall says '${fw:-refused}' (expected '${want:-refused}'). One half advertises a range the other will not make real; nothing on the node can see the difference, because verify_post_apply never traverses PREROUTING."
	fi

	if [ -n "$GO_OUT" ]; then
		gv="$(printf '%s\n' "$GOV" | sed -n "${i}p")"
		[ "$gv" = "$want" ] \
			&& ok "  and Go agrees" \
			|| badln "  Go says '${gv:-refused}' for '$label' while the shell says '${fw:-refused}'. The Go renderer produces the subscription for a Go-bearing node and the shell one for every other node — the SAME operator value must not yield different client configs depending on which binary happened to render."
	fi
done <<EOF
$ROWS
EOF

# ---------------------------------------------------------------------------------------------------
# 4. THE GENERAL FORM of the second defect: a params key the renderers read but nothing can set.
# ---------------------------------------------------------------------------------------------------
printf '\n-- every knob the renderers read must be reachable by an operator --\n'
# Anchored INSIDE write_params. The first `jq -n` in this file belongs to seed_operator_overrides, so an
# unanchored range read that helper's tiny program instead of the defaults object and reported every
# identity-derived key as unreachable — a gate failing on its own extraction rather than on the code.
GENERATED="$(sed -n '/^write_params()/,/^}$/p' "$PARAMS_LIB" \
	| sed -n "/jq -n/,/>\"\$tmp\"/p" | grep -oE '[a-z0-9_]+:' | tr -d ':' | sort -u)"
[ -n "$GENERATED" ] || badln "could not read the generated params key set from nb_render_params.sh — this section would pass vacuously"
ALLOWED="$(jq -r '.operator_toggle_keys[]?' "$VOCAB" | sort -u)"
[ -n "$ALLOWED" ] || badln "could not read operator_toggle_keys from control/vocab.json — this section would pass vacuously"

# Keys the CLIENT renderers actually consume. Identity/secret material is generated, never operator-set.
READ_KEYS="$( { grep -oE "paramStr\(params, \"[a-z0-9_]+\"" "$REPO_ROOT/internal/spec/subscription.go" | sed -E 's/.*"([a-z0-9_]+)"/\1/'
                grep -oE "myc_params_get \"\\\$params\" '\.[a-z0-9_]+'" "$RENDER" | sed -E "s/.*'\.([a-z0-9_]+)'/\1/"
              } | sort -u )"
[ -n "$READ_KEYS" ] || badln "could not read the consumed params key set — this section would pass vacuously"

# A key can legitimately reach params.json by THREE routes, not two. The third is a dedicated stamping
# step — apply_reachability_posture writes `.node_bind` from the node profile with a `jq '.node_bind = …'`
# — which is neither in write_params' defaults object nor operator-settable, and is nonetheless perfectly
# reachable. Counting only the first two reported node_bind as unsettable, which is a false alarm about a
# key that has worked since RP-0011.
STAMPED="$(grep -rhoE "jq [^|]*'\.[a-z0-9_]+ *=" "$REPO_ROOT"/control/lib/*.sh 2>/dev/null \
	| sed -E "s/.*'\.([a-z0-9_]+) *=.*/\1/" | sort -u)"

unreachable=""
for k in $READ_KEYS; do
	printf '%s\n' "$GENERATED" | grep -qx "$k" && continue
	printf '%s\n' "$ALLOWED"   | grep -qx "$k" && continue
	printf '%s\n' "$STAMPED"   | grep -qx "$k" && continue
	unreachable="$unreachable $k"
done
if [ -n "$unreachable" ]; then
	badln "a renderer reads these params keys and NOTHING can set them:$unreachable. write_params regenerates params.json from a fixed object and merge_operator_overrides honours only the Go-owned allowlist, so a hand-edited value is erased by the next converge — which is every timer tick. A knob in this state is not 'off by default', it is unsettable, and the feature it belongs to cannot be turned on by anyone."
else
	ok "every params key the renderers consume is either generated or operator-settable"
fi

printf '%s\n' "$ALLOWED" | grep -qx hysteria2_hop_ports \
	&& ok "hysteria2_hop_ports is operator-settable (the overlay survives write_params)" \
	|| badln "hysteria2_hop_ports is not in operator_toggle_keys — the port-hopping feature ships and cannot be enabled"

# ---------------------------------------------------------------------------------------------------
# 5. And prove the round trip: an operator-set range survives regeneration.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the operator overlay round trip --\n'
(
	set -u
	OPERATOR_OVERRIDES="$WORK/ovr.json"
	OPERATOR_TOGGLE_KEYS="$(jq -ec '.operator_toggle_keys' "$VOCAB")"
	printf '{"hysteria2_enabled":true,"hysteria2_hop_ports":"20000:21000"}\n' >"$OPERATOR_OVERRIDES"
	jq -n '{hysteria2_enabled:false, hysteria2_port:8444, hysteria2_hop_ports:"", hysteria2_hop_interval:"30s"}' >"$WORK/defaults.json"
	# The merge as nb_render_params.sh performs it. Driving the shipped function needs the whole entrypoint
	# environment; the jq program is the load-bearing part and is reproduced here verbatim from that file.
	jq -n --slurpfile base "$WORK/defaults.json" --slurpfile ovr "$OPERATOR_OVERRIDES" \
		--argjson keys "$OPERATOR_TOGGLE_KEYS" \
		'($base[0] // {}) as $d | ($ovr[0] // {}) as $o
		 | reduce $keys[] as $k ($d; if ($o|has($k)) then . + { ($k): $o[$k] } else . end)' >"$WORK/merged.json"
	got="$(jq -r '.hysteria2_hop_ports' "$WORK/merged.json")"
	[ "$got" = "20000:21000" ] && exit 0 || { printf '%s' "$got" >"$WORK/got"; exit 1; }
) \
	&& ok "an operator-set range survives the regeneration of params.json" \
	|| badln "the operator's range did not survive the merge (got '$(cat "$WORK/got" 2>/dev/null)') — it is dropped on the next converge, and the node reverts to no hopping while every issued config still advertises the range"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the hop-range deciders disagree, or the knob cannot be set.\n' >&2
	exit 1
fi
printf 'PASS: all deciders agree on every value, and an operator-set range reaches the node and survives.\n'
exit 0
