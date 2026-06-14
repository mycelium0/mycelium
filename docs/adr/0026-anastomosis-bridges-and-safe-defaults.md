<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0026: `Anastomosis Bridges, traffic capability classes, and the closed-by-default safe defaults`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: Communes
> connect **only** through explicit **Anastomosis Bridges** — there is **NEVER** a bridge unless one is
> explicitly established — and a bridge is a **full contract** (trust relationships; allowed traffic
> classes; forbidden traffic classes; abuse-propagation rules; quarantine rules; revocation rules;
> recovery rules; evidence requirements); that traffic is distinguished by **capability class** (local
> control · emergency coordination · messaging · signed-content replication · software updates ·
> real-time media · relay · egress · unknown bulk), where **higher risk requires stronger trust and
> stronger immunity policy and anonymous egress is NOT a default primitive**; and that the default node
> posture is **closed** (no open relay; no public egress by default; no unknown third-party transit; no
> bridge without an explicit policy; no topology sharing; rate limits for untrusted scopes; quarantine
> suspicious behaviour; local/community traffic preferred over external transit). Saved as
> `docs/adr/0026-anastomosis-bridges-and-safe-defaults.md`.
>
> **Scope note.** This ADR pins the **bridge contract grammar, the capability-class taxonomy, and the
> safe-defaults posture**. The end-to-end immunity doctrine — Communes, Mycobiome, genetics, immune
> signals, temporary scoped cuts, sovereign defence, no global abuse oracle — is the subject of its
> companion Vision [../vision/0008-immunity-communes-mycobiome.md](../vision/0008-immunity-communes-mycobiome.md);
> this ADR records the inter-Commune connection contract and the closed-by-default posture, and their
> honest trade-offs. The sovereign entity **Commune** (introduced by [ADR-0023](0023-communes-mycobiome-genetics.md))
> is **not** an architectural layer: it is explicitly distinct from the data / control / routing /
> discovery **planes** (the architectural layers, which are **not** renamed). Where this ADR says
> "Commune" it means the sovereign society; where it says "plane" it means the architectural layer.
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0011-carrier-agnostic-bridging.md](0011-carrier-agnostic-bridging.md),
> [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md),
> [0018-fungi-role-and-opt-in-publish.md](0018-fungi-role-and-opt-in-publish.md),
> [0021-decentralized-observability-not-a-central-collector.md](0021-decentralized-observability-not-a-central-collector.md),
> [0023-communes-mycobiome-genetics.md](0023-communes-mycobiome-genetics.md),
> [0024-immunity-temporary-cuts-and-signals.md](0024-immunity-temporary-cuts-and-signals.md),
> [0025-no-global-abuse-oracle.md](0025-no-global-abuse-oracle.md),
> [../vision/0003-node-interaction-and-distributed-awareness.md](../vision/0003-node-interaction-and-distributed-awareness.md),
> [../vision/0004-living-network-doctrine.md](../vision/0004-living-network-doctrine.md),
> [../vision/0008-immunity-communes-mycobiome.md](../vision/0008-immunity-communes-mycobiome.md),
> [../THREAT-MODEL.md](../THREAT-MODEL.md), [../GLOSSARY.md](../GLOSSARY.md), `internal/spec`.

---

## Metadata

- **ID:** ADR-0026
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** proposed
- **Layer(s):** discovery/membership (bridge establishment + trust scope), control plane (contract
  policy, capability gating, abuse-propagation/quarantine/revocation rules), data plane (capability-class
  enforcement, rate limits, relay/egress posture); cross-cutting immune track
- **Phase:** cross-cutting. The **closed-by-default safe-defaults posture** is **already-true / near-term
  Phase-0 node behaviour** — it follows directly from per-operator credentials, no open relay, and no
  public egress ([ADR-0014](0014-per-operator-node-credentials.md)), not from any cross-Commune
  machinery. The **Anastomosis-Bridge contract schema** and the **`TrafficCapabilityClass` taxonomy**
  are **inert-typed now** (Phase 0-2 data + `Validate()` only, per
  [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)). **Live** bridge establishment /
  revocation and cross-Commune capability-class negotiation are **Phase 3-4** (gossip/DHT/membership);
  **trust-gradient grading of higher-risk capability classes is Phase 5.**
- **Related:** the companion immunity/Communes Vision
  ([VIS-0008](../vision/0008-immunity-communes-mycobiome.md) §9 Anastomosis Bridges, §12 Traffic
  Capability Classes & Safe Defaults — the doctrine this ADR binds);
  [ADR-0011](0011-carrier-agnostic-bridging.md) (the *carrier* bridge characterized by a capability +
  risk descriptor and a flow-class policy — an Anastomosis Bridge is its cross-Commune generalization,
  lifting "capability + risk" to a *full contract* between two sovereign genetics);
  [ADR-0014](0014-per-operator-node-credentials.md) (per-operator signer key material; the closed,
  self-sufficient node that owes no traffic to anyone); [ADR-0023](0023-communes-mycobiome-genetics.md)
  (Communes as first-class sovereign entities with their own genetics — the entities a bridge connects;
  *connection between Communes is never implicit*); [ADR-0024](0024-immunity-temporary-cuts-and-signals.md)
  (immune signals + temporary scoped cuts — the signals a bridge's abuse-propagation / quarantine /
  revocation clauses carry); [ADR-0025](0025-no-global-abuse-oracle.md) (no global abuse oracle —
  **bridge contracts determine which signals are binding**; this ADR supplies the contract that
  decision rests on); [ADR-0016](0016-software-releases-not-an-operated-network.md) (software, not an
  operated network — no authority establishes bridges on a Commune's behalf);
  [ADR-0002](0002-no-custom-cryptography.md) (bridge contract signatures use standard audited
  primitives); [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md) (inert Phase-0-2 schemas);
  VIS-0004 (the flow-class **quality** ladder this ADR composes with as a **risk/consent** taxonomy);
  `internal/spec` (`TrustScope`, `SporeEnvelope`, `SignerKeyID`, `DiscoveryBackend`, the carrier
  `CarrierCapability`/`CarrierRisk` descriptors of ADR-0011);
  [../refactoring.md](../refactoring.md) §7 (`FORBIDDEN_TOPOLOGY_CENTRALIZATION`,
  `TELEMETRY_SAFETY_VIOLATION`).

## Context

[ADR-0023](0023-communes-mycobiome-genetics.md) makes Mycelium a **Mycobiome** — an ecosystem of
sovereign **Communes**, compatible by protocol and not by authority — and makes one consequence explicit:
**membership obligates a Commune to nothing.** No Commune is required to trust another, to relay all
traffic, or to remain connected. That leaves an unanswered structural question: when two Communes *do*
want to interoperate, **how** is that connection expressed, and **what** may flow across it? This ADR
answers both, and pins the closed posture a node holds **before** any such connection exists.

Three forces shape the answer, and all three point the same way.

- **Adversary model — the fabric as an attack substrate, and the bridge as the propagation path.** The
  immunity doctrine ([VIS-0008](../vision/0008-immunity-communes-mycobiome.md);
  [ADR-0024](0024-immunity-temporary-cuts-and-signals.md)) names the abuse Mycelium must be able to
  refuse: DDoS traffic, scanning, credential attacks, malware command/control, hostile relay use, abuse
  transit, infrastructure attacks, and — the case unique to a *Mycobiome* — **one Commune using another
  Commune as an attack platform.** A connection between Communes is precisely the channel that abuse
  would travel; an *implicit* or *default-on* connection would make every Commune a free relay and egress
  point for every other, i.e. the universal bypass substrate the Canonical Rule forbids. The inverse abuse
  also applies: a bridge whose revocation, quarantine, or abuse-propagation rules are vague becomes a lever
  one Commune can pull against another. The contract must pin both the **forbidden** classes and the
  **revocation/quarantine/recovery** path, not only the allowed classes.
- **Affected asset.** Ingress reachability and **the absence of an open relay/egress** (a default-on
  bridge or a default egress primitive *is* the open relay the THREAT-MODEL denies) · the network map
  (a bridge must not require or produce a global topology to be established) · each Commune's sovereign
  right to refuse traffic, refuse trust, and refuse connection · operators (a bridge a node was never
  asked to consent to is a coercion and liability surface). The bridge contract and the safe defaults
  exist to keep all of these closed unless a Commune **explicitly** opens them.
- **Fundamental trade-off (reach ↔ safety, stated honestly).** A closed-by-default posture and
  per-bridge explicit contracts forfeit *frictionless universal reachability*: two Communes cannot just
  "find each other and route" — someone must establish a contract first, anonymous egress is not handed
  out for free, and a strict default will sometimes refuse a connection a user wanted. That cost is real.
  Its inverse is also real: any fabric that connects everyone by default, relays for everyone by default,
  and egresses for everyone by default is an attack amplifier and a single shared liability. The doctrine
  resolves this in favour of **sovereign, consented connection**: *Mycelium must grow through anything;
  Mycelium must not attack through everything.*

This ADR composes from contracts that already exist. [ADR-0011](0011-carrier-agnostic-bridging.md)
already characterizes a **carrier** bridge by a `CarrierCapability` + `CarrierRisk` descriptor and a
**flow-class** degradation ladder (the *quality* a carrier can safely support), and already requires a
carrier to declare its **supported flow classes** and to carry abuse-propagation / quarantine /
revocation considerations. An Anastomosis Bridge is the **cross-Commune generalization** of that idea:
where a carrier bridge says "this *link* can safely move this quality of flow," an Anastomosis Bridge
says "these two sovereign *genetics* agree this *capability* of traffic may cross, under these trust,
abuse-propagation, quarantine, revocation, recovery, and evidence terms." The flow-class ladder grades
**quality**; the capability classes grade **risk and consent**; the two compose — a carrier offers a
flow class, a Commune's genetics ([ADR-0023](0023-communes-mycobiome-genetics.md)) decide which
*capability* classes may ride it, for whom, across which bridge.

## Considered Options

> "Leave it implicit — Communes that can reach each other simply interoperate, and any node relays/egresses
> by default" is **option 0** and is rejected by recording this ADR: an implicit/default-on connection is
> the open relay and the universal bypass substrate the doctrine and THREAT-MODEL forbid.

1. **Implicit interoperation + open relay/egress by default (option 0).** Any two protocol-compatible
   Communes interoperate on contact; any node relays and egresses for any peer unless it opts out.
   - Pros: maximal reachability with zero setup; the simplest mental model ("everyone can reach
     everyone"); no contract grammar to design.
   - Cons: it **is** the open relay and universal bypass substrate the Canonical Rule and THREAT-MODEL
     deny; it makes every Commune a free attack platform for every other (the doctrine's named abuse:
     "one Commune using another as an attack platform"); anonymous egress becomes a default primitive;
     it forfeits each Commune's sovereign right to refuse; abuse and liability propagate with no contract
     to bound them.
   - Impact on survivability: catastrophic — a single abuser degrades shared relay/egress for everyone,
     and there is no scoped, revocable boundary to clot the infection at.

2. **A single global bridging policy / registry the reference build honors.** One published "who-may-bridge
   / who-may-relay" policy or registry every node consults.
   - Pros: globally consistent connection rules; one place to reason about reachability.
   - Cons: it re-introduces a global authority over connection — a coercion/seizure target and a de-facto
     global kill switch over who may reach whom — contradicting [ADR-0016](0016-software-releases-not-an-operated-network.md),
     [ADR-0021](0021-decentralized-observability-not-a-central-collector.md), and
     [ADR-0025](0025-no-global-abuse-oracle.md); a default-honored global policy "advisory unless
     overridden" collapses to binding for the majority who never override.
   - Impact on survivability: catastrophic on capture — compel the registry and you control who may
     connect across the whole Mycobiome.

3. **Explicit per-bridge contracts + capability-class gating + closed-by-default node posture (chosen).**
   No connection between Communes exists unless an **Anastomosis Bridge** is explicitly established by both
   genetics; the bridge is a **full contract** (trust, allowed/forbidden capability classes,
   abuse-propagation, quarantine, revocation, recovery, evidence); traffic is graded by **capability
   class** with higher risk gated behind stronger trust + immunity policy and **anonymous egress never a
   default**; and the **default node posture is closed** (no open relay, no public egress, no unknown
   transit, no bridge without policy, no topology sharing, rate-limit untrusted, quarantine suspicious,
   local preferred over external transit).
   - Pros: connection is sovereign and consented, never implicit; abuse has a **scoped, revocable,
     recoverable** boundary to clot at (the bridge contract is where [ADR-0024](0024-immunity-temporary-cuts-and-signals.md)
     cuts and [ADR-0025](0025-no-global-abuse-oracle.md) binding-signal decisions land); no global
     authority over connection exists; reuses the [ADR-0011](0011-carrier-agnostic-bridging.md)
     capability/risk + flow-class machinery and standard-primitive signers
     ([ADR-0002](0002-no-custom-cryptography.md)/[ADR-0014](0014-per-operator-node-credentials.md)); the
     closed posture is **already true** in Phase 0.
   - Cons: more setup friction — interoperation requires an explicit contract, not contact; a strict
     default will sometimes refuse a connection a user wanted; the contract grammar and the
     capability-class taxonomy are new schema surface that must be kept inert until phase
     ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)); cross-Commune capability negotiation
     (Phase 4-5) re-opens the trust-bootstrapping and Sybil-bridge hazards, which must be **bounded** by
     genetics/evidence/quorum, not assumed away.
   - Impact on survivability: strongly positive — connection is scoped and revocable; abuse is contained
     at the bridge; no single target controls who may reach whom; a node defends itself by default.

## Decision

**Option 3.** Anastomosis Bridges, traffic capability classes, and the closed-by-default safe defaults
become **canon**. The Core provides the **compatibility** (the bridge contract grammar and the capability
taxonomy); each Commune provides the **life** (its genetics decide which bridges to establish and which
capability classes to allow). No authority establishes a bridge, grades a capability, or opens a relay on
a Commune's behalf.

### Decision 1 — Anastomosis Bridges: the only inter-Commune channel; never implicit

Communes communicate **only** through explicit **Anastomosis Bridges**. This lifts the fabric's existing
fusion primitive — *anastomosis*, "two exploring paths fuse where useful"
([GLOSSARY](../GLOSSARY.md); VIS-0003) — from **edge-fusion** to **society-fusion**, governed by a
contract. The bridge is the cross-Commune generalization of the carrier bridge
([ADR-0011](0011-carrier-agnostic-bridging.md)): an ADR-0011 carrier carries a capability + risk
**descriptor**; an Anastomosis Bridge carries a **full contract** between two sovereign genetics.

**Hard NEVER — default rule: no bridge exists unless explicitly established.** There is **no** implicit,
ambient, transitive, or default-on connection between Communes. Protocol compatibility
([ADR-0023](0023-communes-mycobiome-genetics.md)) makes two Communes *able* to bridge; it never makes
them *bridged*. A bridge requires explicit establishment by **both** genetics (each Commune's
trust-roots/governance, per [ADR-0023](0023-communes-mycobiome-genetics.md)), and either side may revoke.

### Decision 2 — The bridge contract grammar: what a bridge MUST define

Every Anastomosis Bridge **must** define, as signed contract terms (signature via standard primitive,
[ADR-0002](0002-no-custom-cryptography.md); per-operator/quorum `SignerKeyID`,
[ADR-0014](0014-per-operator-node-credentials.md)):

- **trust relationships** — which trust scopes / signer sets of each genetics the bridge honours, and at
  what trust level (a bounded `TrustScope` relation, never a global trust grant);
- **allowed traffic classes** — the explicit set of **capability classes** (Decision 3) that may cross,
  for which scopes;
- **forbidden traffic classes** — the explicit set of capability classes that **must not** cross
  (forbidden is stated, not merely "everything not allowed", so a contract widening is always an explicit
  change);
- **abuse-propagation rules** — whether, and which, immune signals
  ([ADR-0024](0024-immunity-temporary-cuts-and-signals.md): `abuse` / `bridge_risk` / …) propagate
  across the bridge, and with what binding effect — the contract clause [ADR-0025](0025-no-global-abuse-oracle.md)
  requires for any cross-Commune binding to exist at all;
- **quarantine rules** — how a quarantine on one side is reflected (or not) on the other, always
  scoped, reversible, and TTL-bounded ([ADR-0024](0024-immunity-temporary-cuts-and-signals.md));
- **revocation rules** — how either side withdraws the bridge (a bridge revocation is a scoped,
  reversible cut, [ADR-0024](0024-immunity-temporary-cuts-and-signals.md); it is unilateral — neither
  side can compel the other to stay bridged);
- **recovery rules** — the defined path to re-establish or re-widen after a cut/quarantine/revocation,
  so a bridge can **heal**, consistent with *heal requires clot*
  ([ADR-0024](0024-immunity-temporary-cuts-and-signals.md));
- **evidence requirements** — the **evidence class** (a coarse, enumerable category — never raw
  evidence, never PII) a propagated abuse/quarantine signal must carry to have effect under this contract.

A bridge contract **MUST NOT** require or produce a complete topology map to be established, and **MUST
NOT** embed raw traffic, user identities, or locations — it is policy between genetics, redacted to the
same boundary as every other signal ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md);
[ADR-0024](0024-immunity-temporary-cuts-and-signals.md); refactoring §7 `TELEMETRY_SAFETY_VIOLATION`).

### Decision 3 — Traffic capability classes: risk-graded, consent-gated

Traffic is distinguished by **capability class**:

> **local control · emergency coordination · messaging · signed-content replication · software updates ·
> real-time media · relay traffic · egress traffic · unknown bulk traffic.**

**Higher-risk capabilities require stronger trust and stronger immunity policy.** A Commune's genetics
([ADR-0023](0023-communes-mycobiome-genetics.md)) decide which capability classes are permitted, to whom,
and across which bridge; the risk gradient runs roughly from low-risk, self-scoped classes (local
control, emergency coordination, signed-content replication, software updates) up to the high-risk
classes (relay traffic, egress traffic, and **unknown bulk traffic**), which require the strongest trust
and the strongest immunity policy and may be refused outright.

**Anonymous egress is NOT a default primitive.** Egress for an unidentified third party is a high-risk
capability that a Commune may grant only by explicit policy across an explicit bridge — it is never
handed out by default, never implied by reachability, and never the meaning of "Mycelium works."

This is the **risk/consent** refinement of the [ADR-0011](0011-carrier-agnostic-bridging.md) /
VIS-0004 flow-class **quality** ladder: the ladder grades *what quality a carrier can carry*; the
capability classes grade *what risk a Commune consents to carry, for whom*. The two compose — a carrier
offers a flow class; genetics decide which capability classes may ride it; a bridge contract decides
which of those cross to a peer Commune.

### Decision 4 — Safe defaults: the closed-by-default node posture

The default node posture is **closed**. Absent explicit policy to the contrary, a node:

- runs **no open relay**;
- performs **no public egress by default**;
- accepts **no unknown third-party transit by default**;
- forms **no bridge without an explicit trust policy** (Decision 1-2);
- performs **no topology sharing by default**;
- applies **rate limits for untrusted scopes**;
- **quarantines suspicious behaviour** (a local, scoped, reversible cut,
  [ADR-0024](0024-immunity-temporary-cuts-and-signals.md));
- **prefers local/community traffic over external transit.**

No Commune is required to relay all traffic, to trust all other Communes, or to remain connected during
active abuse. These are **policy-driven, never controlled by a global authority**
([ADR-0025](0025-no-global-abuse-oracle.md)).

**Honest phase split.** This closed posture is **already the current node reality**, because it follows
from contracts already in canon, not from any cross-Commune machinery: per-operator credentials and a
self-sufficient node ([ADR-0014](0014-per-operator-node-credentials.md)); no open relay / no public
egress (Phase 0-2 ingress and egress coincide on one node — nothing is an open relay; THREAT-MODEL;
ARCHITECTURE Layer 3); no topology sharing (no gossip runs before Phase 3-4); the host firewall opening
no third-party transit by default. **Local** rate-limits and **local** quarantine are near-term
node-local behaviours. What is **Phase 3-4** is live **bridge establishment/revocation** and immune-signal
**emission** over scoped gossip; **Phase 5** is the **trust-gradient grading** of higher-risk capability
classes and cross-Commune trust propagation.

### Decision 5 — Phase discipline & inertness

Per [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md): the **safe-defaults posture binds now**
(it is current node behaviour). The **`AnastomosisBridge` contract schema** and the
**`TrafficCapabilityClass` enum + `CapabilityPolicy`** are introduced **typed and inert** in
`internal/spec` — schema-versioned, JSON-tagged, pure `Validate()`, signatures via standard primitive only
— with **no live bridge establishment, no capability negotiation, no propagation runs** before their
phase. A bridge contract you can *construct and validate* is not a bridge anything *acts on* before
Phase 3-4; cross-Commune capability grading does not run before Phase 5.

### Decision 6 — The hard NEVERs preserved (in one place)

This ADR preserves, and does not soften, the doctrine's hard NEVERs in its domain:

- **never a bridge without an explicit contract** (Decision 1);
- **anonymous egress is not a default primitive** (Decision 3);
- **never an open relay / public egress / unknown transit by default** (Decision 4);
- **never a global authority** that establishes bridges, grades capability, or opens relay/egress on a
  Commune's behalf, and **never a global kill switch** over who may connect
  ([ADR-0025](0025-no-global-abuse-oracle.md));
- **never raw traffic, user identity, location, or a complete topology map** in a bridge contract or any
  signal it carries ([ADR-0024](0024-immunity-temporary-cuts-and-signals.md)/[ADR-0021](0021-decentralized-observability-not-a-central-collector.md)).

**Canonical Rule (preserved).** *Mycelium is not a universal bypass substrate. Mycelium is a Mycobiome
composed of sovereign Communes. The Core provides compatibility; Communes provide life. Mycelium must
grow through anything; Mycelium must NOT attack through everything.* This rule is canon and may not be
watered down.

## Consequences

- **Positive:** inter-Commune connection is **sovereign and consented**, never implicit — protocol
  compatibility never implies connection; abuse has a **scoped, revocable, recoverable** boundary to clot
  at (the bridge contract is where [ADR-0024](0024-immunity-temporary-cuts-and-signals.md) cuts and
  [ADR-0025](0025-no-global-abuse-oracle.md) binding-signal decisions land); capability classes make risk
  explicit and keep anonymous egress off the default path; the closed posture removes the open
  relay/egress an adversary most wants; the design reuses the [ADR-0011](0011-carrier-agnostic-bridging.md)
  capability/risk + flow-class machinery, the existing `TrustScope`/`SporeEnvelope` carriers, and
  standard-primitive signers ([ADR-0002](0002-no-custom-cryptography.md)/[ADR-0014](0014-per-operator-node-credentials.md))
  rather than inventing new authority or new crypto; each Commune stays sovereign over its own connections
  ([ADR-0016](0016-software-releases-not-an-operated-network.md)/[ADR-0023](0023-communes-mycobiome-genetics.md)).
- **Negative / cost (named honestly, not soft-pedalled):**
  - **Setup friction.** Interoperation requires an explicit contract, not mere contact; two Communes
    that could reach each other still cannot route until a bridge is established. This is the deliberate
    price of refusing implicit connection.
  - **A strict default refuses wanted connections.** The closed posture and "anonymous egress is not a
    default" will sometimes refuse a relay/egress a user actually wanted; the remedy is explicit policy,
    not a softened default.
  - **No frictionless universal reachability** and **no single answer to "can A reach B?"** — the answer
    is per-bridge and per-genetics, by design.
  - **Cross-Commune capability/bridge bootstrapping (Phase 4-5) re-opens trust-bootstrapping and
    Sybil-bridge hazards** — a Sybil peer presenting plausible genetics to obtain a bridge, or to be
    granted a higher-risk capability. These are **bounded, not solved here** — they need genetics-rooted
    trust, evidence-class requirements, and quorum/threshold signing, pinned by the Phase-4-5 work, before
    any live cross-Commune capability negotiation runs.
- **Impact on user security (requirement №1):** strongly positive — no node is an open relay or default
  egress for an unknown party; no authority can open a bridge or grant egress on a Commune's behalf; a
  bridge contract and the safe defaults carry **no** raw traffic, identity, location, or full map; a user's
  Commune can refuse, cut, and quarantine without any global target able to force connection. The residual
  risk (Sybil-bridge / capability-bootstrapping in Phase 4-5) is named and deferred under a bound, not
  waved away.
- **Impact on observability/measurements:** none added to the collection path. A bridge contract is
  **policy between genetics**, not a measurement feed; abuse-propagation across a bridge rides the existing
  redacted immune-signal carrier ([ADR-0024](0024-immunity-temporary-cuts-and-signals.md)) with the same
  source-side redaction and no central collector ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md)).
  A bridge neither requires nor produces a global topology.
- **Follow-on actions required:** add the **inert** `AnastomosisBridge` contract schema and the
  `TrafficCapabilityClass` enum + `CapabilityPolicy` to `internal/spec` (data + `Validate()` only, ADR-0002
  signer fields, ADR-0013 inertness); the [ADR-0025](0025-no-global-abuse-oracle.md) bridge-contract
  binding-grammar (how a contract clause makes an immune-signal class binding) is realised by Decision 2's
  abuse-propagation/evidence terms — keep the two in lock-step; add **Anastomosis Bridge**, **traffic
  capability class**, and **safe defaults** to [../GLOSSARY.md](../GLOSSARY.md) (cross-referencing the
  ADR-0011 carrier-bridge entry and the Commune-vs-plane distinction); add the inter-Commune bridge
  abuse/Sybil cases to [../THREAT-MODEL.md](../THREAT-MODEL.md) (the open-relay/egress and Sybil-bridge
  rows); spawn the **Phase-4-5** bridge-establishment + capability-negotiation work with the
  Sybil-bridge / trust-bootstrapping bounds.
- **What is now forbidden:** any **implicit, ambient, transitive, or default-on** connection between
  Communes; establishing a bridge **without an explicit contract** defining trust / allowed+forbidden
  capability classes / abuse-propagation / quarantine / revocation / recovery / evidence; treating
  **anonymous egress** as a default primitive, or any of **open relay / public egress / unknown transit /
  topology sharing** as a default; any **global authority/registry** that establishes bridges, grades
  capability, or opens relay/egress on a Commune's behalf, or a global kill switch over connection
  ([ADR-0025](0025-no-global-abuse-oracle.md)); a bridge contract that **requires or produces a complete
  topology** or that carries **raw traffic / identity / location / a full map**; standing up **live**
  bridge establishment or capability negotiation **before its phase**, or expressing the contract/taxonomy
  as anything but **inert** schema in Phase 0-2; renaming the architectural data/control/routing/discovery
  **planes** to "Commune."

## Compliance

How the decision is verified in practice:

- **`no_bridge_without_contract` conformance gate** — rejects any code path or config that establishes,
  implies, or default-enables an inter-Commune connection without an explicit, signed bridge contract
  carrying all eight terms (trust / allowed / forbidden / abuse-propagation / quarantine / revocation /
  recovery / evidence). `Validate()` rejects a bridge contract missing the **forbidden** set or the
  **revocation** + **recovery** paths. An implicit/default-on cross-Commune connection is an **S0** under
  `FORBIDDEN_TOPOLOGY_CENTRALIZATION` (it is an open relay + a connection an adversary can ride) and blocks
  merge.
- **`no_default_egress_or_relay` conformance gate** — asserts the shipped default posture is closed: no
  open relay, no public egress, no unknown third-party transit, no topology sharing, rate-limit untrusted,
  quarantine suspicious, local preferred over external transit; rejects any default that grants **anonymous
  egress** or **relay** to an untrusted/unidentified scope. Anonymous egress as a default primitive blocks
  merge.
- **`capability_class_gating` conformance test** — asserts the `TrafficCapabilityClass` enum is the closed
  set (local-control / emergency-coordination / messaging / signed-content-replication / software-updates /
  real-time-media / relay / egress / unknown-bulk), that higher-risk classes (relay / egress / unknown-bulk)
  cannot be permitted without an explicit `CapabilityPolicy` referencing a `TrustScope`, and that no
  capability is granted by default by reachability alone.
- **`spec_inert` / `no_premature_mesh`** ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)) —
  the `AnastomosisBridge` and `TrafficCapabilityClass`/`CapabilityPolicy` types import no network, file-I/O,
  or process-execution packages and link no establishment/negotiation/propagation path; any live bridge
  establishment wired before Phase 3-4, or capability grading before Phase 5, fails the merge gate.
- **`no_global_authority` / `no_global_abuse_oracle` review checkpoint**
  ([ADR-0023](0023-communes-mycobiome-genetics.md)/[ADR-0025](0025-no-global-abuse-oracle.md)) — code/doc
  review rejects any registry/policy/authority that establishes bridges, grades capability, or opens
  relay/egress fabric-wide, or that any Commune is **required** to honor; any cross-bridge binding effect
  must trace to an explicit bridge-contract clause (Decision 2), never to a default or a global feed.
- **`immune_signal_no_pii` / no-leak check**
  ([ADR-0024](0024-immunity-temporary-cuts-and-signals.md)/[ADR-0021](0021-decentralized-observability-not-a-central-collector.md))
  — a bridge contract and any abuse/quarantine signal it propagates carry **only** redacted policy +
  decision metadata (scope, capability class, severity, reason/evidence class, TTL, signer/quorum, action
  hint); `Validate()` and the leak check reject any field carrying raw traffic, identity, location, or a
  full/tiling map.
- **`no_custom_crypto`** ([ADR-0002](0002-no-custom-cryptography.md)) — bridge-contract signer/quorum
  fields are key-id string(s) + signature bytes referencing a standard primitive only; defining any bespoke
  signature/threshold scheme fails.
- **`check_ppn_wording`** — the bridge / capability-class / safe-defaults vocabulary stays neutral PPN
  language (no loaded access framing; no country names).
- **Audit checkpoint** — a merge introducing the bridge/capability schema also updates the GLOSSARY
  (Anastomosis Bridge, traffic capability class, safe defaults — cross-referencing the ADR-0011
  carrier-bridge entry and the Commune-vs-plane distinction) and the THREAT-MODEL inter-Commune rows;
  reviewers reject any softening of the hard NEVERs (no bridge without a contract; anonymous egress as a
  default; open relay/egress/transit/topology-sharing as a default; a global authority over connection;
  raw traffic/identity/location/full-map in a contract or signal).
