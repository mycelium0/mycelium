<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Node Interaction & Distributed Awareness

## Metadata
- **ID:** VIS-0003
- **Date:** 2026-06-12
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** primary Phase 3–4 (with inert Phase 0–2 interfaces); deferred pieces in Phase 5 (trust-gradient routing), Phase 6 (carrier-bridged island merge) and Phase 7 (autonomous cord promotion) — see [../ROADMAP.md](../ROADMAP.md)
- **Layer(s):** discovery, control plane, routing, cross-cutting
- **Related:** [0001-mycelium-vision-and-scope.md](0001-mycelium-vision-and-scope.md),
  [0002-carrier-agnostic-mycelial-doctrine.md](0002-carrier-agnostic-mycelial-doctrine.md),
  [../audits/0001-preliminary-architecture-audit.md](../audits/0001-preliminary-architecture-audit.md),
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md),
  [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md),
  [../ARCHITECTURE.md](../ARCHITECTURE.md), [../ROADMAP.md](../ROADMAP.md),
  [../THREAT-MODEL.md](../THREAT-MODEL.md), the internal research baseline (maintainers' knowledge base)

## 1. Problem and context

VIS-0001 promises a self-healing mesh; VIS-0002 promises a fabric that grows through many small local
connections, carries spores over any carrier, and survives as islands when cut. Neither says *how a
node learns who else is out there* — how a new hypha finds the existing mycelium, how a node
announces itself, how the fabric remembers which links work and which have decayed when no central
authority holds that knowledge. Today (Phase 0) membership is static config and the control plane is
shell-based; there is no machine-readable discovery, registry, or network-state contract at all. A
node knows only what its operator typed.

For the mesh to route, self-heal, and degrade gracefully (the VIS-0001 properties), nodes must
acquire **distributed awareness**: enough local knowledge of their neighbourhood to forward traffic,
bootstrap new transports, and recover after a link dies — without any node, or the coordinator, ever
holding the whole map. That last clause is the entire difficulty. A complete membership map is the
single most valuable asset an adversary could seize from an operator, and a registry of "who is
reachable where" is simultaneously a routing table and a surveillance dataset. The adversary reality
this initiative must answer (see [../THREAT-MODEL.md](../THREAT-MODEL.md)) is therefore not only
transport blocking but **sybil enumeration of ingress points, eclipse of a node's view of the mesh,
weaponised revocation, forged compromised-node incident reports, gossip flooding,
topology/membership correlation, fragment-stitching reconstruction by a node coalition, and operator
coercion of any node that knows too much.** Distributed awareness must raise the cost of all of
these, not create them.

This Vision exists because discovery is the next layer the mesh climbs onto, and because the
operator's framing of it (verbatim below) needs to be reconciled with canon, mapped to its real
phases, and corrected on one technical point before it becomes a building plan.

## 2. Vision (desired outcome)

A joining node finds the living mesh, announces itself with a minimal signed identity, and gradually
syncs a **local, trust-scoped, replicated picture of its neighbourhood** — enough to route, to
bootstrap new transports, and to self-heal — while **no node and no coordinator ever holds the global
topology**. Awareness is distributed the way a mycelium is aware: each node senses gradients from its
neighbours, remembers local stress, lets dead links decay, and reconstructs a usable picture of the
surrounding fabric from neighbour caches when parts of the network drop away. Knowledge flows by
scope, trust, and need — never "everything, because two clusters met." A joining node's first edges
are **inviter-vouched, never supplied by whatever peer answers first** (§4 Observe), so a fresh node's
worldview cannot be owned by the discovery surface it bootstraps from.

The target property for the user is unchanged from VIS-0001 and inherited here: reliable private
connectivity given a channel to the network and at least one reachable, working node — now made
*resilient to node loss and to view-poisoning* because awareness is replicated across neighbours
rather than centralised, and self-heals from those neighbour caches when nodes disconnect. When the
fabric is cut, an island retains its local registry and topology fragments and keeps routing locally
(VIS-0002 §4); when islands meet, they exchange signed, coarse, aggregate scoped summaries first —
never full maps and never per-node link weights.

## 3. Principles governing this initiative

- [x] **Do not reinvent cryptography or transport** — discovery rides the canonical Layer-4 stack
  (per [../ROADMAP.md](../ROADMAP.md) / [../ARCHITECTURE.md](../ARCHITECTURE.md): libp2p, Kademlia DHT,
  GossipSub, AutoNAT, Circuit-Relay/ICE/STUN/TURN; Headscale/Nebula-lighthouse coordinator pattern).
  Every registry record, topology fragment, incident report, and revocation is a **signed,
  TTL-bounded spore** using only standard audited primitives. No bespoke scheme — see
  [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md). The specific
  primitive pins (signature validation profile, AEAD context-binding, scope encryption, threshold
  root, sampling/failure-detection algorithms, replication parameters) are **candidates for the
  governing ADRs**, recorded in §9/§10, not settled here.
- [x] **Indistinguishability over obfuscation** — announce/gossip traffic must ride transports that
  resemble legitimate HTTPS/QUIC and must not become a new fingerprintable "discovery protocol"
  signature.
- [x] **Redundancy by default** — awareness is replicated (gossip/anti-entropy, a DHT replication
  factor, erasure-coded k-of-n topology fragments) so that the loss of nodes does not lose the
  knowledge; revocations and bootstrap spores ride many carriers so a single suppressed channel cannot
  silence them. Replication fan-out is **capped by record sensitivity**, not maximised blindly (§6):
  the most sensitive records replicate least, because every replica is another seizure target.
- [x] **Degradation, not failure** — losing neighbours degrades a node to a smaller but still
  routable local view, then to island mode (VIS-0002 §4), then to pure TTL-expiry trust when no log or
  witness is reachable. The registry is **never a synchronous global lookup** whose outage freezes the
  mesh; the coordinator is not a kill-switch.
- [x] **User security is function #1** — knowledge-minimisation is the design centre, not a footnote: a
  node knows little, no full topology to anyone, no PII in any record, aggregated/noised/scoped stress
  signals only (above a minimum-aggregation floor), peer scores strictly local and never gossiped,
  anti-enumeration as a first-class requirement that covers the *sync path*, not only lookup
  endpoints. Data never collected cannot be seized or compelled.

## 4. Scope

This Vision restates the operator's five points in Mycelial vocabulary and on the correct primitives.
The operator input (verbatim intent) was: (1) new nodes **observe** existing nodes via minimal
integration metadata; (2) new nodes **announce** a minimal signed identity to immediate neighbours,
who acknowledge and propagate locally; (3) a distributed **registry** of nodes within trust scope,
updated incrementally by gossip, authoritative for local routing and transport bootstrapping; (4)
local **topology caching** of nearest-neighbour fragments (transport links, link weights, recent node
state history) that can reconstruct a wider picture from neighbour caches and self-heal on
disconnection; (5) distributed **storage of network state** (attack/compromise events, local
degradation signals, gradient signals, newly grown hyphae / promoted cords) so stress memory and
routing metrics survive without exposing full state to any one node.

### In scope

- **Observe (hyphae sensing the mesh).** A joining hypha discovers *currently reachable* neighbours
  through metadata sufficient for integration only — endpoint, transport capabilities, trust scope —
  via the Phase-3 coordinator (coordinator-mediated observation) and then via peer-to-peer gossip in
  Phase 4. Disclosure is **graduated**: unvouched or low-trust peers receive less; no peer receives a
  neighbour list by asking. The **first-contact trust anchor is the inviter**: a fresh node's join
  capability (a biscuit-style join token) cryptographically binds the joiner to the inviter who
  issued it, so the joiner's *first* edges and diversity seed are inviter-vouched rather than
  supplied by whichever DHT/gossip peer answers first. This closes first-join eclipse — the
  "anchor peers persisted across restart" defence protects only *re-*join, so a true first-join needs
  the inviter binding as its anchor.
- **Announce (a spore at boot).** On boot a node emits a **minimal signed identity spore** to its
  immediate neighbours — capabilities, enabled transport *classes*, trust scope, service-capability
  classes — which they acknowledge and propagate *locally within scope*, not globally. Exact service
  ports are **not** broadcast to low-trust peers (capability classes, not exact ports — exact tuples
  are a soft operator-fingerprint and a target-selection aid; §10 PII). This generalises the existing
  config-distribution bundle (one node's endpoint/transport/health metadata) into a mesh reachability
  record. Phase 3 announce is coordinator-mediated (auto-onboarding: a new node joins with one
  command, receives role + config); Phase 4 announce is gossip into the mesh.
- **Distributed registry (the local picture, replicated).** Each node keeps a **local, trust-scoped,
  gossip-replicated registry** of reachable nodes within its scope, updated incrementally by
  anti-entropy reconciliation; it is the authoritative source for *local* routing and for
  bootstrapping new transports. **Imported entries are inert** — non-routable and non-vouching —
  **until the node has locally validated/probed them**: gossip and anti-entropy may *carry* an entry
  into the local view, but an entry the node has never contacted carries no standing until local
  observation backs it, so import-before-validation cannot poison routing. A genuinely *distributed*
  registry is the Phase-4 libp2p Kademlia DHT + GossipSub layer that replaces the Phase-3 coordinator
  registry. The DHT is a **hint / rendezvous layer only — never the membership root or the trust
  root.** Reachability advertisement uses **rotating/ephemeral, closeness/PSI-style rendezvous** (not
  long-lived deterministic keys), because *who publishes under a key and who reads it* links advertiser
  to seeker for any node near that keyspace region (§10 correlation).
- **Local topology caching (fragments, not maps).** Nodes cache **fragments of nearest topology** —
  transport links, link weights (latency, reliability), recent node-state history — sufficient to
  reconstruct a usable wider picture *through neighbour links*, and to **self-heal from neighbour
  caches** when some nodes disconnect. Fragment **scope is minimised so overlaps between neighbours'
  fragments are small** — a stranger's or coalition's fragments do not tile into wide coverage (§10
  fragment-stitching). Fragments are signed, TTL-bounded spores that converge across partitions by
  CRDT-style merge. The cached state expresses the canonical edge lifecycle as established vocabulary
  — *candidate edge → probed → active → reinforced → cord → degraded → decayed → pruned* — without
  redefining those states (the forthcoming network-state-model ADR formalises them).
- **Distributed storage of network state (resilient stress memory).** Distributed, redacted records
  for attack/compromise events, local degradation/failure signals, gradient signals (demand,
  scarcity, priority), and newly grown hyphae / promoted cords — so stress memory and routing metrics
  are **resilient without exposing full state to any single node.** These records are aggregated,
  noised, scoped "signed incident reports", carried as the canonical *stress summary* and *cache
  manifest* spore types. Two anti-forgery floors apply: (a) **no stress/incident summary leaves a node
  below a minimum-aggregation threshold** (a k-anonymity-style floor on contributing observations),
  with region granularity coarsened when the contributing set is small — aggregation-of-one is not
  aggregation; and (b) an incident report that **targets a specific node** requires **k-of-n
  independent witness corroboration** before it affects that node's standing, so a single-signer
  incident report cannot become a back-door false-revocation lever that bypasses the threshold
  protection real revocation gets (§10).
- **Audit + gradual activation.** Each node keeps a **local-only, TTL-rotated** read/write log for
  auditability (a fixed-shape, no-PII, signature-ID/key-ID / checkpoint-hash discipline, never a
  relationship graph, never gossiped or exported); wall-clock time is coarsened or omitted so the log
  cannot serve as a timing-ordered interaction trace. A new node **gradually syncs registry +
  topology fragments before becoming an active relay.**
- **Inert Phase 0–2 interfaces only.** In Phases 0–2 this Vision contributes **schemas and interfaces
  shaped to later accept gossip/DHT backing without breaking** — and nothing that runs. See §4 Non-goals.

### Out of scope / explicitly not doing now

- Any end-user client application or bespoke client is **out of scope**. Nodes expose standard
  protocol endpoints consumed by existing off-the-shelf clients; a bespoke client is possible future
  work only.
- **Proof-of-Space (proper) is out of scope and explicitly not adopted.** The operator framing
  described topology caching as "inspired by Proof-of-Space concepts" for self-healing resilience.
  Proof-of-Space is a *storage-commitment / Sybil-resistance* primitive (influence bound to committed
  disk, like Proof-of-Work binds it to hashpower) — a cost-imposition proof, **not** a data-availability
  or self-healing mechanism. What this Vision actually needs is **redundant distributed availability
  with anti-entropy repair**, which is a different thing. Adopting Proof-of-Space here would be
  technically inaccurate and would smuggle a scarce-resource economic primitive into the architecture
  for no benefit. See §10 Open questions for the correct primitives and the rationale.
- A global membership map, a master topology, a permanent centre, or any "diagnostics" mode that
  reconstructs the whole network by default — not for any node and not for the coordinator. (A scoped
  diagnostic view may exist only where explicitly and narrowly allowed, and is itself an open question;
  it is never the default and never global.)
- Gossiping peer reputation / trust scores between nodes (a Sybil and correlation vector — scores stay
  strictly local and subjective).
- Raw telemetry, identity-linked incident records, or any persistent behavioural profile.

### Deferred → future phase/Vision

- **Genuinely distributed registry over DHT + gossip → Phase 4** (the Phase-3 coordinator registry
  dissolves into it). Trust-gradient-driven routing → Phase 5. Autonomous cord promotion from measured
  link weights → Phase 7.
- **Carrier-bridged island merge** (two separated fragments reconciling registries/topology over any
  bridge, scoped-summaries-first) → Phase 6. Caching *as a topology-survival mechanism within a
  connected mesh* is Phase 4–5; reconciling *across* a partition boundary over a carrier is Phase 6.
- The formal state-model ADR (`NodeState`, `EdgeState`, `RouteState`, `CarrierCapability`,
  `SporeEnvelope`, `StressSignal`, `TrustScope`, `CordPromotion`, `DecayPolicy`, `QuarantinePolicy`,
  and the route-score contract) that turns this Vision's vocabulary into typed state machines.

### Non-goals — phase discipline (what must NOT appear in Phases 0–2)

Distributed awareness is **Phase 3–4 territory.** Per the Scope-discipline fence (MYC-F006,
[../ROADMAP.md](../ROADMAP.md)), the following must **not be running behaviour** in Phases 0–2; early
phases may define only inert data models / interfaces, and only ones that do not block the future:

- **No DHT and no gossip transport running.** Discovery interfaces may be *shaped* so they can later be
  backed by gossip or a DHT — but no DHT runs (that is Phase 4) and no gossip propagates.
- **No distributed registry.** Phase 0–2 membership is static config / config-distribution endpoint;
  the operator owns everything. The `coordinator` role is present but inert/deferred in Phase 0.
- **No peer-to-peer observation and no announce-into-mesh.** A single node (Phases 0–1) and 1–N
  self-tuning nodes (Phase 2) do not gossip topology or announce to a fabric.
- **No master map, no permanent centre, no raw telemetry.** Pulling these forward would smuggle in
  exactly what the non-negotiable constraints forbid. Phase 0–2 telemetry is deferred, opt-in,
  PII-safe, aggregated, no correlation, no identity binding.
- **No trust gradient driving routing** (Phase 5) and **no autonomous cord promotion without
  measurement** (Phase 7). Trust *fields* and path-weight *fields* may exist in data models, inert.
- **Phase-transition rule:** do not begin Phase N+1 until Phase N meets its DoD in production with
  real users. This Vision does not authorise starting discovery as running code while Phases 0–2 are
  unmet.

## 5. Target audience and scenarios

- **Who:** a node operator / volunteer running a home machine behind NAT · a community maintaining a
  mesh segment · the fleet coordinator operator in Phase 3 · a new node owner onboarding for the first
  time.
- **Key scenarios:**
  - *Joining.* A new node boots, presents its inviter-bound join token, observes reachable neighbours
    via integration metadata only (first edges inviter-vouched, not DHT-supplied), announces a minimal
    signed identity, and syncs registry + topology fragments **before** it starts relaying — it earns
    its place as an active hypha gradually, not on first contact.
  - *Self-heal from neighbour caches.* Several nodes disconnect; a survivor reconstructs a usable local
    picture by re-pulling fragments from its remaining neighbours (anti-entropy repair, regenerating
    lost erasure-coded shards), and keeps routing.
  - *Island.* The segment is cut from the wider mesh; it keeps its local registry, service registry,
    and topology fragments and continues local discovery and routing (VIS-0002 §4). On reconnection it
    exchanges signed, coarse, aggregate scoped summaries first (counts / capability classes, no
    per-node identifiers, no per-edge weights), requests only missing artifacts within already-shared
    scope, and preserves local autonomy if merge confidence is low.
  - *Stress memory survives.* A transport class is throttled in a region; once the
    minimum-aggregation floor is met, the redacted stress summary propagates within trust scope so
    neighbours bias away from the affected class — and survives the loss of the node that first
    observed it, because it is replicated, not centrally held. A stress signal that names a *specific
    node* as compromised additionally requires k-of-n witness corroboration before neighbours act on
    it, so one observer cannot induce a false-quarantine-by-incident.

## 6. Assets and trade-offs

- **Protected assets in focus:** the **network map** (asset most at risk here — a registry is a
  membership map and a routing table at once) · ingress reachability · operators (a node holding less
  is a node less worth coercing) · user identity/location (must never enter a record) · traffic
  content (never in a registry/incident/topology record).
- **Conscious trade-offs:**
  - *Openness ↔ Sybil-resistance.* An open join is easy to enumerate and to flood with fake
    identities; trust-scoped, invitation-anchored membership resists this at the cost of friction for
    newcomers.
  - *Awareness ↔ knowledge-minimisation.* Every additional fact a node caches helps routing and hurts
    safety under coercion. The bias is deliberately toward *less*: fragments not maps, summaries not
    raw signals, scope not global.
  - *Availability ↔ seizure surface.* Wider replication and erasure-coding survive node loss, but every
    additional custodian of a scoped record is another node an adversary can compromise or compel to
    obtain that data — compromising *one* fragment custodian yields that scoped fragment. We therefore
    **cap replication fan-out by record sensitivity**: the most sensitive records replicate least, or
    not beyond TTL-bounded caches, accepting weaker availability for those records in exchange for a
    smaller seizure surface.
  - *Adaptation speed ↔ false-migration / false-quarantine risk.* Fast reaction to a stress or
    revocation signal risks acting on a poisoned or false signal; decay, hysteresis, witness
    corroboration, and measure-before-acting slow this down on purpose.
  - *Centralisation (simplicity) ↔ decentralisation (resilience).* The Phase-3 coordinator registry is
    simple and capturable; the Phase-4 DHT is resilient and harder to reason about. We accept the
    centralised form as a temporary target.
- **Technical debt accepted knowingly:** the **Phase-3 coordinator registry is a deliberate temporary
  centre** — it issues membership and aggregates block-intelligence in one place — accepted on the
  explicit plan to dissolve it into the Phase-4 DHT + gossip layer. It must never be allowed to become
  a kill-switch or a permanent master map in the meantime.

## 7. Definition of Done (measurable, not a slogan)

- [ ] A new node joins, presents an inviter-bound join token, observes neighbours via integration
  metadata only, announces a signed identity, syncs registry + topology fragments, and becomes an
  active relay **only after** sync — and at no point can it (or any single node) enumerate the global
  membership, and at first-join its initial view is inviter-vouched rather than supplied by the first
  peers that answer.
- [ ] We artificially disconnect a fraction of a node's neighbours → the node reconstructs a usable
  local routing picture from remaining neighbour caches within a bounded recovery window, with no human
  intervention.
- [ ] A planted Sybil cluster joining through a small number of attack edges **cannot** dominate an
  honest node's local view, inflate its own standing, or crowd out honest entries beyond the bound
  expected from the attack-edge count; imported-but-unvalidated entries stay inert (non-routable,
  non-vouching) so gossip propagation alone cannot poison routing.
- [ ] A node restart does not let an attacker monopolise the rebuilt peer view (eclipse): anchor
  peers, outbound quota, and diversity quotas hold the honest fraction of the view above target. The
  eclipse test covers **the DHT read path as well as peer-table composition** — an adversary cannot
  eclipse a node's DHT view of a specific membership/revocation key (disjoint-path lookup +
  per-bucket diversity hold).
- [ ] A false revocation against an honest node, injected by one coerced/malicious node, does **not**
  remove that node from honest peers' registries (revocation is scoped + threshold-signed +
  merge-dominant), and a *suppressed* legitimate revocation still arrives via an alternate carrier.
- [ ] A forged compromised-node **incident report** from a single signer against an honest node does
  **not** cost that node standing or cause neighbours to bias away from it without **k-of-n independent
  witness corroboration** — the incident/stress channel cannot be used as a back-door false-revocation
  lever.
- [ ] A merge-poisoning attempt — an adversary-controlled transient island asserting false quarantines
  against honest nodes — **self-heals by TTL** and requires a threshold-signed re-assertion to persist;
  a single coerced node cannot ratchet permanent quarantines onto honest nodes across future merges.
- [ ] Gossip flooding (bogus registrations / fake attack events / oversized records) is rate-limited
  and self-prunes by TTL without burying real signals.
- [ ] **Enumeration resistance is cumulative, not single-shot:** N low-trust / Sybil identities
  re-querying over time T **cannot** jointly reconstruct a neighbour list, sweep the keyspace, or
  stitch graduated-disclosure crumbs into "enough"; and the **anti-entropy / sync path** leaks no more
  than the scope a peer is vouched for (reconciliation digests are themselves trust-scoped, not over
  the node's whole keyspace).
- [ ] A bounded coalition of colluding/compelled nodes **cannot** reconstruct topology beyond the union
  of its own legitimately-scoped neighbourhoods (fragment scopes are minimised so they do not tile).
- [ ] An auditor inspecting any node's registry, topology cache, incident store, and read/write log
  finds **no PII, no full topology, no complete peer list, no relationship graph, and no
  timing-ordered interaction trace** — only redacted, TTL-bounded, scoped facts; the log carries no
  wall-clock resolution fine enough to reconstruct who-saw-what-when.
- [ ] Taking the coordinator (Phase 3) or the log/witnesses (Phase 4) offline degrades the mesh to
  TTL-expiry trust and local routing — it does **not** freeze or kill it.

## 8. Measurability and observability

Signals that prove the property and feed the adaptation layer, all PII-safe and aggregated:
fraction of an honest node's local view that remains honest under a planted Sybil/eclipse attack (peer
table *and* DHT read path); time to reconstruct a routable local picture after neighbour loss
(self-heal latency); registry convergence time after a gossip update; false-positive/false-negative
rates of the incident/stress channel on labelled events, paired with an **"aggregation floor
honoured" check** (no summary emitted below the minimum-observation threshold) and a **forged-incident
rejection rate** (single-signer node-targeting reports rejected absent k-of-n corroboration); share of
legitimate revocations that arrive despite a suppressed carrier; share of false merge-asserted
quarantines that self-heal by TTL; share of bogus records rejected before propagation; and the
enumeration-resistance check — confirmed *cumulative* inability of N strangers over time T to sweep
the keyspace, pull a neighbour list, observe rendezvous-key advertiser↔seeker links, or learn a
neighbour's full record-ID set via the sync path. Observability uses the standard PII-safe metrics
stack (Prometheus/Alertmanager/textfile-gauge); the incident/stress store must aggregate, add noise,
honour the aggregation floor, and bind no identity before any signal leaves a node.

## 9. Dependencies and prerequisites

- **Preceding phases/Vision/ADR:** VIS-0001 (founding) and VIS-0002 (spore/island/carrier doctrine)
  accepted; [../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md) binds every
  signed artefact; [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md)
  defines the spore envelope and carrier descriptor. **Phases 0–2 must meet their DoD in production
  before discovery runs as code.** The forthcoming network-state-model ADR (the typed state machines)
  is a prerequisite for the registry/topology schemas.
- **Contracts this Vision touches:** the **config-distribution endpoint** (generalised from one node's
  bundle into mesh reachability records — shaped to later accept gossip/DHT backing without breaking);
  the **block-event / block-intelligence telemetry** (the payload of distributed network-state
  storage — aggregate, noise, aggregation-floor, no identity binding); the **spore schema + carrier
  capability/risk descriptor** (cache-manifest, stress-summary, route-capsule, trust-invitation,
  revocation-notice spore types — never carrying full topology, complete peer lists, per-edge weights,
  or user identities); the planned **`internal/spec` typed schemas** (where any inert
  discovery/telemetry/spore data model lives first as a non-blocking interface).
- **External stack/infra:** libp2p (go-libp2p primary; Rust daemon allowed per ADR-0012), Kademlia
  DHT, GossipSub, AutoNAT, Circuit-Relay/ICE/STUN/TURN, Snowflake-style ephemeral ingress;
  Headscale/Nebula-lighthouse coordinator pattern (Phase 3). Candidate primitives for the registry/
  state store and their hardening (subject to the ADRs): Brahms (Byzantine peer sampling); SWIM +
  Lifeguard (failure detection with low false-positive eviction); S/Kademlia disjoint-path lookup
  with per-bucket diversity (a **hard requirement, not a mere candidate, for any record that carries
  revocation/quarantine state** — see §10 eclipse); the GossipSub hardening trio (outbound `D_out`
  quota, opportunistic grafting, flood-publish) and IHAVE/IWANT rate limits as candidate
  eclipse/flood mitigations; Ed25519 with a pinned ZIP-215 / `verify_strict` validation profile, AEAD
  context-binding, and HPKE/age scope encryption as the candidate signed-spore profile; biscuit
  capability tokens for join/scope binding; FROST-Ed25519 threshold root; Sigsum-style transparency
  log.
- **Cross-cutting tracks that cannot be deferred:** security, measurement, legal/opsec,
  governance (who holds the threshold trust root and how it is kept jurisdiction-diverse).

## 10. Risks and open questions

The gossiped node-registry and the distributed "attack-event / compromised-node" store are among the
highest-value attack surfaces in the whole design, because each is simultaneously a *membership map*
(the network-map asset) and a *trust-control channel* (the revocation lever). The real tensions, and
how trust-scope + signed spores + replication bounds mitigate them — and, where they do **not**
suffice as described, what closes the gap:

- **Sybil poisoning of the registry.** An adversary mints many cheap identities to dominate a node's
  local view, inflate its own standing, and crowd out honest entries. *Mitigation:* you bound it, you
  do not prevent it — anchor membership in the **invitation graph** so Sybils cost real attack edges
  and inviters are accountable; use conserved/seed-based trust, never global eigenvector trust
  (mutually-rating Sybils would inflate trust from nothing); add IP/subnet/ASN colocation as a *soft*
  signal and graph-gated micro-PoW demanded only of low-trust/uninvited peers. **Imported registry
  entries are inert (non-routable, non-vouching) until locally validated/probed**, so gossip/
  anti-entropy import cannot poison routing before any local scoring is possible. Peer scores stay
  strictly local and are never gossiped — gossiping scores is itself a Sybil amplification channel.
  *Caveat carried honestly:* because the inviter down-weight is a **local, never-gossiped** score, it
  cannot by itself globally constrain a malicious high-trust inviter who mints many invitations —
  every honest node must rediscover the abuse independently. The open question below asks for a
  **signed, scoped, non-reputational attack-edge accounting** (SybilLimit-style edge counts attached
  to the invitation graph, distinct from gossiped reputation) so inviter abuse carries a
  cryptographically visible, non-reputational cost; until that lands, vouching-abuse detection is
  honestly per-node and local (see "fundamentally hard problems").
- **First-join eclipse before anchors exist.** "Anchor peers persisted across restart" protects only
  *re-*join; a brand-new node has no anchors and would otherwise take its entire initial view from
  whatever peers answer first — exactly the eclipse-at-join the DoD must defeat. *Mitigation:* the
  **inviter binding** (§4 Observe) makes the issuing inviter the mandatory first edge and diversity
  seed; the biscuit join token cryptographically binds the joiner to that inviter so the first view is
  inviter-vouched, not discovery-supplied.
- **Eclipse / view monopolisation.** An adversary fills a node's peer table (especially across a
  restart) so it only ever sees attacker-supplied registry and revocation state. *Mitigation:* the
  GossipSub hardening trio (outbound `D_out` quota, opportunistic grafting, flood-publish), plus anchor
  connections persisted across restart, feeler / test-before-evict, un-steerable randomised eviction,
  per-IP/subnet/ASN diversity quotas, and always one out-of-band lifeline. **Crucially, this secures
  the gossip overlay but not the Kademlia read path:** an adversary who cannot eclipse the gossip mesh
  can still eclipse a node's *DHT view of a specific key* (a target's membership record or revocation)
  unless **S/Kademlia disjoint-path lookup + per-bucket diversity are mandatory** for any record
  carrying revocation/quarantine state — so they are promoted from candidate to requirement, and the
  eclipse DoD covers the read path explicitly.
- **False revocation — the revocation channel as a weapon.** A coerced or malicious node injects
  revocations against *honest* nodes (DoS-by-revocation), or suppresses a legitimate revocation to keep
  a burned key alive. *Mitigation:* revocations are **scoped** (revoke "may relay region X" / "may
  vouch", never base identity), **threshold-signed** (FROST root — one coerced signer cannot revoke),
  and **merge-dominant** on partition merge (a quarantine asserted on either side survives;
  *un*-revoke requires positive re-attestation, never mere absence). Against suppression: ride
  revocations over many carriers and back them with a transparency log so silent abuse *and* silent
  non-revocation are both detectable. No auto-quarantine without an observable signal and a reversal
  path.
- **Forged compromised-node incident reports — the parallel lever revocation's defence misses.** FROST
  protects *revocation*, but "attack/compromise" events ride the *incident/stress* channel, where a
  single node's signature emits one — and §5 has neighbours "bias away" on such signals, which is
  false-quarantine-by-incident *without* the threshold protection. *Mitigation:* the incident/stress
  channel gets its own anti-forgery floor — an incident report that **targets a specific node** must
  carry **k-of-n independent witness corroboration** (multiple nodes observing the same target) before
  it affects that node's standing, closing the single-signer back door around FROST. (Aggregate,
  non-node-targeting stress summaries remain single-observer-emittable but still bound by the
  minimum-aggregation floor below.)
- **Merge-dominant *false* quarantine as a one-coerced-node ratchet.** Merge-dominance is correct
  against *suppression* but asymmetric for *false* quarantines: an adversary controlling one transient
  island could assert quarantines against many honest nodes, and on every future merge those dominate
  and persist while removal demands expensive re-attestation a partitioned honest node may be unable to
  muster. *Mitigation:* a merge-dominant quarantine must itself be **threshold-signed (not
  single-signer)** and **TTL-bounded** so a false one self-heals if not re-asserted by threshold —
  merge-dominance then bounds blast radius without becoming a permanent honest-node-poisoning ratchet.
- **Registry / incident-store flooding.** Spam of bogus registrations, fake attack events, IWANT/IHAVE
  abuse, or oversized records to exhaust bandwidth and bury real signals. *Mitigation:* GossipSub
  IHAVE/IWANT rate limits + behavioural penalty + graylist (RPCs ignored below threshold); graph-gated
  micro-PoW as an admission cost for cheap-to-abuse operations; per-node custody quotas, dedup, bounded
  exploration budget; and TTL/expiry on every record so flooded state self-prunes. *Honest caveat:*
  micro-PoW is a **friction layer, not the load-bearing Sybil bound** — a PoW trivial for a phone is
  trivial for an adversary's phone-equivalent VM at scale; the real bound on Sybils is **attack-edge
  count via the invitation graph**, and micro-PoW only raises the cost of cheap abuse per trust-region.
- **Topology enumeration / crawling.** Treating the registry as a free global membership map (a single
  crawler has enumerated an entire public DHT in minutes); a `findNode`-style endpoint that returns
  neighbour lists to strangers is enumeration-by-design. *Mitigation:* make anti-enumeration
  first-class **across both the lookup and the sync path** — rate-limit and refuse keyspace-sweep
  queries from strangers; do not return full neighbour lists to unvouched peers (graduated
  disclosure); **trust-scope the anti-entropy / IHAVE reconciliation set itself** so a peer reconciles
  only over the scope it is vouched for, never the node's whole record-ID keyspace (naive set
  reconciliation otherwise leaks the full set of held record IDs even when payloads are encrypted);
  defend against *cumulative* disclosure (N low-trust identities re-querying over time must not sum to
  a neighbour list); prefer closeness/PSI-style rendezvous over open enumeration; rotate/ephemeralise
  advertised IDs; and keep the DHT a hint layer only, never the membership or trust root.
- **Membership / traffic correlation, incl. rendezvous-key observation.** Cross-referencing who is in
  the registry, who advertises what, who reads which key, and who reports which incidents to map
  relationships, ingress points, and operator infrastructure. A DHT key is a long-lived deterministic
  locator: the nodes responsible for that keyspace region (which an adversary can approach via ID
  grinding) observe *advertiser ↔ seeker*. *Mitigation:* **rotating/ephemeral, closeness/PSI-style
  rendezvous as a hard requirement** for any reachability advertisement (not a preference);
  route-summary minimisation; no full topology and no per-node link weights in island merge; scoped
  exchange by trust and need; aggregate/noise/redact stress signals before they leave a node; and run
  detection distributed and locally with no global view (the detector must not itself become a
  correlation tool).
- **Fragment-stitching reconstruction by a coalition.** No single node holds full topology and the
  coordinator does not — but an adversary running M nodes (or compelling M operators) can stitch
  overlapping local fragments into a wide map; signed, scoped fragments still tile into coverage where
  scopes overlap. *Mitigation:* **minimise fragment scope so overlaps are small** and a stranger's or
  coalition's fragments do not tile; accept that the goal is a *bound*, not prevention (consistent with
  the Sybil framing) — a bounded coalition reconstructs no more than the union of its own
  legitimately-scoped neighbourhoods (DoD §7).
- **PII in state history.** Incident or registry records carrying IPs, user-linkable identifiers, full
  peer lists, or topology become a seizable/compellable surveillance dataset — and a **time-ordered
  key-ID log is itself a latent relationship graph** (ordering + timing reconstruct
  who-saw-what-when even without explicit edges). *Mitigation:* no raw telemetry, no user
  identity/location, no complete peer lists, no full topology, no per-edge weights in summaries, no
  persistent behavioural profiles; the only acceptable record contents are redacted route health,
  transport success/failure summaries, latency/jitter distributions, regional interference
  fingerprints without identity (coarsened when the contributing set is sparse), and signed,
  witness-corroborated incident reports; the minimal loggable fact is a signature-ID/key-ID +
  checkpoint hash, never a relationship; and the audit log is **local-only, never gossiped/exported,
  TTL-rotated (not append-forever), with wall-clock resolution coarsened or omitted** so it cannot
  serve as a timing-correlation trace. Data never collected cannot be seized or compelled.

**Fundamentally hard problems (honest, not "we'll sort it out"):** the first-contact / bootstrap
problem under enumeration pressure (the inviter binding anchors it but does not make open join free);
Sybil-resistance versus openness (the attack-edge bound is the best we can do, not prevention) — and
specifically that **inviter accountability is, until a signed non-reputational attack-edge accounting
exists, detected only locally and per-node**; making revocation safe *in both directions*
(forge-resistant **and** suppression-resistant) and extending that same threshold/witness floor to the
parallel incident channel; and convergence of security state across partitions without letting a false
quarantine ratchet or trust teleport across a partition boundary.

**Open questions → research / ADR / RFC:**

- **Proof-of-Space is NOT adopted, and here is the correct mechanism.** The operator framing called
  topology caching "inspired by Proof-of-Space concepts." That is a mischaracterisation that must not
  ship: Proof-of-Space is a storage-commitment / Sybil-resistance proof (influence bound to committed
  disk), not a data-availability or self-healing mechanism. What "fragments that self-heal from
  neighbour caches" actually means is **redundant distributed availability with anti-entropy repair**,
  built from standard primitives: (a) **gossip / anti-entropy replication** (GossipSub; candidates
  Brahms, SWIM + Lifeguard) — the correct name for "self-heal from neighbour caches"; (b) a **DHT
  replication factor** (k replicas) with region/wide publication and S/Kademlia disjoint-path lookup +
  per-bucket diversity to resist keyspace eclipse — the DHT as hint layer only; (c) **erasure-coded
  k-of-n fragments paired with anti-entropy repair** — erasure coding gives k-of-n *reconstruction*,
  but only anti-entropy *repair* (regenerating lost shards onto fresh custodians) delivers the
  ongoing *self-heal* the claim needs, so the two are specified together; (d) **signed, TTL-bounded
  spores with replay protection** (Ed25519/ZIP-215, per-flow-class TTL, scoped nonce cache, AEAD
  context-binding; optional HPKE/age scope encryption); (e) **CRDT-style merge** for island/partition
  convergence, with the safety constraint that security state (revocations/quarantines) is
  merge-dominant **and** threshold-signed **and** TTL-bounded (so false quarantines self-heal), and
  cross-island reputation gains are discounted until re-validated locally. Open question for the ADR:
  the exact replication factor, fragment k-of-n parameters, per-record-class TTLs, and the
  sensitivity→replication-cap policy.
- The shape of the **invitation graph / trust-scope** model (SybilLimit-style attack-edge accounting
  carried in a signed, scoped, **non-reputational** form so inviter abuse has a cryptographically
  visible cost without gossiping reputation; biscuit capability tokens for join binding and for "this
  node may appear in scope X until T"); whether **identity rotation must chain rotated IDs to the same
  inviter binding** so anti-enumeration ID rotation does not become free Sybil minting / honest-churn
  impersonation; the calibration of graph-gated micro-PoW (trivial for a phone, punishing at scale,
  scaling super-linearly with identity count *per trust-region*) — noting micro-PoW is friction, not
  the load-bearing bound.
- Custody of the **threshold trust root** (FROST-Ed25519, RFC 9591) and how to keep its t-of-n members
  jurisdiction-diverse without crowning a permanent centre; whether and how a *narrow, explicitly
  allowed* scoped diagnostic view can exist without becoming a master map.
- The **minimum-aggregation floor and witness-corroboration** parameters: the k-anonymity-style floor
  (minimum contributing observations) and region-coarsening rule for stress summaries, and the k-of-n
  witness count for node-targeting incident reports.
- The **island-merge summary floor**: the exact coarse, aggregate, count/capability-level digest shape
  (no per-node identifiers, no per-edge weights), and the rule that full per-node records transfer only
  on explicit pull within already-shared trust scope.
- Route-flap-damping-style decay parameters (exponential decay + hysteresis, with the
  over-suppression caution so honest churn is not pruned as if hostile).

## 11. What becomes possible next

With distributed awareness in place, the mesh can route on a local picture instead of static config;
self-heal from neighbour caches; and carry stress memory that survives node loss. This is the
substrate Phase 5 needs for **trust-gradient-driven routing** and Phase 7 needs for **autonomous cord
promotion from measured link weights** — gradients can guide only once nodes sense their neighbourhood.
It is also the precondition for VIS-0002's **carrier-bridged island merge** (Phase 6): two islands can
reconcile scoped summaries only if each already keeps a local registry and topology fragments to
summarise. The mesh is extended on top of something working, not instead of it.

## 12. Next steps

- [ ] **ADR — distributed network-state model** (`docs/adr/NNNN-...`): formalise `NodeState`,
  `EdgeState`, `RouteState`, `CarrierCapability`, `SporeEnvelope`, `StressSignal`, `TrustScope`,
  `CordPromotion`, `DecayPolicy`, `QuarantinePolicy`, the route-score contract, the
  *candidate → probed → active → reinforced → cord → degraded → decayed → pruned* lifecycle as state
  machines, and the import-inert-until-validated rule for gossiped/anti-entropy entries.
- [ ] **ADR — discovery, registry & gossip** (`docs/adr/NNNN-...`): the Phase-3 coordinator-registry →
  Phase-4 Kademlia-DHT + GossipSub evolution; replication factor / erasure-coding + anti-entropy-repair
  parameters and the sensitivity→replication-cap policy; the inviter-binding bootstrap anchor;
  S/Kademlia disjoint-path + per-bucket diversity as a requirement for revocation/quarantine records;
  the anti-enumeration / graduated-disclosure rules **including trust-scoped anti-entropy and
  cumulative-disclosure resistance**; rotating/ephemeral PSI-style rendezvous; and the explicit
  non-adoption of Proof-of-Space.
- [ ] **ADR — distributed revocation, incident floor & trust root** (`docs/adr/NNNN-...`): scoped,
  threshold-signed (FROST), TTL-bounded, merge-dominant revocation **and quarantine**; the k-of-n
  witness-corroboration floor for node-targeting incident reports; the minimum-aggregation floor for
  stress summaries; transparency-log + witness cosigning; degraded-mode TTL-expiry trust.
- [ ] **RP — inert Phase 0–2 discovery/state schemas** (`docs/proposals/NNNN-...`): the non-blocking
  `internal/spec` data models shaped to later accept gossip/DHT backing, with test-vectors, running no
  distributed behaviour.
- [ ] **research-note** on the Sybil/eclipse bound calibration, signed non-reputational attack-edge
  accounting, micro-PoW sizing, witness-count / aggregation-floor calibration, and erasure-coding
  parameters (`docs/research/...`).
- [ ] **Trigger an event-driven audit** when the discovery layer (Phase 4) is connected, per
  [../refactoring.md](../refactoring.md).
