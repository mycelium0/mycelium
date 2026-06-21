#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_cli_no_actuation.sh — conformance (RP-0011 chunk C/B2c): the operator-facing node/transport CLI
# verbs (myceliumctl node validate|plan, transport list|enable|disable) NEVER actuate a live node. They
# read the registry, parse/validate/preview the descriptor, and the writer verbs (transport
# enable|disable) edit ONLY the node-profile descriptor (node.config.json) — they run NO subprocess, do
# NOT mutate live state (params.json / the sing-box config / units / the firewall), and perform no
# destructive file op. The live mutation stays the explicit, separately-gated `node-bootstrap --node-apply`
# (B2b). So the CLI edits INTENT; it cannot restart, re-render, or break a live node. OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = no actuation + dispatched, 1 = a subprocess/live-mutation/destructive op, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_cli_no_actuation: cannot resolve repo root\n' >&2; exit 2; }
MAIN="$REPO_ROOT/cmd/myceliumctl/main.go"
[ -f "$MAIN" ] || { printf 'node_cli_no_actuation: missing %s\n' "$MAIN" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== node/transport CLI verbs never actuate a live node (RP-0011 chunk C/B2c) ==\n'

# The block of the node/transport command functions (from readFileOrStdin through, up to usage()).
block="$(awk '/^func readFileOrStdin\(/{f=1} f{print} /^func usage\(/{exit}' "$MAIN")"
[ -n "$block" ] || { badln "cannot locate the node/transport CLI block in main.go"; }

# 1. no subprocess / exec / actuation.
if printf '%s' "$block" | grep -qE 'exec\.Command|exec\.CommandContext|"os/exec"|syscall\.(Exec|ForkExec|StartProcess)'; then
	badln "a node/transport verb spawns a subprocess (must not actuate — the apply is the explicit --node-apply)"
else
	ok "no subprocess / exec in the node/transport verbs"
fi

# 2. no DESTRUCTIVE file ops on live state.
if printf '%s' "$block" | grep -qE 'os\.(Remove|RemoveAll|Rename|Truncate)|os\.Chmod[^)]*0o?7|os\.Chown'; then
	badln "a node/transport verb performs a destructive/ownership file op (remove/rename/truncate/chown)"
else
	ok "no destructive (remove/rename/truncate) file ops in the verbs"
fi

# 3. no write to / reference of LIVE node state (params.json / sing-box config / units / firewall). The
#    descriptor (node.config.json under /var/lib/mycelium) is the ONLY thing these verbs may touch.
if printf '%s' "$block" | grep -qiE 'params\.json|/usr/local/etc|/etc/sing-box|sing-box/config|\.service|systemctl|\bufw\b|iptables|nft\b'; then
	badln "a node/transport verb references live node state (params/sing-box config/units/firewall) — it must only touch the descriptor"
else
	ok "the verbs touch only the registry + the node.config.json descriptor (no live state)"
fi

# 4. the descriptor write is 0600 (node-local, not world-readable), if the writer verbs write at all.
if printf '%s' "$block" | grep -qE 'os\.WriteFile'; then
	if printf '%s' "$block" | grep -E 'os\.WriteFile' | grep -qvE '0o?600'; then
		badln "a descriptor write does not use 0600 (the node-local profile must not be world-readable)"
	else
		ok "the descriptor write uses 0600 (node-local)"
	fi
fi

# 5. the verbs are dispatched (the gate guards live code).
grep -qE '^[[:space:]]*case "node":' "$MAIN" && grep -qE '^[[:space:]]*case "transport":' "$MAIN" \
	&& ok "the node + transport commands are dispatched" \
	|| badln "the node/transport commands are not both dispatched in main.go run()"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the node/transport CLI verbs edit intent only and never actuate a live node.\n'
	exit 0
fi
printf 'FAIL: a node/transport CLI verb actuates or mutates live node state — see above.\n' >&2
exit 1
