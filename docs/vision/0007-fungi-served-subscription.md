<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Fungi-served self-propagating subscription (decentralized ingress distribution)

> **Document type.** Vision & Scope — "why and where", not a specification. The wire formats, the
> partition function, the credit/invite math, and the gossip contract are pinned by the ADRs and RPs
> this Vision spawns (§8), not here.
>
> **The paradox it dissolves.** A single auto-updating subscription URL (the "Rocky" model) is the most
> *usable* bootstrap there is — import one link, the client polls it, blocked servers are silently
> replaced, new ones appear. But that exact convenience is also the project's three forbidden things in
> one object: a **single point of block** (cut the sub domain and every user's updates stop — and a
> cold-start user with no working server is stranded), a **global map** (whoever holds the URL sees the
> whole network — the adversary's most valuable prize, [../THREAT-MODEL.md](../THREAT-MODEL.md)), and a
> **coercion target** (seize the issuer, get every node and every user). Mycelium cannot ship that and
> stay Mycelium. The resolution — the operator's insight — is to stop treating the subscription as a
> *document served from one place* and treat it as a **living, partial, per-user view of the mesh that
> the fungi themselves serve, refresh, and re-issue.** Each user imports one link; behind it a *fungus*
> (a distribution-custodian node, [../adr/0018-fungi-role-and-opt-in-publish.md](../adr/0018-fungi-role-and-opt-in-publish.md))
> hands out only its **neighborhood's** ingress, keeps it fresh as that neighborhood churns, and passes
> fresh ingress to neighboring fungi — so there is no single link, no single issuer, and no single map,
> yet every user still gets the one-link, self-updating experience.

## Metadata
- **ID:** VIS-0007
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** Distribution / discovery track. Today: inert schema only (Phase 0–2). Coordinator-assisted
  distribution is Phase 3; DHT/gossip + invite/reputation is Phase 4; trust-gradient hand-out is Phase 6.
- **Layer(s):** bootstrap / config distribution, discovery / membership, control plane (cross-cutting)
- **Related:** [0003-node-interaction-and-distributed-awareness.md](0003-node-interaction-and-distributed-awareness.md)
  (spores, knowledge gradient, registry→DHT→gossip), [0004-living-network-doctrine.md](0004-living-network-doctrine.md)
  (growth-front niches, signal-speed classes), [0006-decentralized-observability.md](0006-decentralized-observability.md)
  (the in-region edge signal a fungus needs to know which ingress is alive *where*),
  [../adr/0018-fungi-role-and-opt-in-publish.md](../adr/0018-fungi-role-and-opt-in-publish.md) (the fungi role),
  [../adr/0014-per-operator-node-credentials.md](../adr/0014-per-operator-node-credentials.md),
  [../adr/0020-phase0-scope-reconciliations.md](../adr/0020-phase0-scope-reconciliations.md) (Phase-0 stays
  out-of-band hand-off), [../ROADMAP.md](../ROADMAP.md) (Phase 1 matured endpoint; Phase 3–6 distribution).

## Context — what we are replacing, and what already works

The Phase-1 [ROADMAP](../ROADMAP.md) matured config-distribution endpoint gives the client the standard
**auto-update loop**: a stable URL is consumed as a *Remote Profile* that the client re-fetches on a
cadence the server influences. This loop is real and off-the-shelf today — sing-box mandates graphical
clients implement automatic profile update (60-minute default) for a remote-URL profile
([sing-box client spec](https://sing-box.sagernet.org/clients/general/)), and the XTLS subscription
standard defines a `profile-update-interval` HTTP response header (integer **hours**) so the server tells
the client how often to refresh ([XTLS/Xray-core #4877](https://github.com/XTLS/Xray-core/discussions/4877),
[xtls-subscription-standards](https://github.com/jomertix/xtls-subscription-standards)). One endpoint can
also serve per-client-appropriate, indistinguishability-preserving configs (REALITY domain-borrowing, self-steal-with-nginx)
selected by client type — the 2025-26 panel ecosystem bakes this in
([remnawave/templates](https://github.com/remnawave/templates)). **Mycelium keeps this client-facing loop
unchanged** (off-the-shelf clients, no bespoke app — [../adr/0016-software-releases-not-an-operated-network.md](../adr/0016-software-releases-not-an-operated-network.md)).
What VIS-0007 changes is **who is on the other end of the URL, and what it knows.**

The convenience that makes the Rocky model survive ("new servers work periodically") is precisely the
auto-rotation-through-the-sub: blocked ingress is swapped, the next poll delivers fresh. Its fragility is
that the sub endpoint is one place. Per the Xray-core lead, the *transports* that survive (REALITY, QUIC,
CDN-passing) are known ([net4people/bbs #425](https://github.com/net4people/bbs/issues/425)) — but a CDN
front "is not permanently blocked, but is unstable," and since mid-2025 some blocking adversaries accept
the collateral damage and throttle CDN ranges wholesale. So hardening the *transport* of a single sub endpoint is
necessary but not sufficient; the endpoint's **singularity** is the irreducible weakness. Distribution is
the answer the network-persistence field already converged on.

## The canon we inherit (decentralized ingress distribution)

Tor's bridge-distribution lineage is the worked example of "many users, partial views, no global map,
survives enumeration and coercion." VIS-0007 adopts its proven pieces and maps each to a fungus:

- **Backend ↔ distributor split (rdsys, BridgeDB's successor, 1.0 shipped Feb 2025).** Resource *intake*
  is separated from distribution *policy*; "smartly hand out resources … and thwart Sybil attacks" is the
  **distributor's** job, not the intake plane's
  ([rdsys architecture, faithful mirror](https://github.com/i2p-pt/i2p-rdsys),
  [Tor blog](https://blog.torproject.org/making-connections-from-bridgedb-to-rdsys/)). → A fungus is a
  *distributor*; its ingress-refresh plane is separate from its who-gets-what policy plane, and Sybil
  defense lives in the policy plane.
- **Partial, self-refreshing view via a diff stream.** rdsys hands each distributor an *initial,
  deterministically-selected* set plus *incremental updates* as resources appear/change/disappear
  (`ResourceDiff{New,Changed,Gone}`). → This **is** the "partial, self-refreshing view": a fungus holds a
  deterministic slice + a churn diff, not a static dump.
- **Disjoint partitioning of the enumeration surface.** Each bridge maps to exactly **one** distributor
  via `HMAC(id, secret)`; learning one channel never leaks another's
  ([bridgedb-spec](https://spec.torproject.org/bridgedb-spec.html)). → A fungus advertises a disjoint
  slice; capturing one fungus yields only its slice.
- **Knowledge gradient keyed to the requester.** BridgeDB groups requesters by /24 into ~4 disjoint
  clusters via HMAC-to-rings, so an adversary in one IP region sees only that region's subset. It is *not*
  enumeration-proof (a national-scale adversary enumerated all bridges in ~1 month, NDSS'17) — partitioning **raises the cost**, it does
  not eliminate the risk. → Different users get different fungi/ingress, derived deterministically from a
  requester attribute.
- **Heterogeneous out-of-band bootstrap.** Bridges reach users over website / email / MOAT / Telegram so no
  single channel block cuts all first-contact paths. → A fungus exposes its bootstrap over multiple
  carrier channels ([../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md)).
- **Sybil resistance by trust, not open registration.** rdsys's Telegram distributor gates on account age;
  **Lox** (PETS 2023) is reputation-based — it *detects blocked bridges* and rewards users whose bridges
  stay unblocked (trust levels 0–4)
  ([Lox/PETS-2023](https://petsymposium.org/popets/2023/popets-2023-0029.php)). → Hand-out is gated by
  identity-age + a reputation that *rises when a fungus's advertised ingress stays unblocked* — which is
  exactly the in-region edge signal VIS-0006 already gathers.
- **Invitation admission + a credit economy (rBridge, NDSS 2013).** New users join only via one-time
  invitation tickets probabilistically issued to high-reputation users and passed to friends; a user earns
  credits from the *uptime* of the ingress they hold and must **spend** credits to replace blocked ingress
  — so burning ingress is not cheap. Fine-grained per-user/per-ingress reputation beats coarse per-group
  reputation by ~an order of magnitude under 5% malicious users
  ([rBridge/NDSS-2013](https://www.ndss-symposium.org/ndss2013/ndss-2013-programme/rbridge-user-reputation-based-tor-bridge-distribution-privacy-preservation/)).
  → Re-issuance is metered against good-behavior credit; admission is invite-gated.

## The Mycelium design — a fungus serves the subscription

A **fungus** is a Mycelium node that has taken the distribution-custodian niche (ADR-0018). It owns four
planes, mapped to the canon above and to contracts the fabric already declares (inert in Phase 0–2):

1. **The client-facing loop (unchanged, standard).** The fungus serves a normal Remote-Profile / XTLS
   subscription URL over a Mycelium-grade indistinguishable, block-resistant transport (the same bar as the
   data plane it advertises — [../refactoring.md](../refactoring.md) §15.2). Off-the-shelf clients poll it
   and auto-update; the user experience is the one link they wanted. **Critically, the fetch rides a
   Mycelium transport**, so an already-bootstrapped client keeps updating *through the mesh* even when the
   bootstrap channel is blocked (the resilient-update property, generalized off a single domain).
2. **The view plane — partial + self-refreshing.** What the URL returns is a **per-user slice** of the
   network's ingress, derived deterministically from the user's credential (`HMAC(user, scope-secret)` →
   neighborhood), kept fresh by a churn diff as the fungus's neighborhood rotates/gets blocked. No user, and
   no coalition below the partition threshold, can reconstruct the global map — the **knowledge gradient**
   VIS-0003 already names. Region/transport descriptors stay coarse and closed-vocabulary (EdgeReport
   discipline; no precise geo/ASN — Audit-0004 F-020).
3. **The awareness plane — knowing which ingress is alive *where*.** A fungus re-issues *good* ingress, and
   it only knows which is good from the **in-region edge signal** (VIS-0006): redacted, floored, aggregated
   reachability reports flowing from the edge. This is why VIS-0006 is a hard dependency — the fungus's
   refresh quality is exactly the network's in-region observability.
4. **The propagation plane — re-issue + gossip.** A fungus learns ingress from **scoped, TTL-bounded,
   signed spores** gossiped by neighbors (VIS-0003 `SporeEnvelope`), not from a central registry — this is
   the one place Mycelium goes *beyond* rdsys, whose intake backend is central. It re-issues links against
   earned credit, gossips fresh ingress to neighbor fungi, and when a fungus (or its slice) is blocked, its
   users are re-pointed to a sibling fungus. Admission is invite-gated; re-issuance is credit-metered;
   reputation rises with unblocked uptime and falls when advertised ingress dies (Lox + rBridge).

## Phase discipline (this is mostly Phase 3–6; almost nothing is built now)

Per [../adr/0013-mycelial-vocabulary-and-phase-discipline.md](../adr/0013-mycelial-vocabulary-and-phase-discipline.md):

- **Phase 0–2 — inert only.** The schema hooks already exist and stay data-only: `SporeEnvelope`,
  `TrustScope`, `EdgeReport`/`TransportClass`, `DiscoveryBackend` (declaration). The Phase-1 matured
  endpoint ([ROADMAP](../ROADMAP.md)) ships the *single-operator* self-replenishing subscription +
  client-side merge — **not** fungi distribution. Phase 0 stays out-of-band hand-off (ADR-0020 §1).
- **Phase 3 — coordinator-assisted distribution.** A coordinator may play the rdsys-style intake role
  (with a knowledge ceiling + TTL/decay + an emergency quarantine path, never a permanent central brain —
  `COORDINATOR_SUPERGOD_DRIFT` guard, [../refactoring.md](../refactoring.md) §7). Partition + diff-stream
  hand-out lands here.
- **Phase 4 — DHT/gossip + invite/reputation.** Intake decentralizes onto the spore/gossip layer; invite
  tickets + the credit economy + Lox-style blocked-ingress detection activate (sybil resistance from the
  moment membership opens, §15.7).
- **Phase 6 — trust-gradient hand-out.** Per-user slice quality follows the trust gradient.

## Named risks (the design must hold these by construction)

- `SINGLE_POINT_OF_BLOCK` (S0) — *the* failure this Vision exists to avoid: never one issuer, one URL, one
  map. A blocked fungus degrades to its slice; users re-point to siblings.
- `ENUMERATION_EXPOSURE` (S1; S0 at Phase 4+) — partitioning raises cost but is not enumeration-proof
  (NDSS'17); invitation + credit + per-user partial views are mandatory at open membership, not optional.
- `USER_DEANON` / `TRAFFIC_CORRELATION` (S0) — a fungus learns *which credential it served which slice to*.
  Minimize: per-user views carry no PII, the fungus is ingress-distribution only (it is **not** the user's
  data-plane ingress — keep distribution and carriage separate so one fungus never knows "who" *and*
  "where"), and credentials are unlinkable across fungi where feasible (Lox's privacy-preserving accounting
  is the reference).
- `FORBIDDEN_TOPOLOGY_CENTRALIZATION` / `MASTER_MAP_DRIFT` (S1→S0) — no fungus, coordinator, or island-merge
  may accrete the global ingress map; scope, TTL, and the knowledge ceiling are load-bearing.
- **Coercion / seizure** — a seized fungus exposes only its slice (partition); its credential is revocable
  (Lox blocked-detection + re-key), and credit clawback bounds an inside attacker.

## What this spawns
- An ADR pinning the **partition + diff-stream** distribution contract (slice function, churn diff,
  per-client format negotiation) for Phase 3.
- An ADR pinning **invitation + reputation/credit** (admission, credit accrual from unblocked uptime,
  re-issuance metering, revocation) for Phase 4 — grounded in Lox/rBridge, no in-house crypto (ADR-0002).
- An RP wiring the Phase-1 single-operator self-replenishing subscription as the *seam* the fungi layer
  later sits behind (so the client loop never changes across the phase transition, §15.8).

## Open research questions (carried from the deep-research, 2025–2026)
- **Sub-over-tunnel as default.** Which off-the-shelf clients route the subscription fetch *through the
  active tunnel* by default (so updates survive a blocked bootstrap channel), and how is it configured? Not
  established as standard behavior. Server-driven HTTP 301/308 endpoint-migration **is** documented and
  standard — the subscription standard specifies 301/308 redirect-following as a MUST — but it is doctrinally
  insufficient as a *sole* resilience mechanism: to learn the redirect the client must still reach the **old**
  origin, which is itself a `SINGLE_POINT_OF_BLOCK` (S0). So Mycelium treats redirect-based migration as **one
  signal among several**, never the sole migration path, and never a substitute for client-side multi-sub
  merge across independent origins (RP-0007-c/d).
- **Fast rotation signaling.** `profile-update-interval` is hour-granular — too coarse for sub-hour ingress
  rotation. What push / short-lived-config / next-fetch-hint mechanism rotates promptly without overloading
  fungi?
- **Fully-P2P deterministic-slice-plus-diff.** rdsys still has a central intake backend; achieving the
  slice+diff property with **no** central backend (only scoped spores) is the open frontier this Vision
  stakes out.
- **Coercion containment + re-key.** Combine Lox blocked-detection with rBridge credit metering to bound a
  seized/coerced fungus and re-issue a fresh partial view to honest neighbors.
