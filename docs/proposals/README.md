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
| [0003](0003-fleet-rollout-signed-self-updating.md) | Fleet rollout: canonical bootstrap → signed, self-updating fleet | draft | cross-cutting deploy/bootstrap |
