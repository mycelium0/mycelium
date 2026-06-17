<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Audit Report — `<short title>`

> **Document type.** Audit report template. Structure matches
> [../refactoring.md](../refactoring.md) (mandatory audit template + severity
> model + expert lenses). The finished report is saved as
> `docs/audits/NNNN-<slug>.md`, slug in kebab-case; referenced as `Audit-NNNN`.
> Findings are numbered `F-NNN`, action items `A-NNN` (3-digit).
>
> **Which blocks to use.** The full expert-lens block is mandatory for a
> **full-scale** audit. For a PR-audit or tactical audit a reduced form is
> acceptable: Executive Summary + Findings + Action Items (lenses by trigger).
>
> **See also:** [adr.md](adr.md), [refactoring-proposal.md](refactoring-proposal.md),
> [../development.md](../development.md), [../refactoring.md](../refactoring.md),
> [../ARCHITECTURE.md](../ARCHITECTURE.md), [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Header
- **Date:** YYYY-MM-DD
- **Scope:** <what is covered: layers / components / phase / track>
- **Version / branch / commit range:** `<component>` vX.Y.Z, `<branch>`, `<from>..<to>`
- **Participants:** <name / agent / auditor role>
- **Audit type:** PR-audit | tactical | full-scale | event-triggered

## Executive Summary
- **Overall assessment:** <one or two lines>
- **Key risks:** <list S0/S1>
- **Verdict:** `pass` | `pass_with_conditions` | `fail`
  - `fail` if there are unresolved S0/S1 findings, a red CI (lint / type /
    contract / conformance / netsim), or documentation not updated for a
    significant change.

### Expert Lens Scores (mandatory for full-scale audit)

> Lenses are the canon §6.2 eight-lens roster ([../refactoring.md](../refactoring.md)
> §6.2): four domain lenses (Security/Threat, Network-persistence, Anonymity/Privacy,
> Operational-resilience) plus four general lenses (McConnell, Parnas, Brooks, Dijkstra),
> read through the Mycelium lens: a distributed resilient mesh for persistent private
> networking where user security is functional requirement №1 and the adversary is adaptive.
>
> Security/Threat · Network-persistence · Anonymity/Privacy · McConnell —
> **always mandatory**. Operational-resilience — mandatory for any change to
> routing/control/discovery, for every phase transition, and for every
> post-incident audit. Parnas / Brooks / Dijkstra — by trigger: new
> transport or transport profile · change to discovery / sybil resistance /
> trust model · change to the contract between layers · change to a public
> node-facing or config-distribution surface · roadmap phase transition ·
> blast-radius > 20 files.

| Lens | Score | Verdict |
|---|---:|---|
| **Security / Threat** — user security as functional requirement №1 against an adaptive adversary: fail-closed under behavioral-layer detection/ML/probe/IP-AS/UDP-drop/domain-block/sybil/coercion, no leak path opened by a fallback, secrets and keys never widened in scope, explicit invariants on every critical flow, measurability of detector decisions (precision/recall), absence of "magic" branching instead of a contract. | N / 10 | … |
| **Network-persistence** — survival of connectivity under blocking and rotation: formalised channel-state transitions (`clean / throttled / blocked / shutdown`), idempotency of repeated rotation commands, **anti-flapping and bounded recovery time** (no oscillation), local node autonomy when the control plane is unreachable, restart-survival of the persistence path. | N / 10 | … |
| **Anonymity / Privacy** — minimisation of metadata and de-anonymisation surface: no new correlation handle across nodes/flows, telemetry carries no identifying or locating signal, public contracts (config distribution / telemetry / control) do not expose topology or membership, observability does not weaken the anonymity set. | N / 10 | … |
| **Operational-resilience** (mandatory for routing/control/discovery changes, phase transitions, and post-incident audits) — runtime/processes/fault tolerance: clear boundary between substrate-OS and node-agent (the agent does not substitute the kernel/systemd/firewall), node process lifecycle (start/running/degraded/failed/recovered), supervision and restart strategy, isolation of hardware/network faults from domain semantics, timeout/cancel/retry taxonomy at the network edge. | N / 10 | … |
| **McConnell** — construction quality and maintainability: locality of changes, clear names, no divergence between code ↔ README ↔ ADR ↔ RP ↔ CHANGELOG ↔ runbook, tests alongside the change, migration and rollback present, version bump reflects real blast-radius, no stale comments used as boundary definitions. | N / 10 | … |
| **Parnas** — information hiding and modularity (by trigger): vendor/protocol details hidden behind an adapter boundary (Xray/sing-box/AmneziaWG/libp2p), consumers do not reach into the internals of a neighbouring layer, public contract instead of access to private fields, transport implementation is replaceable without rewriting consumers. | N / 10 | … |
| **Brooks** — conceptual integrity (by trigger): one architectural story (five layers, interconnected mesh), no proliferation of "managers/controllers" without ownership semantics, temporary form does not become canon, the system is explainable through a small set of stable rules. | N / 10 | … |
| **Dijkstra** — simplicity and correctness (by trigger): flows simplified without losing ownership; **no "clever" fallback that breaks fail-closed**; abstraction does not hide real side effects (key distribution, IP switching); no mixing of unrelated responsibilities in one method; state count does not grow unnecessarily. | N / 10 | … |

#### Summary
- **Strongest lens:** …
- **Weakest lens:** …
- **Main reason for weakest score:** …
- **Required action before next major RP:** … (a lens score < 6.0 requires
  explanation before the next major RP; < 5.0 blocks connection of a new
  layer/domain and must produce a finding ≥ S2, or ≥ S1 if the risk is
  significant).
- **Engineering Maturity Score (weighted, §6.4 of canon):** N.N / 10 — *guidance
  only, not a merge gate*.

## Objects reviewed
- **Layers/components:** <data plane / control plane / routing / discovery / infra>
- **Contracts:** <config distribution / transport config / telemetry-signal schema / control commands / capability>
- **Scenarios / flows:** <config delivery / auto-rotation on block / egress-route migration / node onboarding / bootstrap>
- **Documentation:** <links to ARCHITECTURE/THREAT-MODEL/ROADMAP/ADR/RP/runbook>
- **Observability / failure modes:** <which detector/rotation signals were checked; netsim adversary scenarios>
- **Adversary model tested against:** <behavioral-layer detection/ML/probe/IP-AS/UDP-drop/domain-block/sybil/coercion>

## Findings

> Severity (canon [../refactoring.md](../refactoring.md)):
> **S0** critical — immediate halt of merge/rollout; **S1** high — required before
> next major step / connecting a new layer; **S2** medium — next cycle; **S3** low —
> improvement plan; **NOTE** observation with no mandatory action.
>
> **Named Mycelium categories (default severity):**
> - `CUSTOM_CRYPTO` = **S0** — custom cryptography/transport instead of a
>   standard audited primitive (violates principle №1).
> - `USER_DEANON` / `PII_LEAK` = **S0** — node/telemetry knows or logs data that
>   de-anonymises the user or links traffic to an identity; a feature that trades
>   convenience for de-anonymisation.
> - `CONTROL_PLANE_OUTLIVED_BY_DATA` = **S0** — management/config distribution is
>   easier to block than the data plane (coordinator = kill switch, no fallback
>   channels).
> - `FAIL_OPEN` / `SILENT_SECURITY_BYPASS` = **S0** — silent security bypass or
>   leak to a cleartext channel on failure instead of fail-closed.
> - `DISTINGUISHABLE_FROM_HTTPS` = **S1** — traffic/banner/response to probing is
>   statistically or signature-wise distinguishable; cover site does not withstand
>   active probing.
> - `HIDDEN_CENTRALIZATION` = **S1** — hidden single point of failure /
>   unpluggable coordinator dependency that breaks "degradation, not failure"
>   (relevant for Phase 4–5).
> - `SYBIL_SURFACE_DRIFT` = **S1** — opening discovery/join without proportionate
>   sybil-resistance (ingress enumeration/flooding).
> - `FLAPPING_ROTATION` = **S2** — auto-rotation oscillates / migrates without
>   cause.
>
> The list is extended by separate ADR/RP; unnamed findings receive severity from
> the auditor per §7 of the canon.

### F-001
- **Category:** layer boundary | contract | state ownership | security/privacy | policy | process | observability | docs | `<named category above>` | other
- **Severity:** S0 | S1 | S2 | S3 | NOTE
- **Description:** <what was found>
- **Affected components/layers:** <list>
- **Affected asset / adversary model:** <if applicable: which asset is at risk, which adversary capability this opens>
- **Root cause:** <why this happened>
- **Risk:** <what happens if not fixed>
- **Recommendation:** <what to do; reference future RP-NNNN/ADR-NNNN if needed>

### F-002
…

## Drift
- **Where code has diverged from canon:** …
- **Where canon has lagged behind code:** …
- **What needs updating:** <ARCHITECTURE / THREAT-MODEL / ROADMAP / ADR / contracts / README / CHANGELOG / runbook>

## Decisions
- **Accepted:** …
- **Rejected:** …
- **Deferred:** …
- **Requires RFC / Vision:** …

## Action Items
| ID | Action | Owner | Due | Blocking? |
|---|---|---|---|---|
| A-001 | … | … | YYYY-MM-DD | yes/no |

## Follow-up
- **When:** date or condition for a re-audit (e.g. "before Phase N+1 starts" or
  "after the next major blocking event").
- **Gate criterion for re-review:** <what must be green/closed: no unresolved
  S0/S1, CI green, documentation in sync>.
