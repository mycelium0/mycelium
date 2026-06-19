#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_rotate_apply.sh — RP-0012 auto-rotation executor seam (C4b dry-run + C4c gated live loop).
# Author: mindicator & silicon bags quartet.
#
# flow_rotate applies a RotationPlan (from `myceliumctl rotate-plan`). Two modes, behind a TRIPLE GATE:
#   * DEFAULT (no --apply-rotation, or any --dry-run) = DRY-RUN: apply the plan's params delta to a
#     TEMPORARY params copy, render a candidate, run the real `sing-box check`, and STOP — promotes
#     nothing; the persisted params, the operator-overrides overlay and the live config stay byte-identical.
#   * --apply-rotation AND DRY_RUN=0 AND the node is ARMED (a node-local sentinel
#     $STATE_DIR/rotate-live.enabled, placed by hand / `--rotate-arm`, NEVER shipped in git) = LIVE:
#     validate first against a temp copy, then PERSIST the rotation through the operator-overrides overlay
#     (so it survives the next write_params/--update), re-render from the persisted params, then the
#     EXISTING render -> validate -> promote -> apply -> verify -> rollback path. Every failure edge
#     REVERTS the overlay (so a rolled-back rotation cannot re-apply on the next tick) and, on a post-apply
#     rollback, records the outcome (rollback budget + hold latch).
#
# The triple gate (dry-run default + --apply-rotation required + node-armed sentinel) is why a deploy can
# never actuate a node: nodes auto-pull main, but the arm sentinel is node-local state git can never
# carry, and flow_rotate is reached ONLY by the explicit --rotate dispatch (never flow_bootstrap /
# flow_update). The unattended timer (C4c-2) ships DISABLED. rotate_apply_gated.sh pins all of this.
#
# CATCHABILITY: write_params + render_candidate signal failure by `die` (= exit 1), which a bare
# `if ! cmd` / `cmd || true` CANNOT trap — the whole sourced script would terminate, skipping the overlay
# revert and leaving a rolled-back rotation to re-apply next tick. So every die-capable mutating call on a
# recoverable edge is wrapped in a SUBSHELL `( cmd )`: a die then exits only the subshell, the caller sees
# non-zero, and the revert runs. validate_config / apply_singbox / verify_post_apply genuinely `return 1`
# (no wrap needed). The new control-logic helpers live HERE (sourced lib), never in the entrypoint
# (no_new_control_decisions_in_bash). The render/validate/promote/apply/verify/rollback primitives,
# write_params + the operator-overrides overlay ($OPERATOR_OVERRIDES / $OPERATOR_TOGGLE_KEYS from
# nb_render_params.sh), and $STATE_DIR/$PARAMS_JSON/$SINGBOX_CONFIG/$ARTIFACT_ROOT/$TOOLING_DIR are reused
# verbatim, resolved at call time from the shared sourced scope.

# --- live-actuation arming sentinel ------------------------------------------------------------------
# A node actuates a LIVE rotation ONLY if this node-local file is present. It is NEVER committed (like
# two_hop.json / params.json) so it can never arrive via the auto-pull; arming is a per-node operator act.
_rotate_sentinel() { printf '%s' "$STATE_DIR/rotate-live.enabled"; }
rotate_live_armed() { [ -f "$(_rotate_sentinel)" ]; }

rotate_arm() {
	need_root
	( umask 077; : >"$(_rotate_sentinel)" ) || die "rotation: could not arm (write $(_rotate_sentinel))."
	log "rotation: node ARMED for LIVE apply ($(_rotate_sentinel) present). Disarm with '$0 --rotate-disarm'."
}

rotate_disarm() {
	need_root
	rm -f "$(_rotate_sentinel)" || die "rotation: could not disarm (remove $(_rotate_sentinel))."
	log "rotation: node DISARMED ($(_rotate_sentinel) removed); --apply-rotation now falls back to dry-run."
}

# --- the unattended rotation loop (RP-0012 C4c-2): SHIPS DISABLED ------------------------------------
# The auto-apply timer is the autonomous half of the loop. It is installed + enabled ONLY by the explicit
# rotate_enable_loop (--rotate-enable-loop) — NEVER by flow_bootstrap / flow_update / install_tooling, so an
# auto-pull can never arm it (rotate_apply_gated.sh pins this). Even once enabled, each tick only ACTUATES
# while the node is armed (rotate-arm) AND a rotate_plan.json is present; on an un-armed node every tick is
# a harmless dry-run. Producing fresh plans from on-node signals is the MEASURE-plane chunk (later); until
# then the loop applies whatever rotate_plan.json a producer has written (the no-op short-circuit makes a
# repeated identical plan a zero-restart no-op). Arming the loop is a separate, individually-revertible
# operator decision taken AFTER the RP-0012 §6 go/no-go.
ROTATE_LOOP_INTERVAL="${ROTATE_LOOP_INTERVAL:-5min}"

rotate_enable_loop() {
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would install + enable mycelium-rotate.timer (every $ROTATE_LOOP_INTERVAL)"; return 0; fi
	cat >/etc/systemd/system/mycelium-rotate.service <<UNIT
[Unit]
Description=Mycelium auto-rotation apply (RP-0012; gated by --apply-rotation + the node arm sentinel)
[Service]
Type=oneshot
ExecStart=$NB_SELF --rotate --apply-rotation --checkout $CHECKOUT_DIR --state-dir $STATE_DIR --tooling-dir $TOOLING_DIR
UNIT
	cat >/etc/systemd/system/mycelium-rotate.timer <<UNIT
[Unit]
Description=Run the Mycelium auto-rotation apply every $ROTATE_LOOP_INTERVAL
[Timer]
OnBootSec=$ROTATE_LOOP_INTERVAL
OnUnitActiveSec=$ROTATE_LOOP_INTERVAL
AccuracySec=30s
[Install]
WantedBy=timers.target
UNIT
	run systemctl daemon-reload
	run systemctl enable --now mycelium-rotate.timer || die "rotation: could not enable mycelium-rotate.timer (fail-closed)."
	warn "rotation: mycelium-rotate.timer ENABLED — this node will AUTONOMOUSLY apply rotation plans every $ROTATE_LOOP_INTERVAL."
	warn "rotation: it actuates ONLY while armed (--rotate-arm) with a rotate_plan.json present; disable with '$0 --rotate-disable-loop'."
}

rotate_disable_loop() {
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would disable + remove mycelium-rotate.timer"; return 0; fi
	run systemctl disable --now mycelium-rotate.timer 2>/dev/null || true
	rm -f /etc/systemd/system/mycelium-rotate.timer /etc/systemd/system/mycelium-rotate.service
	run systemctl daemon-reload
	log "rotation: mycelium-rotate.timer DISABLED + removed; the node no longer auto-rotates."
}

# --- registry-sourced toggle keys (single source of truth: control/vocab.json; §2.2 #8) --------------
# The proto -> enable_key / port_key mapping is OWNED by the Go transport registry, emitted to the
# committed control/vocab.json (.protos[].enable_key / .port_key). We READ it (jq, available on every
# node) rather than re-deriving the naming rule in bash — re-deriving would duplicate the source of truth.
# OPERATOR_TOGGLE_KEYS stays as a fail-closed defense-in-depth allowlist.
_rotation_vocab() { printf '%s' "${MYC_VOCAB:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/vocab.json}"; }

# _rotation_enable_key PROTO -> the registry enable_key for PROTO. Refuses (fail-closed) a proto with no
# enable_key (e.g. amneziawg — not params-toggled) or one absent from the OPERATOR_TOGGLE_KEYS allowlist.
_rotation_enable_key() {
	local proto="$1" key vocab
	[ -n "$proto" ] || die "rotation: empty proto (cannot resolve enable key)."
	vocab="$(_rotation_vocab)"
	[ -f "$vocab" ] || die "rotation: transport registry $vocab not found (fail-closed; required to resolve the enable key)."
	key="$(jq -r --arg p "$proto" '.protos[] | select(.proto==$p) | .enable_key // ""' "$vocab" 2>/dev/null)"
	[ -n "$key" ] || die "rotation: proto '$proto' has no enable_key in the registry — not a params-toggled transport (fail-closed)."
	printf '%s' "$OPERATOR_TOGGLE_KEYS" | jq -e --arg k "$key" 'index($k) != null' >/dev/null 2>&1 \
		|| die "rotation: registry enable_key '$key' for '$proto' is not in OPERATOR_TOGGLE_KEYS (fail-closed)."
	printf '%s' "$key"
}

# _rotation_port_key PROTO -> the registry port_key for PROTO ("" if none / registry absent). The caller
# applies it only if it is allowlisted and the plan names a target port.
_rotation_port_key() {
	local proto="$1" vocab
	vocab="$(_rotation_vocab)"
	[ -f "$vocab" ] || return 0
	jq -r --arg p "$proto" '.protos[] | select(.proto==$p) | .port_key // ""' "$vocab" 2>/dev/null
}

# _rotation_port_key_if_moving PLAN PROTO -> echo the allowlisted port_key IF the plan requests a valid
# (>0) port move for PROTO, else echo NOTHING. Pure resolver (no TAB-packing — the caller reads to_port
# separately and passes it as the value).
_rotation_port_key_if_moving() {
	local plan="$1" proto="$2" to_port port_key
	to_port="$(jq -r '.to.to_port // 0' "$plan")"
	printf '%s' "$to_port" | grep -qE '^[0-9]+$' || return 0
	[ "$to_port" -gt 0 ] || return 0
	port_key="$(_rotation_port_key "$proto")"
	[ -n "$port_key" ] || return 0
	printf '%s' "$OPERATOR_TOGGLE_KEYS" | jq -e --arg k "$port_key" 'index($k) != null' >/dev/null 2>&1 || return 0
	printf '%s' "$port_key"
}

# _rotation_set_delta FILE ENABLE_KEY PORT_KEY TO_PORT — set enable_key=true (+ optional port) in FILE,
# ATOMICALLY (single jq -> tmp -> mv); a failure leaves FILE byte-unchanged. PORT_KEY="" skips the port.
_rotation_set_delta() {
	local file="$1" ek="$2" pk="$3" pv="$4" tmp
	tmp="$(mktemp)" || die "rotation: mktemp failed."
	jq --arg ek "$ek" --arg pk "$pk" --argjson pv "${pv:-0}" \
		'.[$ek] = true | (if $pk != "" then .[$pk] = $pv else . end)' "$file" > "$tmp" && mv -f "$tmp" "$file" \
		|| { rm -f "$tmp"; die "rotation: could not write the rotation delta to $file (fail-closed)."; }
}

# apply_rotation_to_params PLAN PARAMS_FILE — enable the plan's To-sibling in PARAMS_FILE (in place).
# Used for the DRY-RUN preview against a TEMP copy (persisted state untouched). Fail-closed.
apply_rotation_to_params() {
	local plan="$1" params="$2" proto enable_key pk to_port
	proto="$(jq -r '.to.proto // empty' "$plan")"
	[ -n "$proto" ] || die "rotation: plan has no .to.proto (cannot apply)."
	enable_key="$(_rotation_enable_key "$proto")"
	to_port="$(jq -r '.to.to_port // 0' "$plan")"
	pk="$(_rotation_port_key_if_moving "$plan" "$proto")"
	_rotation_set_delta "$params" "$enable_key" "$pk" "$to_port"
	log "rotation: params delta applied to the dry-run copy — enabled '$enable_key' for $proto."
}

# --- live persistence through the operator-overrides overlay -----------------------------------------
_rotate_overlay_bak() { printf '%s' "$STATE_DIR/operator-overrides.rotate-bak.json"; }

# persist_rotation_to_overlay PLAN — write the plan's To-sibling enable key (+ optional port) into the
# PERSISTED operator-overrides overlay so the rotation SURVIVES write_params/--update. Honors DRY_RUN
# (no mutation). SNAPSHOTS the pre-rotation overlay to the backup FIRST (revert_rotation_overlay restores
# it). The mutation is ATOMIC, so a failure leaves the overlay byte-unchanged. Fail-closed.
persist_rotation_to_overlay() {
	local plan="$1"
	[ "$DRY_RUN" -eq 0 ] || { log "[dry-run] would persist the rotation into $OPERATOR_OVERRIDES (no mutation)."; return 0; }
	local proto enable_key pk to_port bak
	proto="$(jq -r '.to.proto // empty' "$plan")"
	[ -n "$proto" ] || die "rotation: plan has no .to.proto (cannot persist)."
	enable_key="$(_rotation_enable_key "$proto")"
	to_port="$(jq -r '.to.to_port // 0' "$plan")"
	pk="$(_rotation_port_key_if_moving "$plan" "$proto")"
	[ -f "$OPERATOR_OVERRIDES" ] || ( umask 077; printf '{}\n' >"$OPERATOR_OVERRIDES" ) \
		|| die "rotation: could not initialise the overlay $OPERATOR_OVERRIDES (fail-closed)."
	jq -e 'type == "object"' "$OPERATOR_OVERRIDES" >/dev/null 2>&1 \
		|| die "rotation: overlay $OPERATOR_OVERRIDES is not a JSON object (fail-closed; fix or remove it)."
	bak="$(_rotate_overlay_bak)"
	cp -f "$OPERATOR_OVERRIDES" "$bak" || die "rotation: could not snapshot the overlay (fail-closed; refusing to mutate without a revert path)."
	_rotation_set_delta "$OPERATOR_OVERRIDES" "$enable_key" "$pk" "$to_port"
	chmod 0600 "$OPERATOR_OVERRIDES" 2>/dev/null || true
	log "rotation: persisted enable of '$enable_key' into the operator-overrides overlay (survives --update; snapshot at $bak)."
}

# revert_rotation_overlay — restore the overlay from the pre-rotation snapshot. Called on EVERY live
# failure edge so a failed rotation is not silently re-applied on the next write_params/timer tick. On a
# restore FAILURE it ESCALATES loudly and returns 1 (the caller still dies fail-closed) — the overlay may
# remain mutated, which the operator must fix by hand from the snapshot.
revert_rotation_overlay() {
	local bak; bak="$(_rotate_overlay_bak)"
	[ -f "$bak" ] || { warn "rotation: no overlay snapshot to revert ($bak absent)."; return 0; }
	if install -m 0600 "$bak" "$OPERATOR_OVERRIDES" 2>/dev/null; then
		log "rotation: reverted the operator-overrides overlay to its pre-rotation snapshot."
		return 0
	fi
	warn "rotation: CRITICAL — could NOT revert the overlay ($OPERATOR_OVERRIDES); the rotated enable key may persist and re-apply on the next --update. Restore by hand from the snapshot $bak. OPERATOR ATTENTION REQUIRED."
	return 1
}

# rotate_abort_revert CANDIDATE MSG — PRE-PROMOTE failure recovery: nothing was promoted, so the live
# config is untouched; revert the overlay and regenerate params (subshell so write_params' internal die is
# caught), drop the candidate, die fail-closed.
rotate_abort_revert() {
	local candidate="$1" msg="$2"
	revert_rotation_overlay
	( write_params ) || warn "rotation: write_params failed while reverting; params.json may still hold the rotated values — operator attention needed (overlay snapshot: $(_rotate_overlay_bak))."
	rm -f "$candidate" 2>/dev/null || true
	die "rotation: $msg; reverted overlay (fail-closed; nothing promoted)."
}

# --- between-tick rotation state ---------------------------------------------------------------------
_rotate_state_file() { printf '%s' "$STATE_DIR/rotate_state.json"; }

# persist_rotation_state PLAN — record the plan's next_state as the node's between-tick rotation state
# (read by the next rotate-plan). A successful promote needs no budget adjustment (Plan already advanced
# the window); the rollback path uses record_rotation_rollback instead.
persist_rotation_state() {
	local plan="$1" tmp
	[ "$DRY_RUN" -eq 0 ] || return 0
	jq -e '.next_state' "$plan" >/dev/null 2>&1 \
		|| { warn "rotation: plan has no .next_state; between-tick state not updated."; return 0; }
	tmp="$(mktemp)" || return 0
	jq '.next_state' "$plan" > "$tmp" && ( umask 077; mv -f "$tmp" "$(_rotate_state_file)" ) \
		|| { rm -f "$tmp"; warn "rotation: could not persist between-tick state."; return 0; }
	chmod 0600 "$(_rotate_state_file)" 2>/dev/null || true
	log "rotation: persisted next_state -> $(_rotate_state_file)."
}

# record_rotation_rollback PLAN — fold a rollback into the between-tick state via the pure Go
# rotate.RecordOutcome (spends the per-window rollback budget; latches the planner to hold once exhausted).
# Needs the Go spine binary + a node-local rotate_limits.json; both are present on the Go-bearing node
# where live rotation runs. Degrades to a warning (the rollback itself already happened) if either is
# missing — for the drill rollback-latch case (Step 3/4) both MUST be present.
record_rotation_rollback() {
	local plan="$1"
	local spine="${SPINE_BIN:-$TOOLING_DIR/bin/myceliumctl-go}"
	local limits="${ROTATE_LIMITS:-$STATE_DIR/rotate_limits.json}"
	[ "$DRY_RUN" -eq 0 ] || return 0
	[ -x "$spine" ] || { warn "rotation: spine binary absent ($spine); rollback NOT recorded (budget/latch unchanged)."; return 0; }
	[ -f "$limits" ] || { warn "rotation: no $limits; rollback NOT recorded (budget/latch unchanged). Provide rotate_limits.json to enable the latch."; return 0; }
	local input next tmp
	input="$(jq -n --slurpfile p "$plan" --slurpfile l "$limits" \
		'{state: ($p[0].next_state // {}), limits: $l[0], rolled_back: true}')" \
		|| { warn "rotation: could not assemble rollback-record input."; return 0; }
	next="$(printf '%s' "$input" | "$spine" rotate-record - 2>/dev/null)" \
		|| { warn "rotation: rotate-record failed; budget/latch unchanged."; return 0; }
	tmp="$(mktemp)" || return 0
	printf '%s\n' "$next" > "$tmp" && ( umask 077; mv -f "$tmp" "$(_rotate_state_file)" ) \
		|| { rm -f "$tmp"; warn "rotation: could not persist post-rollback state."; return 0; }
	chmod 0600 "$(_rotate_state_file)" 2>/dev/null || true
	log "rotation: recorded rollback (rollback budget spent; hold latch updated) -> $(_rotate_state_file)."
}

# --- DRY-RUN executor (default; promotes nothing, mutates no persisted state) -------------------------
rotate_apply_dryrun() {
	local plan="$1" from to
	from="$(jq -r '.from.proto // "?"' "$plan")"
	to="$(jq -r '.to.proto // "?"' "$plan")"
	log "rotation (DRY-RUN): rotate $from -> $to (reason=$(jq -r '.reason' "$plan")) — render + 'sing-box check'; promotes nothing."
	local tmp_params="$STATE_DIR/params.rotate-dryrun.json"
	local candidate="$STATE_DIR/config.rotate-candidate.json"
	cp -f "$PARAMS_JSON" "$tmp_params" || die "rotation: could not stage a temp params copy."
	apply_rotation_to_params "$plan" "$tmp_params"
	if ! ( PARAMS_JSON="$tmp_params"; render_candidate "$candidate" ); then
		rm -f "$tmp_params" "$candidate" 2>/dev/null || true
		die "rotation: candidate render failed (fail-closed; nothing changed)."
	fi
	if validate_config "$candidate"; then
		log "[dry-run] OK: rotation candidate ($from -> $to) rendered + passed 'sing-box check'. WOULD promote; NOT promoting (dry-run). Live config + persisted params unchanged."
		rm -f "$tmp_params" "$candidate" 2>/dev/null || true
		return 0
	fi
	rm -f "$tmp_params" "$candidate" 2>/dev/null || true
	die "rotation: candidate failed 'sing-box check' (fail-closed; nothing changed)."
}

# --- LIVE executor (armed + --apply-rotation + DRY_RUN=0 only) ----------------------------------------
rotate_apply_live() {
	local plan="$1" from to
	from="$(jq -r '.from.proto // "?"' "$plan")"
	to="$(jq -r '.to.proto // "?"' "$plan")"
	log "rotation (LIVE, armed): rotate $from -> $to (reason=$(jq -r '.reason' "$plan"))."
	local tmp_params="$STATE_DIR/params.rotate-pre.json"
	local candidate="$STATE_DIR/config.rotate-candidate.json"
	# Phase A — VALIDATE FIRST against a temp params copy; touch NO persisted state if the rotation is bad.
	cp -f "$PARAMS_JSON" "$tmp_params" || die "rotation: could not stage temp params (fail-closed)."
	apply_rotation_to_params "$plan" "$tmp_params"
	if ! ( PARAMS_JSON="$tmp_params"; render_candidate "$candidate" ); then
		rm -f "$tmp_params" "$candidate" 2>/dev/null || true
		die "rotation: pre-validate render failed (fail-closed; nothing changed)."
	fi
	if ! validate_config "$candidate"; then
		rm -f "$tmp_params" "$candidate" 2>/dev/null || true
		die "rotation: candidate failed 'sing-box check' (fail-closed; nothing changed)."
	fi
	rm -f "$tmp_params" 2>/dev/null || true
	# Phase B — PERSIST via the overlay (snapshot taken), regenerate params, re-render + re-validate the
	# AUTHORITATIVE config. Every die-capable step is SUBSHELL-wrapped so a failure is catchable and the
	# overlay is reverted (rotate_abort_revert) — a bare `if ! write_params` cannot trap write_params' die.
	persist_rotation_to_overlay "$plan"
	if ! ( write_params ); then
		rotate_abort_revert "$candidate" "write_params failed after the overlay update"
	fi
	if ! ( render_candidate "$candidate" ); then
		rotate_abort_revert "$candidate" "post-persist render failed"
	fi
	if ! validate_config "$candidate"; then
		rotate_abort_revert "$candidate" "post-persist candidate failed 'sing-box check'"
	fi
	# No-op short-circuit: the sibling is already the live config -> keep the overlay + state, no restart
	# (an always-on PPN must not drop client connections for a no-op).
	if [ -f "$SINGBOX_CONFIG" ] && cmp -s "$candidate" "$SINGBOX_CONFIG"; then
		rm -f "$candidate" 2>/dev/null || true
		persist_rotation_state "$plan"
		log "rotation: candidate identical to the live config; sibling already serving (no restart). Overlay kept."
		return 0
	fi
	# Phase C — PROMOTE with rollback. On verify failure: restore last-known-good config AND revert the
	# overlay AND regenerate params AND restart onto last-good AND record the rollback, then fail closed.
	# Each recovery step is guarded (subshell where it can die) so one failure cannot skip the rest.
	promote_config "$candidate"
	rm -f "$candidate" 2>/dev/null || true
	install_singbox_unit
	if apply_singbox && verify_post_apply; then
		persist_rotation_state "$plan"
		render_serve_bundle
		log "rotation: LIVE apply verified ($from -> $to). Sibling promoted; between-tick state persisted."
		return 0
	fi
	warn "rotation: post-apply verification FAILED; rolling back config + overlay (fail-closed)."
	rollback_config
	revert_rotation_overlay
	( write_params ) || warn "rotation: write_params failed during rollback; params.json may still hold the rotated values — operator attention needed."
	apply_singbox || warn "rotation: could not restart sing-box onto the restored config — operator attention needed."
	verify_post_apply || warn "rotation: service still unhealthy after rollback — operator attention needed."
	record_rotation_rollback "$plan"
	die "rotation: rolled back (fail-closed). Last-known-good config restored; overlay reverted; rollback recorded."
}

# flow_rotate — the --rotate dispatch target. Reads a RotationPlan (default $STATE_DIR/rotate_plan.json,
# override ROTATE_PLAN; produced by `myceliumctl rotate-plan`). HOLD plan -> no-op. ACT plan -> DRY-RUN by
# default; LIVE only when --apply-rotation (ROTATE_APPLY=1) AND DRY_RUN=0 AND the node is armed. Any other
# combination is a DRY-RUN preview. Fail-closed throughout.
flow_rotate() {
	log "=== rotate: plan -> dry-run preview | gated live apply (RP-0012) ==="
	need_root
	local plan="${ROTATE_PLAN:-$STATE_DIR/rotate_plan.json}"
	# Self-drive (RP-0010 C5c): if the MEASURE daemon has written a FRESH rotate.PlanInput, fold it into
	# the RotationPlan this loop consumes. A stale or absent PlanInput leaves $plan untouched (the loop
	# then uses whatever plan is present, or holds). The apply path below stays triple-gated regardless,
	# so self-driving NEVER lowers the actuation bar — it only supplies the plan, never applies it.
	refresh_rotate_plan_from_daemon
	[ -f "$plan" ] || die "rotation: no plan at $plan (produce one, or enable the MEASURE daemon with --measure-enable, or 'myceliumctl rotate-plan PLANINPUT.json > $plan')."
	jq -e . "$plan" >/dev/null 2>&1 || die "rotation: plan $plan is not valid JSON (fail-closed)."
	[ -f "$PARAMS_JSON" ] || die "rotation: params.json missing ($PARAMS_JSON); bootstrap first."
	if [ "$(jq -r '.act // false' "$plan")" != "true" ]; then
		log "rotation plan is a HOLD (reason=$(jq -r '.reason // "?"' "$plan"); $(jq -r '.held_because // ""' "$plan")) — nothing to apply."
		return 0
	fi
	if [ "${ROTATE_APPLY:-0}" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
		if rotate_live_armed; then
			rotate_apply_live "$plan"
		else
			warn "rotation: --apply-rotation given but this node is NOT armed (sentinel $(_rotate_sentinel) absent)."
			warn "rotation: refusing to actuate; running a DRY-RUN preview instead. Arm THIS node with '$0 --rotate-arm' to allow live apply."
			rotate_apply_dryrun "$plan"
		fi
	else
		if [ "${ROTATE_APPLY:-0}" -eq 1 ]; then
			warn "rotation: --apply-rotation given with --dry-run; running a DRY-RUN preview only (no persisted mutation)."
		fi
		rotate_apply_dryrun "$plan"
	fi
}
