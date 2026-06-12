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
- **DHT** (Kademlia) — a distributed hash table for peer discovery without a central server.
- **Gossip / GossipSub** — epidemic propagation of messages (reachability, blocking intelligence)
  across the mesh.
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
