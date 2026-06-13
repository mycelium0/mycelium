<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbook — node AS-diversity inventory

Phase-0 hosting guidance ([ROADMAP.md](../ROADMAP.md), Phase-0 scope: *"hosting selection with attention to
AS-level blocking — do not concentrate everything in one tainted AS"*) requires that the fleet be spread
across **distinct, independently-blockable autonomous systems**, and that this spread be **auditable** — a
single IP/AS block must never take out a disproportionate share of the fleet, and fresh capacity must be
held in reserve.

This runbook defines the inventory the operator keeps to make that auditable. **It carries no node IPs,
hostnames, or AS numbers in the repository** — those are operator state. Maintain the real inventory in a
local, gitignored file (`docs/runbooks/node-as-inventory.local.md`, ignored by convention); the table here
is the **template + the fleet's diversity rationale** in abstracted form.

## What to record (per node)
Keyed by the abstract node handle (`node-A`, `node-B`, …), **never the IP**:

| Field | Why it matters |
|---|---|
| Node handle | Stable label; the real IP/hostname lives only in the local inventory. |
| Region (coarse) | Geographic + jurisdictional spread; avoid clustering. |
| Provider | Avoid concentrating on one provider (correlated takedown / policy). |
| AS class | The autonomous system the egress sits in — the unit an adversary blocks at the AS level. |
| IP-reputation posture | Is the IP/range fresh, or does it carry prior taint (known VPN/abuse lists)? |
| Donor (REALITY) | Whether the node's pinned donor differs from its neighbours (fingerprint diversity); record *that it differs*, not the value. |
| Deploy date | Age + rotation cadence. |

## Fleet diversity invariants (the auditable bar)
- **≥3 distinct autonomous systems** across the fleet; no single AS hosts a majority of nodes.
- **≥2 distinct providers**; no single provider hosts a majority.
- **≥2 distinct regions/jurisdictions.**
- **1–2 fresh IPs held in reserve** in a *different* AS, ready for migration if a node's IP/AS is blocked
  (Phase-2 auto-migration builds on this; in Phase 0 it is a manual operator reserve).
- **Donor SNIs varied** across nodes (each node pins its own from `nodes/dataplane/donor-sni-candidates.json`).

## Current fleet (abstracted; real values in the local inventory)
| Node | Region (coarse) | Distinct AS? | Distinct provider? | Reserve IP? |
|---|---|---|---|---|
| node-A | (record locally) | yes | — fill — | — fill — |
| node-B | (record locally) | yes | — fill — | — fill — |
| node-C | (record locally) | yes | — fill — | — fill — |

**Status (2026-06):** the fleet runs **3 nodes in 3 distinct countries on 3 distinct autonomous systems**
(verified operationally; exact AS/provider/IP recorded only in the local inventory). The invariants above
are met for ≥3-AS / ≥2-region; the operator records the per-node AS/provider + confirms the reserve-IP slot
in the local inventory and reflects the audit outcome in the
[Phase-0 acceptance ledger](../phase0-acceptance-ledger.md) (hosting row).

## When to update
On every node add/remove/migrate, on a donor re-pin, and at each Phase-transition review. A blocked IP/AS
event triggers: migrate to a reserve IP in a different AS, then re-record.
