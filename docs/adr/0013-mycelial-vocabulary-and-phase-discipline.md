<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0013: `Mycelial vocabulary discipline and Phase 0-2 inert-schema rule`

> **Document type.** ADR (Architectural Decision Record). Records **two bound
> decisions** that govern how the living-network metaphor enters the codebase and
> how far Phase 0-2 may go in encoding it: (1) when a mycelial term may name
> something, and (2) that early phases ship only inert typed schemas. Saved as
> `docs/adr/0013-mycelial-vocabulary-and-phase-discipline.md`.
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0011-carrier-agnostic-bridging.md](0011-carrier-agnostic-bridging.md),
> [0012-go-primary-control-plane-language.md](0012-go-primary-control-plane-language.md),
> [../vision/0002-carrier-agnostic-mycelial-doctrine.md](../vision/0002-carrier-agnostic-mycelial-doctrine.md),
> [../vision/0003-node-interaction-and-distributed-awareness.md](../vision/0003-node-interaction-and-distributed-awareness.md),
> the forthcoming Vision VIS-0004 (living-network architecture), [../ROADMAP.md](../ROADMAP.md),
> [../development.md](../development.md), [../GLOSSARY.md](../GLOSSARY.md).

---

## Metadata

- **ID:** ADR-0013
- **Date:** 2026-06-12
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** cross-cutting track (governs data plane, control plane, routing/orchestration, discovery/membership)
- **Phase:** cross-cutting; binds Phase 0-2 hard, scopes what Phase 3-4 is allowed to wire
- **Related:** VIS-0002, VIS-0003, VIS-0004 (forthcoming), ADR-0002, ADR-0011, ADR-0012,
  [../ROADMAP.md](../ROADMAP.md) (Scope discipline / finding MYC-F006; Phase-transition principle),
  `internal/spec` types

## Context

The living-network metaphor is load-bearing in this project. VIS-0002 and VIS-0003 establish a
canon vocabulary — hyphae explore, anastomoses connect, cords carry, gradients guide, stress leaves
memory, dead paths decay, spores germinate, local signals create global structure — and that
vocabulary already names real artifacts (the spore in VIS-0002 §3, the edge lifecycle in VIS-0003 §4).
The metaphor is a design asset precisely because each term, used correctly, points at a measurable
behavior or a typed contract.

Two failure modes threaten that asset, and both must be closed before code accretes around them.

- **Decorative biology.** A metaphor degrades into branding the moment biological names are sprayed
  over ordinary code — renaming a buffer a "hypha," a goroutine a "spore," a logger "stress memory."
  Once that happens the words stop carrying meaning, reviewers can no longer tell a real contract from
  a flavored variable, and the canon becomes unfalsifiable. The discipline that protects the metaphor
  is exactly the discipline that forbids magic literals (development.md §1.1): a name must denote one
  source of truth, not a mood.

- **Premature behavior.** The same vocabulary names emergent network behaviors — autonomous cord
  promotion, gradient-driven routing, gossip-backed distributed awareness, DHT rendezvous — that
  VIS-0003 §4 explicitly defers to Phase 3-7 and that the ROADMAP fences behind Scope discipline
  (finding MYC-F006) and the Phase-transition principle. If Phase 0-2 ships *running* mesh behavior
  under those names, the project violates its own phase order, expands the attack surface before the
  threat model covers it, and ships a global topology / distributed registry that no document yet
  authorizes.

- **Adversary model.** The relevant adversary capabilities are sybil enumeration of ingress points and
  network-map reconstruction (THREAT-MODEL). A prematurely live DHT, gossip fabric, or announce-into-mesh
  path hands an enumerator exactly the global view the doctrine forbids; a coordinator role wired live in
  Phase 0 becomes a permanent center to coerce. Inert schemas leak nothing because nothing runs.
- **Affected asset.** Network map · ingress reachability · operators (a live coordinator/center is a
  coercion target) · the integrity of the design canon itself.
- **Fundamental trade-off.** Expressive metaphor and forward-shaped interfaces ↔ the risk that the
  names imply behavior the system must not yet have. This ADR resolves the trade-off by separating
  *naming a contract* from *running the behavior the contract describes*.

## Considered Options

> "Leave as is" (no written rule; rely on review taste) is option 0 and is rejected implicitly by
> recording this ADR.

1. **Free metaphor — biological names anywhere, behavior whenever convenient.** Let any module adopt
   mycelial names and let early phases prototype mesh behavior under them.
   - Pros: fast to write; reads evocatively.
   - Cons: destroys the metaphor as a review tool; produces undefined "bio-terms" that mean nothing;
     invites Phase 3-7 behavior into Phase 0-2 with no threat-model coverage.
   - Impact on indistinguishability / survivability: severe negative — a live, under-specified mesh in
     early phases enlarges the enumerable surface and can crown a de-facto permanent center.

2. **Ban the metaphor in code — keep it in prose only.** Use plain technical names everywhere in code;
   confine biology to vision documents.
   - Pros: zero risk of decorative biology; unambiguous code.
   - Cons: throws away a genuine asset — the canon names *are* the precise contract names (Spore, Cord,
     EdgeState), and divorcing them from the schema forces a translation layer and re-introduces
     drift between doctrine and types.
   - Impact on indistinguishability / survivability: neutral on the wire; negative on maintainability,
     which indirectly harms survivability (drift between canon and implementation).

3. **Bounded metaphor + inert early schemas (chosen).** A mycelial term may be used *only* where it
   names a real contract — a schema, a state machine, a policy rule, or a measurable behavior — and
   Phase 0-2 may encode those contracts only as inert typed schemas and interfaces, with no running
   mesh behavior.
   - Pros: keeps the metaphor as a load-bearing, falsifiable vocabulary; lets `internal/spec` carry
     the canon types now without shipping behavior; aligns one-to-one with development.md §1.1
     (one source of truth per name) and the ROADMAP phase fences.
   - Cons: requires reviewers and a conformance gate to police both the naming rule and the
     inertness rule; some forward-shaped types sit unused until Phase 3-4.
   - Impact on indistinguishability / survivability: positive — nothing observable runs early, the
     network map is never assembled, and the canon stays trustworthy as the system grows.

## Decision

**Option 3.** Two bound, jointly enforced rules become canon.

### Decision 1 — Mycelial vocabulary discipline

A mycelial / living-network term may appear in code or in normative docs **only when it names a real
contract**: a typed **schema**, a **state machine** (or one of its states), a **policy rule**, or a
**measurable behavior**. Ordinary code is **never** renamed with biology — buffers, goroutines,
loggers, caches, retries, and the like keep plain technical names. This is the same one-source-of-truth
rule that forbids magic literals (development.md §1.1): a canon word denotes exactly one contract, not a
flavor. The canonical term definitions, binding for code and docs, are:

- **Spore** — a signed, TTL-bounded portable artifact (see ADR-0011; envelope type `SporeEnvelope`).
- **Cord** — a promoted path / path-set with *measured* usefulness and *reversible* demotion
  (`CordPromotion`; promotion is never autonomous before its phase).
- **Hyphal probe** — a bounded, cheap exploration probe.
- **Gradient** — a measured bias affecting exploration / routing (`GradientSignal`).
- **Stress memory** — redacted, scoped failure history with retention/decay (`StressSignal`, `DecayPolicy`).
- **Topology fragment** — a TTL-bounded, scoped *partial* local topology; **never** a full map
  (`TopologyFragment`).

The edge-lifecycle state names — `candidate -> probed -> active -> reinforced -> cord -> degraded ->
(dormant | scarred) -> decayed -> pruned` (VIS-0003 §4, extended by VIS-0004 §5 concept 6 with
`dormant` and `scarred` as first-class members carrying the failure semantics) — are a state machine
and therefore *are* legitimate canon names (`EdgeState`). The same applies to the typed objects VIS-0003 §10/§12 enumerates (`NodeState`,
`EdgeState`, `RouteState`, `CarrierCapability`, `TransportHealth`, `TrustScope`, `QuarantinePolicy`,
and the rest). A term outside the canon, or a canon term attached to something that is not a contract,
is an **undefined bio-term** and is forbidden.

### Decision 2 — Phase 0-2 is inert typed schemas and interfaces only

Phase 0-2 may define **only inert** data models and interfaces in `internal/spec` (and the equivalent
Rust spec for sealed organs). "Inert" means: pure data and pure validation logic at the Layer-2
boundary — no file I/O, no network, no process execution (consistent with the `package spec`
contract and ADR-0012). Concretely, Phase 0-2 must **not** ship, run, or auto-enable any of:

- a running **DHT** (rendezvous/hint layer) or any DHT read/write path;
- a running **gossip** / anti-entropy transport, or any propagation of state to neighbors;
- a **distributed registry** (membership stays static config / a config-distribution endpoint; the
  operator owns membership; the `coordinator` role exists in models but is **inert/deferred**);
- **announce-into-mesh** or peer-to-peer observation between nodes;
- a **global topology** / master map — only TTL-bounded `TopologyFragment`s may be modeled, and they
  are not exchanged;
- **autonomous cord promotion** — `CordPromotion` is a typed object with no automatic promoter;
  promotion requires measurement and is wired no earlier than its ROADMAP phase.

Behavior is wired in **Phase 3-4** (and later, per VIS-0003 §4: distributed registry over DHT+gossip
→ Phase 4; trust-gradient routing → Phase 5; carrier-bridged island merge → Phase 6; autonomous cord
promotion → Phase 7), under the future Vision VIS-0004 and its follow-on ADRs, and only after the
Phase-transition principle (ROADMAP) is met for the preceding phase in production with real users.

The forthcoming `internal/spec` objects named by the directive — `SporeEnvelope`, `StressSignal`,
`TopologyFragment`, `TransportHealth`, `GradientSignal`, `EdgeState`, `CordPromotion`, `DecayPolicy`,
`TrustScope` — are therefore introduced **typed and inert now**: each carries its schema version
const, doc comments, JSON tags, and a pure `Validate()`, and each references signatures only via a
standard primitive (key id + signature bytes per ADR-0002) — never a custom cipher, KDF, or handshake.
Interfaces may be *shaped* for later gossip/DHT backing, but no such backing runs.

These two rules are bound: the vocabulary discipline keeps the canon honest, and the inert-schema rule
keeps the named behaviors from running before their phase. **Fail-closed posture:** a type whose
backing behavior is not yet authorized must be inert by construction (no live transport, no promoter,
no announcer), so that "not yet wired" cannot silently become "accidentally live."

## Consequences

- **Positive:** the metaphor stays a falsifiable engineering vocabulary, not branding; `internal/spec`
  can carry the full canon type set now, giving Phase 3-4 a stable contract to wire against; the
  GLOSSARY can define every canon term against a concrete contract; phase order and the ROADMAP fences
  are mechanically defensible.
- **Negative / cost:** ongoing review and a conformance gate must police both rules; some forward-shaped
  types sit unused until Phase 3-4; contributors must learn the canon list and the inertness boundary.
- **Impact on user security (requirement №1):** strictly protective. Nothing observable runs in Phase
  0-2: no DHT, no gossip, no announce, no global map. No node and no coordinator assembles a global
  topology, so there is no early map to enumerate or coerce, and no permanent center is crowned.
- **Impact on observability/measurements:** Phase 0-2 telemetry remains deferred, opt-in, PII-safe,
  aggregated, with no correlation or identity binding (VIS-0003 §4). Inert schemas add no live signals;
  the route-score and stress-summary contracts are *typed* now and *measured* later.
- **Follow-on actions required:** add the canon term set and the edge-lifecycle block to
  [../GLOSSARY.md](../GLOSSARY.md); land VIS-0004 as the home for living-network architecture;
  introduce the inert `internal/spec` types (`SporeEnvelope`, `StressSignal`, `TopologyFragment`,
  `TransportHealth`, `GradientSignal`, `EdgeState`, `CordPromotion`, `DecayPolicy`, `TrustScope`)
  with `Validate()` and ADR-0002-compliant signature fields; reference §1.1 from their doc comments.
- **What is now forbidden:** decorative biology on ordinary code; any undefined bio-term; and any
  running DHT, gossip, distributed registry, announce-into-mesh, global topology exchange, or
  autonomous cord promotion in Phase 0-2.

## Compliance

How the two decisions are verified in practice:

- **`spec_inert` conformance test** — asserts the `internal/spec` (and Rust spec) packages import no
  network, file-I/O, or process-execution packages (e.g. flag any import of `net`, `net/http`,
  `os/exec`, file-writing `os`/`io` paths, or a DHT/gossip library) and contain no running goroutine /
  server entrypoint. A canon type that needs live backing fails this gate until its phase. This is the
  machine-checkable form of the Layer-2 `package spec` contract.
- **`no_premature_mesh` CI gate** — blocks merge if Phase 0-2 code references or links a DHT/gossip/
  registry/announce code path, or wires an automatic cord promoter or coordinator activation. Pairs
  with the ROADMAP Scope-discipline fence (finding MYC-F006) and the Phase-transition principle.
- **`mycelial_terms_defined` lint rule** — every mycelial identifier (struct/type/state name, or
  doctrine term in normative docs) must resolve to a canon term in [../GLOSSARY.md](../GLOSSARY.md)
  *and* attach to a schema/state/policy/behavior; an undefined bio-term, or a canon term used on
  ordinary plumbing, fails the lint. This reuses the development.md §1.1 / §7.4
  `no_hardcoded_secrets_endpoints`-style one-source-of-truth machinery.
- **`no_custom_crypto` (ADR-0002)** — signature fields in the new spec types must be key-id string +
  signature `[]byte` referencing a standard primitive only; defining any cipher/KDF/scheme fails.
- **Audit checkpoint** — a merge that introduces a canon type also updates the GLOSSARY entry and, if
  it implies behavior, references VIS-0004 / the relevant phase ADR; reviewers reject canon words that
  name no contract and Phase 0-2 changes that ship behavior.
