<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0037: Federation transport substrate — Nebula (hypha) + libp2p (bridge); inert contract in Phase 3

> Records **one** decision: when node-to-node federation goes **live** (Phase 4+), Mycelium **reuses proven
> substrate, never a homegrown wire protocol** ([ADR-0031](0031-build-vs-reuse-compose-proven-patterns.md),
> [ADR-0002](0002-no-custom-cryptography.md)) — **Nebula** for the intra-Commune, same-operator **hypha**
> bond (role A) and **libp2p (go-libp2p)** for NAT-traversed cross-Commune **bridge** peers (role B). The
> **CA boundary is the Commune boundary**, which is exactly why the two roles take different substrates. In
> **Phase 3** only the **inert, substrate-agnostic contract schema** lands: the **hypha** seam is built
> (typed + `Validate()`, zero callers), the **`AnastomosisBridge`** grammar is **declared but Phase-4
> deferred**. No transport, no crypto, no establishment runs before its phase. Evidence: the local research
> report `docs/research/2026-07-federation-substrate.md`. Saved as
> `docs/adr/0037-federation-transport-substrate.md`.

---

## Context

Phase 3 must land the **inert intra-Commune F2F hypha edge-fusion seam** ([ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)
Decision 5) — schemas + the introduction mechanism ([ADR-0029](0029-community-federated-ingress-edges.md)
Decision 5) only, **no live federation** ([ROADMAP](../ROADMAP.md) Phase-3 DoD). When federation *does* go
live (Phase 4+), the ROADMAP already commits to **reusing proven substrate** (Nebula / WireGuard-Noise for
mutual-auth node links; private libp2p for NAT'd peers) rather than reinventing it. This ADR pins *which*
substrate, so the Phase-3 inert schema can be shaped to **compose with it without lock-in**, and records the
licensing/centralization traps to avoid. The substrate comparison (Nebula vs Headscale/Netmaker/NetBird vs
libp2p vs Yggdrasil, 2025-26) is in the local research report; this ADR is the durable decision it backs.

Two distinct roles the substrate must serve:
- **(A) hypha** — a mutual-authenticated link between nodes the **same** operator runs, inside one Commune,
  rooted in that operator's **own CA/PKI**, with a coordinator the operator **self-hosts**.
- **(B) bridge** — a NAT-traversed link to a **different** operator's Commune (a governed Anastomosis
  Bridge), needing hole-punching + relay fallback across a **CA boundary**.

## Decision

**1. Live substrate (Phase 4+): Nebula for role A, libp2p for role B — reused, not reinvented.**
- **Role A (hypha) → Nebula** (slackhq, **MIT**): certificate mutual-auth rooted in the operator's own CA
  over the Noise Protocol Framework (standard crypto — Curve25519 + AES-256-GCM, satisfies ADR-0002); a
  **self-hosted Lighthouse** coordinator (the operator's own, never a vendor SaaS); single Go static binary.
- **Role B (bridge) → libp2p (go-libp2p, MIT)**: decentralized **DCUtR** hole-punching + a **self-hosted
  Circuit Relay v2** whose reservations bound relayed traffic by count/duration/bytes — no vendor
  DERP/STUN/TURN. **Relay fallback is mandatory** (DCUtR ≈70% at the hole-punch stage; the ≈30% symmetric-NAT
  residual has no direct path).

**2. The CA boundary is the Commune boundary.** Nebula relays are constrained to **same-CA** hosts, so a
foreign-CA node cannot relay for your network — the decisive reason role B is **not** Nebula. This is not a
limitation to work around; it is the correct shape: same-CA = one Commune = hypha (Nebula); cross-CA = two
Communes = bridge (libp2p). The doctrine's hypha↔bridge split maps one-to-one onto the substrate split.

**3. Phase-3 lands only the inert, substrate-agnostic contract** (`internal/spec`, per
[ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md) inertness): schema-versioned, JSON-tagged, pure
`Validate()`, signatures as `SignerKeyID` references only ([ADR-0002](0002-no-custom-cryptography.md)/[ADR-0014](0014-per-operator-node-credentials.md)).
The contract captures **five substrate-agnostic fields** so it composes with either transport at Phase 4:
1. **identity / PKI handle** — a substrate-agnostic `IdentityHandle{Kind, CAFingerprint, NodeIdentity}`
   holding a Nebula CA-fingerprint + cert identity (hypha) **or** a libp2p peer-ID (bridge); opaque, never an
   IP/location;
2. **capability classes** — the [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) Decision-3 9-value
   `TrafficCapabilityClass` taxonomy + a `CapabilityPolicy` (allowed/forbidden, forbidden stated explicitly);
3. **TTL** — a `DecayPolicy`-bounded lifetime (replay-bounded, self-expiring);
4. **consent / double-opt-in** — both sides opt in ([ADR-0029](0029-community-federated-ingress-edges.md)
   Decision 5); a fungi **MAY introduce, MUST NOT enumerate**;
5. **hop-depth cap** — introduction depth **1–2** + a max-degree bound.

**4. Build order: hypha now, bridge declared-deferred.**
- **BUILT inert (Phase 3):** `IdentityHandle`, `TrafficCapabilityClass`, `CapabilityPolicy`,
  `SiblingDescriptor` (the hypha bond), `HyphaInvitation` (the introduction, carried in the existing
  `SporeTypeTrustInvitation` `SporeEnvelope`). Typed + `Validate()` + inertness gate; **zero callers**.
- **DECLARED, Phase-4 deferred:** the `AnastomosisBridge` 8-term contract grammar
  ([ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) Decision 2 — trust / allowed / forbidden /
  abuse-propagation / quarantine / revocation / recovery / evidence) is typed in full so the architecture is
  visible, but **nothing establishes, negotiates, or propagates a bridge** before Phase 4-5. Built inert
  alongside the hypha; also zero callers.

**5. Traps recorded (all avoidable).** Nebula's optional **"Managed Nebula" SaaS** control plane (use the OSS
lighthouse/CA path); Nebula's **same-CA relay** constraint (→ libp2p for role B); Headscale's **default DERP
map pointing at Tailscale Inc.** unless `urls:[]` is set (the WireGuard-control-plane family's centralization
trap). No BUSL/SSPL/proprietary-coordinator lock-in in the chosen substrates (both MIT).

## Consequences

- The Phase-3 inert schema is transport-agnostic: plugging in Nebula (hypha) or libp2p (bridge) at Phase 4
  fills the `IdentityHandle` and adds a live establishment path — **no schema rewrite, no vendor lock-in**.
- We author **no cryptography and no wire protocol** (ADR-0002/0031); the "hypha" is a **contract over a
  proven transport**, not a new protocol.
- Inertness is enforced, not merely intended: the new types must land with **zero production callers** and an
  inertness gate; `NodeProfile.Validate` already refuses the reserved weather opt-in, and the same discipline
  binds the federation types until Phase 4-5.
- **Risk:** naming substrates now could invite premature wiring. Mitigation: the inertness gate + the hard
  phase split in ADR-0026 Decision 5; building a live publisher/dialer in Phase 3 would *violate* the DoD.

## Alternatives considered

- **WireGuard + a self-hosted control plane (Headscale / Netmaker / NetBird)** — viable for role A, but the
  control-plane family carries the DERP/coordinator centralization trap (Headscale defaults to Tailscale
  Inc.'s DERP), and none gives role B's decentralized hole-punch + bounded self-relay as cleanly as libp2p.
- **Nebula for both roles** — rejected for role B: same-CA relay cannot bridge across operators.
- **Yggdrasil / cjdns** — a self-arranging encrypted mesh overlay; reserved for the **Phase 5/6** mesh, not
  the Phase-4 mutual-auth node link or the governed bridge.
- **A homegrown node-link protocol** — rejected outright (ADR-0002 no-custom-crypto, ADR-0031 build-vs-reuse).

## Status

**accepted** — Phase 3 (inert schema; hypha built, bridge declared) / Phase 4+ (live transport). Extends
[ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) (bridge grammar + capability taxonomy) and
[ADR-0029](0029-community-federated-ingress-edges.md) (introduction mechanism); governed by
[ADR-0031](0031-build-vs-reuse-compose-proven-patterns.md) + [ADR-0002](0002-no-custom-cryptography.md);
realized as inert types in `internal/spec` (hypha + anastomosis-bridge).
