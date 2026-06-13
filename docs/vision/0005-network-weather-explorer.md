<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Network-Weather Explorer

> **Document type.** Vision & Scope. This defines a public, privacy-preserving **explorer** for the
> fabric — an aggregated "network weather" surface, not a per-node map. It is "why and where", not a
> specification; field names, parameters, the aggregation floor `k`, and the publish protocol are
> pinned by the ADRs and the RP this Vision spawns, not here.
>
> **The one reframe that governs everything.** This is **not** a blockchain explorer. A blockchain
> replicates global state into every node by design; Mycelium does the opposite — no node and no
> coordinator ever holds the global topology, because the **network map is the adversary's single most
> valuable prize** (VIS-0003 §6, [../THREAT-MODEL.md](../THREAT-MODEL.md) §Protected assets). A literal
> node → endpoint → peers → location explorer would hand over exactly the asset the architecture exists
> to deny. The correct reference is an aggregated measurement surface (Tor-Metrics / OONI-style): it
> shows the fabric's **health and resilience**, and is **impossible to reverse into topology by
> construction.**

## Metadata
- **ID:** VIS-0005
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** cross-cutting **Measurement** track — a central publisher now (Phase 0 onward), dissolving into mesh-native digest spores in Phase 3–4 (see [../ROADMAP.md](../ROADMAP.md) cross-cutting tracks)
- **Layer(s):** observability / measurement, control plane (cross-cutting)
- **Related:** [0003-node-interaction-and-distributed-awareness.md](0003-node-interaction-and-distributed-awareness.md),
  [0004-living-network-doctrine.md](0004-living-network-doctrine.md),
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md),
  [../THREAT-MODEL.md](../THREAT-MODEL.md), [../ARCHITECTURE.md](../ARCHITECTURE.md),
  [../ROADMAP.md](../ROADMAP.md), [../../observability/README.md](../../observability/README.md),
  `internal/spec` (the inert schemas this projects from)

## 1. Problem and context

The fabric already measures itself: Phase-0 observability gives per-transport handshake success,
reachability, and interference triage (host fault vs network interference), and VIS-0003 / VIS-0004
define the redacted, scoped, decay-bounded signals (`TransportHealth`, `StressSignal`, `EdgeState`,
`GradientSignal`) the adaptation layer will run on. None of this is **visible** to the people the
project is for, or to operators deciding whether the fabric is healthy. There is no public, honest,
at-a-glance answer to "is private connectivity holding right now, and where is interference biting?".

The naive way to provide that answer is a node directory — and it is the most dangerous artifact the
project could ship. A directory of "who is reachable where" is simultaneously a routing table and a
surveillance dataset; published, it is a ready-made enumeration and operator-coercion target. The
explorer must therefore be built **inside-out from the privacy invariants**: it publishes only what is
already aggregated, noised, scoped, and above a minimum-aggregation floor — never anything that names a
node, an endpoint, a location, or a user. What is never collected or published cannot be seized,
compelled, or crawled.

## 2. Vision (desired outcome)

A public **network-weather** site shows the fabric's resilience at a glance — an overall resilience
index, per-transport-**class** health, coarse interference signals, the edge-lifecycle "metabolism",
and the immortality-through-rotation story (a transport class was burned, the fabric recovered) — and
**carries no map**. An auditor can read the published snapshot and the source and confirm it cannot be
reversed into topology, membership, geography, or identity.

Participation is **opt-in and open**: any operator who wants to contribute runs their node in the
**fungi** role (§4). A fungi aggregates its own neighbourhood's redacted signals, applies the
aggregation floor and noise **at the source before publishing**, forgets the raw observations, and
emits a signed, TTL-bounded digest. The explorer's publisher collects digests from many fungi,
coarsens once more across sources, suppresses anything below the floor, and emits a static public
snapshot. The site renders that snapshot and nothing else.

The target property for the user is unchanged from VIS-0001 and inherited here: the explorer makes the
fabric's health legible **without ever becoming the correlation tool VIS-0003 §8 warns the detector
must not be** — including not surveilling its own visitors.

## 3. Principles governing this initiative

- [x] **The map is never assembled.** No tier — fungi, publisher, or site — holds or publishes global
  topology, a node list, per-node rows, per-edge weights, geography, or identity. The public snapshot
  is a projection of aggregates that **cannot tile back into a map** (VIS-0003 §10 fragment-stitching).
- [x] **Obfuscate at the source, not at the sink.** The privacy transform (aggregation floor `k`,
  noise, coarsening) is applied by the fungi **before** anything leaves the node — the
  reduce-precision-before-publish model (cf. telemetry gateways that downsample before an MQTT uplink).
  The publisher and site only ever see already-redacted data.
- [x] **Opt-in only, aggregate-and-forget.** A node contributes only if its operator chooses the fungi
  role; a fungi retains no raw observations after emitting a digest. Data never retained cannot be
  seized or compelled.
- [x] **Do not reinvent cryptography.** Each digest is a signed, TTL-bounded `SporeEnvelope` using
  standard primitives only — a key-id string plus signature bytes per
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md);
  `import-inert-until-validated` applies to every digest the publisher ingests.
- [x] **The site is not surveillance.** A site about private connectivity must not itself track its
  readers: no analytics, no third-party scripts, no visitor logs tied to identity; static, self-hostable,
  AGPL like the rest of the project.

## 4. Scope

### The fungi role (the contract behind the name)

A **fungi** is a node in a temporary, reversible niche (a `cache-custodian`-class niche, VIS-0004
concept 8 / `NodeRole`) whose contract is: *aggregate the redacted, scoped signals of its own
neighbourhood, apply the minimum-aggregation floor and noise, forget the raw inputs, and emit a signed
TTL-bounded `stress-digest` `SporeEnvelope`.* The niche is **ephemeral and rotating** — which node is a
fungi changes over time (VIS-0004 concept 5: niches, not classes) — so no fungi becomes a permanent
aggregation centre. Each fungi sees only its own scope; fungi digests do not tile into wider coverage.

### In scope

- **The public network-weather snapshot** (`network-weather.json`, §contract below): an overall
  resilience index; per-transport-**class** state and reachability (never per node); coarse interference
  signal classes carrying an **opaque scope id, never geography**; the edge-lifecycle distribution as
  **percentages** (not counts — counts leak fleet size); fleet sizes as order-of-magnitude buckets;
  obfuscated rotation events; and a methodology block declaring `k`, the noise, and what is withheld.
- **The fungi opt-in publish path.** Now (Phase 0 onward): a fungi runs a small read-only aggregator
  over its own PII-safe signals and publishes a digest to the explorer's publisher. This rides the
  allowed Phase-0–2 telemetry envelope: **opt-in, PII-safe, aggregated, no correlation, no identity
  binding** ([../ROADMAP.md](../ROADMAP.md) Phase 2 / Measurement track).
- **The publisher** (off-network control side): verifies digest signatures, coarsens across sources,
  suppresses below-floor cells, strips anything resembling a leak, and emits the static snapshot. The
  privacy-bearing step lives here and in the fungi, never in the browser.
- **The static explorer site**: renders the snapshot only; no live queries against nodes; no visitor
  tracking. **Self-hostable by any operator from the static snapshot**; the project itself runs no
  public reference deployment and publishes no public endpoint for it.
- **A fail-closed conformance check**: a generated snapshot that cannot be proven safe (per the §7
  invariants) is not published. The check lives in the conformance suite (registered in
  [../development.md](../development.md)); this Vision records the invariant, not the gate script.

### Out of scope / explicitly not doing now

- **A node directory, a membership list, per-node rows, a topology view, or any geographic map.** Not
  for any tier, not as an "advanced mode". This is the line the whole Vision exists to hold.
- **Anything per-user.** No client counts attributable to identity, no user geography, no destinations.
- **Live querying of nodes from the browser.** The site reads a pre-redacted static snapshot only; an
  endpoint a visitor can query is an enumeration surface.
- **Pulling mesh behaviour forward.** The explorer does not run a DHT, gossip, registry, or
  announce-into-mesh (Phase 3–4); it consumes only already-redacted aggregates.

### Deferred → future phase/Vision

- **Mesh-native fungi digests.** In Phase 3–4 a fungi emits its `stress-digest` as a real spore onto
  the awareness layer and the publisher reads spores instead of receiving direct opt-in uploads — the
  **public contract is unchanged**, only the transport beneath it. Island-scoped weather and
  carrier-bridged digest carriage follow the VIS-0002/0003 phase order (Phase 6).
- The exact `k`, noise mechanism and budget, coarsening rules, rotation-event obfuscation, and the
  digest spore schema → the spawned ADR/RP (§12).

### Non-goals — phase discipline (what must NOT appear in Phases 0–2)

Per the scope-discipline fence (MYC-F006, [../ROADMAP.md](../ROADMAP.md)) and VIS-0003 §4: in Phases
0–2 the fungi/publisher path runs only as **opt-in, PII-safe, aggregated, identity-free telemetry**.
No DHT, no gossip, no registry, no announce-into-mesh, no global topology, and no per-node disclosure
runs. The explorer is a measurement surface layered on top of working access, never a discovery layer.

## 5. Target audience and scenarios

- **Who:** a person relying on the fabric who wants to know it is healthy · a node operator deciding
  whether to rotate or contribute · a researcher or journalist verifying the project's honesty claims ·
  an auditor checking that the published surface leaks nothing.
- **Key scenarios:**
  - *At-a-glance health.* A visitor opens the site and reads the resilience index, which transport
    classes are alive, and whether interference is elevated — with no place names and no node identities.
  - *Opt-in contribution.* An operator flips their node into the fungi role; it begins publishing
    redacted digests; the fleet-wide snapshot reflects more samples without exposing the new node.
  - *Rotation story.* A transport class is burned; the snapshot shows it degrade and the fabric
    recover within a bounded window — the immortality-through-rotation property, made visible and
    anonymised.
  - *Audit.* A reviewer diffs `network-weather.json` and the source and confirms: no IP/host/ASN/port/
    SNI/geo, no per-node rows, every shown cell at/above `k`, fleet sizes bucketed — and the gate agrees.

## 6. Assets and trade-offs

- **Protected assets in focus:** the **network map** (never assembled at any tier) · ingress
  reachability (only class-level health is shown, never an endpoint) · operators (a fungi holds only
  redacted aggregates and forgets the raw — little to coerce out of) · user identity/location (never in
  any cell) · the publisher (a value target — see trade-offs).
- **Conscious trade-offs:**
  - *Visibility ↔ enumeration surface.* Every additional published detail helps legibility and helps an
    adversary; the bias is deliberately toward less — classes not nodes, percentages not counts, buckets
    not exact sizes, opaque scopes not geography.
  - *Openness ↔ poisoning.* An open fungi role invites fake digests; `import-inert-until-validated`,
    signed digests, the aggregation floor, and cross-source coarsening bound a single bad source's
    influence (full anti-Sybil weighting is the spawned ADR's job).
  - *Central publisher (simple) ↔ mesh-native (resilient).* A single publisher now is simple and a
    value target; it holds only already-redacted aggregates and dissolves into mesh-native spore
    ingestion in Phase 3–4. It must never accrete raw inputs or become a map.
- **Technical debt accepted knowingly:** the central publisher is a deliberate temporary centre,
  accepted on the explicit plan to read mesh-native digest spores later; it must never hold raw
  per-node data or reconstruct topology in the meantime.

## 7. Definition of Done (measurable, not a slogan)

- [ ] The site renders the resilience index, per-class transport health, coarse interference signals,
  the lifecycle distribution, and rotation events from a single static `network-weather.json`.
- [ ] **An auditor cannot reverse the published snapshot** into topology, a membership/node list,
  geography, an endpoint, or any per-user fact — confirmed by inspection and by the gate.
- [ ] **Every shown cell meets the aggregation floor** `k`; below-floor cells are omitted, never shown
  as zero; fleet sizes are order-of-magnitude buckets; lifecycle is percentages, not counts.
- [ ] A fungi, audited after emitting a digest, retains **no raw observations** and holds no node list,
  no full topology, and no per-edge weights — only redacted, TTL-bounded, scoped aggregates.
- [ ] Contribution is **opt-in only**: a node never publishes weather data without its operator
  explicitly choosing the fungi role.
- [ ] A **fail-closed conformance check** fails the build if a generated snapshot contains an IP/host/
  ASN/port/SNI/country/location-code/secret/per-node identifier, or a shown cell below `k`, or an
  un-bucketed fleet count. Fail-closed: an unprovable-safe snapshot is not published.
- [ ] The site loads with **no analytics, no third-party scripts, and no identity-linked visitor logs**;
  it is self-hostable from the static snapshot.

## 8. Measurability and observability

The explorer is itself a measurement product, so it is held to the same PII-safe stack and floors as
the signals it shows (VIS-0003 §8, VIS-0004 §8, [../../observability/README.md](../../observability/README.md)):
aggregation-floor-honoured checks (no cell below `k`), withheld-field checks (the gate), snapshot
freshness/TTL adherence, and a periodic adversarial review confirming the published surface still
cannot be reversed into a map. The site adds no client-side telemetry of its own.

## 9. Dependencies and prerequisites

- **Preceding Vision/ADR:** VIS-0003 (distributed awareness, the source of the redacted signal model
  and the no-global-map invariant) and VIS-0004 (the living-network doctrine and the `internal/spec`
  types this projects from); [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md)
  binds the digest signature.
- **Contracts this Vision touches:** `internal/spec` (`TransportHealth`, `StressSignal`, `EdgeState`,
  `GradientSignal`, `SporeEnvelope`, `TrustScope`, `NodeRole`) — the explorer publishes a redacted
  **projection** of these, adding no new identity-bearing field; the Phase-0 observability stack (the
  PII-safe source signals); the block-intelligence/telemetry envelope (opt-in, aggregated, no identity).
- **External/repo:** the explorer **code lives in a separate repository** (AGPL), deployed as a static
  site that **any operator may self-host** from the redacted snapshot; the project itself operates no
  public deployment and publishes no public endpoint for it. This Vision and its spawned ADR/RP are
  the canonical reference that repository implements against.

## 10. Risks and open questions

- **The site becomes the very map it forbids.** Mitigated by building from the invariants (§3), the
  by-class/percentage/bucket/opaque-scope rules, and the fail-closed gate; the standing risk is
  *cumulative* disclosure across snapshots over time — the gate and review must check that successive
  snapshots do not sum to more than any single one (cf. VIS-0003 §10 cumulative enumeration).
- **Fungi-digest poisoning / Sybil sources.** A flood of fake opt-in digests skews the weather.
  Bounded by signed digests, `import-inert-until-validated`, the aggregation floor, cross-source
  coarsening, and per-source caps; the load-bearing anti-Sybil weighting is the spawned ADR's job, not
  settled here.
- **Publisher as a value target.** It is a temporary centre; it holds only already-redacted aggregates,
  must never accrete raw inputs, and dissolves into mesh-native digest ingestion in Phase 3–4.
- **Open questions → ADR/RP:** the aggregation floor `k` and region-coarsening rule (shared with
  VIS-0003); the noise mechanism and privacy budget; the `stress-digest` spore schema and the opt-in
  upload protocol now vs the mesh-native spore path later; the rotation-event obfuscation; the
  cumulative-disclosure bound across snapshots; the anti-Sybil source weighting.

## 11. What becomes possible next

With an honest, privacy-preserving weather surface, the project gains a public legibility layer it
currently lacks — people can see the fabric is healthy, operators can decide to rotate or contribute,
and the honesty claims become checkable — all without creating the map the architecture spends so much
effort denying. The same digest path is the visible end of the Phase-3 block-intelligence aggregation
and the Phase-4 mesh-native stress-digest spores; the explorer is the surface those grow into, not a
parallel system.

## 12. Next steps

- [ ] **ADR — network-weather data contract & aggregation floor** (`docs/adr/NNNN-...`): the
  `network-weather.json` schema, the fungi `stress-digest` spore schema, the floor `k`, noise budget,
  coarsening/bucketing rules, rotation-event obfuscation, and the cumulative-disclosure bound.
- [ ] **ADR — fungi role & opt-in publish path** (`docs/adr/NNNN-...`): the `cache-custodian`-class
  fungi niche and rotation, the opt-in upload protocol (Phase 0 onward) and its dissolution into
  mesh-native digest spores (Phase 3–4), and the anti-Sybil source weighting.
- [ ] **RP — explorer publisher** (`docs/proposals/NNNN-...`): the off-network publisher (verify →
  coarsen → suppress-below-floor → strip → emit static snapshot), with a fail-closed conformance check
  enforcing the §7 invariants (the check is part of the conformance suite, not specified in the RP).
- [ ] **Separate explorer repository** (AGPL): the static site + publisher, implementing this Vision;
  self-hostable by any operator from the redacted snapshot — the project operates no public
  deployment.
- [ ] **Trigger an event-driven audit** when the publisher and the first live snapshot land, per
  [../refactoring.md](../refactoring.md), focused on reversibility and cumulative disclosure.
