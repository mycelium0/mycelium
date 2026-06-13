<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — In-region edge reporting: the opt-in edge reachability signal

> **Document type.** Refactoring / Change Proposal. Structure matches
> [../refactoring.md](../refactoring.md) and [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md).
> This RP **defines a concept and its contracts and plans the future work**; the only thing it lands now
> is the **inert `EdgeReport` schema** (`internal/spec/edgereport.go`, already merged). The *running*
> edge reporter is **Phase 2** and is explicitly **not built before Phases 0 and 1 are complete in
> production** (the maintainer's directive; ROADMAP phase-transition principle).
>
> **Why this exists.** It is the priority deliverable of the decentralized-observability doctrine
> ([../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md) §4):
> the one signal that matters most — *can a user reach a node from the network where their access is
> blocked?* — cannot be measured from the operator's own clean network; it can only come from the
> **edge**, the clients inside the affected network, gathered redacted and aggregated.

---

## Metadata
- **ID:** RP-0006
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** **not before Phase 2** (Phases 0 and 1 must be done in production first). Phases 0-1 may only
  carry the **inert** `EdgeReport` schema/interface (now merged); no edge report is emitted, collected, or
  consumed until Phase 2. See [../ROADMAP.md](../ROADMAP.md) (Measurement track + Scope discipline).
- **Related:**
  [../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md) (the doctrine — §4 makes this the priority);
  [../adr/0021-decentralized-observability-not-a-central-collector.md](../adr/0021-decentralized-observability-not-a-central-collector.md) (decentralized, no collector);
  [../adr/0018-fungi-role-and-opt-in-publish.md](../adr/0018-fungi-role-and-opt-in-publish.md) (the opt-in path the report rides, Phase 2);
  [../adr/0017-network-weather-data-contract.md](../adr/0017-network-weather-data-contract.md) (floor `k`, noise, coarsening — the report obeys these);
  [../adr/0019-node-local-reachability-health.md](../adr/0019-node-local-reachability-health.md) (the node-local L0 monitor — a *second* vantage, not a substitute for the edge);
  [0004-network-weather-explorer-publisher.md](0004-network-weather-explorer-publisher.md) (the publisher + fail-closed gate this feeds — unbuilt, a hard prerequisite);
  [0005-inoculum-bundle-and-toolkit.md](0005-inoculum-bundle-and-toolkit.md) (the operator bundle that carries the opt-in reporter + its consent);
  `internal/spec/edgereport.go` (the inert schema this RP lands);
  [../THREAT-MODEL.md](../THREAT-MODEL.md).

## 1. Title
Define **in-region edge reporting**: an opt-in, identity-free, region-bucketed, transport-class
reachability signal emitted by clients at the edge, floored and coarsened at the source, carried over the
fungi opt-in path into the aggregate network-weather surface — so the fabric can finally see *what it
cannot see from the operator's own network*: where access is actually being blocked, from inside.

## 2. Reason
[VIS-0006](../vision/0006-decentralized-observability.md) settled *why*: the **vantage problem** (§1). A
node can be healthy on every operator dashboard and unreachable from the user's network; reachability is a
property of the *path*, and the interference is on the path the operator's monitor does not sit on. The
only observers on that path are the **clients in the affected region**. Their reports, gathered opt-in and
redacted, are the missing signal — and gathering them from the edge, aggregate-and-forget, is inherently
decentralized ([ADR-0021](../adr/0021-decentralized-observability-not-a-central-collector.md)). This is the
priority of the whole observability effort; the node-local monitor ([ADR-0019](../adr/0019-node-local-reachability-health.md))
is a useful *second* vantage but never a substitute for the edge one.

What is missing is the **work and migration plan**: the report contract, the consent and emission path,
the privacy prerequisites, and the strict phase gating that keeps any running behaviour out of Phases 0-1.

## 3. Scope

### 3.1 Participation
| Component / layer | Change | Phase |
|---|---|---|
| `internal/spec` (`EdgeReport`, `TransportClass`) | **inert schema + Validate + tests — LANDED now** | Phase 0-2 (inert) |
| Standard clients / the Inoculum ([RP-0005](0005-inoculum-bundle-and-toolkit.md)) | opt-in edge reporter + consent path | Phase 2 (future) |
| Fungi opt-in path ([ADR-0018](../adr/0018-fungi-role-and-opt-in-publish.md)) | ingest + aggregate edge reports under a scope | Phase 2 (future) |
| Stress-digest schema-hardening ADR | `NoisePolicy` field, closed `RegionBucket`/`TransportClass` vocab, cumulative-disclosure model | prerequisite (future) |
| Publisher + fail-closed gate ([RP-0004](0004-network-weather-explorer-publisher.md)) | cross-source floor/strip; **unbuilt — hard prerequisite** | Phase 2 (future) |

### 3.2 Blast-radius cap
This RP is a **single-step specification + design** plus one inert schema file. It introduces **no running
behaviour**, no data-plane change, and no client code. The running reporter, the aggregation, and the
publisher are explicitly out of this RP's cap and are deferred to dedicated Phase-2 work that may not begin
until Phases 0-1 are complete.

## 4. Current state
- `internal/spec/edgereport.go` defines the inert `EdgeReport` (coarse `RegionBucket`, coarse
  `TransportClass`, aggregate reachable/unreachable counts, a minimum-aggregation floor `MinAggregate`,
  medium speed class, `DecayPolicy`) with `Validate()` enforcing structure + the floor. **Nothing produces
  or consumes it.** No PII is representable by construction: no identity, no precise location, no IP/ASN,
  no endpoint/SNI.
- The node-local L0 monitor ([ADR-0019](../adr/0019-node-local-reachability-health.md)) is deployed and
  gives the *node's own* vantage — not the edge one.

## 5. Target state (Phase 2)
An edge client, **only if its user opts in**, observes which transport *classes* succeeded/failed from its
vantage, reduces them to a floored, coarse `EdgeReport` (omit below `k`, classes not endpoints, a coarse
region bucket, never identity/precise-location), and submits it over the opt-in fungi path. Fungi aggregate
reports within a `TrustScope`, re-apply the floor (+ noise once that field exists), forget the raw, and the
publisher coarsens once more and emits the aggregate network-weather surface. The fabric then shows, for
example, "the REALITY-TCP family is degraded in region bucket X; the QUIC family is alive" — without ever
holding a map, a node list, or a user trail.

## 6. Risks
- **De-anonymisation via granularity.** Too-fine a `RegionBucket` (or a stable opaque bucket id) becomes a
  fingerprint correlatable with external blocking events. Mitigation: coarse buckets, scheduled rotation or
  a privacy budget (the cumulative-disclosure model — unsolved, a prerequisite).
- **Sybil-poisoned reports.** A flood of fake edge reports can move above-floor cells. The floor `k` bounds
  it but does not solve it; per-source caps + the signature verifier are unbuilt (bounded, not solved).
- **Consent / coercion.** Edge reporting must be genuinely opt-in, revocable, and clearly explained in the
  Inoculum; a reporter must never become a covert beacon.
- **Phase jump.** Implementing a running reporter before Phases 0-1 are done would violate scope discipline
  and ship unvalidated measurement; this RP forbids it.

## 7. Acceptance criteria + Non-goals
**Acceptance (for the *inert* step landed now):** the `EdgeReport`/`TransportClass` schema compiles,
`Validate()` enforces the floor + structure, tests pass under `go test -race`, the offline gates stay
green, and the type represents no PII.
**Non-goals (deferred — not in this RP):** any running edge reporter; any aggregation or publishing; the
consent UX; the `NoisePolicy`/closed-vocabulary/cumulative-disclosure spec changes; anti-Sybil edge
weighting. Each is named here as future Phase-2 work, gated behind Phase 0-1 completion.

## 8. Prerequisites (before any Phase-2 emission)
1. **Phases 0 and 1 complete in production** (ROADMAP phase-transition principle).
2. The stress-digest schema-hardening ADR: a typed `NoisePolicy`/privacy budget; `RegionBucket` and
   `TransportClass` pinned to closed, audited vocabularies with `Validate()` rejecting non-members; a
   committed cumulative-disclosure model.
3. The publisher + fail-closed conformance gate ([RP-0004](0004-network-weather-explorer-publisher.md)) —
   the only cross-source enforcer of omit-not-zero and the no-leak strip — must exist and pass.

## 9. Migration strategy
Phase 0-1: ship and keep the inert schema only; no emission. Phase 2: implement the opt-in reporter behind
explicit consent, wire the fungi ingestion, land the prerequisites in §8, then enable emission gated by the
fail-closed publisher gate. The schema is designed so the Phase-2 implementation does not have to break it.

## 10. Rollback / fallback
The inert schema is pure data + validation; removing or revising it is a localized spec change with no
runtime effect. No live system depends on it until Phase 2.

---

No node IPs, hostnames, country names, location codes, secrets, or contact details appear in this proposal
or in the schema it lands; `RegionBucket`/`TransportClass` are coarse, opaque, and PII-free by construction.
