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
| [0001](0001-bootstrap-phase-0-node.md) | Bootstrap node Phase 0 (VLESS+REALITY + cover) | draft | Phase 0 |
| [0002](0002-phase0-live-verified-hardened-node.md) | Phase 0: scaffold → live, verified, hardened single node | draft | Phase 0 |
| [0003](0003-network-rollout-signed-self-updating.md) | Network rollout: canonical bootstrap → signed, self-updating network | draft | cross-cutting deploy/bootstrap |
| [0004](0004-network-weather-explorer-publisher.md) | Network-weather explorer: off-network publisher + static site | draft | cross-cutting Measurement track |
| [0005](0005-inoculum-bundle-and-toolkit.md) | Inoculum: signed operator starter bundle, v0 schema, local-only toolkit | draft | not before Phase 2 |
| [0006](0006-in-region-edge-reporting.md) | In-region edge reporting: opt-in edge reachability signal (inert EdgeReport schema now) | draft | not before Phase 2 |
| [0007](0007-phase1-distribution-health-xhttp.md) | Phase 1: matured distribution + health/failover + an XHTTP-over-real-TLS LTE channel (gated NO-GO behind the Phase-0 GO signature) | draft | Phase 1 (after GO) |
