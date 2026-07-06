<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Living-Network Doctrine

> **Document type.** Vision & Scope. This is the engineering doctrine that turns
> Mycelium from "a mesh wearing fungal vocabulary" into a *living-network model*:
> a set of named contracts (schemas, state machines, policies, measurable
> behaviours) that make the metaphor load-bearing. It is "why and where", not a
> specification — final field names, parameters, and algorithms are pinned by the
> ADRs this Vision spawns, not here.
>
> **What this is not.** Not a permission slip to run anything new. Phases 0–2
> contribute only *inert typed schemas and interfaces*; no DHT, no gossip, no
> distributed registry, no announce-into-mesh, no global topology, and no
> autonomous cord promotion run as code. Phases 3–4 wire behaviour (see VIS-0003).
> It is also not a rename pass: a mycelial term earns its place only where it
> defines a real contract (§3, the naming discipline).
>
> **See also:** [0001-mycelium-vision-and-scope.md](0001-mycelium-vision-and-scope.md),
> [0002-carrier-agnostic-mycelial-doctrine.md](0002-carrier-agnostic-mycelial-doctrine.md),
> [0003-node-interaction-and-distributed-awareness.md](0003-node-interaction-and-distributed-awareness.md),
> [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md),
> [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md),
> [../GLOSSARY.md](../GLOSSARY.md), [../ROADMAP.md](../ROADMAP.md),
> [../ARCHITECTURE.md](../ARCHITECTURE.md), [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Metadata
- **ID:** VIS-0004
- **Date:** 2026-06-12
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** cross-cutting, Phase 0–8 — inert typed schemas in Phases 0–2 (the inert advisory seam is Phase-2 groundwork that goes live in Phase 3); running behaviour wired in Phases 3–4 and refined in Phases 6–8 (see [../ROADMAP.md](../ROADMAP.md))
- **Layer(s):** cross-cutting (data plane, control plane, routing, discovery)
- **Related:** [0001-mycelium-vision-and-scope.md](0001-mycelium-vision-and-scope.md),
  [0002-carrier-agnostic-mycelial-doctrine.md](0002-carrier-agnostic-mycelial-doctrine.md),
  [0003-node-interaction-and-distributed-awareness.md](0003-node-interaction-and-distributed-awareness.md),
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md),
  [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md),
  the forthcoming network-state-model ADR (ADR-0013+), [../GLOSSARY.md](../GLOSSARY.md),
  [../ARCHITECTURE.md](../ARCHITECTURE.md), [../ROADMAP.md](../ROADMAP.md),
  [../THREAT-MODEL.md](../THREAT-MODEL.md), the internal research baseline (maintainers' knowledge base)

## 1. Problem and context

VIS-0002 gave Mycelium a vocabulary — hyphae explore, anastomoses connect, cords carry, gradients
guide, stress leaves memory, dead paths decay, spores germinate, local signals create global
structure. VIS-0003 gave it a discovery and awareness model. What neither did was *commit the
biology to engineering*: state the rule that a fungal term may name something only when it defines a
real contract, and then translate the living-network behaviours — source/sink flow, pulsatile
probing, pruning, dormant-vs-scarred edges, signal-speed classes, wound response — into concrete
schemas, state machines, and policies that an implementer can build and a test can measure. Without
that step, the metaphor risks becoming decoration: "fungal vocabulary sprinkled over an ordinary
mesh", which buys nothing and hides where the real contracts live.

The adversary reality this addresses (see [../THREAT-MODEL.md](../THREAT-MODEL.md)) is not a single
block but *rotation pressure*: large-scale network degradation and ML traffic classification, IP/AS blocking, UDP
throttling, protocol allowlisting, active probing, sybil enumeration of ingress points, weaponised
revocation, and operator coercion — applied continuously, so that any specific block, port, SNI, or
protocol is burned and replaced on a regular cadence. A network designed around any one transport
dies with that transport. A network designed around *adaptation* treats each transport as
disposable. The living-network model is how Mycelium makes adaptation a first-class, typed,
measurable property rather than an aspiration in a metaphor.

Why now: the `internal/spec` typed-schema layer exists and is the agreed home for inert data models
(VIS-0003 §9). Before those schemas are written we need a doctrine that says *which* mycelial concept
each schema realises, what it must and must not carry, and which phase may run it — so the schemas
are shaped correctly the first time and the metaphor stays honest.

## 2. Vision (desired outcome)

**North star — availability and "immortality" through rotation.** Specific blocks and protocols
rotate regularly, so individual transports are *disposable*. The network must stay available *through*
rotation, by adaptation and self-healing, rather than by defending any one perfect protocol or
crowning any one central authority. **The mesh is the asset, not any one transport.** "Immortality"
here is a precise engineering claim, not romance: the system survives the planned death of its parts.
A transport class being burned should degrade flow class and trigger exploration toward alternatives,
never take the fabric dark.

The desired state is that every living-network behaviour Mycelium claims is backed by a named
contract: a typed schema in `internal/spec`, a state machine over a defined lifecycle, or a policy
object with measurable inputs and outputs. A reader can point at a behaviour ("the mesh grows toward
under-served regions", "a stressed region seals before any global action", "probing speeds up under
uncertainty") and find the exact `internal/spec` type, the rule that drives it, and the metric that
proves it works — or find that it is explicitly inert until a named phase.

The target property for the user is unchanged from VIS-0001 and inherited here: reliable private
connectivity given a channel to the network and at least one reachable, working node — now made
*durable across transport rotation*, because the mesh adapts and self-heals around disposable
transports instead of standing or falling with them.

## 3. Principles governing this initiative

- [x] **Do not reinvent cryptography or transport** — every contract that references a signature does
  so via standard primitives only: a key-id string plus signature bytes per
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md). This Vision defines
  no cipher, KDF, handshake, or scheme; living-network behaviour rides the canonical stack
  (libp2p, Kademlia, GossipSub, AutoNAT, relay/ICE/STUN/TURN; Headscale/Nebula-lighthouse pattern).
- [x] **Indistinguishability over obfuscation** — pulsatile probing is *jittered and adaptive-cadence
  specifically to avoid synchronized bursts and a fingerprintable "probe protocol" signature*;
  exploration and health traffic must resemble legitimate HTTPS/QUIC.
- [x] **Redundancy by default** — source/sink flow, growth-front roles, and storage organs exist to
  keep capability replicated across disposable transports and nodes; pruning is bounded so it
  improves dispersion rather than concentrating the fabric onto few edges.
- [x] **Degradation, not failure** — the entire doctrine is a degradation engine: flow class drops,
  edges decay and dormant before pruning, regions seal rather than the whole mesh reacting, and a
  burned transport triggers exploration rather than outage.
- [x] **User security is function #1** — knowledge-minimisation is the design centre. Every signal is
  aggregated/noised/scoped above a minimum-aggregation floor; no PII; no global topology to any node;
  no economics, tokenomics, global reputation, or bandwidth market; no autonomous cord promotion in
  Phases 0–2. Data never collected cannot be seized or compelled.

## 4. Scope

This Vision (a) states the north star, (b) translates the ten living-network concepts into concrete
architecture, (c) fixes the naming discipline, (d) records the canonical term definitions, and (e)
provides the concept → `internal/spec` type → phase mapping (§5 below; the consolidated table is in
§11-adjacent form at the end of §5). It governs *what the schemas mean and which phase may run them*;
it does not write the schemas (that is the RP) or settle parameters (that is the ADRs).

### Naming discipline (the rule that makes the metaphor load-bearing)

A mycelial term is used **only where it defines a real contract** — a schema, a state machine, a
policy rule, or a measurable behaviour. It is **never** sprinkled over ordinary code. A struct that
is just a struct gets an ordinary name; a struct that *is* the signed TTL-bounded portable artifact
gets the name `SporeEnvelope`, because there the term carries the contract. This mirrors the
no-magic-literals discipline (development.md §1.1): just as cross-service identifiers live once in a
named constant rather than scattered as literals, mycelial terms live once on the type that defines
their contract rather than scattered as flavour. The conformance consequence: a reviewer can ask of
any biological name in the tree "what contract does this define?", and if the answer is "none, it
reads nicely", the name is wrong.

Canonical term definitions (the load-bearing six, plus the spore/cord lifecycle inherited from
VIS-0002/0003):

- **Spore** — a signed, TTL-bounded, portable artifact (the `SporeEnvelope` type). Carries the
  enumerated spore *types* (bootstrap hints, route capsules, trust invitations, revocation notices,
  signed update manifests, stress summaries, cache manifests, delayed messages, emergency
  coordination); never raw traffic, full topology, complete peer lists, user identities, private
  content, or persistent behavioural profiles.
- **Cord** — a promoted path / path-set with *measured usefulness* and *reversible demotion*
  (`CordPromotion`). A cord is never a permanent backbone: it is a measurement-backed promotion that
  can decay back down.
- **Hyphal probe** — a bounded, cheap exploration probe: a budgeted, adaptive-cadence, jittered
  check, never an unbounded crawl.
- **Gradient** — a measured bias affecting exploration / routing (`GradientSignal`); a scalar/field,
  never a command and never a global instruction.
- **Stress memory** — redacted, scoped failure history with retention/decay (`StressSignal` +
  `DecayPolicy`); aggregated above a floor, never raw, never identity-linked.
- **Topology fragment** — a TTL-bounded, scoped *partial* local topology (`TopologyFragment`); never
  a full map, scoped so neighbours' fragments do not tile into wide coverage.

### In scope

- **The north star as a stated, testable property** (§2): availability and immortality through
  rotation, with the burned-transport behaviour (degrade + explore, never go dark) as a Definition-of-
  Done item (§7).
- **The ten living-network concepts, each mapped to a real contract** (§5): for each concept, the
  schema / state machine / policy / measurable behaviour it becomes, the `internal/spec` type(s) it
  touches, and its Phase-0–2 (inert) vs Phase-3–4 (running) status.
- **The naming discipline** (above) as doctrine that the spec work and reviews enforce.
- **The canonical term definitions** (above) as the single reference the GLOSSARY and the spec doc
  comments point to.
- **The concept → spec type → phase mapping table** (§5), which the network-state-model ADR (ADR-0013)
  turns into typed state machines and the RP turns into inert schemas with test-vectors.
- **Inert Phase-0–2 interfaces only**: the future `internal/spec` objects named here — `SporeEnvelope`,
  `StressSignal`, `TopologyFragment`, `TransportHealth`, `GradientSignal`, `EdgeState`,
  `CordPromotion`, `DecayPolicy`, `TrustScope` — are typed and inert now, shaped to accept later
  gossip/DHT backing without breaking, and run nothing.

### Out of scope / explicitly not doing now

- Any end-user client application or bespoke client is **out of scope**. Nodes expose standard
  protocol endpoints consumed by existing off-the-shelf clients; a bespoke client is possible future
  work only.
- **Any economics.** No tokenomics, no bandwidth market, no global reputation, no eigenvector/global
  trust score, no payment, no scarcity-resource primitive (concept 2 below is mutualism *without*
  economics: contribution may raise *local, scoped* priority/trust only).
- **A global membership map, master topology, or permanent centre** — not for any node and not for the
  coordinator (inherited from VIS-0003). The fragment/gradient/stress contracts are explicitly
  partial-and-scoped so they cannot be assembled into a master map by design.
- **Raw telemetry, identity-linked records, or persistent behavioural profiles** in any signal.
- Settling parameters: decay constants, hysteresis bands, probe cadences, aggregation-floor `k`,
  witness-count, replication factors, cord-promotion thresholds — all deferred to the ADRs/research.

### Deferred → future phase/Vision

- **Running source/sink growth bias, pulsatile cadence control, active pruning, dormant/scarred
  re-test logic, signal-speed routing, storage-organ custody, and compartment wound response** →
  Phases 3–4 wire these as behaviour (gradient routing refines in Phase 6; carrier-bridged island
  merge in Phase 7; autonomous cord promotion in Phase 8) — see [../ROADMAP.md](../ROADMAP.md) and
  VIS-0003 §4.
- **Autonomous cord promotion from measured link weights** → Phase 8. In Phases 0–2 `CordPromotion`
  is an inert field/record; no promotion fires.
- The formal **network-state-model ADR** (ADR-0013) and its sibling discovery/registry and
  revocation/incident ADRs (VIS-0003 §12) that turn this doctrine's vocabulary into typed state
  machines and policies.

### Non-goals — phase discipline (what must NOT appear in Phases 0–2)

Per the Scope-discipline fence (MYC-F006, [../ROADMAP.md](../ROADMAP.md)) and VIS-0003 §4, in Phases
0–2 this Vision contributes **inert typed schemas and interfaces only**. The following must **not be
running behaviour**:

- **No running DHT or gossip**, no distributed registry, no announce-into-mesh, no global topology —
  interfaces may be *shaped* for later backing; nothing propagates.
- **No autonomous cord promotion** and **no trust/gradient field driving routing** — `CordPromotion`,
  `GradientSignal`, and any trust field exist as inert data only.
- **No active pruning, no growth bias, no pulsatile cadence control running** — `DecayPolicy`,
  source/sink bias, and probe-cadence logic are typed but dormant.
- **No raw telemetry**; Phase 0–2 telemetry is deferred, opt-in, PII-safe, aggregated, no correlation,
  no identity binding.
- **Phase-transition rule:** do not begin Phase N+1 until Phase N meets its DoD in production with
  real users. This Vision authorises no running behaviour while Phases 0–2 are unmet.

## 5. Target audience and scenarios — the ten concepts as concrete architecture

- **Who:** the implementer writing `internal/spec` schemas and the ADR authors who formalise them ·
  a node operator whose node will later run these behaviours · a reviewer enforcing the naming
  discipline and the phase fence · a community maintaining a mesh segment under rotation pressure.

Each concept below is stated as the **real contract** it becomes — schema / state machine / policy /
measurable behaviour — with the `internal/spec` type(s) it touches and its phase status. None of
this runs in Phases 0–2; the types are inert there.

1. **Source-sink flow.** *Contract:* a **policy** (a growth/replication/exploration bias function)
   keyed off measured demand and spare capacity. Spare-capacity nodes/regions are **sources**;
   degraded/under-served scopes are **sinks**. The policy biases growth-front placement, cache
   replication, and route exploration *toward sinks*. *Schema:* the demand/scarcity/priority field is
   a `GradientSignal`; the spare-vs-degraded reading derives from `TransportHealth` and aggregated
   `StressSignal`; replication targets reference `TrustScope`. *Measurable behaviour:* exploration and
   replication budget measurably skews toward measured-sink scopes; never toward a static "center".
   *Phase:* inert fields in 0–2; the bias *runs* in Phase 3–4 (refined as routing bias in Phase 6).
   *Invariants:* gradients are scoped and aggregated, never a global demand map.

2. **Reciprocal mutualism WITHOUT economics.** *Contract:* a **policy rule** — measured local
   contribution may raise a peer's **local, scoped** priority/trust only. *Schema:* a scoped,
   *strictly-local, never-gossiped* trust/priority field within `TrustScope` (and the local-only
   scoring noted in VIS-0003 §4). *Hard negative space (this is what makes it mutualism not
   markets):* **never** tokenomics, payment, a bandwidth market, global reputation, or
   eigenvector/global trust — those are out of scope (§4) and would let mutually-rating Sybils inflate
   trust from nothing. *Measurable behaviour:* a contributing neighbour gains local scoped priority;
   the same standing is *not* observable or transferable globally. *Phase:* inert field in 0–2;
   local-only effect in 4–5. *Invariants:* scores strictly local, never gossiped.

3. **Pulsatile probing.** *Contract:* a **policy / control loop** — adaptive-cadence health checks
   and exploration, *slower when stable, faster under uncertainty, jittered* to avoid synchronized
   bursts and fingerprints. *Schema:* cadence/jitter parameters live on a probe-policy object; inputs
   are `TransportHealth` (volatility/uncertainty) and `StressSignal`; each probe is a **hyphal probe**
   (bounded, cheap). *Measurable behaviour:* probe interval measurably tracks uncertainty; inter-probe
   timing is jittered (no detectable periodicity) — and this doubles as an indistinguishability
   requirement. *Phase:* cadence/jitter fields typed-inert in 0–2; the loop *runs* in Phase 3–4.
   *Invariants:* every probe is budgeted; no unbounded crawl; jitter is mandatory.

4. **Active pruning.** *Contract:* a **policy** that does more than stale cleanup: it reduces
   over-dense topology, improves convergence, lowers enumeration surface, and increases *useful*
   dispersion. *Schema:* `DecayPolicy` (route-flap-damping-style: exponential decay + hysteresis)
   driving `EdgeState` transitions toward `decayed → pruned`, with a density/dispersion target. *State
   machine:* the prune step of the edge lifecycle (§ canonical lifecycle). *Measurable behaviour:*
   redundant edges are pruned without dropping below a dispersion floor; enumeration surface measurably
   shrinks; honest churn is *not* pruned as hostile (hysteresis). *Phase:* `DecayPolicy` inert in 0–2;
   pruning *runs* in Phase 3–4. *Invariants:* pruning must not concentrate the fabric or crown a
   center; over-suppression caution applies.

5. **Growth-front roles (niches, not classes).** *Contract:* a **state-machine attribute** — a node
   may *temporarily* occupy a niche: frontier probe, stable anchor, cache custodian, bridge carrier,
   relay candidate, or cord endpoint. Roles are reversible niches, not permanent classes. *Schema:* a
   role/niche enum (a `LinkState`-style named string type with a `...Unknown` default and `Validate()`,
   per development.md §1.1) carried on `EdgeState`/node state; cache-custodian and cord-endpoint niches
   cross-reference `CordPromotion` and the storage-organ contract (concept 8). *Measurable behaviour:*
   a node's niche changes with conditions and reverts; no niche is sticky or privileged into a class.
   *Phase:* the enum is typed-inert in 0–2; niche assignment *runs* in Phase 3–4 (cord-endpoint niche
   gated to Phase 8). *Invariants:* niches are temporary and reversible; never a permanent center.

6. **Dormant and scarred edges.** *Contract:* a **state machine** that distinguishes three failure
   semantics: *ordinary decay* (stale, cheaply re-testable) vs *dormant* (re-testable but cooled) vs
   *scarred/dangerous* (needs *stronger evidence* before reuse). *Schema:* `dormant` and `scarred` are
   first-class `EdgeState` lifecycle members alongside `degraded`/`decayed` (not a side qualifier),
   with reuse thresholds set by `DecayPolicy` and the scarred threshold informed by
   corroborated `StressSignal`. *Measurable behaviour:* a scarred edge requires k-of-n /
   stronger-evidence corroboration before re-activation, while a dormant edge re-tests cheaply; the
   two are not conflated. *Phase:* the qualifier is typed-inert in 0–2; the re-test/evidence logic
   *runs* in Phase 3–4. *Invariants:* scarred reuse needs corroborated, scoped evidence, never a single
   signer (ties to VIS-0003's witness floor).

7. **Signal speed classes.** *Contract:* a **classification policy** routing signals by speed/
   confidence to different effects: *fast volatile health* → routing; *medium aggregated stress
   summaries* → exploration bias; *slow corroborated* → trust; *threshold-signed hard signals* →
   revocation/quarantine. *Schema:* a speed-class enum (named string type + `Validate()`) carried on
   `TransportHealth` (fast), `StressSignal`/`GradientSignal` (medium), `TrustScope` (slow), and the
   revocation/quarantine spore types within `SporeEnvelope` (hard, threshold-signed). *Measurable
   behaviour:* a fast health blip moves routing but not trust; only a threshold-signed hard signal can
   revoke; medium signals only bias exploration. *Phase:* speed-class fields typed-inert in 0–2;
   speed-differentiated effects *run* in Phase 3–4 (trust gradient → Phase 6; revocation → the
   incident/revocation ADR). *Invariants:* a fast signal can never escalate itself into a trust or
   revocation effect; only threshold-signed hard signals revoke.

8. **Storage organs.** *Contract:* a **role + policy** — some trusted nodes act as **scoped cache
   custodians** for manifests, revocations, bootstrap spores, stress summaries, and local survival
   artifacts. *Schema:* the cache-custodian niche (concept 5) plus custody quotas and a
   sensitivity→replication-cap policy; custody references `SporeEnvelope` (cache-manifest, revocation,
   bootstrap-hint, stress-summary spore types) and `TrustScope`. *Measurable behaviour:* survival
   artifacts remain reconstructable from custodian caches after node loss (anti-entropy repair), while
   the most sensitive records replicate *least* (cap by sensitivity, per VIS-0003 §6). *Phase:* custody
   fields typed-inert in 0–2; custody *runs* in Phase 3–4. *Invariants:* a custodian never holds full
   topology or peer lists; replication fan-out capped by record sensitivity; no PII.

9. **Compartment wound response.** *Contract:* a **state machine / policy** — a stressed or suspicious
   region becomes a **sealed/healing scope** (a compartment) *before any global action*; raw suspicion
   is **not** leaked globally. *Schema:* a `QuarantinePolicy`-adjacent compartment state over
   `TrustScope`, driven by corroborated `StressSignal`, emitting only redacted, aggregated,
   threshold-gated summaries; quarantine itself rides a threshold-signed, TTL-bounded
   revocation/quarantine spore in `SporeEnvelope`. *Measurable behaviour:* a suspicious region seals
   and self-heals locally; nothing about the suspicion leaves it except a redacted, aggregated,
   threshold-corroborated summary above the floor — a single observer cannot trigger global action.
   *Phase:* compartment/quarantine fields typed-inert in 0–2; sealing *runs* in Phase 3–4
   (threshold-signed quarantine per the revocation/incident ADR). *Invariants:* no raw suspicion
   leaves the compartment; no global action before local sealing; threshold + TTL so false seals
   self-heal.

10. **Symbiosis over replacement.** *Contract:* a **design constraint / policy bias** — strengthen
    existing carriers and communities rather than replace them. *Schema:* this is the carrier-agnostic
    bridging stance (ADR-0011); `TransportHealth` and `CarrierCapability` describe *any* carrier so the
    fabric layers onto existing infrastructure; bias functions (concepts 1, 5) prefer reinforcing a
    healthy existing carrier over standing up a parallel one. *Measurable behaviour:* the fabric adds
    redundancy on top of working carriers and degrades onto them, rather than displacing them; a burned
    transport is replaced, a healthy one is reinforced. *Phase:* carrier descriptors typed-inert in
    0–2; symbiotic bias *runs* in Phase 3–4 (carrier-bridged island merge → Phase 7). *Invariants:*
    transports are disposable but existing carriers are reinforced, not torn out — the mesh is the
    asset.

**Concept → `internal/spec` type(s) → phase mapping.**

| # | Concept | Real contract | `internal/spec` type(s) touched | Phase 0–2 (inert) | Phase 3–4 (running) |
|---|---|---|---|---|---|
| 1 | Source-sink flow | growth/replication/exploration bias **policy** toward sinks | `GradientSignal`, `TransportHealth`, `StressSignal`, `TrustScope` | typed fields, no bias applied | bias runs (routing bias refined Phase 6) |
| 2 | Reciprocal mutualism, no economics | local-only scoped priority/trust **policy rule** | `TrustScope` (strictly-local, never-gossiped field) | inert field | local-only effect; never global/market |
| 3 | Pulsatile probing | adaptive-cadence, jittered probe **control loop** | probe-policy object, `TransportHealth`, `StressSignal` (each probe = hyphal probe) | cadence/jitter params typed | loop runs |
| 4 | Active pruning | density/dispersion **policy** + decay | `DecayPolicy`, `EdgeState` | `DecayPolicy` inert | pruning runs (lifecycle `decayed → pruned`) |
| 5 | Growth-front roles | reversible niche **state-machine attribute** | role/niche enum on `EdgeState`/node state, `CordPromotion` | enum typed-inert | niches assigned (cord endpoint → Phase 8) |
| 6 | Dormant & scarred edges | failure-semantics **state machine** | `EdgeState` (`dormant`/`scarred` lifecycle members), `DecayPolicy`, `StressSignal` | states typed-inert | re-test / stronger-evidence logic runs |
| 7 | Signal speed classes | signal-routing **classification policy** | speed-class enum on `TransportHealth` / `StressSignal` / `GradientSignal` / `TrustScope` / `SporeEnvelope` | speed-class fields typed | speed-differentiated effects (trust → Phase 6) |
| 8 | Storage organs | scoped cache-custodian **role + policy** | cache-custodian niche, `SporeEnvelope`, `TrustScope`, sensitivity→replication cap | custody fields typed | custody + anti-entropy repair run |
| 9 | Compartment wound response | seal-before-global **state machine / policy** | compartment state over `TrustScope`, `StressSignal`, `SporeEnvelope` (quarantine), `QuarantinePolicy`-adjacent | compartment/quarantine fields typed | sealing runs (threshold-signed quarantine) |
| 10 | Symbiosis over replacement | reinforce-not-replace **design constraint / bias** | `TransportHealth`, `CarrierCapability`, bias functions (#1, #5) | carrier descriptors typed | symbiotic bias runs (island merge → Phase 7) |

*Cross-cutting type roles:* `SporeEnvelope` is the carrier of every signed TTL-bounded artifact across
concepts 7–9; `StressSignal` + `DecayPolicy` back stress memory across 4, 6, 9; `GradientSignal` backs
the bias across 1, 7; `TopologyFragment` is the scoped partial-topology substrate (never a map) that
concepts 1, 4, 8 read and write. All remain inert in Phases 0–2.

## 6. Assets and trade-offs

- **Protected assets in focus:** the **network map** (no concept may assemble one — fragments/
  gradients/stress are partial-and-scoped by contract) · ingress reachability · operators (a node
  holding less, and holding only redacted/scoped state, is less worth coercing) · user identity/
  location (never in any signal) · traffic content (never in a spore or signal).
- **Conscious trade-offs:**
  - *Adaptation speed ↔ false-migration / false-quarantine risk.* Faster pulsatile probing and faster
    reaction to stress find blocks sooner but risk acting on a poisoned or transient signal; decay,
    hysteresis, dormant-vs-scarred distinction, witness corroboration, and measure-before-acting slow
    this on purpose.
  - *Dispersion ↔ enumeration surface (pruning).* Active pruning lowers enumeration surface and
    improves convergence, but over-pruning concentrates the fabric and reduces redundancy; the
    dispersion floor and hysteresis bound it.
  - *Availability ↔ seizure surface (storage organs).* Wider custody survives node loss but every
    custodian is a seizure/coercion target; replication fan-out is capped by record sensitivity.
  - *Mutualism ↔ Sybil amplification.* Local scoped priority rewards contribution, but any *global* or
    *gossiped* version becomes a Sybil/trust-inflation channel — hence the hard no-economics,
    scores-strictly-local rule.
  - *Indistinguishability ↔ adaptation cadence.* Faster probing is more adaptive but more
    fingerprintable; jitter and adaptive (not fixed) cadence are the reconciliation.
- **Technical debt accepted knowingly:** the Phase-3 coordinator (VIS-0003) is a deliberate temporary
  centre that some of these behaviours (custody hints, growth-front assignment) lean on before Phase 4
  decentralises them; accepted on the explicit plan to dissolve it, and on the rule that it must never
  become a kill-switch or a master map.

## 7. Definition of Done (measurable, not a slogan)

- [ ] **Immortality through rotation:** we artificially burn the active transport class → nodes
  degrade flow class and trigger exploration toward alternatives, and the fabric stays available
  (does **not** go dark) and recovers without human intervention within a bounded window.
- [ ] **Every claimed concept maps to a real contract:** for each of the ten concepts there exists a
  named `internal/spec` type (or named state-machine/policy object) and a metric — no concept is
  backed only by prose. An auditor can trace concept → type → metric for all ten (§5 table).
- [ ] **Naming discipline holds:** a review of the tree finds **no** mycelial term that does not define
  a contract; every biological name answers "what schema/state-machine/policy/measurable behaviour
  is this?".
- [ ] **Source-sink bias is measurable:** exploration/replication budget skews toward measured-sink
  scopes and never toward a static center.
- [ ] **Pulsatile probing is adaptive and jittered:** probe interval tracks measured uncertainty and
  inter-probe timing shows no detectable periodicity (indistinguishability check).
- [ ] **Pruning improves dispersion, not concentration:** active pruning lowers enumeration surface
  while staying above the dispersion floor, and does not prune honest churn as hostile.
- [ ] **Dormant vs scarred is honoured:** a scarred edge requires stronger (corroborated) evidence
  before reuse; a dormant edge re-tests cheaply; the two are never conflated.
- [ ] **Signal speed classes don't leak across:** a fast health signal moves routing but cannot, by
  itself, alter trust or trigger revocation; only a threshold-signed hard signal revokes.
- [ ] **Wound response seals locally:** a stressed/suspicious region seals and self-heals as a
  compartment, and nothing but a redacted, aggregated, threshold-corroborated summary above the floor
  leaves it — no raw suspicion is leaked globally.
- [ ] **Phase fence holds:** in Phases 0–2 all named types validate as inert (no DHT/gossip, no
  registry, no announce, no global topology, no autonomous cord promotion fires).
- [ ] **Invariants hold under audit:** no PII, no full topology to any node, no economics/tokenomics/
  global reputation, all signals aggregated/noised/scoped above the floor.

## 8. Measurability and observability

Signals that prove the doctrine and feed the adaptation layer, all PII-safe and aggregated above the
minimum-aggregation floor: time-to-recovery after a burned transport class (the immortality metric);
flow-class degradation depth vs availability during rotation; source-sink bias skew (fraction of
exploration/replication budget reaching measured sinks); probe-cadence-vs-uncertainty correlation and
inter-probe timing entropy (indistinguishability); enumeration-surface reduction and dispersion-floor
adherence under pruning; scarred-edge reuse rate gated by corroboration; cross-class signal-leak rate
(must be zero — fast signals never causing trust/revocation effects); compartment self-heal latency and
zero raw-suspicion-leak checks; custody survival rate after node loss vs replication-cap adherence.
Observability uses the standard PII-safe metrics stack (Prometheus/Alertmanager/textfile-gauge); every
signal aggregates, noises, honours the floor, and binds no identity before leaving a node — the
detector must not itself become a correlation tool.

## 9. Dependencies and prerequisites

- **Preceding Vision/ADR:** VIS-0001 and VIS-0002 (spore/island/carrier doctrine) and VIS-0003 (node
  interaction & distributed awareness) — this Vision is the engineering doctrine layered on all three;
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md) binds every signed
  contract to standard primitives; [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md)
  defines the spore envelope and carrier descriptor that concepts 7–10 reference.
- **Contracts this Vision touches:** the `internal/spec` typed schemas (the inert home of every named
  type here — `SporeEnvelope`, `StressSignal`, `TopologyFragment`, `TransportHealth`, `GradientSignal`,
  `EdgeState`, `CordPromotion`, `DecayPolicy`, `TrustScope`), shaped to later accept gossip/DHT
  backing without breaking; the config-distribution endpoint and block-intelligence telemetry (the
  later payload of source-sink and wound-response behaviour, aggregated and identity-free); the
  GLOSSARY (the canonical term definitions here are its mycelial-doctrine reference).
- **External stack/infra:** the canonical Layer-4 stack (libp2p, Kademlia DHT, GossipSub, AutoNAT,
  relay/ICE/STUN/TURN; Headscale/Nebula-lighthouse coordinator pattern) — referenced, not run, in
  Phases 0–2.
- **Cross-cutting tracks that cannot be deferred:** security (witness/threshold floors for scarred
  reuse and wound response), measurement (without metrics, adaptation is blind), legal/opsec
  (aggregation floor, no PII), governance (custody of the threshold trust root, kept jurisdiction-
  diverse without a permanent centre).

## 10. Risks and open questions

- **Strategic risks:** the metaphor decays back into decoration if the naming discipline is not
  enforced in review (the whole Vision then buys nothing); over-eager adaptation (fast probing, fast
  pruning, fast reaction) acting on poisoned/transient signals; a custody or growth-front role
  silently ossifying into a permanent class or center; any signal accreting PII or tiling into a map
  across nodes.
- **Fundamentally hard problems (honest, not "we'll sort it out"):** distinguishing ordinary decay
  from dormant from scarred without either reusing a dangerous edge or permanently scarring an honest
  one; tuning pulsatile cadence to be adaptive yet indistinguishable; bounding pruning so it disperses
  rather than concentrates; keeping mutualism's local-priority reward from becoming a Sybil channel;
  and converging compartment/wound state across partitions without letting a false seal ratchet (the
  same merge-dominance tension VIS-0003 §10 carries).
- **Open questions → research / ADR / RFC:** the exact decay constants and hysteresis bands
  (`DecayPolicy`); probe cadence/jitter calibration (adaptive yet non-fingerprintable); the
  source-sink bias function shape and its scope; the dispersion floor and pruning density target; the
  dormant-vs-scarred thresholds and the corroboration count for scarred reuse; the sensitivity→
  replication-cap policy for storage organs; the minimum-aggregation floor `k` and region-coarsening
  rule shared with VIS-0003; and the cord-promotion thresholds (Phase 8). Parameters are pinned by the
  ADRs/research, not here.

## 11. What becomes possible next

With the living-network doctrine fixed, the `internal/spec` schemas can be written *knowing what each
type means and which phase may run it*, and the network-state-model ADR (ADR-0013) can formalise the
edge lifecycle and the named types as state machines without re-litigating the metaphor. This is the
substrate Phases 3–4 wire into behaviour, Phase 6 refines into trust-gradient routing, Phase 7 uses
for carrier-bridged island merge, and Phase 8 uses for autonomous cord promotion — each built on
something working, not instead of it. The payoff is a mesh whose immortality-through-rotation is a
typed, tested property rather than a slogan.

## 12. Next steps

- [ ] **ADR — distributed network-state model** (`docs/adr/0013-...`): formalise `EdgeState`,
  `CordPromotion`, `DecayPolicy`, `TrustScope`, `GradientSignal`, `StressSignal`, `TopologyFragment`,
  `TransportHealth`, `SporeEnvelope`, the `candidate → probed → active → reinforced → cord → degraded →
  (dormant | scarred) → decayed → pruned` lifecycle (dormant/scarred as first-class members), the
  niche enum, the signal-speed-
  class enum, and the import-inert-until-validated rule — all as typed state machines.
- [ ] **ADR — discovery, registry & gossip** and **ADR — distributed revocation, incident floor &
  trust root** (`docs/adr/0014-...`, `0015-...`, per VIS-0003 §12): the running behaviour for source-
  sink bias, custody, signal-speed effects, and compartment/wound response.
- [ ] **RP — inert Phase 0–2 living-network schemas** (`docs/proposals/NNNN-...`): the non-blocking
  `internal/spec` data models named in §5, with test-vectors, running no distributed behaviour.
- [ ] **GLOSSARY update** (`docs/GLOSSARY.md`): add the mycelial-doctrine section referencing the
  canonical term definitions in §4 (Spore, Cord, Hyphal probe, Gradient, Stress memory, Topology
  fragment) and the edge lifecycle.
- [ ] **research-note** on decay/hysteresis, probe cadence, source-sink bias, dispersion floor,
  dormant/scarred thresholds, and replication-cap calibration (`docs/research/...`).
- [ ] **Trigger an event-driven audit** when the living-network behaviour (Phase 3–4) is connected,
  per [../refactoring.md](../refactoring.md).
