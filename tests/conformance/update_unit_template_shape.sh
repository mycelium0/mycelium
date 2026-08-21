#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# update_unit_template_shape.sh — conformance: the shipped mycelium-update unit TEMPLATE stays
# node-agnostic and signature-gated, so the file an operator copies to a node can never itself carry
# an unauthenticated auto-pull, a node identity, or a pre-armed [Install] wiring.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   `--insecure-no-verify` makes verify_signed_ref (control/lib/nb_update_apply.sh) return BEFORE it
#   checks anything — ADR-0015 names that check as THE provenance gate. The update unit runs as root,
#   on a timer, and its success path merges fetched code into the canonical checkout, installs
#   tooling from it and compiles the spine. So a unit file carrying that flag is one `systemctl
#   enable` away from a periodic unauthenticated root-level auto-pull — and the person who types the
#   enable is usually not the person who added the flag.
#
#   This is not hypothetical. On 2026-07-27 two live nodes were found carrying a hand-edited copy of
#   this unit whose ExecStart had grown `--insecure-no-verify` plus a literal node address and a
#   client list. It survived weeks because NOTHING looks at a deployed unit: no code path in this
#   repo installs, reconciles or removes mycelium-update.{service,timer} (they are documentation-
#   grade templates the operator copies by hand — RP-0003 W3), and `--node-apply` never touches
#   /etc/systemd/system. The drift could only spread by being copied from the template, so the
#   template is the one place a repo-scoped gate can stand.
#
# WHAT THIS CHECKS (offline, inspect-only, over the TRACKED tree)
#   1. ExecStart is EXACTLY the node-agnostic default and appears exactly once — no appended flags.
#   2. Neither unit file contains `--insecure-no-verify`.
#   3. Neither unit file contains a node-specific pin: no IPv4/IPv6 literal, no --node-address,
#      no --clients, no --allowed-signers path. (This is the assertion that would have caught the
#      deployed shape had it ever been committed.)
#   4. No tracked code file (.sh/.yml/.yaml/.j2/.go) references `mycelium-update` — i.e. the
#      "no code path owns this unit" contract holds. If someone lands an owning verb, they must come
#      here and update this gate deliberately, rather than the contract rotting silently.
#   5. The timer's [Install] is WantedBy=timers.target and the service's is
#      WantedBy=multi-user.target, so a plain `cp` yields `disabled` — installing is never arming.
#
# WHAT THIS DELIBERATELY DOES NOT CHECK
#   That the timer is DISARMED on a node. Unlike the measure/rotate timers (whose contract really is
#   ships-disabled — see measure_daemon_ships_disabled.sh), this timer's documented Definition of
#   Done is being ACTIVE on every node once the signed-release pipeline exists
#   (docs/proposals/0003-network-rollout-signed-self-updating.md, "Definition of Done"). A
#   ships-disarmed assertion here would encode a rule the project does not hold.
#
# HONEST SCOPE LIMIT
#   This gate passes today and would have passed on 2026-07-01: the template has always been clean.
#   It is a REGRESSION GUARD on the source of copies, not a detector of the defect that was actually
#   found — that lived entirely on-node, where no offline gate can see. The on-node counterpart is
#   scripts/update_unit_drift_drill.sh, which diffs a deployed unit against this template. Say so
#   rather than let a green gate imply coverage it does not have.
#
# Exit: 0 = template is node-agnostic and unarmed-by-default, 1 = a violation, 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'update_unit_template_shape: cannot resolve repo root\n' >&2; exit 2; }

SVC="$REPO_ROOT/infra/systemd/mycelium-update.service"
TMR="$REPO_ROOT/infra/systemd/mycelium-update.timer"

# The one ExecStart the template may carry. Node-agnostic by construction: no signer path (that is
# appended per node, out of band), no ref pin, no address, no client list.
EXPECT_EXEC='ExecStart=/opt/mycelium/scripts/node-bootstrap.sh --update'

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== mycelium-update unit template shape ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# Fail CLOSED on a missing template: a deleted unit must break this gate, never silently pass it.
for f in "$SVC" "$TMR"; do
	[ -f "$f" ] || { printf 'FAIL: unit template missing: %s\n' "${f#"$REPO_ROOT"/}" >&2; exit 2; }
	[ -r "$f" ] || { printf 'FAIL: unit template unreadable: %s\n' "${f#"$REPO_ROOT"/}" >&2; exit 2; }
done

# Directive lines only: strip comments so the prose in these headers (which necessarily NAMES the
# forbidden flag in order to warn about it) can neither trip a check nor mask a real directive.
svc_d="$(grep -vE '^[[:space:]]*#' "$SVC")"
tmr_d="$(grep -vE '^[[:space:]]*#' "$TMR")"

# 1. ExecStart is exactly the node-agnostic default, exactly once.
exec_lines="$(printf '%s\n' "$svc_d" | grep -cE '^[[:space:]]*ExecStart=' || true)"
exec_line="$(printf '%s\n' "$svc_d" | grep -E '^[[:space:]]*ExecStart=' | head -1 | sed 's/[[:space:]]*$//')"
if [ "$exec_lines" != "1" ]; then
	bad "the service template has $exec_lines ExecStart= lines (expected exactly 1) — a second ExecStart is a second, unreviewed command run as root"
elif [ "$exec_line" = "$EXPECT_EXEC" ]; then
	ok "ExecStart is exactly the node-agnostic default"
else
	bad "ExecStart has drifted from the node-agnostic default."
	bad "  expected: $EXPECT_EXEC"
	bad "  found:    $exec_line"
	bad "  -> per-node arguments (signer path, --repo-ref, address, clients) are appended ON THE NODE, never shipped in the template."
fi

# 2. The provenance-bypass flag appears in NO unit template, armed or not.
for pair in "service:$svc_d" "timer:$tmr_d"; do
	name="${pair%%:*}"; body="${pair#*:}"
	if grep -q -- '--insecure-no-verify' <<<"$body" ; then
		bad "$name template carries --insecure-no-verify — it makes verify_signed_ref return before checking anything (ADR-0015's provenance gate), and an installed unit is one \`systemctl enable\` away from an unauthenticated root-level auto-pull"
	else
		ok "$name template does not carry --insecure-no-verify"
	fi
done

# 3. No node-specific pin. The template must be copyable to ANY node unmodified.
# HERE-STRINGS, not `printf … | grep -q … && pin_hit=…`. Under the `pipefail` set above that shape is a
# race that fails OPEN here: `grep -q` exits on the first match and closes the pipe, `printf` can die of
# SIGPIPE (141), pipefail reports the pipeline as failed even though the pattern MATCHED, the `&&` does
# not fire — and the pin goes UNRECORDED, so the gate passes on a template it should reject. The same
# shape produced a ~5-in-40 flaky FAILURE in node_two_hop_failclosed; here it would have been a silent
# miss instead, which is worse. Both variables are fed as one string so a single here-string covers both.
both="$svc_d
$tmr_d"
pin_hit=""
grep -qE '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' <<<"$both" && pin_hit="$pin_hit IPv4-literal"
grep -qE '([0-9a-fA-F]{1,4}:){3,}[0-9a-fA-F]{0,4}'          <<<"$both" && pin_hit="$pin_hit IPv6-literal"
grep -q -- '--node-address'                                  <<<"$both" && pin_hit="$pin_hit --node-address"
grep -q -- '--clients'                                       <<<"$both" && pin_hit="$pin_hit --clients"
grep -q -- '--allowed-signers'                               <<<"$both" && pin_hit="$pin_hit --allowed-signers"
if [ -n "$pin_hit" ]; then
	bad "the template carries node-specific value(s):$pin_hit — a committed node address is an OPSEC leak, and a committed signer path or client list makes the shipped template unusable on any other node"
else
	ok "the template is node-agnostic (no address literal, no --node-address/--clients/--allowed-signers)"
fi

# 4. The "no code path owns this unit" contract. Scoped to git ls-files so an untracked local file
#    cannot make this red locally and green in CI. (That scoping bit me the other way round on first
#    run: the drill below was still untracked, so the sweep did not see it and the gate passed
#    locally, then failed in CI the moment it was committed. Hence the ALLOWLIST is explicit and its
#    read-only claim is CHECKED, not asserted — an exclusion nobody verifies is just a hole.)
READONLY_INSPECTORS="scripts/update_unit_drift_drill.sh"
owners=""
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case "$f" in infra/systemd/*|docs/*|tests/conformance/update_unit_template_shape.sh) continue ;; esac
		case " $READONLY_INSPECTORS " in *" $f "*) continue ;; esac
		case "$f" in *.sh|*.yml|*.yaml|*.j2|*.go) ;; *) continue ;; esac
		grep -vE '^[[:space:]]*(#|//)' "$REPO_ROOT/$f" 2>/dev/null | grep -q 'mycelium-update' && owners="$owners $f"
	done <<EOF
$(git -C "$REPO_ROOT" ls-files 2>/dev/null)
EOF
	if [ -n "$owners" ]; then
		bad "tracked code now references mycelium-update:$owners"
		bad "  -> if you have given these units a real owner (an install/remove verb), that is a GOOD change — but update this gate and the template header deliberately, and add the reconcile-on-apply behaviour the other owned units have."
	else
		ok "no tracked code path installs, edits or removes the unit (the hand-copy contract holds; RP-0003 W3)"
	fi

	# 4b. The allowlist is only sound while the allowlisted file really is read-only. A mutating
	#     systemctl verb at COMMAND position would make it an owner in disguise — and it would be
	#     invisible to check 4, since the allowlist skips it. Operator-guidance strings that merely
	#     NAME those commands (`crit "  systemctl disable --now …"`) do not start a line, so quoting
	#     advice stays legal while actually running it does not.
	for f in $READONLY_INSPECTORS; do
		if [ ! -f "$REPO_ROOT/$f" ]; then
			bad "allowlisted read-only inspector is missing: $f — remove it from READONLY_INSPECTORS or restore it (a stale allowlist silently widens the sweep's blind spot)"
			continue
		fi
		if grep -nE '^[[:space:]]*(sudo[[:space:]]+)?systemctl[[:space:]]+(enable|disable|start|stop|restart|mask|unmask|link|preset)' "$REPO_ROOT/$f" >/dev/null 2>&1; then
			bad "$f is allowlisted as READ-ONLY but invokes a mutating systemctl verb:"
			grep -nE '^[[:space:]]*(sudo[[:space:]]+)?systemctl[[:space:]]+(enable|disable|start|stop|restart|mask|unmask|link|preset)' "$REPO_ROOT/$f" | sed 's/^/          /'
			bad "  -> a drill that arms, disarms or masks the unit is an OWNER, and check 4 cannot see it because the allowlist skips it."
		else
			ok "$f is allowlisted and verified read-only (no mutating systemctl verb at command position)"
		fi
	done
else
	printf '  SKIP  not a git work tree — cannot scope the ownership sweep to tracked files\n'
fi

# 5. Installing is never arming: a plain `cp` must leave the timer DISABLED.
if grep -qE '^[[:space:]]*WantedBy=timers\.target' <<<"$tmr_d" ; then
	ok "timer [Install] is WantedBy=timers.target (a plain cp yields 'disabled', not 'enabled')"
else
	bad "the timer's [Install] is not WantedBy=timers.target — an unexpected install target can arm the timer as a side effect of copying it"
fi
if grep -qE '^[[:space:]]*WantedBy=multi-user\.target' <<<"$svc_d" ; then
	ok "service [Install] is WantedBy=multi-user.target"
else
	bad "the service's [Install] target changed — re-confirm that copying the unit cannot start it"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the mycelium-update unit template is not node-agnostic / signature-gated. This template is\n' >&2
	printf '      copied BY HAND onto nodes and nothing ever reconciles a deployed copy back to it, so a\n' >&2
	printf '      defect shipped here propagates silently and permanently.\n' >&2
	exit 1
fi
printf 'PASS: the update unit template is node-agnostic, carries no provenance bypass, and is unarmed on\n'
printf '      copy. Scope: the TEMPLATE only — deployed drift is caught by scripts/update_unit_drift_drill.sh.\n'
exit 0
