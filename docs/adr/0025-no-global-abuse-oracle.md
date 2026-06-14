<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0025: `No global abuse oracle — abuse resistance is not a global kill switch`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: there is
> **NEVER** a global authority able to ban a node or a Commune network-wide, and abuse resistance
> **MUST NOT** become a global kill switch. Fungi may **sign** warnings; Communes may **subscribe** to
> or **ignore** them; **bridge contracts** determine which signals are binding; **local decisions stay
> local**. The end-to-end immunity doctrine (Communes, Anastomosis bridges, immune signals, sovereign
> defense) is the subject of [../vision/0008-immunity-communes-mycobiome.md](../vision/0008-immunity-communes-mycobiome.md);
> this ADR records **one** of its bound decisions and its honest trade-offs. Saved as
> `docs/adr/0025-no-global-abuse-oracle.md`.

---

## Metadata
- **ID:** ADR-0025
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** discovery/membership, control plane, project governance (cross-cutting)
- **Phase:** cross-cutting; the prohibition **binds now**; warning signing/subscription and bridge-bound
  enforcement are Phase 4–5 (gossip/membership), with **inert typed schema hooks** definable now
  ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md))
- **Related:** [../vision/0008-immunity-communes-mycobiome.md](../vision/0008-immunity-communes-mycobiome.md) (the doctrine);
  [0021-decentralized-observability-not-a-central-collector.md](0021-decentralized-observability-not-a-central-collector.md)
  and [../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md) (no central collector / no central map — the structural parent of this prohibition);
  [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md) (no single owner/operator; consensus governance);
  [0018-fungi-role-and-opt-in-publish.md](0018-fungi-role-and-opt-in-publish.md) (fungi sign TTL-bounded `SporeEnvelope`s — the same signer/role contract that signs warnings);
  [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md) (per-operator signer key material; no shared network key);
  [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md) (warning signatures use standard audited primitives);
  ADR-0023 (Communes as first-class sovereign entities) and ADR-0024 (Anastomosis bridges as the only inter-Commune channel) — the entities this decision constrains;
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (operator coercion; the network map is the adversary's prize);
  [../refactoring.md](../refactoring.md) §7 (`FORBIDDEN_TOPOLOGY_CENTRALIZATION` / `SINGLE_POINT_OF_BLOCK`).

## Context
The immunity doctrine ([VIS-0008](../vision/0008-immunity-communes-mycobiome.md)) makes self-defense
canonical: a resilient network that cannot defend itself becomes a carrier for parasites, so a Commune
(a sovereign Mycelium society — distinct from the architectural *planes*, the data/control/routing/discovery
**layers**, which are not renamed) must be able to refuse relay, refuse trust, clot off infection, and
quarantine suspicious behavior. The doctrine introduces **immune signals** (`abuse_signal`,
`quarantine_signal`, `cut_signal`, `rate_limit_signal`, `corridor_revocation`, `bridge_risk_signal`,
`commune_policy_signal`) that carry abuse intelligence between participants.

This creates an obvious and dangerous temptation: a single trusted authority — or a single registry /
reputation service / blocklist feed — that nodes and Communes consult to decide who is "abusive", and
that can therefore ban a node or a whole Commune **network-wide**. That is the immune system inverted
into a weapon. Several forces pull against it, all decisive:

- **Adversary model — operator coercion.** A global authority that can ban network-wide is exactly the
  single coercion/seizure target the architecture exists to deny ([../THREAT-MODEL.md](../THREAT-MODEL.md):
  *Operator coercion*). Compel the one oracle and you can sever any node, any Commune, or the whole
  Mycobiome — the same compel-one-learn-everything / compel-one-cut-everything failure already rejected
  for the central collector ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md)).
- **Affected asset — the network map + reachability.** To ban network-wide, an oracle must know who and
  where everyone is and must be the path everyone's enforcement runs through. That **is** a master map
  plus a single point of block — the precise asset [ADR-0021](0021-decentralized-observability-not-a-central-collector.md)
  and VIS-0006 deny, and the structural defect named `FORBIDDEN_TOPOLOGY_CENTRALIZATION` /
  `SINGLE_POINT_OF_BLOCK` ([../refactoring.md](../refactoring.md) §7).
- **Posture — software, not an operated network.** A binding global ban authority would re-introduce a
  central operated service with an owner, contradicting [ADR-0016](0016-software-releases-not-an-operated-network.md):
  no person/maintainer owns or operates the network; the Mycobiome has no global authority.
- **Fundamental trade-off (openness ↔ sybil-resistance, stated honestly).** Removing the global oracle
  forfeits a clean, globally-consistent abuse verdict and a fast network-wide takedown of a genuinely
  malicious node. That capability is real, and so is its inverse: any mechanism strong enough to take
  down a bad actor everywhere is strong enough to take down a *targeted* actor everywhere. The doctrine
  resolves this in favor of survivability: **a network that cannot cut infection is not alive; a network
  that can be cut from one place is already captured.**

## Considered Options
> "Leave the temptation open" is option 0.

1. **A global abuse oracle / network-wide blocklist authority (option 0).** One signed authority (or a
   small fixed quorum) whose verdicts every node/Commune is required to honor; a banned node or Commune
   is cut everywhere.
   - Pros: globally consistent, unambiguous abuse verdicts; fast network-wide takedown of a genuinely
     malicious actor; simple mental model ("the bad list"); no per-Commune policy divergence to reason
     about.
   - Cons: it **is** a global kill switch and a single coercion/seizure target; requires (and therefore
     builds) the master map of who/where to enforce against; a false or coerced verdict severs the
     innocent everywhere; contradicts ADR-0016, ADR-0021, and the doctrine's *No Global Abuse Oracle*
     principle; concentrates the most dangerous authority in the system in one place.
   - Impact on survivability: **catastrophic on compromise** — one coerced/seized verdict can sever any
     node, any Commune, or the whole Mycobiome.

2. **No global oracle: signed, advisory, locally-evaluated warnings, bridge-bound enforcement (chosen).**
   No authority can ban network-wide. Fungi may **sign** warnings (TTL-bounded, scoped, advisory).
   Communes may **subscribe** to or **ignore** any warning source. **Bridge contracts** ([ADR-0024])
   decide which signals are binding across an Anastomosis bridge. Every ban/cut/quarantine is a **local**
   Commune decision, scoped to that Commune (and to its explicitly bridged peers per their contracts).
   - Pros: no global kill switch and no single coercion target by construction; no master map is required
     to enforce (enforcement is local and scoped); aligns with ADR-0016/0021 and the doctrine; preserves
     genuine self-defense — a Commune can still cut, clot, and quarantine, just never on someone else's
     behalf without consent; warnings reuse the existing fungi/`SporeEnvelope` signer contract
     ([ADR-0018], [ADR-0014], [ADR-0002]).
   - Cons: **no globally consistent verdict** — the same actor may be trusted in one Commune and banned
     in another; **no fast network-wide takedown** of a genuinely malicious node; a Commune that ignores
     good warnings can harbor abuse (its own and its bridged peers' problem to manage, not the network's
     to force); warning **subscription itself** is a trust relationship that can be gamed (Sybil warning
     sources, poisoned reputation) and is only *bounded* by scope/TTL/quorum, not solved.
   - Impact on survivability: degrades gracefully; abuse is contained Commune-by-Commune; no single
     target yields a network-wide cut.

3. **A "soft" global oracle — globally published warnings that are advisory by default but that the
   reference build honors unless overridden.** A published feed everyone consumes; the default is to obey.
   - Pros: keeps most of option 1's consistency with a nominal opt-out.
   - Cons: an *honored-by-default* global feed is a de-facto kill switch — the default **is** the policy,
     and the default path is the coercion target; "advisory unless overridden" collapses to "binding" for
     the majority who never override. Rejected: a default-binding global feed is a global oracle wearing
     an opt-out badge.

## Decision
**Option 2.** It becomes **canon** that Mycelium has **no global abuse oracle**: there is **NEVER** a
global authority — no registry, reputation service, blocklist feed, signer, or quorum — capable of banning
a node or a Commune network-wide, and abuse resistance **MUST NOT** become a global kill switch. This is
the immune-system corollary of the no-central-map / no-central-collector canon
([ADR-0021](0021-decentralized-observability-not-a-central-collector.md), VIS-0006): the network already
refuses a global *view*; it equally refuses a global *verdict*.

Specifically, the following bind:

- **Fungi may SIGN warnings.** A warning is an advisory, signed, **scoped + TTL-bounded** immune signal,
  carried in the same envelope contract fungi already use ([ADR-0018](0018-fungi-role-and-opt-in-publish.md):
  the per-operator-signed, TTL-bounded `SporeEnvelope`; [ADR-0014](0014-per-operator-node-credentials.md):
  `signer_key_id` + signature; [ADR-0002](0002-no-custom-cryptography.md): standard audited primitives,
  no custom crypto). A warning carries **scope, severity, reason code, TTL, evidence class, signer or
  quorum, and a reversible action hint** — and, per the doctrine's hard NEVER, it carries **no raw
  traffic, no user identities, no locations, and no complete topology map.** Signing a warning grants its
  signer **no enforcement power** over anyone.

- **Communes may SUBSCRIBE or IGNORE.** Consuming a warning source is a **per-Commune** choice; ignoring
  every warning source is always permitted. No node is required to subscribe to any warning feed, and no
  warning is binding merely because it was validly signed. Subscription is a trust relationship the
  Commune owns, not an obligation the network imposes.

- **Bridge contracts determine which signals are binding.** Whether an immune signal has any *binding*
  effect across an Anastomosis bridge is decided **only** by that bridge's explicit contract
  (ADR-0024: a bridge defines abuse-propagation rules, quarantine rules, evidence requirements,
  revocation/recovery rules). Absent an explicit contract clause making a signal class binding, a signal
  is advisory. There is no implicit, ambient, or default-on cross-Commune enforcement.

- **Local decisions stay local.** Every ban / cut / quarantine / rate-limit is a **local** decision of
  the deciding Commune, scoped to that Commune and to its explicitly-bridged peers per their contracts.
  A Commune defending itself (refusing relay, clotting a route, quarantining a node — the **already-true
  Phase-0 closed-by-default posture**: no open relay, no public egress, per-operator credentials,
  ADR-0014) is exercising sovereign self-defense, **not** acting as an authority over anyone else.

- **Fail-closed direction.** The fail-closed default here is **non-enforcement, not enforcement**: an
  unrecognized, unsubscribed, unverifiable, or contract-unbound warning has **no** binding effect. A
  signal becomes binding only by explicit, verifiable subscription **and** an explicit bridge-contract
  clause — never by default, never by silence.

**Phase discipline** ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)): the *prohibition*
binds immediately and applies to every phase. The *machinery* — signed warnings, subscription, and
bridge-bound enforcement — is Phase 4–5 (it depends on gossip/membership, which do not exist before then);
only **inert, typed schema hooks** (e.g. a closed `ReasonCode` enum, a `Warning`/immune-signal schema with
`Validate()` and no runtime consumer) may be defined earlier. The closed-by-default local posture (option
2's "local decisions stay local" floor: no open relay, no public egress, local rate-limits, local
quarantine) is **already-true Phase-0 node posture** and is framed as current, not future.

## Consequences
- **Positive:** no global kill switch and no single coercion/seizure target for abuse enforcement, by
  construction; no master map is required to enforce policy (enforcement is local and scoped); alignment
  with ADR-0016 (no owner/operator), ADR-0021 + VIS-0006 (no central map/collector), and the doctrine's
  *No Global Abuse Oracle* and *Canonical Rule*; genuine self-defense is preserved — a Commune can cut,
  clot, and quarantine without being able to do so on anyone else's behalf; warnings reuse the audited
  fungi/`SporeEnvelope`/per-operator-signer contract rather than inventing a new authority.
- **Negative / cost (named honestly, not soft-pedalled):**
  - **No globally consistent abuse verdict.** The same actor may be trusted in one Commune and banned in
    another; there is no single answer to "is this node abusive?".
  - **No fast network-wide takedown** of a genuinely malicious node — containment is Commune-by-Commune
    and as slow as the slowest Commune chooses to be; a Commune that ignores good warnings can harbor
    abuse.
  - **Subscription is itself a trust surface** — Sybil/poisoned warning sources are only *bounded* by
    scope, TTL, quorum, and the consuming Commune's own judgement, **not solved** (the same
    cumulative-disclosure / Sybil class left open in ADR-0021; future ADR/RP work, not a claim of
    resistance now).
- **Impact on user security (requirement №1):** strongly positive — there is no global authority that
  could be compelled to cut a user's access or a Commune's connectivity network-wide; warnings are
  structurally forbidden from carrying identity, location, raw traffic, or a full map ([VIS-0008];
  [../THREAT-MODEL.md](../THREAT-MODEL.md)). No correlation channel is introduced by the warning path
  beyond what the existing redacted `SporeEnvelope` already permits.
- **Impact on observability/measurements:** none added to the collection path; warnings are an
  **advisory output** of existing redacted signals, not a new collector. Any binding cross-Commune effect
  is gated on an explicit bridge contract, not on a measurement feed.
- **Follow-on actions required:** the Phase-4–5 immune-signal schema ADR (closed `ReasonCode` enum,
  `Warning`/`AbuseSignal` typed schema with `Validate()`, evidence-class taxonomy) — inert hooks only
  until gossip/membership land; the bridge-contract binding-grammar (ADR-0024) must define how a contract
  clause makes a signal class binding; an RP for the warning publish/subscribe path that reuses the
  fungi/`SporeEnvelope` signer contract.
- **What is now forbidden:** building **any** global authority, registry, reputation service, blocklist
  feed, signer, or quorum whose verdicts can ban a node or Commune network-wide, or that any node/Commune
  is **required** to honor; making any warning **binding by default** (default-on, ambient, or
  "advisory-unless-overridden" global enforcement); enforcing an abuse signal across a bridge **without**
  an explicit bridge-contract clause; any warning carrying raw traffic, user identity, location, or a
  complete topology map.

## Compliance
How to verify the decision is respected in practice:
- **`no_global_abuse_oracle` conformance gate** (to be added to the conformance suite + named in
  [../development.md](../development.md)): rejects any code path or config that (a) treats a warning as
  binding without an explicit subscription **and** an explicit bridge-contract clause, (b) ships a
  default-on / required-by-default warning feed, or (c) builds a registry/reputation/blocklist authority
  with network-wide ban scope. A binding global oracle is an **S0** under
  `SINGLE_POINT_OF_BLOCK` + `FORBIDDEN_TOPOLOGY_CENTRALIZATION` ([../refactoring.md](../refactoring.md)
  §7) — it is simultaneously a global kill switch and a coercion target — and blocks merge.
- The immune-signal/`Warning` schema (when introduced) carries **only** scope, severity, reason code,
  TTL, evidence class, signer/quorum, and a reversible action hint, enforced by `Validate()`; a leak
  check rejects any warning field carrying identity, location, raw traffic, or a full map (reusing the
  existing no-leak invariant of the telemetry path, ADR-0021/ADR-0018).
- Warning signatures use a standard audited primitive (`no_custom_crypto`, [ADR-0002](0002-no-custom-cryptography.md))
  and the per-operator signer key id (ADR-0014) — code/doc review rejects a new shared "abuse-authority"
  key.
- Code/doc review rejects any text or interface asserting that a fungus, quorum, or feed can ban
  network-wide, or that any warning is binding by default; the negated form ("Communes may ignore
  warnings"; "no global authority can ban network-wide") is the only permitted framing.
