#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# unit_execstart_flags_parse.sh — conformance: every flag the project writes into a systemd unit's
# ExecStart is a flag the entrypoint can actually parse, and every mode the dispatcher handles is a mode
# some flag can reach.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   `--fp-probe` was dispatched (`fp-probe) measure_fp_ab_probe ;;`) and never parsed. The generated
#   mycelium-l7probe.service passes it as its SECOND ExecStart, so on every node, every ~2.5 minutes, for
#   the whole life of the feature, that command died at argument parsing with "unknown argument:
#   --fp-probe". The RP-0015 fingerprint A/B probe has therefore never run once, and no fp_probe.json has
#   ever existed on any node.
#
#   Nothing noticed, and the reasons are worth naming because they generalise:
#     * `ExecStart=-` (Audit-0008 S2-1) makes systemd ignore a non-zero exit — deliberately, so a probe
#       that legitimately returns 1 for a DEAD member does not fail the unit. The same prefix hides a
#       command that never started.
#     * So `systemctl --failed` was clean, the unit's Result was success, and the on-node drift drill
#       passed. Every green signal was green.
#     * The producer had a gate (fp_ab_probe_producer.sh), and it extracts the shell FUNCTION and calls it
#       directly — proving the function works while the path that invokes it was broken. Testing the unit
#       of work and never the wiring is exactly how this survives.
#
#   Two artefacts have to agree here and are written in different files by different people at different
#   times: control/lib/*.sh emits the unit, scripts/node-bootstrap.sh parses the argv. Nothing connected
#   them. This gate is that connection.
#
# WHAT IT CHECKS
#   1. EVERY long flag appearing in an ExecStart= line the project generates (control/lib/*.sh heredocs
#      and infra/systemd/*) is accepted by the entrypoint's argument parser.
#   2. Every MODE the dispatcher handles is reachable — some parser branch sets it. (`bootstrap` is the
#      default and needs no flag; it is the sole allowed exception, named explicitly.)
#   3. The parser sets no MODE the dispatcher does not handle — a flag that parses into a dead end.
#
# Flags are read from the REAL ExecStart lines, not from a hand-kept list, so a new unit is covered the
# day it lands.
#
# OFFLINE + INSPECT-ONLY. Exit: 0 = every emitted flag parses, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'unit_execstart_flags_parse: cannot resolve repo root\n' >&2; exit 2; }
NB="$REPO_ROOT/scripts/node-bootstrap.sh"
[ -f "$NB" ] || { printf 'unit_execstart_flags_parse: missing %s\n' "$NB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== emitted ExecStart flags vs the entrypoint parser ==\n'

# The parser block: the `case` over "$1" that consumes argv.
parser="$(awk '/^while \[ "\$#" -gt 0 \]; do/{f=1} f{print} f&&/^[[:space:]]*esac/{exit}' "$NB")"
[ -n "$parser" ] || { printf 'FAIL: could not extract the argument parser from %s — re-confirm this gate.\n' "$NB" >&2; exit 1; }

# --- 1. every emitted flag must parse --------------------------------------------------------------
# Only flags aimed at OUR OWN entrypoint: an ExecStart may legitimately run another binary (myceliumd,
# node_exporter) with flags of its own, so a line is considered only when it invokes node-bootstrap.
shopt -s nullglob
sources=( "$REPO_ROOT"/control/lib/*.sh "$REPO_ROOT"/infra/systemd/* )
shopt -u nullglob

emitted=""
for f in "${sources[@]}"; do
	[ -f "$f" ] || continue
	while IFS= read -r line; do
		case "$line" in
			*NB_SELF*|*node-bootstrap.sh*) ;;
			*) continue ;;
		esac
		for tok in $(printf '%s\n' "$line" | grep -oE '\-\-[a-z0-9][a-z0-9-]*'); do
			case " $emitted " in *" $tok "*) ;; *) emitted="$emitted $tok" ;; esac
		done
	done < <(grep -hE '^[[:space:]]*ExecStart=' "$f" 2>/dev/null)
done

if [ -z "$emitted" ]; then
	badln "no ExecStart line invoking the entrypoint was found in control/lib/*.sh or infra/systemd/* — the discovery moved; re-confirm this gate rather than letting it pass on an empty set"
else
	missing=""
	for tok in $emitted; do
		grep -qE "(^|[[:space:]]|\|)${tok}\)" <<<"$parser" || missing="$missing $tok"
	done
	n="$(printf '%s' "$emitted" | wc -w | tr -d ' ')"
	if [ -n "$missing" ]; then
		badln "a generated unit passes flag(s) the entrypoint cannot parse:$missing — node-bootstrap dies at argument parsing, and with the deliberate 'ExecStart=-' prefix systemd reports the unit successful anyway, so the command silently never runs (this is exactly how --fp-probe went unexecuted on every node for the life of the feature)"
	else
		ok "all $n flag(s) emitted into an ExecStart are accepted by the parser"
	fi
fi

# --- 2/3. dispatcher and parser cover the same mode set ---------------------------------------------
# NESTING-AWARE. This used to stop at the first line matching `^[[:space:]]*esac` and to take every
# `label)` it had seen. Both broke the moment a dispatcher arm grew a NESTED case: the probe arms now
# separate a verdict exit code from a fault, so the extraction ended inside the first probe arm and
# reported the seven modes below it as flags with no dispatcher branch — a FAIL on a healthy tree.
# Depth is tracked instead, and only arms at the dispatcher's own level count as modes.
disp="$(awk '
	/^[[:space:]]*case .* in[[:space:]]*$/ { if (f || $0 ~ /case "\$MODE" in/) { f = 1; d++; next } }
	!f { next }
	/^[[:space:]]*esac/ { d--; if (d == 0) exit; next }
	d == 1 && /^[[:space:]]*[a-z0-9|-]+\)/ { print }
' "$NB" | grep -oE '^[[:space:]]*[a-z0-9-]+\)' | sed -E 's/[[:space:]]//g; s/\)$//' | sort -u)"
pars="$(printf '%s' "$parser" | grep -oE 'MODE="[a-z0-9-]+"' | sed 's/MODE="//; s/"//' | sort -u)"

if [ -z "$disp" ] || [ -z "$pars" ]; then
	badln "could not extract the mode dispatcher ($(printf '%s' "$disp" | wc -w | tr -d ' ') modes) or the parser's mode set ($(printf '%s' "$pars" | wc -w | tr -d ' ')) — re-confirm this gate"
else
	# `bootstrap` is the default MODE and is reached with no flag at all. It is the ONLY exemption, and it
	# is named here rather than filtered by a pattern, so a second unreachable mode cannot hide behind it.
	unreachable="$(comm -23 <(printf '%s\n' "$disp") <(printf '%s\n' "$pars") | grep -vx 'bootstrap' || true)"
	deadend="$(comm -13 <(printf '%s\n' "$disp") <(printf '%s\n' "$pars") || true)"
	[ -z "$unreachable" ] \
		&& ok "every dispatched mode is reachable from some flag (bootstrap is the default, by design)" \
		|| badln "the dispatcher handles mode(s) no flag can select: $(printf '%s' "$unreachable" | tr '\n' ' ')— dead code that looks implemented"
	[ -z "$deadend" ] \
		&& ok "every parsed mode has a dispatcher branch" \
		|| badln "the parser accepts flag(s) whose mode the dispatcher does not handle: $(printf '%s' "$deadend" | tr '\n' ' ')— the flag is accepted and then does nothing"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a generated unit passes a flag the entrypoint cannot parse, or a mode is unreachable.\n' >&2
	exit 1
fi
printf 'PASS: every emitted ExecStart flag parses, and the dispatcher and parser cover the same modes.\n'
exit 0
