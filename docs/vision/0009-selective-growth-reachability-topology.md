<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Selective Growth & Reachability Topology (grow only into impaired paths; carry out-of-region egress node-to-node, never user-direct)

> **Document type.** Vision & Scope — "why and where", not a specification. The split-tunnel route-set
> shape, the domain-aware vs CIDR-only engine split, the two-hop corridor contract, and the
> reachability-topology invariants are pinned by the ADRs and inert schemas this Vision references and
> spawns (§13), not here. This document is **canonical doctrine** for the *shape* the fabric grows into:
> it does not water down a single principle below, and it preserves the Canonical Rule verbatim.
>
> **The one reframe that governs everything: the mycelium does not grow where it is not needed.** Every
> prior Vision asked how Mycelium *reaches* — block-resistant transports, carrier-agnostic bridging,
> self-healing reroute. This Vision adds the discipline those reaches must obey: **a tunnel that carries
> traffic whose native path is already fine is not resilience — it is needless attack surface, needless
> correlation surface, and needless cost.** A living mycelium extends a hypha toward a nutrient it cannot
> otherwise reach and **declines to grow** where reach is already direct. The same discipline answers the
> hardest empirical fact about an impaired path: out-of-region direct reach is not merely "slower" — it is
> *structurally* degraded as a class, and the only topology that survives carries out-of-region egress
> **node-to-node**, never user-direct. We name this principle **Selective Growth**, and the shape it
> dictates **Reachability Topology**.

## Metadata
- **ID:** VIS-0009
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** cross-cutting **Routing & reachability** track. Today (Phase 0–2): a **manual,
  operator-built two-hop corridor** and **per-client split-tunnel route sets** are a **current-posture
  deployment pattern** — an operator can configure them by hand now. **Automated** route selection,
  automated split-tunnel classification, and automated cross-node corridor selection are **Phase 3–5**
  (they require the gossip/measurement/membership machinery that does not run before then). Inert typed
  schemas (the corridor/route-set descriptors) are definable now under phase discipline.
- **Layer(s):** routing plane (split-tunnel decision, region-scoped route sets), data plane (the
  two-hop corridor carriage), discovery/membership (corridor establishment in later phases);
  cross-cutting reachability track.
- **Related:** [0001-mycelium-vision-and-scope.md](0001-mycelium-vision-and-scope.md) (the core property
  — reliable private connectivity given a channel and one working node),
  [0002-carrier-agnostic-mycelial-doctrine.md](0002-carrier-agnostic-mycelial-doctrine.md) (the carrier
  doctrine the corridor's hops ride), [0006-decentralized-observability.md](0006-decentralized-observability.md)
  §1 (the **vantage problem** — in-region reachability cannot be measured from the operator's clean
  network; the reason a Selective-Growth decision must be made from in-region signal, not operator-side),
  [0008-immunity-communes-mycobiome.md](0008-immunity-communes-mycobiome.md) §9 (Anastomosis Bridges —
  the cross-node fusion primitive an out-of-region egress hop is an instance of) and §15 (the Canonical
  Rule this Vision preserves);
  [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md) (a hop is a
  carrier characterized by capability + risk + flow class),
  [../adr/0013-mycelial-vocabulary-and-phase-discipline.md](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)
  (phase discipline; inert schemas in Phases 0–2),
  [../adr/0016-software-releases-not-an-operated-network.md](../adr/0016-software-releases-not-an-operated-network.md)
  ("not a universal bypass substrate"; software, not an operated network),
  [../adr/0019-node-local-reachability-health.md](../adr/0019-node-local-reachability-health.md) (the L0
  reachability/health sensing that *informs* but does not *actuate* a split-tunnel decision in Phase 0–2),
  [../adr/0021-decentralized-observability-not-a-central-collector.md](../adr/0021-decentralized-observability-not-a-central-collector.md)
  (no central collector; the vantage problem stated as a decision),
  [../adr/0026-anastomosis-bridges-and-safe-defaults.md](../adr/0026-anastomosis-bridges-and-safe-defaults.md)
  (the bridge contract grammar, capability classes, and closed-by-default posture an out-of-region egress
  hop must satisfy — egress is a high-risk capability class, never a default primitive);
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (destination-AS/subnet throughput degradation; the third-party
  TLS-termination disclosure surface), [../refactoring.md](../refactoring.md) §15.x (the named merge-gate
  categories this Vision extends), [../GLOSSARY.md](../GLOSSARY.md), [../ROADMAP.md](../ROADMAP.md).

## 1. Problem and context — reach is not uniform, and "more tunnel" is not more safety

Two facts, both load-bearing, shape this Vision.

**(a) Carrying traffic that did not need carrying is a cost, not a courtesy.** The naive posture — "tunnel
everything, always" — treats the tunnel as free. It is not. Every destination forced through the tunnel
that was natively reachable adds: a correlation surface (one path now sees flows it had no reason to see),
a single-point-of-block surface (a reachable destination becomes unreachable the moment the tunnel is
impaired), latency and cost, and — most sharply — it makes the node look like exactly the
indiscriminate, carry-anything relay the Canonical Rule forbids
([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)). The mycelium that grows
everywhere is not robust; it is a larger, more attackable, more legible organism.

**(b) Out-of-region direct reach is structurally degraded — as a class, not a flap.** The harder fact,
empirically corroborated by the project's own **two-vantage test** (a probe from inside a high-interference
network vs. a probe from a transit-clean neighbouring region): an out-of-region destination, reached
**directly** across the high-interference border, suffers a **destination-AS / subnet,
download-direction throughput filter** — the path completes a handshake and a small head of data, then the
download direction is throttled to a freeze (on the order of a few tens of kilobytes, then stall). This is
**not** a per-destination block and **not** transport-distinguishability; it hits **out-of-region hosters
and CDNs as a class**, keyed on the destination network, in the download direction. Three consequences
follow directly, and each is a design constraint:

- **Fronting via an out-of-region CDN does not help.** If the throttle is keyed on the *destination
  network class* (out-of-region hoster/CDN ranges), then routing through *another* out-of-region CDN lands
  in the same class — the front shares the fate of what it fronts. The border filter does not care which
  out-of-region network it is; it cares that the path *crosses the border to an out-of-region network*.
- **A TLS-terminating CDN is also a disclosure surface.** A path that terminates TLS at a third party
  hands that party the user's source address *and* the destination hostnames — a deanonymization and
  logging surface that is worse precisely where the third party can be compelled to retain it
  ([../THREAT-MODEL.md](../THREAT-MODEL.md): "Assets"; `USER_DEANON`). The mitigation for (b) must not
  itself create a `USER_DEANON` channel.
- **The path that survives is the path that never traverses the border filter.** The only reach that is
  not download-throttled is one whose *user-facing leg never crosses the high-interference border to an
  out-of-region network*. That means: **in-region ingress** (the user reaches an in-region node by a
  native, transit-clean in-region path), with the **out-of-region egress carried node-to-node** — an
  in-region node hands off to an out-of-region node over a node-to-node hop — **never user-direct to an
  out-of-region node.** The border filter sees only an in-region-to-in-region flow on the leg it can
  reach; the out-of-region leg is on the far side of the in-region node, where the filter does not sit.

This is *why* Selective Growth and Reachability Topology are one Vision: (a) says **grow only where reach
is impaired**; (b) says **where you must grow out-of-region, grow node-to-node, never user-direct.** The
first keeps the organism small; the second keeps the one part that must be large on the only path that
survives.

## 2. Vision (desired outcome)

When this initiative is complete, a Mycelium deployment carries **only** the traffic whose native path is
impaired, and routes the rest **direct** (split-tunnel by default); and where the impaired path is an
out-of-region destination behind a high-interference border, the out-of-region egress travels
**node-to-node** (an anastomosis hop), with the user's only leg being an **in-region**, native-reachable
one. The property for the user is unchanged and *strengthened*: reliable private connectivity for impaired
destinations, **without** sacrificing the native-reachable ones to a single tunnel's fate, **without**
handing a third party their source address and destination hostnames, and **without** the node becoming an
indiscriminate carry-anything relay. The mycelium grows toward the nutrient it cannot otherwise reach, and
declines to grow where reach is already direct.

## 3. Principles governing this initiative (compatibility with the core)

- [x] **Do not reinvent cryptography or transport.** A two-hop corridor is composed from existing
  transports and existing carrier hops ([ADR-0011](../adr/0011-carrier-agnostic-bridging.md)); the
  node-to-node egress hop is an instance of the Anastomosis primitive
  ([VIS-0008](0008-immunity-communes-mycobiome.md) §9; [ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md)),
  not a new mechanism. Signers use standard primitives ([ADR-0002](../adr/0002-no-custom-cryptography.md)).
- [x] **Indistinguishability over obfuscation.** The user-facing leg is an ordinary in-region flow to an
  in-region node; Selective Growth keeps off the tunnel everything that would make the node look like a
  carry-anything relay.
- [x] **Degradation, not failure.** A native-reachable destination kept off the tunnel does not go dark if
  the tunnel is impaired; split-tunnel is itself a degradation-containment posture.
- [x] **User security is function №1.** Selective Growth *reduces* correlation surface (less traffic on the
  tunnel that did not need to be), and Reachability Topology *forbids* the third-party TLS-termination
  disclosure surface (no user-direct out-of-region termination at a compellable party).
- [x] **Phase discipline ([ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)).** A
  **manual** operator two-hop corridor and **manual** per-client split-tunnel route sets are
  current-posture; **automated** route/corridor/split-tunnel decision-making is Phase 3–5; the descriptor
  schemas are inert hooks definable now (§13).
- [x] **Not a universal bypass substrate ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).**
  Selective Growth is the operational expression of the Canonical Rule: the fabric grows into an impaired
  path *selectively*, it does not become a free, indiscriminate, anyone-to-anywhere transport.
- [x] **Transport universality — the set is universal, the route adapts.** Mycelium implements the **full**
  transport/protocol diversity, *including* transports that are impaired on some networks. A transport is
  never privileged, nor removed from the set, because one environment degrades it: it stays first-class
  wherever its native path is unimpaired — an out-of-region, CDN-fronted transport that a high-interference
  border throttles (§1(b)) is still a healthy primary transport on a network that does not. What adapts to
  the environment is the **route and topology** (this Vision's subject), **not the transport set**. This is
  the reach-everywhere reading of the core: the fabric is built to make resilient, useful connections
  anywhere they are wanted, and is not posed against any one environment — narrowing the set to one
  environment's conditions would be both a loss of global reach and a misframing of what the fabric is for.

## 4. Selective Growth — the principle

> **Selective Growth: the mycelium does not grow where it is not needed.** The tunnel carries **only**
> traffic whose native path is impaired. Destinations that are natively reachable route **direct**
> (split-tunnel by default). Growth is toward an impaired path, never around a reach that already works.

This is doctrine, not optimization. Its three obligations:

- **Split-tunnel is the default, not an opt-in.** The default disposition of a flow is **direct**; a flow
  is placed on the tunnel only because its native path is *known* to be impaired. "Tunnel everything" is
  the rejected default — it is needless attack/correlation surface and it makes the node look like a
  carry-anything relay.
- **Impairment is the entry condition for growth.** A destination earns a place on the tunnel by evidence
  that its native path is impaired (degraded handshake, RST injection, IP/AS block, the download-direction
  throughput throttle of §1(b)). Absent that evidence, it routes direct.
- **The decision is made from the impaired vantage, not the clean one.** *Whether* a native path is
  impaired is the **vantage problem** ([VIS-0006](0006-decentralized-observability.md) §1;
  [ADR-0021](../adr/0021-decentralized-observability-not-a-central-collector.md)): it cannot be answered
  from the operator's clean network — only from in-region signal. So a Selective-Growth classification is
  ultimately an **edge/in-region** decision, which is exactly why the *automated* form is Phase 3–5 (it
  needs the in-region signal the measurement track is building), while the *manual* form is current
  posture (the operator encodes a known-impaired set by hand).

**Engine note — the instrument matters.** Domain-aware split is the *precise* instrument: the
**xray-class transports' geo-routing** can route by domain/destination, so it can put exactly the impaired
destinations on the tunnel and leave the rest direct. **CIDR-only transports** — the **WireGuard-class /
AmneziaWG** path — cannot split by domain; they can only **approximate** Selective Growth via
**region-exclude route sets** (an `AllowedIPs` that excludes native-reachable in-region ranges so they
route direct, while out-of-region ranges go to the tunnel). The CIDR-only approximation is honest and
useful but coarse; the domain-aware path is the instrument when precision matters. This is a *capability of
the chosen engine*, not a defect to paper over — record which engine a deployment uses and which
granularity of Selective Growth it can therefore achieve.

## 5. Reachability Topology — in-region ingress, out-of-region egress node-to-node

The shape Selective Growth grows into, when the impaired path is an out-of-region destination behind a
high-interference border, is fixed by §1(b):

- **In-region ingress is load-bearing.** The user's only leg is to an **in-region** node, reached by a
  native, transit-clean **in-region path**. This leg never crosses the high-interference border, so it is
  not subject to the destination-AS download-throttle; it looks like an ordinary in-region flow.
- **Out-of-region direct reach is structurally degraded.** A user-direct path to an out-of-region node (or
  an out-of-region CDN front) crosses the border filter and inherits the destination-AS,
  download-direction throughput throttle **as a class** — fronting via another out-of-region network does
  not escape the class (§1(b)). Therefore **user-direct out-of-region reach is not a topology this fabric
  relies on.**
- **Out-of-region egress travels node-to-node — an anastomosis hop — never user-direct.** Where the
  destination is out-of-region, an **in-region node** hands the flow off to an **out-of-region node** over
  a **node-to-node** hop; the out-of-region node performs the egress. This hop **is** an Anastomosis
  ([VIS-0008](0008-immunity-communes-mycobiome.md) §9): "two exploring paths fuse where useful," lifted to
  carry an out-of-region egress on the far side of the border filter. The filter, sitting on the
  in-region leg, sees only an in-region-to-in-region flow.
- **No third-party TLS termination on the user's behalf.** The out-of-region egress is performed by a node
  the deployment trusts under an explicit contract — **not** by terminating the user's TLS at a compellable
  third party that would learn the user's source address and destination hostnames (§1(b);
  `USER_DEANON`). The node-to-node hop carries the flow without offering it to a third party to terminate.

**The invariant, stated once:** *the user's leg is in-region and native-reachable; the out-of-region leg,
if any, is carried node-to-node behind an in-region node; out-of-region reach is never user-direct, and is
never terminated for the user at a compellable third party.*

## 6. Ties to the existing doctrine (this Vision contradicts none of it)

- **Anastomosis Bridges ([VIS-0008](0008-immunity-communes-mycobiome.md) §9 /
  [ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md)).** The node-to-node out-of-region
  egress hop (§5) is an Anastomosis hop, and it carries the **egress** capability class — a **high-risk**
  class that is **never a default primitive** and requires stronger trust and stronger immunity policy
  ([ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md) Decision 3). In later phases, a
  cross-Commune egress hop is an Anastomosis **Bridge** and needs the full explicit contract (allowed /
  forbidden classes, abuse-propagation, quarantine, revocation, recovery, evidence). Reachability Topology
  therefore inherits the closed-by-default posture wholesale: the corridor is **opened by explicit
  policy**, never implied by reachability, never a default-on relay.
- **The vantage problem ([VIS-0006](0006-decentralized-observability.md) §1 /
  [ADR-0021](../adr/0021-decentralized-observability-not-a-central-collector.md)).** Selective Growth's
  entry condition — "is this native path impaired?" — is the vantage problem restated as a *routing*
  decision. The operator's clean network cannot answer it; only in-region signal can. This is the direct
  reason the **automated** classifier is Phase 3–5 (it consumes in-region measurement the project is still
  building) and the **manual** known-impaired set is current posture. L0 reachability/health sensing
  ([ADR-0019](../adr/0019-node-local-reachability-health.md)) *informs* the operator but does **not**
  actuate a split-tunnel decision in Phase 0–2.
- **"Not a universal bypass substrate" ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).**
  Selective Growth is the operational form of the Canonical Rule. A fabric that tunnels everything for
  everyone *is* the universal bypass substrate; one that grows into an impaired path selectively, carries
  out-of-region egress only node-to-node under explicit policy, and routes native-reachable traffic
  direct, is the sovereign, consented shape the Rule requires. *Mycelium must grow through anything;
  Mycelium must NOT attack through everything* — and **must not grow where it is not needed.**

## 7. Scope

### In scope
- The **Selective Growth** principle (split-tunnel by default; impaired-path entry condition;
  in-region-vantage decision) as canonical doctrine.
- The **Reachability Topology** invariant (in-region ingress load-bearing; out-of-region direct reach
  structurally degraded; out-of-region egress node-to-node, never user-direct, never third-party-terminated).
- The **engine-granularity** distinction (domain-aware split = precise; CIDR-only = region-exclude
  approximation) as a recorded property of a deployment.
- A **current-posture** deployment pattern: a **manual** operator-built two-hop corridor + **manual**
  per-client split-tunnel route sets.
- **Inert** descriptor schemas for the corridor and the route set (§13).

### Out of scope / explicitly not doing now
- Any end-user client application is **out of scope** (consumption interface unchanged: standard clients
  connect to standard endpoints).
- **Automated** route selection, **automated** split-tunnel classification, and **automated**
  cross-node/cross-Commune corridor selection — **Phase 3–5** (they need the gossip/measurement/membership
  machinery that does not run before then).
- Any **default-on** corridor, any **default** out-of-region egress, or treating out-of-region egress as a
  primitive — forbidden by [ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md) regardless of
  phase.
- Any path that **terminates the user's TLS at a third party** to "front" an out-of-region destination.

### Deferred → future phase/Vision
- The automated Selective-Growth classifier consuming in-region edge signal (Phase 3–5, depends on
  [VIS-0006](0006-decentralized-observability.md) edge reporting).
- The cross-Commune egress-corridor **Bridge contract** specialization (Phase 4–5, under
  [ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md)).

## 8. Measurability and observability
The decision rests on **two-vantage** signal: a probe from inside a high-interference network vs. a probe
from a transit-clean neighbouring region. The corroborating signature of the structural degradation is a
**destination-AS / subnet, download-direction throughput throttle** (handshake + a small head of data,
then a download-direction stall), reproducible **per destination-network-class**, not per individual
destination — which is what distinguishes it from a flap or a single-destination block. Success of
Selective Growth is measurable as: the **share of carried traffic whose native path was actually
impaired** (ideally → all of it; needlessly-tunnelled native-reachable traffic is the defect), and the
**survival of the out-of-region leg** when it is carried node-to-node vs. user-direct. All of this rides
the **redacted, aggregate-and-forget** observability contract
([ADR-0021](../adr/0021-decentralized-observability-not-a-central-collector.md)) — no central collector,
no map, in-region signal floored at source.

## 9. Risks and open questions
- **The throttle's keying may shift.** If the destination-AS/subnet download-throttle is re-keyed (e.g. to
  flow-shape rather than destination class), the "fronting does not help" conclusion and the
  node-to-node-egress remedy must be re-derived from fresh two-vantage signal — this is an empirical claim
  with a shelf life, not a permanent law.
- **The vantage problem bounds automation.** Until in-region edge reporting lands
  ([VIS-0006](0006-decentralized-observability.md)), the automated classifier cannot be honest; the manual
  known-impaired set is the only correct current form. Claiming an automated Selective-Growth decision
  before the signal exists is a defect (`SILENT_DEGRADATION` /
  [ADR-0021](../adr/0021-decentralized-observability-not-a-central-collector.md) "claiming what isn't
  built").
- **CIDR-only coarseness.** Region-exclude route sets over-tunnel and under-tunnel at the edges of a region
  block; the residual is named, not waved away — domain-aware split is the precise instrument where it is
  available.
- **Out-of-region egress is high-risk by class.** A node-to-node egress hop carries the egress capability
  class; the Sybil/abuse hazards of cross-node and cross-Commune egress are **bounded** by
  [ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md)'s contract grammar (Phase 4–5), not
  solved here.

## 10. Phase path & what this spawns

**Phase discipline ([ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)).**

- **Phase 0–2 (now):** a **manual** operator-built two-hop corridor (in-region node → out-of-region node,
  the second hop carried node-to-node) and **manual** per-client split-tunnel route sets are a
  **current-posture deployment pattern** — an operator configures them by hand. The CIDR-only engine
  approximates Selective Growth via region-exclude `AllowedIPs`; the domain-aware engine achieves it
  precisely. L0 reachability sensing ([ADR-0019](../adr/0019-node-local-reachability-health.md))
  **informs** but does not **actuate**. The corridor/route-set descriptor schemas are **inert hooks**
  (data + `Validate()` only).
- **Phase 3–4:** **automated** Selective-Growth classification consuming scoped in-region signal;
  automated split-tunnel decisions; node-to-node egress corridor establishment over scoped gossip.
- **Phase 5:** cross-Commune egress corridor as an Anastomosis **Bridge** with a full contract
  ([ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md)); trust-graded selection of which peer
  performs the out-of-region egress.

**ADR this Vision spawns (next free number — ADR-0027):**
- **ADR-0027 — Selective Growth & the Reachability Topology invariant.** Pins (a) split-tunnel-by-default
  with the impaired-path entry condition; (b) the Reachability Topology invariant (in-region ingress
  load-bearing; out-of-region egress node-to-node, never user-direct, never third-party-TLS-terminated);
  (c) the engine-granularity split (domain-aware precise vs. CIDR-only region-exclude approximation); (d)
  the phase split (manual current-posture vs. automated Phase 3–5); and the honest trade-offs.

**Inert schemas (`internal/spec`, data + `Validate()` only — [ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)):**
a `ReachabilityCorridor` descriptor (ordered hops; each hop a carrier capability + risk +
[ADR-0011](../adr/0011-carrier-agnostic-bridging.md) flow class; the egress hop carries the **egress**
capability class and references a `TrustScope` + a `CapabilityPolicy` per
[ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md)); a `SplitRouteSet` descriptor (the
domain-aware include/exclude set *or* the CIDR region-exclude set, with an explicit `engine_granularity`
field = `domain_aware` | `cidr_only`). Each MUST `Validate()`-reject: a corridor whose egress hop has no
`TrustScope`/`CapabilityPolicy`; a topology with a **user-direct out-of-region egress**; any field carrying
raw traffic, user identity, location, or a full topology map.

**Named finding category ([refactoring.md](../refactoring.md) §15.x) this spawns** — so audits name the
new failure modes consistently, matching the existing `OPEN_RELAY_OR_DEFAULT_EGRESS` /
`BRIDGE_WITHOUT_CONTRACT` / `GLOBAL_KILL_SWITCH` style:

- `REACHABILITY_TOPOLOGY_VIOLATION` (**S1**; **S0** if it creates a deanonymization channel) — a
  deployment that (i) routes a **user-direct out-of-region egress** across the high-interference border
  (instead of carrying it node-to-node behind an in-region node), or (ii) **terminates the user's TLS at a
  third party** to front an out-of-region destination (a `USER_DEANON` surface — then also S0). The
  reachability-shape sibling of `OPEN_RELAY_OR_DEFAULT_EGRESS`.
- `NEEDLESS_GROWTH` (**S2**) — the tunnel carries traffic whose native path is **not** impaired
  ("tunnel-everything" default), inflating correlation/attack surface and making the node look like a
  carry-anything relay. Selective Growth requires split-tunnel-by-default; a default that tunnels
  native-reachable traffic violates it. (S2 = a doctrine/posture drift, not a direct user-safety breach;
  escalates only if combined with a topology violation above.)

## 11. The Canonical Rule (preserved, not watered down)

> **Mycelium is not a universal bypass substrate. The mycelium does not grow where it is not needed: the
> tunnel carries only traffic whose native path is impaired, and native-reachable destinations route
> direct. Where the impaired path is out-of-region, the user's leg is in-region and native-reachable, and
> the out-of-region egress is carried node-to-node — an anastomosis hop, never user-direct, and never
> terminated for the user at a compellable third party. Mycelium must grow through anything; Mycelium must
> NOT attack through everything; and Mycelium must NOT grow where it is not needed.**

