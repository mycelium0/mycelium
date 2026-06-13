<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR — Architecture Decision Records

Each ADR records **one** architecturally significant decision and its context. An ADR is the "why
this way" (decision); the "how we migrate the system" is described by an RP in [../proposals/](../proposals/).

- **Template:** [../templates/adr.md](../templates/adr.md)
- **When to write / policy:** [../development.md](../development.md), [../refactoring.md](../refactoring.md)
- **Numbering:** `NNNN-<slug>.md`, slug kebab-case, `NNNN` zero-padded and monotonically increasing (separate sequence from RP/Audit/Vision).
- **How to add:** copy the template → next free `NNNN` → fill in → Status `proposed`; commit with a type-prefix subject (`docs: …`) and an `Implements: ADR-NNNN` trailer — never the ADR id in the subject (see [../development.md](../development.md) §6.2).

## Current records
| ID | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Maintain ADRs | accepted |
| [0002](0002-no-custom-cryptography.md) | Do not reinvent cryptography | accepted |
| [0003](0003-licensing-and-jurisdiction.md) | Licence and jurisdiction | **accepted** |
| [0010](0010-phase0-transport-set.md) | Phase 0 modern transport set + engine selection | **accepted** |
| [0011](0011-carrier-agnostic-bridging.md) | Carrier-agnostic bridging and spore channels | proposed |
| [0012](0012-go-primary-control-plane-language.md) | Go as the primary control-plane language (Rust for sealed organs) | **accepted** |
| [0013](0013-mycelial-vocabulary-and-phase-discipline.md) | Mycelial vocabulary discipline + Phase 0-2 inert schemas | **accepted** |
| [0014](0014-per-operator-node-credentials.md) | Per-operator node credentials — no shared fleet key material | **accepted** |
| [0015](0015-fleet-artifact-delivery-and-node-update.md) | Fleet artifact-delivery and node-update model (signature-gated pull, fail-closed apply) | **accepted** |
| [0016](0016-software-releases-not-an-operated-network.md) | Software releases, not an operated network; community-consensus governance | **accepted** |

> Reserved (produced by ADR-0003): 0004 no-logs/retention ·
> 0005 classification as encryption item · 0006 legal wrapper for egress · 0007 role/jurisdiction
> separation · 0008 applicable-sanctions screening · 0009 distribution channels.
