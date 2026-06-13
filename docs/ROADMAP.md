<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Roadmap

The path from a single node to an autonomous, self-healing mesh. Eight phases (0–7). Each phase ships
to production, delivers working access **on its own**, and leaves an artefact (code / infra /
measurements) that the next phase builds on.

Cross-cutting tracks (running through all phases) are described at the end — they cannot be
deferred to "later".

```
Phase 0      Phase 1        Phase 2          Phase 3          Phase 4          Phase 5
Foundation → Distribution → Adaptation    → Fleet with    → Decentrali-   → Autonomous
+ multi-     + health +     layer           centralised      sation:          self-healing
protocol     failover       (self-tuning)   coordination     mesh             mesh
data plane   maturity                                                          (incl. under
1 node       1 node,        1–N nodes,     N own nodes,    N nodes +        capture)
many         priorities/    self-tuning    coordinator     volunteers,      any machine
transports   health/        + IP migration DHT/mesh         a node           in a LAN = a node
             failover
                                  Phase 6                       Phase 7
                              → Carrier-agnostic           → Biological-flow
                                bridging & spores             optimization
                                DTN store/carry/forward,      local-rule route
                                non-IP carriers,              adaptation at scale
                                island merge                  (Physarum/fungal-flow
                                                              spirit)
```

Phases 0–5 build the mesh and make it self-heal. Phases 6–7 are the later, research- and
compute-heavier endgame: bridging across any carrier, and optimizing flow with biological local rules.

Timelines are relative (team of 1–3). These are directions, not deadlines.

---

## Phase 0 — Foundation + multi-protocol data plane (≈ 4–6 weeks)

**Goal.** A single VPS provides stable access through several independent transport "shapes" at
once, so the loss of any one shape does not end access. Establish the engineering discipline that
everything else depends on.

> **Scope note.** Phase 0 now ships the **multi-protocol data plane** — this pulls forward what was
> previously Phase 1's transport breadth. A node that speaks only one transport is one failure
> surface; the foundation is stronger when the first node already offers independent shapes. The
> transport set, the engine choice, and the per-protocol toggling are recorded in
> [ADR-0010](adr/0010-phase0-transport-set.md). Phase 1 accordingly shifts to maturing
> config-distribution, health, and failover (see below).

**Scope.**
- One egress node running the **modern transport set** on **sing-box (primary engine)** —
  individually toggleable per deployment via `group_vars` so the operator exposes only a chosen
  subset (minimal exposure): VLESS+REALITY+XTLS-Vision (TCP), VLESS+REALITY+gRPC,
  VLESS+REALITY+XHTTP, Hysteria2 (QUIC/UDP), TUIC v5 (QUIC/UDP), Shadowsocks-2022 AEAD,
  ShadowTLS v3 wrapping Shadowsocks, and Trojan over TLS (optional).
- **AmneziaWG** (obfuscated WireGuard) provisioned as a **separate** non-TLS/UDP path.
- **Xray-core (≥ v26.2.4)** retained as an **optional alternative engine** for the
  VLESS+XTLS-Vision+REALITY shape (the existing `nodes/dataplane/vless-reality/` path is kept).
- REALITY (and ShadowTLS) shapes point at a real TLS donor site; behind the node a genuine cover
  site on Caddy/nginx returns legitimate content to active probing.
- Key and identity management: UUID issuance/revocation, rotation of REALITY parameters.
- Config distribution endpoint: a single URL/file delivers the node's endpoint bundle (all enabled
  transports) to any compatible off-the-shelf client (sing-box / Clash-Meta format). Bespoke
  client software is out of scope.
- Basic observability: node liveness, per-transport handshake success rate, utilisation, alerts.
- Reproducible deployment: one script/Ansible/Terraform playbook stands up a node from scratch.
- Hosting selection with attention to **AS-level blocking** (do not concentrate everything in
  one tainted AS).

**Stack.** sing-box (primary, transport multiplexing) with AmneziaWG as a separate path and
Xray-core as an optional alternative engine; Caddy/nginx; Terraform + Ansible; Prometheus +
Alertmanager; standard off-the-shelf clients (sing-box/Clash-Meta) consume the config distribution
endpoint. Engine and protocol versions pinned to concrete tags (see
[dependency-policy.md](dependency-policy.md)).

**Definition of Done.**
- A user with a restrictive network connection retrieves the config endpoint and reaches the
  open internet over an enabled transport.
- At least two independent transport shapes are reachable at once; disabling one in `group_vars`
  removes only that inbound and leaves the others working.
- Active probing of the server returns a genuine donor-site response, not a suspicious one.
- Node is deployed from zero with a single command; a client credential is revoked without
  reinstalling the node.
- No excluded legacy transport (VMess, plain Shadowsocks, plain WireGuard, OpenVPN, L2TP/IPsec,
  PPTP, SSTP, IKEv2) is present on the node ([ADR-0010](adr/0010-phase0-transport-set.md)).

**Risks / notes.** A single node is still a single point of blockage at the IP/AS level — multiple
transports do not change that; node migration (phase 2) and a fleet (phase 3) address it. Avoid IP
ranges with a known-tainted reputation; keep 1–2 fresh IPs in different ASes in reserve. Keeping
the exposed surface minimal (per-protocol toggling) is the operator's lever against the larger
attack surface that breadth introduces.

---

## Phase 1 — Config distribution + health + failover maturity (≈ 4–6 weeks)

**Goal.** The multi-protocol node from Phase 0 already speaks several transport "dialects"; Phase 1
makes the **distribution, health, and failover** around them mature. The config distribution
endpoint captures all enabled transports with priority ordering and health metadata, standard
clients failover automatically, and block visibility emerges: *what exactly* is being blocked.

> **Scope note.** The transports themselves were introduced in Phase 0 (see
> [ADR-0010](adr/0010-phase0-transport-set.md)). Phase 1 does **not** re-introduce them; it focuses
> on making the endpoint bundle, per-transport health signalling, prioritisation, and
> client-side failover production-grade, and on adding diversification and a CDN-fronted last
> resort.

**Scope.**
- **Config distribution endpoint** (server-side) matured: delivers the client a bundle of all
  enabled endpoints with **priorities and metadata** (transport, region, health). Updates reach
  clients without reinstalling anything; a newly enabled endpoint propagates automatically.
- **Per-transport health and failover:** per-endpoint metrics (handshake success rate,
  time-to-first-byte, connection resets) feed the bundle's health metadata so standard clients
  fail over between the Phase 0 transports cleanly.
- Port and SNI diversification; multiple donor sites across the enabled shapes.
- A **CDN-fronted** path (Cloudflare) added as a last-resort wrapper around a TLS-family shape.
- UDP-friendly transports (Hysteria2 / TUIC) are surfaced in the bundle but flagged as
  conditional, with the understanding that UDP is excised entirely in some environments.

**Stack.** The Phase 0 engines (sing-box primary; AmneziaWG separate; Xray optional);
sing-box/Clash-Meta config distribution format; Cloudflare as CDN front; per-endpoint health
collection feeding the bundle.

**Definition of Done.**
- When one transport is blocked, standard clients switch to a working one **within the same
  node** with minimal user-visible disruption.
- The dashboard shows per-transport state, e.g. "VLESS-TCP degraded in region X, AmneziaWG alive".
- A new endpoint enabled server-side propagates to clients through the config distribution
  endpoint without manual intervention, with correct priority and health metadata.

**Risks / notes.** Still a single node/IP — if it is blocked by IP or AS, the fix is node
migration (phase 2). UDP paths are provisioned but not relied upon as the primary route.

---

## Phase 2 — Adaptation layer and self-tuning (≈ 6–10 weeks)

**Goal.** What operators previously did by hand over hours in response to a blocking event
(migrating VLESS-TCP → REALITY/gRPC/CDN), the node does **itself in minutes**. This is the
core of the adaptation layer.

**Scope.**
- **Network-state detector.** Classifies the channel state from signals: handshake timeouts,
  TCP RST injection, throughput collapse after a successful connect (the AS-level "data dies"
  pattern), active-probing failures, rising loss/jitter. States:
  `clean / throttled / DPI-blocked / shutdown`.
- **Auto-rotation loop.** On a block event: rotate transport/port/SNI, regenerate REALITY
  parameters, bring up/switch to a fresh IP, fall back to CDN-fronted path as last resort. All
  without human intervention, with rate limits and rollback.
- **Telemetry and online learning.** Nodes (and, with opt-in consent, anonymised signals from
  connected clients) send block events. These build a policy of "which transport is alive where
  right now". The same dataset drives an **optional ML classifier** for channel-state estimation
  (a symmetric answer to the adversary's ML-based traffic classification): not "guess the
  protocol", but "diagnose the channel faster and more accurately".
- **A/B obfuscation self-tuning.** AmneziaWG junk-packet parameters, ClientHello padding
  (Reality-Vision), packet sizes and timings — tuned by survivability feedback.

**Stack.** Lightweight control agent on the node (Go — ADR-0012); telemetry queue; signal store;
optional online classifier; IP provider integration for fast address rotation.

**Definition of Done.**
- Artificially blocking the active transport → clients recover **without human action** within
  single-digit minutes; the node publishes a block event with diagnosis.
- Transport-selection policy differs by region and updates from telemetry.
- Detector decisions are measurable (precision/recall on labelled incidents); anti-flapping and
  false-migration protection is in place.

**Risks / notes.** Telemetry is itself a signal and an attack surface — aggregate, add noise, do
not tie to identity (see [THREAT-MODEL.md](THREAT-MODEL.md)). ML amplifies the heuristics; it
does not replace them: heuristics must work without ML.

---

## Phase 3 — Node fleet with centralised coordination (≈ 8–12 weeks)

**Goal.** Many **owned** nodes under unified management. True cross-node rerouting and shared
block-intelligence emerge. This is a "proto-mesh" with a centre — an intentionally simple step
before decentralisation.

**Scope.**
- **Coordinator** (Headscale / Nebula-lighthouse pattern): node registry, config distribution,
  block-intelligence aggregation, serving the best ingress to a client by geography/health.
- **Fleet-level rerouting:** if egress A is unreachable from region R, clients in R are
  automatically redirected to egress B; ingress and egress can be different nodes (ingress is
  nearby, egress has a clean reputation).
- **Shared block-intelligence layer** from phase 2, aggregated across the fleet: "in region R
  today REALITY on donor D and CDN-front are alive; AmneziaWG is degraded".
- **The coordinator must itself be persistent and resilient:** domain-fronting, multiple anycast
  fronts, CDN distribution, P2P fallback if the coordinator's primary addresses are blocked.
  Otherwise the coordinator becomes a single point of failure.
- Auto-onboarding: a new VPS joins the fleet with one command and receives its role and config.

**Stack.** Headscale or a custom WireGuard/Noise control plane; block-intelligence gossip;
anycast/CDN fronts for the coordinator itself; service discovery.

**Definition of Done.**
- Nodes join and leave the fleet on the fly; clients rebalance automatically.
- An AS-level block of an egress node triggers **fleet-level route migration**, not just
  single-node recovery.
- The coordinator remains reachable when its primary domain is blocked (via fallback channels).

**Risks / notes.** The coordinator is the highest-value target: its compromise exposes the
network map. Minimise what it knows; design its replacement starting now (phase 4). This is a
deliberate, tracked technical debt.

---

## Phase 4 — Decentralisation: the mesh (≈ 3–6 months)

**Goal.** Remove the mandatory centre. Nodes discover one another, maintain a shared map, and
route **without a single point of control**. This phase also admits **home machines behind NAT**
as full participants.

**Scope.**
- **Membership and discovery:** DHT + gossip (libp2p Kademlia + GossipSub) replacing the
  coordinator registry. Nodes publish reachability, health, and block signals into the mesh.
- **NAT traversal:** ICE/STUN/TURN, hole-punching, DERP-style relays — making a machine in a
  home LAN behind NAT a full node (ingress / relay), following the proven volunteer model of
  Snowflake.
- **Multi-hop routing:** onion/garlic style (ingress → relay → egress) so that blocking or
  compromising one hop neither exposes the full path nor collapses access. Trade-off: latency ↔
  unblockability ↔ anonymity selected per scenario.
- **Sybil resistance:** invitation trees / social-graph trust / proof-of-work — so an adversary
  cannot flood the mesh with surveillance nodes to enumerate and block ingress points (the
  primary threat for decentralised systems).
- **Ephemeral ingress nodes (Snowflake-style):** a browser or home box acts as a short-lived
  ingress point; ingress points are numerous and short-lived enough that enumerating and blocking
  them is not cost-effective.

**Stack.** libp2p (go-libp2p; a Rust daemon is an allowed backend — ADR-0012): Kademlia DHT, GossipSub, AutoNAT, Circuit-Relay, hole-punching;
WebRTC for browser-based ingress; invitation/trust scheme; onion routing over Noise channels.

**Definition of Done.**
- The mesh continues to operate with the phase 3 coordinator **switched off**.
- A new node behind a home NAT joins the mesh and carries third-party traffic.
- Blocking a set of ingress nodes **does not partition** the mesh; routes converge around the
  failure.
- A controlled sybil injection does not allow the adversary to enumerate the majority of
  ingress points.

**Risks / notes.** Anonymity ↔ throughput ↔ latency: pick two, consciously and per scenario.
DHT/discovery is a prime target for enumeration and flooding; design enumeration resistance from
day one of this phase.

---

## Phase 5 — Autonomous self-healing mesh (ongoing)

**Goal.** The target property: reliable private connectivity for the people and groups who need
it, given some internet connectivity and **at least one reachable mesh node (including one in the
same LAN)**. The mesh senses blocks and routes around them without central coordination — and it
keeps healing even when part of the mesh has been **captured or taken over**.

**Scope.**
- **Autonomous self-healing:** nodes locally detect blocks and rebuild routes; there is no
  global dispatcher — behaviour is emergent from local rules and gossip.
- **Self-healing under capture / takeover attempts.** The mesh must survive not only blocking
  from the outside but compromise from the inside. When a node is captured, coerced, or behaving
  as if taken over, the mesh: **detects** the compromised/coerced node from local signals
  (anomalous routing, route-poisoning attempts, stress patterns, failed verification);
  **quarantines** it so it carries no scoped traffic; **revokes scoped trust** through signed
  revocation spores; **decays poisoned routes** so reinforced-but-bad paths lose weight;
  **reroutes around the captured region** using path diversity; and **never crowns a permanent
  centre** — no node, after recovery, becomes an irreplaceable coordinator. Recovery returns the
  mesh to a decentralised steady state, not to a new single point of control.
- **Reputation and trust:** a trust gradient suppresses malicious or malfunctioning nodes
  without a centre; protection against route-poisoning and Eclipse attacks.
- **Shared capacity:** home nodes contribute a share of their bandwidth; fairness accounting
  and anti-abuse controls.
- **Trivial node joining:** one script turns any machine into an auto-joining node;
  LAN-discovery (mDNS) allows a neighbour on the same local network to serve as ingress when
  the external internet is cut.
- **First-contact bootstrapping:** how a new participant whose internet is fully blocked finds
  the first working ingress — out-of-band bootstrap configs (file/LAN/Bluetooth/Wi-Fi Direct),
  well-known CDN rendezvous, domain-fronting. This is the hardest open problem; it has its
  own cross-cutting track in the roadmap.
- **Governance and federation:** how communities operate their own mesh segments and how
  those segments interconnect.

**Definition of Done (measurable, not a slogan).**
- The mesh survives the loss of X % of nodes and targeted blocking with a bounded **recovery
  time SLO**.
- A new participant whose internet is fully blocked obtains a working first ingress within an
  acceptable time via at least one out-of-band channel.
- A node brought online in a LAN provides access to the rest of the local network even when the
  external uplink degrades.
- A captured or coerced node injected into the mesh is detected, quarantined, and stripped of
  scoped trust within a bounded time; poisoned routes decay; traffic reroutes around the captured
  region; and no surviving node becomes a permanent centre.

**Risks / notes.** This is an asymptote, not a checkbox: a simultaneously fast, high-capacity,
strongly-anonymous, and perfectly-unblockable network does not exist (fundamental trade-offs).
The value is a robust approximation; every prior phase already delivers real access. Each phase
must leave users connected — even if the next phase never ships.

---

## Phase 6 — Carrier-agnostic bridging & spores (research- and engineering-heavy)

**Goal.** Let separated islands reconnect through **any carrier that can move authenticated bytes**,
not only continuous IP links. The mesh keeps working across intermittent, low-rate, and non-IP
carriers, and two islands that meet can merge safely without exposing their full topologies. This phase
turns the carrier-agnostic doctrine of [ADR-0011](adr/0011-carrier-agnostic-bridging.md) into running
behaviour.

**Scope.**
- **DTN store/carry/forward.** Delay-/disruption-tolerant operation: a node accepts custody of
  spores, carries them while disconnected, and forwards them when a bridge becomes available.
  Deduplication, TTL/expiry, and replay protection are enforced end to end.
- **Non-IP carriers as convergence-layer adapters.** Carrier adapters for satellite, Wi-Fi Direct,
  Bluetooth / Bluetooth Mesh, LoRa-style radio, WebRTC, and physical hand-off (QR / file / USB / NFC /
  memory card), each exposing a capability + risk descriptor. The carrier constrains the flow class;
  it does not become a separate protocol.
- **Spore artefacts in production.** Compact, signed, TTL-bounded, replay-protected spores —
  bootstrap hints, route capsules, trust invitations, revocation notices, signed manifests, stress
  digests, cache manifests, delayed messages — flow across bridges and are safe to carry through
  untrusted custody.
- **Island merge with scoped signed summaries.** When two previously separated islands discover a
  bridge, they reconcile through **scoped, signed route/health summaries**, never a full topology
  exchange. Merge is incremental, trust-scoped, and metadata-minimised.
- **Flow-class degradation ladder applied per carrier.** A carrier is used only for flow classes it
  can safely support; flows degrade down the ladder (HD video → … → bootstrap spore) instead of
  failing.

**Stack.** Carrier adapter interfaces and spore schemas first defined as data models in earlier
phases (see scope-discipline note below), then backed by DTN convergence-layer logic; standard signing
and encryption primitives only (no custom cryptography, per [ADR-0002](adr/0002-no-custom-cryptography.md)).

**Definition of Done.**
- Two islands with no shared IP path reconnect through at least one non-IP carrier by exchanging
  signed spores.
- A spore survives a store/carry/forward hop through untrusted custody: it is replay-protected,
  deduplicated, and rejected after TTL expiry; a mutated or stale spore is detected and dropped.
- An island merge completes using scoped signed summaries only; neither side gains a full topology
  map of the other.
- A narrow, intermittent carrier is correctly restricted to bootstrap/manifest/delayed-message flow
  classes and is never promoted to a real-time cord without measurement.

**Risks / notes.** Low-rate carriers leak metadata if scopes and summaries are too rich — minimise
ruthlessly. Malicious custody (store-and-drop, mutation), spore replay, and route-capsule poisoning are
first-class attacks (see [THREAT-MODEL.md](THREAT-MODEL.md)). Do not over-trust satellite or radio
carriers as "safe by default".

---

## Phase 7 — Biological-flow optimization (the science / compute-heavy endgame)

**Goal.** Optimize routing and capacity allocation with **local rules in the spirit of Physarum and
fungal flow networks** — bounded exploration, reinforcement of useful paths, fusion of independent
paths, pruning and decay of unused ones, and stress memory — operating at mesh scale without any global
optimizer. This is the most research- and compute-heavy phase; it refines, rather than replaces, the
self-healing mesh.

**Scope.**
- **Local-rule route adaptation at scale.** Each node adapts its routing weights from local
  measurements and scoped gossip, in the flow-network spirit: paths that repeatedly carry useful flow
  are reinforced; paths that fail or fall silent decay. No node runs a global optimizer; global
  structure emerges from local signals.
- **Bounded exploration.** Each node spends a small, rate-limited budget probing alternative paths,
  carriers, and bridges — weak hyphae — never enough to reveal more topology than needed.
- **Fusion and pruning.** Independent local paths fuse (anastomosis) when fusion improves resilience
  without concentrating knowledge; stale, unverified, or unused topology is pruned as metabolism, not
  punishment.
- **Stress memory at scale.** Redacted, scoped, decaying stress signals bias future growth toward
  demand, scarcity, and trustworthy regions, and away from regions with a history of failure or
  capture — without exposing users.
- **Decay everywhere.** Every edge, route, reputation signal, bridge capability, and bootstrap hint
  carries age and decay semantics, so the optimized network never ossifies around stale state.

**Stack.** Distributed local-rule adaptation over the Phase 4–6 substrate (gossip, scoped trust,
carrier adapters, spores); measurement and simulation (netem/netsim, flow-network models) to validate
that local rules converge to good global behaviour. Heuristics must work without ML; any learning is an
amplifier, not a dependency, and uses only approved redacted inputs.

**Definition of Done.**
- Under realistic stress (node loss, blocking, capture, intermittent carriers), local-rule adaptation
  converges to routing that is measurably better than static selection, with a bounded convergence
  time and no global optimizer.
- Reinforcement, fusion, pruning, and decay are individually observable and reversible; a bad
  reinforcement decision is detected and decayed away.
- Stress memory measurably steers growth away from a previously captured or failure-prone region
  without retaining any user-identifying data.

**Risks / notes.** This is an asymptote and the heaviest research bet: convergence, stability, and
oscillation (flapping) are real risks, and "biological" is a design metaphor, not a correctness proof.
Every adaptation must be measurable, bounded, and reversible. The mesh from Phase 5 already delivers
real, self-healing access; Phase 7 makes it more efficient, it is not a precondition for usefulness.

---

## Cross-cutting tracks (through all phases — cannot be deferred)

| Track | Essence | Why it cannot wait |
|---|---|---|
| **Bootstrapping / first contact** | How a node or new participant finds the very first working ingress when everything is blocked: bootstrap configs (file/LAN/Bluetooth/Wi-Fi Direct), CDN rendezvous, domain-fronting | A fundamental limitation of all persistent private networks; without it the mesh "works" only for those already inside |
| **Carrier-agnostic bootstrapping** | Treat any carrier that moves authenticated bytes (IP, LTE/5G, satellite, Wi-Fi Direct, Bluetooth, LoRa-style radio, WebRTC, QR/file/USB hand-off) as a possible bridge for compact signed spores — so first contact and recovery do not depend on continuous IP reachability. Full model in [ADR-0011](adr/0011-carrier-agnostic-bridging.md) | If carrier and spore *interfaces* are not anticipated early, later phases (esp. Phase 6) become a rewrite; the data models must not block future store/carry/forward |
| **Security and anonymity** | De-anonymisation threats, traffic-correlation attacks, node compromise; what a node knows about users | Baked into the protocol from the start — cannot be bolted on later |
| **Measurement** | OONI-style measurements of "what is blocked where and how", replacing guesswork with ground truth. Its public, privacy-preserving surface is the **network-weather explorer** ([vision/0005](vision/0005-network-weather-explorer.md)): opt-in `fungi` nodes emit redacted aggregated digests; the explorer shows fabric health, never a map | Feeds the adaptation layer; without data, adaptation is blind |
| **Legal and operational security** | Distribution/operation of persistent private network tools is subject to legal pressure in some jurisdictions; exit-node liability; operator and user protection | A legal error is irreversible; detailed legal and compliance analysis is maintained in the maintainers' internal knowledge base |
| **Governance and funding** | Who pays for nodes, how decisions are made, how mesh segments federate | Determines whether the project reaches phases 4–5 |

## Scope discipline (finding MYC-F006)

The advanced mechanisms in this roadmap are **not Phase 0–2 runtime scope**. Specifically,
carrier-agnostic spores, the DHT, trust gradients, learning federation, and autonomous cord promotion
**must not be implemented as running behaviour in Phases 0–2**. Pulling them forward would smuggle in a
master map, a permanent centre, or raw telemetry — exactly what the non-negotiable constraints forbid.

What Phases 0–2 *may* do is define **data models and interfaces only** — and only those that do **not
block** future implementation:

- carrier capability + risk descriptors and spore schemas may be sketched as data models, but no
  store/carry/forward, custody, or non-IP carrier behaviour runs yet (that is Phase 6);
- discovery interfaces may be shaped so they can later be backed by gossip or a DHT, but no DHT runs
  (that is Phase 4);
- trust fields may exist in data models, but no trust gradient drives routing (that is Phase 5);
- telemetry interfaces may be defined, but no learning federation runs and no raw telemetry is
  collected;
- path-weight fields may exist, but no autonomous cord promotion happens without measurement.

The rule: early phases anticipate the future with **inert interfaces**, never with early runtime
behaviour. Each phase's Definition of Done stays coherent and self-contained — a phase is done when its
own DoD is met, not when a later phase's mechanism is half-built inside it.

## Phase-transition principle

Do not begin phase N+1 until phase N has met its Definition of Done **in production with real
users**. The mesh is built on top of working access, not instead of it. Each phase must leave
users connected — even if the next phase never ships.
