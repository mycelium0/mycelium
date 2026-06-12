<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0010: Phase 0 Modern Transport Set and Engine Selection

## Metadata
- **ID:** ADR-0010
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** data plane (primarily), touching control plane (per-protocol toggling, config distribution)
- **Phase:** Phase 0 (see [../ROADMAP.md](../ROADMAP.md)); transport breadth pulled forward from Phase 1
- **Related:** [ADR-0001](0001-record-architecture-decisions.md),
  [ADR-0002](0002-no-custom-cryptography.md),
  [../ARCHITECTURE.md](../ARCHITECTURE.md) Layer 1,
  [../ROADMAP.md](../ROADMAP.md) Phase 0 / Phase 1,
  [RP-0001](../proposals/0001-bootstrap-phase-0-node.md),
  [../dependency-policy.md](../dependency-policy.md)

## Context

The Phase 0 node bootstrap ([RP-0001](../proposals/0001-bootstrap-phase-0-node.md)) brought up a
single transport: VLESS + XTLS-Vision + REALITY on Xray-core. That is the highest-reachability
TCP/TLS option, but a node that speaks only one transport has a single failure surface: when that
one shape is identified and blocked, access stops. Operators serving communities, researchers,
journalists, NGOs, families, and distributed teams over unreliable, restrictive, high-interference,
or disaster-prone networks need a node that can offer several independent transport "shapes" so
that the loss of one does not end connectivity.

What prompts the decision now: deciding **which** transports the data plane standardises on (and
which it deliberately excludes), and **which engine** terminates them, is an architecturally
significant choice that touches the transport protocol matrix and the external stack dependency
set — the exact triggers that require an ADR ([ADR-0001](0001-record-architecture-decisions.md)).
Leaving it implicit invites ad-hoc per-deployment drift and re-litigation.

- **Adversary model** (see [../THREAT-MODEL.md](../THREAT-MODEL.md)): DPI signature matching,
  ML-based traffic classification, active probing, IP/AS-level blocking, and UDP/QUIC throttling
  or full UDP removal. No single transport answers all of these at once — TCP/TLS shapes survive
  active probing well but share a fate under AS-level blocking; QUIC/UDP shapes excel on lossy
  links but vanish where UDP is excised; a non-TLS UDP path (AmneziaWG) covers a different gap
  again. Breadth is the answer to "what happens when this one shape stops working".
- **Affected asset:** ingress reachability (primarily) and, indirectly, user identity/location —
  every transport must preserve the indistinguishability and no-custom-crypto invariants so that
  breadth never comes at the cost of a weak shape.
- **Fundamental trade-off:** indistinguishability ↔ cost/latency, and exposure ↔ resilience.
  More transports means more resilience but a larger attack surface and more to operate. The
  resolution is per-protocol toggling (see Decision): operators opt in to exactly the subset they
  need, keeping the exposed surface minimal while the breadth remains available.

This decision concerns transport selection and obfuscation **shaping** only. Confidentiality
remains held exclusively by standard audited primitives as provided by upstream
([ADR-0002](0002-no-custom-cryptography.md)); nothing here introduces, forks, or hand-rolls a
cryptographic primitive.

## Considered Options

1. **Stay single-transport (VLESS+REALITY+Vision only)** — option 0, leave as is.
   - Pros: smallest surface to operate and audit; the strongest single TCP/TLS shape.
   - Cons: one shape is one failure surface — identifying and blocking it ends access; no
     UDP-friendly path for lossy links; no non-TLS fallback when TLS shapes are degraded.
   - Impact on indistinguishability / survivability: indistinguishability stays strong, but
     survivability is brittle: a single block event is terminal until manual migration.

2. **A broad, modern, individually-toggleable transport set on a primary multi-protocol engine,
   with a separate non-TLS UDP path and an optional alternative engine** (chosen).
   - Pros: independent shapes spanning TCP/TLS, HTTP/2, HTTP-framed, QUIC/UDP, and non-TLS UDP, so
     the loss of one shape leaves others working; each transport toggled on or off per deployment
     to keep exposure minimal; all shapes built only on audited upstream primitives.
   - Cons: more to configure, observe, and keep version-pinned; a larger potential surface if an
     operator enables everything (mitigated by per-protocol toggling and minimal-exposure defaults).
   - Impact on indistinguishability / survivability: each included shape independently targets
     indistinguishability from ordinary HTTPS/QUIC; survivability rises markedly because blocking
     must take down several independent shapes rather than one.

3. **Add legacy transports too (VMess, plain Shadowsocks, plain WireGuard, OpenVPN, etc.) for
   maximum compatibility** (rejected).
   - Pros: works with the widest range of old clients.
   - Cons: these shapes are easily fingerprinted or have known detectable signatures, dragging
     down the node's overall indistinguishability and offering an adversary an easy classification
     handle; superseded by modern equivalents that are strictly better.
   - Impact on indistinguishability / survivability: a single easily-fingerprinted inbound can
     taint the node's reputation and its IP/AS, undermining the strong shapes sharing that address.

## Decision

**Option 2.** The Phase 0 data plane standardises on the modern transport set below, terminated by
**sing-box as the primary engine**, with **AmneziaWG as a separate non-TLS/UDP path** and
**Xray-core retained as an optional alternative engine**. Every protocol is **individually
toggleable** via `group_vars` so an operator exposes only a chosen subset.

### Included transports (the modern set) and why each

| # | Transport | Family | Why it is in the set |
|---|---|---|---|
| 1 | **VLESS + REALITY + XTLS-Vision (TCP)** | TCP/TLS | Highest-reachability TCP/TLS shape; borrows a real donor handshake so active probing receives a legitimate response; Vision equalises TLS record lengths against length-fingerprinting. The primary shape, carried over from [RP-0001](../proposals/0001-bootstrap-phase-0-node.md). |
| 2 | **VLESS + REALITY + gRPC** | HTTP/2 over TLS | Wraps the stream in HTTP/2; survives some conditions that take down bare TCP-TLS, and multiplexes cleanly through HTTP/2-aware middleboxes. First TLS-family fallback. |
| 3 | **VLESS + REALITY + XHTTP** | HTTP-framed over TLS | Modern HTTP-framed transport (successor to earlier HTTP-upgrade transports); resilient where plain streams are disrupted and friendlier to HTTP-shaped paths and CDNs. Second TLS-family fallback. |
| 4 | **Hysteria2** | QUIC / UDP | Aggressive congestion control over QUIC; strong on lossy, throttled, or high-latency links where TCP collapses. UDP-friendly networks. |
| 5 | **TUIC v5** | QUIC / UDP | A second, independent QUIC/UDP shape with low-overhead multiplexing; gives a distinct QUIC fingerprint so the QUIC family is not a single point of failure. |
| 6 | **Shadowsocks-2022 (AEAD, `2022-blake3-aes-256-gcm`)** | TCP (and UDP) | The modern AEAD-2022 construction with per-session salts; a lightweight non-VLESS shape useful as an independent fallback. (The legacy pre-2022 Shadowsocks is excluded — see below.) |
| 7 | **ShadowTLS v3 wrapping Shadowsocks-2022** | TCP/TLS wrapper | Presents a genuine TLS handshake to a real external host in front of Shadowsocks, so the outer shape looks like ordinary TLS and answers active probing, while the inner shape stays a modern AEAD channel. |
| 8 | **Trojan over TLS (optional)** | TCP/TLS | A simple TLS-terminated shape for operators who want a plain-TLS option behind a real certificate; included as optional because shapes 1–3 generally dominate it, but it remains a useful independent fallback. |
| 9 | **AmneziaWG (obfuscated WireGuard)** | non-TLS / UDP | Obfuscated WireGuard (junk packets, header randomisation, padding) with the WireGuard cryptographic core unchanged; a non-TLS UDP path that fails differently from every TLS shape and from QUIC, covering a distinct gap. Runs as a **separate** path, not inside the sing-box engine. |

All shaping above — padding, junk packets, header randomisation, transport framing — is
obfuscation, **not** a confidentiality boundary; confidentiality is held only by the audited
upstream primitives ([ADR-0002](0002-no-custom-cryptography.md)).

### Excluded transports (legacy / easily-fingerprinted / superseded) and why

| Excluded | Reason |
|---|---|
| **VMess** | Older signature with known detectable characteristics; superseded by VLESS+REALITY, which is strictly better for indistinguishability. |
| **Plain Shadowsocks (pre-2022)** | Lacks the AEAD-2022 construction; easier to fingerprint and superseded by Shadowsocks-2022 (#6). |
| **Plain WireGuard** | An unobfuscated, easily-identified UDP handshake; superseded by AmneziaWG (#9), which keeps the same audited core but is not trivially fingerprinted. |
| **OpenVPN** | Recognisable handshake and packet structure; superseded by the modern set. |
| **L2TP/IPsec, PPTP, SSTP, IKEv2** | Legacy VPN protocols with well-known fingerprints and weaker survivability under DPI; offer nothing the modern set does not. |

### Engine decision

- **sing-box is the primary engine.** One server process terminates the TLS-family VLESS+REALITY
  variants (Vision / gRPC / XHTTP), the QUIC/UDP shapes (Hysteria2, TUIC), Shadowsocks-2022,
  ShadowTLS v3, and Trojan — many protocols under one roof, which simplifies operation,
  observability, and config distribution.
- **AmneziaWG is a separate non-TLS/UDP path.** It is not a sing-box inbound; it runs as its own
  service so the non-TLS UDP shape fails independently of the sing-box process and of every TLS
  shape.
- **Xray-core is retained as an optional alternative engine.** The existing
  `nodes/dataplane/vless-reality/` Xray path is kept and not removed; an operator may run the
  VLESS+REALITY+Vision shape on Xray instead of (or alongside) sing-box. This preserves the
  Phase 0 work and provides engine diversity.

### Per-protocol toggling for minimal exposure

Each protocol is an independent on/off switch in `group_vars`. A deployment exposes **only** the
subset the operator chooses; the default posture is minimal exposure, not "everything on". This
directly resolves the exposure ↔ resilience trade-off: breadth is available, but the surface
actually presented to the network is whatever the operator deliberately enables.

This canon binds **Layer 1** of [../ARCHITECTURE.md](../ARCHITECTURE.md): the data plane is a set
of independently-toggleable, indistinguishability-preserving shapes; Layer 3 selects the active one
among those enabled; Layer 2 distributes the per-protocol toggles and the resulting endpoint
bundle.

**Fail-closed.** When no enabled transport is reachable, the node does not fall back to an
unprotected or legacy shape; it reports no connectivity rather than degrading to a weaker boundary.

## Consequences

- **Positive:** the loss of any single transport shape no longer ends access; the node spans
  TCP/TLS, HTTP/2, HTTP-framed, QUIC/UDP, and non-TLS UDP families; per-protocol toggling keeps the
  exposed surface minimal; engine diversity (sing-box primary, Xray optional) avoids a single-engine
  dependency; every shape is built only on audited upstream primitives.
- **Negative / cost:** more configuration, observability, and version-pinning to maintain; a larger
  potential attack surface if an operator enables many transports at once (mitigated by toggling and
  minimal-exposure defaults); two engines and a separate AmneziaWG service to keep updated
  ([../dependency-policy.md](../dependency-policy.md)).
- **Impact on user security (requirement №1):** the node learns nothing new about users — no
  per-user attribution or access logging is introduced by adding transports; every included shape
  preserves indistinguishability, and excluded legacy shapes that could taint the node's reputation
  are kept out. Confidentiality, deniability, and forward secrecy remain those of the audited
  upstream primitives.
- **Impact on observability/measurements:** per-transport liveness and handshake-success signals
  become available (per inbound), giving Layer 2 finer-grained input on "which shape is alive
  where" than a single-transport node could.
- **Follow-on actions required:** the multi-protocol sing-box config and the `group_vars` per-protocol
  toggles are delivered in the Phase 0 data plane and control components; [../ROADMAP.md](../ROADMAP.md)
  Phase 0 / Phase 1 scope updated to reflect transport breadth pulled forward; version pins recorded
  per [../dependency-policy.md](../dependency-policy.md).
- **What is now forbidden:** adding any excluded legacy transport (VMess, plain pre-2022
  Shadowsocks, plain WireGuard, OpenVPN, L2TP/IPsec, PPTP, SSTP, IKEv2) to a Mycelium node; shipping
  a deployment with "everything on" as an unconsidered default instead of an operator-chosen subset;
  treating any obfuscation shaping as a confidentiality boundary.

## Compliance

How to verify the decision is respected in practice:
- conformance test **`no_custom_crypto`** — every transport uses only audited upstream primitives,
  no hand-rolled crypto ([ADR-0002](0002-no-custom-cryptography.md));
- conformance test **`no_legacy_transport`** — fails the build if any excluded legacy transport
  (VMess / plain Shadowsocks / plain WireGuard / OpenVPN / L2TP/IPsec / PPTP / SSTP / IKEv2) appears
  in a node config;
- conformance test **`per_protocol_toggle`** — each transport is independently enabled/disabled via
  `group_vars`, and a deployment with no transport explicitly enabled produces no public inbound;
- conformance test **`cover_site_probe`** / netsim scenario **`active_probe`** — TLS-family and
  ShadowTLS shapes return a genuine cover/donor response to active probing;
- netsim scenarios **`udp_drop`** and **`as_blackhole`** — confirm that removing UDP or blocking an
  AS leaves at least one enabled non-affected shape reachable;
- conformance test **`fail_closed_on_block`** — when no enabled transport is reachable, the node
  reports no connectivity rather than falling back to a weaker boundary;
- dependency-policy check — sing-box, Xray-core, and AmneziaWG are pinned to concrete versions
  ([../dependency-policy.md](../dependency-policy.md)).
