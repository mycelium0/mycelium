<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0031: Build-vs-reuse — compose proven patterns, do not reinvent

## Metadata
- **ID:** ADR-0031
- **Date:** 2026-06-17
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** cross-cutting (architecture / dependency strategy)
- **Phase:** cross-cutting — decisions bind from Phase 2 onward; **not a phase gate**
- **Related:** [ROADMAP.md](../ROADMAP.md) "Build-vs-reuse" principle; [ADR-0010](0010-phase0-transport-set.md) (closed transport set); [ADR-0012](0012-go-primary-control-plane-language.md) (Go spine); [ADR-0018](0018-fungi-role-and-opt-in-publish.md) (fungi role) + [ADR-0029](0029-community-federated-ingress.md) (anastomosis) — amended by the federation section below; [ADR-0025](0025-no-global-abuse-oracle.md) + [ADR-0030](0030-advisory-network-awareness.md) (advisory never actuates / topology-not-a-map); [ADR-0027](0027-selective-growth-and-in-region-ingress.md) (in-region ingress); [RP-0008](../proposals/0008-go-spine-distribution-rendering.md) (Go spine); [RP-0010](../proposals/0010-phase2-adaptivity.md) (Phase-2 adaptivity — consumes the ADOPT/WRAP decisions here). Prompted by an operator prior-art analysis + the pre-Phase-2 research (2026-06-17).

## Context

Mycelium is **software for resilient, secure connectivity**. It is viable as an **engineering composition of proven patterns** — not as novel network biology. Every building block the roadmap needs already has battle-tested prior art; reimplementing those from scratch lowers the odds of success and widens the attack surface. The "fungal" vocabulary is a **metaphor** for local rules, decay, redundancy, and scoped trust — never a licence for uncontrolled self-organisation.

A pre-Phase-2 research pass (prior-art survey → mapping → adversarial verification) confirmed this and produced concrete, license-checked reuse decisions. This ADR records them so the project has a single answer to "build or reuse?" per component, and so the ROADMAP's forward-reference to "the build-vs-reuse ADR" resolves.

**Two framing constraints bind this and every downstream design doc** (see also the project's neutral-wording discipline):
1. Describe mechanisms as **resilient secure connectivity** / blocking-resistance / reachability under restrictive conditions. Do not frame Mycelium as an apparatus-specific tool.
2. **Mycelium does not claim or guarantee anonymity.** It is legal software whose purpose is resilient connectivity, not identity concealment; an anonymity-focused variant is out of scope and may be forked. Consequently the "measurement must not become an oracle" concern is about **network-topology / operator-federation-graph leakage** (telemetry must not become a *map* of who runs or peers with whom), **not** user de-anonymisation.

## Decision

Adopt a four-verdict discipline — **ADOPT / WRAP / BUILD / DEFER** — and apply it per component. Permissive upstream licences (MIT/BSD/Apache-2.0) and LGPL/GPL-with-linking are one-way compatible into Mycelium's AGPL-3.0-or-later; Mycelium stays AGPL and retains upstream notices.

| Component | Verdict | Decision + rationale |
|---|---|---|
| **Phase-2 local-rule self-tuning** (per transport-class/path weight) | **ADOPT** | Take *only* the standard reinforce-and-evaporate **scoring law** — **EWMA / exponential-smoothing** reinforcement + **exponential time-decay** + **control-theory Schmitt-trigger hysteresis** — a few-line scoring update over the **closed** transport set ([ADR-0010](0010-phase0-transport-set.md)), **not** a routing/discovery protocol. It maps directly onto the existing `spec.DecayPolicy` (HalfLife + Hysteresis = flap-damping + RetentionFloor = "scar memory"). The Physarum/Tero-2010 (Science 2010) + ant-colony imagery is the bio-inspired **metaphor** for the decay-and-scar intuition, **not** the literal implemented equation. *(Attribution corrected 2026-06-19: a build-vs-reuse audit confirmed the implemented law is EWMA + exponential decay + hysteresis — both already on this list — and not the Tero-2010 tube-conductivity model; the reuse is named accurately so a reviewer can check it.)* |
| **Phase-2 edge-measurement signal** | **WRAP** | Reuse the already-built `internal/reach` Monitor/Registry/Prober (produces fast-class `spec.TransportHealth`, strictly node-local per ADR-0019; never classifies state, rotates, or assembles topology). No new measurement code. |
| **Phase-2 connectivity-state detector** {clean / throttled / blocked / shutdown} | **BUILD** | The one true build. No prior-art primitive classifies our specific signatures — throughput collapse *after* a successful connect (destination-AS, "~16 KB then stall", ADR-0027), single-stream behavioral degradation (Phase-1 on-device finding), active-probe failure. Fed from the WRAP'd `internal/reach` signal; decisions must be measurable (precision/recall on labelled incidents). |
| **Spore artifacts** (signed, TTL-bounded bootstrap / route-hint / revocation) | **ADOPT** | Model on the DTN Bundle Protocol v7 (RFC 9171) primary-block field set — creation timestamp + lifetime/TTL + issuer + a detached BPSec-style signature; "delete on lifetime expired"; Bundle-Age "don't trust the carrier clock" — plus Briar's transport-agnostic handshake thinking. **Control plane ONLY** (bootstrap/route/trust/revocation): spores must NEVER carry the low-latency data path (BPv7 has no latency bound) and must NOT inherit BPv7 status-report machinery (a topology-leak surface). |
| **P2P connectivity substrate** (peer identity, multi-transport, NAT traversal, relays) | **DEFER → Phase 4+** | libp2p (MIT OR Apache-2.0; clean into AGPL). ADOPT the **connectivity layer only** — Circuit-Relay v2 + DCUtR + AutoNATv2 + self-certifying identity — when relay/NAT becomes the bottleneck. NAT traversal is a *solved, measured* problem (~70% decentralized hole-punch, TCP≈QUIC); reuse it. **Run it private/permissioned (no public DHT — a topology-enumeration surface) and behind Mycelium's own transports** — libp2p's wire shape is recognisable and is plumbing, never the outermost layer or the blocking-resistance brick. |
| **Encrypted self-healing mesh overlay** (PK-derived addressing) | **DEFER → Phase 4/6** | Yggdrasil-go (LGPL-3.0 + linking exception) / cjdns (GPL-3.0). Borrow **patterns** only (self-certifying PK-derived addressing, self-healing). Mesh routing and blocking-resistant transport are **orthogonal** — these nail addressing/self-healing, they are not a connectivity-resilience layer. |
| **Volunteer / federated ingress edge** ([ADR-0029](0029-community-federated-ingress.md)) | **WRAP → Phase 4+** | Borrow the Snowflake *architecture* (BSD-3): relay-preferred, **content-blind** untrusted edge; rendezvous **decoupled** from the data path; NAT-aware matching. **Do NOT inherit a uniform protocol fingerprint** — Snowflake's real-world weakness is its single recognisable signature; Mycelium's edges keep transport diversity. |

## Federation / friend-to-friend — amends ADR-0018 and ADR-0029

The operator's fungi model is **friend-to-friend (F2F)**, and the research confirms this is a *structural advantage*, not a limitation: Mycelium's operator-controlled → invite-only → scoped-trust posture is a **stronger starting position against sybil/abuse** than open-mesh designs. The decisions:

- **Peering is invite-only — mutual key exchange, no public-explorer discovery.** Reachability *is* the key exchange; there is no global directory to enumerate. This is the anti-enumeration property, and it is the federation analogue of the friend-to-friend / darknet model (RetroShare, Freenet darknet mode, Briar).
- **A fungi introduces its peers (Briar-style contact-introduction).** With **mutual consent**, a fungi hands each side ephemeral rendezvous + key material for the other — a scoped, TTL-bounded capability (a spore), **not** a long-term identity — then steps back; the two derive a **direct** channel that **survives the introducer's departure** (resilience without a permanent hub).
- **Bounded horizon (policy, default 1–2 hops).** Introduced parties do not inherit the introducer's other neighbours; weather and topology propagate with a decreasing hop-scope, so no fungi assembles the transitive graph. This is the topology-leak control (per the framing constraint above and [ADR-0030](0030-advisory-network-awareness.md)).

**Anastomosis security requirements** (operator, 2026-06-17 — amend [ADR-0029](0029-community-federated-ingress.md), to be specified for Phase 3–5):
1. **Variable-weight links (thin ↔ thick).** Not all fungi connect, and live links carry variable capacity/trust — some barely-alive (thin), some load-bearing (thick).
2. **A new anastomosis must not become thick.** Thickness (capacity/trust to carry load) is **earned over time** from observed good behaviour; a fresh peering starts **thin and capacity-graduated**. Otherwise a new link is a **population-on-population attack** vector (flood/takeover).
3. **Capture-containment.** Compromise of a child node or a fungi must not propagate along anastomoses/fungi — blast-radius limiting via thin-by-default + the bounded horizon + signed/scoped/TTL spores (no unsigned code or config flows across a link). A captured fungi can affect only its thin links and ~1 hop, never the federation.

These are **Phase 3–5 federation behaviour** (per [ROADMAP.md](../ROADMAP.md) scope discipline / MYC-F006); Phase 2 builds only the inert seams + the local adaptivity ([RP-0010](../proposals/0010-phase2-adaptivity.md)). The **weather-publish** half rides Phase 2 self-healing and lands in the new Phase 3 ([ADR-0030](0030-advisory-network-awareness.md)); the **peering/introduction/anastomosis** half is deferred.

## Consequences

- The ROADMAP forward-reference resolves; RP-0010 consumes the ADOPT (the reinforce-and-evaporate scoring law — EWMA + decay + hysteresis) and WRAP (`internal/reach`) decisions and owns the BUILD (detector).
- Reuse stays **behind** Mycelium's own transports and **inside** the scoped→federated→open-mesh trajectory; nothing here pulls a later-phase mechanism into early runtime (the inert-interface rule holds).
- Every reuse is license-checked into AGPL; the per-component verdicts are revisited only when a component's phase arrives.
- The self-organisation ↔ blocking-resistance conflict (discovery = enumeration surface, telemetry = topology-map risk, rotation = observable signal, volunteers = sybil/abuse) is *why* each open mechanism is DEFERred behind invite-only/scoped trust — not adopted early.
