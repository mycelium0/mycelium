<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0011: Phase-2 fungi-role packaging + deployment/management CLI

## Metadata
- **ID:** RP-0011
- **Slug:** `phase2-fungi-packaging-cli`
- **Status:** **DRAFT — proposed** (Phase-2 deliverable; gated behind the signed Phase-1 GO, [phase1-acceptance-ledger.md](../phase1-acceptance-ledger.md))
- **Phase:** Phase 2 (the package + CLI + the introduction *mechanism*); the live anastomosis *bridge runtime* is exercised at the Phase-2 → 3 boundary and matures in Phase 3–4
- **Type:** single-workstream RP (packaging + CLI), with an inert federation seam
- **Related:** [ADR-0018](../adr/0018-fungi-role-and-opt-in-publish.md) (fungi role / opt-in publish) + [ADR-0029](../adr/0029-community-federated-ingress.md) (anastomosis bridges) — this RP specifies the introduction constraints those ADRs deferred; [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md) (build-vs-reuse / F2F federation); [ADR-0030](../adr/0030-advisory-network-awareness.md) (class-aggregate redacted weather); [ADR-0024](../adr/0024-immunity-temporary-cuts-and-signals.md) (Communes/immunity); [ADR-0012](../adr/0012-go-primary-control-plane-language.md) + [RP-0008](0008-go-spine-distribution-rendering.md) (the Go spine this CLI is built on); [RP-0010](0010-phase2-adaptivity.md) (Phase-2 adaptivity, sibling). Prompted by an operator design note (2026-06-17).

## Rationale

Phase 2 needs Mycelium to become **deployable and manageable by others as a release** — a package with a minimal **deployment + management CLI** — so that additional **fungi** can be stood up and **anastomosis** can be tested at the Phase-2 → 3 boundary. This is the concrete enabler for the federation layer: you cannot test communes joining until a second operator can stand up a fungi from a release in minutes.

It is also the natural home for the maturing Go spine: **continue the shell → Go migration ([RP-0008](0008-go-spine-distribution-rendering.md) P3) through Phase 2**, so the management CLI is the Go-spine binary (already render-time-resident on nodes since RP-0008 P3 chunk 1), not new bash.

Framing: this is **software for resilient, secure connectivity**. It does **not** claim or guarantee anonymity (an anonymity-focused variant is out of scope and may be forked).

## The model

**Commune = a population + its fungi** (the existing immunity/Commune doctrine, [ADR-0024](../adr/0024-immunity-temporary-cuts-and-signals.md)):

```
Commune A:  ordinary nodes A1 A2 A3  +  fungi FA
Commune B:  ordinary nodes B1 B2     +  fungi FB
Commune C:  ordinary nodes C1 C2 C3  +  fungi FC
```

**Fungi is a ROLE / niche, not a second node *type*.** Any sufficiently capable node may temporarily take the fungi-role. Biological framing (also the UX vocabulary):
- ordinary node = **hypha / tissue**;
- fungi = **fruiting body / cap (шляпка) / population coordinator** ("fruiting node").

A fungi does **four things**:
1. **holds** its own node population;
2. **issues/updates the bundle** for its population (the RP-0007 self-replenishing subscription it already serves);
3. **collects redacted network-weather** — class-aggregate, no per-node row ([ADR-0030](../adr/0030-advisory-network-awareness.md));
4. **establishes private bridges with other fungi** (anastomosis).

An ordinary node may "grow" to a fungi if it knows its **address/key** — but an ordinary node need **not** know the whole commune, and certainly not neighbouring communes. Knowledge is local and need-to-know.

## Anastomosis — the introduction model

The key property: **the introducer is not a permanent route.** It *initiates fusion* and can then step away.

```
FA knows FB and FC.
FA is NOT obliged to be the forever-route between FB and FC.
FA MAY offer to introduce them.
If FB and FC BOTH consent, they create a direct private bridge.
FA can then be turned off; FB ↔ FC stay connected.
```

This is *stronger* than ordinary friend-to-friend: the network can **close useful links itself**, so it survives the loss of any single fungi. (Briar-style contact-introduction is the proven primitive — see [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md).)

### Hard constraints — no auto-clique
Auto-introducing everyone to everyone produces a fast-growing clique → structure leakage, attack-surface growth, uncontrolled trust, and a near-global map via neighbours. Therefore, by construction:

- **max introduction depth: 1–2 hops** (a policy, not a constant);
- **max degree per fungi** (bounded number of live bridges);
- **TTL on bridge invitations** (a scoped, expiring capability — a spore, [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md));
- **double opt-in** (both fungi must consent; never one-sided);
- **no neighbour-list sharing** (a fungi never reveals who else it peers with);
- **no automatic transitive trust**; **no "friend-of-friend is trusted."**

Plus the [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md) anastomosis rules: a **new** bridge starts **thin** and cannot become thick without earned, observed good behaviour (anti population-on-population attack); a captured node/fungi is **contained** (no malicious propagation along anastomoses).

### The invariant
> **A fungi MAY introduce. A fungi MUST NOT enumerate.**

This is the federation analogue of [ADR-0030](../adr/0030-advisory-network-awareness.md)'s "advisory, never a map": introduction is a consented, scoped, expiring act; enumeration (a list/graph of peers, transitive neighbour discovery) is forbidden by construction.

## Scope

**In scope (Phase 2):**
- A **release package** of the Go-spine control binary + the deployment/management CLI (continuing [RP-0008](0008-go-spine-distribution-rendering.md) P3 so the renderers are Go, not bash).
- A **minimal management CLI** for the fungi-role: stand up / tear down a fungi; manage its population; issue/refresh its bundle; publish its redacted class-aggregate weather ([ADR-0030](../adr/0030-advisory-network-awareness.md)); and the **bridge-invitation mechanism** with all constraints above (double opt-in, TTL, depth/degree caps).
- The introduction mechanism's **inert/seam parts** land behind proof gates (like the existing weather/immunity schemas) — the *issuing and consuming of a scoped, double-opt-in, TTL-bounded bridge invitation*, with **no neighbour enumeration anywhere**.

**Deferred (Phase 2 → 3 boundary / Phase 3–4):** the live anastomosis bridge runtime (FB ↔ FC carrying traffic, FA stepping away), per the trajectory discipline (ROADMAP / MYC-F006). Phase 2 proves the package, the CLI, and the introduction *mechanism*; the federation *runtime* is exercised at the boundary and matures next.

**Out of scope:** anonymity; global discovery / DHT / gossip; auto-clique / transitive trust (forbidden above); new transport protocols (the set is closed, [ADR-0010](../adr/0010-phase0-transport-set.md)).

## Acceptance criteria
- **AC-1 (deployable release):** a second operator can stand up a fungi from the release package via the CLI in minutes (mirrors the Phase-0 one-command bootstrap), with no manual fixups.
- **AC-2 (the four functions):** a stood-up fungi holds its population, serves/refreshes its bundle, and publishes a redacted class-aggregate weather snapshot (ADR-0030 gates stay green).
- **AC-3 (introduction, constrained):** the CLI can issue a bridge invitation that is double-opt-in, TTL-bounded, and depth/degree-capped; a conformance gate proves **no code path enumerates or shares a neighbour list** ("must not enumerate"), and that a new bridge cannot start thick.
- **AC-4 (anastomosis survives the introducer — boundary test):** two fungi introduced via the CLI form a direct bridge; turning the introducer off leaves the bridge intact. (Exercised at the Phase-2 → 3 boundary.)
- **AC-5 (Go-spine, not bash):** the CLI is the Go spine (RP-0008 P3); no new control-decisions-in-bash; `no_new_control_decisions_in_bash` stays green.
- **AC-6 (framing):** the resilient-secure-connectivity voice throughout (no apparatus-specific or jurisdiction framing), no anonymity claim, and no per-node/IP/location leakage in any artifact or CLI output.

## Risks / notes
- The release widens who can run a fungi → the sybil/abuse surface; mitigated by invite-only peering + the thin-by-default / earned-thickness rule + capture-containment ([ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md)).
- "Must not enumerate" is the load-bearing privacy invariant — it must be a *gate*, not a guideline.
- This RP depends on RP-0008 P3 maturing the Go renderers; sequence it after the bundle renderer ports so the CLI manages Go-rendered artifacts.
