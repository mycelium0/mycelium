#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fungi_scoped.sh — conformance (RP-0011 chunk C-4): scripts/fungi is a SCOPED orchestration-only
# entrypoint. It is the operator's one-command surface, but it must NOT become a second, ungoverned
# apply path that bypasses node-bootstrap's fail-closed render -> validate -> promote -> rollback spine.
# Two sections:
#   (A) ACTUATION SCOPED — the actuating verbs (deploy/update/apply) actuate ONLY by invoking
#       scripts/node-bootstrap.sh (update/apply exec it; deploy SEQUENCES it — converge, then the explicit
#       --measure-enable/--rotate-arm/--rotate-enable-loop arm dispatches, so one command self-arms through
#       the governed spine); fungi itself runs NO service-mutating command (systemctl start/stop/restart/
#       reload/enable/disable/mask), NO engine run/check, and writes NO live config.
#   (B) ORCHESTRATION ONLY — fungi defines NO control logic: no config render/validate/promote/rollback,
#       no `sing-box check`, no jq-driven config mutation. It sequences + delegates; `status` is read-only.
# OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = fungi stays scoped + orchestration-only, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'fungi_scoped: cannot resolve repo root\n' >&2; exit 2; }
F="$REPO_ROOT/scripts/fungi"
[ -f "$F" ] || { printf 'fungi_scoped: missing %s\n' "$F" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== fungi is a scoped, orchestration-only entrypoint (RP-0011 C-4) ==\n'

# ---- (A) actuation scoped ----------------------------------------------------------------------
# the three actuating verbs delegate to node-bootstrap.sh (the fail-closed actuator)
for v in deploy update apply; do
	grep -qE "^[[:space:]]*$v\)" "$F" && grep -qE '"\$NODE_BOOTSTRAP"' "$F" \
		&& ok "verb '$v' actuates via \$NODE_BOOTSTRAP" \
		|| badln "verb '$v' does not delegate actuation to node-bootstrap"
done

# fungi must run NO service-MUTATING systemctl command (read verbs is-active/show/list-unit-files are fine)
if grep -qE 'systemctl[[:space:]]+(start|stop|restart|reload|enable|disable|mask|daemon-reload)' "$F"; then
	badln "fungi runs a service-MUTATING systemctl command — actuation must go through node-bootstrap"
else
	ok "no service-mutating systemctl in fungi (status is read-only: is-active/show/list-unit-files)"
fi

# fungi must not run an engine directly, nor write a live config
if grep -qE 'sing-box[[:space:]]+(run|check)|xray[[:space:]]+run|/usr/local/etc|/etc/sing-box|sing-box/config|>[[:space:]]*"?\$?SINGBOX_CONFIG' "$F"; then
	badln "fungi runs an engine directly or writes a live config — that belongs to node-bootstrap"
else
	ok "fungi runs no engine directly and writes no live config"
fi

# ---- (B) orchestration only --------------------------------------------------------------------
# no render/validate/promote/rollback control logic of its own
if grep -qE 'render_candidate|promote_config|rollback_config|validate_config|apply_singbox|write_params|jq[[:space:]].*\.inbounds' "$F"; then
	badln "fungi embeds render/validate/promote/config-mutation logic — it must only sequence + delegate"
else
	ok "fungi embeds no render/validate/promote/rollback logic (delegates to the spine)"
fi

# the actuators are reached ONLY by delegating to node-bootstrap. Every "$NODE_BOOTSTRAP" reference is
# either an exec (the single-passthrough verbs update/apply) or a direct call (the deploy verb legitimately
# SEQUENCES node-bootstrap sub-commands: converge, then the explicit --measure-enable/--rotate-arm/
# --rotate-enable-loop arm dispatches). Inlined service/engine/config actuation — the thing that would make
# fungi a second ungoverned apply path — is forbidden by the checks ABOVE; here we only reject a reference
# that is NOT a node-bootstrap invocation or the existence guard.
badref="$(grep -E '"\$NODE_BOOTSTRAP"' "$F" \
	| grep -vE 'exec "\$NODE_BOOTSTRAP"|"\$NODE_BOOTSTRAP" \$\{deploy_args|"\$NODE_BOOTSTRAP" "\$@"|\[ -x "\$NODE_BOOTSTRAP" \]|NODE_BOOTSTRAP=' || true)"
[ -z "$badref" ] \
	&& ok "every node-bootstrap reference is a delegating invocation or the guard (deploy may sequence arm dispatches)" \
	|| badln "a node-bootstrap reference is neither a delegating invocation nor the guard: $(printf '%s' "$badref" | tr '\n' '|')"

# the deploy verb's self-arm goes through the EXPLICIT node-bootstrap arm dispatches (never a systemctl or
# service mutation inside fungi) — pins that self-arming still flows through the governed spine + the
# ships-disabled flags, so the ONE-command deploy cannot become an ungoverned arm path.
if grep -qE '"\$NODE_BOOTSTRAP".*--measure-enable' "$F"; then
	grep -qE '"\$NODE_BOOTSTRAP".*--rotate-enable-loop' "$F" \
		&& ok "deploy self-arms via node-bootstrap dispatches (--measure-enable + --rotate-arm + --rotate-enable-loop)" \
		|| badln "deploy references --measure-enable but not --rotate-enable-loop (incomplete arm chain)"
else
	ok "deploy does not self-arm here (serve-only wrapper) — no arm dispatch to pin"
fi

# plan delegates to the Go deploy-plan verb (pure preview), not to a live read
grep -qE 'deploy-plan' "$F" \
	&& ok "verb 'plan' delegates to myceliumctl deploy-plan (pure preview)" \
	|| badln "verb 'plan' does not delegate to deploy-plan"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: fungi actuates only via node-bootstrap, mutates no service/config itself, embeds no control logic.\n'
	exit 0
fi
printf 'FAIL: fungi is not properly scoped/orchestration-only.\n' >&2
exit 1
