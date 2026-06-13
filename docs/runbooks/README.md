<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbooks — operational procedures

Step-by-step operational procedures: what to do by hand (or by script) in a specific situation.
This is a persistent private network — downtime means people without network access, so
procedures must be fast and pre-tested.

- **Naming:** `<verb>-<object>.md`, e.g. `deploy-node.md`, `rotate-ip-as.md`, `incident-blocking-wave.md`.
- **When to add:** whenever an operation is performed repeatedly or under pressure (incident).
- **Relationship:** an RP that changes an operational procedure must add or update the relevant runbook (see [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md) §8).

## Current runbooks (landed)
- `deploy-node.md` — deploy a node from scratch (RP-0001).
- `node-bootstrap.md` — one-command ON-node bootstrap + semi-auto network updater (push-to-update).
- `rotate-ip-as.md` — migrate by IP/AS after a blocking event.
- `reality-rotation.md` — manual Phase-0 REALITY cover-identity rotation (deliberately changes links).
- `node-as-inventory.md` — AS-diversity inventory template + invariants (real values → `*.local.md`).
- `verify-phase0-acceptance.md` — the operator-owned Phase-0 acceptance proofs (D1/D2/rotation/D4/GO)
  that flip the acceptance ledger NO-GO → GO.

## Planned (Phase 1–2)
- `incident-blocking-wave.md` — response to a transport blocking wave.
