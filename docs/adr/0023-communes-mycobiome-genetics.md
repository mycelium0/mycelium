<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0023: `Mycelium is a Mycobiome of sovereign Communes with their own genetics`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: Mycelium is
> not a single network but a **Mycobiome** — an ecosystem of sovereign **Communes**, each a
> first-class society entity with its own **genetics** (trust roots, accepted signers, governance,
> bridge/immunity/transport/observability policies, trust-propagation rules), **compatible by
> protocol, not by authority**. The **Commune** is the *society* entity and is **explicitly distinct
> from the architectural layer-planes** (data plane / control plane / routing & orchestration /
> discovery & membership) — it does **not** rename them. Saved as
> `docs/adr/0023-communes-mycobiome-genetics.md`.
>
> **See also:** [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md),
> [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0011-carrier-agnostic-bridging.md](0011-carrier-agnostic-bridging.md),
> [0018-fungi-role-and-opt-in-publish.md](0018-fungi-role-and-opt-in-publish.md),
> [0021-decentralized-observability-not-a-central-collector.md](0021-decentralized-observability-not-a-central-collector.md),
> [../vision/0003-node-interaction-and-distributed-awareness.md](../vision/0003-node-interaction-and-distributed-awareness.md),
> [../ARCHITECTURE.md](../ARCHITECTURE.md), [../GLOSSARY.md](../GLOSSARY.md),
> [../GOVERNANCE.md](../../GOVERNANCE.md), [../THREAT-MODEL.md](../THREAT-MODEL.md),
> `internal/spec` (`TrustScope`, `SporeEnvelope`, `DiscoveryBackend`, `NodeRole`).

---

## Metadata
- **ID:** ADR-0023
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** cross-cutting track (a society/governance model that spans all four layer-planes — data
  plane, control plane, routing & orchestration, discovery & membership — without modifying any of them)
- **Phase:** cross-cutting. The **entity model** binds now and may be encoded only as **inert typed
  schema hooks** in Phase 0-2 (per [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md));
  **live Communes, genetic exchange, cross-Commune trust, and the Mycobiome fabric are Phase 4-5**
  (gossip/DHT/membership = Phase 3-4; trust-gradient = Phase 5). The closed-by-default node posture
  this entity model formalises is **already true today** (per-operator credentials, no shared key
  material, no open relay/egress — [ADR-0014](0014-per-operator-node-credentials.md)).
- **Related:** the **Operator Doctrine** (Immunity, Communes, Sovereign Defense — the canonical source
  this ADR binds); [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md) (vocabulary + inert
  Phase 0-2 schemas); [ADR-0016](0016-software-releases-not-an-operated-network.md) (software, not an
  operated network; consensus governance; no single owner); [ADR-0014](0014-per-operator-node-credentials.md)
  (per-operator credentials, no shared network key material); [ADR-0011](0011-carrier-agnostic-bridging.md)
  (carrier-agnostic bridging); [ADR-0018](0018-fungi-role-and-opt-in-publish.md) (fungi niche; opt-in
  publish); [ADR-0021](0021-decentralized-observability-not-a-central-collector.md) (no central
  collector); [VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md) (distributed
  awareness; `TrustScope`, spore, knowledge gradient). **Spawns** the sibling ADRs of this doctrine
  cluster: **ADR-0024** (Anastomosis Bridges — explicit, contract-bound inter-Commune connection),
  **ADR-0025** (Immunity + immune signals + temporary scoped cuts), **ADR-0026** (no global abuse
  oracle; safe defaults; traffic capability classes).

## Context

The Operator Doctrine makes a structural claim that prior canon had only implied: **Mycelium is not
one network with one membership.** It is a *Mycobiome* — an ecosystem of independent societies that
share a protocol but not an authority. This ADR records that claim as the foundational entity model on
which the rest of the doctrine cluster (immunity, bridges, defense) is built. The remaining doctrine
pieces are deliberately split into sibling ADRs so each binds **one** decision; this one binds the
*entity model* only.

**The naming hazard this ADR must resolve.** The doctrine says *"the term Plane is replaced; use
Mycelium Commune."* In **this** repository the word **plane never named a society** — it names the
architectural **layers** (Layer 1 data plane, Layer 2 control plane, Layer 3 routing & orchestration,
Layer 4 discovery & membership — [ARCHITECTURE.md](../ARCHITECTURE.md)). Those layer-planes are *not*
being renamed and must not be. The **Commune** is therefore introduced as a **new, first-class
sovereign-society entity**, **orthogonal** to the layer-planes: a Commune is a *who* (a society and its
governance), a layer-plane is a *where* (an architectural tier of the software). A Commune is realised
*across all four* layer-planes; it is not one of them. This ADR exists in part to make that distinction
canon so neither term erodes the other.

**Why an ecosystem rather than a network — the architectural force.** A single global membership with a
single root of authority is exactly the structure the project has refused at every layer: it is a
single coercion/seizure target, it manufactures a global kill switch, and it re-introduces the central
brain [ADR-0014](0014-per-operator-node-credentials.md) /
[ADR-0016](0016-software-releases-not-an-operated-network.md) already reject. The Mycobiome model
removes the thing an adversary most wants — a single authority that can name, admit, expel, or map
everyone.

- **Adversary model.** Operator coercion; sybil enumeration of membership; network-map reconstruction;
  config-distribution blocking; the *governance-capture* adversary that seeks a single authority to
  compel or to weaponise as a global ban/kill switch ([THREAT-MODEL.md](../THREAT-MODEL.md)).
- **Affected asset.** The **network map** and **membership** above all (a single global membership *is*
  the map and the directory); operators; the project's legal/coercion posture.
- **Fundamental trade-off.** Openness ↔ sybil-resistance / coordination cost: many sovereign societies
  compatible only by protocol give up the simplicity, instant-global-consistency, and single-policy
  enforcement of one authority — in exchange for the absence of any single target, owner, or kill
  switch. The doctrine takes that trade deliberately.

**Standing on existing canon.** The pieces a Commune is built from already exist as inert contracts:
[VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md)'s **`TrustScope`** (scoped,
bounded trust), the signed **`SporeEnvelope`** (TTL-bounded, signer-attributed artifact — signature is
a standard primitive per [ADR-0002](0002-no-custom-cryptography.md), never custom crypto), the inert
**`DiscoveryBackend`** interface (Phase 3-4 membership, deferred), and **`NodeRole`** niches. A
Commune's *genetics* is, concretely, a **named, signed bundle of those scopes, signer sets, and
policies** — not a new cryptographic system. Per
[ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md), any schema introduced for it in Phase 0-2
must be **inert** (pure data + `Validate()`, no live gossip/DHT/membership/promotion).

## Considered Options

1. **One global Mycelium network with one membership + one root of authority (option 0 — status-quo
   misreading).**
   - Pros: trivially simple to reason about; one policy; instant global consistency; one place to admit
     or expel a node.
   - Cons: it **is** the global membership/directory the architecture exists to deny; a single
     coercion/seizure target; a built-in **global kill switch**; re-introduces the central owner that
     [ADR-0016](0016-software-releases-not-an-operated-network.md) /
     [ADR-0014](0014-per-operator-node-credentials.md) reject; one captured authority captures everyone.
   - Impact on survivability: catastrophic on capture — the whole fabric falls with one target.

2. **Mycelium as a Mycobiome of sovereign Communes, compatible by protocol not authority (chosen).**
   - Pros: no global membership, owner, or authority exists by construction; each society is its own
     trust/governance domain; capture of one Commune does not capture another; aligns with
     per-operator credentials, consensus governance, and scoped trust already in canon; an ecosystem
     can specialise and evolve without coordination.
   - Cons: more concepts (Commune vs layer-plane vs operator vs node); no single global policy to
     enforce; interoperability must be carried entirely by the **protocol/Core**, so the Core's
     compatibility contract becomes load-bearing; cross-Commune connection needs explicit machinery
     (the spawned Anastomosis-Bridge ADR), not a free assumption.
   - Impact on survivability: degrades gracefully — no single target yields the ecosystem.

3. **Rename the architectural layer-planes to "Communes" (literal reading of "Plane is replaced").**
   - Pros: matches the doctrine sentence verbatim.
   - Cons: **wrong for this codebase** — "plane" here names software layers, not societies; renaming
     them would corrupt [ARCHITECTURE.md](../ARCHITECTURE.md), every ADR `Layer(s)` field, and the
     template's layer-boundary language, while *failing* to introduce the actual new entity the
     doctrine needs. A category error.
   - Impact: pure harm; rejected outright.

## Decision

**Option 2.** Mycelium is a **Mycobiome** — an ecosystem of compatible **Communes** — and a Commune is
a **first-class sovereign-society entity, explicitly distinct from the architectural layer-planes**.
What becomes **canon**:

1. **Commune — the sovereign society entity.** A **Commune** is a sovereign Mycelium society:
   examples are a family, company, university, municipal body, NGO, emergency-response group, or a
   state Commune. A Commune is a **new, first-class entity**. It is **not** an architectural layer and
   does **not** rename the layer-planes; the layer-planes (data / control / routing & orchestration /
   discovery & membership) keep their names and meanings unchanged. A Commune is realised *across* all
   four layer-planes. **Global Mycelium does not own Communes.**

2. **Commune genetics.** Every Commune possesses a **genetic profile** — its sovereign policy bundle:
   **trust roots; accepted signers; governance rules; bridge policies; immunity policies; transport
   policies; observability policies; trust-propagation rules.** Two Communes may run **identical
   software** while having **completely different genetics**. Genetics is a *named, signed bundle of
   existing primitives* (`TrustScope` sets, signer-key-id sets per
   [ADR-0014](0014-per-operator-node-credentials.md), policy records) carried in signed
   `SporeEnvelope`-class artifacts — **not new cryptography** ([ADR-0002](0002-no-custom-cryptography.md)).

3. **Compatible by protocol, not by authority.** Communes interoperate because they speak the same
   **Core protocol**, never because any authority admits them. **The Core provides compatibility;
   Communes provide life.** There is **no membership roster, no admission authority, and no owner** of
   the Mycobiome. Communes may **cooperate, coexist, remain isolated, specialise, or evolve
   independently without losing interoperability.**

4. **The Mycobiome is an ecosystem, not a network.** The collection of all protocol-compatible
   Communes is the **Mycobiome** — not a single network. No global authority owns it; it has no center,
   no roster, and no kill switch.

5. **Sovereignty implies non-obligation (the entity-level consequence; the mechanics are spawned).**
   Membership in the Mycobiome obligates a Commune to **nothing**: no Commune is required to trust any
   other, to relay all traffic, or to remain connected. *Connection between Communes is never implicit*
   — it exists only through an explicit contract (the **Anastomosis Bridge**, spawned to **ADR-0024**).
   *Self-defense, immune signals, and temporary scoped cuts* (spawned to **ADR-0025**) and *the absence
   of any global abuse oracle, plus safe defaults and traffic capability classes* (spawned to
   **ADR-0026**) are the machinery of that sovereignty; this ADR binds only the entity model they rest
   on.

6. **Phase + inertness.** The **entity model binds now.** Any Phase 0-2 expression of it is **inert
   typed schema hooks only** (e.g. a `Commune`/`Genetics` record with `Validate()` referencing existing
   inert types) — **no** live Commune membership, **no** genetic exchange, **no** cross-Commune trust,
   **no** Mycobiome fabric runs before its phase ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)).
   **Live Communes and genetics are Phase 4-5** (membership/gossip/DHT = Phase 3-4; trust-gradient =
   Phase 5). The **closed-by-default node posture** the model formalises — per-operator credentials, no
   shared key material, no open relay/egress, no bridge without explicit trust — is **already current**
   ([ADR-0014](0014-per-operator-node-credentials.md)).

**Canonical Rule (preserved verbatim in intent).** *Mycelium is not a universal bypass substrate.
Mycelium is a Mycobiome composed of sovereign Communes. The Core provides compatibility; Communes
provide life. Communes may cooperate, isolate, defend themselves, and evolve different genetics. No
global authority owns the Mycobiome.* This rule is now canon and may not be watered down.

## Consequences

- **Positive:** no global membership, directory, owner, or authority exists by construction — the
  adversary's single most valuable prize (the global map + a coercible authority) is removed at the
  entity level; capture of one Commune does not yield another; the model is the natural completion of
  per-operator credentials ([ADR-0014](0014-per-operator-node-credentials.md)) and
  software-not-an-operated-network ([ADR-0016](0016-software-releases-not-an-operated-network.md));
  sovereignty (non-obligation to relay/trust/stay connected) is now a *named property*, not an
  accident; the Commune ↔ layer-plane distinction is fixed in canon so neither term erodes the other.
- **Negative / cost:** more concepts to teach (Commune vs layer-plane vs operator vs node vs fungi);
  **no single global policy** can be enforced — coordination and any cross-Commune action cost more and
  require explicit contracts; the **Core's compatibility contract becomes load-bearing** (a protocol
  break fragments the Mycobiome with no authority to reconcile it); a real risk of **terminology drift**
  if "Commune" and "plane" are ever conflated — guarded by the Compliance check below.
- **Impact on user security (requirement №1):** strongly positive — removing a global authority/roster
  removes a central coercion target and a global kill switch; trust stays **scoped** (`TrustScope`,
  VIS-0003), so a node/Commune never has to expose itself to the whole ecosystem to participate; no new
  logging, correlation, or identity binding is introduced (genetics carries policy, **never** raw
  traffic, identities, locations, or a full map).
- **Impact on observability/measurements:** none added or lost here — observability stays
  decentralized and aggregate-and-forget ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md));
  the *observability policy* simply becomes an explicit gene of a Commune rather than a global setting.
  Cross-Commune signal exchange (immune signals) is deferred to **ADR-0025** and rides existing
  redacted spore contracts, never a global feed.
- **Follow-on actions required:** spawn **ADR-0024** (Anastomosis Bridges), **ADR-0025** (Immunity,
  immune signals, temporary scoped cuts), **ADR-0026** (no global abuse oracle; safe defaults; traffic
  capability classes); add **Commune / Genetics / Mycobiome** to [GLOSSARY.md](../GLOSSARY.md) under a
  Mycelial-doctrine section, each cross-referencing the layer-plane entry to mark the distinction;
  define the **inert** `Commune`/`Genetics` schema hook in `internal/spec` when its track is scheduled
  (per [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md), inert until Phase 4-5).
- **What is now forbidden:** (a) any **global authority, roster, owner, or membership service** for the
  Mycobiome, in any phase; (b) treating Mycobiome membership as an **obligation** to trust, relay, or
  stay connected; (c) **renaming or repurposing** the architectural layer-planes (data / control /
  routing & orchestration / discovery & membership) as "Communes," or otherwise conflating the society
  entity with a layer; (d) standing up **live** Communes, genetic exchange, or cross-Commune trust
  before their phase, or expressing them as anything but **inert** schema in Phase 0-2; (e) implying any
  authority "admits" Communes — compatibility is by **protocol only.**

## Compliance

How to verify the decision is respected in practice:
- **`commune_not_a_layer_plane` doc-conformance check** — fails the build if a document uses "Commune"
  as a synonym for, or a rename of, an architectural layer-plane (data/control/routing/discovery), or
  refers to "the four Communes/planes" interchangeably; the layer-plane names must remain reserved for
  the architecture layers.
- **`no_global_authority` conformance check** — rejects tree language asserting a global Mycelium
  owner, network-wide membership roster, admission authority, or network-wide ban/kill switch (extends
  the existing [ADR-0016](0016-software-releases-not-an-operated-network.md) "operates/owns a network"
  separation check).
- **`spec_inert` / `no_premature_mesh` gates** ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md))
  — any `Commune`/`Genetics` type added to `internal/spec` must be inert (pure data + `Validate()`, no
  live gossip/DHT/membership/promotion) until its Phase 4-5 track is authorized.
- **`no_custom_crypto`** ([ADR-0002](0002-no-custom-cryptography.md)) — genetics signing/verification
  must use standard audited primitives (opaque `signer_key_id` + raw `signature` bytes), never a
  bespoke scheme.
- **`check_ppn_wording`** — the Commune/Mycobiome vocabulary stays neutral PPN language (no loaded
  access framing; no country names).
