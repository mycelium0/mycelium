<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0014: `Per-operator node credentials — no shared network key material`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound
> decision: how TLS/identity material is provisioned across a mesh whose nodes are
> run by **independent operators**, not a single owner. Saved as
> `docs/adr/0014-per-operator-node-credentials.md`.
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0010-phase0-transport-set.md](0010-phase0-transport-set.md),
> [0011-carrier-agnostic-bridging.md](0011-carrier-agnostic-bridging.md),
> [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [../vision/0003-node-interaction-and-distributed-awareness.md](../vision/0003-node-interaction-and-distributed-awareness.md),
> [../GLOSSARY.md](../GLOSSARY.md).

---

## Metadata

- **ID:** ADR-0014
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** data plane (transport TLS), discovery/membership (federation), deploy/bootstrap
- **Phase:** cross-cutting; binds node bootstrap from Phase 0 onward
- **Related:** ADR-0002 (no custom crypto), ADR-0010 (transport set), ADR-0011 (carrier-agnostic
  bridging), VIS-0003 (membership/trust layer)

## Context

Mycelium is a **multi-operator** network: nodes are run by different, independent people, not by a
single owner. Any design that assumes one administrator holds all key material is wrong for the mesh.

Phase-0 bring-up took an expedient shortcut: a single shared **wildcard certificate**
(`*.mycelium.host`) was issued once and **copied to every node**, with the TLS-QUIC transports
(Hysteria2, TUIC) presenting it under SNI `m.mycelium.host` so clients connect by IP with zero
per-node DNS. That works while every node belongs to **one** operator. It does **not** generalise:

- Distributing a domain's **private key** to independent operators is a key disclosure that voids the
  certificate's meaning and trust.
- It creates a **central dependency** on one owner's domain (`mycelium.host`) and its renewal.
- It contradicts the network's decentralised nature — each node should be **self-sufficient**, the way
  each hypha in a mycelium carries what it needs locally.

Crucially, **most transports need no certificate at all.** The REALITY family
(VLESS-Vision / gRPC / XHTTP, per ADR-0010) borrows a **donor SNI** and authenticates with a per-node
X25519 keypair — no CA, no domain. AmneziaWG / WireGuard need only a keypair. **Only the TLS-QUIC
transports (Hysteria2, TUIC) require a real TLS certificate.**

## Decision

1. **No shared network key material.** Every node holds **only its own** keys and certificates. No
   private key is ever copied between operators or distributed network-wide.

2. **Certless REALITY backbone.** The canonical transport backbone is REALITY-based
   (VLESS-Vision / gRPC / XHTTP). Each node is self-sufficient with its own per-node REALITY keypair +
   shortId; these require **no domain, no certificate, no CA**. AmneziaWG is likewise a per-node
   keypair. A node can therefore join the mesh with **zero** certificate infrastructure.

3. **Per-operator certificates for TLS transports.** Hysteria2 and TUIC, which require a TLS
   certificate, use a **per-node** certificate chosen by that node's operator, one of:
   - **(a)** the operator's **own domain + ACME** (e.g. Let's Encrypt), when they have a domain; or
   - **(b)** a per-node **self-signed certificate pinned by the client** (SHA-256 of the certificate /
     SPKI). No CA, no domain. The client config (already per-node) carries the pin.

   Blanket `insecure: true` trust is not used (it would accept any certificate); pinning preserves the
   no-custom-crypto, fail-closed posture of ADR-0002.

4. **No network domain dependency.** `mycelium.host` is **one operator's** convenience for **their own**
   nodes, not part of the protocol and not required by any other operator. Certificates may, and will,
   differ per node. The shared wildcard is explicitly **non-canonical**.

5. **TLS is transport security, not node identity.** Whether a node is a *legitimate* mycelium node is
   decided by the membership/trust layer (inviter-vouched spores, VIS-0003) — **never** by its TLS
   certificate. A self-signed HY2/TUIC cert says nothing about mesh membership, and a CA-signed one
   grants none. The two concerns are kept separate.

6. **CDN fronting is a per-operator option, not a network feature** — and is currently unused (the
   candidate CDN is blocked on target access networks, so fronting behind it gains nothing).

## Consequences

- A new operator can stand up a node with **no domain and no certificate** (REALITY + AmneziaWG), or
  additionally enable HY2/TUIC with **their own** certificate (own-domain ACME or self-signed + pin).
- The **canonical node bootstrap** generates per-node credentials **locally** (REALITY keypair,
  AmneziaWG keypair, and — only if HY2/TUIC are enabled — a self-signed certificate); it never fetches
  or installs shared key material.
- **Subscription / client-config generation** must emit, for self-signed HY2/TUIC nodes, the per-node
  certificate **pin** (SHA-256) rather than a shared SNI + public-CA assumption.
- An operator's **own existing nodes** may keep a shared wildcard as a transitional convenience because
  they share one trust domain (one owner); new or independently-operated nodes follow this ADR. The
  wildcard is a migration artefact, not the model.
- A conformance check should assert that no node template or deploy path embeds shared private-key
  material, and that the bootstrap’s certificate step is per-node.

## Alternatives considered

- **Shared wildcard everywhere** (status quo Phase-0 shortcut) — rejected: requires sharing a private
  key with independent operators; central domain dependency.
- **A network-internal CA that signs each node** — rejected for now: reintroduces a central trust root and
  key-distribution problem; REALITY (certless) + per-node self-signed-with-pinning achieves the goal
  without one. May be revisited if a federation-level PKI is ever justified, but node *identity* belongs
  to the spore/membership layer (VIS-0003), not a TLS CA.
- **`insecure: true` for self-signed HY2/TUIC** — rejected: accepts any certificate (MITM-open);
  pinning is the fail-closed equivalent.
