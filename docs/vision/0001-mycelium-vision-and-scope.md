<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Mycelium: Resilient-Access Mesh

## Metadata
- **ID:** VIS-0001
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (founding vision of the project)
- **Horizon:** Phase 0–5 (see [../ROADMAP.md](../ROADMAP.md))
- **Layer(s):** cross-cutting
- **Related:** [../ROADMAP.md](../ROADMAP.md), [../ARCHITECTURE.md](../ARCHITECTURE.md),
  [../THREAT-MODEL.md](../THREAT-MODEL.md)

## 1. Problem and Context

Many networks are unreliable: outages, congestion, packet loss, and interference are everyday
conditions for the communities, researchers, journalists, NGOs, families, distributed teams, and
infrastructure operators who depend on them. Restrictive networks are one case of this broader
problem. By mid-2026 the most restrictive environments combine transit-layer inspection appliances
at exchange points with ML-based traffic classification of encrypted traffic, AS-level and
IP-range blocking, near-complete suppression of unidentified UDP, and protocol allowlisting during
partial outages. Unadapted protocols are fragile under these conditions (OpenVPN fingerprinted
quickly, vanilla WireGuard soon after). Details are in
[../THREAT-MODEL.md](../THREAT-MODEL.md); research digests and preprint analysis are maintained
in the maintainers' internal knowledge base. Network interference is a moving target — what helps
most is the speed of adaptation and redundancy of paths, not any single "perfect" protocol.

## 2. Vision

An information layer that helps households, people, and organizations keep reliable, private control
of their own connectivity: a decentralized, self-healing **mesh** of nodes that coordinates and
reroutes autonomously. The target property for a user: reliable private connectivity for the people
and groups who need it, wherever networks are unreliable — available as long as some channel to the
network exists and at least one working mesh node is reachable (including within the same local
network).

> **Distant, out-of-scope aspiration.** A fully community-run, peer-to-peer connectivity layer is a
> far-future direction, conceivable only after the mesh is decentralized. It is explicitly out of
> current scope and noted here as a horizon, not a promise.

## 3. Governing Principles

- [x] **Do not invent cryptography or transports** — Xray/sing-box, AmneziaWG, libp2p, patterns
  from Snowflake/Headscale ([../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md)).
- [x] **Indistinguishability > obfuscation** — statistical resemblance to legitimate HTTPS/QUIC.
- [x] **Redundancy by default** — multiple protocols, ports, SNIs, IPs, and ASes.
- [x] **Degrade, do not fail** — losing a node or coordinator slows the mesh; it does not shut
  it down.
- [x] **User safety is function #1** — opsec and legal considerations are addressed from the
  start, not deferred.

## 4. Scope

### In scope
- Multi-protocol self-tuning node → fleet → decentralized mesh (phases 0–5).
- Adaptation layer ("online adaptation"): network interference detection + auto-rotation + measurement.
- Home nodes behind NAT joining the mesh; ephemeral ingress; multi-hop.
- Standard protocol endpoints served by the node and consumed by off-the-shelf clients.

### Out of scope (now)
- Custom cryptography or transports; a from-scratch anonymizing network at the level of Tor.
- Total offline scenarios (some channel is required — external or LAN).
- Guarantees of staying reachable under every condition (this is an asymptote; see §7).
- Any end-user **client application**: client UX, QR/subscription-profile distribution, or a
  bespoke client. Nodes expose **standard protocol endpoints consumed by existing off-the-shelf
  clients**; a bespoke client is explicitly out of scope (possible future work).
- A fully community-run, peer-to-peer connectivity layer (a distant horizon; see §2).

### Deferred
- Decentralized discovery/mesh → Phase 4; autonomous self-healing → Phase 5.

## 5. Target Audience and Scenarios

- **Who:** communities and community infrastructure · researchers · journalists · NGOs · families ·
  distributed and remote teams · a non-technical end user on a restrictive network · a node operator ·
  a volunteer running a home machine behind NAT · a community maintaining a mesh segment.
- **Scenarios:** joining via a single bootstrap config / join token · auto-recovery during a
  period of heavy interference · first contact when most paths are blocked · a node joining from a
  home LAN · keeping a local segment connected through an outage.

## 6. Assets and Trade-offs

- **Protected assets:** user identity/location · traffic content · reachability of ingress
  nodes · operators · network topology map.
- **Conscious trade-offs:** the anonymity trilemma (latency ↔ capacity ↔ anonymity — choose
  2 of 3 per scenario); openness ↔ sybil-resistance; indistinguishability ↔ cost/latency;
  speed of adaptation ↔ risk of false relocation; centralization (simplicity in Phase 3) ↔
  decentralization (resilience in Phase 4).
- **Accepted technical debt:** the Phase 3 coordinator as a target — plan to dissolve it in
  Phase 4.

## 7. Definition of Done (measurable, not a slogan)

- [ ] The network survives the loss of X% of nodes and targeted blocking with a **bounded
  recovery time** (SLO).
- [ ] A newcomer whose usual paths are blocked obtains a first working ingress within an acceptable
  window via at least one out-of-band channel.
- [ ] A node on one LAN provides access to the rest of that local network even when the external
  link is degraded.
- [ ] When the active transport is artificially blocked, clients recover without human
  intervention within single-digit minutes.

## 8. Measurability and Observability

Signals that feed the adaptation layer: handshake success rate, TTFB, connection drops,
detector precision/recall on labeled incidents, recovery time, fraction of ingress nodes that
survive targeted blocking. OONI-style measurements must be established early — without data,
adaptation is blind.

## 9. Dependencies and Prerequisites

- **Stack/infra:** Cloudflare/CDN, a provider supporting rapid IP rotation, hosting in "clean"
  ASes, libp2p, Headscale.
- **Cross-cutting tracks (cannot defer):** bootstrapping, security, measurement, law/opsec,
  governance/funding.

## 10. Risks and Open Questions

- **Strategic:** allowlist-only scenarios, ongoing adaptation against ML-based classification, sybil
  enumeration of ingress nodes.
- **Fundamentally hard (honest, not "we'll fix it"):** the first-contact problem; sybil-
  resistance vs openness; the anonymity trilemma.
- **Open questions → research/RFC:** network interference detector thresholds; auto-rotation policy;
  mesh trust model.

## 11. What Becomes Possible Next

Each phase leaves users with access and serves as the foundation for the next: single node →
fleet → mesh → autonomous self-healing network. The mesh is built **on top of** what is already
working, not as a replacement.

## 12. Next Steps

- [x] ADRs for key decisions ([../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md),
  [../adr/0003-licensing-and-jurisdiction.md](../adr/0003-licensing-and-jurisdiction.md)).
- [x] First RP ([../proposals/0001-bootstrap-phase-0-node.md](../proposals/0001-bootstrap-phase-0-node.md)).
- [ ] Research note on open detector/rotation questions ([../research/](../research/)).
- [ ] Event-driven audit when adding a new layer (Phase 3/4) — [../refactoring.md](../refactoring.md).
