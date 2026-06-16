#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_reserved_jq_vars.sh — conformance: no jq invocation names a variable (via --arg / --argjson /
# --slurpfile / --rawfile NAME) after a jq RESERVED KEYWORD. `def`/`as`/`reduce`/`if`/… are keywords;
# jq 1.6 (still shipped on some nodes) fails to PARSE a `$def` reference ("unexpected def, expecting
# IDENT"), so such a filter silently breaks on those nodes while a newer jq (1.7+) tolerates it. That is
# exactly how a `--slurpfile def` shipped: the offline suite ran on a host with jq 1.8 and never saw it,
# while a node with jq 1.6 died on every --update at the operator-override merge. This gate is a STATIC,
# jq-version-INDEPENDENT scan so the bug cannot recur or hide behind a newer local jq.
#
# Exit: 0 = no reserved-word jq variable names, 1 = at least one found, 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

printf '== reserved-jq-variable-name check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# jq reserved words that must never be used as a passed-in variable name. (Operators/keywords whose use
# as `$name` jq 1.6 rejects or that read confusingly.) __loc__ is a jq builtin token too.
RESERVED='def|as|if|then|elif|else|end|reduce|foreach|try|catch|import|include|label|and|or|not|__loc__'

# Scan shell + go sources for `--arg|--argjson|--slurpfile|--rawfile <reserved>` (the only place a jq
# variable name is introduced from outside the program). Exclude this gate file itself and the .git tree.
hits="$(grep -rnE -- "--(arg|argjson|slurpfile|rawfile)[[:space:]]+($RESERVED)\b" \
	"$REPO_ROOT/control" "$REPO_ROOT/scripts" "$REPO_ROOT/tests" "$REPO_ROOT/cmd" "$REPO_ROOT/internal" \
	2>/dev/null | grep -vF "no_reserved_jq_vars.sh")"

if [ -n "$hits" ]; then
	printf '\nFAIL: a jq variable is named after a reserved keyword (breaks jq 1.6 parsing):\n' >&2
	printf '%s\n' "$hits" >&2
	printf '\nRename the variable (e.g. `--slurpfile def` -> `--slurpfile base`, `$def` -> `$base`).\n' >&2
	exit 1
fi

printf 'PASS: no jq variable is named after a reserved keyword (jq 1.6-safe).\n'
exit 0
