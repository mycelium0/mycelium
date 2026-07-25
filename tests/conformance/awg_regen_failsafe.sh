#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# awg_regen_failsafe.sh — conformance (Audit-0008 S1-4 migration): the `--awg-regen` action
# (regen_awg_dialect in control/lib/nb_render_awg.sh) swaps a LIVE node's AmneziaWG obfuscation dialect to
# the per-node derived one. Because it edits the live data-plane config, it MUST be fail-safe + surgical:
#   1. BACKUP-FIRST — it copies the live awg0.conf to a backup BEFORE any mutation.
#   2. RESTORE-ON-FAILURE — a bring-up failure restores the backup + restarts, then dies.
#   3. SURGICAL — the swap (_awg_swap_dialect) rewrites ONLY the 9 [Interface] obfuscation lines
#      (Jc/Jmin/Jmax/S1/S2/H1..H4); it never seds a key / address / peer line, and it verifies exactly 9
#      dialect lines both before and after (a non-standard/hand-tuned config is refused, not mangled).
#   4. KEY-PRESERVING — regen never calls render_awg0 / awg genkey / awg genpsk (no identity churn): the
#      node + every client keep their keys; only the dialect changes.
#   5. DRY-RUN — a --dry-run branch previews and returns without mutating.
#   6. WIRED — --awg-regen parses to MODE=awg-regen and dispatches to regen_awg_dialect.
#
# Structural (greps the committed source); no node required. Exit: 0 = fail-safe held, 1 = a property
# regressed, 2 = usage/precondition.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
AWG="$REPO_ROOT/control/lib/nb_render_awg.sh"
NB="$REPO_ROOT/scripts/node-bootstrap.sh"

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== awg-regen fail-safe / surgical migration check (Audit-0008 S1-4) ==\n'
[ -f "$AWG" ] || { printf 'FAIL: nb_render_awg.sh missing.\n' >&2; exit 2; }
[ -f "$NB" ]  || { printf 'FAIL: node-bootstrap.sh missing.\n' >&2; exit 2; }

# Extract the regen_awg_dialect body (from its def to the next top-level `}` at column 0).
body="$(awk '/^regen_awg_dialect\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
[ -n "$body" ] || { bad "regen_awg_dialect() not found in nb_render_awg.sh"; printf '\n-- Result --\nFAIL\n' >&2; exit 1; }
swap="$(awk '/^_awg_swap_dialect\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
[ -n "$swap" ] || bad "_awg_swap_dialect() not found in nb_render_awg.sh"

# 1) BACKUP-FIRST: a `cp -a "$awg_conf" "$bak/..."` backup appears BEFORE the first _awg_swap_dialect call.
bak_ln="$(printf '%s\n' "$body" | grep -nE 'cp -a "\$awg_conf" "\$bak/' | head -1 | cut -d: -f1)"
swap_ln="$(printf '%s\n' "$body" | grep -nE '_awg_swap_dialect "\$c"|for c in .*cfgs.*_awg_swap_dialect' | head -1 | cut -d: -f1)"
# the swap loop line:
swaploop_ln="$(printf '%s\n' "$body" | grep -nE 'do _awg_swap_dialect|_awg_swap_dialect "\$c"' | head -1 | cut -d: -f1)"
if [ -n "$bak_ln" ] && [ -n "$swaploop_ln" ] && [ "$bak_ln" -lt "$swaploop_ln" ]; then
	ok "backup (cp -a awg0.conf -> \$bak) happens BEFORE the dialect swap"
else
	bad "no backup-before-mutation ordering proven (backup line=$bak_ln, swap line=$swaploop_ln)"
fi

# 2) RESTORE-ON-FAILURE: the bring-up failure path restores the backup + restarts, then dies.
if printf '%s\n' "$body" | grep -qE 'cp -a "\$bak/awg0.conf" "\$awg_conf"' \
	&& printf '%s\n' "$body" | grep -qE 'restart awg-quick@awg0' \
	&& printf '%s\n' "$body" | grep -qiE 'RESTOR'; then
	ok "restore-on-failure path present (cp backup back + restart awg0 + die)"
else
	bad "no restore-on-failure path (a failed bring-up must restore the backup)"
fi

# 3) SURGICAL: _awg_swap_dialect seds ONLY the 9 dialect keys, never a key/address/peer field.
if printf '%s\n' "$swap" | grep -qE 's/\^H1 = ' && printf '%s\n' "$swap" | grep -qE 's/\^Jc = '; then
	ok "the swap rewrites the dialect lines (Jc.., H1..)"
else
	bad "the swap does not target the dialect lines as expected"
fi
if printf '%s\n' "$swap" | grep -qiE 's/\^?(PrivateKey|PublicKey|PresharedKey|AllowedIPs|Address|Endpoint)'; then
	bad "the swap seds a KEY/ADDRESS/PEER field — it must ONLY touch the 9 dialect lines"
else
	ok "the swap never seds a key/address/peer field (surgical)"
fi
# before+after 9-line sanity present.
if printf '%s\n' "$swap" | grep -qE '_awg_dialect_lines' && printf '%s\n' "$swap" | grep -qE '\-eq 9'; then
	ok "the swap verifies exactly 9 dialect lines (refuses a non-standard config; post-swap sanity)"
else
	bad "the swap does not verify the 9-dialect-line invariant before/after"
fi

# 4) KEY-PRESERVING: regen never regenerates identity (no render_awg0 / awg genkey|genpsk in its body).
if printf '%s\n' "$body" | grep -qE 'render_awg0|awg genkey|awg genpsk|awg pubkey'; then
	bad "regen_awg_dialect regenerates identity (render_awg0 / awg genkey|genpsk|pubkey) — it must PRESERVE keys"
else
	ok "regen preserves keys (no render_awg0 / awg genkey|genpsk|pubkey — only the dialect changes)"
fi

# 5) DRY-RUN: a preview branch returns without mutating.
if printf '%s\n' "$body" | grep -qE '\[ "\$DRY_RUN" -eq 1 \]' && printf '%s\n' "$body" | grep -qE 'dry-run.*awg-regen|\[dry-run\]'; then
	ok "a --dry-run branch previews without mutating"
else
	bad "no --dry-run preview branch in regen_awg_dialect"
fi

# 6) WIRED: --awg-regen -> MODE=awg-regen -> regen_awg_dialect.
if grep -qE '\-\-awg-regen\)[[:space:]]*MODE="awg-regen"' "$NB" && grep -qE '^\s*awg-regen\)[[:space:]]*regen_awg_dialect' "$NB"; then
	ok "--awg-regen is parsed to MODE=awg-regen and dispatched to regen_awg_dialect"
else
	bad "--awg-regen is not wired (arg-parse -> MODE -> dispatch)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the --awg-regen migration action is not provably fail-safe / surgical.\n' >&2
	exit 1
fi
printf 'PASS: --awg-regen is backup-first, restore-on-failure, surgical (9 dialect lines only), key-preserving, dry-run-able.\n'
exit 0
