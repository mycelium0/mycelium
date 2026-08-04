#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# rotate_rollback_executes.sh — conformance: RUN the rotation's rollback branch. Not read it — run it.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   rotate_apply_live's Phase C is the node's whole safety net for an unattended rotation: when the
#   promoted sibling does not come up, seven things have to happen in order, or the node is left serving a
#   config it already decided was bad —
#     1. rollback_config          restore the last-known-good bytes
#     2. revert_rotation_overlay  put operator-overrides.json back, or the next --update re-applies the
#                                 rotation that just failed
#     3. write_params             regenerate params from the reverted overlay
#     4. apply_singbox            restart onto the restored config
#     5. verify_post_apply        confirm the restored config is actually healthy
#     6. record_rotation_rollback spend the rollback budget and latch hold_until, so a node that cannot
#                                 rotate stops trying every 90 seconds
#     7. die                      fail closed
#   Every one of those had been read by a human and by inspect-only gates. NONE of them had ever been
#   EXECUTED — the branch is reached only when a live apply fails on a live node, and it never had. An
#   untested recovery path is the one thing worse than no recovery path: it is a recovery path everything
#   else is designed around.
#
#   It was untestable for a mechanical reason, now fixed: verify_post_apply lives in the entrypoint, and
#   the entrypoint's `exit 0` sat OUTSIDE the MYC_NB_NO_DISPATCH guard, so sourcing it to reach the
#   function killed the sourcing shell.
#
# WHAT IS REAL HERE, AND WHAT IS NOT — the distinction the claim rests on
#   REAL, executed as shipped: rotate_apply_live, promote_config, rollback_config,
#   persist_rotation_to_overlay, revert_rotation_overlay, persist_rotation_state(_preapply),
#   record_rotation_rollback (against a genuinely built Go spine), apply_singbox, verify_post_apply.
#   SUBSTITUTED, each for a stated reason that keeps it outside the claim:
#     * myceliumctl / sing-box  — external programs; stubs stand in as the candidate PRODUCER and the
#                                 schema validator. The rollback is what is under test, not the renderer.
#     * install_singbox_unit    — writes a HARDCODED /etc/systemd/system path (the one apply primitive
#                                 that is not variable-driven), so the fixture cannot contain it.
#     * write_params            — deliberately controlled, both polarities: one row exists precisely to
#                                 prove that its FAILURE does not skip steps 4-7.
#     * measure_l7_probe*       — advisory by construction (`|| warn`; they cannot change the verdict) and
#                                 they reach the network. Nothing in the claim depends on them.
#   Every path the executed primitives touch is asserted to resolve inside a throwaway root BEFORE the
#   first one runs; this gate executes `install`, `mv -f` and `rm -f` against those paths.
#
# THE CONTROL ROW IS LOAD-BEARING. Scenario E drives the SAME harness to a HEALTHY apply and requires no
# rollback at all. Without it every "the rollback ran" row above is equally consistent with a harness that
# makes everything fail — which is this project's own signature defect, a pass indistinguishable from
# "the code under test did not execute".
#
# Exit: 0 = the recovery path runs and is complete; 1 = it does not; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'rotate_rollback_executes: cannot resolve repo root\n' >&2; exit 2; }
ENTRY="$REPO_ROOT/scripts/node-bootstrap.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
for f in "$ENTRY" "$FIXTURE"; do
	[ -f "$f" ] || { printf 'rotate_rollback_executes: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'rotate_rollback_executes: jq required\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== rotation rollback: execute the recovery branch, and prove it is complete ==\n'

# The Go spine, for the REAL record_rotation_rollback. Without it that step degrades to a warning by
# design, and the budget/latch rows below would assert nothing — so they are SKIPPED rather than passed
# vacuously, and the skip is printed.
SPINE=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.rbk.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
if command -v go >/dev/null 2>&1 \
   && ( cd "$REPO_ROOT" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
        go build -o "$WORK/myceliumctl-go" ./cmd/myceliumctl ) 2>"$WORK/build.err"; then
	SPINE="$WORK/myceliumctl-go"
else
	printf '  SKIP  no Go spine (jq-only lane): the rollback BUDGET/LATCH rows cannot run. The recovery\n'
	printf '        sequence rows below still execute in full; record_rotation_rollback degrades to a\n'
	printf '        warning exactly as it does on a node without the spine.\n'
fi

# ---------------------------------------------------------------------------------------------------
# scenario NAME  FAIL_MODE  — build a node root, drive the real rotate_apply_live, print its trace.
#   FAIL_MODE: restart-once | verify | wp-fail | none
# Each runs in its own PROCESS: rotate_apply_live ends in `die`, which is `exit 1`.
# ---------------------------------------------------------------------------------------------------
scenario() (
	set -uo pipefail
	mode="$1"; out="$2"

	MYC_NB_NO_DISPATCH=1; export MYC_NB_NO_DISPATCH
	# CLEAR the positional parameters first. The entrypoint parses "$@" at source time, and inside a
	# function "$@" is the FUNCTION's arguments — sourcing it with these still set makes it die on
	# "unknown option: restart-once" before defining a single one of the functions under test.
	set --
	# shellcheck source=/dev/null
	. "$ENTRY" || { printf 'ENTRY-SOURCE-FAILED\n'; exit 2; }
	set +e
	# AFTER the entrypoint: it sets STATE_DIR and friends to the PRODUCTION absolute paths, and the fixture
	# is what re-points them into a throwaway root. Sourcing in the other order leaves /var/lib/mycelium
	# live in a process that is about to run install/mv/rm.
	# shellcheck source=/dev/null
	. "$FIXTURE" || { printf 'FIXTURE-SOURCE-FAILED\n'; exit 2; }
	fakenode_init

	OPERATOR_OVERRIDES="$STATE_DIR/operator-overrides.json"
	INVALID_CONFIG="$STATE_DIR/config.invalid.json"
	ROTATE_LIMITS="$STATE_DIR/rotate_limits.json"
	TOOLING_DIR="$FAKENODE_ROOT/tooling"
	# no-spine forces the degraded bookkeeping path REGARDLESS of the host, so the row that checks what the
	# node TELLS the operator is not a property of whether this machine happens to have Go.
	if [ "$mode" = no-spine ]; then SPINE_BIN="$TOOLING_DIR/bin/absent"; else SPINE_BIN="${SPINE:-$TOOLING_DIR/bin/absent}"; fi
	MYCTL="$STUBDIR/myceliumctl"
	SINGBOX_BIN="$STUBDIR/sing-box"
	RENDER_TEMPLATE="$FAKENODE_ROOT/template.json"

	# THE REFUSAL. Everything the executed primitives write to must live inside the throwaway root. The
	# spine is the one deliberate exception: it is read-only and built by this gate.
	p=""
	for p in "$OPERATOR_OVERRIDES" "$INVALID_CONFIG" "$ROTATE_LIMITS" "$TOOLING_DIR" "$MYCTL" \
	         "$SINGBOX_BIN" "$RENDER_TEMPLATE" "$SINGBOX_CONFIG" "$LASTGOOD_CONFIG" "$PARAMS_JSON"; do
		case "$p" in
			"$FAKENODE_ROOT"/*) ;;
			*) printf 'REFUSED %s resolves outside %s\n' "$p" "$FAKENODE_ROOT"; exit 2 ;;
		esac
	done
	printf '{}\n' >"$RENDER_TEMPLATE"

	# --- the two external programs -------------------------------------------------------------------
	# The candidate PRODUCER. It writes a config whose generation differs from the live one, because a
	# byte-identical candidate short-circuits before Phase C and no rollback could ever be reached.
	cat >"$MYCTL" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
[ -n "$out" ] || exit 1
printf '{"generation":"NEW","inbounds":[]}\n' >"$out"
STUB
	chmod +x "$MYCTL"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"

	# systemctl: FAIL-ONCE on restart, so the failing apply and the RECOVERY restart are distinguishable.
	# A stub that always fails would also fail step 4 and the rows could not tell "the rollback restarted
	# the service" from "nothing restarted anything".
	cat >"$STUBDIR/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"$FAKENODE_ROOT/calls"
case "\$*" in
  *restart*)
    case "$mode" in
      restart-once|wp-fail|no-spine)
        if [ ! -f "$FAKENODE_ROOT/restart.tripped" ]; then
          : >"$FAKENODE_ROOT/restart.tripped"; exit 1
        fi ;;
    esac
    exit 0 ;;
  *is-active*)
    # 'verify' mode: the unit restarts fine and the health check is what says no — the OTHER half of
    # \`apply_singbox && verify_post_apply\`. It recovers once the last-known-good config is back.
    if [ "$mode" = verify ] && [ ! -f "$FAKENODE_ROOT/rolled" ]; then exit 3; fi
    exit 0 ;;
esac
exit 0
STUB
	chmod +x "$STUBDIR/systemctl"

	# --- the substitutions, each recorded so its absence is visible ---------------------------------
	install_singbox_unit() { printf 'install_singbox_unit\n' >>"$FAKENODE_ROOT/calls"; }
	# The wp-fail refusal is keyed on the ROLLBACK having started, not on the mode alone. Failing it
	# unconditionally never reaches Phase C at all: write_params is called in Phase B too, and a failure
	# there takes the PRE-PROMOTE abort path (rotate_abort_revert), which reverts the overlay and dies
	# without ever promoting. That looks identical from the outside — config OLD, overlay restored — while
	# testing a different function entirely.
	write_params() {
		printf 'write_params\n' >>"$FAKENODE_ROOT/calls"
		if [ "$mode" = wp-fail ] && [ -f "$FAKENODE_ROOT/rolled" ]; then
			printf 'write_params: refusing (rollback path)\n' >&2; return 1
		fi
		return 0
	}
	converge_node_tail() { printf 'converge_node_tail\n' >>"$FAKENODE_ROOT/calls"; }
	measure_l7_probe()           { return 0; }
	measure_l7_probe_amneziawg() { return 0; }
	measure_l7_probe_xhttp()     { return 0; }
	# rollback_config is REAL; this only marks WHEN it ran, so the is-active stub can recover afterwards
	# (a restored config that is still reported dead is a different scenario, not this one).
	eval "_shipped_rollback_config() $(declare -f rollback_config | tail -n +2)"
	rollback_config() {
		printf 'rollback_config\n' >>"$FAKENODE_ROOT/calls"
		: >"$FAKENODE_ROOT/rolled"
		_shipped_rollback_config "$@"
	}

	# --- node state ----------------------------------------------------------------------------------
	( umask 077
	  jq -n '{node_address:"203.0.113.9", donor_sni:"www.example.invalid", tls_sni:"tls.example.invalid",
	          vless_reality_vision_enabled:true, vless_reality_vision_port:8443,
	          hysteria2_enabled:true, hysteria2_port:8444,
	          shadowtls_enabled:false, shadowtls_port:8446}' >"$PARAMS_JSON"
	  printf '{"operator":"pre-rotation","shadowtls_enabled":false}\n' >"$OPERATOR_OVERRIDES"
	  # The PRODUCTION defaults, verbatim from nb_measure.sh, not invented ones. Invented numbers were
	  # internally inconsistent (min_interval 30m against window/max_per_window = 6h) and the Go validator
	  # rejected them, so rotate-record failed and the budget rows measured the fixture. max_rollbacks=1
	  # is also what ships, which is why ONE rollback both spends the budget and arms the latch.
	  printf '%s\n' '{"flip_confirmations":3,"min_weight_margin":0.1,"min_interval_ns":1800000000000,"window_ns":3600000000000,"max_per_window":2,"max_rollbacks_per_window":1,"cooldown_after_rollback_ns":3600000000000}' >"$ROTATE_LIMITS" )
	printf '{"generation":"OLD","inbounds":[]}\n' >"$LASTGOOD_CONFIG"
	cp "$OPERATOR_OVERRIDES" "$FAKENODE_ROOT/overlay.before"

	# A plan that ENABLES a currently-disabled sibling: the move a planner actually emits.
	jq -n '{act:true,
	        from:{proto:"vless-reality-vision",action:"none",from_port:8443,to_port:0},
	        to:{proto:"shadowtls",action:"promote-sibling",from_port:0,to_port:0},
	        reason:"degraded-active",
	        next_state:{last_rotate_at:"2026-08-04T00:00:00Z", window_start:"2026-08-04T00:00:00Z",
	                    rotations_in_window:1, rollbacks_in_window:0, impaired_streak:0,
	                    hold_until:"0001-01-01T00:00:00Z"}}' >"$FAKENODE_ROOT/plan.json"

	DRY_RUN=0
	# NESTED subshell, because the failure edge ENDS IN `die` — which is `exit 1`. Called bare, it takes
	# this scenario down with it and every observation below goes unwritten: the first draft reported "the
	# scenario produced no digest" for all three failure modes and passed only the healthy control, which is
	# indistinguishable from a rollback that never ran.
	( rotate_apply_live "$FAKENODE_ROOT/plan.json" ) >"$FAKENODE_ROOT/stdout" 2>&1
	printf 'rc=%s\n' "$?" >"$FAKENODE_ROOT/rc"

	# Hand the observations back as a flat digest; the assertions live in the parent.
	{
		cat "$FAKENODE_ROOT/rc"
		printf 'calls=%s\n' "$(tr '\n' ',' <"$FAKENODE_ROOT/calls" 2>/dev/null)"
		printf 'live_gen=%s\n'   "$(fakenode_generation "$SINGBOX_CONFIG")"
		printf 'overlay_same=%s\n' "$(cmp -s "$FAKENODE_ROOT/overlay.before" "$OPERATOR_OVERRIDES" && printf yes || printf no)"
		printf 'overlay=%s\n'    "$(jq -c . "$OPERATOR_OVERRIDES" 2>/dev/null)"
		printf 'rb_window=%s\n'  "$(jq -r '.rollbacks_in_window // "-"' "$STATE_DIR/rotate_state.json" 2>/dev/null)"
		printf 'hold=%s\n'       "$(jq -r '.hold_until // "-"' "$STATE_DIR/rotate_state.json" 2>/dev/null)"
		printf 'restarts=%s\n'   "$(grep -c 'restart' "$FAKENODE_ROOT/calls" 2>/dev/null || true)"
		# The executor's own words for why a step degraded. record_rotation_rollback swallows every
		# failure into a warn (the rollback itself already happened), so without this a row can only say
		# "the budget was not spent" and never which of the four reasons it was.
		printf 'why=%s\n' "$(grep -i 'rotation:' "$FAKENODE_ROOT/log" 2>/dev/null | grep -iE 'rollback|record|spine|limits' | tail -2 | tr '\n' ';')"
		# The LAST thing the operator is told. It is the only account of the rotation they get on an
		# unattended node, so it is an assertable output in its own right.
		printf 'final=%s\n' "$(grep '^die ' "$FAKENODE_ROOT/log" 2>/dev/null | tail -1 | tr -d '\n')"
	} >"$out"
	exit 0
)

field() { sed -n "s/^$2=//p" "$1" | head -1; }
has()   { case ",$(field "$1" calls)," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------------------------------
# A + B. The two ways a live apply fails: the restart itself, and the health check after it.
# ---------------------------------------------------------------------------------------------------
for mode in restart-once verify; do
	case "$mode" in
		restart-once) label="the restart of the promoted config FAILS" ;;
		verify)       label="the service restarts but verify_post_apply says it is NOT healthy" ;;
	esac
	printf '\n-- %s --\n' "$label"
	D="$WORK/$mode.digest"
	scenario "$mode" "$D"
	if [ ! -s "$D" ]; then
		badln "the scenario produced no digest at all — rotate_apply_live could not be driven, so nothing below was measured"
		continue
	fi

	[ "$(field "$D" rc)" != "0" ] \
		&& ok "rotate_apply_live FAILS CLOSED (rc=$(field "$D" rc))" \
		|| badln "the apply returned SUCCESS after a failed promote. Every caller treats rc=0 as 'the rotation is live'; the planner would record a rotation that is not serving."

	[ "$(field "$D" live_gen)" = "OLD" ] \
		&& ok "step 1: the live config is back to the last-known-good bytes" \
		|| badln "the live config reads generation '$(field "$D" live_gen)' — the node is left serving the config the rotation just proved bad."

	[ "$(field "$D" overlay_same)" = "yes" ] \
		&& ok "step 2: operator-overrides.json is byte-restored to its pre-rotation snapshot" \
		|| badln "the overlay still holds the rotated delta ($(field "$D" overlay)). It survives write_params, so the next --update or timer tick RE-APPLIES the rotation that just failed — a flap with no upper bound."

	has "$D" write_params \
		&& ok "step 3: params are regenerated from the reverted overlay" \
		|| badln "write_params was never called during recovery; params.json keeps the rotated values while the config does not."

	[ "$(field "$D" restarts)" -ge 2 ] 2>/dev/null \
		&& ok "step 4: the service is restarted onto the restored config ($(field "$D" restarts) restarts seen)" \
		|| badln "only $(field "$D" restarts) restart(s) — the bytes were rolled back but the running process still holds the failed config in memory. A rollback nothing restarts is a rollback that has not happened."

	has "$D" converge_node_tail \
		&& badln "converge_node_tail ran on a FAILED rotation — the convergence tail opens the firewall for the port set of a config that is being withdrawn" \
		|| ok "and the convergence tail is NOT run for a rotation that failed"

	if [ -n "$SPINE" ]; then
		[ "$(field "$D" rb_window)" = "1" ] \
			&& ok "step 6: the rollback is recorded (rollbacks_in_window 0 -> 1)" \
			|| badln "rollbacks_in_window reads '$(field "$D" rb_window)'. The executor said: $(field "$D" why). Unspent, the budget never accumulates and the planner re-derives the identical act plan every 90 seconds, forever."
		case "$(field "$D" hold)" in
			-|""|0001-01-01T00:00:00Z)
				badln "hold_until is '$(field "$D" hold)' — no latch. The rollback cooldown is the only thing that stops a node that CANNOT rotate from restarting sing-box on every tick." ;;
			*)  ok "and the post-rollback hold latch is set (hold_until=$(field "$D" hold))" ;;
		esac
		case "$(field "$D" final)" in
			*"NOT RECORDED"*) badln "the budget WAS spent, yet the closing message tells the operator it was not — the message has to track the outcome in both directions, or it is noise" ;;
			*recorded*)       ok "step 7: it fails closed with a message that matches what happened" ;;
			*)                badln "the closing message names neither outcome: '$(field "$D" final)'" ;;
		esac
	fi
done

# ---------------------------------------------------------------------------------------------------
# C. One failing recovery step must not skip the rest. Each is subshell-guarded for exactly this reason;
#    unguarded, write_params' internal `die` would exit before the restart, the verify and the record.
# ---------------------------------------------------------------------------------------------------
printf '\n-- a recovery step that itself FAILS (write_params refuses) --\n'
D="$WORK/wp.digest"
scenario wp-fail "$D"
if [ ! -s "$D" ]; then
	badln "the scenario produced no digest — nothing below was measured"
else
	[ "$(field "$D" live_gen)" = "OLD" ] && [ "$(field "$D" overlay_same)" = "yes" ] \
		&& ok "the config and overlay are still restored" \
		|| badln "a failing write_params took the earlier recovery steps down with it"
	[ "$(field "$D" restarts)" -ge 2 ] 2>/dev/null \
		&& ok "and the restart onto the restored config still happens" \
		|| badln "write_params' failure skipped the restart. Every step after it is unreached, and the node runs the failed config with the good bytes on disk — the worst of both."
	if [ -n "$SPINE" ]; then
		[ "$(field "$D" rb_window)" = "1" ] \
			&& ok "and the rollback is still recorded (the budget is not silently refunded)" \
			|| badln "the rollback went unrecorded because an EARLIER step failed; the anti-flap latch is exactly what a partly-failing recovery needs most"
	fi
	[ "$(field "$D" rc)" != "0" ] \
		&& ok "and it still fails closed" \
		|| badln "a recovery that itself failed reported success"
fi

# ---------------------------------------------------------------------------------------------------
# D. The bookkeeping step degrades (no spine). The rollback itself must still be complete — and the node
#    must SAY that the budget went unspent. Host-independent: the scenario forces SPINE_BIN absent.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the rollback is recorded by a spine that is NOT there --\n'
D="$WORK/nospine.digest"
scenario no-spine "$D"
if [ ! -s "$D" ]; then
	badln "the scenario produced no digest — nothing below was measured"
else
	[ "$(field "$D" live_gen)" = "OLD" ] && [ "$(field "$D" restarts)" -ge 2 ] 2>/dev/null \
		&& ok "the config rollback and the restart happen anyway (bookkeeping must never undo recovery)" \
		|| badln "a missing spine took the actual recovery down with it"
	case "$(field "$D" final)" in
		*"NOT RECORDED"*) ok "and the closing message says the rollback went UNRECORDED" ;;
		*recorded*)
			badln "the node signed off with \"$(field "$D" final)\" while record_rotation_rollback had just warned that it could not record anything. The budget is unspent and no hold latch is armed, so the planner re-derives this rotation on the next tick — and the one line the operator reads says the opposite. This is the project's own recurring defect: reporting confidently on something the code did not establish." ;;
		*)  badln "the closing message names neither outcome: '$(field "$D" final)'" ;;
	esac
	[ "$(field "$D" rc)" != "0" ] && ok "and it still fails closed" \
		|| badln "a rotation whose rollback went unrecorded returned success"
fi

# ---------------------------------------------------------------------------------------------------
# E. THE CONTROL. Same harness, healthy apply. If this rolls back too, every row above is meaningless.
# ---------------------------------------------------------------------------------------------------
printf '\n-- control: a HEALTHY apply must not roll back anything --\n'
D="$WORK/ok.digest"
scenario none "$D"
if [ ! -s "$D" ]; then
	badln "the control scenario produced no digest — the rows above cannot be trusted"
else
	[ "$(field "$D" rc)" = "0" ] \
		&& ok "a healthy apply returns success" \
		|| badln "the control scenario ALSO failed (rc=$(field "$D" rc)). Every rollback row above is then consistent with a harness in which nothing can succeed — they measure the fixture, not the code."
	[ "$(field "$D" live_gen)" = "NEW" ] \
		&& ok "the promoted config stays live" \
		|| badln "a healthy apply did not leave the new config live (generation $(field "$D" live_gen))"
	[ "$(field "$D" overlay_same)" = "no" ] \
		&& ok "the rotation delta stays in the overlay (it must survive the next write_params)" \
		|| badln "a SUCCESSFUL rotation left the overlay unchanged — the rotation would be undone by the next --update"
	has "$D" converge_node_tail \
		&& ok "and the node converges (xray, firewall, bundle)" \
		|| badln "a successful rotation skipped converge_node_tail — it routinely promotes a sibling on a different port, and the firewall only ever ADDS"
	if [ -n "$SPINE" ]; then
		case "$(field "$D" rb_window)" in
			0|-) ok "no rollback is recorded for a rotation that worked" ;;
			*)   badln "a successful rotation spent rollback budget ($(field "$D" rb_window)) — the latch would fire on healthy nodes" ;;
		esac
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the rotation recovery path does not run, or does not complete.\n' >&2
	exit 1
fi
printf 'PASS: the rollback branch executes end to end, completes when a step of it fails, and stays out of the way when the apply is healthy.\n'
exit 0
