<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Phase-2 GO/NO-GO acceptance ledger

The single artifact that authorizes the **Phase-2 → Phase-3 transition**. Per
[ROADMAP.md](ROADMAP.md) ("Phase-transition principle"), **Phase 3 does not begin until Phase-2's
Definition of Done is met** — not when the code merely exists. This ledger maps the Phase-2 Definition
of Done (the ROADMAP "Phase 2 — Single-node adaptivity" section, honestly re-phased 2026-07-02) to
status, evidence, and owner. It is the authoritative Phase-2 status.

Phase 2 is scoped to **exactly one thing: the node-local `measure → detect → tune → rotate → rollback`
loop on a single node.** End-to-end *client* recovery, the operability/release track, and the
advisory/fungi boundary are **Phase 3** by the re-phasing decision, not Phase-2 acceptance criteria.

> **Current verdict: GO — Phase-2 → Phase-3 transition AUTHORIZED 2026-07-03** (operator sign-off
> recorded below). On a live node the node-local self-drive loop closed autonomously: an induced
> degradation was detected, the impaired-verdict streak persisted to the flip threshold under the
> anti-flap guard, the planner emitted a rotation, and the rotation was **recorded** with the rate/latch
> limits and rollback path in force — the `measure → detect → tune → rotate → rollback` loop the DoD
> requires. Detector decisions are **measurable** (precision/recall on a labelled-incident corpus). The
> detection layer's L4-only blind spot (a bound-but-client-dead transport probing healthy) is closed for
> the REALITY + genuine-TLS families by the node-local L7 own-cert/cover-path probe
> ([ADR-0036](adr/0036-node-local-l7-liveness-probe.md)), and the fidelity hardening that made the
> self-drive robust (Audit-0007 S1 + all of S2) is landed and CI-green. Named Phase-3 carry-forwards
> (end-to-end client recovery, the marker-replay anti-flap hardening, the remaining audit S3/NOTE items,
> cadence-default tuning, the on-node donor drill) are recorded below — hardening inputs, not Phase-2
> blockers. (No IPs/hostnames/donor-mappings/locations appear here, per the project OPSEC rule.)

## Self-drive acceptance (the first armed drill)

The Phase-2 loop had been *built* (detector + tuner + measure + planner + gated rotation + rollback) but
never proven to complete a rotation **unattended**. The first armed self-drive drill on a live node was
therefore also the acceptance test — and it earned its keep: it surfaced **three layered bugs** that had
each silently prevented the unattended loop from ever closing, all fixed before sign-off:

1. **`--measure-enable` did not retire the legacy reach-only unit** → a `:9551` port conflict → the
   measure plane never started. (Fixed; the retire is now part of enabling the plane.)
2. **The rotation executor discarded `plan.next_state` on HOLD** → the anti-flap impaired-streak reset
   `0→1` every tick and never reached the flip threshold → it **never rotated**. (Fixed: HOLD persists
   `next_state`; MEASURE folds it back so the streak accumulates.)
3. **On an all-transports node, "promote-sibling" is a no-op** (the active reference is not re-pointed) →
   no server-side visible recovery; recovery there is **client-side failover** — which is the Phase-3
   end-to-end bar, not the Phase-2 loop.

After the fixes, on tightened probe/rotate cadences the node **autonomously** flipped clean → shutdown,
accumulated the impaired streak to the flip threshold, the planner returned `act = true`, and a rotation
was **recorded** (`rotations_in_window = 1`) — the loop closed. This is the DoD's `degrades → plan →
apply → rollback-available → refuse-stale`, observed end to end on the node.

## Acceptance scorecard (Phase-2 Definition of Done)

| DoD criterion | Status | Evidence |
|---|---|---|
| An active transport degrades → the node produces a rotation **plan** → **dry-run** preview + gated **live apply** → **rollback** works → stale/noisy signals are **refused** (anti-flap + staleness guard) | **PASS** | `internal/rotate` pure planner + gated live apply/rollback in `myceliumd` ([RP-0012](proposals/0012-phase2-auto-rotation-actuation.md)); the armed drill above closed the loop on a live node; `rotator_pure_planner`, `rotate_apply_gated`, `rotate_closed_set_only`, `measure_daemon_ships_disabled`/`measure_daemon_advisory` gates green. |
| Detector decisions are **measurable** (precision/recall on labelled incidents) | **PASS** | `internal/detect` pure classifier + stateful detector with a labelled-incident corpus and precision/recall + anti-flap tests ([RP-0010](proposals/0010-phase2-adaptivity.md) AC-2); `detector_pure_no_probe`, `detector_state_closed_vocab` gates green. |
| **Detection fidelity** — a bound-but-client-DEAD transport must not probe healthy (the L4-only blind spot) | **PASS (REALITY + genuine-TLS families; scoped)** | Node-local L7 own-cert/cover-path probe ([ADR-0036](adr/0036-node-local-l7-liveness-probe.md)) folds into `spec.DetectorSignal.ActiveProbeOK`; Audit-0007 S1 + all of S2 landed and CI-green (exec-bit, single-marker-producer + no third-party beacon, donor-probe port-race + `set -e` fix, planner co-failed-sibling exclusion, honest coverage). Coverage is **scoped** to the three families the L4 window cannot see (see follow-ups). |
| Adapts **route + behaviour** on one node; **does not grow the protocol set** | **PASS** | Rotation resolves only within the closed `TransportRegistry` (`rotate_closed_set_only`, AC-5); self-tuning weights (reinforce-and-evaporate) on `internal/tune`. |
| End-to-end *client* recovery (a stock client recovering unattended) | **N/A — Phase-3 bar by the DoD** | The Phase-2 DoD explicitly names this the Phase-3 bar; carried forward below. |

## Deferrals (named, not blockers — Phase-3 scope)

These are **Phase-3 by the re-phasing decision**, not gaps in Phase-2 acceptance:

- **End-to-end client recovery** — a stock client on a standard subscription recovering within minutes,
  measured *at the client*. (Phase-3 DoD.)
- **Block-event publish path** — the first production caller of the node-status digest, i.e. publishing
  the node-local verdict as class-aggregate advisory weather. (Phase-3 advisory/fungi inert seam.)
- **Operability & release** — `make dist` + signed release, the fungi deploy/management CLI, the unified
  node descriptor. (Phase-3 operability track.)

## Hardening follow-ups (carried into Phase 3)

Made concrete by the drill and the Audit-0007 remediation; each is a hardening input, not a
Phase-2 blocker:

1. **Marker-replay anti-flap hardening (Audit-0007 S2-5a).** The daemon re-reads the L7 marker every
   tick until it ages out, so one dead probe *generation* can satisfy the tick-based anti-flap on its own.
   The fix — fault only after ≥N **distinct** dead generations — shifts the drilled detect→rotate latency
   and so needs a **self-drive re-drill**. Documented as a known limitation in ADR-0036.
2. **Remaining audit S3/NOTE.** Stale ShadowTLS fallback literal; genuine-TLS probe SAN-match
   (`-verify_hostname`); the deploy-time `donor_verify` rc=2 fail-open/-closed posture (a security-posture
   decision); `MAX_AGE` cadence cross-check; the zero-sample-window fold note.
3. **Cadence-default tuning.** The armed drill closed the loop on *tightened* cadences; the shipped
   defaults (reach window, rotate timer) are conservative and want tuning against a single-digit-minute
   recovery target.
4. **Rotation visibility on all-transports nodes.** Where every transport is already served, a
   server-side "promote-sibling" is a no-op; recovery there is client-side failover (the Phase-3 e2e bar).
   Re-pointing the active reference / surfacing the rotation is a visibility follow-up.
5. **On-node gold-standard donor drill.** The randomized-port + `flock` donor-verify hardening (S2-3) is
   proven by a control-flow harness; a live drill on a node (`www.samsung.com` → viable, `www.microsoft.com`
   → broken, with the real engine) is the remaining gold-standard confirmation.

## Sign-off

- **Operator GO:** recorded 2026-07-03 — the node-local `measure → detect → tune → rotate → rollback`
  loop closed autonomously on a live node; detector decisions are measurable; the detection-fidelity
  hardening (Audit-0007 S1 + all of S2) is landed and CI-green. **Phase-2 → Phase-3 transition
  AUTHORIZED.** End-to-end client recovery, the release track, and the advisory/fungi boundary are the
  Phase-3 work, per the re-phasing decision.
- **Engineering plane:** the offline conformance suite (63 gates) is green; the Go spine builds and passes
  `go vet` / unit tests / `-race`; every Audit-0007 S1 + S2 remediation commit is CI-green on `main`.
