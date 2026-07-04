<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Roadmap

The path from a single node to an autonomous, self-healing mesh. Nine phases (0–8). Each phase ships
to production, delivers working access **on its own**, and leaves an artefact (code / infra /
measurements) that the next phase builds on.

Cross-cutting tracks (running through all phases) are described at the end — they cannot be
deferred to "later".

```
Phase 0  Foundation + multi-protocol data plane      1 node, many transports
Phase 1  Distribution + health + failover maturity   1 node, priorities / health / failover
Phase 2  Single-node adaptivity (self-tuning)        1 node: measure→detect→tune→rotate→rollback
Phase 3  Living node — recovery, release,            client recovers e2e; a 2nd operator installs
         fungi/advisory INERT seam  ◀ FIRST RELEASE  from a signed release; advisory + hypha seams (inert)
Phase 4  Node network (per-Commune, no global centre) N own nodes, the operator's OWN coordinator
Phase 5  Decentralisation: the mesh                  N nodes + volunteers; DHT/mesh; NAT'd home box = a node
Phase 6  Autonomous self-healing mesh                heals around blocks, even when part is captured
Phase 7  Carrier-agnostic bridging & spores          DTN store/carry/forward; non-IP carriers; island merge
Phase 8  Biological-flow optimization                local-rule route adaptation at scale (Physarum spirit)
```

Phases 0–6 build the mesh and make it self-heal (the first public release cuts at the end of Phase 3,
the living single node). Phases 7–8 are the later, research- and compute-heavier endgame: bridging
across any carrier, and optimizing flow with biological local rules.

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
  site on Caddy/nginx returns legitimate content to active probing. (For a REALITY-only node the
  external donor *is* the genuine cover under active probing; a self-hosted Caddy/nginx cover site is
  optional defense-in-depth — see [ADR-0020](adr/0020-phase0-scope-reconciliations.md).)
- Key and identity management: UUID issuance/revocation, rotation of REALITY parameters. (REALITY-
  parameter rotation is a **manual** Phase-0 operator procedure
  ([runbooks/reality-rotation.md](runbooks/reality-rotation.md)); automated/triggered rotation is
  Phase 2 — see [ADR-0020](adr/0020-phase0-scope-reconciliations.md).)
- Config distribution endpoint: a single URL/file delivers the node's endpoint bundle (all enabled
  transports) to any compatible off-the-shelf client (sing-box / Clash-Meta format). Bespoke
  client software is out of scope. (Phase 0 uses **local generation + out-of-band hand-off**, not a
  public always-on endpoint, which is itself a scan/fingerprint surface; the matured distribution
  endpoint is Phase 1 — see [ADR-0020](adr/0020-phase0-scope-reconciliations.md).)
- Basic observability: node liveness, per-transport handshake success rate, utilisation, alerts.
  (Node-side producers — liveness + utilisation — are deployed loopback-only; per-transport
  handshake-success and **alerting** are reconciled to the **decentralized** model — the per-operator
  monitor / Phase-2 edge reporting, with **no central cross-operator collector in any phase** — see
  [ADR-0021](adr/0021-decentralized-observability-not-a-central-collector.md) and
  [vision/0006](vision/0006-decentralized-observability.md).)
- Reproducible deployment: one script/Ansible/Terraform playbook stands up a node from scratch.
  (`node-bootstrap.sh` + the Ansible path are the Phase-0 deploy paths; the Terraform path is
  deferred/optional until separately validated — see [ADR-0020](adr/0020-phase0-scope-reconciliations.md).)
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
  removes only that inbound and leaves the others working. ("Independent shapes" = independent
  transport **families**: REALITY/TLS-over-TCP is one family regardless of Vision/gRPC/XHTTP framing;
  the canonical Phase-0 second family is **AmneziaWG/UDP** on every node — see
  [ADR-0020](adr/0020-phase0-scope-reconciliations.md).)
- Active probing of the server returns a genuine donor-site response, not a suspicious one.
- Node is deployed from zero with a single command; a client credential is revoked without
  reinstalling the node.
- No excluded legacy transport (VMess, plain Shadowsocks, plain WireGuard, OpenVPN, L2TP/IPsec,
  PPTP, SSTP, IKEv2) is present on the node ([ADR-0010](adr/0010-phase0-transport-set.md)).

**Risks / notes.** A single node is still a single point of blockage at the IP/AS level — multiple
transports do not change that; node migration (phase 2) and a network (phase 4) address it. Avoid IP
ranges with a known-tainted reputation; keep 1–2 fresh IPs in different ASes in reserve. Keeping
the exposed surface minimal (per-protocol toggling) is the operator's lever against the larger
attack surface that breadth introduces.

---

## Phase 1 — Config distribution + health + failover maturity (≈ 4–6 weeks)

> **Status: CLOSED — GO-signed 2026-06-17** (Phase-1 → Phase-2 transition authorized). The distinctive
> deliverables (genuine single-layer TLS, the two-hop in-region-ingress → out-of-region-egress topology,
> multiplexed REALITY, the self-replenishing subscription seam) were proven on the operator's live
> restrictive link on both LTE and Wi-Fi. Authoritative status + on-device evidence + named deferrals
> (Xray-XHTTP serving path, observability dashboard, Hysteria2/Salamander) are in the
> [Phase-1 acceptance ledger](phase1-acceptance-ledger.md). The **pre-Phase-2 research** is the next gate
> before the Phase-2 detector/measurement track opens.

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
  clients without reinstalling anything; a newly enabled endpoint propagates automatically. The
  `region` metadatum MUST use the same coarse, closed-vocabulary discipline as
  `EdgeReport.RegionBucket` (no precise geo/ASN, drawn from an audited closed set) so the bundle never
  becomes a user-location channel (Audit-0004 F-020).
- **Self-replenishing subscription (the "one link" operator/user experience).** A standard client
  imports a node's subscription **once** and thereafter **self-updates**: rotated parameters
  (port / SNI / shortId / a newly enabled transport) reach the already-imported client on its next
  refresh, with no manual re-import. This is the matured, always-reachable form of the Phase-0
  out-of-band, hand-rendered subscription (which is deliberately *not* self-updating — see
  [ADR-0020](adr/0020-phase0-scope-reconciliations.md)); the subscription channel itself must be at
  least as block-resistant as the data plane it advertises ([refactoring.md](refactoring.md) §15.2).
- **Operator single-profile aggregation across their own nodes.** A cluster operator can carry
  **all** their nodes' endpoints as one profile in a standard client (sing-box / Clash-Meta / Happ),
  with auto-failover across nodes, and have it **self-replenish** as nodes rotate or new nodes come
  online. This is achieved by **client-side aggregation of per-node subscriptions** — each node
  serves only its **own** bundle and the client merges them — **not** by a central endpoint that
  enumerates every node. A single endpoint listing the whole cluster is a coordinator-shaped index
  of all ingress + a one-shot enumeration/coercion target
  (`SINGLE_POINT_OF_BLOCK` / `FORBIDDEN_TOPOLOGY_CENTRALIZATION`, [refactoring.md](refactoring.md) §7,
  §15.2, §15.6) and is prohibited here. The **signed, TTL-bounded, cross-node** form of the same
  convenience is the Inoculum bundle (deferred Phase-3 design,
  [RP-0005](proposals/0005-inoculum-bundle-and-toolkit.md)); Phase 1 ships only the
  standard-subscription self-update plus client-side merge.
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
- A cluster operator imports **one** profile spanning all their nodes (client-side merge of the
  per-node subscriptions) and, when a node rotates parameters or a new node/endpoint is enabled, the
  already-imported client picks up the change on its next refresh **without** a manual re-import —
  and no single artifact enumerates the whole cluster.
- The subscription / config-distribution channel is itself **at least as block-resistant as the data
  plane it advertises** (§15.2): it rides an indistinguishability-preserving transport, with a
  conformance or runbook check proving it does not collapse to a single blockable domain/endpoint
  (Audit-0004 F-022; a `SINGLE_POINT_OF_BLOCK` invariant carried into the Phase-1 RP).

**Risks / notes.** Still a single node/IP — if it is blocked by IP or AS, the fix is node
migration (phase 2). UDP paths are provisioned but not relied upon as the primary route.

---

## Phase 2 — Single-node adaptivity (self-tuning)

> **Status: CLOSED — GO-signed 2026-07-03** (Phase-2 → Phase-3 transition authorized). On a live node the
> node-local `measure → detect → tune → rotate → rollback` loop closed **autonomously**: an induced
> degradation was detected, the impaired streak persisted to the flip threshold under the anti-flap guard,
> the planner emitted a rotation, and the rotation was recorded with the rate/latch limits and rollback
> path in force. Detector decisions are measurable (precision/recall on labelled incidents), and the
> L4-only detection blind spot is closed for the REALITY + genuine-TLS families
> ([ADR-0036](adr/0036-node-local-l7-liveness-probe.md); the detection-fidelity hardening — Audit-0007 S1 +
> all of S2 — is landed and CI-green). Authoritative status + acceptance evidence + named Phase-3
> carry-forwards (end-to-end client recovery, the marker-replay anti-flap hardening, the audit S3/NOTE
> tail, cadence-default tuning) are in the [Phase-2 acceptance ledger](phase2-acceptance-ledger.md).

**Goal.** What operators previously did by hand over hours in response to a blocking event
(migrating VLESS-TCP → REALITY/gRPC/CDN), a **single node does itself in minutes**. Phase 2 is
scoped to exactly one thing: the node-local **measure → detect → tune → rotate → rollback** loop
on one node.

> **Scope (operator directive; roadmap honestly re-phased 2026-07-02).** Phase 2 is **single-node
> adaptivity, and nothing else.** The transport *set* is already universal and closed
> ([ADR-0010](adr/0010-phase0-transport-set.md)); Phase 1's on-device proof confirmed the existing
> shapes suffice ([phase1-acceptance-ledger.md](phase1-acceptance-ledger.md)). Phase 2 adapts the
> **route and behaviour** on one node — it does not grow the protocol list — and it **composes proven
> patterns, does not reinvent** (build-vs-reuse, [ADR-0031](adr/0031-build-vs-reuse-compose-proven-patterns.md)).
> The work Phase 2 originally over-reached into — **end-to-end client recovery, the operability/release
> track, and the advisory/fungi boundary** — is the **new Phase 3** (the re-phasing: Phase 2 grew beyond
> its plan, so it is honestly closed as single-node adaptivity, and its release-and-federation-adjacent
> tail becomes Phase 3; old Phases 3–7 renumber to 4–8). The shell → Go migration
> ([RP-0008](proposals/0008-go-spine-distribution-rendering.md) P3) is a cross-cutting track, not a phase.

**Scope.**
- **Network-state detector** ([RP-0010](proposals/0010-phase2-adaptivity.md)). Classifies the node's
  own channel state from by-product signals: handshake timeouts, TCP RST injection, throughput
  collapse after a successful connect (the AS-level "data dies" pattern), own-cert/cover-path L7
  liveness ([ADR-0036](adr/0036-node-local-l7-liveness-probe.md)), rising loss/jitter. States:
  `clean / throttled / blocked / shutdown`.
- **Auto-rotation loop** ([RP-0012](proposals/0012-phase2-auto-rotation-actuation.md)). On a
  degradation: rotate transport/port/SNI, regenerate REALITY parameters, switch address, fall back to
  a non-degraded shape — under rate limits, anti-flap, and **rollback**, on the node itself.
- **Self-tuning** (A/B obfuscation). AmneziaWG junk-packet parameters, ClientHello padding, packet
  sizes/timings — tuned by survivability feedback (the reinforce-and-evaporate decay law).
- **Node-local diagnosis.** The node classifies its own channel as a **node-local** signal;
  *publishing* it as advisory network weather is Phase 3.

**Stack.** Go control agent ([ADR-0012](adr/0012-go-primary-control-plane-language.md)): the pure
`internal/detect` + `internal/tune` + `internal/measure` + `internal/rotate` spine, `myceliumd`
gated live apply + rollback.

**Definition of Done.**
- An active transport degrades → the node produces a rotation **plan** → **dry-run** preview + gated
  **live apply** work → **rollback** works → stale/noisy signals are **refused** (anti-flap +
  staleness guard). (End-to-end *client* recovery — a stock client recovering unattended — is the
  **Phase-3** bar, not Phase 2.)
- Detector decisions are measurable (precision/recall on labelled incidents).

**Risks / notes.** Telemetry is itself a signal — the node-local signal stays on the node; anything
emitted is aggregate, noised, identity-free (Phase 3, [THREAT-MODEL.md](THREAT-MODEL.md)). ML
amplifies the heuristics, it never replaces them.

**Status. CLOSED — GO-signed 2026-07-03** (Phase-2 → Phase-3 transition authorized;
[phase2-acceptance-ledger.md](phase2-acceptance-ledger.md)). Detector + tuner + measure + planner +
gated rotation + rollback are built and the node-local self-drive **closed autonomously on a live
node**; detection fidelity is hardened (ADR-0036 + Audit-0007 S1/all-S2, CI-green). End-to-end client
recovery, the release track, and the advisory/fungi boundary are **Phase 3**.

---

## Phase 3 — Living node: recovery, release, and the fungi / advisory inert seam (≈ 6–10 weeks)

**Goal.** Turn the self-adapting single node into a **living node an operator can actually run and
share**: a real client recovers end-to-end without human action; a second operator installs a node
from a signed release with no manual fixes; and the **inert seams** for advisory network-weather and
the fungi F2F boundary are in place — with **no live federation runtime**. The first public release
is cut after this phase closes honestly.

**Scope.**
- **End-to-end client recovery** ([RP-0013](proposals/0013-phase3-e2e-client-recovery.md), draft). A stock
  client on a standard subscription, holding a sibling endpoint, survives a real/artificial block and
  recovers within minutes — measured at the **client**, not "node-side serving ok".
- **Operability & release.** `make dist` + signed release; the fungi deploy/management CLI (install,
  status, plan, apply); node diagnostics with a redacted bug-report bundle; the **unified node
  descriptor** — engine/ingress/CDN-front/reachability as default-off *capabilities*, not node variants
  ([ADR-0034](adr/0034-unified-node-profile.md)).
- **Advisory / fungi boundary — INERT SEAM only.** Class-aggregate network weather (no per-node row,
  k-floored, TTL, signed — [ADR-0030](adr/0030-advisory-network-awareness.md)); the **F2F hypha** seam
  — an intra-Commune, same-operator node-to-node bond (edge-fusion), with the constrained introduction
  mechanism ("a fungi MAY introduce, MUST NOT enumerate"; double-opt-in, 1–2-hop depth, TTL, no
  neighbour-list sharing) and the Anastomosis-Bridge / capability-class schemas typed **inert**
  ([ADR-0026](adr/0026-anastomosis-bridges-and-safe-defaults.md)). A *hypha* is the intra-Commune
  counterpart to the cross-Commune **Anastomosis Bridge**; both are contract-bound, never implicit.

**Stack.** The Phase-2 Go spine + the release/packaging surface; the advisory + hypha/bridge schemas
as **inert typed data** ([ADR-0013](adr/0013-mycelial-vocabulary-and-phase-discipline.md)); no gossip,
DHT, or live bridge runtime.

**Definition of Done.**
- A stock client recovers **end-to-end, unattended**, under a real block (repeatable auto-test).
- A **second operator** installs a node from the signed release with **no manual fixes**.
- The advisory-weather + fungi/hypha layers exist as **safe inert seams** — schemas + introduction
  mechanism only, **no live federation**. **First public release cut here.**

**Risks / notes.** The temptation is to light up live federation in this phase — resist it. The live
hypha corridor / bridge runtime, autonomous multi-hop, and any node-to-node discovery are **Phase 4+**.
Reuse proven substrate when federation goes live — **Nebula** (intra-Commune same-CA hypha) + **libp2p**
(NAT'd cross-Commune bridge), chosen in [ADR-0037](adr/0037-federation-transport-substrate.md) (the CA
boundary is the Commune boundary); the Phase-3 inert contract schema defers to it — do not reinvent
([ADR-0031](adr/0031-build-vs-reuse-compose-proven-patterns.md)).

---

## Phase 4 — Node network (≈ 8–12 weeks)

**Goal.** Many nodes **an operator runs, coordinated by that operator for their own Commune** — not a
global centre. True cross-node rerouting and shared block-intelligence *within a Commune* emerge. Each
Commune is self-governed by its node operators ([ADR-0016](adr/0016-software-releases-not-an-operated-network.md),
[ADR-0023](adr/0023-communes-mycobiome-genetics.md)); there is **no central coordinator over the
network as a whole** — only each operator's own, per-Commune control point, an intentionally simple
step before full decentralisation.

**Scope.**
- **Per-Commune coordinator** (Headscale / Nebula-lighthouse pattern; the operator's OWN, never a
  global authority): node registry, config distribution, block-intelligence aggregation within the
  Commune, serving the best ingress to a client by geography/health.
- **Network-level rerouting:** if egress A is unreachable from region R, clients in R are
  automatically redirected to egress B; ingress and egress can be different nodes (ingress is
  nearby, egress has a clean reputation).
- **Shared block-intelligence layer** from phase 2, aggregated across the network: "in region R
  today REALITY on donor D and CDN-front are alive; AmneziaWG is degraded".
- **The coordinator must itself be persistent and resilient:** domain-fronting, multiple anycast
  fronts, CDN distribution, P2P fallback if the coordinator's primary addresses are blocked.
  Otherwise the coordinator becomes a single point of failure.
- Auto-onboarding: a new VPS joins the network with one command and receives its role and config.

**Stack.** Headscale or a custom WireGuard/Noise control plane; block-intelligence gossip;
anycast/CDN fronts for the coordinator itself; service discovery.

**Definition of Done.**
- Nodes join and leave the network on the fly; clients rebalance automatically.
- An AS-level block of an egress node triggers **network-level route migration**, not just
  single-node recovery.
- The coordinator remains reachable when its primary domain is blocked (via fallback channels).

**Risks / notes.** The coordinator is the highest-value target: its compromise exposes the
per-Commune network map. Minimise what it knows; design its replacement starting now (phase 5). This is a
deliberate, tracked technical debt.

---

## Phase 5 — Decentralisation: the mesh (≈ 3–6 months)

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
  reachability ↔ anonymity selected per scenario.
- **Sybil resistance:** invitation trees / social-graph trust / proof-of-work — so an adversary
  cannot flood the mesh with surveillance nodes to enumerate and block ingress points (the
  primary threat for decentralised systems).
- **Ephemeral ingress nodes (Snowflake-style):** a browser or home box acts as a short-lived
  ingress point; ingress points are numerous and short-lived enough that enumerating and blocking
  them is not cost-effective.

**Stack.** libp2p (go-libp2p; a Rust daemon is an allowed backend — ADR-0012): Kademlia DHT, GossipSub, AutoNAT, Circuit-Relay, hole-punching;
WebRTC for browser-based ingress; invitation/trust scheme; onion routing over Noise channels.

**Definition of Done.**
- The mesh continues to operate with the phase 4 coordinator **switched off**.
- A new node behind a home NAT joins the mesh and carries third-party traffic.
- Blocking a set of ingress nodes **does not partition** the mesh; routes converge around the
  failure.
- A controlled sybil injection does not allow the adversary to enumerate the majority of
  ingress points.

**Risks / notes.** Anonymity ↔ throughput ↔ latency: pick two, consciously and per scenario.
DHT/discovery is a prime target for enumeration and flooding; design enumeration resistance from
day one of this phase.

---

## Phase 6 — Autonomous self-healing mesh (ongoing)

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
strongly-anonymous, and perfectly-reachable network does not exist (fundamental trade-offs).
The value is a robust approximation; every prior phase already delivers real access. Each phase
must leave users connected — even if the next phase never ships.

---

## Phase 7 — Carrier-agnostic bridging & spores (research- and engineering-heavy)

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

## Phase 8 — Biological-flow optimization (the science / compute-heavy endgame)

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

**Stack.** Distributed local-rule adaptation over the Phase 5–7 substrate (gossip, scoped trust,
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
Every adaptation must be measurable, bounded, and reversible. The mesh from Phase 6 already delivers
real, self-healing access; Phase 8 makes it more efficient, it is not a precondition for usefulness.

---

## Cross-cutting tracks (through all phases — cannot be deferred)

| Track | Essence | Why it cannot wait |
|---|---|---|
| **Bootstrapping / first contact** | How a node or new participant finds the very first working ingress when everything is blocked: bootstrap configs (file/LAN/Bluetooth/Wi-Fi Direct), CDN rendezvous, domain-fronting | A fundamental limitation of all persistent private networks; without it the mesh "works" only for those already inside |
| **Carrier-agnostic bootstrapping** | Treat any carrier that moves authenticated bytes (IP, LTE/5G, satellite, Wi-Fi Direct, Bluetooth, LoRa-style radio, WebRTC, QR/file/USB hand-off) as a possible bridge for compact signed spores — so first contact and recovery do not depend on continuous IP reachability. Full model in [ADR-0011](adr/0011-carrier-agnostic-bridging.md) | If carrier and spore *interfaces* are not anticipated early, later phases (esp. Phase 7) become a rewrite; the data models must not block future store/carry/forward |
| **Security and anonymity** | De-anonymisation threats, traffic-correlation attacks, node compromise; what a node knows about users | Baked into the protocol from the start — cannot be bolted on later |
| **Measurement** | OONI-style measurements of "what is blocked where and how", replacing guesswork with ground truth. Its public, privacy-preserving surface is the **network-weather explorer** ([vision/0005](vision/0005-network-weather-explorer.md)): opt-in `fungi` nodes emit redacted aggregated digests; the explorer shows fabric health, never a map | Feeds the adaptation layer; without data, adaptation is blind |
| **Advisory network awareness** (operator-local) | The bridge between Phase-2 self-healing and Phase-4 coordination: several self-healing nodes share **signed, class-aggregate, TTL-bound** advisory weather (per-**class** transport health, bundle freshness, degraded coarse buckets) through an operator-local fungi-lite publisher + `cell-pack` (`aggregate --sign --ttl`). **Federation, not coordination** — no map, no coordinator, no per-node row, no transmitted node id, advisory-never-actuates. Decision + the 10 proof gates in [ADR-0030](adr/0030-advisory-network-awareness.md) | Without it the Phase-3 → Phase-4 jump is a cliff (each node heals itself → a per-Commune coordinator, with no rung between). This rides Phase-2 self-healing, gives the inert weather/immunity `internal/spec` schemas their first caller behind proof gates, and tests the future fungi/explorer model **before any mesh exists**. The advisory shape must be class-aggregate by construction — the per-node-digest design reconstructs the network map (rejected, ADR-0030) |
| **Legal and operational security** | Distribution/operation of persistent private network tools is subject to legal pressure in some jurisdictions; exit-node liability; operator and user protection | A legal error is irreversible; detailed legal and compliance analysis is maintained in the maintainers' internal knowledge base |
| **Governance and funding** | Who pays for nodes, how decisions are made, how mesh segments federate | Determines whether the project reaches phases 5–6 |

## Scope discipline (finding MYC-F006)

The advanced mechanisms in this roadmap are **not Phase 0–2 runtime scope**. Specifically,
carrier-agnostic spores, the DHT, trust gradients, learning federation, and autonomous cord promotion
**must not be implemented as running behaviour in Phases 0–2**. Pulling them forward would smuggle in a
master map, a permanent centre, or raw telemetry — exactly what the non-negotiable constraints forbid.

What Phases 0–2 *may* do is define **data models and interfaces only** — and only those that do **not
block** future implementation:

- carrier capability + risk descriptors and spore schemas may be sketched as data models, but no
  store/carry/forward, custody, or non-IP carrier behaviour runs yet (that is Phase 7);
- discovery interfaces may be shaped so they can later be backed by gossip or a DHT, but no DHT runs
  (that is Phase 5);
- trust fields may exist in data models, but no trust gradient drives routing (that is Phase 6);
- telemetry interfaces may be defined, but no learning federation runs and no raw telemetry is
  collected;
- path-weight fields may exist, but no autonomous cord promotion happens without measurement.

The rule: early phases anticipate the future with **inert interfaces**, never with early runtime
behaviour. Each phase's Definition of Done stays coherent and self-contained — a phase is done when its
own DoD is met, not when a later phase's mechanism is half-built inside it.

## Build-vs-reuse: compose proven patterns, do not reinvent (2026-06-17)

Mycelium is viable as an **engineering composition of proven patterns**, not as novel network biology.
Every building block this roadmap needs already has battle-tested prior art; reimplementing them from
scratch lowers the odds. The "fungal" vocabulary stays a **metaphor** for local rules, decay, redundancy,
and scoped trust — never a justification for uncontrolled self-organisation. The rule: where a mature
primitive fits a need, **ADOPT or WRAP** it (license permitting — AGPL-3.0-or-later) rather than BUILD.

Indicative prior art per need (the per-component ADOPT/WRAP/BUILD/DEFER decisions are pinned in
[ADR-0031](adr/0031-build-vs-reuse-compose-proven-patterns.md), informed by the pre-Phase-2 research):

- **P2P substrate** (Phase 4+ peer identity, multi-transport, NAT traversal, hole-punching, relays) — libp2p.
- **Store-carry-forward "spores"** (signed TTL-bounded bootstrap/route/trust/revocation artifacts, NOT the
  data path) — DTN / Bundle Protocol v7 (RFC 9171) thinking; Briar for carrier-agnostic sync.
- **Encrypted self-healing mesh overlay** (Phase 5/6) — Yggdrasil / cjdns.
- **Mature anonymous overlay + the telemetry lesson** — I2P (direct health/latency measurement is a
  identity exposure minefield → indirect/profile-based only; binds [ADR-0025](adr/0025-no-global-abuse-oracle.md)/[ADR-0030](adr/0030-advisory-network-awareness.md)).
- **Volunteer/federated blocking-resistant edges** (ADR-0029) — Tor Snowflake (and its real costs: broker,
  onboarding, abuse, measurement).
- **Local-rule adaptation** (Phase 2 self-tuning) — Physarum/slime-mold work is *optimisation heuristics*
  (exploration budget, reinforcement, decay, local gradients), **not** a deployable routing protocol; take
  the rules, add the threat model / privacy / sybil-resistance ourselves.

**The default conflict to respect everywhere:** self-organisation and blocking-resistance fight by default —
discovery creates an enumeration surface, health telemetry a fingerprinting/deanon oracle, rotation an
observable signal, volunteers sybil/abuse/legal risk. In an ordinary mesh visibility is a feature; in this
one it is a vulnerability. This is *why* the trajectory above is scoped → federated → open-mesh, never
open-mesh-first.

## Immunity, Communes, and sovereign defense across the phases

The operator doctrine — **immunity, temporary cuts, Communes, Anastomosis Bridges, and sovereign
defense** — is canonical (see [GLOSSARY](GLOSSARY.md) and [THREAT-MODEL](THREAT-MODEL.md)). A resilient
network that cannot defend itself becomes an attack substrate: a network that cannot cut infection is
not alive, it is already captured. This doctrine maps onto the phase discipline exactly like every
other advanced mechanism here — **safe-default node posture is current behaviour; the cross-Commune
machinery is inert schema now and live only in Phases 5–6** ([ADR-0013](adr/0013-mycelial-vocabulary-and-phase-discipline.md)).

**Terminology guard.** A **Mycelium Commune** is a *new first-class entity* — a sovereign Mycelium
society (family, company, university, municipal, NGO, emergency-response, state) with its own trust
roots, governance, update/bridge/immunity/observability policies, fungi quorum, and acceptable-use
rules. It is **not** one of the architectural *layer planes* (data plane, control plane, routing plane,
discovery plane), which keep their names unchanged. The collection of all protocol-compatible Communes
is the **Mycobiome** — an ecosystem, not a single owned network. Communes are compatible by protocol,
not by authority.

**Cross-cutting invariant (all phases): no global abuse oracle.** There must **never** be a global
authority capable of banning nodes or Communes network-wide — abuse resistance must not become a global
kill switch. Local decisions belong to local Communes. `fungi` may *sign* warnings ([ADR-0018](adr/0018-fungi-role-and-opt-in-publish.md));
Communes may subscribe to, weigh, or ignore them; bridge contracts alone determine which signals are
binding. This invariant binds every phase below, alongside the existing **never a global kill switch**,
**never a master map**, and **signals never carry raw traffic, identity, location, or a full topology**
constraints ([VIS-0003](vision/0003-node-interaction-and-distributed-awareness.md), [VIS-0006](vision/0006-decentralized-observability.md)).

| Doctrine element | When it is real | Notes |
|---|---|---|
| **Safe defaults / closed-by-default posture** — no open relay; no public egress by default; no unknown third-party transit; no bridge without explicit trust policy; no topology sharing by default; local/community traffic preferred over external transit | **Phase 0–1 (largely already true)** | Follows directly from per-operator credentials ([ADR-0014](adr/0014-per-operator-node-credentials.md)) and the no-open-relay/no-egress data-plane posture. Anonymous egress is **not** a default primitive. |
| **Local rate limits + local quarantine** for untrusted scopes; quarantine suspicious behaviour | **Phase 0–1 node policy** | Per-node, per-operator enforcement; no cross-Commune coordination required, so no membership/trust dependency. |
| **Traffic capability classes** (local control, emergency coordination, messaging, signed content replication, software updates, real-time media, relay, egress, unknown bulk) — higher-risk capabilities require stronger trust and immunity policy | **Phase 0–2 as typed schema; enforced per class as capabilities ship** | Define the class taxonomy as an inert descriptor early; classes gate behaviour only once the relevant transport/relay capability exists. |
| **Inert immune / cut / Commune / bridge schemas** — typed, no runtime behaviour: `abuse_signal`, `quarantine_signal`, `cut_signal`, `rate_limit_signal`, `corridor_revocation`, `bridge_risk_signal`, `commune_policy_signal`; Commune genetics; bridge-contract descriptors | **Phase 0–2 (data models / interfaces only)** | Sketched the same way carrier/spore/discovery/trust schemas are — defined so as **not to block** later implementation, with **no** gossip, membership, or cross-Commune action running ([ADR-0013](adr/0013-mycelial-vocabulary-and-phase-discipline.md)). Signals carry only: scope, severity, reason code, TTL, evidence class, signer/quorum, reversible action hint — **never** raw traffic, identities, locations, or complete topology maps. |
| **Temporary cuts (clotting)** — scoped, reversible, time-bounded, auditable inside the affected Commune, minimally revealing, independent of any global topology — isolating a node, route, transport, bridge, corridor, trust scope, or Commune | **Local cut of a node/route/transport: Phase 1–2** (operator-scoped). **Cut of a bridge / corridor / trust scope / Commune: Phase 5–6** | The ability to heal requires the ability to clot. Local clotting needs no membership; Commune-scoped cuts ride on Phase 5–6 trust/membership. |
| **Live Communes + Commune genetics** (trust roots, accepted signers, governance, bridge/immunity/transport/observability policies, trust-propagation rules) | **Phase 6–7** | Communes are first-class once membership and trust exist; two Communes may run identical software with completely different genetics. |
| **Anastomosis Bridges** — explicit inter-Commune bridges defining trust relationships, allowed/forbidden traffic classes, abuse-propagation/quarantine/revocation/recovery rules, evidence requirements | **Phase 6–7** | **No bridge exists unless explicitly established.** (Distinct from the Phase-8 biological *anastomosis* of local **paths** at §[Phase 8](#phase-8--biological-flow-optimization-the-science--compute-heavy-endgame); a Bridge is a governed inter-Commune contract, not a fused route.) Builds on carrier-agnostic bridging ([ADR-0011](adr/0011-carrier-agnostic-bridging.md)). |
| **Immune signals in flight + cross-Commune cuts** — gossiped abuse/quarantine/cut/revocation signals; subscription and weighting per bridge contract | **Phase 6–7** | Requires gossip/DHT and trust gradient; honours the no-global-abuse-oracle invariant — signals are advisory unless a bridge contract makes them binding. |
| **Governance / quorum / federation** — Commune governance, fungi quorum, how Communes cooperate, coexist, isolate, specialise, or evolve independent genetics | **Phase 6–7** | Decentralised and consensus-based; global Mycelium does not own Communes ([ADR-0016](adr/0016-software-releases-not-an-operated-network.md)). |

**Sovereign defense (cross-cutting posture).** Every Commune must be *capable* of self-defense —
accepting educational/emergency/update traffic while rejecting anonymous relay, unknown egress, bulk
scanning, or specific bridges, and quarantining suspicious nodes. No Commune is required to relay all
traffic, to trust all other Communes, or to remain connected during active abuse. These are
policy-driven choices, never controlled by a global authority. The closed-by-default end of this
posture is **already** the Phase-0–1 node default above; the Commune-scoped policy engine that makes it
expressive arrives with membership in Phases 5–6.

**Canonical rule.** Mycelium is not a universal bypass substrate. It is a Mycobiome composed of
sovereign Communes: the Core provides compatibility, Communes provide life. Communes may cooperate,
isolate, defend themselves, and evolve different genetics; no global authority owns the Mycobiome.
Mycelium must grow through anything — and must **not** attack through everything.

## Phase-transition principle

Do not begin phase N+1 until phase N has met its Definition of Done **in production with real
users**. The mesh is built on top of working access, not instead of it. Each phase must leave
users connected — even if the next phase never ships.
