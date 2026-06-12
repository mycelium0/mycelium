<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Architecture

The architecture is divided into five layers. The layers are stable across phases — what
changes is their **implementation** (from "one node" to "the mesh"), not the contracts between
them. This makes it possible to grow decentralisation incrementally without rewriting everything.

```
┌─────────────────────────────────────────────────────────────────────┐
│ 5. Consumption interface   out of scope — standard off-the-shelf     │
│                            clients connect to standard endpoints      │
├─────────────────────────────────────────────────────────────────────┤
│ 4. Discovery &             who is in the mesh, how to join,          │
│    membership              sybil-resistance, NAT traversal           │
├─────────────────────────────────────────────────────────────────────┤
│ 3. Routing &               path selection ingress→egress, multi-hop, │
│    orchestration           rerouting                                  │
├─────────────────────────────────────────────────────────────────────┤
│ 2. Control plane           keys, configs, block-intelligence,        │
│                            adaptation layer, telemetry               │
├─────────────────────────────────────────────────────────────────────┤
│ 1. Data plane              the tunnel itself + obfuscation:          │
│                            multi-protocol, indistinguishability      │
└─────────────────────────────────────────────────────────────────────┘
```

The central architectural principle: **the control plane and discovery layer must themselves be
persistent and resilient**. A tunnel resistant to network interference is of little use if the config
that bootstraps it is served from a domain that can be cut in under a minute. Management traffic
therefore travels over the same resilient channels as data traffic.

---

## Layer 1. Data plane

The goal is **statistical indistinguishability** from legitimate HTTPS/QUIC — not merely "a
hidden VPN". Multiple transports run in parallel; Layer 3 selects the active one.

### Transport matrix (modern set, current as of June 2026)

The full modern transport set and the rationale for every inclusion and exclusion is recorded in
[ADR-0010](adr/0010-phase0-transport-set.md). **Engine:** **sing-box is the primary engine** (one
server, many protocols); **AmneziaWG** runs as a **separate** non-TLS/UDP path; **Xray-core** is
retained as an **optional alternative engine** for the VLESS+REALITY+Vision shape. Every transport
is **individually toggleable** (per-deployment `group_vars`), so an operator exposes only a chosen
subset and keeps the exposed surface minimal.

| Transport | Basis | Strength | Where it breaks | Role |
|---|---|---|---|---|
| **VLESS + REALITY + XTLS-Vision (TCP)** | TCP/TLS, borrows the handshake of a real donor site | Best survivability against DPI + active probing; Vision equalises TLS record lengths | Targeted blocking events aimed at VLESS-TCP-TLS | **Primary** |
| **VLESS + REALITY + gRPC** | HTTP/2 wrapper over TLS | Survives some conditions that take down bare TCP-TLS; multiplexes through HTTP/2-aware middleboxes | Higher latency cost | First TLS-family fallback |
| **VLESS + REALITY + XHTTP** | HTTP-framed transport over TLS | Resilient where plain streams are disrupted; friendlier to HTTP-shaped paths and CDNs | Higher framing overhead | Second TLS-family fallback |
| **Hysteria2** | QUIC/UDP with aggressive congestion control | Strong on lossy, throttled, high-latency links | Depends on live UDP | UDP-friendly networks |
| **TUIC v5** | QUIC/UDP, low-overhead multiplexing | A second, independent QUIC fingerprint so the QUIC family is not a single point of failure | Depends on live UDP | UDP-friendly networks |
| **Shadowsocks-2022 (AEAD)** | `2022-blake3-aes-256-gcm`, per-session salts | Lightweight non-VLESS shape; independent fallback | Plain TCP shape without a TLS cover on its own | Independent fallback |
| **ShadowTLS v3 (wrapping Shadowsocks-2022)** | Real TLS handshake to an external host in front of Shadowsocks | Outer shape looks like ordinary TLS and answers active probing; inner stays a modern AEAD channel | Targeted TLS-shape blocking | TLS-covered fallback |
| **Trojan over TLS** (optional) | TLS-terminated behind a real certificate | Simple plain-TLS option; independent fallback | Generally dominated by the REALITY shapes | Optional fallback |
| **AmneziaWG** | WireGuard + junk packets, header randomisation, padding (core unchanged) | Fast, ~3 % overhead over WG; non-TLS UDP path that fails differently from every TLS and QUIC shape; each node speaks its own obfuscation dialect | UDP is fully excised in some network environments | Separate non-TLS path |

Excluded as legacy / easily-fingerprinted / superseded (full reasoning in
[ADR-0010](adr/0010-phase0-transport-set.md)): **VMess, plain Shadowsocks (pre-2022), plain
WireGuard, OpenVPN, L2TP/IPsec, PPTP, SSTP, IKEv2.** A CDN-fronted (Cloudflare) path remains
available as a last-resort wrapper around a TLS-family shape.

**Layer principles:**
- The REALITY (and ShadowTLS) cover host is always a real donor: active probing receives a
  legitimate response.
- Diversify **ports, SNI values, donor sites, IPs, and ASes** — blocking can happen at AS level
  (traffic to a "tainted" autonomous system is cut wholesale: the handshake succeeds, the data
  dies).
- Obfuscation parameters (AmneziaWG junk, ClientHello/Reality-Vision padding) are not constants —
  they are tunable values selected by the adaptation layer (Layer 2).
- Each transport is an independent on/off switch: breadth is available, but the surface presented
  to the network is whatever the operator deliberately enables ([ADR-0010](adr/0010-phase0-transport-set.md)).

---

## Layer 2. Control plane + adaptation layer

The brain of adaptation. Evolution: phases 0–2 — a local agent on the node; phase 3 — a fleet
coordinator; phases 4–5 — distributed consensus over gossip.

**Components:**
- **Identity and keys:** issuance and revocation of node/client identities, rotation of
  REALITY parameters, config distribution and updates via the config distribution endpoint.
- **Network-state detector:** diagnoses the channel state as `clean / throttled / DPI-blocked /
  shutdown` from signals (handshake timeouts, TCP RST injection, throughput collapse after a
  successful connect, probing failures, rising loss/jitter).
- **Auto-rotation loop:** on a block event — rotate transport/port/SNI, regenerate REALITY
  parameters, switch IP, fall back to CDN-front as last resort. Includes anti-flapping and
  rollback logic.
- **Telemetry and policy:** anonymised block-event signals feed a policy of "which transports
  are alive where". Optional ML classifier for channel-state estimation (a symmetric answer to the
  adversary's ML-based traffic classification).

**Resilience of the control plane itself:** configs and commands travel via CDN fronts,
domain-fronting, multiple anycast ingress points, and a P2P fallback. The invariant: "data can
outlive management" is unacceptable — management must survive wherever data does.

---

## Layer 3. Routing and orchestration

Path selection from the ingress node to a clean egress, and route reconstruction on block events.

- **Ingress/egress separation:** the ingress node is close to the user (low latency, may have a
  "tainted" reputation); the egress node has a clean reputation. In phases 0–2 they coincide.
- **Rerouting:** if egress E is unreachable from region R, traffic from R is automatically
  redirected to an alternate egress; the path is rebuilt around the failed segment.
- **Multi-hop (phase 4+):** onion/garlic style — ingress → relay → egress; no single hop knows
  the full path. The latency ↔ reachability ↔ anonymity trade-off is selected per scenario.
- **Selection policy:** takes into account geography, node health, current block-intelligence,
  and node trust score (phase 5).

---

## Layer 4. Discovery and membership

How nodes find one another and who is authorised to be in the mesh. This is the project's primary
evolution track.

| Phase | Mechanism | Trust model | NAT traversal |
|---|---|---|---|
| 0–2 | Static config / config distribution endpoint | Operator owns everything | Nodes on public IPs |
| 3 | Coordinator registry (Headscale-style) | Central coordinator issues membership | Coordinator DERP relays |
| 4–5 | DHT + gossip (libp2p Kademlia + GossipSub) | Invitation tree / social graph / PoW | ICE/STUN/TURN, hole-punching, circuit-relay |

**Sybil-resistance** is critical from the moment joining becomes open: without it an adversary
floods the mesh with surveillance nodes, enumerates ingress points, and blocks or de-anonymises
users. The approach is graduated trust: a new node routes little and "knows little"; trust grows
with a verifiable history and valid invitations.

**NAT traversal** is what makes a machine behind a home LAN a full participant: AutoNAT
determines the NAT type, hole-punching establishes a direct connection, and a relay is used as
fallback. This follows the proven volunteer model demonstrated by Snowflake.

---

## Carrier adapters & spore channels (cross-cutting: Layers 1, 2, 4)

Mycelium does not assume that every useful link is continuous, IP-based, high-bandwidth, and
bidirectional. **Any carrier that can move authenticated bytes can be a Mycelium bridge** — and the
carrier *constrains the flow class, it does not define Mycelium*. This principle cuts across the data
plane (Layer 1), the control/adaptation plane (Layer 2), and discovery/membership (Layer 4). The full
decision is recorded in [ADR-0011](adr/0011-carrier-agnostic-bridging.md).

**Carrier adapters are convergence-layer adapters, not new protocols.** Each carrier —
IP over TCP/UDP/QUIC/TLS, LTE/5G and fixed broadband, satellite, Wi-Fi Direct / local Ethernet /
local Wi-Fi, Bluetooth or Bluetooth Mesh, LoRa-style low-rate radio meshes, WebRTC volunteer ingress,
QR code / file / USB / NFC / memory-card hand-off, and future radio or optical links — is wrapped in an
adapter that exposes a **capability + risk descriptor**: maximum safe payload size, expected bandwidth,
latency/delay distribution, intermittent vs. continuous availability, directionality, broadcast/
multicast/unicast behaviour, custody model, deduplication and encryption-envelope support, replay/
expiry support, detectability and collateral-risk class, operator/user risk, and the flow classes the
carrier can safely support. A low-rate carrier is first-class: it may not carry video, but it can carry
bootstrap hints, revocation notices, signed manifests, and small messages. A bridge is never promoted
to a cord (Layer 3) without measurement.

**Spores are compact portable artefacts.** A spore is a small, signed, TTL-bounded, replay-protected
object that is safe to carry across any bridge — including untrusted ones — and useful *without
revealing a full topology map*. Spore types include: bootstrap hints, route capsules, trust
invitations, revocation notices, signed update manifests, stress digests, cache manifests, and delayed
messages. Every spore is signed by an appropriate key, optionally encrypted to a scope or recipient,
bounded by TTL/expiry and replay protection, and safe to duplicate and deduplicate. Spores are the unit
that lets separated islands reconnect through whatever bridge is available.

**Flow-class degradation ladder.** No carrier is forced to support every traffic class. When a carrier
cannot sustain a class, the flow degrades down the ladder rather than failing outright:

`HD video → low video → audio → interactive text/events → delayed message → signed manifest → bootstrap spore`.

Real-time flows require measured route quality; low-rate or intermittent carriers participate through
store/carry/forward and bootstrap semantics. This keeps the network useful at every link quality: when
a high-capacity cord cannot exist, a narrow bridge can still move a signed spore that keeps an island
reachable.

---

## Layer 5. Consumption interface (out of scope)

End-user client applications, client UX, QR/subscription-profile distribution workflows, and
any bespoke client software are **explicitly out of scope** for the current project. Nodes expose
**standard protocol endpoints** (VLESS+REALITY, AmneziaWG, Hysteria2/TUIC, CDN-fronted gRPC)
that are consumed by existing off-the-shelf clients such as sing-box or Clash-Meta. Building a
bespoke client is possible future work, not part of the current roadmap.

The server-side config distribution endpoint (Layer 2) provides a machine-readable bundle of
endpoint addresses, transport priorities, and health metadata that standard clients can consume
without modification.

---

## Recommended stack (build on proven components)

| Purpose | Choice | Rationale |
|---|---|---|
| Tunnel + transport multiplexing | **sing-box** (primary engine); **Xray-core** (optional alternative) | One server, many protocols (REALITY/Vision/gRPC/XHTTP, Hysteria2, TUIC, Shadowsocks-2022, ShadowTLS, Trojan); see [ADR-0010](adr/0010-phase0-transport-set.md) |
| Non-TLS fallback | **AmneziaWG** | Obfuscated WireGuard; each node speaks its own dialect |
| Cover / anti-probing | **Caddy/nginx** + real donor site | Legitimate response to any probe |
| Coordinator (phase 3) | **Headscale** or custom Noise control plane | Proven WireGuard control-plane pattern |
| P2P / mesh (phase 4+) | **libp2p** (Kademlia, GossipSub, AutoNAT, circuit-relay) | Mature DHT/gossip/NAT-traversal primitives |
| Browser ephemeral ingress | **Snowflake** pattern (WebRTC + broker) | Proven volunteer-node model |
| Fronting / last resort | **Cloudflare** (CDN-front, WARP) | Best survivability in combination with REALITY |
| Infrastructure / deploy | **Terraform + Ansible** | Reproducibility; fast IP/AS migration |
| Observability / measurement | **Prometheus/Alertmanager** + **OONI** methodology | Feeds the adaptation layer with real data |
| Control agents | **Go** or **Rust** | Single binary; strong libp2p/sing-box ecosystem |

The project's innovation is **not** a new transport or new cryptography (those are left alone —
that is the canon of [ADR-0002](adr/0002-no-custom-cryptography.md): only standard audited
primitives), but in layers 2–4: adaptation speed, rerouting, and a decentralised
sybil-resistant mesh.
