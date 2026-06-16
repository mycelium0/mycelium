<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0017: `Network-weather data contract and aggregation floor`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: the
> data contract for the public **network-weather** surface — the `network-weather.json` snapshot
> schema, the fungi `stress-digest` `SporeEnvelope` schema, the aggregation floor `k`, the noise
> mechanism and privacy budget, the coarsening/bucketing and rotation-obfuscation rules, and the
> cumulative-disclosure bound — pinned as **definitions only** (the running publisher is deferred).
> Saved as `docs/adr/0017-network-weather-data-contract.md`.
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [../vision/0005-network-weather-explorer.md](../vision/0005-network-weather-explorer.md),
> [../vision/0003-node-interaction-and-distributed-awareness.md](../vision/0003-node-interaction-and-distributed-awareness.md),
> [../GLOSSARY.md](../GLOSSARY.md) (Network weather), `internal/spec` (the inert schemas this projects from).

---

## Metadata

- **ID:** ADR-0017
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** observability / measurement, control plane (cross-cutting)
- **Phase:** cross-cutting; schemas inert from Phase 0; running publisher deferred to a later phase (RP-0004)
- **Related:** VIS-0005 (network-weather explorer — the source of this contract), VIS-0003 (the redacted
  signal model and the cumulative-enumeration bound, §10), ADR-0002 (no custom crypto — the digest
  signature), ADR-0013 (mycelial vocabulary + Phase 0-2 inert-schema discipline), `internal/spec`
  (`StressSignal`, `TransportHealth`, `EdgeState`/`EdgeLifecycle`, `SporeEnvelope`, `TrustScope`, `NodeRole`)

## Context

VIS-0005 §12 spawns this ADR. It establishes a public **network-weather** surface — an aggregated,
privacy-preserving "is private connectivity holding right now, and where is interference biting?"
read on the fabric — built **inside-out from the privacy invariants**: a measurement surface
(Tor-Metrics / OONI-style), explicitly **not** a node directory, topology view, or geographic map.
VIS-0005 fixes *why and where*; it deliberately defers *the exact field names, the floor `k`, the
noise, and the publish protocol* to this ADR (and the fungi/publisher work it also spawns).

What must be pinned here is the **data contract**: the on-the-wire shapes and the numeric/redaction
rules that make the surface provably impossible to reverse into a map. Two shapes carry the contract:

- the **fungi `stress-digest`** — what an opt-in contributing node emits: a signed, TTL-bounded
  redacted aggregate of its own neighbourhood, floored and noised **at the source** before anything
  leaves the node; and
- the public **`network-weather.json` snapshot** — what the off-network publisher emits after
  verifying digests, coarsening across sources, and suppressing below-floor cells; the static site
  renders this and nothing else.

These project from the **inert** `internal/spec` types (VIS-0005 §9): `StressSignal` already carries a
`reason_code`, a `sample_count`, a `min_aggregate` floor, a `TrustScope`, and a medium `SpeedClass`;
`SporeEnvelope` already carries the `stress-digest` `SporeType`, a TTL, and an ADR-0002 key-id +
signature reference. This ADR adds **no new identity-bearing field**; it specifies how those existing
shapes are floored, noised, bucketed, and obfuscated into a public projection — as **definitions**,
not as running code. The constraints below restate the VIS-0005 §3 invariants and the VIS-0003 §10
cumulative-enumeration bound in contract-binding terms.

## Decision

This ADR binds the network-weather data contract. It defines schemas and numeric rules **only**;
nothing here runs in Phase 0-2 (see Phase discipline below).

### 1. The fungi `stress-digest` is a signed, TTL-bounded `SporeEnvelope`

A fungi (VIS-0005 §4 — a node in the rotating `cache-custodian`-class `NodeRole` niche) emits its
contribution as a `SporeEnvelope` with `type = stress-digest` (`SporeTypeStressDigest`), and **no new
envelope schema is introduced**:

- The envelope uses **standard primitives only**: an opaque `signer_key_id` plus raw `signature` bytes
  over the envelope (ADR-0002). This ADR names **no** cipher, KDF, or signature scheme — the algorithm
  lives in the verifier against a named standard primitive, never here. No custom digest scheme.
- It is **TTL-bounded** (`issued_at` / `expires_at`, replay-bounded) and **scoped** to a `TrustScope`
  whose `id` is **opaque — never geography, never a node, never an endpoint**.
- Its `payload` carries the **redacted, floored, noised aggregate** of the fungi's own neighbourhood —
  a set of redacted cells projected from `StressSignal` / `TransportHealth` — and **never** raw
  observations, raw counts, peer identities, endpoints, or per-node rows. The fungi applies the floor
  and the noise (rules 3–4) **before** building the payload, then **forgets the raw inputs**
  (aggregate-and-forget, VIS-0005 §3).
- Every ingested digest is **inert until validated** (`import-inert-until-validated`): the publisher
  treats an unverified or below-floor digest as data, never as trusted aggregate, and a single source's
  influence is bounded by the floor, cross-source coarsening, and per-source caps (the load-bearing
  anti-Sybil source weighting is the sibling fungi ADR's job, not settled here).

### 2. The public `network-weather.json` snapshot schema

A single static snapshot is the **only** public artifact. Its schema is the following fields, and **a
field not listed here MUST NOT appear** (the snapshot is allow-listed, not deny-listed):

- **`overall_resilience_index`** — a single bounded scalar (normalised, e.g. `[0,1]`) summarising
  fabric health. A derived index, not a count.
- **`transport_classes[]`** — per-transport-**CLASS** health and reachability: each entry carries a
  transport **class** label (never a per-node `transport_ref`, SNI, port, or endpoint) and bounded,
  noised health / reachability ratios. **Never per node, never per endpoint.**
- **`interference_signals[]`** — coarse interference signal **classes**, each carrying an **opaque
  scope id** (projected from `TrustScope.id`) and a coarse severity class. The scope id is **opaque
  and carries no geography** — no country name, location code, ASN, region, or any value reversible to
  a place. Interference is shown as a class with an opaque scope, never as "where".
- **`edge_lifecycle_distribution`** — the edge-lifecycle "metabolism" (the `EdgeLifecycle` states:
  `candidate … active … cord … dormant … scarred … pruned`) expressed as a **distribution of
  percentages that sum to 100**, **never as counts** — counts leak network size.
- **`network_sizes`** — any size figure (sources, scopes, classes) given **only as order-of-magnitude
  buckets** (e.g. tens / hundreds / thousands), **never an exact count**.
- **`rotation_events[]`** — the immortality-through-rotation story (a transport class was burned, the
  fabric recovered) as **obfuscated** events: a coarse event class and a coarse time bucket, with the
  exact node, exact time, exact scope, and exact magnitude **withheld** (rule 5).
- **`methodology`** — an explicit block declaring the aggregation floor `k`, the noise mechanism and
  privacy budget in force for this snapshot, the bucket boundaries, the snapshot TTL / freshness, and
  **what is withheld**. The surface declares its own redaction so an auditor can check it.

### 3. The aggregation floor `k`

A single **minimum-aggregation floor `k`** governs every published cell (it is the
`StressSignal.min_aggregate` / `ErrAggregationFloor` discipline, made a public-surface rule):

- `k` is the **minimum number of distinct underlying samples per published cell**. A cell with fewer
  than `k` samples is **OMITTED entirely** — **never shown as 0, never imputed, never blurred to a
  near-zero value** (a shown zero is itself a disclosure that the cell exists below the floor).
- The floor is applied **at the source by the fungi** (rule 1) and **again across sources by the
  publisher** (cross-source coarsening), so neither tier ever publishes a sub-floor cell.
- `k` is a single declared constant for the contract (carried in the `methodology` block and pinned in
  `internal/spec` as the canonical source of truth — call sites never hardcode it, per development.md
  §1.1). This ADR fixes `k`'s **role and the omit-not-zero rule**; the exact integer is the schema's
  declared constant, tunable upward but never below a value that preserves the invariant.

### 4. Noise mechanism and privacy budget

Every published numeric cell is **noised before publication** (at the source, then bounded again at
the publisher):

- Noise is added to ratios, the resilience index, and the lifecycle distribution from a **declared,
  standard, calibrated mechanism** (the contract declares the family and its scale in `methodology`;
  it is a measurement-noise mechanism, not a new cryptographic primitive — ADR-0002 governs signing,
  not statistical noise). Noise is applied **after** flooring, never as a substitute for it.
- The contract carries a **privacy budget**: a declared bound on how much true signal the noised cells
  may collectively reveal per snapshot. The budget is **declared in `methodology`** and is the
  accounting unit for rule 6.
- **Coarsening / bucketing** is mandatory and one-directional: classes not nodes, percentages not
  counts, order-of-magnitude buckets not exact sizes, coarse severity classes not raw magnitudes,
  opaque scopes not geography. Coarsening is irreversible by construction — a published bucket cannot
  be narrowed back to its members.

### 5. Rotation-event obfuscation

`rotation_events[]` exists to tell the recovery story **without** timing or locating a burn:

- Each event publishes only a **coarse event class** (e.g. a class degraded; the fabric recovered
  within a bounded window) and a **coarse time bucket**.
- **Withheld:** the exact node, the exact endpoint, the exact scope, the exact timestamp, the exact
  magnitude, and any sequence detail that could correlate a rotation to a place, an operator, or a
  burn event. An event that cannot be obfuscated to this rule is **omitted**, not approximated.

### 6. The cumulative-disclosure bound (across snapshots)

The standing risk is not any single snapshot but **the sum of successive snapshots over time**
(VIS-0003 §10 cumulative enumeration / fragment-stitching):

- **Successive snapshots MUST NOT, in aggregate, disclose more than any single snapshot.** The series
  is held to the per-snapshot privacy budget (rule 4) **as a running total**, not per-snapshot in
  isolation — differencing two snapshots, or summing many, must not reverse a below-floor cell, narrow
  a bucket, or de-obfuscate a rotation event.
- This is enforced by **consistent flooring, bucket boundaries, and scope-id treatment across
  snapshots** (stable buckets so diffs reveal nothing; opaque scope ids that do not become a stable
  cross-snapshot fingerprint of a place) and by the cumulative budget accounting above. The contract
  records the bound; the fail-closed conformance check that proves a given snapshot series honours it
  lives in the conformance suite (VIS-0005 §7), not in this ADR.

### 7. No new identity-bearing field; allow-listed projection

The contract is a **redacted projection** of the inert `internal/spec` shapes and adds **no** field
that names or is reversible to: an IP, host, ASN, port, SNI, country, location code, region, email,
secret, per-node identifier, per-edge weight, exact count, or any per-user fact. Both schemas are
**allow-listed**: a value not enumerated above must not be emitted. A snapshot that cannot be proven
to satisfy this is **not published** (fail-closed — the check is the conformance suite's, VIS-0005 §7).

## Consequences

- VIS-0005's surface has a **binding contract**: the `network-weather.json` field set, the
  `stress-digest` envelope shape, and the numeric rules (`k`, noise, buckets, rotation obfuscation,
  cumulative bound) are now specified rather than gestured at — implementable by the separate
  AGPL explorer repository against a fixed reference.
- The `stress-digest` is a `SporeEnvelope` with `type = stress-digest`, so it inherits ADR-0002 signing
  (key-id + signature bytes), TTL/replay bounds, scoping, and `import-inert-until-validated` for free —
  no new envelope or crypto scheme is introduced.
- The surface is **provably non-reversible by construction**: classes not nodes, percentages not
  counts, buckets not sizes, opaque scopes not geography, obfuscated rotations, every shown cell at or
  above `k`, and a cumulative bound across snapshots. An auditor can diff a snapshot against the
  `methodology` block and confirm what is withheld.
- The exact `k` integer, the noise family's scale, and the bucket boundaries are **declared constants**
  carried in `methodology` and pinned in `internal/spec`; they are tunable upward without changing the
  contract, but never below the value that preserves the omit-not-zero and cumulative-bound invariants.
- The **running publisher and site are deferred** (RP-0004, VIS-0005 §12): this ADR ships definitions,
  not a publisher, a site, or a live snapshot. The privacy-bearing transform lives in the fungi and the
  publisher when they are built — never in the browser.

## Alternatives considered

- **A node directory / topology / per-node rows ("advanced mode").** Rejected — this is the exact
  artifact VIS-0005 exists to forbid: a published node→endpoint→peers→location view is simultaneously a
  routing table and a surveillance dataset, the adversary's single most valuable prize (VIS-0003 §6).
  The contract is class/percentage/bucket/opaque-scope precisely so it cannot tile back into a map.
- **Exact counts and timestamps (more "useful").** Rejected — counts leak network size and growth, and
  exact rotation timing locates burns; percentages, order-of-magnitude buckets, and coarse time buckets
  give legibility without the enumeration surface.
- **Per-snapshot privacy only (ignore cumulative disclosure).** Rejected — successive snapshots sum and
  diff into more than any single one (VIS-0003 §10); the contract binds a cumulative budget and stable
  bucket/scope treatment across the series, not just per snapshot.
- **A bespoke digest signing / obfuscation scheme.** Rejected (ADR-0002) — the digest is a standard
  signed `SporeEnvelope` (key-id + signature bytes); statistical noise uses a declared standard
  mechanism. No home-grown crypto is introduced anywhere in the contract.
- **Specify the running publisher and live snapshot here.** Rejected for phase discipline — this ADR
  pins the inert contract; the verify→coarsen→suppress→strip→emit publisher and the static site are
  deferred to RP-0004 and the separate explorer repository (VIS-0005 §12).

## Phase discipline

Per ADR-0013 and VIS-0005 §4 "Non-goals — phase discipline": in **Phase 0-2** the shapes in this ADR
are **INERT typed schemas only**, projected from `internal/spec` (whose every type is a data model with
`Validate()` and no running behaviour). **No** running publisher, **no** live `network-weather.json`,
**no** fungi emitting digests onto a mesh, **no** DHT, gossip, registry, announce-into-mesh, or global
topology runs here. The fungi opt-in path, when built, rides only the allowed Phase-0-2 telemetry
envelope (**opt-in, PII-safe, aggregated, no correlation, no identity binding**); the running publisher
and static site are **deferred to RP-0004** (VIS-0005 §12) and the separate AGPL explorer repository.
The project operates no public deployment and publishes no public endpoint for this surface.
