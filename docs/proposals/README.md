<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP — Refactoring / Change Proposals

Each RP describes the **work and migration** for an architecturally significant change (how we
migrate the system). The decision "why this way" is recorded in an ADR — see [../adr/](../adr/).

- **Template:** [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md)
- **Policy and mandatory sections:** [../refactoring.md](../refactoring.md) §13
- **Numbering:** `NNNN-<slug>.md`, ID `RP-NNNN` (zero-padded, monotonically increasing, separate sequence).
- **Commit:** the subject of the implementing commit carries `RP-NNNN ...` (see [../commit-template.txt](../commit-template.txt)).
- **Blast-radius cap:** one RP = one manageable step (§3.2 of template); exceeding the cap → split/declare multi-phase.

## Current records
| ID | Title | Status | Phase |
|---|---|---|---|
| [0001](0001-bootstrap-phase-0-node.md) | Bootstrap node Phase 0 (VLESS+REALITY + cover) | landed | Phase 0 |
| [0002](0002-phase0-live-verified-hardened-node.md) | Phase 0: scaffold → live, verified, hardened single node | landed | Phase 0 |
| [0003](0003-network-rollout-signed-self-updating.md) | Network rollout: canonical bootstrap → signed, self-updating network | active | cross-cutting deploy/bootstrap |
| [0004](0004-network-weather-explorer-publisher.md) | Network-weather explorer: off-network publisher + static site | draft | cross-cutting Measurement track |
| [0005](0005-inoculum-bundle-and-toolkit.md) | Inoculum: signed operator starter bundle, v0 schema, local-only toolkit | draft | not before Phase 2 |
| [0006](0006-in-region-edge-reporting.md) | In-region edge reporting: opt-in edge reachability signal (inert EdgeReport schema now) | draft | not before Phase 2 |
| [0007](0007-phase1-distribution-health-xhttp.md) | Phase 1: matured distribution + health/failover + an XHTTP-over-real-TLS LTE channel (Phase-0 GO signed 2026-06-15 → authorized; live status in the acceptance ledger) | active | Phase 1 (active) |
| [0008](0008-go-spine-distribution-rendering.md) | Consolidate distribution-rendering control logic in the Go spine (strangler: typed contracts → Go-owned vocab/mapping → ported renderers; "no control-decisions-in-bash") | active | cross-cutting (P1 Phase 1, P3 not before Phase 2) |
| [0009](0009-node-bootstrap-decomposition.md) | Decompose the node-bootstrap god-object (2130-line monolith → orchestration-only entrypoint + focused `control/lib/*.sh` modules; OS-glue stays bash, control-logic modules earmarked for the RP-0008 Go migration; staged behaviour-preserving chunks + a no-new-control-decisions-in-bash gate) | draft | cross-cutting (control-plane structure) |
| [0010](0010-phase2-adaptivity.md) | Phase-2 adaptivity — detect → adapt → self-tune over the CLOSED transport set (not new protocols). WRAP `internal/reach` (measure); BUILD the connectivity-state detector {clean/throttled/blocked/shutdown}; ADOPT the Physarum control law onto `spec.DecayPolicy` for the auto-rotation self-tuner. Events stay class-aggregate/advisory-never-actuates (ADR-0030); executes the ADR-0031 verdicts | draft | Phase 2 |
| [0011](0011-phase2-fungi-packaging-and-cli.md) | Phase-3 fungi-role packaging + deployment/management CLI — a release package + minimal CLI so other operators can stand up a fungi (the population coordinator role) and anastomosis can be tested at the Phase-3→4 boundary. Fungi = a ROLE (4 functions: hold population, issue/refresh bundle, collect redacted weather, bridge with other fungi); Briar-style double-opt-in introduction with hard constraints (1–2 hop depth, max degree, TTL invitations, no neighbour-list sharing, no transitive trust); the invariant "a fungi MAY introduce, MUST NOT enumerate". Built on the Go spine (continues RP-0008 P3). **Scope expanded 2026-06-20** to the Phase-3 **Operability & Release** track: a single unified node form (one node-local descriptor, capabilities-not-types — [ADR-0034](../adr/0034-unified-node-profile.md)) + the installer/management CLI verbs (deploy / transport / reachable / cdn / status) + node diagnostics with a redacted bug-report bundle + the CI/release/badges surface; sibling to the cross-cutting Advisory Network Awareness ([ADR-0030](../adr/0030-advisory-network-awareness.md)); roadmap re-phased 2026-07-02 (Phase 2 = single-node adaptivity; this = new Phase 3) | active | Phase 3 (federation runtime → P4-5) |
| [0012](0012-phase2-auto-rotation-actuation.md) | Phase-2 auto-rotation actuation — the live-mutating half of the RP-0010 ADAPT plane, split into its own RP for a stricter dry-run-first + go/no-go discipline. Pure rotation PLANNER (`internal/rotate`: hysteresis → cooldown → rate budget / rollback latch → highest-weight closed-set candidate) + a dry-run executor seam reusing the existing render→validate→promote→verify→rollback path + a gated live loop. Node-local only (AC-4), within the closed set (AC-5); includes the 4-node 2-population degrade/recover test plan | active | Phase 2 |
| [0013](0013-phase3-e2e-client-recovery.md) | Phase-3 end-to-end client recovery — the first Phase-3 workstream (opened after the Phase-2 GO-sign). Proves the loop closes **at the client**: a stock client on a standard subscription recovers on a sibling within single-digit minutes under a real/artificial block, measured **at the client**, no human action, and **repeatably**. Codifies the e2e recovery contract (always ≥2 independently-reachable siblings; client failover not defeated; subscription refreshes after a rotation), a scripted-block → measured-recovery harness + on-device confirmation, and the DoD-3 e2e acceptance. No new actuation, no cross-node coordination (AC-4/AC-5 preserved) | draft | Phase 3 |
