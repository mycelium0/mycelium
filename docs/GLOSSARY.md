<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Glossary

Brief definitions of project terms. For deeper treatment see
[ARCHITECTURE.md](ARCHITECTURE.md), [THREAT-MODEL.md](THREAT-MODEL.md),
and [research/](research/).

## Network interference and DPI

- **DPI** (Deep Packet Inspection) — deep analysis of packets to classify or block traffic by
  signature or statistical fingerprint.
- **Transit-layer inspection appliances** — large-scale DPI hardware deployed at traffic
  exchange points; inspects and blocks traffic in transit.
- **ML-based traffic classification** — identifying "this is a VPN" from flow statistics
  (sizes / timings / entropy) rather than a fixed signature; the answer is statistical
  **indistinguishability**.
- **Active probing** — the network adversary directly connects to a suspicious server and checks
  whether it behaves as the claimed cover site. Countered by REALITY + a live cover site.
- **AS-level / IP-range blocking** — cutting traffic to an entire autonomous system (the
  handshake completes; data silently dies).
- **Protocol allowlisting** — a mode in which only an approved list of services is reachable
  (e.g. during a network shutdown); everything else is unreachable.
- **UDP/QUIC throttling** — selective rate-limiting or dropping of UDP traffic, degrading
  QUIC-based transports.

## Transports and private connectivity

- **VLESS** — a lightweight proxy protocol in the Xray/sing-box ecosystem; delegates encryption to TLS.
- **REALITY** — masquerades as a TLS handshake with a real third-party donor site; survives
  active probing.
- **XTLS-Vision** — equalises TLS record lengths (ClientHello padding) against
  length-fingerprinting; the recommended flow for VLESS+REALITY over TCP.
- **gRPC transport** — wraps the VLESS stream in HTTP/2; multiplexes cleanly through HTTP/2-aware
  middleboxes and survives some conditions that disrupt bare TCP/TLS streams.
- **XHTTP transport** — a modern HTTP-framed transport (successor to earlier HTTP-upgrade
  transports); resilient where plain streams are disrupted and friendlier to HTTP-shaped paths and
  CDNs.
- **Hysteria2** — a QUIC/UDP transport with aggressive congestion control; effective on lossy,
  throttled, or high-latency links.
- **TUIC** (v5) — a QUIC/UDP transport with low-overhead multiplexing; provides a QUIC fingerprint
  independent of Hysteria2 so the QUIC family is not a single point of failure.
- **Shadowsocks-2022** — the modern AEAD construction of Shadowsocks (e.g.
  `2022-blake3-aes-256-gcm`) with per-session salts; replaces the easily-fingerprinted pre-2022
  Shadowsocks.
- **ShadowTLS** (v3) — a wrapper that presents a genuine TLS handshake to a real external host in
  front of an inner shape (e.g. Shadowsocks-2022): the outer shape looks like ordinary TLS and
  answers active probing, while the inner stays a modern AEAD channel.
- **Trojan** — a simple proxy protocol terminated behind a real TLS certificate; presents as
  ordinary TLS to an external observer.
- **AmneziaWG** — a WireGuard fork with obfuscation (junk packets, header randomisation, padding);
  the cryptographic core is unchanged. A non-TLS UDP path that fails independently of TLS and QUIC
  shapes.
- **Domain fronting** — connecting to a large CDN with an innocuous SNI and a different Host
  header; increasingly difficult but still viable in some environments.
- **Refraction / decoy routing** — maintaining reachability via a cooperative router (TapDance,
  Conjure): traffic "turns" toward a blocked resource at a friendly ISP.
- **Pluggable transport** — a swappable obfuscation layer (obfs4, meek, Snowflake) on top of a
  base channel.
- **Cover site / donor** — a real website behind the proxy that returns a legitimate response to
  probing.

## Mesh and P2P

- **Snowflake** — a Tor transport: broker + ephemeral WebRTC proxies contributed by volunteers;
  a reference model for distributed relay meshes.
- **DHT** (Kademlia) — a distributed hash table for peer discovery without a central server
  (Phase 3-4; not run in Phase 0-2).
- **Gossip / GossipSub** — epidemic propagation of messages (reachability, blocking intelligence)
  across the mesh (Phase 3-4; not run in Phase 0-2).
- **NAT traversal / hole-punching** — establishing a direct connection through NAT
  (ICE/STUN/TURN) so that a non-public machine can become a node.
- **Multi-hop / onion routing** — a path ingress→intermediate→egress where no single hop knows
  the full route.
- **Bootstrap config / join token** — the configuration bundle or credential that a new node
  uses to come online and join the mesh.
- **Link** — an encrypted channel between two nodes.
- **Rerouting** — redirecting traffic around a failed or blocked link or node; the core
  resilience mechanism of the mesh.
- **Egress node** — a node with a reachable exit to the open internet.

## Mycelial doctrine

These are the load-bearing metaphors of the fabric (VIS-0002). A mycelial term is used only where
it defines a real contract — a schema, a state machine, a policy rule, or a measurable behavior.

- **Spore** — a signed, TTL-bounded portable artifact carried across any bridge. Compact,
  replay-bounded, and carrier-agnostic. May carry bootstrap hints, route capsules, trust
  invitations, revocation notices, signed update manifests, stress summaries, cache manifests,
  delayed messages, or emergency-coordination messages. Must never carry raw traffic, full
  topology maps, complete peer lists, user identities, private content, or persistent behavioral
  profiles (VIS-0002 §3).
- **Cord** — a promoted path or path-set with measured usefulness and reversible demotion. A cord
  is reinforced because measurement shows it is useful, and it is demoted back when usefulness
  decays; promotion is never autonomous before measurement (Phase 7).
- **Hyphal probe** — a bounded, cheap exploration probe. The metabolically inexpensive unit of
  "explore cheaply": a single low-cost reach attempt with strict bounds, not an open-ended scan.
- **Gradient** — a measured bias affecting exploration or routing. A directional field derived
  from measurement (e.g. toward under-served scopes) that biases where growth, caching, and route
  exploration go; it never carries identity and is never a global map.
- **Stress memory** — redacted, scoped failure history with retention and decay. Remembers that a
  scope was stressed without leaking who, what, or raw suspicion; bounded by retention and decay
  policy, and never promoted to a global signal (see Compartment wound response).
- **Topology fragment** — a TTL-bounded, scoped partial local topology — never a full map. A
  bounded slice of the local neighbourhood picture, expiring on its TTL; no node and no
  coordinator ever holds the global topology (VIS-0003 §2).
- **Anastomosis** — the fusion of two exploring paths into a shared, useful connection ("fuse
  where useful"); the contract-level event behind candidate edges becoming active.
- **Decay** — ordinary, measured aging of an edge or artifact toward demotion (route-flap-damping
  style: exponential decay with hysteresis), distinct from active pruning.
- **Pruning (metabolism)** — active reduction of over-dense topology to improve convergence, lower
  enumeration surface, and increase useful dispersion — not merely stale cleanup.
- **Bridge / carrier** — any carrier that can move authenticated bytes; the carrier constrains the
  flow class but does not define Mycelium (VIS-0002 §2).
- **Flow class / flow-class degradation ladder** — the measured quality tier a carrier supports,
  and the graceful downgrade sequence from interactive/real-time flows down to a single bootstrap
  spore as conditions degrade.
- **Island** — a separated fabric fragment that is not dead: it keeps local discovery, messaging,
  cache, service registry, emergency coordination, and delayed sync (VIS-0002 §4).
- **Island merge** — reconnection of two islands through any bridge by exchanging signed scoped
  summaries first, requesting only missing in-scope artifacts, never full maps.

## Distributed awareness

- **Distributed awareness** — the local, trust-scoped, replicated neighbourhood picture; no node
  and no coordinator ever holds the global topology (VIS-0003 §2). Phase 3-4 territory.
- **Import-inert-until-validated** — the rule that any imported artifact (spore, fragment, summary)
  has no effect on local state until it passes validation; receipt alone never mutates the fabric.
- **Anti-entropy (repair)** — periodic reconciliation that lets a node self-heal scoped state from
  neighbour caches; the replication path, distinct from lookup, and a cumulative-enumeration
  surface that uses graduated disclosure and trust-scoped reconciliation.
- **Coordinator** — a Phase-3 temporary, scoped centre that dissolves into the Phase-4 DHT;
  present but inert in Phase 0 (VIS-0003). Never a permanent centre.

## Network weather (public measurement surface)

The sanctioned **public** way to expose the fabric's condition: aggregated, privacy-preserving, and
**never a map or directory** (VIS-0005). It projects the redacted distributed-awareness signals into a
surface that cannot be reversed into topology, membership, geography, or identity.

- **Network weather** — the public snapshot of the fabric's health: an overall resilience index,
  per-transport-**class** health and reachability, coarse interference classes, the edge-lifecycle
  distribution as percentages, and obfuscated rotation events. Carries opaque scope ids — never a node,
  endpoint, location, or user (VIS-0005). The opposite of a blockchain explorer: no tier ever holds the
  global map.
- **fungi (role)** — a node in a temporary, rotating `cache-custodian`-class niche (a `NodeRole`, not a
  permanent class) that aggregates its own neighbourhood's redacted signals, applies the aggregation
  floor and noise **at the source**, forgets the raw inputs, and emits a signed, TTL-bounded
  stress-digest spore. Opt-in only; aggregate-and-forget (VIS-0005).
- **Stress-digest** — the signed, TTL-bounded `SporeEnvelope` a fungi emits: a redacted, floored,
  noised aggregate of neighbourhood stress. The unit the explorer publisher ingests; never raw
  observations (VIS-0005).
- **Aggregation floor (`k`)** — the minimum-aggregation threshold below which a cell is omitted (never
  shown as zero), applied at the source so the published surface stays impossible to reverse into a map
  (VIS-0005; the exact `k` is pinned by the spawned ADR).
- **Explorer publisher / snapshot** — the off-network step that verifies digests, coarsens across
  sources, suppresses below-floor cells, and emits a static `network-weather.json`; the explorer site
  renders only that snapshot and adds no visitor tracking (VIS-0005).

## Selective Growth and the surviving-path pattern

The current-posture deployment pattern for a high-interference path, and the principle that governs it:
**the mycelium does not grow where it is not needed.** The tunnel carries only the traffic whose native
path is impaired; everything natively reachable routes direct. The path that survives is one that never
traverses the high-interference border filter — in-region ingress, with out-of-region egress carried
node-to-node (an anastomosis hop), never user-direct to an out-of-region node. The manual operator-built
two-hop and the per-client split-tunnel here are **current-posture** deployment patterns (allowed now);
their *automated* cross-node selection and route-set assembly are Phase 3-5 (gossip/route promotion), not
near-term node behaviour.

- **Selective Growth** — the principle that the tunnel carries **only** traffic whose native path is
  impaired, while natively-reachable destinations route direct (split-tunnel by default): *the mycelium
  does not grow where it is not needed.* It is the routing-discipline expression of the same restraint as
  the closed-by-default safe defaults (ADR-0026) and "Mycelium is not a universal bypass substrate"
  (ADR-0016): reach is extended exactly where direct reach is degraded, and nowhere else, which minimises
  exposed surface, cost, and the amount of traffic an observer can attribute to the tunnel. **Engine
  note:** domain-aware split (the geo-routing of the xray-class transports) is the precise instrument for
  this; CIDR-only transports (the WireGuard-class / AmneziaWG) can only approximate it via region-exclude
  route sets. The manual operator-built form is current posture; automated selection is Phase 3-5.
- **In-region ingress** — an entry node reached over an **in-region path**, so the user's first hop never
  crosses the high-interference border filter. The user connects to a node whose path is native-reachable;
  the impaired out-of-region reach is taken on **behind** the ingress, node-to-node, not from the user's
  device. Pairs with out-of-region (node-hop) egress to form the surviving path.
- **Out-of-region (node-hop) egress** — out-of-region reach carried **node-to-node** from an in-region
  ingress to an out-of-region node, so the impaired border filter is crossed by the inter-node hop and
  **never user-direct**. A user-direct connection to an out-of-region node hits the border filter and is
  degraded as a class (see destination-AS throughput degradation); carrying that egress over an
  anastomosis hop is the path that survives. Distinct from the closed-by-default *anonymous egress*, which
  is not a default primitive (ADR-0026): this is an operator's own consented two-hop, not open egress for
  an unidentified third party.
- **Destination-AS throughput degradation** — a download-direction throughput filter applied to
  out-of-region egress ranges by **destination AS / subnet as a class** (the handshake completes, then the
  download direction is throttled — e.g. a short burst then a freeze), rather than a clean block of one
  host. Because it hits out-of-region hosters and CDNs **as a class**, fronting via any out-of-region CDN
  does not help — and a TLS-terminating CDN additionally discloses the user's source address and the
  destination hostnames to a third party. The surviving answer is a path that never traverses the
  border filter at all (in-region ingress + node-hop egress), not a different out-of-region front. The
  download-direction sibling of **AS-level / IP-range blocking** (where the handshake completes and data
  silently dies); here the path is **impaired**, not cleanly cut.
- **Anastomosis hop (egress)** — the inter-node hop that carries out-of-region egress for an in-region
  ingress: the deployment-level instance of **anastomosis** ("two exploring paths fuse where useful")
  applied to the egress leg, so the impaired path is crossed node-to-node and never user-direct. The
  manual operator-built form (a deliberate two-hop an operator stands up) is **current posture**;
  *automated* discovery and promotion of such a hop is Phase 3-5, and a hop that crosses **between**
  Communes is an **Anastomosis Bridge** governed by an explicit contract (ADR-0026), not an implicit
  route.

## Mycelial schemas (`internal/spec`)

Typed control-plane schemas formalising the doctrine above. Each is a data model with `Validate()`
only — no running behavior. All are inert in Phase 0-2 (VIS-0003 §4 phase discipline); signature
references use standard primitives via a key-id string plus signature bytes, never a custom scheme
(ADR-0002).

- **SporeEnvelope** — the signed, TTL-bounded wrapper around a spore payload: type, scope, issue
  and expiry timestamps, replay bound, and key-id/signature reference (typed schema; inert in
  Phase 0-2).
- **StressSignal** — a redacted, scoped failure observation backing stress memory: scope, signal
  speed class, and decay-bounded retention; carries no identity or raw suspicion (typed schema;
  inert in Phase 0-2).
- **TopologyFragment** — a TTL-bounded, scoped partial topology slice; never a full map (typed
  schema; inert in Phase 0-2).
- **TransportHealth** — fast, volatile per-edge health used for routing input (e.g. link state,
  measured quality); the fastest signal speed class (typed schema; inert in Phase 0-2).
- **GradientSignal** — a measured bias field toward under-served scopes that influences
  exploration and routing; carries no identity (typed schema; inert in Phase 0-2).
- **EdgeState** — the edge lifecycle state value:
  `candidate → probed → active → reinforced → cord → degraded → (dormant | scarred) → decayed → pruned`,
  where `dormant` (inactive but cheaply re-testable) and `scarred` (dangerous/suspicious, needs
  stronger evidence before reuse) are first-class lifecycle members carrying the failure semantics of
  concept 6 (typed schema; inert in Phase 0-2).
- **CordPromotion** — the record promoting a path or path-set to a cord on measured usefulness,
  with the demotion condition that makes it reversible (typed schema; inert in Phase 0-2).
- **DecayPolicy** — the retention-and-decay parameters governing how edges, artifacts, and stress
  memory age toward demotion or pruning (exponential decay with hysteresis) (typed schema; inert
  in Phase 0-2).
- **TrustScope** — the bounded scope within which an artifact, signal, or priority applies;
  contribution may raise local scoped priority but never global reputation or tokenomics (typed
  schema; inert in Phase 0-2).
- **SignalSpeedClass** — the speed/corroboration tier of a signal: fast volatile health → routing;
  medium aggregated stress summaries → exploration bias; slow corroborated → trust;
  threshold-signed hard → revocation/quarantine (typed schema; inert in Phase 0-2).
- **NodeRole** — a temporary niche a node may occupy (frontier probe, stable anchor, cache
  custodian, bridge carrier, relay candidate, cord endpoint); a niche, not a permanent class
  (typed schema; inert in Phase 0-2).

## Security and anonymity

- **Sybil attack** — flooding the mesh with fake nodes in order to enumerate ingress points or
  de-anonymise traffic.
- **Eclipse attack** — isolating a node by surrounding it with adversary-controlled nodes
  (route/neighbour poisoning).
- **Enumeration** — systematic discovery by an adversary of the mesh's ingress points for
  blocking.
- **Indistinguishability** — statistical resemblance of traffic to legitimate HTTPS/QUIC; a
  stronger goal than "obfuscation".
- **fail-closed** — on failure the system does not "leak" past its security boundary; it reports
  "no connection" and stops.
- **Anonymity trilemma** — it is not possible to simultaneously have low latency, high
  throughput, and strong anonymity; the design picks two.
- **Adaptation layer** — the self-tuning subsystem (network-state detector + auto-rotation +
  measurements) that adapts the mesh's configuration in near-real time; replaces what previously
  required hours of manual intervention.

## Legal and operational concepts

- **mere-conduit / safe-harbour** — the legal principle that a transit intermediary (relay) bears
  no liability for traffic it carries, as recognised in various intermediary-liability regimes.
- **dual-use export controls** — controls on goods and software with both civilian and military
  applications; published open-source software typically qualifies for a general licence exemption
  in most jurisdictions, but applicable rules vary.
- **Applicable sanctions regimes** — jurisdiction-specific asset-freeze and service-restriction
  rules that operators must assess for their own situation; Mycelium makes no representation about
  compliance in any particular jurisdiction.
- **Cryptographic-means licensing** — in some jurisdictions, developing, producing, or
  distributing software that performs encryption may require a licence from a national authority;
  operators should assess applicable rules for their deployment context.

## Immunity, Communes, and the Mycobiome

The doctrine that a resilient fabric must also be able to defend itself: resilience without immunity
turns a network into an attack substrate. Builds on opt-in publish + cache-custodian custody
(ADR-0018), trust scope / spore / knowledge gradient (VIS-0003), carrier-agnostic bridging (ADR-0011),
cords (VIS-0004), decentralized observability with no central collector (VIS-0006/ADR-0021),
per-operator credentials (ADR-0014), and software-not-an-operated-network with consensus governance
(ADR-0016). The cross-Commune machinery (bridges, immune signals, cross-Commune trust) is Phase 4-5
with inert schema hooks definable now (ADR-0013); local safe defaults, rate limits, and quarantine are
already-true Phase-0 node posture.

- **Commune** (Mycelium Commune) — a sovereign Mycelium society: a deployment with its own trust
  roots, governance, update policy, bridge policy, immune system, observability policy, fungi quorum,
  and acceptable-use rules. Examples: a family, company, university, municipal, NGO,
  emergency-response, or state Commune. Global Mycelium does not own Communes; they are first-class
  entities, compatible by protocol and not by authority. **Distinct from the layer "planes"** — the
  architectural layers (data plane, control plane, routing plane, discovery plane) are unchanged and
  are NOT renamed; a Commune is a governed *society*, not a layer.
- **Mycobiome** — the collection of all protocol-compatible Communes. Not a single network but an
  ecosystem: Communes may cooperate, coexist, remain isolated, specialize, and evolve independently
  without losing interoperability. The Core provides compatibility; Communes provide life. No global
  authority owns the Mycobiome.
- **Commune Genetics** — a Commune's defining profile: trust roots, accepted signers, governance
  rules, bridge policies, immunity policies, transport policies, observability policies, and trust
  propagation rules. Two Communes may run identical software while having completely different
  genetics; compatibility is by protocol, not by shared authority.
- **Anastomosis Bridge** — an explicit, contracted link between two Communes (the inter-Commune form
  of anastomosis — "fuse where useful"). A bridge defines trust relationships, allowed and forbidden
  traffic classes, abuse-propagation rules, quarantine rules, revocation rules, recovery rules, and
  evidence requirements. Default rule: **no bridge exists unless explicitly established** (Phase 4-5;
  inert schema hooks definable now).
- **Immunity** — a Commune's capacity to defend itself rather than optimize for universal
  availability at any cost. A Commune must be capable of protecting against DDoS traffic, scanning,
  credential attacks, malware command-and-control, hostile relay use, abuse transit, infrastructure
  attacks, and one Commune using another as an attack platform. No Commune is required to relay all
  traffic, to trust all other Communes, or to remain connected during active abuse.
- **Temporary Cut / Clotting** — a scoped, reversible, time-bounded isolation that a living fabric
  uses to stop the spread of harm, as an organism clots a wound. A cut may isolate a node, route,
  transport, bridge, corridor, trust scope, or Commune. Cuts must be scoped, reversible,
  time-bounded, auditable inside the affected Commune, minimally revealing, and independent of any
  global topology. Rule: **the ability to heal requires the ability to clot.**
- **Immune Signal** — a future-phase control signal carrying a defensive decision, not data:
  `abuse_signal`, `quarantine_signal`, `cut_signal`, `rate_limit_signal`, `corridor_revocation`,
  `bridge_risk_signal`, `commune_policy_signal`. A signal must **NEVER** contain raw traffic, user
  identities, locations, or complete topology maps. A signal **should** contain scope, severity,
  reason code, TTL, evidence class, signer or quorum, and a reversible action hint (Phase 4-5; inert
  schema hooks definable now).
- **Sovereign Defense** — the principle that every Commune may set and enforce its own defensive
  posture: accepting (e.g.) educational, emergency, or update traffic while rejecting anonymous relay,
  unknown egress, bulk scanning, or specific bridges, and quarantining suspicious nodes. These
  choices are policy-driven and local — never controlled by a global authority.
- **Global Abuse Oracle (forbidden)** — the explicitly prohibited notion of a global authority able
  to ban nodes or Communes network-wide. There must **NEVER** be one. Local decisions belong to local
  Communes; fungi may sign warnings, Communes may subscribe to or ignore them, and bridge contracts
  determine which signals are binding. Rule: **abuse resistance must not become a global kill switch.**
- **Traffic Capability Class** — the risk-graded category of a flow, used to gate it against trust
  and immunity policy: local control, emergency coordination, messaging, signed-content replication,
  software updates, real-time media, relay traffic, egress traffic, and unknown bulk traffic.
  Higher-risk capabilities require stronger trust and stronger immunity policies. Anonymous egress is
  **not** a default primitive.
- **Safe Defaults** — the closed-by-default node posture: no open relay; no public egress by default;
  no unknown third-party transit by default; no bridge without an explicit trust policy; no topology
  sharing by default; rate limits for untrusted scopes; quarantine for suspicious behavior; and
  local/community traffic preferred over external transit. Largely already-true Phase-0 posture
  (per-operator credentials, no open relay/egress).
