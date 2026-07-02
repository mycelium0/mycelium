<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0021: `Decentralized aggregate-and-forget observability, not a central collector`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: Mycelium's
> observability is **decentralized and aggregate-and-forget**, built from the existing redacted, scoped,
> decaying spec contracts — it does **not** stand up a cross-operator central collector (e.g. one
> Prometheus that discovers and scrapes every operator's nodes). The end-to-end architecture, layers, and
> phase path are the subject of [../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md);
> this ADR records the decision and its honest trade-offs.

---

## Metadata
- **ID:** ADR-0021
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** observability / measurement, control plane (cross-cutting)
- **Phase:** cross-cutting Measurement track (the decision binds now; running aggregation is Phase 3 / 4–5)
- **Related:** [../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md) (the doctrine);
  [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md) (no central operated service);
  [0017-network-weather-data-contract.md](0017-network-weather-data-contract.md), [0018-fungi-role-and-opt-in-publish.md](0018-fungi-role-and-opt-in-publish.md),
  [0019-node-local-reachability-health.md](0019-node-local-reachability-health.md) (the deployed L0 monitor);
  [../vision/0005-network-weather-explorer.md](../vision/0005-network-weather-explorer.md) (the public L3 surface);
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (the network map is the adversary's prize; telemetry is itself a surface).

## Context
Phase-0 node-side observability is now deployed (loopback `node_exporter` + `dataplane-stats` + the
reachability monitor). The next question is how those signals become network-wide awareness and alerting.
The obvious move — a central Prometheus that scrapes every operator's nodes — was explicitly rejected by
the maintainer ("no central position"). Two forces pull against it:

- **Adversary model + affected asset.** A cross-operator discovery service + node directory + per-node time
  series is *simultaneously* a routing table and a surveillance dataset — the **network map**, the single
  most valuable prize for the adversary ([../THREAT-MODEL.md](../THREAT-MODEL.md)) — and a single
  seizure/coercion target. It also re-introduces a central operated service, contradicting
  [ADR-0016](0016-software-releases-not-an-operated-network.md).
- **The vantage problem (the deeper reason).** The signal that matters most — *can a user reach a node
  from the network where their access is blocked?* — **cannot be measured from the operator's own clean
  network** ([ADR-0019](0019-node-local-reachability-health.md): external probing measures the monitor's
  reachability, not the node's egress, let alone the user's ingress). Even a perfectly safe central
  collector optimizes the wrong thing; the missing signal is edge-side, in-region, and inherently
  distributed (VIS-0006 §1).

## Considered Options
1. **Cross-operator central Prometheus collector (option 0).**
   - Pros: trivially simple; mature PromQL/Alertmanager tooling; instant strongly-consistent global view;
     exact un-noised metrics; durable queryable history for forensics/trends.
   - Cons: it **is** the network map + a single coercion/seizure target; requires nodes discoverable with
     health off-loopback (an enumeration surface); accretes subpoenable cross-operator raw history;
     contradicts ADR-0016; **and still cannot answer the in-region vantage question.**
   - Impact on survivability: catastrophic on compromise (whole-fabric exposure from one target).
2. **Decentralized, aggregate-and-forget observability (chosen).**
   - Pros: no cross-operator global map exists at any tier by construction (fungi see only their own scope,
     digests don't tile); ephemeral rotating aggregators are not durable coercion targets; resilient to
     single-point seizure; and it is the only model that can gather **edge/in-region** signal without
     building a map; matches the "no central position" requirement.
   - Cons: approximate not exact (sketch error + noise, worse at small cardinalities); convergence latency /
     eventual consistency; gossip overhead on shared transports (needs QoS); **deliberately loses durable
     forensic history**; and the hard problems are only *bounded*, not solved (Sybil poisoning,
     cumulative cross-snapshot disclosure).
   - Impact on survivability: degrades gracefully; no single target yields the fabric.
3. **Per-operator monitor over one's OWN network, dissolving into the mesh later (the pragmatic interim, adopted as Phase-0–2 form of option 2).**
   - Pros: works today with mature tooling; holds no *cross-operator* map; per-operator private.
   - Cons: holds a single-operator node view + durable per-own-node history (not aggregate-and-forget);
     blind to in-region blocking. Acceptable as a bounded, per-operator interim — **not** as the end state.

## Decision
**Option 2**, realized through option 3 as its Phase-0–2 interim. Mycelium's observability is decentralized
and aggregate-and-forget; **no cross-operator central collector is built in any phase.** What becomes canon:

- **Sensing is node-local and loopback (L0), the redaction is at the source (L1), aggregation is scoped and
  ephemeral (fungi, L1.5/L2), and the only wider view is the off-network publisher of already-redacted
  aggregates (L3)** — the layers and phase gating are pinned in VIS-0006.
- **The only collector permitted is a per-operator monitor over that operator's OWN network** (loopback
  exporters reached over the operator's own SSH tunnels). It is explicitly **not** the rejected
  cross-operator coordinator, and it is explicitly **not** aggregate-and-forget — it retains durable
  per-own-node history. This is a deliberate, bounded exception for an operator's own boxes.
- **Privacy is structural only where the code makes it so.** Today that is the aggregation floor `k`
  (`spec.StressSignal.Validate` enforces `SampleCount ≥ MinAggregate`). **Noise, forget, the signature
  verifier, per-source anti-Sybil caps, and the cross-source fail-closed publish gate do not exist yet**
  and must be built before they are claimed (VIS-0006 §9). Custom cryptography is prohibited
  ([ADR-0002](0002-no-custom-cryptography.md)).
- **Fail-closed:** no digest is ever published until the publisher's fail-closed conformance gate (the
  cross-source enforcer of omit-not-zero + the no-leak strip) exists and passes.

## Consequences
- **Positive:** no cross-operator map at any tier; no single coercion target; alignment with ADR-0016 and
  the threat model; the architecture can reach the edge/in-region signal a central collector never could.
- **Negative / cost (named honestly, not soft-pedalled):**
  - **Durable forensic history is deliberately lost** in the mesh model ("what did region X look like three
    weeks ago"). For a connectivity-resilience project this is a genuine operational loss, mitigated only by
    the per-operator interim monitor's own-network history.
  - **Approximation** (sketch + noise) makes small-scale figures (resilience index, network size) imprecise;
    needs a stated accuracy floor / larger buckets.
  - **Sybil poisoning is bounded, not solved**, and cumulative cross-snapshot disclosure is unsolved
    (VIS-0006 §5.9); both need future ADR/RP work, not a claim of resistance now.
- **Impact on user security (requirement №1):** strongly positive — no cross-operator map, no durable
  cross-operator raw store, edge reports floored/coarsened at source; the residual risks (in-memory raw
  during aggregation, the per-operator monitor's own history) are named and bounded.
- **Impact on observability/measurements:** the **in-region blind spot is the priority gap** to close, not
  an accepted loss — the model's central deliverable is opt-in **edge reporting** (VIS-0006 §4), Phase-3
  Measurement-track work. Until it lands, the project is honest that it sees only operator-side host health
  and the operator's own-network reachability.
- **Follow-on actions required:** ADR-0021 spawns the schema-hardening ADR (NoisePolicy + closed ReasonCode
  enum + cumulative-disclosure model), the Phase-4–5 gossip+sketch ADR, and depends on RP-0004 (publisher +
  fail-closed gate); it reconciles ADR-0018 §3 / VIS-0005 to place the opt-in digest path at **Phase 3**,
  not "Phase 0 onward".
- **What is now forbidden:** building a cross-operator scrape coordinator / node directory / discovery
  service in any phase; exposing node health off loopback; claiming noise/forget/verifier/anti-Sybil-caps
  exist before they are built; publishing any digest before the fail-closed gate exists.

## Compliance
- No tracked config or deploy path stands up a cross-operator collector or exposes an exporter port on a
  public interface (exporters stay loopback; the host firewall opens no exporter port — verifiable on a node
  and in the bootstrap/observability surface).
- The opt-in digest/edge-reporting path is documented as **Phase 3**, not Phase 0 (ADR-0018 / VIS-0005
  reconciled).
- Before any digest is published: a `NoisePolicy` field + a closed `ReasonCode` enum exist in
  `internal/spec` with `Validate()` enforcement, and the publisher's fail-closed gate exists and passes
  (the leak **invariant**, enforced by the conformance suite — the concrete gate lives in
  `tests/conformance/` + [../development.md](../development.md), named there, not here).
- Code/doc review rejects any claim that noise, forget, the signature verifier, or anti-Sybil caps are in
  effect before they are implemented.
