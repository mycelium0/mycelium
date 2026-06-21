#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_cli_readonly.sh — conformance (RP-0011 chunk C): the operator-facing node-profile CLI verbs
# (myceliumctl node validate|plan, transport list) are READ-ONLY. They parse / validate / preview the
# node descriptor and the registry but NEVER write node state, rename/remove files, or exec a
# subprocess. The live-mutating verbs (deploy / transport enable|disable) land only once the bootstrap
# reads the descriptor — until then these verbs cannot change a live node. OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = read-only + dispatched, 1 = a write/exec or a missing dispatch, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_cli_readonly: cannot resolve repo root\n' >&2; exit 2; }
MAIN="$REPO_ROOT/cmd/myceliumctl/main.go"
[ -f "$MAIN" ] || { printf 'node_cli_readonly: missing %s\n' "$MAIN" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== node/transport CLI verbs are read-only (RP-0011 chunk C) ==\n'

# The block of the node/transport command functions (from readFileOrStdin through, up to usage()).
block="$(awk '/^func readFileOrStdin\(/{f=1} f{print} /^func usage\(/{exit}' "$MAIN")"
[ -n "$block" ] || { badln "cannot locate the node/transport CLI block in main.go"; }

# 1. no write / rename / remove / mkdir / chmod / exec / syscall in the read-only verbs.
if printf '%s' "$block" | grep -qE 'os\.(WriteFile|Create|OpenFile|Remove|RemoveAll|Rename|Mkdir|MkdirAll|Chmod|Chown|Truncate)|ioutil\.WriteFile|exec\.Command|"os/exec"|syscall\.'; then
	badln "a node/transport verb performs a write/rename/remove/mkdir/chmod/exec (must be read-only):"
	printf '%s' "$block" | grep -nE 'os\.(WriteFile|Create|OpenFile|Remove|RemoveAll|Rename|Mkdir|MkdirAll|Chmod|Chown|Truncate)|ioutil\.WriteFile|exec\.Command|"os/exec"|syscall\.' | sed 's/^/    /'
else
	ok "no write/rename/remove/mkdir/chmod/exec in the node/transport verbs"
fi

# 2. the verbs are actually dispatched (registered), so the gate guards live code.
grep -qE '^[[:space:]]*case "node":' "$MAIN" \
	&& ok "the 'node' command is dispatched" \
	|| badln "the 'node' command is not dispatched in main.go run()"
grep -qE '^[[:space:]]*case "transport":' "$MAIN" \
	&& ok "the 'transport' command is dispatched" \
	|| badln "the 'transport' command is not dispatched in main.go run()"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the node/transport CLI verbs are read-only and dispatched.\n'
	exit 0
fi
printf 'FAIL: a node/transport CLI verb mutates node state or is undispatched — see above.\n' >&2
exit 1
