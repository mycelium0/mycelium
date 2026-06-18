#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_rotate_apply.sh — RP-0012 C4b: the DRY-RUN auto-rotation executor seam.
# Author: mindicator & silicon bags quartet.
#
# flow_rotate applies a rotation plan's params delta to a TEMPORARY params copy, renders a candidate
# config, and runs the REAL `sing-box check` — but NEVER promotes. It is a true dry-run: the
# persisted params, the operator-overrides overlay, and the live sing-box config are all left
# byte-identical; it proves the plan -> params-delta -> render -> validate seam works without
# touching live state. The live promote -> verify -> rollback loop and the unattended timer are C4c,
# gated behind the RP-0012 §6 go/no-go.
#
# apply_rotation_to_params is the ONE new control-logic helper; it lives here (sourced lib), never in
# the entrypoint (no_new_control_decisions_in_bash). Everything else is reused verbatim
# (render_candidate / validate_config from nb_update_apply.sh; $PARAMS_JSON / $STATE_DIR;
# $OPERATOR_TOGGLE_KEYS from nb_render_params.sh) — resolved at call time in the shared sourced scope.

# apply_rotation_to_params PLAN PARAMS_FILE — enable the plan's To-sibling in PARAMS_FILE (in place).
# The enable key follows the closed registry convention (proto '-' -> '_', plus '_enabled') and is
# flipped ONLY if it is in the closed OPERATOR_TOGGLE_KEYS allowlist (the authoritative, fail-closed
# guard): a non-params-toggled or unknown transport (e.g. amneziawg) is refused, never injected. An
# optional port move is applied likewise, only if the proto's *_port key is allowlisted.
apply_rotation_to_params() {
	local plan="$1" params="$2"
	local proto snake enable_key port_key to_port tmp
	proto="$(jq -r '.to.proto // empty' "$plan")"
	[ -n "$proto" ] || die "rotation: plan has no .to.proto (cannot apply)."
	snake="$(printf '%s' "$proto" | tr '-' '_')"
	enable_key="${snake}_enabled"
	printf '%s' "$OPERATOR_TOGGLE_KEYS" | jq -e --arg k "$enable_key" 'index($k) != null' >/dev/null 2>&1 \
		|| die "rotation: '$enable_key' (proto '$proto') is not an operator-toggle key (fail-closed; not a params-toggled transport)."
	tmp="$(mktemp)" || die "rotation: mktemp failed."
	jq --arg k "$enable_key" '.[$k] = true' "$params" > "$tmp" && mv "$tmp" "$params" \
		|| { rm -f "$tmp"; die "rotation: could not enable '$enable_key' in params (fail-closed)."; }
	to_port="$(jq -r '.to.to_port // 0' "$plan")"
	if printf '%s' "$to_port" | grep -qE '^[0-9]+$' && [ "$to_port" -gt 0 ]; then
		port_key="${snake}_port"
		if printf '%s' "$OPERATOR_TOGGLE_KEYS" | jq -e --arg k "$port_key" 'index($k) != null' >/dev/null 2>&1; then
			tmp="$(mktemp)" || die "rotation: mktemp failed."
			jq --arg k "$port_key" --argjson v "$to_port" '.[$k] = $v' "$params" > "$tmp" && mv "$tmp" "$params" \
				|| { rm -f "$tmp"; die "rotation: could not set '$port_key' in params (fail-closed)."; }
		fi
	fi
	log "rotation: params delta applied to the dry-run copy — enabled '$enable_key' for $proto."
}

# flow_rotate — the --rotate dispatch target. Reads a RotationPlan (default $STATE_DIR/rotate_plan.json,
# produced by `myceliumctl rotate-plan`; override with ROTATE_PLAN). A HOLD plan is a no-op. An ACT
# plan is applied to a TEMP params copy, rendered, and validated with the real `sing-box check`;
# nothing is promoted (dry-run). Fail-closed throughout; the live config and persisted params are
# never modified.
flow_rotate() {
	log "=== rotate (DRY-RUN): plan -> params delta -> render -> 'sing-box check'; NEVER promotes (RP-0012 C4b) ==="
	need_root
	local plan="${ROTATE_PLAN:-$STATE_DIR/rotate_plan.json}"
	[ -f "$plan" ] || die "rotation: no plan at $plan (produce one: 'myceliumctl rotate-plan PLANINPUT.json > $plan')."
	jq -e . "$plan" >/dev/null 2>&1 || die "rotation: plan $plan is not valid JSON (fail-closed)."
	[ -f "$PARAMS_JSON" ] || die "rotation: params.json missing ($PARAMS_JSON); bootstrap first."
	if [ "$(jq -r '.act // false' "$plan")" != "true" ]; then
		log "rotation plan is a HOLD (reason=$(jq -r '.reason // "?"' "$plan"); $(jq -r '.held_because // ""' "$plan")) — nothing to apply."
		return 0
	fi
	local from to
	from="$(jq -r '.from.proto // "?"' "$plan")"
	to="$(jq -r '.to.proto // "?"' "$plan")"
	log "rotation plan: rotate $from -> $to (reason=$(jq -r '.reason' "$plan"))."
	# DRY-RUN: stage a TEMP params copy (persisted params + overlay untouched), apply the delta,
	# render a candidate, run the REAL 'sing-box check', then STOP. promote_config is never called
	# here — the live promote/verify/rollback loop is C4c, behind the RP-0012 go/no-go.
	local tmp_params="$STATE_DIR/params.rotate-dryrun.json"
	local candidate="$STATE_DIR/config.rotate-candidate.json"
	cp -f "$PARAMS_JSON" "$tmp_params" || die "rotation: could not stage a temp params copy."
	apply_rotation_to_params "$plan" "$tmp_params"
	# Render from the temp params in a subshell so the global $PARAMS_JSON is never mutated.
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
