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

# ---------------------------------------------------------------------------
# THE DEPLOY VERB'S RESULTING POSTURE — driven, not grepped.
#
# This was two text greps asserting that the arm chain EXISTS. It therefore ratified whatever the chain
# happened to do, and what it happened to do was satisfy all three legs of the rotation triple gate in one
# command: --rotate-arm placed the node-local sentinel, and the loop unit's own ExecStart carries
# `--rotate --apply-rotation`, so a bare `fungi deploy` left a node that could promote a config unattended,
# with no prompt and no --yes. The greps could not see that, because existence is not posture.
#
# So: run the real script with a RECORDING STUB in place of node-bootstrap and assert the argv it produces.
# This works because fungi derives NODE_BOOTSTRAP from its own resolved path, so a copy in a temp dir finds
# the stub beside it. Offline, no root, nothing installed.
#
# THE INVARIANT, in three rows:
#   deploy                 -> detection comes up (--measure-enable, --rotate-enable-loop) and the sentinel
#                             (--rotate-arm) is NOT placed. The loop plans and refuses to promote.
#   deploy --auto-rotate   -> the sentinel IS placed. Unattended promotion is a deliberate act.
#   deploy --no-arm        -> none of the three.
# Plus: neither fungi-level flag may reach node-bootstrap, which dies on an unknown flag — forwarding one
# would abort the entire deploy, and that is the most likely way this breaks.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.fungi.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts"
cp "$F" "$WORK/scripts/fungi"
cat >"$WORK/scripts/node-bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MYC_ARGV_LOG:?}"
exit 0
STUB
chmod +x "$WORK/scripts/node-bootstrap.sh" "$WORK/scripts/fungi"

drive() { # drive <label> <args...>  -> echoes the recorded argv lines, one invocation per line
	local lbl="$1"; shift
	: >"$WORK/argv.$lbl"
	MYC_ARGV_LOG="$WORK/argv.$lbl" bash "$WORK/scripts/fungi" deploy "$@" >/dev/null 2>&1
	cat "$WORK/argv.$lbl"
}
# saw PATTERN HAYSTACK. The `--` guard belongs INSIDE, next to grep — passing it at the call site
# makes it the pattern and every row silently tests the wrong thing.
saw() { printf '%s\n' "$2" | grep -qF -- "$1"; }

for row in "default::0" "auto:--auto-rotate:1" "noarm:--no-arm:2"; do
	lbl="${row%%:*}"; rest="${row#*:}"; flag="${rest%%:*}"; want="${rest##*:}"
	out="$(drive "$lbl" ${flag:+$flag})"
	case "$want" in
		0) # detection up, sentinel NOT placed
			if saw '--measure-enable' "$out" && saw '--rotate-enable-loop' "$out" && ! saw '--rotate-arm' "$out"; then
				ok "deploy (default): detection comes up and the rotate-live sentinel is NOT placed"
			else
				badln "deploy (default) produced the wrong posture. Expected --measure-enable and --rotate-enable-loop WITHOUT --rotate-arm; got: $(printf '%s' "$out" | tr '\n' '|'). A default that places the sentinel means one command yields a node that promotes configs unattended — the loop's unit already carries --apply-rotation, so the sentinel is the only thing standing between an enabled loop and live promotion."
			fi ;;
		1) # sentinel placed on explicit opt-in
			if saw '--rotate-arm' "$out" && saw '--measure-enable' "$out" && saw '--rotate-enable-loop' "$out"; then
				ok "deploy --auto-rotate: the sentinel IS placed (unattended promotion is an explicit act)"
			else
				badln "deploy --auto-rotate did not place the sentinel; got: $(printf '%s' "$out" | tr '\n' '|')"
			fi ;;
		2) # nothing armed
			if ! saw '--measure-enable' "$out" && ! saw '--rotate-arm' "$out" && ! saw '--rotate-enable-loop' "$out"; then
				ok "deploy --no-arm: none of the three (serve only)"
			else
				badln "deploy --no-arm still armed something; got: $(printf '%s' "$out" | tr '\n' '|')"
			fi ;;
	esac
	# The fungi-level flags must be CONSUMED. node-bootstrap dies on an unknown flag.
	if [ -n "$flag" ] && saw "$flag" "$out"; then
		badln "deploy forwarded the fungi-level flag '$flag' to node-bootstrap, which dies on an unrecognised flag — the whole deploy aborts"
	fi
done
[ -n "$(drive base)" ] && ok "the recording stub is reached at all (the harness is not vacuous)" \
	|| badln "the stub recorded nothing — fungi did not invoke node-bootstrap, so every row above is vacuous"

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
