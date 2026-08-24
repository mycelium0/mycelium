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

# ---------------------------------------------------------------------------
# A CONVERGE VERB MUST NOT BE A CHANNEL TO EVERY OTHER MODE (Audit-0011 #7).
#
# `fungi deploy` used to forward every unrecognised argument straight to node-bootstrap.sh, which parses
# each flag as a whole-run MODE, last-wins. So `fungi deploy --revoke alice` REVOKED A CLIENT and never
# converged — the verb the operator typed was silently replaced by a different one, and deploy reported
# success. Driven, because an allow-list that is grepped is an allow-list nobody proved rejects anything.
#
# Each row uses a mode flag that takes NO argument. An earlier draft used `--revoke alice`, and under a
# mutation that removed the allow-list the row still went green — because the bare `alice` then tripped a
# DIFFERENT guard ("unexpected argument"). Same exit code, unrelated cause: the row was measuring the
# wrong refusal. A valueless flag has nowhere else to fail.
printf '\n'
for mode in --rotate --node-apply --rotate-arm --update; do
	: >"$WORK/argv.mode"
	MYC_ARGV_LOG="$WORK/argv.mode" bash "$WORK/scripts/fungi" deploy "$mode" >/dev/null 2>&1
	rc=$?
	n="$(wc -l <"$WORK/argv.mode" | tr -d ' ')"
	if [ "$rc" -ne 0 ] && [ "$n" -eq 0 ]; then
		ok "deploy $mode: refused (rc=$rc), actuator invoked 0 times"
	else
		badln "\`fungi deploy $mode\` exited $rc having invoked the actuator $n time(s): $(tr '\n' '|' <"$WORK/argv.mode"). node-bootstrap parses $mode as a whole-run MODE, last-wins, so this silently runs a DIFFERENT verb than the operator typed while deploy reports success. Measured with --revoke: it revoked a client and never converged."
	fi
done
# ...while a legitimate converge-shaping flag still gets through. An allow-list that rejects everything
# is not a fix, and this is the row that would catch it.
: >"$WORK/argv.legit"
MYC_ARGV_LOG="$WORK/argv.legit" bash "$WORK/scripts/fungi" deploy --no-harden >/dev/null 2>&1
if grep -qF -- '--no-harden' "$WORK/argv.legit"; then
	ok "and a legitimate converge-shaping flag (--no-harden) still reaches the actuator"
else
	badln "the allow-list also blocked --no-harden, which shapes the converge and selects no mode. An allow-list that refuses valid input is a different outage, not a fix."
fi

# ---------------------------------------------------------------------------
# EVERY VERB NAMED IN A FALLBACK STRING IS DISPATCHED BY THE TOOL THAT STRING NAMES (Audit-0011 #8).
#
# SECURITY.md and the bug-report template both told reporters to run `myceliumctl diag collect`. Nothing
# puts any `myceliumctl` on $PATH; the only file of that name on a node is the SHELL tool, whose dispatch
# has no `diag` verb at all. So the PII redactor built specifically to keep keys, peer addresses and
# client names out of a public issue was unreachable by the person it protects, and the path of least
# resistance was pasting raw journald into a public issue.
printf '\n'
SHELL_CTL="$REPO_ROOT/control/myceliumctl"
# DERIVE the verb list from the documents themselves rather than hard-coding it. A hand-maintained list
# would only ever contain the verbs someone remembered to add — and the whole finding is that nobody
# noticed `myceliumctl diag collect` had no dispatch behind it for the life of the feature. Anything an
# operator-facing document tells a person to type is in scope, automatically, including the next one.
DOCS="$REPO_ROOT/SECURITY.md $REPO_ROOT/docs/THREAT-MODEL.md $REPO_ROOT/QUICKSTART.md"
[ -d "$REPO_ROOT/.github/ISSUE_TEMPLATE" ] && DOCS="$DOCS $(find "$REPO_ROOT/.github/ISSUE_TEMPLATE" -type f 2>/dev/null | tr '\n' ' ')"
# shellcheck disable=SC2086  # DOCS is a deliberate word-split list of paths, none containing spaces
verbs="$(grep -rhoE '`?(fungi|myceliumctl) [a-z][a-z-]+' $DOCS 2>/dev/null \
	| sed 's/^`//; s/^[a-z]* //' | sort -u)"
if [ -z "$verbs" ]; then
	printf '  SKIP  no operator-facing doc names a fungi/myceliumctl verb; nothing to reach.\n'
fi
# Strip comments ONCE, into a variable. Piping into `grep -q` inside the loop made printf write into a
# pipe grep had already closed on its first match — a "Broken pipe" line per verb, in a gate whose job is
# to be read.
F_NOCOMMENT="$(sed 's/[[:space:]]#.*$//' "$F")"
for verb in $verbs; do
	if printf '%s\n' "$F_NOCOMMENT" | grep -qE "^[[:space:]]*([a-z-]+\|)*${verb}(\|[a-z-]+)*\)"; then
		ok "\`fungi $verb\` — named in a doc, dispatched by fungi"
	elif [ -f "$SHELL_CTL" ] && grep -qE "^[[:space:]]*([a-z-]+\|)*${verb}(\|[a-z-]+)*\)" "$SHELL_CTL"; then
		ok "\`$verb\` — named in a doc, dispatched by control/myceliumctl"
	else
		badln "an operator-facing document tells a reader to run a '$verb' verb that NEITHER scripts/fungi NOR control/myceliumctl dispatches. Measured instance: SECURITY.md and the bug-report template both said \`myceliumctl diag collect\`, nothing puts any myceliumctl on \$PATH, and the shell tool of that name has no diag verb — so the PII redactor was unreachable by the person filing the report and raw journald, which carries client source addresses and key material, was the path of least resistance."
	fi
done
# And the docs must point at a tool that exists on a node. `myceliumctl` is not on $PATH anywhere.
docs_ref="$(grep -rn 'myceliumctl diag' "$REPO_ROOT/SECURITY.md" "$REPO_ROOT/.github/ISSUE_TEMPLATE/" "$REPO_ROOT/docs/THREAT-MODEL.md" 2>/dev/null | head -3)"
if [ -z "$docs_ref" ]; then
	ok "no operator-facing doc instructs a reporter to run a \`myceliumctl\` that is not on \$PATH"
else
	badln "these still tell a reporter to run \`myceliumctl diag\`, and nothing installs a \`myceliumctl\` on \$PATH (the Go binary is myceliumctl-go under TOOLING_DIR): $(printf '%s' "$docs_ref" | tr '\n' '|' | cut -c1-220). Use \`fungi diag\`."
fi

# EVERY FLAG A DOCUMENT TELLS THE OPERATOR TO PASS MUST BE ACCEPTED BY THE TOOL IT NAMES.
#
# The verb check above has a twin defect, and the twin shipped: the deploy allow-list (added to stop
# `fungi deploy --revoke alice` silently running a different verb) omitted three flags the documentation
# instructs operators to pass.
#
#   * QUICKSTART "Covered architectures" tells every non-amd64/arm64 operator to pass --singbox-sha256
#     and --xray-sha256 explicitly. `fungi deploy` refused both. The one-command surface the document
#     teaches was unusable on the one architecture class the document singles out.
#   * --region-exclude is the ONLY input that changes what an AmneziaWG client config ROUTES. Without it
#     compute_client_allowed (control/lib/nb_render_awg.sh) emits the safe-narrow default — tunnel ranges
#     only, deliberately, because we never silently full-tunnel. Measured on a live node: a served client
#     config carrying `AllowedIPs = 10.13.13.0/24`. That client completes a handshake, stays up on
#     PersistentKeepalive, and carries NOT ONE BYTE of user traffic. Every self-report is green.
#
# So: derive the flags from the documents, the same way the verbs above are derived. A hand-kept list
# would only ever hold the flags someone remembered, and the whole finding is that nobody remembered.
printf '\n'
qs="$REPO_ROOT/QUICKSTART.md"
if [ ! -f "$qs" ]; then
	printf '  SKIP  QUICKSTART.md not found; the documented-flag check did not run.\n'
else
	# Flags named in backticks or fences anywhere in QUICKSTART. Exclude the two `fungi`-LEVEL flags the
	# wrapper consumes itself, and the flags the doc names only to say they belong to another verb.
	doc_flags="$(grep -ohE -- '--[a-z][a-z0-9-]+' "$qs" | sort -u \
		| grep -vxE -- '--auto-rotate|--no-arm|--repo-ref|--allowed-signers|--depth|--branch|--tag|--signer|--engine|--params|--state|--out|--update|--node-apply|--rotate-arm|--transport|--domain|--mode|--ack')"
	W2="$WORK/flags"; mkdir -p "$W2/scripts"
	cp "$F" "$W2/scripts/fungi"
	cat >"$W2/scripts/node-bootstrap.sh" <<'STUB2'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MYC_ARGV_LOG:?}"
exit 0
STUB2
	chmod +x "$W2/scripts/node-bootstrap.sh" "$W2/scripts/fungi"
	refused=""
	for fl in $doc_flags; do
		# Only judge flags scripts/node-bootstrap.sh actually accepts on the converge path. A flag the
		# actuator does not know is a documentation bug of a different kind, out of scope for this row.
		grep -qE "^[[:space:]]*(--[a-z0-9-]+\|)*${fl}\)" "$REPO_ROOT/scripts/node-bootstrap.sh" 2>/dev/null || continue
		grep -qE "^[[:space:]]*${fl}\)" "$REPO_ROOT/scripts/node-bootstrap.sh" 2>/dev/null \
			|| grep -q -- "$fl)" "$REPO_ROOT/scripts/node-bootstrap.sh" 2>/dev/null || continue
		# Mode flags must stay refused — that is the other half of this allow-list and is asserted above.
		case "$fl" in --revoke|--rotate*|--measure*|--update|--node-apply|--awg-*|--hy2-*|--reality-*) continue ;; esac
		# Try BOTH arities. A valueless flag given a value trips the "unexpected argument" guard, and a
		# value-taking flag given none trips the actuator's own `${2:?}` — either way the actuator is not
		# invoked, and a row that only tried one form would report a refusal that is really its own
		# mistake. (It did, on the first draft: --no-harden and --no-amneziawg, both allow-listed, both
		# reported as refused because the probe handed them an argument they do not take.)
		hit=0
		for form in "$fl" "$fl placeholder"; do
			: >"$W2/log"
			# shellcheck disable=SC2086  # deliberate split: the second form is flag + value
			MYC_ARGV_LOG="$W2/log" bash "$W2/scripts/fungi" deploy $form >/dev/null 2>&1
			[ -s "$W2/log" ] && { hit=1; break; }
		done
		[ "$hit" -eq 1 ] || refused="$refused $fl"
	done
	if [ -z "$refused" ]; then
		ok "every documented converge flag QUICKSTART names is accepted by \`fungi deploy\`"
	else
		badln "QUICKSTART tells the operator to pass these to \`fungi deploy\`, and the allow-list refuses them — the actuator is never invoked:$refused. scripts/node-bootstrap.sh accepts each one and none selects a mode, so refusing them breaks a documented path with no safety benefit. --singbox-sha256/--xray-sha256 are what QUICKSTART tells every non-amd64/arm64 operator to pass; --region-exclude is the only way to make an AmneziaWG client carry traffic at all."
	fi
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
