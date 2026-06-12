<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0001: Record Architecture Decisions via ADR

> This is the "zeroth" ADR: it establishes the ADR practice itself. All subsequent decisions
> reference it as the source of process.

## Metadata
- **ID:** ADR-0001
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** cross-cutting track (process / documentation)
- **Phase:** Phase 0 (engineering hygiene foundation; applies to all phases)
- **Related:** [../development.md](../development.md) §12, [../refactoring.md](../refactoring.md),
  [templates/adr.md](../templates/adr.md), [README.md](README.md)

## Context

Mycelium travels from a single VLESS+REALITY node toward a decentralized, self-healing mesh
(see [../ROADMAP.md](../ROADMAP.md), phases 0→5). The layers are stable across phases; their
implementations change — but that is precisely why the **reasons** behind boundary decisions
(why the control plane rides the same covert channels as data; why ingress and egress are
separated; why custom cryptography is forbidden; why the Phase 3 coordinator is a consciously
accepted temporary liability) must outlast implementation churn and team turnover.

Competing forces:

- The project targets persistent private networking across unreliable networks: many decisions are dictated by the **threat model**
  ([../THREAT-MODEL.md](../THREAT-MODEL.md)) and **law** (detailed legal and compliance analysis
  is maintained in the maintainers' internal knowledge base). Those decisions cannot be held only
  in memory — the cost of error is high and often irreversible (jurisdiction choice, log
  retention, exposure of ingress nodes).
- Work proceeds via PR with multiple contributors. Without written decision records, a blame/audit
  trail cannot distinguish "we decided this" from "this just happened".
- Canon without explanation of "why" invites drift: a new contributor reopens already-closed
  forks or quietly violates a layer boundary.

The existing canon ([../development.md](../development.md), [../refactoring.md](../refactoring.md))
already requires documenting architecturally significant changes, but does not define a single
record format for the **decision itself**, separate from a work description (RP) or an audit.

## Options Considered

1. **No ADRs; record decisions inside RPs and commit history.**
   - Pros: fewer document types.
   - Cons: an RP describes *work*, not a long-lived *decision*; commit messages are not
     searchable as canon; "why" dissolves. Explicitly forbidden state — "hold architectural
     decisions only in memory" / "code as the sole documentation"
     ([../development.md](../development.md) §15).

2. **Maintain one consolidated architectural-decisions document (a decision changelog).**
   - Pros: single place.
   - Cons: a monolith reviews poorly in PRs, conflicts under parallel work, and gives no stable
     ID per decision for cross-references (ADR-NNNN from RP, from audit, from code).

3. **ADR: one decision = one file `docs/adr/NNNN-<slug>.md`, monotonically numbered, fixed
   template, statuses proposed/accepted/rejected/deprecated/superseded.**
   - Pros: stable ID for references; review scoped to one decision; explicit lifecycle
     (including `superseded by`); separates "why" (ADR) from "how" (RP) and "what's wrong now"
     (Audit). Matches [templates/adr.md](../templates/adr.md).
   - Cons: another document type and the discipline to maintain it.

## Decision

**Option 3.** Every architecturally significant Mycelium decision is recorded as a separate ADR
in [`docs/adr/`](.) using the template [templates/adr.md](../templates/adr.md).

The following becomes canon:

- **File and ID.** `docs/adr/NNNN-<slug>.md`, ID `ADR-NNNN`; `NNNN` is zero-padded 4-digit,
  monotonically increasing, a **separate** sequence from `RP-NNNN` (proposals) and `Audit-NNNN`
  (audits); slug is kebab-case.
- **Status lifecycle.** `proposed → accepted | rejected`; an accepted ADR may later become
  `deprecated` or `superseded by ADR-MMMM`. ADRs are **never deleted or rewritten retroactively**
  — stale ones are marked with a status; the decision is replaced by a new ADR. This preserves
  traceability.
- **When an ADR is required.** Change to layer boundaries or inter-layer contracts; change of
  state/process ownership; change to the transport protocol matrix; change to the trust/sybil
  model; rotation/detection policy; introduction or removal of an external stack dependency;
  legal/jurisdictional forks. Triggers are synchronized with "architecturally significant change"
  ([../refactoring.md](../refactoring.md) §3).
- **Relationship to RP/Audit.** An RP that changes canon references an ADR (or creates one); an
  ADR requiring migration references an RP; an audit finding requiring a decision spawns an ADR.
  A commit implementing a decision carries `ADR-XXXX …` or `RP-XXXX …` in its subject line
  (see [../commit-template.txt](../commit-template.txt)).
- **Authorship.** Author of all ADRs: **mindicator & silicon bags quartet**.

## Consequences

- **Positive:** long-lived, traceable decision memory; a common reference language (ADR-NNNN)
  across code, RPs, and audits; a new contributor understands "why" without archaeological digs
  through commit history; decisions driven by threat model or legal constraints are recorded
  deliberately rather than dissolving.
- **Negative / cost:** maintenance discipline; risk of "ADR for its own sake" on trivial changes
  (mitigated by the triggers in §3 of refactoring.md — trivial changes travel as ordinary
  type-prefixed commits).
- **Follow-on work:** maintain [`docs/adr/README.md`](README.md) as the index; first substantive
  ADRs are [ADR-0002](0002-no-custom-cryptography.md) (no custom cryptography) and
  [ADR-0003](0003-licensing-and-jurisdiction.md) (license and jurisdiction).
- **What becomes forbidden:** holding architectural decisions only in memory or only in commit
  messages; changing canon without an ADR/RFC; rewriting an accepted ADR retroactively instead
  of marking it `superseded`.

## Impact on Project Invariants

- **Do not invent cryptography/transports:** the ADR is the place where this invariant is
  anchored and verified ([ADR-0002](0002-no-custom-cryptography.md)).
- **Indistinguishability > obfuscation:** transport/obfuscation decisions receive a written
  survivability rationale.
- **Redundancy and graceful degradation:** —
- **Adaptation driven by measurement:** the ADR template requires a Compliance section (how we
  verify), which pushes toward measurable decisions.
- **User safety is requirement #1:** legal/threat-driven decisions cease to be informal
  agreements; the cost of error is recorded in writing.

## Compliance

How to verify this decision is observed in practice:

- **Audit checkpoint.** PR-audit and full-scale audits ([../refactoring.md](../refactoring.md)
  §4) verify: is there an ADR behind each architecturally significant change; has an accepted ADR
  been retroactively rewritten; are RP↔ADR↔Audit cross-references correct.
- **Index.** [`docs/adr/README.md`](README.md) lists all ADRs; a missing ADR in the index or a
  dangling `superseded by` link is a documentation defect.
- **Numbering.** A duplicate `NNNN` or a break in monotonicity is a defect (caught in review;
  with tooling — a lint for ID uniqueness).
- **Commit trail.** An architectural commit with no reference to an ADR/RP is treated as an
  audit-trail bug ([../development.md](../development.md) §1.3), not a style note.
