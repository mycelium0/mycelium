<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Decentralized Observability (mesh-native awareness without a collector)

> **Document type.** Vision & Scope. This defines *how Mycelium sees itself* — node and network health —
> **without a central collector**, built from the redacted, scope-bounded, decay-bounded contracts the
> fabric already defines. It is "why and where", not a specification; field names, the noise model, the
> gossip/sketch contract, and the publish protocol are pinned by the ADRs and RPs this Vision spawns (§9),
> not here.
>
> **The one reframe that governs everything: the vantage problem.** The single most important question for
> a resilient-access fabric is *"can a user reach a node from the network where their access is being
> blocked?"* — and that question **cannot be answered from the operator's own clean network.** A central
> monitor scraping the operator's fleet measures *the operator's* reachability, not the blocked user's
> (see [../adr/0019-node-local-reachability-health.md](../adr/0019-node-local-reachability-health.md):
> external probing measures the monitoring host's reachability, not the node's egress, and certainly not
> the user's ingress). The only vantage that answers the real question is **the edge — the users and nodes
> inside the affected network** — and the only safe way to gather edge signal is **redacted, floored,
> aggregated, and decentralized**. So decentralization here is not privacy hygiene bolted onto monitoring;
> it is the *only* architecture that can both (a) see what matters (in-region reachability, from in-region
> vantage points) and (b) refuse to build the one thing the project exists to deny — a network map. A
> cross-operator scrape coordinator fails on both counts: it is the map (the adversary's single most
> valuable prize, [../THREAT-MODEL.md](../THREAT-MODEL.md)) **and** it still cannot see in-region.

## Metadata
- **ID:** VIS-0006
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** cross-cutting **Measurement** track. Today: node-local sensing only (L0, deployed). The
  decentralized aggregation layers are Phase 2 (opt-in edge telemetry) and Phase 3–4 (mesh-native gossip).
- **Layer(s):** observability / measurement, control plane (cross-cutting)
- **Related:** [0003-node-interaction-and-distributed-awareness.md](0003-node-interaction-and-distributed-awareness.md),
  [0004-living-network-doctrine.md](0004-living-network-doctrine.md),
  [0005-network-weather-explorer.md](0005-network-weather-explorer.md) (the public L3 surface this feeds);
  [../adr/0017-network-weather-data-contract.md](../adr/0017-network-weather-data-contract.md),
  [../adr/0018-fungi-role-and-opt-in-publish.md](../adr/0018-fungi-role-and-opt-in-publish.md),
  [../adr/0019-node-local-reachability-health.md](../adr/0019-node-local-reachability-health.md),
  ADR-0021 (the decentralized-vs-central decision this Vision motivates);
  [../proposals/0004-network-weather-explorer-publisher.md](../proposals/0004-network-weather-explorer-publisher.md),
  [../proposals/0005-inoculum-bundle-and-toolkit.md](../proposals/0005-inoculum-bundle-and-toolkit.md)
  (the operator bundle that carries an opt-in edge reporter); `internal/spec/network.go` (the inert schemas);
  [../THREAT-MODEL.md](../THREAT-MODEL.md), [../ROADMAP.md](../ROADMAP.md).

## 1. The problem: in-region blindness
A node can be perfectly healthy on the operator's dashboards and completely unreachable from the network
the user is actually on. Reachability is not a property of the node alone; it is a property of the *path
between a specific user network and the node*, and that path is exactly where interference happens
(handshake tampering, RST injection, IP/AS blocking, UDP throttling). The operator's monitoring host sits
on a different, usually unobstructed, path. **Therefore the operator's own measurements — however rich —
are blind to the one signal that matters most: is the node reachable from where access is being blocked?**
This is the central gap any honest observability design for this project must confront. It is not a
footnote to be deferred; it is the reason the architecture is shaped the way it is.

## 2. Why decentralized, not a central collector
Two failure modes of a central collector, both decisive:

1. **A cross-operator collector *is* the network map.** A discovery service + node directory + per-node
   time series is simultaneously a routing table and a surveillance dataset — the precise asset the
   architecture exists to deny ([../THREAT-MODEL.md](../THREAT-MODEL.md)), and a single seizure/coercion
   target (compel one operator, learn the whole fabric). It also contradicts the "software, not an operated
   network" posture ([../adr/0016-software-releases-not-an-operated-network.md](../adr/0016-software-releases-not-an-operated-network.md)).
2. **It still cannot answer the vantage question.** Even a perfectly safe central collector scrapes from
   *its* network, not the blocked user's. It optimizes the wrong thing: exactness and a global view of
   operator-side health, when the missing signal is edge-side, in-region, and inherently distributed.

The answer is to collect *at the edge*, reduce to a redacted aggregate *at the source*, and let the
aggregates flow and merge *locally* — never assembling a global map anywhere. This is the fungal model:
local sensing, lossy scope-bounded signalling, aggregate-and-forget.

## 3. The layered architecture (honest: what RUNS vs what is named-but-unbuilt)
Each biological term below is load-bearing **only** where it names a contract that exists; terms that name
unbuilt mechanisms are fenced as future work, never presented as canon ([../adr/0013-mycelial-vocabulary-and-phase-discipline.md](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)).

| Layer | Biological analogue | Contract | Status / Phase |
|---|---|---|---|
| **L0 — sensory hyphae** (node-local probing) | a hyphal tip senses its own microenvironment | `internal/reach` Monitor + node_exporter + dataplane-stats → fast-class `spec.TransportHealth`, loopback only | **RUNNING today** (ADR-0019). The entire genuinely-Phase-0 story. |
| **L1 — local digestion** | a compartment emits a bounded, decaying stress signal and forgets the stimulus | reduce raw L0 observations to a redacted, scoped, **floored** (+ noised, once a field exists) medium-class `spec.StressSignal`; forget the raw | **schema inert** now; **running generation/emission is Phase 2** (opt-in telemetry track) |
| **L1.5 — fungi niche** | a fruiting body forms, sheds, dissolves | `spec.NodeRole` cache-custodian niche: a node opts into a temporary, reversible aggregator role over its own scope | niche **enum inert** now; **occupancy/aggregation is Phase 3–4** |
| **L2 — anastomosis** | hyphae fuse and exchange signals locally | scope-bounded gossip + probabilistic-sketch merge (SWIM/phi-accrual, push-sum, count-min/HyperLogLog/t-digest, CRDT) bounded by `TrustScope.MaxHops` | **Phase 3–4; NO schema exists yet** — contract TBD in a gossip ADR |
| **L2.5 — compartment wound response** | a compartment seals an infected zone; false seals self-heal | threshold-signed `spec.SporeEnvelope` (hard-class) on k-of-n corroboration | **signalling Phase 3–4; routing actuation Phase 5** (signalling ≠ actuation) |
| **L3 — fruiting / spore release** | a mushroom releases redacted spores | off-network publisher → static `network-weather.json` (VIS-0005) | **spawned but UNBUILT** (RP-0004); a hard prerequisite before any publish |

## 4. In-region measurement — the priority, not a deferred loss
The vantage problem (§1) has exactly one real solution: **gather signal from the edge — from the clients
and nodes inside the affected network**, because they are the only observers on the path that is actually
being interfered with. This is the OONI-style insight ([0005](0005-network-weather-explorer.md)) applied
to our own fabric.

- **Source of truth = the edge.** A client that imported an operator-provided **Inoculum**
  ([RP-0005](../proposals/0005-inoculum-bundle-and-toolkit.md)) or any standard client can — **strictly
  opt-in** — report which transport *shapes* succeeded or failed from its vantage, as a coarse, identity-
  free, region-bucketed signal (no IP, no precise location, no per-destination detail). A node's own L0
  sensing is a *second* vantage, never a substitute for the edge one.
- **Reduce at the source.** An edge report is floored and coarsened *before it leaves the reporter* (omit
  below `k`, classes not endpoints, buckets not counts), so a single report reveals nothing and a captured
  collector learns only already-redacted aggregates.
- **Aggregate decentrally.** Reports flow into the fungi/digest path (L1→L3), merged within scope bounds,
  never tiled into a map.
- **Phase discipline.** Edge reporting is **opt-in telemetry = Phase 2** (ROADMAP Measurement track); the
  schema/interface is inert now. We record the *intent and shape* now because it is the central deliverable
  the whole model exists to achieve — but no edge reporting runs in Phase 0–2. The hard open problems
  (anti-Sybil edge weighting, region-bucket granularity vs. de-anonymisation, opt-in consent UX in the
  Inoculum) are named here as the priority design threads, not solved.

**Until edge reporting exists, the project is honest that it is NOT sighted on in-region blocking** — only
on operator-side host health and the operator's own-network reachability (§6). Closing that gap is the
point of this Vision.

## 5. Privacy invariants
1. **No cross-operator map** is ever assembled — no fungi, no publisher, no set of fungi holds or publishes
   cross-operator topology, a node list, per-node rows, per-edge weights, location, or identity; fragments
   must not tile back into a map (VIS-0003 §10). *Scoped honestly:* the interim per-operator monitor (§7)
   does hold a single-operator node view — the deliberate, bounded exception for an operator's own boxes.
2. **Obfuscate at the source, not the sink.** The aggregation floor `k` is applied at the source today
   (`StressSignal.Validate`); **noise is aspirational until a `NoisePolicy` field exists** in
   `internal/spec` and is pinned in an ADR (§9) — it does not exist yet.
3. **Aggregate-and-forget is a coercion guarantee only with an enforced bound.** A Phase-3–4 aggregator
   MUST bound the raw-input retention window and zeroise raw inputs immediately after emitting a digest,
   so a fungi seized mid-digest leaks only a bounded window. (The interim per-operator monitor is
   explicitly NOT aggregate-and-forget — it retains durable per-own-node history.)
4. **Omit-not-zero floor `k`** — any cell below `k` distinct samples is omitted entirely, never shown as 0
   or blurred; enforced at source today, and again cross-source at the publisher (the cross-source
   enforcement lives in the publisher's fail-closed gate, which **does not exist yet** and is a hard
   prerequisite before any publish).
5. **Signal-speed non-escalation** — a fast (`TransportHealth`) or medium (`StressSignal`) signal can never
   by itself alter trust or trigger revocation/quarantine; only a threshold-signed hard `SporeEnvelope`
   can. **Signalling ≠ actuation:** no seal actuates routing before its phase (single-node Phase 2,
   network-level Phase 3+, hard quarantine Phase 5).
6. **Scope-bounded propagation** — every digest carries a `TrustScope` with `MaxHops`; bounded fanout + TTL
   prevent any node from seeing all corners (Phase 3–4 behaviour; the field is inert now).
7. **TTL-bounded, signed, replay-safe artifacts** — every digest is a `SporeEnvelope` with issue/expiry
   and a standard-primitive signature ([../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md)).
   *Today `SporeEnvelope.Validate()` checks the presence of a signature, not its verification* — a verifier
   is Phase-3–4 and unbuilt.
8. **Opaque, location-free fields, closed vocabularies.** Scope ids are opaque (no geography/ASN); classes
   not nodes, percentages not counts, order-of-magnitude buckets not exact sizes. `StressSignal.ReasonCode`
   MUST be pinned to a **closed enum** with `Validate()` rejecting non-members (today it is a free string
   checked only for non-emptiness — a leak channel the floor `k` does not cover).
9. **Cumulative cross-snapshot disclosure is an UNSOLVED open problem**, not a structural property. A
   stable opaque scope id is itself a cross-snapshot fingerprint; resolution needs scheduled scope-id
   rotation or a committed privacy budget. Do not claim cumulative-disclosure resistance until one exists.
10. **Opt-in only, no queryable endpoint, import-inert-until-validated.** A node/client contributes only by
    its operator's/user's explicit choice; the publisher exposes a static pre-redacted snapshot, never a
    live API, and tracks no visitors; unverified digests are inert data. Anti-Sybil weighting is **bounded,
    not solved** (per-source caps and the signature verifier are unbuilt).

## 6. Honest reality check (what is real today)
- **Only L0 runs.** Loopback `node_exporter` + `dataplane-stats` + the reachability Monitor on every node.
  Everything above L0 is inert schema or unbuilt code.
- **Of floor + noise + forget, only the floor `k` is structural today** (`StressSignal.Validate` enforces
  `SampleCount ≥ MinAggregate`). Noise has no field; forget, the signature verifier, per-source caps,
  cross-source coarsening, and the fail-closed publish gate are all unbuilt.
- **The interim per-operator monitor is NOT the rejected central master, and is NOT aggregate-and-forget**
  (§7). Conflating the two would either tear out all visibility or, worse, rebuild the cross-operator map.

## 7. The interim (Phase 0–2): sighted at the edge of one's own fleet
With no central master and no running mesh, the operator is sighted at **L0 only**, and that is correct:
- Each node runs `node_exporter` (loopback `:9100`), `dataplane-stats` (loopback `:9550`, reading sing-box
  `clash_api` `:9090` aggregate counters), and — when configured — the reachability Monitor's loopback
  `/reachability`. The host firewall opens no exporter port.
- The operator reaches these from **their own** control host over an SSH tunnel and runs
  Prometheus + Alertmanager + a handshake/TCP blackbox probe **there**, scraping only the nodes that
  operator runs. **This is per-operator private tooling, not a cross-operator coordinator:** it holds no
  other operator's nodes, assembles no cross-operator topology, runs no gossip/DHT. It is *not* the rejected
  master.
- Two honest limits, stated plainly: **(a)** this tier retains durable per-own-node history (forensic
  value, and a subpoena/coercion surface for the operator's own boxes) — it is not aggregate-and-forget;
  **(b)** the blackbox vantage is the operator's own network, so the interim **cannot see in-region
  blocking** — the very thing §1/§4 say matters most — until edge reporting exists.

## 8. Phase path
- **Phase 0–2 (now):** L0 local sensing (deployed) + inert schemas + each operator's own control-host
  monitor over their own fleet. No emission, no gossip, no mesh, no cross-operator map.
- **Phase 2 (Measurement track):** L1 generation/emission as the network-state detector + **opt-in edge
  reporting** (§4) — the priority. Requires first: a `NoisePolicy` field, a closed `ReasonCode` enum, the
  publisher + its fail-closed gate + signature verifier + per-source caps. No off-node gossip yet.
- **Phase 3–4:** L1.5/L2/L2.5-signalling — fungi niche occupancy, mesh-native digest spores over gossip,
  push-sum + sketch merge bounded by `MaxHops`, SWIM/phi-accrual liveness, CRDT `EdgeState` convergence,
  compartment-seal *signalling*. The central publisher dissolves into mesh ingestion; the public contract
  unchanged.
- **Phase 5+:** trust-gradient routing; compartment-seal *actuation* at network level; hard-class
  revocation/quarantine via a future `QuarantinePolicy`; Phase 7 local-rule flow optimization.

## 9. What this spawns
- **ADR-0021** — the bound decision: decentralized aggregate-and-forget observability vs. a central
  collector, with the honest losses (durable forensic history; the in-region blind spot) and the explicit
  per-operator-monitor-is-not-the-master clarification.
- **A stress-digest schema-hardening ADR** (fold into ADR-0017 or new) — add a typed `NoisePolicy`/privacy
  budget to `StressSignal`; pin `ReasonCode` to a closed enum; commit a cumulative-disclosure model. These
  are blocking prerequisites before any digest is emitted.
- **A Phase-3–4 gossip + sketch ADR** — SWIM/push-sum/CMS/HLL/t-digest/CRDT, the bounded-fanout/TTL/MaxHops
  rule, the aggregator's bounded-retention + zeroise-after-digest constraint, and whether sketch bytes are
  an optional `StressSignal` field or a new spore type. This is the home for the "anastomosis" contract,
  which does not exist today.
- **RP-0004** (network-weather publisher + fail-closed gate) — already spawned, unbuilt; a hard
  prerequisite before any publish.
- Edge-reporting design (§4) — the opt-in client reporter, its consent path in the Inoculum (RP-0005), its
  region-bucket granularity, and its anti-Sybil weighting — the priority Phase-2 design thread.

## 10. Non-goals / phase discipline
- **No cross-operator collector, ever** — not in any phase. The per-operator own-fleet monitor (§7) is the
  only collector, and only over one's own boxes.
- **No gossip / DHT / mesh / announce-into-mesh / running aggregation in Phase 0–2** — inert schemas + L0
  only. Those are Phase 3–4.
- **No raw telemetry collected in Phase 0–2.** Edge/digest emission is opt-in Phase-2 behaviour.
- **Biology is load-bearing only where it names a real contract.** "Anastomosis = gossip+sketch", "fruiting
  body = publisher", "quorum-sensing = density-gated emitter" name unbuilt mechanisms and are fenced as
  future work — never canon until their ADR/RP lands.
