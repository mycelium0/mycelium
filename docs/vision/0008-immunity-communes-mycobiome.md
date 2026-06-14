<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — Immunity, Communes, and the Mycobiome (sovereign defense without a global oracle)

> **Document type.** Vision & Scope — "why and where", not a specification. The signal taxonomy's wire
> shapes, the cut state machine, the bridge contract grammar, the Commune genetic profile, and the
> immune-signal validation rules are pinned by the ADRs and inert schemas this Vision spawns (§13), not
> here. This document is now **canonical doctrine** — it does not water down a single principle below,
> and it preserves every hard NEVER and the Canonical Rule verbatim.
>
> **The one reframe that governs everything: a network that cannot cut infection is already captured.**
> Every prior Vision asked how Mycelium *heals* — how it reroutes around a blocked path, re-points a
> user to a sibling fungus, merges two islands, regrows through a cut carrier. This Vision adds the
> precondition the others assumed: **the ability to heal requires the ability to clot.** A living
> organism that cannot seal a wound does not stay open and generous — it bleeds out, or it becomes a
> carrier for whatever entered the wound. A resilient fabric optimized for universal availability *at
> any cost* is not resilient; it is an **attack substrate** — a free, global, indistinguishable
> transport that anyone can point at anyone. Resilience without immunity is not a softer form of
> safety; it is the absence of safety wearing resilience's coat. So immunity is not a feature bolted
> onto the mesh: it is the second half of the same property. **Mycelium must grow through anything;
> Mycelium must NOT attack through everything.** The fabric that cannot refuse to relay an attack is
> not alive — it is already someone else's weapon.

## Metadata
- **ID:** VIS-0008
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Horizon:** cross-cutting **Sovereignty & defense** track. Today (Phase 0–2): the *local*,
  closed-by-default node posture is **already true** — per-operator credentials, no open relay, no
  public egress, local rate limits, local quarantine; the cross-Commune machinery (immune signals,
  bridges, governance, cross-Commune trust) is **inert schema hooks only**. Immune-signal *emission*
  and scoped cuts that propagate are Phase 3–4; trust-gradient and cross-Commune actuation are Phase 5.
- **Layer(s):** governance / trust, control plane, discovery / membership, bridging (cross-cutting).
  **NOTE — this Vision introduces a NEW first-class entity, the *Commune*, which is NOT one of the
  architectural layer-*planes*.** The four layers (data plane, control plane, routing plane,
  discovery plane) keep their names and meaning unchanged; see §6.
- **Related:** [0001-mycelium-vision-and-scope.md](0001-mycelium-vision-and-scope.md) (core property),
  [0002-carrier-agnostic-mycelial-doctrine.md](0002-carrier-agnostic-mycelial-doctrine.md) (the spore /
  carrier doctrine immune signals ride), [0003-node-interaction-and-distributed-awareness.md](0003-node-interaction-and-distributed-awareness.md)
  (`SporeEnvelope`, `TrustScope`, `StressSignal`, `SignalSpeedClass`, knowledge gradient, the
  coordinator-is-not-a-kill-switch rule), [0004-living-network-doctrine.md](0004-living-network-doctrine.md)
  (concept 9 **Compartment wound response** — the existing seal-before-global state machine immunity
  generalizes), [0006-decentralized-observability.md](0006-decentralized-observability.md) (the redacted
  in-region signal an immune system needs to know *where* it is sick),
  [0007-fungi-served-subscription.md](0007-fungi-served-subscription.md) (fungi as warning signers, not
  global banners); [../adr/0011-carrier-agnostic-bridging.md](../adr/0011-carrier-agnostic-bridging.md)
  (a bridge is characterized by capability + risk — the seed of the Anastomosis Bridge contract),
  [../adr/0013-mycelial-vocabulary-and-phase-discipline.md](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)
  (phase discipline; biology load-bearing only where it names a contract),
  [../adr/0014-per-operator-node-credentials.md](../adr/0014-per-operator-node-credentials.md) (the
  per-operator trust root a Commune's genetics build on),
  [../adr/0016-software-releases-not-an-operated-network.md](../adr/0016-software-releases-not-an-operated-network.md)
  (software not an operated network; consensus governance — why no global authority can exist),
  [../adr/0018-fungi-role-and-opt-in-publish.md](../adr/0018-fungi-role-and-opt-in-publish.md) (the
  fungi niche that may sign warnings), [../adr/0021-decentralized-observability-not-a-central-collector.md](../adr/0021-decentralized-observability-not-a-central-collector.md)
  (no central collector — the immune analogue is no central oracle);
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (the "Mesh capture / takeover → self-healing response"
  section this Vision elevates to doctrine; "Assets"; the named-category matrix),
  [../refactoring.md](../refactoring.md) §7 (named finding categories this spawns),
  [../GLOSSARY.md](../GLOSSARY.md), [../ROADMAP.md](../ROADMAP.md).

## 1. Problem and context — resilience without immunity is an attack substrate

The threat model this Vision answers is the project's own success. Every property Mycelium builds for
the blocked user — block-resistant transports, carrier-agnostic bridging, self-healing reroute,
self-propagating ingress — is, viewed from the wrong end, a recipe for a **free, indistinguishable,
hard-to-block, self-repairing relay network**. The same fabric that lets a person reach the open
network past interference can be pointed *outward*: as a DDoS amplifier, a scanning platform, a
malware command/control carrier, a credential-stuffing relay, an abuse-transit corridor, or — the
sharpest case — **one society using another society's fabric as an attack platform** it never agreed
to host. A fabric that cannot say *no* to any of these is not a public good; it is a public hazard,
and one that invites exactly the wholesale, collateral-damage blocking the project exists to survive.

The existing canon already anticipated the *inward* version of this — a captured, coerced, or
taken-over node — and answered it with the THREAT-MODEL's **detect → quarantine → revoke scoped trust
→ decay poisoned routes → reroute around the captured region → never crown a permanent centre**
sequence (Phase 5 self-healing), and with VIS-0004's concept 9 **Compartment wound response** (a
suspicious region seals into a healing scope *before any global action*). This Vision does two things
the canon had not: it (a) **generalizes that immune response from the single node/region to the whole
ecosystem** — including the cross-society case — and (b) **names the sovereign entity that holds the
immune policy**: the Commune. Why now: VIS-0006 gives the fabric the redacted in-region signal an
immune system needs to know *where* it is sick; VIS-0007 opens membership and distribution, which is
exactly when the attack-substrate risk goes from theoretical to live (S0 the moment membership opens).
Immunity must be doctrine *before* the machinery that creates the exposure ships.

## 2. Vision (desired outcome)

When this initiative is complete, Mycelium is not "a network" but a **Mycobiome** — an ecosystem of
sovereign **Communes**, compatible by protocol, that can cooperate, coexist, isolate, specialize, and
evolve independently. Each Commune can *defend itself*: it can refuse to relay traffic it did not
consent to, rate-limit and quarantine abuse, scope-cut an infected node/route/bridge/corridor, and
sever a bridge to a misbehaving peer Commune — all by **local policy**, none of it by a global
authority's leave. The property for the user is unchanged and *strengthened*: reliable private
connectivity, given a channel and one working node — **plus** the assurance that the fabric they
depend on will not be drowned, poisoned, or blocked-by-collateral because it could not refuse to carry
an attack. Healing and clotting are the same organism's two reflexes; the user gets both.

## 3. Principles governing this initiative (compatibility with the core)

- [x] **Do not reinvent cryptography or transport.** Immune signals are signed `SporeEnvelope`s using
  standard primitives via key-id + signature bytes ([../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md));
  quorum signing reuses the threshold-signing the hard signal class already assumes (VIS-0003/0004).
- [x] **Indistinguishability over obfuscation.** A cut is *minimally revealing* (§5): isolating a scope
  must not announce, to an outside observer, that a cut happened or where — the cut is a local policy
  state, not a broadcast.
- [x] **Phase discipline.** Local safe-defaults / local cuts / local rate-limits / local quarantine are
  current node posture; cross-Commune immune signals, Anastomosis Bridges, Commune governance, and
  cross-Commune trust are Phase 4–5 with **inert schema hooks** definable now
  ([../adr/0013-mycelial-vocabulary-and-phase-discipline.md](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)).
- [x] **No global authority / no master map.** The immune system has **no global abuse oracle** (§10),
  exactly as the observability layer has no central collector (ADR-0021) and the topology has no master
  map (THREAT-MODEL Assets #5). Abuse resistance must never become a global kill switch.
- [x] **Software, not an operated network; consensus governance.** Global Mycelium owns no Commune
  ([../adr/0016-software-releases-not-an-operated-network.md](../adr/0016-software-releases-not-an-operated-network.md));
  the Core provides compatibility, Communes provide life and policy.
- [x] **Signal-speed non-escalation.** A fast/medium immune signal can never by itself revoke or
  quarantine; only a threshold-signed hard `SporeEnvelope` actuates, and only within scope (VIS-0003/0004).

## 4. New principle — Immunity

**Mycelium must not optimize for universal availability at any cost.** A resilient network that cannot
defend itself becomes a carrier for parasites. **The network must support defensive behavior.**
Communes must be capable of protecting themselves from: DDoS traffic; scanning; credential attacks;
malware command/control; hostile relay use; abuse transit; infrastructure attacks; and **one Commune
using another Commune as an attack platform.** Three hard non-obligations follow, and they are
canonical:

- **No Commune is required to relay all traffic.**
- **No Commune is required to trust all other Communes.**
- **No Commune is required to remain connected during active abuse.**

These invert the naive reading of "resilient": the right to *refuse* is the immune complement to the
right to *reach*. Immunity is not in tension with the core property — it is its precondition (§1).

## 5. Temporary Cuts (clotting)

**A living organism must be capable of clotting.** Mycelium must support **temporary, scoped cuts**. A
cut may isolate: **a node, a route, a transport, a bridge, a corridor, a trust scope, a Commune.**
Cuts are not the inverse of the fabric's healing reflexes; they are the *same* state machine running in
the sealing direction — VIS-0004 concept 9's Compartment wound response, generalized so the sealable
scope can be as small as one edge or as large as a peer Commune. Every cut MUST be:

- **scoped** — bounded by a `TrustScope`; never network-wide;
- **reversible** — a cut is a clot, not an amputation; it dissolves;
- **time-bounded** — carries a TTL; false seals self-heal on expiry (the same "false seals self-heal"
  property VIS-0004 already requires of compartments);
- **auditable inside the affected Commune** — the Commune can account for its own cuts;
- **minimally revealing** — a cut does not broadcast its existence, location, or cause to outside
  observers (indistinguishability invariant, §3);
- **independent of any global topology** — a cut needs no global map and produces none; it is a local
  policy state over a local scope.

**Rule: the ability to heal requires the ability to clot.** The cut state machine maps onto the
existing edge lifecycle — `EdgeState`'s `scarred` member (a dangerous/suspicious edge needing stronger
evidence before reuse) is already the "clotted, reversible" state for a single edge; this Vision
generalizes that semantics up to route / transport / bridge / corridor / trust-scope / Commune scope.

## 6. Communes — sovereign societies (distinct from layer-planes)

**The term "Plane" — as a name for a sovereign entity — is introduced here as the Commune; it does NOT
rename the architectural layer-planes.** This distinction is load-bearing and must not be blurred:

- The **layer-planes** (data plane, control plane, routing plane, discovery plane) are *architectural
  layers* of a single node's stack. They keep their names and meaning unchanged everywhere in the canon.
- A **Mycelium Commune** is a *sovereign Mycelium society* — a deployment with its own governance. It
  is a **new first-class entity**, not a layer. Examples: a family, a company, a university, a
  municipality, an NGO, an emergency-response group, a state Commune.

A Commune possesses its own: **trust roots; governance; update policy; bridge policy; immune system;
observability policy; fungi quorum; acceptable-use rules.** **Global Mycelium does not own Communes.
Communes are first-class entities.** This is the natural home for the per-operator trust root
([ADR-0014](../adr/0014-per-operator-node-credentials.md)) and the per-Commune observability policy
(VIS-0006): the Commune is the boundary inside which "the operator's own fleet" already lives today.

## 7. Commune Genetics

**Every Commune possesses a genetic profile:** trust roots; accepted signers; governance rules; bridge
policies; immunity policies; transport policies; observability policies; trust propagation rules. **Two
Communes may run identical software while having completely different genetics.** This is the deepest
consequence of "software, not an operated network" ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)):
the Core is the genome-reader, not the genome. **Communes are compatible by protocol, not by
authority** — the same binary, configured by two different genetic profiles, yields two societies that
interoperate without either submitting to the other.

## 8. The Mycobiome

**The collection of all compatible Communes is the Mycobiome. Not a single network — an ecosystem.**
Communes may **cooperate, coexist, remain isolated, specialize, evolve independently, without losing
interoperability.** The Mycobiome has no center, no roster, and no owner; it is defined intensionally
("everything that speaks the protocol") not extensionally (a list) — which is exactly why no global
map, no global directory, and no global oracle can exist over it (THREAT-MODEL Assets #5; ADR-0021).

## 9. Anastomosis Bridges

**Communes communicate through explicit bridges: Anastomosis Bridges.** This reuses the fabric's
existing fusion primitive — *anastomosis* is already the load-bearing term for "two exploring paths
fuse where useful" (GLOSSARY; VIS-0003) — and lifts it from edge-fusion to **society-fusion**, governed
by an explicit contract. A bridge defines: **trust relationships; allowed traffic classes; forbidden
traffic classes; abuse propagation rules; quarantine rules; bridge revocation rules; recovery rules;
evidence requirements.** It is the cross-Commune generalization of the carrier-bridge characterization
([ADR-0011](../adr/0011-carrier-agnostic-bridging.md)): where ADR-0011 says a *carrier* bridge carries
a capability + risk descriptor, an Anastomosis Bridge carries a *full contract* between two sovereign
genetics. **Default rule: no bridge exists unless explicitly established.** (This preserves the hard
NEVER: *no bridge without an explicit contract.*)

## 10. Sovereign Defense & No Global Abuse Oracle

**Every Commune must be capable of self-defense.** A Commune may, by policy, *accept*
educational / emergency / update traffic while *rejecting* anonymous relay, unknown egress, bulk
scanning, or specific bridges, and *quarantine* suspicious nodes. **These are policy-driven, not
controlled by a global authority.**

And the hard ceiling on all of it — the principle that keeps abuse-resistance from becoming the very
weapon the project denies:

> **There must NEVER be a global authority capable of banning nodes or Communes network-wide.** Local
> decisions belong to local Communes. **Fungi may sign warnings. Communes may subscribe to warnings.
> Communes may ignore warnings.** Bridge contracts determine which signals are binding. **Rule: abuse
> resistance must not become a global kill switch.**

This is the immune-system mirror of the rules already in canon: *the coordinator is not a kill-switch*
(VIS-0003/0004; development.md §2.2), *no central collector* (ADR-0021), *never crown a permanent
centre* (THREAT-MODEL self-healing). A fungus signing a warning is the exact analogue of a fungus
emitting a stress-digest — a redacted, signed, TTL-bounded, **advisory** signal that no one is obliged
to obey. Subscription, not subjugation.

## 11. Immune Signals (the taxonomy + the never/should rules)

Future phases may introduce immune-system signals — each a typed `SporeEnvelope` payload, carried at
the **hard** `SignalSpeedClass` where it actuates (threshold-signed, scope-bounded, TTL-bounded), or
the **medium** class where it only advises:

| Immune signal | Carries (advisory or actuating) | Scope analogue in canon |
|---|---|---|
| `abuse_signal` | a redacted report that a scope is emitting abuse | medium; like `StressSignal` for misuse |
| `quarantine_signal` | seal a scope into a healing compartment | hard; VIS-0004 concept 9 / `QuarantinePolicy` |
| `cut_signal` | a temporary scoped cut (§5) | hard; the clotting state machine |
| `rate_limit_signal` | tighten the rate ceiling for an untrusted scope | medium; the local default already runs |
| `corridor_revocation` | withdraw a previously-allowed transit corridor | hard; trust-scoped revocation |
| `bridge_risk_signal` | a peer-Commune bridge's risk class rose | medium; ADR-0011 risk descriptor, cross-Commune |
| `commune_policy_signal` | a Commune's published acceptable-use / immunity stance | medium; genetics (§7) made legible to peers |

The redaction rules are **canonical and absolute** — they are the immune-system instance of the spore
doctrine (VIS-0002 §3) and the `TELEMETRY_SAFETY_VIOLATION` boundary (refactoring §7):

- **Signals must NEVER contain:** raw traffic; user identities; locations; complete topology maps.
- **Signals should contain:** scope; severity; reason code; TTL; evidence class; signer or quorum; a
  reversible action hint.

The "reversible action hint" is doctrine, not decoration: a signal proposes a *reversible* action
(consistent with §5), never an irreversible one, and never an action wider than its scope.

## 12. Traffic Capability Classes & Safe Defaults

**Distinguish capability classes** — and gate higher-risk ones behind stronger trust and stronger
immunity policy:

> local control · emergency coordination · messaging · signed content replication · software updates ·
> real-time media · relay traffic · egress traffic · unknown bulk traffic.

**Higher-risk capabilities require stronger trust and stronger immunity policies. Anonymous egress is
NOT a default primitive.** This is the capability-class refinement of VIS-0004's flow-class ladder: the
ladder graded *quality*; this grades *risk and consent*. The two compose — a carrier offers a flow
class; a Commune's genetics decide which *capability* classes may ride it, for whom.

**Safe Defaults — the default node posture (largely Phase-0-true today):**

> no open relay; no public egress by default; no unknown third-party transit by default; no bridge
> without explicit trust policy; no topology sharing by default; rate limits for untrusted scopes;
> quarantine suspicious behavior; local/community traffic preferred over external transit.

**Honest phase split.** The closed-by-default posture is **already the current node reality**: per-operator
credentials ([ADR-0014](../adr/0014-per-operator-node-credentials.md)), no open relay / no public
egress (THREAT-MODEL; ARCHITECTURE Layer 3 — ingress and egress coincide on one node in Phase 0–2,
nothing is an open relay), no topology sharing (no gossip runs), the host firewall opening no exporter
port (VIS-0006 §7). Local rate-limits and local quarantine are near-term node-local behaviors. What is
**Phase 4–5** is the *propagating* machinery: cross-Commune immune signals, capability-class
negotiation across an Anastomosis Bridge, and trust-gradient-driven hand-out of higher-risk
capabilities (Phase 5). The schemas for all of it are inert hooks definable now (§13).

## 13. Phase path & what this spawns

**Phase discipline ([ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)).** Phases 0–2
ship inert typed schemas + the already-true local closed-by-default posture; gossip / DHT / membership
(and therefore propagating immune signals, cuts that cross a scope boundary, and Anastomosis Bridges)
are Phase 3–4; the trust-gradient that grades cross-Commune capability is Phase 5.

- **Phase 0–2 (now):** local safe-defaults, local rate-limits, local quarantine, the closed-by-default
  node posture — **running**. Commune / genetics / immune-signal / bridge schemas — **inert hooks**.
- **Phase 3–4:** immune-signal *emission* over scoped gossip; cuts that propagate within scope;
  Anastomosis Bridge contracts established and revoked; fungi-signed warnings (advisory) published.
- **Phase 5:** trust-gradient grading of higher-risk capability classes; cross-Commune trust
  propagation; cut/quarantine actuation across a bridge — always reversible, scoped, TTL-bounded.

**ADRs this Vision spawns (0023–0026, all written):**
- **[ADR-0023](../adr/0023-communes-mycobiome-genetics.md) — Communes, the Mycobiome, and Commune
  Genetics** (*written*). Pins the Commune as a first-class entity *distinct from the layer-planes*;
  defines the genetic-profile fields (trust roots, accepted signers, governance, bridge / immunity /
  transport / observability policies, trust-propagation rules); states "compatible by protocol, not by
  authority"; names the Mycobiome as an intensional ecosystem with no roster, center, or owner.
- **[ADR-0024](../adr/0024-immunity-temporary-cuts-and-signals.md) — Immunity: temporary scoped cuts
  (clotting) + immune signals** (*written*). Pins the single bound defensive primitive in two halves:
  (a) the **cut** invariants (scoped, reversible, time-bounded, auditable-in-deployment,
  minimally-revealing, global-topology-independent) generalizing VIS-0004 concept 9 /
  `EdgeState.scarred` up to route / transport / bridge / corridor / trust-scope / Commune; and (b) the
  seven **immune signals** (§11), their `SignalSpeedClass` mapping, the absolute NEVER-contains list,
  the should-contain list, and the "reversible action hint" rule. **Heal requires clot.**
- **[ADR-0025](../adr/0025-no-global-abuse-oracle.md) — No global abuse oracle** (*written*). Pins the
  hard ceiling (§10): never a global authority able to ban a node or Commune network-wide; fungi may
  sign warnings, Communes may subscribe or ignore, bridge contracts decide which signals bind, local
  decisions stay local; abuse resistance must not become a global kill switch.
- **[ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md) — Anastomosis Bridges, traffic
  capability classes, and the closed-by-default safe defaults** (*written*). Pins the bridge contract
  grammar (trust, allowed / forbidden classes, abuse-propagation, quarantine, revocation, recovery,
  evidence), the default "no bridge without an explicit contract," the capability-class list, the
  closed-by-default node posture, and "anonymous egress is not a default primitive."

**Inert schemas (`internal/spec`, data-model + `Validate()` only, no behavior — ADR-0013):**
`Commune` / `CommuneGenetics` (trust roots, signers, policy bundles); `ImmuneSignal` payload union
(`abuse_signal`, `quarantine_signal`, `cut_signal`, `rate_limit_signal`, `corridor_revocation`,
`bridge_risk_signal`, `commune_policy_signal`) carried in `SporeEnvelope`; `CutScope` /
`CutPolicy` (extends the `QuarantinePolicy`-adjacent compartment, VIS-0004); `AnastomosisBridge`
contract; `TrafficCapabilityClass` enum + `CapabilityPolicy`. Each MUST carry a `TrustScope` and a
TTL; each MUST reject (in `Validate()`) any payload bearing raw traffic, identity, location, or a full
map.

**Named finding categories (refactoring §7) this spawns** — so audits name the new failure modes
consistently:
- `GLOBAL_ABUSE_ORACLE_DRIFT` (**S0**) — any component (fungus, coordinator, bridge, island-merge)
  acquiring the power to ban a node/Commune network-wide, or any "warning" becoming *binding* outside a
  bridge contract. The immune-system sibling of `COORDINATOR_SUPERGOD_DRIFT` / `FORBIDDEN_TOPOLOGY_CENTRALIZATION`.
- `IRREVERSIBLE_OR_UNSCOPED_CUT` (**S1**; **S0** if global) — a cut that is not scoped, not TTL-bounded,
  not reversible, or that depends on / produces global topology. The clotting analogue of `SILENT_DEGRADATION`.
- `IMMUNE_SIGNAL_OVERREACH` (**S1**; **S0** if it carries identity/location/destination) — an immune
  signal carrying more than {scope, severity, reason code, TTL, evidence class, signer/quorum, action
  hint}. A specialization of `TELEMETRY_SAFETY_VIOLATION`.
- `IMPLICIT_BRIDGE` / `CAPABILITY_OVERREACH` (**S0**) — a cross-Commune bridge active without an
  explicit contract, or a higher-risk capability class (relay / egress / unknown bulk) carried without
  the required trust + immunity policy. Joins `UNSAFE_ROUTING_OR_UNAUTHORIZED_BRIDGE_USE`.

## 14. Non-goals / the hard NEVERs (preserved, not watered down)

- **NEVER a global kill switch.** No global authority may ban a node or Commune network-wide; abuse
  resistance must not become a global kill switch (§10). Fungi sign warnings; Communes may ignore them.
- **NEVER a global abuse oracle / master map.** The Mycobiome has no roster, no directory, no center.
- **Immune signals NEVER carry** raw traffic, user identity, location, or a complete topology map.
- **NEVER a bridge without an explicit contract.** Default: no bridge exists unless explicitly established.
- **Anonymous egress is NOT a default primitive**, and is never silently enabled by a fallback path.
- **No cut is irreversible, unscoped, or global** — clotting, not amputation.

## 15. The Canonical Rule

> **Mycelium is not a universal bypass substrate. Mycelium is a Mycobiome composed of sovereign
> Communes. The Core provides compatibility. Communes provide life. Communes may cooperate, isolate,
> defend themselves, evolve different genetics. No global authority owns the Mycobiome. Mycelium must
> grow through anything. Mycelium must NOT attack through everything. A network that cannot cut
> infection is not alive — it is already captured.**
