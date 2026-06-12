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
| Active probing | data plane / node | Donor site returns a legitimate response; no extraneous ports or banners |
| IP-level / AS-level blocking | node | IP/AS diversity, fast rotation, CDN-front, ephemeral ingress nodes |
| UDP excision | transport | TCP/TLS paths are primary; UDP is a bonus |
| Block of the config distribution domain | control plane | Domain-fronting, anycast, P2P fallback, out-of-band bootstrap configs |
| Sybil / ingress enumeration | discovery | Invitation trees, social-graph/history trust, PoW, graduated knowledge |
| Eclipse / route poisoning | discovery / routing | Reputation scoring, peer diversity, verifiability |
| Traffic-timing correlation | routing | Multi-hop, padding, mixing (at latency cost) |
| Node compromise | full stack | Minimal node knowledge; ingress/egress separation; forward secrecy |
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
