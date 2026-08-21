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
# The migrate/rotate MACHINERY lives in _awg_apply_dialect; regen_awg_dialect / rotate_awg_dialect are thin
# wrappers that call it at a chosen epoch. The fail-safe properties are therefore asserted on that body.
body="$(awk '/^_awg_apply_dialect\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
[ -n "$body" ] || { bad "_awg_apply_dialect() not found in nb_render_awg.sh"; printf '\n-- Result --\nFAIL\n' >&2; exit 1; }
grep -qE '^regen_awg_dialect\(\)' "$AWG" || bad "regen_awg_dialect() not found in nb_render_awg.sh"
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
if grep -qE 'cp -a "\$bak/awg0.conf" "\$awg_conf"' <<<"$body" \
	&& grep -qE 'restart awg-quick@awg0' <<<"$body" \
	&& grep -qiE 'RESTOR' <<<"$body" ; then
	ok "restore-on-failure path present (cp backup back + restart awg0 + die)"
else
	bad "no restore-on-failure path (a failed bring-up must restore the backup)"
fi

# 3) SURGICAL: _awg_swap_dialect seds ONLY the 9 dialect keys, never a key/address/peer field.
if grep -qE 's/\^H1 = ' <<<"$swap" && grep -qE 's/\^Jc = ' <<<"$swap" ; then
	ok "the swap rewrites the dialect lines (Jc.., H1..)"
else
	bad "the swap does not target the dialect lines as expected"
fi
if grep -qiE 's/\^?(PrivateKey|PublicKey|PresharedKey|AllowedIPs|Address|Endpoint)' <<<"$swap" ; then
	bad "the swap seds a KEY/ADDRESS/PEER field — it must ONLY touch the 9 dialect lines"
else
	ok "the swap never seds a key/address/peer field (surgical)"
fi
# before+after 9-line sanity present.
if grep -qE '_awg_dialect_lines' <<<"$swap" && grep -qE '\-eq 9' <<<"$swap" ; then
	ok "the swap verifies exactly 9 dialect lines (refuses a non-standard config; post-swap sanity)"
else
	bad "the swap does not verify the 9-dialect-line invariant before/after"
fi

# 4) KEY-PRESERVING: regen never regenerates identity (no render_awg0 / awg genkey|genpsk CALL in its body).
#    Match CODE only — strip full-line comments so an accurate prose mention (e.g. "what render_awg0 would
#    produce") does not false-trigger; a real call is on a non-comment line.
if printf '%s\n' "$body" | grep -vE '^[[:space:]]*#' | grep -qE 'render_awg0|awg genkey|awg genpsk|awg pubkey'; then
	bad "regen_awg_dialect regenerates identity (render_awg0 / awg genkey|genpsk|pubkey) — it must PRESERVE keys"
else
	ok "regen preserves keys (no render_awg0 / awg genkey|genpsk|pubkey call — only the dialect changes)"
fi

# 5) DRY-RUN: a preview branch returns without mutating.
if grep -qE '\[ "\$DRY_RUN" -eq 1 \]' <<<"$body" && grep -qE '\[dry-run\]' <<<"$body" ; then
	ok "a --dry-run branch previews without mutating"
else
	bad "no --dry-run preview branch in the apply machinery"
fi

# 6) WIRED: --awg-regen -> MODE=awg-regen -> regen_awg_dialect; --awg-rotate -> rotate_awg_dialect.
if grep -qE '\-\-awg-regen\)[[:space:]]*MODE="awg-regen"' "$NB" && grep -qE '^\s*awg-regen\)[[:space:]]*regen_awg_dialect' "$NB"; then
	ok "--awg-regen is parsed to MODE=awg-regen and dispatched to regen_awg_dialect"
else
	bad "--awg-regen is not wired (arg-parse -> MODE -> dispatch)"
fi
if grep -qE '\-\-awg-rotate\)[[:space:]]*MODE="awg-rotate"' "$NB" && grep -qE '^\s*awg-rotate\)[[:space:]]*rotate_awg_dialect' "$NB"; then
	ok "--awg-rotate is parsed to MODE=awg-rotate and dispatched to rotate_awg_dialect"
else
	bad "--awg-rotate is not wired (arg-parse -> MODE -> dispatch)"
fi

# --- ROTATION (epoch) properties -------------------------------------------------------------------
rot="$(awk '/^rotate_awg_dialect\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
apply="$(awk '/^_awg_apply_dialect\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
der="$(awk '/^derive_awg_dialect\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
[ -n "$rot" ]   || bad "rotate_awg_dialect() not found"
[ -n "$apply" ] || bad "_awg_apply_dialect() (shared migrate/rotate machinery) not found"

# 7) EPOCH-0 COMPATIBILITY: epoch 0 must derive from the key ALONE, so introducing rotation reproduces an
#    already-migrated node's original dialect byte-for-byte.
if grep -qE '\[ "\$epoch" -eq 0 \] \|\| input=' <<<"$der" ; then
	ok "epoch 0 derives from the key alone (already-migrated nodes keep their dialect)"
else
	bad "derive_awg_dialect does not preserve epoch-0 behaviour (would change existing nodes' dialects)"
fi

# 8) ROTATION ACTUALLY CHANGES THE DIALECT: rotate bumps the epoch (cur + 1).
if grep -qE 'next=\$\(\( cur \+ 1 \)\)' <<<"$rot" && grep -qE '_awg_apply_dialect "\$next"' <<<"$rot" ; then
	ok "rotate bumps the epoch (cur+1) and applies at the new epoch (a genuinely fresh dialect)"
else
	bad "rotate does not bump the epoch — it would be idempotent, not a rotation"
fi

# 9) ROTATION IS KEY/PEER-PRESERVING: rotate never regenerates identity (code lines only).
if printf '%s\n' "$rot" | grep -vE '^[[:space:]]*#' | grep -qE 'awg genkey|awg genpsk|render_awg0'; then
	bad "rotate_awg_dialect touches identity (genkey/genpsk/render_awg0) — rotation must only change the dialect"
else
	ok "rotate preserves keys + peers (only the dialect changes)"
fi

# 10) L7 SELFTEST IS FAIL-CLOSED: a DEAD probe rolls back (config AND epoch), not just warns.
if grep -qE 'measure_l7_probe_amneziawg' <<<"$apply" \
	&& grep -qE '_awg_rollback "the L7 selftest' <<<"$apply" ; then
	ok "the L7 handshake selftest is fail-closed (a DEAD data-plane rolls back)"
else
	bad "the L7 selftest does not roll back on a DEAD data-plane (a node could sit on an unservable dialect)"
fi

# 11) ROLLBACK REVERTS THE EPOCH in lockstep with the config (no epoch/config skew).
if grep -qE '_awg_rollback\(\)' <<<"$apply" \
	&& grep -qE 'printf .%s\\n. "\$prev_epoch" > "\$\(_awg_epoch_file\)"' <<<"$apply" ; then
	ok "rollback reverts the epoch together with the config (no epoch/config skew)"
else
	bad "rollback does not revert the epoch — a failed rotation would leave epoch/config skewed"
fi

# 12) A RE-RENDER RESPECTS THE EPOCH: render_awg0 derives at the current epoch, so a rotated node does not
#     silently revert to its epoch-0 dialect on the next render.
r0="$(awk '/^render_awg0\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$AWG")"
if grep -qE 'derive_awg_dialect "\$spriv" "\$\(_awg_read_epoch\)"' <<<"$r0" ; then
	ok "render_awg0 derives at the current epoch (a rotated node keeps its rotated dialect on re-render)"
else
	bad "render_awg0 ignores the rotation epoch — a re-render would revert a rotated node's dialect"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the --awg-regen migration action is not provably fail-safe / surgical.\n' >&2
	exit 1
fi
printf 'PASS: --awg-regen is backup-first, restore-on-failure, surgical (9 dialect lines only), key-preserving, dry-run-able.\n'
exit 0
