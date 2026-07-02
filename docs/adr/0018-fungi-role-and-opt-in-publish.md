<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0018: `Fungi role and the opt-in weather publish path`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: the
> **fungi** niche and the **opt-in publish path** by which a node contributes redacted
> network-weather digests — what the niche's contract is, that contribution is opt-in and
> aggregate-and-forget, how it rides the allowed PII-safe telemetry envelope now and dissolves
> into mesh-native digest spores later, and how anti-Sybil source weighting is bounded. Saved as
> `docs/adr/0018-fungi-role-and-opt-in-publish.md`.
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [../vision/0005-network-weather-explorer.md](../vision/0005-network-weather-explorer.md),
> [../vision/0004-living-network-doctrine.md](../vision/0004-living-network-doctrine.md),
> [../GLOSSARY.md](../GLOSSARY.md), `internal/spec/network.go`.

---

## Metadata

- **ID:** ADR-0018
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** observability / measurement, control plane (node role assignment), cross-cutting
- **Phase:** cross-cutting; the schema is inert in Phase 0-2, the opt-in telemetry publish path RUNS from
  **Phase 3** (the advisory-weather publish path — running emission is not Phase-0 behaviour; see
  [ADR-0021](0021-decentralized-observability-not-a-central-collector.md) and ROADMAP Scope-discipline),
  dissolving into mesh-native digest spores in Phase 4-5
- **Related:** VIS-0005 (network-weather explorer — the source; §4 fungi role + §12 spawned items),
  VIS-0004 (living-network doctrine — niches not classes, concept 5), ADR-0002 (no custom crypto —
  the digest signature), ADR-0013 (vocabulary + phase discipline), ADR-0014 (per-operator
  credentials — the signer key id), `internal/spec` (`NodeRole`, `StressSignal`, `SporeEnvelope`,
  `TrustScope`)

## Context

VIS-0005 defines a public **network-weather** surface: an aggregated, privacy-preserving projection
of the redacted distributed-awareness signals (`TransportHealth`, `StressSignal`, `EdgeState`,
`GradientSignal`) that is **impossible to reverse into topology, membership, geography, or identity
by construction**. The Vision states the *why and where*; it spawns (§12) two ADRs and an RP to pin
the contracts. This ADR pins one of them: the **fungi role and the opt-in publish path** — the
node-side half of how weather data comes into being. (Its sibling ADR pins the
`network-weather.json` and `stress-digest` schemas, the floor `k`, the noise budget, and the
cumulative-disclosure bound; the RP pins the off-network publisher.)

The naive way to source a weather surface is to have every node report what it sees to a collector.
That is exactly the artifact the architecture exists to deny: a collector of per-node observations is
simultaneously a routing table and a surveillance dataset, and the **network map is the adversary's
single most valuable prize** (VIS-0003 §6, [../THREAT-MODEL.md](../THREAT-MODEL.md)). The publish path
must therefore be built **inside-out from the privacy invariants** (VIS-0005 §3): a node redacts,
floors, noises, and **forgets** at the source, before anything leaves it, and only ever if its
operator explicitly chose to participate. What is never collected or retained cannot be seized,
compelled, or crawled.

The `internal/spec` schemas already encode the pieces this projects from, all **inert** in Phase 0-2:
`NodeRole` (temporary niches, not permanent classes — including `cache-custodian`), `StressSignal`
(a redacted, scoped, aggregation-floored summary carrying a reason code and a count, never raw
traffic, identities, or location), and `SporeEnvelope` (a signed, TTL-bounded artifact whose
`stress-digest` type carries a redacted aggregated stress summary; its signature is a standard
primitive — an opaque `signer_key_id` plus raw `signature` bytes per ADR-0002). This ADR records the
**role contract and publish path** that bind these schemas into a fungi; it does not implement a
running publisher, registry, or announce path.

## Decision

1. **The fungi niche (the contract behind the name).** A **fungi** is a node occupying a temporary,
   reversible **`cache-custodian`-class niche** (`NodeRole = "cache-custodian"`, VIS-0004 concept 5:
   niches, not permanent classes) whose contract is exactly:
   - **aggregate** the redacted, scoped signals of **its own neighbourhood** (the `StressSignal` /
     `TransportHealth` family within its own `TrustScope`) — never beyond its scope, never a global
     view;
   - **apply the minimum-aggregation floor and noise AT THE SOURCE** — the privacy transform runs on
     the node, before anything is emitted (VIS-0005 §3: obfuscate at the source, not at the sink);
   - **forget the raw inputs** — after emitting, the fungi retains no raw observations, no node list,
     no full topology, no per-edge weights; only the redacted, TTL-bounded, scoped aggregate it
     emitted (aggregate-and-forget);
   - **emit a signed, TTL-bounded `stress-digest` `SporeEnvelope`** (`SporeType = "stress-digest"`),
     signed with the node's own per-operator key material (ADR-0014: `signer_key_id` + signature
     bytes, ADR-0002) — never a new scheme.

2. **The niche is ephemeral and rotating — no permanent aggregation centre.** Which node is a fungi
   changes over time; the role is shed as readily as it is taken (VIS-0004 concept 5). **Each fungi
   sees only its own scope, and fungi digests do not tile into wider coverage** — there is no fungi,
   and no set of fungi, that holds a region-spanning or global view. The rotating, scope-bounded
   niche is the structural reason the publisher cannot reconstruct a map from the digests it ingests:
   none of its sources ever held one.

3. **The opt-in publish path (opt-in only, aggregate-and-forget).** A node publishes weather data
   **if and only if its operator explicitly chooses the fungi role.** There is no default, no
   silent, and no inferred participation; a non-fungi node emits no weather digest at all. From
   **Phase 3** (the opt-in advisory-weather publish path; the schema is inert in Phase 0-2 and no
   digest is emitted then — see [ADR-0021](0021-decentralized-observability-not-a-central-collector.md))
   the fungi path rides the **allowed PII-safe aggregated telemetry envelope**:
   opt-in, PII-safe, aggregated, **no correlation, no identity binding**
   ([../ROADMAP.md](../ROADMAP.md) Phase 3 / advisory-weather publish path). A fungi runs a small **read-only**
   aggregator over its own already-PII-safe signals and emits the `stress-digest`; it never opens a
   queryable endpoint and never accretes raw inputs.

4. **Dissolution into mesh-native digest spores (Phase 4-5).** The opt-in upload path is the
   **early transport** for an unchanged public contract. In Phase 4-5 a fungi emits the same
   `stress-digest` `SporeEnvelope` as a real spore onto the awareness layer, and the publisher reads
   spores instead of receiving direct opt-in uploads. **The public contract — the digest shape, the
   floor, the forget-the-raw rule, the opt-in requirement — is unchanged; only the transport beneath
   it changes.** This is the deliberate, planned dissolution VIS-0005 §scope records; it does **not**
   pull mesh behaviour forward into Phase 0-2 (see §Phase discipline).

5. **Anti-Sybil source weighting — design here, not running.** An open fungi role invites fake
   digests that could skew the weather. A single bad source is bounded by composing mechanisms that
   already exist in the schemas and posture, each load-bearing:
   - **`import-inert-until-validated`** — every ingested digest is inert until its signature and
     structural invariants validate (the `SporeEnvelope.Validate()` posture; signature verification
     is the verifier's Phase 4-5 job against a named standard primitive, never a new scheme);
   - **signed digests** — each digest carries a per-operator `signer_key_id` + signature (ADR-0014),
     so sources are attributable to a key and a flood from one key is detectable;
   - **the aggregation floor `k`** — a cell below the floor is **omitted, never shown as zero**, so a
     thin fake source cannot manufacture a visible cell;
   - **cross-source coarsening** — the publisher coarsens once more across many sources, so no single
     source determines a published cell;
   - **per-source caps** — a single `signer_key_id`'s contribution to any cell is bounded, so one
     source cannot dominate.

   This ADR **defines** the source-weighting design (the mechanisms and their composition) and the
   invariant they enforce — *a single bad source has bounded influence on the published surface*. It
   does **not** specify a running weighting algorithm or reputation system; the load-bearing
   weighting parameters land with the publisher (the spawned RP) and the floor/noise ADR, and remain
   inert until that phase.

6. **Phase discipline.** In **Phases 0-2 the fungi path runs only as opt-in, PII-safe, aggregated,
   identity-free telemetry** (ADR-0013, AGENTS.md §2, VIS-0005 §Non-goals). **No DHT, no gossip, no
   registry, no announce-into-mesh, no global topology, no per-node disclosure** runs in Phase 0-2;
   the `DiscoveryBackend` interface stays a declared-only no-op stub. The mesh-native spore transport
   (decision 4) is **Phase 4-5**. This ADR records the role contract and the opt-in path as a
   measurement surface layered on working access, never a discovery layer.

## Consequences

- A node becomes a fungi **only** by explicit operator choice; the bootstrap and config surface must
  treat the `cache-custodian` weather-publishing niche as opt-in, off by default, and individually
  revertible (the niche is reversible — VIS-0004 concept 5).
- A fungi, audited after emitting a digest, **retains no raw observations** and holds no node list,
  no full topology, and no per-edge weights — only redacted, TTL-bounded, scoped aggregates (a
  VIS-0005 §7 Definition-of-Done item). A conformance check should assert the aggregate-and-forget
  property and that no fungi path retains or emits raw per-node data.
- Digests are **signed `SporeEnvelope`s using standard primitives only** (`signer_key_id` +
  signature bytes, ADR-0002/ADR-0014); no new signature or aggregation cryptography is introduced.
  `import-inert-until-validated` applies to every ingested digest.
- The **public contract is transport-agnostic**: the Phase-3 opt-in upload and the Phase-4-5
  mesh-native spore carry the **same** `stress-digest` shape, so the explorer and its auditors do not
  change when the transport beneath dissolves into the mesh.
- Anti-Sybil source weighting is **bounded but not yet running**: this ADR fixes the mechanisms and
  the bounded-influence invariant; the publisher RP and the floor/noise ADR supply the live
  parameters. Until then nothing weights or ingests at runtime (Phase 0-2 inert).
- The node never opens a **queryable** weather endpoint; an endpoint a visitor or peer can query is
  an enumeration surface (VIS-0005 §out-of-scope). The fungi only **emits** redacted digests.

## Alternatives considered

- **Every node reports raw observations to a central collector** — rejected: a per-node observation
  collector is a routing table and a surveillance dataset, the exact map the architecture denies
  (VIS-0003 §6). The fungi forgets the raw at the source and emits only floored aggregates.
- **A permanent aggregator class (dedicated weather nodes)** — rejected: a permanent aggregation
  centre is a coercion target and a standing partial map. The niche is **ephemeral and rotating**
  (VIS-0004 concept 5); each fungi sees only its own scope and digests do not tile into coverage.
- **Default-on / opt-out participation** — rejected: contribution must be opt-in only so a node
  never publishes weather data without its operator explicitly choosing it (VIS-0005 §7); data never
  retained or emitted cannot be seized or compelled.
- **A running anti-Sybil reputation/weighting system now** — deferred: full source weighting is
  load-bearing and belongs with the publisher and the floor/noise ADR (Phase 4-5). This ADR bounds a
  single bad source with signed digests + `import-inert-until-validated` + the floor + cross-source
  coarsening + per-source caps, and defers the running algorithm.
- **Pulling the mesh-native spore transport into Phase 0-2** — rejected: it would run a DHT / gossip /
  announce path the phase discipline forbids (ADR-0013). The opt-in telemetry upload is the allowed
  non-mesh transport; the spore path is Phase 4-5, with the public contract unchanged.
