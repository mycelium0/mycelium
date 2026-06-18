<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0012: Phase-2 auto-rotation actuation (executing the RP-0010 ADAPT plane)

## Metadata
- **ID:** RP-0012
- **Slug:** `phase2-auto-rotation-actuation`
- **Status:** **ACTIVE — implementation in progress** (C4a planner + C4b dry-run seam + C4c-1 gated live apply + C4c-3 live drill landed — see §5.1; only C4c-2, the disabled unattended timer, remains)
- **Phase:** Phase 2 (Adaptation layer)
- **Type:** single-workstream RP with three sub-chunks (planner / executor seam / gated live loop)
- **Related:** [RP-0010](0010-phase2-adaptivity.md) (the detect→adapt→self-tune planes; this RP executes its Plane-3 ADAPT actuation — formerly RP-0010 "C4"); `internal/detect` (the verdict), `internal/tune` (the ranking), `internal/spec/rotate.go` + `internal/rotate` (this RP); [ADR-0010](../adr/0010-phase0-transport-set.md) (the closed transport set, AC-5); [ADR-0025](../adr/0025-no-global-abuse-oracle.md) (advisory-never-actuates, AC-4); `control/lib/nb_update_apply.sh` + `nb_two_hop.sh` (the reused render→validate→promote→verify→rollback path); [development.md](../development.md) §2.2 #4 (no silent emergency rotation path).

## Rationale

RP-0010 builds the connectivity **detector** (C1/C2) and **self-tuner** (C3) as pure, inert plane-2/3 algorithms — they *decide*, nothing *acts*. This RP is the one chunk that can change a live node: it **actuates** the decision, rotating the active transport within the closed set when the node's own detector says the active shape is degraded. It is split out of RP-0010 because it is the operator-facing / live-mutating half, held to a stricter dry-run-first + go/no-go discipline than the inert algorithm.

**The actuation is node-local only.** Each node plans and applies for itself, from its own detector verdict + own tuner ranking — there is no cross-node coordination, so a bad rotation on one node cannot propagate. A global/peer signal can never reach the decision (AC-4); a rotation can never grow the protocol set (AC-5).

## Scope — three layers

1. **PLANNER (pure, new — `internal/spec/rotate.go` schema + `internal/rotate`).** The explicit Layer-2 rotation policy as a pure `Plan(PlanInput) → RotationPlan`: clean verdict → hold; else hysteresis (`FlipConfirmations`) → cooldown (`MinInterval`) → per-window rate budget (`MaxPerWindow`) / rollback latch → pick the highest-weight tuner-promoted closed-set candidate beating the incumbent by `MinWeightMargin`. Deterministic; the clock is a parameter; imports only `{fmt, time, internal/spec}`. `RecordOutcome` spends the rollback budget and latches to hold.
2. **EXECUTOR SEAM (thin, dry-run-first).** `myceliumctl rotate-plan` (stdin `PlanInput` → stdout `RotationPlan`, run on a Go-bearing node) + a node-bootstrap `flow_rotate` (`--rotate` arg) that applies a plan's params delta and runs the **existing** `render_candidate → validate_config (sing-box check) → promote_config → apply → verify_post_apply → rollback_config` path. **Default = dry-run** (render + validate, promote nothing — the existing `DRY_RUN=1` makes this free). No new apply mechanism.
3. **GATED LIVE LOOP (deferred).** The `--apply-rotation` promote branch + an auto-apply systemd timer that **ships disabled** and is enabled only by an explicit `--rotate-enable-loop` (never by `flow_bootstrap`). Behind the §6 go/no-go.

## Rotation policy (`DefaultRotationLimits`, no magic constants)

| Knob | Default | Purpose |
|---|---|---|
| `FlipConfirmations` | 3 | hysteresis — N consecutive impaired verdicts before any move (atop the C2 detector's own dead-zone) |
| `MinWeightMargin` | 0.1 | a candidate must beat the incumbent tuner weight by this much (no ping-pong between near-equal shapes) |
| `MinInterval` | 15m | minimum between two promotions (cooldown) |
| `MaxPerWindow` / `Window` | 2 / 1h | rate limit (anti-beacon) |
| `MaxRollbacksPerWindow` | 1 | rollback budget — after this the planner **latches into hold** and leaves last-known-good running |
| `CooldownAfterRollback` | 1h | hold-only span after any rollback |

"Rotate back" is the natural consequence of the C3 decay law (a just-blocked shape fades toward `RetentionFloor` and re-promotes once clean verdicts return), not a separate rule. `regen-reality` rotates only a member's REALITY keypair/shortID (a transport parameter, permitted per development.md §2.2 #1) — never the node identity or the pinned donor SNI (§8.7).

## Chunking

- **C4a — pure planner + gates + tests (LANDED).** `internal/spec/rotate.go` (the closed `RotationAction`/`RotationReason` enums, `RotationCandidate`/`RotationLimits`/`RotationState`/`RotationPlan` + pure `Validate`), `internal/rotate` (`Plan` + `RecordOutcome` + `DefaultRotationLimits`). Gates `rotator_pure_planner` (purity/determinism/local-only) + `rotate_closed_set_only` (AC-5). The whole AC-4/AC-5/anti-flap decision, provable offline. INERT — nothing calls `Plan` in production.
- **C4b — executor seam, dry-run-first.** `myceliumctl rotate-plan` + `control/lib/nb_rotate_apply.sh` (`flow_rotate` + `apply_rotation_to_params`) + `--rotate`, reusing the existing apply path, **promote branch not reachable by default**. Extends `no_new_control_decisions_in_bash`. Runs the 4-node drill **Step 1** (dry-run).
- **C4c-1 — gated live apply (LANDED).** The `--apply-rotation` promote→verify→rollback branch in `control/lib/nb_rotate_apply.sh` (`rotate_apply_live`), behind a TRIPLE GATE: dry-run default · `--apply-rotation` (`ROTATE_APPLY=1`) + `DRY_RUN=0` · a node-local arm sentinel (`$STATE_DIR/rotate-live.enabled`, `--rotate-arm`, never committed). The rotation persists through the operator-overrides overlay (so it survives `write_params`/`--update`); EVERY failure edge reverts the overlay (subshell-wrapped so a `write_params`/`render_candidate` `die` is catchable) and a post-apply rollback records the outcome via `myceliumctl rotate-record` (the pure `RecordOutcome`: rollback budget + hold latch). The `enable_key`/`port_key` come from the committed registry (`control/vocab.json`, single source — §2.2 #8), not a bash convention. Gate `rotate_dry_run_default` → `rotate_apply_gated` (triple gate + revert-safety + no-implicit-actuation + no-auto-arm). **INERT on deploy** — `flow_rotate` is reached only by the explicit `--rotate` dispatch; an auto-pull changes no node's behaviour.
- **C4c-3 — the live drill (LANDED, supervised — see §5.1).** The drill on node A=m1 (P2={m3,m4} untouched): Step-1 dry-run + live promote/verify (Case 2), rollback+revert (Case 3), latch (Case 4), anti-flap (Case 5), undo/teardown (Case 6), invariants + safety-net (Cases 7–8). All PASS; A restored byte-identical. The §6 go/no-go was GREEN in order before any live actuation.
- **C4c-2 — disabled unattended timer (remaining).** The auto-apply systemd timer that ships DISABLED + the explicit `--rotate-enable-loop`. A separate, individually-revertible operator decision (RP §6: out of scope for the first drill).

## Acceptance criteria (verifiable)
- **AC-1 (recover-without-human):** degrade the active transport on a node → a stock client recovers within single-digit minutes with no manual action, via client-native failover + the node's rotation; the node logs a class-level event.
- **AC-4 (advisory-never-actuates):** the decision consumes only the node's local verdict + local weights; `PlanInput` has no global/peer/digest field (a reflect test pins it); rotation never auto-bans or force-routes from a shared signal.
- **AC-5 (no protocol growth):** rotation stays within the closed set — no add-transport action, an out-of-registry proto fails `Validate`; `per_protocol_toggle` / `phase0_port_canon` / `transport_family_independence` stay green across a rotation.
- **Anti-flap:** under steady degradation, at most `MaxPerWindow` rotations per `Window` and one per `MinInterval`; oscillation inside the `MinWeightMargin` band yields zero rotations.

## 5. The 4-node test plan (operator drill)

Populations **P1 = {A, B}**, **P2 = {C, D}** (abstract — no locations). The Go-toolchain node is **A** (runs `go test` + `rotate-plan`); the jq-only sing-box nodes apply deltas; the Xray-only no-auto-update node is never wired into `flow_rotate`.

- **Safety-net invariant (held throughout):** P2 = {C, D} stays clean and untouched — no `flow_rotate` ever runs on C or D. The network is always up via P2. Rotation is strictly node-local, so a bad rotation on A cannot reach B/C/D.
- **Reversible degradation (on A only):** a local nft rule that drops/rate-limits the active member's listen port (operator-flippable, NOT a real adversary action). The detector classifies blocked/throttled, the tuner weight fades, the planner picks a healthy sibling. Restoration = remove the rule.
- **Staged procedure:**
  - **Step 1 — dry-run (default):** `--rotate` (no `--apply-rotation`): assembles `PlanInput`, plans, renders the candidate, passes `sing-box check`, **promotes nothing** (live config byte-identical). P2 untouched.
  - **Step 2 — explicit live apply (A only):** `--rotate --apply-rotation` → promote → `verify_post_apply`; a stock client recovers via failover, no manual action.
  - **Step 3 — rollback proof (A):** induce a candidate that passes `sing-box check` but fails `verify_post_apply`; assert `rollback_config` restores last-known-good and, after `MaxRollbacksPerWindow`, the planner latches to hold.
  - **Step 4 — undo:** remove the nft rule; the tuner re-promotes the original member without teardown; A converges back.
- **Metrics:** AC-1 = wall-clock first-impaired-verdict → `verify_post_apply` success < single-digit minutes; anti-flap = ≤ `MaxPerWindow` promotes/hour each ≥ `MinInterval` apart; AC-5 = inbound transport-class set stays a subset of `spec.TransportClasses()`; AC-4 = no `ConnState`/`DetectReason` on any wire artifact, logs class-level only.

### 5.1 Drill execution record (C4c-3, 2026-06-19 — PASS)

Run on the live network, node **A = m1** (the only Go node; the live loop needs the `rotate-plan`/`rotate-record` binary). **P2 = {m3, m4}**; the Xray node (m2) was excluded (never `flow_rotate`-wired). A's pre-drill state was snapshotted; a teardown trap restored it unconditionally. Because the MEASURE plane is not yet on-node, the `PlanInput` verdict was hand-assembled (faithful actuation; auto-assembly is a later chunk). The rotation target was the default-on `vless-reality-grpc` toggled OFF→ON (the only cleanly-servable sibling on this sing-box: `shadowsocks`/`shadowtls` need a psk and `vless-reality-xhttp`/`xhttp-tls` are Xray-only — the dry-run correctly **refused** each, fail-closed, changing nothing).

- **§6 go/no-go:** whole `tests/run.sh` 35/35 + `go test ./internal/rotate ./internal/spec ./cmd` ✓; **Step 1 dry-run on A** rendered + `sing-box check` + promoted nothing (live config byte-identical, overlay `{}`) ✓; P2 confirmed serving ✓.
- **Step 2 — live apply (Case 2):** `--rotate --apply-rotation` on the armed node promoted grpc, restarted sing-box, `verify_post_apply` PASS; 8443 served; the overlay persisted the rotation. ✓
- **Step 3 — rollback (Case 3):** with 8443 occupied (induced bind failure that passes `sing-box check` but fails `verify_post_apply`), `rollback_config` restored last-known-good, `revert_rotation_overlay` restored the pre-rotation snapshot (so the failed rotation cannot re-apply next tick), and `record_rotation_rollback` spent the budget + set `HoldUntil`. **Latch (Case 4):** the next plan with `now < HoldUntil` returned `act:false, reason: rollback-hold`. ✓
- **Anti-flap (Case 5):** a candidate inside the `MinWeightMargin` band → `act:false, no-better-candidate` (zero rotation). ✓
- **Step 4 — undo / teardown (Case 6):** A restored to the byte-identical baseline (vision+grpc, config hash match), disarmed, overlay `{}`. ✓
- **Invariants:** served classes stayed `⊆ {reality-tcp}` (AC-5); the plan carried `RotationReason`, never `ConnState`/`DetectReason` (AC-4); **P2 {m3,m4} untouched** (sing-box active, no `rotate_state`, never armed — Case 8). ✓
- **AC-1 split:** the NODE-side recovery (healthy sibling promoted + serving) is proven here; the end-to-end *stock-client-recovers-under-a-real-block* half is human-validated on a device (like the Phase-1 acceptance), deferred — it needs the sibling endpoint in the client sub + the MEASURE plane.

## 6. Top safety risks + the go/no-go gate

Risks (all mitigated): accidental live actuation on a fresh node (triple gate: dry-run default + `--apply-rotation` required + timer ships disabled); silent emergency path (exactly one promote edge, all limits in the pure `Plan`); rotation-as-beacon (rate limit + two hysteresis bands); rollback thrash (budget → hold latch via `RecordOutcome`); valid-schema-but-breaks-service candidate (reuse `verify_post_apply` + `rollback_config`); AC-5 growth (no add action, registry-anchored `Validate`); AC-4 violation (no global input field exists); purity erosion (the planner gate + injected clock).

**GO/NO-GO before any live test (C4c / drill Steps 2–4), all GREEN in order:**
1. Whole `tests/run.sh` passes on the Go node — including the new gates and all stay-green regressions.
2. `go test ./internal/rotate/... ./internal/spec/... ./cmd/...` passes.
3. Drill **Step 1 (dry-run on A)** proves render + validate + **promote-nothing**.
4. **P2 = {C, D} confirmed untouched and serving** (the safety net is in place before A actuates).

Only then does the operator explicitly run `--rotate --apply-rotation` on **A only**. The unattended loop is a separate, individually-revertible operator decision, out of scope for the first drill.
