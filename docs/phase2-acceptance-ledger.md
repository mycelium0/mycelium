<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Phase-2 GO/NO-GO acceptance ledger

The single artifact that authorizes closing **Phase-2's single-node-adaptivity core**. Per
[ROADMAP.md](ROADMAP.md) ("Phase-transition principle"), **a phase does not close until its
Definition of Done is met** — not when the code merely exists. This ledger maps the Phase-2
single-node-adaptivity Definition of Done (the ROADMAP "Phase 2 — Single-node adaptivity + the first
release" section, honestly re-phased 2026-07-02, brought current to Decision B 2026-07-04) to status,
evidence, and owner. It is the authoritative status for the adaptivity core.

The adaptivity core is scoped to **exactly one thing: the node-local `measure → detect → tune → rotate →
rollback` loop on a single node.** End-to-end *client* recovery and the operability/release track are
the **closing first-release milestone of Phase 2** (single-node concerns; see ROADMAP Decision B), and
the advisory/fungi boundary is built here as an **inert seam** that **goes live in Phase 3 (live
intra-Commune hypha)** — none of these are adaptivity-core acceptance criteria.

> **Decision C (2026-07-22) — the first-release bar is reached.** The adaptivity CORE (this ledger, GO'd
> 2026-07-03) + end-to-end client recovery ([RP-0013](proposals/0013-phase3-e2e-client-recovery.md)) +
> detector hardening ([RP-0014](proposals/0014-phase2-detector-hardening.md)) + the client-fingerprint knob
> and gated rotation ([RP-0015](proposals/0015-fingerprint-adaptivity.md), live-drill-validated on a node)
> together constitute the **fixed first-release bar**. What remains to cut the release is the release
> MECHANISM (reproducible signed artifacts + verify, a QUICKSTART) — an operator decision, not another
> adaptivity RP. Further single-node client→node hardening (transport-delivery fragmentation
> [RP-0016](proposals/0016-transport-delivery-hardening.md) + future axes) is the **post-release
> client-side-hardening track** (ROADMAP Decision C); it gates neither the release nor Phase 3.

> **Current verdict: GO — Phase-2 single-node-adaptivity core ACCEPTED 2026-07-03** (operator sign-off
> recorded below). On a live node the node-local self-drive loop closed autonomously: an induced
> degradation was detected, the impaired-verdict streak persisted to the flip threshold under the
> anti-flap guard, the planner emitted a rotation, and the rotation was **recorded** with the rate/latch
> limits and rollback path in force — the `measure → detect → tune → rotate → rollback` loop the DoD
> requires. Detector decisions are **measurable** (precision/recall on a labelled-incident corpus). The
> detection layer's L4-only blind spot (a bound-but-client-dead transport probing healthy) is closed for
> the REALITY + genuine-TLS families by the node-local L7 own-cert/cover-path probe
> ([ADR-0036](adr/0036-node-local-l7-liveness-probe.md)), and the fidelity hardening that made the
> self-drive robust (Audit-0007 S1 + all of S2) is landed and CI-green. Named first-release-milestone
> and hardening carry-forwards (end-to-end client recovery, the marker-replay anti-flap hardening, the
> remaining audit S3/NOTE items, cadence-default tuning, the on-node donor drill) are recorded below —
> hardening inputs, not adaptivity-core blockers. (No IPs/hostnames/donor-mappings/locations appear
> here, per the project OPSEC rule.)

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
   no server-side visible recovery; recovery there is **client-side failover** — which is the
   first-release-milestone end-to-end bar, not the adaptivity-core loop.

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
| End-to-end *client* recovery (a stock client recovering unattended) | **N/A — first-release-milestone bar by the DoD** | The adaptivity-core DoD explicitly names this the closing first-release-milestone bar of Phase 2; carried forward below. |

## Deferrals (named, not adaptivity-core blockers)

By Decision B (2026-07-04) these are **not gaps in the Phase-2 adaptivity-core acceptance**: the first
two are the **closing first-release milestone of Phase 2** (single-node concerns), and the advisory
publish path is an **inert seam** built here that **goes live in Phase 3**:

- **End-to-end client recovery** — a stock client on a standard subscription recovering within minutes,
  measured *at the client*. (Closing first-release-milestone DoD of Phase 2.) **Harness both-direction drill DONE 2026-07-05** (RP-0013 C2,
  `tests/e2e/`, on a live node): blocking the active REALITY endpoint → the client's `urltest` recovers on
  the genuine-TLS sibling in **20s**; forcing the client onto the ws-tls family then blocking it → recovers
  on REALITY in **16s**. Client-side auto-failover is symmetric and both directions land far inside the
  single-digit-minute bound; the block is scoped + reversible and never touches the served config. The
  **on-device** authoritative run on the operator's real restrictive link (the Phase-1 realism backstop)
  remains the operator's part.
- **Block-event publish path** — the first production caller of the node-status digest, i.e. publishing
  the node-local verdict as class-aggregate advisory weather. (Advisory/fungi seam is built **inert**
  here as Phase-2 groundwork; publishing it as advisory weather **goes live in Phase 3**.)
- **Operability & release** — `make dist` + signed release, the fungi deploy/management CLI, the unified
  node descriptor. (Closing first-release-milestone operability track of Phase 2.)

## Hardening follow-ups (carried into the closing first-release milestone)

Made concrete by the drill and the Audit-0007 remediation; each is a hardening input, not an
adaptivity-core blocker:

1. **Marker-replay anti-flap hardening (Audit-0007 S2-5a) — RE-DRILL DONE 2026-07-05 (v0.2.29 milestone).**
   The daemon re-reads the L7 marker every tick until it ages out, so one dead probe *generation* could
   satisfy the tick-based anti-flap on its own. The fix — fault only after ≥N **distinct** dead generations
   (`MEASURE_L7_MIN_DEAD_GEN=2`) — shifted the detect→rotate latency and needed a self-drive re-drill.
   **Re-drilled on a live node:** an induced L7-DEAD REALITY active (blackholed `dest`, L4 listener up) drove
   an autonomous rotation to the genuine-TLS sibling in **~8 min** end-to-end (single-digit ✓), on the
   tightened L7 cadence (120±45s, max-age 420k, min_dead_gen=2). The planner anti-flap streak
   (`flip_confirmations` × the ~90s rotate-loop), not the probe cadence, now bounds the tail. Restored clean
   after the fault cleared. Documented in ADR-0036.
2. **Remaining audit S3/NOTE.** Stale ShadowTLS fallback literal; genuine-TLS probe SAN-match
   (`-verify_hostname`); the deploy-time `donor_verify` rc=2 fail-open/-closed posture (a security-posture
   decision); `MAX_AGE` cadence cross-check; the zero-sample-window fold note.
3. **Cadence-default tuning — DONE 2026-07-05 (v0.2.29).** reach/L4 cadence tuned earlier (`21606a5`,
   ~2–3min); the L7 cadence tightened (`4b40299`: interval 300→120s, jitter 120→45s, max-age 900k→420k,
   `min_dead_gen` kept 2). The re-drill above measured ~8min L7 recovery (single-digit). Operator **accepted
   ~8min** and chose NOT to tighten the anti-flap further (it would trade flap-headroom for a marginal gain).
4. **Rotation visibility on all-transports nodes.** Where every transport is already served, a
   server-side "promote-sibling" is a no-op; recovery there is client-side failover (the closing first-release-milestone e2e bar).
   Re-pointing the active reference / surfacing the rotation is a visibility follow-up.
5. **On-node gold-standard donor drill.** The randomized-port + `flock` donor-verify hardening (S2-3) is
   proven by a control-flow harness; a live drill on a node (`www.samsung.com` → viable, `www.microsoft.com`
   → broken, with the real engine) is the remaining gold-standard confirmation.
6. **Force-push / history-rewrite un-sticks nodes MANUALLY (found 2026-07-05).** The updater's
   `git merge --ff-only` (`nb_update_apply.sh`) intentionally refuses a non-fast-forward, so a legitimate
   history rewrite (e.g. a credential scrub) orphans a node's checkout and its auto-update then fails
   fail-closed. One node was found stuck on a pre-rewrite rev with a stale spine; the fix is a deliberate
   `git reset --hard origin/main` per node (an explicit acceptance of the rewrite), after which the normal
   `--update` rebuilds the spine (now from the pinned Go). NOT a code change — the FF-only merge is the
   anti-force-push guard. Documented in [docs/runbooks/node-bootstrap.md](runbooks/node-bootstrap.md).

## Sign-off

- **Operator GO:** recorded 2026-07-03 — the node-local `measure → detect → tune → rotate → rollback`
  loop closed autonomously on a live node; detector decisions are measurable; the detection-fidelity
  hardening (Audit-0007 S1 + all of S2) is landed and CI-green. **Phase-2 single-node-adaptivity core
  ACCEPTED.** End-to-end client recovery and the release track are the closing first-release milestone
  of Phase 2, and the advisory/fungi boundary — built inert here — goes live in Phase 3, per Decision B.
- **Engineering plane:** the offline conformance suite (65 gates) is green; the Go spine builds and passes
  `go vet` / unit tests / `-race`; every Audit-0007 S1 + S2 remediation commit is CI-green on `main`. The
  Phase-2-closing first release ships as **v0.2.29** — the repository's first signed release tag, cut from
  `internal/spec.Version` = 0.2.29 (CHANGELOG `[0.2.29]`).
