<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Network-weather explorer: the off-network publisher and the static site

> **Document type.** Refactoring / Change Proposal. Structure matches
> [../refactoring.md](../refactoring.md) and
> [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md).
> This RP is the **plan** spawned by [VIS-0005 §12](../vision/0005-network-weather-explorer.md): it
> defines the **off-network explorer publisher** (verify → coarsen → suppress-below-floor → strip →
> emit a static `network-weather.json`) and the **static explorer site** that renders that snapshot
> and nothing else. It pins **no** running publisher and no live deployment: the privacy-bearing
> transform is contracted here, the build is a future phase, and the project operates no public
> endpoint. The data contract, the aggregation floor `k`, the fungi opt-in path, and the anti-Sybil
> source weighting are decided in the companion ADRs (§8); this RP plans the work that consumes them.

---

## Metadata
- **ID:** RP-0004
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** cross-cutting **Measurement** track — a central publisher from Phase 0 onward, dissolving into mesh-native digest-spore ingestion in Phase 4 (see [../ROADMAP.md](../ROADMAP.md) cross-cutting tracks)
- **Related documents:**
  [VIS-0005](../vision/0005-network-weather-explorer.md) (the source Vision — this RP is its §12 publisher item);
  ADR-0017 (network-weather data contract & aggregation floor — the `network-weather.json`/`stress-digest` schema, the floor `k`, noise budget, coarsening/bucketing rules, rotation-event obfuscation, and the cumulative-disclosure bound this RP's pipeline enforces; authored alongside this RP per §8);
  ADR-0018 (fungi role & opt-in publish path — the `cache-custodian`-class fungi niche, the opt-in upload protocol now vs the mesh-native spore path later, and the anti-Sybil source weighting; authored alongside this RP per §8);
  [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md) (software, not an operated network — the separation/self-host posture this RP inherits);
  [ADR-0002](../adr/0002-no-custom-cryptography.md) (no custom cryptography — each digest is a signed `SporeEnvelope` verified with standard primitives, key-id + signature bytes, never a new scheme);
  [internal/spec/network.go](../../internal/spec/network.go) (the inert schemas this projects from: `TransportHealth`, `StressSignal`, `EdgeState`, `GradientSignal`, `SporeEnvelope`, `TrustScope`, `NodeRole`, `SporeTypeStressDigest`);
  [../GLOSSARY.md](../GLOSSARY.md) §"Network weather" (network weather / fungi / stress-digest / aggregation floor / publisher);
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (the network map as the adversary's single most valuable prize);
  [../development.md](../development.md) (where the fail-closed conformance check is registered — the invariant, not the gate, is named here);
  [../refactoring.md](../refactoring.md) §13.

## 1. Title
Define the off-network network-weather explorer: a publisher pipeline that **verifies** signed fungi
digests, **coarsens** across sources, **suppresses** below-floor cells, **strips** anything resembling
a leak, and **emits** a static `network-weather.json` snapshot; a static, self-hostable explorer site
that renders only that snapshot with **no visitor tracking**; and a fail-closed conformance check that
refuses to publish any snapshot that cannot be proven to honour the §7/ADR-0017 leak invariant — with
the privacy-bearing step living in the fungi and the publisher, **never** in the browser.

## 2. Reason
[VIS-0005](../vision/0005-network-weather-explorer.md) settled *why and where*: the fabric measures
itself (Phase-0 observability; the redacted `internal/spec` signals), but that health is invisible to
the people the project is for, and the naive way to surface it — a node directory — is the single most
dangerous artifact the project could ship, because **the network map is the adversary's prize**
([../THREAT-MODEL.md](../THREAT-MODEL.md) §Protected assets). VIS-0005 fixed the inside-out answer (an
aggregated Tor-Metrics/OONI-style surface that cannot be reversed into topology), enumerated the
invariants (its §3, §7), and spawned three companion records: the data contract (ADR-0017), the fungi
opt-in path (ADR-0018), and **this RP — the publisher + site** (§12).

What is missing is the **work and migration plan** for the off-network half: how a heap of signed,
already-redacted fungi digests becomes one static, auditable snapshot, and how a site renders it without
itself becoming the correlation tool VIS-0003 §8 warns against. The gap is a build/plan gap, not an
algorithmic one — the privacy math (`k`, noise, coarsening, bucketing, the cumulative-disclosure bound)
is ADR-0017's job, and the source-side aggregate-and-forget is ADR-0018's. Specifically:

- **No publisher pipeline exists.** The fungi opt-in digest is a redacted `SporeEnvelope`
  (`SporeTypeStressDigest`), but nothing collects digests from many sources, re-coarsens across them,
  suppresses cells below the floor, strips residual leak-shaped fields, and emits the static snapshot.
  Until that pipeline is specified, the only thing standing between "many signed digests" and "a public
  map" is policy, not a contracted, ordered, fail-closed transform.
- **There is no fail-closed publish gate.** VIS-0005 §7 requires that *an unprovable-safe snapshot is
  not published* — yet no check exists that fails the build when a generated snapshot carries an
  IP/host/ASN/port/SNI/country/location-code/secret/per-node identifier, or a shown cell below `k`, or
  an un-bucketed network count. Without it, the leak invariant is an aspiration, not a guarantee.
- **The site's "no surveillance" property is undefended.** A site *about* private connectivity must not
  track its readers (no analytics, no third-party scripts, no identity-linked logs), must do **no live
  node queries** (an endpoint a visitor can query is an enumeration surface), and must be self-hostable
  from the static snapshot. None of this is yet a contract; it is the easiest property to lose by
  accident (one analytics snippet, one live API call).
- **The separation posture is not yet projected onto the explorer.** [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)
  fixes that the project is *software, not an operated network*: it runs no public deployment and
  publishes no public endpoint. The explorer must inherit this exactly — the project ships explorer
  *software*, each operator self-hosts their own instance and decides what (if anything) it publishes —
  and the code must live in a **separate AGPL repository**, not be conflated with a project-run service.
- **Where the privacy transform lives is unstated.** The single most important architectural decision —
  that obfuscation happens **at the source (fungi) and in the publisher, never in the browser** — is a
  VIS-0005 §3 principle with no plan binding the publisher and site to it.

Left unplanned, the project has a Vision that forbids a map and a measurement stack that produces the
redacted inputs, but no contracted, fail-closed off-network path between them — the worst case being a
well-intentioned explorer build that quietly reintroduces the enumeration surface the whole architecture
exists to deny.

## 3. Scope
- **Layers:** observability/measurement (the publisher's coarsen/suppress/strip transform and the
  snapshot contract), and a thin presentation surface (the static site). **No** control plane, no data
  plane, no routing/discovery/coordinator, and **no** DHT/gossip/registry/announce — the publisher
  consumes already-redacted aggregates only (VIS-0005 §4 non-goals).
- **Components:** the **publisher** (off-network: verify signed digests → coarsen across sources →
  suppress below-floor cells → strip leak-shaped fields → emit the static `network-weather.json`); the
  **static explorer site** (renders the snapshot; no live queries; no visitor tracking; self-hostable);
  the **fail-closed publish conformance check** (registered in [../development.md](../development.md)
  and the conformance suite — the **invariant** is named here, the gate is not). All three live in a
  **separate AGPL repository**; this RP is the canonical reference that repository implements against.
- **Contracts:** the publisher reads `SporeEnvelope` digests of type `SporeTypeStressDigest` (the inert
  `internal/spec` shapes — `StressSignal`/`TrustScope`/`SporeEnvelope`), each verified per
  [ADR-0002](../adr/0002-no-custom-cryptography.md) (signer key-id + signature bytes, a standard
  primitive — never a new scheme); it emits the `network-weather.json` snapshot whose **schema, floor
  `k`, noise budget, coarsening/bucketing rules, rotation-event obfuscation, and cumulative-disclosure
  bound are defined in ADR-0017** (not re-specified here). The publisher adds **no** new identity-bearing
  field: the snapshot is a redacted *projection* of the inert signals, never a superset.
- **Storage / state:** the publisher holds only **already-redacted aggregates** — never raw observations
  (those are aggregated-and-forgotten at the fungi per ADR-0018), never a node list, never per-edge
  weights, never geography, never per-user facts. It retains the in-flight signed digests long enough to
  verify and coarsen, then the published snapshot; nothing identity-bearing is persisted. The site is
  **static** — it stores no visitor data, sets no identity-linked logs, and loads no third-party origin.
  **No node IP/host/country/jurisdiction/location-code/email/secret/per-node-id is ever stored, emitted,
  or rendered at any tier.**
- **Flows:** opt-in fungi publish a signed `stress-digest` → publisher **verifies** each signature
  (`import-inert-until-validated`; an unverifiable digest never influences output) → **coarsens** across
  sources → **suppresses** every cell below the floor `k` (omit, never show as zero) → **strips** any
  residual leak-shaped field → **emits** the static `network-weather.json` → the fail-closed check
  proves the snapshot honours the leak invariant → the static site (operator-self-hosted) renders it.
  **The browser performs no privacy transform and no live query** — it only renders the pre-proven
  snapshot.
- **Schemas / formats:** **no new wire crypto and no new identity field.** The snapshot is the
  ADR-0017 contract; the digest is the existing `SporeEnvelope`/`SporeTypeStressDigest` shape. This RP
  invents no cipher, no scheme, and no per-node-bearing structure.

### 3.1. Component participation table (mandatory)

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| explorer publisher (separate AGPL repo) | The off-network pipeline: verify → coarsen → suppress-below-floor → strip → emit `network-weather.json`; holds only already-redacted aggregates; the privacy-bearing step lives here + in the fungi, never in the browser | deferred (planned here; future build) | standard signature verify (key-id + bytes, [ADR-0002](../adr/0002-no-custom-cryptography.md)) / jq / a static-site generator (operator choice) | Bespoke privacy projection over the project's own redacted schemas; no off-the-shelf aggregator enforces the §7/ADR-0017 leak invariant or the floor. |
| static explorer site (separate AGPL repo) | Renders the snapshot **only**; no live node queries; **no** analytics/third-party scripts/identity-linked logs; self-hostable from the static snapshot; AGPL | deferred (planned here; future build) | static HTML/JS (no third-party origin) | A surveillance-free, self-hostable static surface is a deliberate constraint, not a SaaS analytics product. |
| fail-closed publish check (conformance suite + [../development.md](../development.md)) | Refuses to publish any snapshot that is not provably leak-free (no IP/host/ASN/port/SNI/country/location-code/secret/per-node-id; every shown cell ≥ `k`; sizes bucketed) — **invariant named here, gate not enumerated** | deferred (planned here; future build) | system shell / jq (verification harness) | The invariant is bespoke to this snapshot contract; the concrete check is an engineering detail kept in the conformance directory + `development.md`, never spelled out in an RP. |
| fungi opt-in publish path | W-source: the `cache-custodian`-class fungi aggregates its own neighbourhood's redacted signals, applies the floor + noise **at the source**, forgets the raw inputs, and emits the signed `stress-digest`; the publisher's only input | deferred (its protocol + niche rotation + anti-Sybil weighting are **ADR-0018's** decision) | standard signature (key-id + bytes) / jq | Source-side aggregate-and-forget; the upload protocol + niche rotation + Sybil weighting are decided in ADR-0018, consumed (not re-decided) here. |
| `internal/spec` (`StressSignal`, `SporeEnvelope`, `TrustScope`, `SporeTypeStressDigest`, …) | The inert, typed shapes the digest and snapshot project from; **read, not changed** — no new identity-bearing field is added | active (inert schemas) | Go | The shapes already exist and are inert (VIS-0003 §4 phase discipline); the explorer is a redacted projection of them. |
| `network-weather.json` snapshot contract | The single static artifact the site renders; its **schema/`k`/noise/bucketing/rotation-obfuscation/cumulative bound are ADR-0017's**, consumed here | deferred (defined in ADR-0017) | JSON | One published contract, decided once in the ADR; this RP plans the pipeline that produces and proves it. |
| DHT / gossip / registry / announce-into-mesh | **Not built here** — the publisher receives opt-in uploads now; mesh-native digest-spore ingestion is Phase 4 (the public contract is unchanged, only the transport beneath it) | deferred | none | Phase 4 ([../ROADMAP.md](../ROADMAP.md) scope discipline); inert here by design — no mesh behaviour is pulled forward. |
| node directory / membership list / topology / geographic map | **Not built — for any tier, not as an "advanced mode"** | excluded | none | The line the whole Vision exists to hold (VIS-0005 §4); a directory is simultaneously a routing table and a surveillance dataset. |

### 3.2. Blast-radius cap
> One RP = one manageable step.

This RP is a **single-step plan** for one coherent responsibility — *define the off-network half of the
network-weather explorer (publisher + site + publish gate)* — and is **declared `draft`, with the build
deferred to a future phase**. It changes no running behaviour: `internal/spec` is read, not modified; no
new wire crypto, no new identity-bearing field, and no client-facing contract is introduced; and the
deliverable lives in a **separate AGPL repository**, so the canonical repo gains a reference document and
(when the build lands) a registered fail-closed conformance check, not a service.

- **Responsibility boundaries affected:** 0 in this repo (the explorer is a *separate-repo* surface; the
  inert schemas are projected from, not redrawn).
- **Layers affected (behaviour):** 0 new running behaviours in Phase 0–2 — the publisher/site are a
  future build; only the opt-in PII-safe digest path rides the allowed Phase-0–2 telemetry envelope.
- **Config-distribution surfaces affected:** 0 — the project runs no public deployment and publishes no
  public endpoint; each operator self-hosts.
- **Files in diff (estimate):** ~1–3 in this repo (this RP; the human-added index row; an optional
  cross-ref touch in [../development.md](../development.md) when the gate is later registered). The
  publisher + site themselves are commits in the **separate** AGPL repository.

- [x] Within cap — single-step RP (a plan/contract; the build is deferred to a future phase).
- [ ] Exceeds cap → declared multi-phase.

  The plan is organised as four ordered workstreams (W1 verify-ingest → W2 transform: coarsen →
  suppress → strip → W3 emit + fail-closed publish gate → W4 the static, surveillance-free site). They
  are a *specification* sequence: each defines a stage of the one pipeline and its DoD/verification, so
  the future separate-repo build has an ordered, testable target. W2 depends on W1 (only verified
  digests are transformed); W3's gate guards W2's output; W4 consumes W3's proven snapshot.

## 4. Current state
The Vision and the inert inputs exist; the **off-network pipeline, the publish gate, and the site do
not**. Specifically:

- **Inputs (the fungi digest) — defined, inert, not yet flowing to a publisher.**
  [internal/spec/network.go](../../internal/spec/network.go) carries the redacted, scoped, TTL-bounded
  shapes (`StressSignal` with its `MinAggregate` floor and `SampleCount ≥ MinAggregate` invariant;
  `SporeEnvelope` with `SporeTypeStressDigest`, a `TrustScope`, and a standard signer key-id + signature
  bytes per [ADR-0002](../adr/0002-no-custom-cryptography.md)). Every type is **inert** (VIS-0003 §4): no
  node aggregates, emits, verifies, or germinates a digest yet, and `DiscoveryBackend.ReportStress` is a
  declared-only stub. The fungi opt-in *protocol* (now) and its mesh-native dissolution (Phase 4) are
  **ADR-0018's** to decide.
- **Verify (W1) — no ingest.** Nothing collects opt-in digests, applies `import-inert-until-validated`,
  or verifies the `SporeEnvelope` signature against an out-of-band source key before a digest may
  influence output. There is no per-source cap and no cross-source coarsening step.
- **Transform (W2) — no coarsen/suppress/strip.** No code coarsens across sources, suppresses cells
  below the floor `k` (omit, never zero), buckets network sizes to order-of-magnitude, renders the
  edge-lifecycle distribution as **percentages** (counts leak network size), obfuscates rotation events,
  or strips residual leak-shaped fields. The floor `k`, the noise mechanism/budget, the coarsening and
  bucketing rules, the rotation-event obfuscation, and the **cumulative-disclosure bound across
  snapshots** are **ADR-0017's** to pin; this RP consumes them.
- **Emit + gate (W3) — no snapshot, no fail-closed publish check.** No `network-weather.json` is
  produced, and there is **no** check that refuses to publish a snapshot carrying an
  IP/host/ASN/port/SNI/country/location-code/secret/per-node identifier, or a shown cell below `k`, or an
  un-bucketed count. The conformance suite today runs offline gates (registered in
  [../development.md](../development.md) and the conformance directory); the network-weather publish
  invariant is **not** among them — and per the operator rule, this RP names only the **invariant**, not
  any gate script or its patterns.
- **Site (W4) — no surface.** No static site renders a snapshot; nothing yet guarantees no live node
  queries, no analytics, no third-party scripts, no identity-linked visitor logs, and self-hostability
  from the static snapshot.
- **Separation — posture set, not yet projected.** [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)
  fixes *software, not an operated network*; nothing yet states that the explorer inherits this exactly,
  that the code lives in a **separate AGPL repository**, and that each operator self-hosts their own
  instance and decides what it publishes.

## 5. Target state
A contracted, fail-closed off-network explorer: opt-in fungi emit signed, already-redacted
`stress-digest` envelopes; an off-network **publisher** verifies each signature, coarsens across
sources, suppresses every below-floor cell, strips anything leak-shaped, and emits a single static
`network-weather.json`; a **fail-closed publish check** refuses any snapshot that is not provably
leak-free (per the §7/ADR-0017 invariant); and a **static, surveillance-free, self-hostable** site
renders that snapshot and nothing else. The **privacy-bearing transform lives in the fungi and the
publisher, never in the browser**, and the whole thing is **separate-repo, AGPL, project-runs-nothing**
software. The build is deferred to a future phase; this RP is the plan, status `draft`.

- **Map never assembled.** No tier — fungi, publisher, or site — holds or publishes global topology, a
  node list, per-node rows, per-edge weights, geography, or identity. The snapshot is a projection of
  aggregates that **cannot tile back into a map** (VIS-0005 §3, §7).
- **Obfuscate at the source, not at the sink.** The floor + noise are applied by the fungi *before*
  anything leaves the node (ADR-0018); the publisher re-coarsens, suppresses, and strips; the **browser
  performs no privacy transform and no live query** (VIS-0005 §3).
- **Opt-in, aggregate-and-forget.** A node contributes only if its operator chooses the fungi role; the
  publisher holds only already-redacted aggregates and never accretes raw inputs (VIS-0005 §3, ADR-0018).
- **No new cryptography.** Each digest is a signed `SporeEnvelope` verified with standard primitives
  (key-id + signature bytes, [ADR-0002](../adr/0002-no-custom-cryptography.md));
  `import-inert-until-validated` applies to every digest ingested.
- **The site is not surveillance.** No analytics, no third-party scripts, no identity-linked visitor
  logs, no live node queries; static, self-hostable, AGPL (VIS-0005 §3, §7).
- **Separation/legal (ADR-0016).** The project operates **no** public deployment and publishes **no**
  public endpoint; each operator self-hosts their own explorer instance and decides what (if anything)
  it publishes; the code lives in a **separate AGPL repository**.

The plan is organised as four ordered workstreams.

---

### W1 — Verify-and-ingest (opt-in signed digests, fail-closed)
**Goal.** Define how the publisher ingests opt-in fungi digests so that **only verified, already-redacted
aggregates** ever influence the snapshot — `import-inert-until-validated`, applied at the off-network
boundary.

**Steps.**
1. **Accept only `SporeTypeStressDigest` envelopes.** The publisher consumes `SporeEnvelope`s of the
   stress-digest type (the inert `internal/spec` shape); anything else is rejected at ingest.
2. **Verify the signature with a standard primitive only** ([ADR-0002](../adr/0002-no-custom-cryptography.md)):
   the signer key-id + signature bytes are checked against an out-of-band set of accepted source keys.
   An unverifiable, expired (TTL per the envelope), or wrong-scope digest is treated as inert and
   **never** influences output (`import-inert-until-validated`).
3. **Treat the digest as already-redacted, never raw.** The publisher does **not** request, store, or
   reconstruct raw observations; the floor + noise were applied at the fungi (ADR-0018). The publisher
   validates the digest's structural invariants (e.g. `StressSignal.SampleCount ≥ MinAggregate`) and
   drops any digest that fails them.
4. **Bound a single source's influence (consume ADR-0018's anti-Sybil weighting).** Apply the per-source
   cap / source weighting that ADR-0018 decides; the load-bearing Sybil resistance is the ADR's job, not
   re-decided here. The publisher receives opt-in uploads now; **mesh-native digest-spore ingestion is
   Phase 4** (same public contract, different transport beneath it — VIS-0005 deferred).

**Definition of Done.** The publisher's ingest contract is specified such that: only signed,
in-TTL, in-scope `stress-digest` envelopes verified against an out-of-band source key influence the
snapshot; an unverifiable/forged/expired/wrong-type digest is inert and changes nothing; per-source
influence is bounded per ADR-0018; no raw observation is ever requested, stored, or reconstructed.

**Verification.**
- A forged-signature, an expired-TTL, a wrong-scope, and a non-stress-digest envelope each leave the
  emitted snapshot **unchanged** (treated as inert).
- A digest that fails its structural invariant (e.g. `SampleCount < MinAggregate`) is dropped.
- A flood from a single source cannot move the snapshot beyond the ADR-0018 per-source cap.

**Dependencies / ordering.** First; consumes ADR-0002 (signature) and ADR-0018 (opt-in protocol +
source weighting). Prerequisite for W2 (only verified digests are transformed).

**Risks + mitigations.** **Fungi-digest poisoning / Sybil sources** — a flood of fake opt-in digests
skews the weather; bounded by signed digests, `import-inert-until-validated`, the aggregation floor,
cross-source coarsening (W2), and the ADR-0018 per-source cap. **Publisher as a value target** — it holds
only already-redacted aggregates and must never accrete raw inputs (so there is little to coerce out of
it). **Threat-model:** *Knowledge minimisation* (raw observations never reach the publisher); *Operator
coercion* (the publisher holds no node list and no raw data).

---

### W2 — Coarsen → suppress-below-floor → strip (the privacy projection)
**Goal.** Turn verified per-source digests into a single, projected aggregate that **cannot be reversed
into a map**: coarsen across sources, suppress every below-floor cell, and strip anything leak-shaped —
the privacy-bearing step, living **in the publisher (and the fungi), never in the browser**.

**Steps.**
1. **Coarsen across sources.** Combine the verified digests into per-transport-**class** health/
   reachability (never per node), coarse interference signal **classes** carrying an **opaque scope id,
   never geography**, and the edge-lifecycle distribution — applying the coarsening rule ADR-0017 pins.
2. **Suppress below the floor `k`.** Any cell whose aggregated sample count is below the floor is
   **omitted, never shown as zero** (showing zero is itself a signal). The floor `k` and the noise
   mechanism/budget are ADR-0017's; the publisher honours, not redefines, them.
3. **Bucket sizes; percentages not counts.** Network sizes are emitted as **order-of-magnitude buckets**
   (raw counts leak network size); the edge-lifecycle distribution is emitted as **percentages**, not
   counts; rotation events are **obfuscated** per ADR-0017's rule.
4. **Strip anything resembling a leak.** Before emit, remove any residual field that looks like a node
   IP/host/ASN/port/SNI/country/location-code/secret/per-node-id — the publisher adds **no** new
   identity-bearing field; the snapshot is a redacted projection, never a superset of the inert signals.
5. **Honour the cumulative-disclosure bound.** Apply ADR-0017's bound so that successive snapshots over
   time do not sum to more than any single one (the standing *cumulative* enumeration risk, VIS-0005 §10).

**Definition of Done.** The transform is specified end-to-end (coarsen → suppress → strip) such that the
projected aggregate carries only by-class/percentage/bucket/opaque-scope values; below-floor cells are
omitted (never zero); sizes are bucketed; the lifecycle distribution is percentages; rotation events are
obfuscated; no leak-shaped field survives; and the cumulative-disclosure bound is applied across
snapshots. The transform lives **only** in the publisher + fungi.

**Verification.**
- An auditor cannot reverse a transformed aggregate into topology, a membership/node list, geography, an
  endpoint, or any per-user fact (inspection + the W3 gate agree).
- Every shown cell meets the floor `k`; a synthetic below-floor cell is **omitted**, not shown as zero;
  network sizes are buckets, the lifecycle is percentages.
- A diff across successive snapshots confirms they do not sum to more than any single one (cumulative
  bound holds).

**Dependencies / ordering.** After W1 (transforms only verified digests). Consumes ADR-0017 (`k`, noise,
coarsening/bucketing, rotation obfuscation, cumulative bound). Feeds W3 (its output is what the gate
proves).

**Risks + mitigations.** **The surface becomes the very map it forbids** — bounded by building from the
invariants (by-class/percentage/bucket/opaque-scope), the floor, and (W3) the fail-closed gate. The
standing risk is **cumulative disclosure across snapshots** — the cumulative bound (step 5) and a
periodic adversarial review address it. **Threat-model:** *Knowledge minimisation* (the bias is
deliberately toward less — classes not nodes, percentages not counts, buckets not exact sizes); *the
network map* (never assembled at any tier).

---

### W3 — Emit the static snapshot + the fail-closed publish gate
**Goal.** Emit the single static `network-weather.json` (the ADR-0017 contract) and gate its publication
**fail-closed**: a snapshot that cannot be proven to honour the leak invariant is **not published**.

**Steps.**
1. **Emit the ADR-0017 snapshot.** Serialise the W2 aggregate into the `network-weather.json` schema
   ADR-0017 defines — an overall resilience index; per-transport-class state and reachability; coarse
   interference classes with opaque scope ids; the lifecycle distribution as percentages; obfuscated
   rotation events; bucketed sizes; and a methodology block declaring `k`, the noise, and what is
   withheld. This RP defines **no** schema field — it consumes the contract.
2. **Enforce the leak invariant fail-closed.** A generated snapshot is publishable **only** if it
   provably contains **no** IP/host/ASN/port/SNI/country/location-code/secret/per-node-id; **every** shown
   cell is at/above `k`; and **all** network sizes are bucketed. *Fail-closed:* an unprovable-safe
   snapshot is **not** published. **Per the operator rule, this RP references the invariant only — the
   check itself lives in the conformance suite and [../development.md](../development.md); no gate script
   or its patterns is named here.**
3. **Snapshot freshness/TTL.** Emit with freshness/TTL metadata so a stale snapshot is detectable; the
   site renders only a fresh, gate-passed snapshot.

**Definition of Done.** The publisher emits a static `network-weather.json` conforming to ADR-0017; the
fail-closed publish check refuses to publish any snapshot that carries an
IP/host/ASN/port/SNI/country/location-code/secret/per-node-id, or a shown cell below `k`, or an
un-bucketed count; an unprovable-safe snapshot is **not** published; the invariant (not a gate script) is
recorded here and the check is registered in the conformance suite + `development.md`.

**Verification.**
- A clean, in-floor, fully-bucketed snapshot passes and is published.
- A snapshot with a seeded leak of each forbidden kind (a node IP/host/ASN/port/SNI/country/location-code,
  a secret, a per-node id), or a below-floor shown cell, or an un-bucketed count, is **refused**
  fail-closed (nothing published).
- The invariant is documented; the conformance suite (per `development.md`) runs the check — this RP does
  not enumerate it.

**Dependencies / ordering.** After W2 (gates its output). Consumes ADR-0017 (the schema + `k` + bucketing
the gate checks against). Prerequisite for W4 (the site renders only a gate-passed snapshot).

**Risks + mitigations.** **A leak slips into the published snapshot** — prevented fail-closed: an
unprovable-safe snapshot is not published. **The gate becomes a spec the RP over-specifies** — avoided by
the operator rule (name the invariant, not the gate). **Cumulative disclosure** — checked by the W2
cumulative bound plus a periodic adversarial review (VIS-0005 §8, §12 event-driven audit). **Threat-model:**
*Supply-chain / disclosure* (no unverified-safe artifact is published); *the network map* (mechanically
refused at publish).

---

### W4 — The static, surveillance-free, self-hostable explorer site
**Goal.** A static site renders the gate-passed `network-weather.json` **and nothing else**: no live node
queries, no visitor tracking, self-hostable by any operator, AGPL — and **no privacy transform in the
browser**.

**Steps.**
1. **Render the snapshot only.** The site loads a single static `network-weather.json` and renders the
   resilience index, per-class transport health, coarse interference signals, the lifecycle distribution,
   and rotation events. It performs **no** live query against any node (a queryable endpoint is an
   enumeration surface — VIS-0005 §4 out-of-scope) and **no** privacy transform (that lives upstream).
2. **No surveillance.** The site loads with **no analytics, no third-party scripts, and no
   identity-linked visitor logs**; it adds no client-side telemetry of its own (VIS-0005 §7, §8).
3. **Self-hostable, separate-repo, AGPL.** The site is a static artifact any operator can self-host from
   the redacted snapshot; the code lives in a **separate AGPL repository**; the **project operates no
   public reference deployment and publishes no public endpoint** ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).

**Definition of Done.** The site renders the resilience index, per-class transport health, coarse
interference signals, the lifecycle distribution, and rotation events from a single static
`network-weather.json`; it makes **no** live node query and runs **no** analytics/third-party
script/identity-linked log; it is self-hostable from the snapshot and AGPL; the project runs no public
deployment.

**Verification.**
- With the network unreachable, the site still renders fully from the static snapshot (proving no live
  query).
- A network trace of a site load shows **no** request to any third-party origin and **no** analytics/
  tracking beacon; no identity-linked log is written.
- The site is served as static files by any operator from the snapshot alone; no project-run endpoint is
  required or published.

**Dependencies / ordering.** Last; consumes W3's gate-passed snapshot. Independent of W1/W2 internals (it
sees only the published artifact). Lives in the separate AGPL repository.

**Risks + mitigations.** **The site becomes a surveillance/enumeration surface** — prevented by
render-only (no live query), no analytics/third-party scripts/identity-linked logs, and static
self-hosting. **Conflation with a project-run service** — prevented by the ADR-0016 separation posture
(separate repo, no public deployment, no public endpoint; each operator decides what to publish).
**Threat-model:** *Active probing* (no queryable endpoint exists); *Knowledge minimisation* (the site
adds no visitor telemetry).

---

## 6. Risks
- **Compatibility.** None client-facing — this RP changes no client contract and no running behaviour;
  it reads the inert `internal/spec` schemas and projects a redacted snapshot. The snapshot schema is
  ADR-0017's; the digest is the existing `SporeEnvelope`/`SporeTypeStressDigest` shape. No new wire
  crypto and no new identity-bearing field is introduced.
- **User security (requirement №1).** The architecture's core asset — the **network map** — is never
  assembled at any tier; no IP/host/ASN/port/SNI/country/location-code/secret/per-node-id or per-user
  fact ever enters any cell. The privacy transform lives at the source (fungi) and in the publisher,
  **never** in the browser; the site adds no visitor tracking. Fail-closed publish: an unprovable-safe
  snapshot is not published.
- **Cumulative disclosure (the standing risk).** Each shown detail helps legibility *and* an adversary,
  and the dominant residual risk is **across snapshots over time**. Bounded by the by-class/percentage/
  bucket/opaque-scope rules, the floor `k`, the publish gate, and ADR-0017's cumulative-disclosure bound,
  plus a periodic adversarial review (VIS-0005 §8) and the §12 event-driven audit when the first live
  snapshot lands.
- **Fungi-digest poisoning / Sybil sources.** A flood of fake opt-in digests skews the weather; bounded
  by signed digests, `import-inert-until-validated`, the aggregation floor, cross-source coarsening, and
  per-source caps — the load-bearing anti-Sybil weighting is **ADR-0018's** job, consumed here.
- **Publisher as a value target.** It is a temporary centre; it holds **only already-redacted
  aggregates**, must never accrete raw inputs or reconstruct topology, and **dissolves into mesh-native
  digest-spore ingestion in Phase 4** (same public contract, different transport).
- **Indistinguishability / probe surface.** The site exposes **no** queryable endpoint (no live node
  query), so it adds no active-probing surface; it renders a pre-redacted static artifact only.
- **Over-specifying the gate.** Avoided by the operator rule: this RP names the **invariant** only; the
  concrete check lives in the conformance suite + `development.md`, never enumerated here.
- **Phase discipline.** In Phases 0–2 only the **opt-in, PII-safe, aggregated, identity-free** digest
  path runs (per ADR-0018); the publisher and site are a **future build** (this RP is the plan,
  `draft`). No DHT/gossip/registry/announce/global-topology runs; no mesh behaviour is pulled forward.
- **Separation / legal.** Inherits [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md):
  the project operates no public deployment and publishes no public endpoint; the explorer is *software*,
  each operator self-hosts and decides what (if anything) to publish; the code is a **separate AGPL repo**.

## 7. Acceptance Criteria
- [ ] The publisher ingests **only** signed, in-TTL, in-scope `stress-digest` envelopes verified against
  an out-of-band source key (standard primitive, [ADR-0002](../adr/0002-no-custom-cryptography.md)); a
  forged/expired/wrong-scope/wrong-type digest is inert (`import-inert-until-validated`) and changes
  nothing; per-source influence is bounded per ADR-0018; no raw observation is ever stored — W1.
- [ ] The transform coarsens across sources, **suppresses every below-floor cell** (omit, never zero),
  buckets sizes to order-of-magnitude, emits the lifecycle distribution as **percentages**, obfuscates
  rotation events, strips every leak-shaped field, and honours the cumulative-disclosure bound; the
  privacy step lives in the publisher + fungi, **never** in the browser — W2.
- [ ] The publisher emits a static `network-weather.json` conforming to ADR-0017, and a **fail-closed**
  publish check refuses any snapshot carrying an IP/host/ASN/port/SNI/country/location-code/secret/
  per-node-id, or a shown cell below `k`, or an un-bucketed count; an unprovable-safe snapshot is **not**
  published; the **invariant is named here, the gate is not** (it lives in the conformance suite +
  `development.md`) — W3.
- [ ] The static site renders the snapshot **only** — no live node queries, **no** analytics/third-party
  scripts/identity-linked visitor logs — and is self-hostable from the static snapshot, AGPL, in a
  **separate repository**; with the network unreachable it still renders fully — W4.
- [ ] **No tier assembles a map:** no node directory, membership list, per-node row, per-edge weight,
  topology view, or geographic map at the fungi, the publisher, or the site — not even as an "advanced
  mode" (VIS-0005 §4).
- [ ] **Separation honoured** ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)): the
  project operates no public deployment and publishes no public endpoint; each operator self-hosts and
  decides what (if anything) it publishes.
- [ ] **Phase discipline:** in Phases 0–2 only the opt-in PII-safe digest path runs (ADR-0018); the
  publisher and site are a future build (this RP is `draft`); no DHT/gossip/registry/announce/
  global-topology runs and no mesh behaviour is pulled forward.
- [ ] **No new cryptography** ([ADR-0002](../adr/0002-no-custom-cryptography.md)): every digest is a
  signed `SporeEnvelope` verified with standard primitives (key-id + signature bytes); the publisher adds
  no new identity-bearing field — the snapshot is a redacted projection of the inert signals.

### Non-goals (deferred to later phases — not in this RP)
- **A node directory / membership list / per-node rows / topology view / geographic map** — for any
  tier, not as an "advanced mode" (VIS-0005 §4: the line the whole Vision exists to hold).
- **Anything per-user** — no identity-attributable client counts, no user geography, no destinations.
- **Live querying of nodes from the browser** — the site reads a pre-redacted static snapshot only.
- **The aggregation floor `k`, the noise mechanism/budget, the coarsening/bucketing rules, the
  rotation-event obfuscation, the cumulative-disclosure bound, the `stress-digest` schema** — decided in
  **ADR-0017**, consumed here.
- **The fungi opt-in upload protocol, the niche rotation, and the anti-Sybil source weighting** — decided
  in **ADR-0018**, consumed here.
- **Mesh-native digest-spore ingestion** (a fungi emits its `stress-digest` as a real spore onto the
  awareness layer and the publisher reads spores) — **Phase 4**; the public contract is unchanged, only
  the transport beneath it. No DHT/gossip/registry/announce runs in Phases 0–2.
- **A project-run reference deployment or a published public endpoint** — the project runs none
  ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)); each operator self-hosts.

## 8. Documentation changes
- [ ] `docs/adr/0017-<slug>.md` (**new**, authored alongside this RP) — network-weather **data contract &
  aggregation floor**: the `network-weather.json` schema, the `stress-digest` spore schema, the floor
  `k`, the noise budget, the coarsening/bucketing rules, the rotation-event obfuscation, and the
  cumulative-disclosure bound this RP's pipeline (W2/W3) enforces. The human adds the row to
  [../adr/README.md](../adr/README.md).
- [ ] `docs/adr/0018-<slug>.md` (**new**, authored alongside this RP) — **fungi role & opt-in publish
  path**: the `cache-custodian`-class fungi niche and rotation, the opt-in upload protocol (Phase 0
  onward) and its dissolution into mesh-native digest spores (Phase 4), and the anti-Sybil source
  weighting W1 consumes. The human adds the row to [../adr/README.md](../adr/README.md).
- [ ] [../development.md](../development.md) — register the **fail-closed network-weather publish
  invariant** (no IP/host/ASN/port/SNI/country/location-code/secret/per-node-id; every shown cell ≥ `k`;
  sizes bucketed; an unprovable-safe snapshot is not published) as a conformance check when the publisher
  build lands. The **invariant** is recorded; the concrete check + patterns stay in the conformance
  directory + `development.md`, **not** enumerated in this RP (operator rule).
- [ ] **Separate explorer repository** (AGPL) — the publisher (W1–W3) + the static site (W4), implementing
  this RP and ADR-0017/ADR-0018; self-hostable by any operator from the redacted snapshot; the project
  operates no public deployment and publishes no public endpoint
  ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — record the network-weather surface under the *network
  map* / *operator coercion* / *active probing* rows: the map is never assembled at any tier, the
  publisher holds only already-redacted aggregates, and the site exposes no queryable endpoint.
- [ ] [../ROADMAP.md](../ROADMAP.md) Measurement track — note the explorer publisher + site as the
  public surface of the digest path, a central publisher now dissolving into mesh-native ingestion in
  Phase 4.
- [ ] Trigger the VIS-0005 §12 **event-driven audit** when the publisher and the first live snapshot land
  (per [../refactoring.md](../refactoring.md)), focused on reversibility and cumulative disclosure.
- [ ] [docs/proposals/README.md](README.md) — add the RP-0004 row (**the human adds the index row** to
  avoid collisions).

## 9. Migration Strategy
There is nothing live to migrate: this RP is a **plan/contract** for a future, separate-repo build, so
"migration" is the *order in which the contract is built and proven*, never a change to a running system.

- **Stages.** ADR-0017 + ADR-0018 land (the data contract + fungi path) → W1 (verify-and-ingest:
  `import-inert-until-validated` over signed opt-in digests) → W2 (coarsen → suppress-below-floor →
  strip) → W3 (emit `network-weather.json` + the fail-closed publish gate) → W4 (the static,
  surveillance-free, self-hostable site). W2 depends on W1; W3 gates W2's output; W4 renders only a
  gate-passed snapshot.
- **Parallel coexistence.** None needed in this repo — the build lives in a **separate AGPL repository**
  and changes no running behaviour here. The opt-in PII-safe digest path (Phase 0–2, per ADR-0018) and
  the future publisher/site coexist by phase: the contract is fixed now, the build follows later.
- **Final cutover.** The moment the publisher emits its first **gate-passed** static snapshot and an
  operator self-hosts the site that renders it, the Measurement track gains its public surface — with the
  §12 event-driven audit run against that first live snapshot before it is relied upon.
- **Phase order.** Phases 0–2: the opt-in PII-safe digest path only (ADR-0018); **no** DHT/gossip/
  registry/announce/global-topology. The publisher + site are a **future build**. Phase 4: the publisher
  reads mesh-native digest spores instead of direct uploads — the **public contract is unchanged**, only
  the transport beneath it.

## 10. Rollback / Fallback
- **How to roll back, and how fast.** Per-snapshot and immediate: the **fail-closed publish gate** is the
  rollback — a snapshot that is not provably leak-free (per the §7/ADR-0017 invariant) is simply **not
  published**, so the last good snapshot (or none) stands. To stop publishing entirely, an operator stops
  generating snapshots and/or stops self-hosting the site; nothing project-run exists to take down. There
  is no client-facing contract and no running service in this repo to revert.
- **Data/keys to preserve.** Nothing identity-bearing exists to preserve: the publisher holds only
  already-redacted aggregates (no node list, no raw observations, no per-edge weights, no geography); raw
  observations are aggregated-and-forgotten at the fungi (ADR-0018). The out-of-band source-key set used
  to verify digests is the only sensitive input and is never committed.
- **Contract/config versions kept in parallel.** None — the snapshot schema is ADR-0017's single contract;
  the digest is the existing `SporeEnvelope`/`SporeTypeStressDigest` shape. No new wire crypto and no new
  identity-bearing field is introduced, so there is no old/new split to maintain.
- **Fail-closed behaviour during rollback.** No silent disclosure path: an unverifiable digest never
  influences output (`import-inert-until-validated`); a below-floor cell is omitted, never shown as zero;
  an unprovable-safe snapshot is **not** published; the site performs no live query and adds no visitor
  tracking. The safe state is *a proven-leak-free snapshot or no snapshot at all*, never
  *published-but-unproven*.

---

## No-secrets / no-IP / no-location note (explicit)
This RP and every artifact it plans obey the project's public-repo discipline and the VIS-0005 §7 leak
invariant. **No** node IP/IPv6 literal, hostname, jurisdiction/country name, location code, ASN, port,
SNI, personal email, secret/key material, per-node identifier, or AI/tool vendor fingerprint (nor
`Co-Authored-By:`) is written into any committed file, into any fungi digest, into the `network-weather.json`
snapshot, or into the rendered site — at **any** tier (fungi, publisher, or site). The privacy-bearing
transform lives at the **source (fungi)** and in the **publisher**, never in the browser; raw
observations are aggregated-and-forgotten at the fungi and never reach the publisher (ADR-0018). The
publisher holds only already-redacted aggregates and adds no identity-bearing field. The **fail-closed publish check** turns
this discipline into a guarantee — an unprovable-safe snapshot is not published — and per the operator
rule this RP records the **invariant** only; the concrete check lives in the conformance suite and
[../development.md](../development.md), never enumerated here. The out-of-band digest-source key set is
never committed.
