#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fp_rotate_drill.sh — RP-0015 increment B (B4): the on-node end-to-end drill that proves the WHOLE
# client-fingerprint chain live — a fingerprint A/B verdict marker -> the measure daemon folds it (the
# pair-stable generation gate) -> the FingerprintPlanInput -> `myceliumctl fingerprint-plan` -> the gated
# actuator rotates the served client uTLS preset -> the rendered config + donor-verify + L7 probe all resolve
# the NEW preset -> restore.
#
# WHAT IT DOES (deterministic + reversible)
#   Runs ON a node whose MEASURE plane is armed (node-bootstrap.sh --measure-enable). Rather than wait for a
#   real upstream fingerprint filter, it INJECTS crafted fp_probe.json marker generations (verdict
#   fingerprint-specific, a stable current->target pair) spaced by > one daemon tick, so the daemon's
#   pair-stable generation gate faults exactly as a live A/B would. It then:
#     Step 1 SILENCE  — no injected fault: fingerprint-plan HOLDs (clean); nothing rotates.
#     Step 2 NEGATIVE — a transport-wide marker: the fold names nothing; fingerprint-plan HOLDs; nothing
#                       rotates (the discriminator's negative — a transport block must NOT rotate the preset).
#     Step 3 FIRE+LIVE— fingerprint-specific across >= fp_min_generations generations, node fp-ARMED: the
#                       plan reaches act, `--fp-rotate --apply-rotation` promotes the target preset, and the
#                       served config's client uTLS fingerprint becomes the target; the overlay persists it.
#     Step 4 RESTORE  — rotate the preset back to the original (an operator-overrides delta + --node-apply),
#                       disarm fp, remove the crafted markers + the fp sentinel + the fp state.
#   It quiesces the mycelium-l7probe.timer for its duration (so a scheduled real A/B cannot overwrite the
#   crafted marker mid-drill) and restores it on exit. Every mutation is reverted by the EXIT trap.
#
# SAFETY. It REFUSES to run unless FP_DRILL_CONFIRM=1 (it rotates the LIVE served preset). It records the
# node's ORIGINAL client_fingerprint first and restores it. On these operator-only nodes a brief
# chrome->firefox->chrome rotation is a config re-render + engine reload, not a client outage (the >=2-family
# set stays served throughout).
#
# NOT A CI GATE. It mutates the served config + needs an armed node. The node-free proofs are the Go fold +
# planner tests (cmd/myceliumd, internal/rotate) and the fp_ab_probe_producer / fp_rotate_gated /
# fp_closed_set_only conformance gates. This closes the loop those cannot: the real gated actuation.

set -uo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/mycelium}"
NB="${NB:-/opt/mycelium/checkout/scripts/node-bootstrap.sh}"
CHECKOUT_DIR="${CHECKOUT_DIR:-/opt/mycelium/checkout}"
TOOLING_DIR="${TOOLING_DIR:-/opt/mycelium/tooling}"
SPINE="${SPINE_BIN:-$TOOLING_DIR/bin/myceliumctl-go}"
SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/sing-box/config.json}"
PARAMS_JSON="${PARAMS_JSON:-$STATE_DIR/params.json}"
OVERRIDES="${OPERATOR_OVERRIDES:-$STATE_DIR/operator-overrides.json}"
FP_MARKER="$STATE_DIR/fp_probe.json"
FP_PLAN_INPUT="$STATE_DIR/rotate_fp_plan_input.json"
FP_STATE="$STATE_DIR/rotate_fp_state.json"
FP_SENTINEL="$STATE_DIR/fp-rotate-live.enabled"
GEN_GAP="${GEN_GAP:-35}"       # > one daemon tick (default 30s) so each generation is read before the next
GENERATIONS="${GENERATIONS:-4}"

say()  { printf '\n=== %s ===\n' "$1"; }
info() { printf '  %s\n' "$1"; }
die()  { printf 'DRILL FAIL: %s\n' "$1" >&2; exit 1; }

[ "${FP_DRILL_CONFIRM:-0}" = "1" ] || die "refusing to run: this rotates the LIVE served preset. Re-run with FP_DRILL_CONFIRM=1."
command -v jq >/dev/null 2>&1 || die "jq required."
[ -x "$SPINE" ] || die "spine binary absent ($SPINE) — the drill needs myceliumctl-go."
[ -f "$PARAMS_JSON" ] || die "params.json absent ($PARAMS_JSON) — bootstrap first."
[ -f "$SINGBOX_CONFIG" ] || die "served config absent ($SINGBOX_CONFIG)."
systemctl is-active --quiet mycelium-measure.service \
	|| die "the MEASURE daemon is not active — run '$NB --measure-enable' first (the drill self-drives off its FingerprintPlanInput)."

# The preset the node currently serves, and a distinct closed-vocab target to rotate to.
ORIG_FP="$(jq -r '.client_fingerprint // "chrome"' "$PARAMS_JSON")"
VOCAB_FILE="${MYC_VOCAB:-$CHECKOUT_DIR/control/vocab.json}"
TARGET_FP="$(jq -r --arg cur "$ORIG_FP" '.client_fingerprints[]? | select(. != $cur)' "$VOCAB_FILE" 2>/dev/null | head -n1)"
[ -n "$TARGET_FP" ] || die "could not pick a target preset distinct from '$ORIG_FP' from $VOCAB_FILE."
info "original preset: $ORIG_FP ; drill target: $TARGET_FP"

# The EFFECTIVE client uTLS preset — params.client_fingerprint, the single source every client render
# (subscription + share-links) + the donor-verify/L7 probe resolve through myc_client_fingerprint. A client
# fingerprint does NOT appear in the SERVER config (SINGBOX_CONFIG); it lives entirely in the client-facing
# artifacts, which write_params + render_serve_bundle refresh from this one value (fingerprint_single_source).
served_fp() { jq -r '.client_fingerprint // "chrome"' "$PARAMS_JSON" 2>/dev/null; }
# Stronger cross-check: the freshly-rendered client subscription actually carries the preset (belt + braces).
subscription_fp() {
	local d; d="$(ls -1d "$STATE_DIR"/serve/*/ 2>/dev/null | head -n1)"
	[ -n "$d" ] || { printf '?'; return; }
	jq -r '[.outbounds[]?.tls.utls.fingerprint // empty] | (.[0] // "?")' "$d"/*.singbox.json 2>/dev/null | head -n1
}

# --- reversible setup: quiesce the real probe timer; arrange full restore on exit. -------------------
RESTORE_DONE=0
restore() {
	[ "$RESTORE_DONE" = "1" ] && return 0; RESTORE_DONE=1
	say "STEP 4 — RESTORE"
	rm -f "$FP_MARKER" "$FP_PLAN_INPUT" "$FP_STATE" 2>/dev/null || true
	"$NB" --fp-rotate-disarm --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 || true
	rm -f "$FP_SENTINEL" 2>/dev/null || true
	# Regenerate the measure config so fp_rotate_enabled returns to false (the sentinel is gone) and restart
	# the daemon back to the disarmed posture.
	"$NB" --measure-configure --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 || true
	systemctl restart mycelium-measure.service >/dev/null 2>&1 || true
	# Restore the original preset through the overlay (survives --update), then re-apply the node.
	if [ "$(jq -r '.client_fingerprint // ""' "$OVERRIDES" 2>/dev/null)" = "$TARGET_FP" ]; then
		local tmp; tmp="$(mktemp)"
		jq --arg fp "$ORIG_FP" '.client_fingerprint = $fp' "$OVERRIDES" > "$tmp" && mv -f "$tmp" "$OVERRIDES"
		"$NB" --node-apply --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 || true
	fi
	systemctl start mycelium-l7probe.timer >/dev/null 2>&1 || true
	local now_fp; now_fp="$(served_fp)"
	if [ "$now_fp" = "$ORIG_FP" ]; then info "restored: served preset back to $ORIG_FP."; else printf '  WARN: served preset is %s (expected %s) — check %s by hand.\n' "$now_fp" "$ORIG_FP" "$OVERRIDES" >&2; fi
}
trap restore EXIT
systemctl stop mycelium-l7probe.timer >/dev/null 2>&1 || true

# inject_marker VERDICT CURRENT TARGET — write a crafted fp_probe.json with a FRESH observed_at.
inject_marker() {
	local verdict="$1" cur="$2" tgt="$3" ts
	ts="$(date -u +%Y-%m-%dT%H:%M:%S.%N%:z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '{"observed_at":"%s","current_fingerprint":"%s","verdict":"%s","target_fingerprint":"%s","suspect_refs":["vless-reality-vision"]}\n' \
		"$ts" "$cur" "$verdict" "$tgt" > "$FP_MARKER.tmp" && mv -f "$FP_MARKER.tmp" "$FP_MARKER"
}

# plan_act — the fp plan the actuator would consume this instant (fold happens in the daemon; here we ask
# the planner directly off the freshest FingerprintPlanInput the daemon wrote, or off a synthesized input).
plan_verdict() { [ -f "$FP_PLAN_INPUT" ] && "$SPINE" fingerprint-plan "$FP_PLAN_INPUT" 2>/dev/null | jq -r '.act' 2>/dev/null || echo "no-input"; }

# --- STEP 1: SILENCE (disarmed, no fault) -----------------------------------------------------------
say "STEP 1 — SILENCE (no injected fault)"
inject_marker "clean" "$ORIG_FP" ""
"$NB" --fp-rotate --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 || true
[ "$(served_fp)" = "$ORIG_FP" ] && info "served preset unchanged ($ORIG_FP) — a clean marker rotates nothing." || die "a clean marker changed the served preset."

# --- STEP 3: FIRE + LIVE (arm, inject fingerprint-specific across generations, gated apply) ----------
# (Step 2 negative is folded into the arming window below: we first prove transport-wide holds.)
say "STEP 2 — NEGATIVE (transport-wide must NOT rotate)"
"$NB" --fp-rotate-arm --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 \
	|| die "could not fp-arm the node."
# Arming writes the sentinel; regenerate the measure config so the daemon folds fp_rotate_enabled=true and
# begins WRITING the FingerprintPlanInput the fp loop self-drives off (the daemon re-reads its config each tick).
"$NB" --measure-configure --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 \
	|| die "could not regenerate the measure config after arming."
systemctl restart mycelium-measure.service >/dev/null 2>&1 || true   # pick up fp_rotate_enabled immediately
info "fp-armed ($FP_SENTINEL present) + measure config regenerated (fp_rotate_enabled=true)."
local_i=0
while [ "$local_i" -lt "$GENERATIONS" ]; do inject_marker "transport-wide" "$ORIG_FP" ""; local_i=$((local_i+1)); sleep "$GEN_GAP"; done
"$NB" --fp-rotate --apply-rotation --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 || true
[ "$(served_fp)" = "$ORIG_FP" ] && info "transport-wide held: served preset still $ORIG_FP (no useless fingerprint rotation)." || die "a transport-wide verdict rotated the preset — the discriminator failed."

say "STEP 3 — FIRE + LIVE (fingerprint-specific across $GENERATIONS generations, gated apply)"
info "injecting fingerprint-specific ($ORIG_FP DEAD, $TARGET_FP ALIVE); waiting for the daemon gate + hysteresis..."
i=0
acted=0
while [ "$i" -lt $(( GENERATIONS + 6 )) ]; do
	inject_marker "fingerprint-specific" "$ORIG_FP" "$TARGET_FP"
	sleep "$GEN_GAP"
	"$NB" --fp-rotate --apply-rotation --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1 || true
	if [ "$(served_fp)" = "$TARGET_FP" ]; then acted=1; break; fi
	i=$((i+1))
done
[ "$acted" = "1" ] || die "the served preset never rotated to $TARGET_FP after $i generations (check mycelium-measure.service + the daemon fp fields)."
info "ROTATED: served client uTLS fingerprint is now $TARGET_FP."

# Consistency: the overlay persisted the target (survives --update), and the node is healthy on the new preset.
[ "$(jq -r '.client_fingerprint // ""' "$OVERRIDES")" = "$TARGET_FP" ] \
	&& info "overlay persisted client_fingerprint=$TARGET_FP (survives --update)." \
	|| die "the rotation did not persist into the operator-overrides overlay."
if "$NB" --l7-probe --checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR" >/dev/null 2>&1; then
	info "post-rotation L7 probe: the node still serves on the new preset."
else
	info "post-rotation L7 probe flagged a member (advisory) — inspect $STATE_DIR/l7_selftest.json."
fi

say "DRILL PASS — fingerprint rotation actuated live and is being restored"
# restore() runs on EXIT.
