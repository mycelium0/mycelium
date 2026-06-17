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
  [../dependency-policy.md](../dependency-policy.md),
  [../../nodes/dataplane/singbox/protocols.md](../../nodes/dataplane/singbox/protocols.md) (sing-box inbound map)

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

- **Adversary model** (see [../THREAT-MODEL.md](../THREAT-MODEL.md)): behavioral-layer signature matching,
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
| 4 | **Hysteria2** | QUIC / UDP | Aggressive congestion control over QUIC; strong on lossy, throttled, or high-latency links where TCP collapses. **Salamander obfs + H3 masquerade is the intended design but is not yet wired into the deployed render path** (see the obfs note below); the inbound is off by default, so the Phase-1 renderer ships it bare (TLS + h3). UDP-friendly but non-primary, since UDP is excised wholesale in some networks. |
| 5 | **TUIC v5** | QUIC / UDP | A second, independent QUIC/UDP shape with low-overhead multiplexing; gives a distinct QUIC fingerprint so the QUIC family is not a single point of failure. |
| 6 | **Shadowsocks-2022 (AEAD, `2022-blake3-aes-256-gcm`)** | TCP (and UDP) | The modern AEAD-2022 construction with per-session salts; a lightweight non-VLESS shape useful as an independent fallback. (The legacy pre-2022 Shadowsocks is excluded — see below.) |
| 7 | **ShadowTLS v3 wrapping Shadowsocks-2022** | TCP/TLS wrapper | Presents a genuine TLS handshake to a real external host in front of Shadowsocks, so the outer shape looks like ordinary TLS and answers active probing, while the inner shape stays a modern AEAD channel. |
| 8 | **Trojan over TLS (optional)** | TCP/TLS | A simple TLS-terminated shape for operators who want a plain-TLS option behind a real certificate; included as optional because shapes 1–3 generally dominate it, but it remains a useful independent fallback. |
| 9 | **AmneziaWG (obfuscated WireGuard)** | non-TLS / UDP | Obfuscated WireGuard (junk packets, header randomisation, padding) with the WireGuard cryptographic core unchanged; a non-TLS UDP path that fails differently from every TLS shape and from QUIC, covering a distinct gap. Runs as a **separate** path, not inside the sing-box engine. |
| 10 | **VLESS + XHTTP over genuine single-layer TLS (real certificate, non-REALITY, CDN-frontable)** | HTTP-framed over TLS | A genuine single-layer TLS shape (real certificate, not a borrowed donor handshake) carrying XHTTP — there is no TLS inside TLS, so it presents the flow profile of an ordinary HTTPS client to a real origin and removes the nested-handshake handle that single-connection classifiers key on. Frontable behind a CDN, which makes it the doctrine-clean HTTP-framed option for paths where a real certificate and origin are preferable to a donor handshake. Served on the Xray path. |
| 11 | **VLESS + WebSocket + TLS (CDN-frontable)** | HTTP-framed over TLS | The broadest-compatibility CDN-frontable shape: a long-lived WebSocket inside ordinary TLS that traverses HTTP-aware middleboxes and CDN edges that pass WebSocket upgrades. It is the successor role to earlier HTTP-upgrade transports and the widest-reach fallback when the HTTP/2 (#2) and XHTTP (#3, #10) shapes are constrained. |

**Hysteria2's intended shape is obfuscated, not bare QUIC — but the obfs is not yet wired (deferred).**
The intended design wraps inbound #4 in **Salamander obfuscation** (`obfs.type = salamander`) and
points unauthenticated requests at an **H3 masquerade** site (the `obfs` and `masquerade` design,
documented in [`protocols.md`](../../nodes/dataplane/singbox/protocols.md) row 4). **Deployment status
(honest):** the deployed sing-box template
[`server.template.renderer.json`](../../nodes/dataplane/singbox/server.template.renderer.json) currently
renders Hysteria2 **bare** (TLS + `alpn: ["h3"]`, no `obfs`, no `masquerade`), and the shell renderer
[`render_singbox.sh`](../../control/lib/render_singbox.sh) has no Salamander/masquerade logic. The
earlier split-brain template that carried `salamander`/`masquerade` placeholder fields was inert (its
tags were never matched by the renderer) and was removed when the renderer template became canonical
(Audit-0005 C02). Because the Hysteria2 inbound is **off by default** and the QUIC family is non-primary
on the operator's UDP-excising carrier (the surviving mobile shape is #10, XHTTP-over-genuine-TLS, not
QUIC), the Salamander obfs + H3 masquerade is recorded here as a **deferred hardening: it must be wired
into the renderer before the Hysteria2 inbound is enabled in a hostile-QUIC environment** (a Phase-2 /
pre-enablement item). The rationale below is preserved as the design target, not a current deployment
claim. This is the QUIC shape that specifically answers **SNI-based QUIC blocking**: Salamander
XOR-scrambles the entire QUIC datagram, so a filter that classifies QUIC by lifting a plaintext SNI out
of the QUIC Initial / TLS ClientHello finds no parseable field to match — the discriminator it keys on
is simply not on the wire. The threat is real and current: per a gfw.report study on SNI-based QUIC
filtering (USENIX Security 2025,
[gfw.report/publications/usenixsecurity25](https://gfw.report/publications/usenixsecurity25/en/)),
the GFW began blocking QUIC in April 2024 by inspecting the SNI field. Should the obfuscated path
(once wired) still be probed or blocked, the **H3 masquerade is the fallback** — the endpoint
impersonates an ordinary HTTP/3 site (`alpn: ["h3"]`) rather than returning an empty or anomalous
response. This shaping is obfuscation, **not** a confidentiality boundary (next paragraph); and
consistent with the provisioned-but-non-primary doctrine for UDP, it does not change Hysteria2's
standing — UDP shapes (#4, #5) remain available but are not the primary route because UDP is excised
wholesale in some environments.

All shaping above — padding, junk packets, header randomisation, transport framing, Salamander's
datagram scrambling — is obfuscation, **not** a confidentiality boundary; confidentiality is held
only by the audited upstream primitives ([ADR-0002](0002-no-custom-cryptography.md)).

### Excluded transports (legacy / easily-fingerprinted / superseded) and why

| Excluded | Reason |
|---|---|
| **VMess** | Older signature with known detectable characteristics; superseded by VLESS+REALITY, which is strictly better for indistinguishability. |
| **Plain Shadowsocks (pre-2022)** | Lacks the AEAD-2022 construction; easier to fingerprint and superseded by Shadowsocks-2022 (#6). |
| **Plain WireGuard** | An unobfuscated, easily-identified UDP handshake; superseded by AmneziaWG (#9), which keeps the same audited core but is not trivially fingerprinted. |
| **OpenVPN** | Recognisable handshake and packet structure; superseded by the modern set. |
| **L2TP/IPsec, PPTP, SSTP, IKEv2** | Legacy VPN protocols with well-known fingerprints and weaker survivability under behavioral-layer detection; offer nothing the modern set does not. |

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

## Amendment (2026-06-14)

This amendment records two findings from a 2025–2026 transport-technique landscape review. It
adds no new decision; it documents shapes the data plane already serves and two hardening facts
that bear on how the set is operated. The decision and its **accepted** status are unchanged.

### Doc gap closed: two already-served HTTP-framed shapes

Rows **#10 (VLESS + XHTTP over genuine single-layer TLS, real certificate, non-REALITY,
CDN-frontable)** and **#11 (VLESS + WebSocket + TLS, CDN-frontable)** were already part of the
served set but were absent from the decision table above. They are now listed. Both are
HTTP-framed-over-TLS shapes that complement the REALITY-family rows: #10 is the genuine
single-layer-TLS answer for paths where a real certificate and origin are preferable to a borrowed
donor handshake (no TLS inside TLS), and #11 is the broadest-compatibility CDN-frontable fallback.
Neither is a confidentiality boundary; both rest only on audited upstream primitives
([ADR-0002](0002-no-custom-cryptography.md)).

### Engine asymmetry: the strongest current hardening is Xray/awg-only

The most repeated finding of the review is an **engine asymmetry**, and it is the reason this ADR
retains Xray-core and runs AmneziaWG as a separate path rather than collapsing onto a single engine.
The strongest currently-available hardening for indistinguishability lives in Xray-core and in the
AmneziaWG userspace path — **not** in sing-box, the primary engine:

- **Post-quantum REALITY** (X25519MLKEM768 key exchange, optional ML-DSA-65) — keeps the handshake
  inside the rising post-quantum browser population and adds harvest-now/decrypt-later resistance.
  Available on the **Xray** path; gated off on sing-box, which lacks parity.
- **Post-handshake mimicry** (REALITY NewSessionTicket / Aparecium-class conformance) — closes the
  active-probing differential against the real TLS stacks of donor origins. Landed on the **Xray**
  path; sing-box parity is **not** yet confirmed and is treated as PARTIAL until it is.
- **VLESS-Encryption** (ML-KEM-768 + X25519) — an optional inner layer relevant only on the genuine-TLS
  XHTTP (#10) and WebSocket (#11) paths, not on REALITY shapes. **Xray**-only at present.
- **AmneziaWG 2.0** (ranged header randomisation, per-packet padding) — per-packet randomisation that
  defeats the static-parameter fingerprinting that exposed the earlier version. Carried by the
  separate **awg** userspace service; sing-box does not carry AmneziaWG 2.0, so the split is permanent.

The practical consequence: where post-quantum REALITY or post-handshake conformance is load-bearing,
serve the REALITY shape on the **Xray** path; keep these features **off by default on sing-box** until
upstream parity lands. This is exactly the engine-diversity escape hatch the Decision preserves, and it
is now load-bearing for indistinguishability rather than a convenience. The version pins, the
parity-tracking, and the conformance probes that enforce this are recorded in the forthcoming
dependency-policy and conformance ADR (**ADR-0028**) and in the maintained landscape reference
([../reference/transport-technique-landscape.md](../reference/transport-technique-landscape.md));
sing-box parity for each item above is tracked there per engine bump. None of this is a confidentiality
change ([ADR-0002](0002-no-custom-cryptography.md)).

### QUIC server-hygiene note

For the QUIC/UDP shapes (#4 Hysteria2, #5 TUIC), the client-side QUIC-Initial handling is already
inherited from the pinned engines. The remaining server-side residue is two hygiene items that
operators of a QUIC leg should set:

- bind the QUIC listener to a **high, non-443 UDP destination port** rather than the well-known
  default, so the UDP shape does not advertise itself by port; and
- present a **real `server_name`** on the QUIC endpoint so the handshake matches an ordinary
  server, not an empty or placeholder name.

These are operator-tunable hygiene defaults, not new transports.

### Scope guard (what this amendment does NOT claim)

Breadth of the set does **not** answer the two structural exposures that no transport shape resolves:
the destination-AS download-throughput throttle and the cross-layer round-trip-time correlation
fingerprint. Both are addressed — only partially — at the routing and topology layer
([ADR-0027](0027-selective-growth-and-in-region-ingress.md),
[VIS-0009](../vision/0009-selective-growth-reachability-topology.md)) via in-region ingress and
node-to-node egress, never claimed beaten at the transport layer. Consistent with
[ADR-0016](0016-software-releases-not-an-operated-network.md), Mycelium is node software and is **not a universal
bypass substrate**; the transport set is breadth and indistinguishability, not a guarantee against
every analysis.
