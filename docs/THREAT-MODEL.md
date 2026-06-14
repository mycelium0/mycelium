<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Threat Model

An honest assessment of the adversary, attack surfaces, unresolved problems, and legal realities.
This document exists so the project does not promise what is impossible, and so that operators
understand risk before it materialises.

## Adversary (capability-based model, June 2026)

A large-scale network operator (the adversary) with the following capabilities:

- **Transit-layer inspection appliances (large-scale DPI at exchange points)** — inspection and
  blocking at the network backbone.
- **AS-level blocking** — cuts all traffic to "tainted" autonomous systems wholesale (observed
  pattern: handshake succeeds, data dies). IP and AS diversity is not optional.
- **ML-based traffic classification** — learns from flow statistics, not signatures. Protocol
  mimicry alone is therefore insufficient; statistical indistinguishability is required.
- **Active probing** — contacts a suspicious server and checks whether it behaves as the claimed
  site. The response must be legitimate (REALITY + donor site handles this).
- **Protocol-class excision** — unrecognised UDP traffic has been cut in some environments.
- **Protocol allowlisting / selective shutdown** — in high-pressure scenarios, only a whitelist
  of approved services is reachable; all others, including standard bootstrap channels, become
  inaccessible.
- **Legal and regulatory pressure** — blocklists covering large numbers of private network
  services; legal frameworks targeting distribution and operation of persistent private network
  tools; pressure on hosting providers and app distribution platforms.
- **Adversarial mesh participation** — running surveillance nodes to enumerate ingress points,
  correlate traffic, and de-anonymise users (the primary threat for phases 4–5).

What the adversary does not currently do at scale, but could: full allowlist-only internet
(at that point only CDN-fronting via indispensable CDNs and offline/LAN channels survive).

## Protected assets

1. **User identity and location** — that a person is using a persistent private network (itself
   actionable in some jurisdictions).
2. **Traffic content and destination** — where and why someone is connecting.
3. **Ingress reachability** — the mere existence of working entry points.
4. **Node operators** — their identities and infrastructure.
5. **Network map** — who is connected to whom (the most valuable prize for the adversary in
   phases 4–5).

## Attack surface and mitigations

| Attack | Where it strikes | Project mitigation |
|---|---|---|
| Signature-based DPI | data plane | REALITY/Vision; indistinguishability from HTTPS |
| ML-based flow classification | data plane | Statistical traffic shaping beyond protocol mimicry; auto A/B obfuscation tuning |
| Active probing | data plane / node | Donor site returns a legitimate response; every exposed port is REALITY/donor-fronted, no plaintext banners. Phase-0 minimal-exposure posture is REALITY-on-443; the bash bootstrap default additionally exposes REALITY+gRPC on 8443 (same family, also donor-fronted) for client failover — a deliberate, recorded two-port default (ADR-0022), not extraneous services |
| IP-level / AS-level blocking | node | IP/AS diversity, fast rotation, CDN-front, ephemeral ingress nodes |
| UDP excision | transport | TCP/TLS paths are primary; UDP is a bonus |
| Block of the config distribution domain | control plane | Domain-fronting, anycast, P2P fallback, out-of-band bootstrap configs |
| Sybil / ingress enumeration | discovery | Invitation trees, social-graph/history trust, PoW, graduated knowledge |
| Eclipse / route poisoning | discovery / routing | Reputation scoring, peer diversity, verifiability |
| Traffic-timing correlation | routing | Multi-hop, padding, mixing (at latency cost) |
| Node compromise | full stack | Minimal node knowledge; forward secrecy; ingress/egress separation (Phase 3–4 — in Phases 0–2 ingress and egress coincide on one node, see ARCHITECTURE.md Layer 3) |
| Operator coercion | people | Minimal logging, plausible deniability, jurisdictional distribution |

## Attack surface: carriers, bridges, and spores

Treating any carrier that moves authenticated bytes as a possible bridge (the carrier-agnostic model
of [ADR-0011](adr/0011-carrier-agnostic-bridging.md)) widens reachability — and widens the attack
surface. Each bridge and each spore is *potentially useful and potentially dangerous*; capability and
risk are characterised before routing through it. These attacks become first-class from Phase 6 (and
their data-model interfaces are anticipated earlier — see the roadmap's scope-discipline note).

| Attack | Where it strikes | Project mitigation |
|---|---|---|
| Bridge enumeration | discovery / bridges | Scoped, trust-gated bridge advertisement; no global bridge map; bridge diversity |
| Malicious custody (store-and-drop / mutate) | bridges / DTN | Signed spores with integrity; deduplication; redundant custody; mutation detected and dropped |
| Spore replay | spores / DTN | TTL/expiry and replay protection; per-spore dedup keys; stale spores rejected |
| Route-capsule poisoning | routing / spores | Scoped signatures; route-summary minimisation; reinforcement only from measured usefulness; poisoned routes decay |
| Metadata leakage from summaries | control plane / bridges | Route-summary minimisation; scoped exchange; no full topology in island merge |
| Bridge flooding | bridges / DTN | Rate limits; custody quotas; dedup; bounded exploration budget per node |
| Carrier-specific coercion | people / carriers | Carrier diversity; degrade down the flow-class ladder; no carrier trusted as safe by default |
| False bridge-capability advertisement | bridges | Measure before promotion; a bridge is never a cord without measurement; risk descriptor verified against behaviour |
| Local-island Eclipse | discovery (islands) | Peer/bridge diversity; scoped trust on merge; no single bridge defines an island's view |
| Over-trusting satellite / radio carriers | carriers | Explicit risk descriptors; treat satellite/radio as untrusted transport, not as inherently safe |
| Mesh capture / takeover | full stack / mesh | Detect → quarantine → revoke scoped trust → decay poisoned routes → reroute around the captured region; never crown a permanent centre (Phase 5 self-healing) |

**Mesh capture / takeover → self-healing response.** Beyond outside blocking, the mesh must withstand
compromise from the inside: a captured, coerced, or taken-over node. The response is the Phase 5
self-healing path: **detect** the compromised/coerced node from local signals (anomalous routing,
poisoning attempts, failed verification, stress patterns); **quarantine** it so it carries no scoped
traffic; **revoke scoped trust** through signed revocation spores; **decay poisoned routes** so bad
paths lose weight; **reroute around the captured region** using path diversity; and **never crown a
permanent centre** — recovery returns the mesh to a decentralised steady state, not to a new single
point of control. Cross-cutting mitigations across all of the above: scoped signatures, TTL and replay
protection, artifact deduplication, route-summary minimisation, trust-scoped exchange, bridge
diversity, local quarantine, stress memory and decay, and no full topology exchange during island
merge.

## Attack surface: Mycelium as an attack substrate

A resilient network that cannot defend itself becomes a carrier for parasites. The same
carrier-agnostic reach ([ADR-0011](adr/0011-carrier-agnostic-bridging.md)) that lets Mycelium grow
through anything would, undefended, let abuse flow through everything. These attacks treat the
network — or a peer Commune — as a weapon. The mitigations below are **policy-driven and local**: a
*Commune* (a sovereign Mycelium society with its own trust roots, governance, and immune policy — a
first-class deployment entity, distinct from the architectural data/control/routing/discovery
**planes**, which keep their names) defends itself; no global authority defends it for it. The
cross-Commune machinery (immune signals, Anastomosis-bridge contracts, cross-Commune trust) is
Phase 4–5 with inert typed schema hooks definable now ([ADR-0013](adr/0013-mycelial-vocabulary-and-phase-discipline.md));
the closed-by-default node posture, local rate limits, and local quarantine are already the
Phase-0 posture (per-operator credentials, no open relay or egress).

| Attack | Where it strikes | Project mitigation |
|---|---|---|
| Abuse transit / Mycelium used as a universal bypass substrate | full stack / capability classes | Capability classes — anonymous egress is **not** a default primitive; higher-risk classes (relay, egress, unknown bulk) require stronger trust and stronger immunity policy; safe-default closed posture (Phase 4–5 classes; Phase-0 default already refuses open relay/egress) |
| One Commune attacking through another (peer Commune as attack platform) | bridges / Communes | Anastomosis-bridge contracts: no bridge exists unless explicitly established; each bridge enumerates allowed and forbidden traffic classes, abuse-propagation rules, and revocation/recovery rules; a Commune is never required to relay all traffic or trust all Communes (Phase 4–5) |
| Hostile relay use | relay / egress | No open relay and no public egress by default; relay/egress are trust-gated capability classes; local/community traffic preferred over external transit; scoped reversible cut isolates a misused corridor |
| Scanning / enumeration originating inside the mesh | node / discovery | Bulk scanning is rejected by default; rate limits for untrusted scopes; quarantine of scanning behaviour; no topology sharing by default starves the scanner of a map |
| Malware command-and-control over the network | data plane / capability classes | Unknown bulk transit is the highest-risk class and closed by default; quarantine of suspicious nodes; scoped reversible cut of the C2 corridor; capability policy, not content inspection, gates the class |
| DDoS traffic / amplification through nodes | node / transport | Rate limits for untrusted scopes; custody/transit quotas; no node is required to relay all traffic; scoped reversible cut of the abusive source or corridor; clotting isolates the flood without a global topology change |
| Coerced global ban / network-wide kill switch | governance (S0) | **No global abuse oracle**: there is never a single authority that can ban a node or Commune network-wide. Fungi may *sign* warnings; Communes may *subscribe to* or *ignore* them; bridge contracts decide which signals bind. A global ban power is itself an S0 attack surface — coerce it once and the whole Mycobiome is captured (see "Immunity and sovereign defense") |
| Immune-signal abuse (poisoned cut/quarantine/abuse signals) | immune signals (Phase 4–5) | Signals carry only scope, severity, reason code, TTL, evidence class, signer/quorum, and a reversible action hint — **never** raw traffic, user identities, locations, or a complete topology map; signed/quorum-gated; cuts are scoped, reversible, and time-bounded so a forged signal cannot become a permanent or global outage |

**Scoped reversible cuts (clotting).** A living organism must be able to clot. Mycelium supports
temporary, scoped cuts: a cut may isolate a node, a route, a transport, a bridge, a corridor, a
trust scope, or a Commune. Every cut is **scoped, reversible, time-bounded, auditable inside the
affected Commune, minimally revealing, and independent of any global topology**. This is the immune
counterpart to the Phase-5 self-healing path above: self-healing reroutes *around* compromise; a cut
*stops* infection from spreading while healing runs. The ability to heal requires the ability to
clot — and because a cut is scoped and time-bounded, it can never degrade into the global kill
switch that the No-Global-Abuse-Oracle rule forbids.

## Mycelium-specific principle: Immunity and sovereign defense

**Resilience without immunity turns a network into an attack substrate.** Mycelium does **not**
optimise for universal availability at any cost. A network that cannot cut infection is not alive —
it is already captured. This principle is canonical and sits alongside knowledge-minimisation, role
separation, and user-safety-above-functionality above.

- **Immunity is a first-class requirement.** Every Commune must be capable of self-defence against
  DDoS, scanning, credential attacks, malware C2, hostile relay use, abuse transit, infrastructure
  attacks, and one Commune using another as an attack platform. The network must support defensive
  behaviour, not only reachability. No Commune is required to relay all traffic, to trust all other
  Communes, or to stay connected during active abuse.

- **The ability to cut infection.** Defence is exercised through scoped, reversible, time-bounded
  cuts (clotting) — over a node, route, transport, bridge, corridor, trust scope, or Commune —
  auditable inside the affected Commune and independent of any global topology. The ability to heal
  requires the ability to clot.

- **No global abuse oracle / no network-wide kill switch.** There must **never** be a global
  authority that can ban nodes or Communes network-wide. Local decisions belong to local Communes.
  Fungi may *sign* warnings ([ADR-0018](adr/0018-fungi-role-and-opt-in-publish.md)); Communes may
  *subscribe to* warnings; Communes may *ignore* warnings; bridge contracts determine which signals
  bind. A global ban power is itself an **S0 attack surface**: it concentrates exactly the coercion
  and centralisation this threat model exists to deny, and a single compromise of it captures the
  whole Mycobiome. This is consistent with the software-not-an-operated-network and consensus-
  governance posture ([ADR-0016](adr/0016-software-releases-not-an-operated-network.md)) and with the
  no-central-collector stance of decentralised observability ([VIS-0006](vision/0006-decentralized-observability.md),
  [ADR-0021](adr/0021-decentralized-observability-not-a-central-collector.md)). Abuse resistance must
  not become a global kill switch.

- **Immune signals reveal the minimum.** Future immune-system signals (abuse, quarantine, cut,
  rate-limit, corridor-revocation, bridge-risk, commune-policy) carry only scope, severity, reason
  code, TTL, evidence class, signer or quorum, and a reversible action hint. They **never** carry raw
  traffic, user identities, locations, or a complete topology map — the same minimisation discipline
  that governs spores and route summaries in the distributed-awareness model
  ([VIS-0003](vision/0003-node-interaction-and-distributed-awareness.md)).

- **Anonymous egress is not a default primitive.** Traffic is sorted into capability classes (local
  control; emergency coordination; messaging; signed-content replication; software updates; real-time
  media; relay; egress; unknown bulk). Higher-risk classes demand stronger trust and stronger
  immunity policy. Anonymous egress and unknown bulk transit are the highest-risk classes and are
  closed by default.

- **Safe-default closed posture.** Default node posture: no open relay; no public egress; no unknown
  third-party transit; no bridge without an explicit trust policy ([Anastomosis bridges](#attack-surface-mycelium-as-an-attack-substrate));
  no topology sharing; rate limits for untrusted scopes; quarantine of suspicious behaviour;
  local/community traffic preferred over external transit. Communes are compatible by protocol, not
  by authority: the Core provides compatibility, Communes provide life, and no global authority owns
  the resulting Mycobiome.

**Canonical rule.** Mycelium is not a universal bypass substrate. It is a Mycobiome of sovereign
Communes that may cooperate, coexist, isolate, defend themselves, and evolve different genetics
without losing interoperability. Mycelium must grow through anything; it must **not** attack through
everything.
merge.

## Unresolved / fundamentally hard problems (honest)

These are not bugs to be fixed later. They are boundaries that all persistent private networks live with.

1. **First-contact bootstrapping.** If a new participant has everything blocked, there is
   nowhere within the network to obtain the first working ingress. Only partial, out-of-band
   mitigations exist: bootstrap configs via file/Bluetooth/Wi-Fi Direct/LAN, well-known CDN
   rendezvous, domain-fronting, physical hand-off. This is the hardest open problem; it has
   a dedicated cross-cutting track in the roadmap.
2. **Sybil attacks and enumeration.** A fully open mesh that anyone can join allows an adversary
   to map it from the inside. Every defence is a trade-off between openness (growth) and
   closedness (security). There is no silver bullet.
3. **The anonymity trilemma.** Low latency, high throughput, and strong anonymity cannot all be
   maximised simultaneously. Pick two for the specific scenario — and communicate this honestly
   to operators and users.
4. **ML-based classification is a moving target.** The adversary learns from traffic statistics;
   the project normalises those statistics. This is ongoing adaptation with no final state — the
   side that adapts faster stays ahead, which is why the adaptation layer (Layer 2) is the heart
   of the project.
5. **Allowlist-only scenario.** If the reachable internet collapses to a whitelist, only
   indispensable CDN fronts and offline/LAN channels survive. The mesh falls back to "at least
   one node in the LAN" — a degraded mode, not full access.

## Legal and operational security (cannot be ignored)

> The full legal and compliance position — including cryptographic-means licensing regimes (in
> some jurisdictions), applicable sanctions regimes, internet-freedom general licences,
> intermediary-liability / mere-conduit / safe-harbour regimes, dual-use export controls, and
> exit-node liability — is maintained in the maintainers' **internal knowledge base (not in this
> public repo)**. Legal questions with architectural consequences are tracked as ADRs
> ([adr/](adr/), §0003+). Below is a summary and its design implications.

Mycelium is a persistent private network, and that activity itself is subject to legal pressure
in some jurisdictions: distribution and operation of persistent private network tools may be
restricted in restrictive environments; pressure is applied to operators and app distribution
platforms; exit nodes may bear liability for transited traffic.

Design implications (not merely a disclaimer):

- **Knowledge minimisation.** Nodes store as little about users as possible; logs are off by
  default; data that is never collected cannot be seized or compelled.
- **Role and jurisdictional separation.** Coordination, ingress, and egress are in different
  hands and under different legal regimes, so that compromising or coercing one actor does not
  expose the rest.
- **Operator protection.** Plausible deniability of participation; clear liability boundaries;
  informed consent for volunteers contributing bandwidth in phases 4–5.
- **User safety above functionality.** If a feature improves convenience at the cost of
  de-anonymisation, it does not ship. User safety is functional requirement #1.

Before operating nodes under any specific legal regime, obtain independent legal assessment for
that jurisdiction.

## What the project does NOT promise

- Not absolute unblockability — fast recovery and path redundancy.
- Not Tor-grade anonymity out of the box — anonymity is configured per scenario and costs
  latency/throughput.
- Not operation under total internet shutdown — some channel must exist (external or at minimum
  a LAN with one mesh node).
- Not "deploy and forget forever" — this is a living system facing a moving target; value
  comes from adaptation speed, not from a final, settled state.
