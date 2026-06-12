<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-NNNN: `<short decision title>`

> **Document type.** ADR (Architectural Decision Record) template. Records
> **one** architectural decision and its context. The finished ADR is saved as
> `docs/adr/NNNN-<slug>.md`, slug in kebab-case; `NNNN` is zero-padded and
> monotonically increasing (separate sequence from RP/Audit).
>
> **When to write an ADR.** Any architecturally significant decision that changes
> layer boundaries (data plane / control plane / routing / discovery), contracts
> between them, state or process ownership, the transport protocol matrix, the
> trust/sybil model, rotation policy, or introduces/removes an external stack
> dependency (Xray/sing-box/AmneziaWG/libp2p/Caddy/CDN). A decision that cannot
> be explained in one or two sentences is not yet ready for an ADR.
>
> **Relationship to RP.** An ADR records the *decision* ("why this way"); an RP
> describes the *work* ("how we migrate the system"). One does not replace the
> other: a significant RP that changes the canon references an ADR; an ADR that
> requires migration references an RP.
>
> **See also:** [refactoring-proposal.md](refactoring-proposal.md),
> [audit.md](audit.md), [../development.md](../development.md),
> [../refactoring.md](../refactoring.md), [../ARCHITECTURE.md](../ARCHITECTURE.md),
> [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Metadata
- **ID:** ADR-NNNN
- **Date:** YYYY-MM-DD
- **Author:** mindicator & silicon bags quartet
- **Status:** proposed | accepted | rejected | deprecated | superseded by ADR-MMMM
- **Layer(s):** data plane | control plane | routing/orchestration | discovery/membership | infra | cross-cutting track
- **Phase:** Phase 0–5 (see [../ROADMAP.md](../ROADMAP.md)); "cross-cutting" if the track spans all phases
- **Related:** <RFC/Vision / Audit-NNNN (F-NNN) / RP-NNNN / another ADR / external source>

## Context
What prompted the decision. What problem exists, what forces pull in different
directions, what constraints apply. **No solution options here — only the
situation.**

Record the following where applicable:

- **Adversary model.** What network adversary capability does this decision address
  (DPI signature / ML traffic classification / active probing / IP/AS blocking /
  UDP throttling or cutting / config-distribution blocking / sybil enumeration of
  ingress points / traffic correlation / operator coercion). Reference
  [../THREAT-MODEL.md](../THREAT-MODEL.md).
- **Affected asset.** User identity/location · traffic content · ingress
  reachability · operators · network map.
- **Fundamental trade-off**, if touched: the anonymity trilemma (latency ↔
  throughput ↔ anonymity), openness ↔ sybil-resistance,
  indistinguishability ↔ cost/latency, adaptation speed ↔ false-migration risk.

## Considered Options
> At least two real options. "Leave as is" is a valid option 0.

1. **<Option A>** — brief summary.
   - Pros: …
   - Cons: …
   - Impact on indistinguishability / survivability: …
2. **<Option B>** — brief summary.
   - Pros: …
   - Cons: …
   - Impact on indistinguishability / survivability: …
3. (optionally others)

## Decision
**<Option X>**, because …

Specifically (one or two paragraphs): which interfaces, which layer boundaries,
which behaviour becomes **canon**. If the decision concerns transport/obfuscation —
name the standard, audited primitive/library used (custom cryptography is
prohibited — see [../development.md](../development.md)). If it concerns the
control plane — how the decision keeps it **persistent** (management must not be
easier to block than data). If it concerns failure — what is considered
**fail-closed**.

## Consequences
- **Positive:** …
- **Negative / cost:** … (latency, capacity, operational complexity, expanded
  attack surface, new external dependency).
- **Impact on user security (requirement №1):** what the node now knows / does
  not know about the user; whether any logging or correlation is introduced;
  whether deniability and forward secrecy are preserved.
- **Impact on observability/measurements:** which detector/rotation signals are
  added or lost.
- **Follow-on actions required:** … (RP-NNNN, config updates, migration).
- **What is now forbidden:** … (the anti-pattern this ADR closes off).

## Compliance
How to verify the decision is respected in practice:
- conformance test (e.g. `no_custom_crypto`, `no_pii_in_telemetry`,
  `cover_site_probe`, `clienthello_in_range`, `fail_closed_on_block`,
  `control_plane_reachable_when_domain_blocked`) — name the specific test;
- lint rule / prohibition on magic-string endpoints and hardcoded secrets;
- netem/netsim scenario reproducing adversary behaviour
  (`rst_injection`, `as_blackhole`, `udp_drop`, `active_probe`);
- audit checkpoint / CI gate that blocks merge on violation.
