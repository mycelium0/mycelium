<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0024: `Immunity — temporary scoped cuts (clotting) and immune signals`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: Mycelium
> supports **immunity** — the capacity of a deployment to defend itself by performing **temporary,
> scoped, reversible, time-bounded, auditable-in-deployment, minimally-revealing cuts** (clotting)
> of a node / route / transport / bridge / corridor / trust scope / Commune, and by carrying
> **immune signals** (`abuse` / `quarantine` / `cut` / `rate_limit` / `corridor_revocation` /
> `bridge_risk` / `commune_policy`) that **never** carry raw traffic, identities, locations, or a
> complete topology map, and that **do** carry scope, severity, reason code, TTL, evidence class,
> signer-or-quorum, and a reversible action hint. **Heal requires clot.** Saved as
> `docs/adr/0024-immunity-temporary-cuts-and-signals.md`.
>
> **Scope note.** This ADR pins the **decision and the contract shape**. The end-to-end immune-system
> doctrine — Communes, Mycobiome, genetics, Anastomosis Bridges, sovereign defence — is the subject of
> its companion Vision; this ADR records the bound defensive primitive (cuts + signals) and its honest
> trade-offs. The new sovereign entity **Commune** introduced here is **not** an architectural layer:
> it is explicitly distinguished from the data / control / routing / discovery **planes**, which are
> the architectural layers and are **not** renamed (see §Decision, the Commune-vs-plane note).
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0011-carrier-agnostic-bridging.md](0011-carrier-agnostic-bridging.md),
> [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md),
> [0018-fungi-role-and-opt-in-publish.md](0018-fungi-role-and-opt-in-publish.md),
> [0021-decentralized-observability-not-a-central-collector.md](0021-decentralized-observability-not-a-central-collector.md),
> [../vision/0003-node-interaction-and-distributed-awareness.md](../vision/0003-node-interaction-and-distributed-awareness.md),
> [../vision/0004-living-network-doctrine.md](../vision/0004-living-network-doctrine.md),
> [../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md),
> [../THREAT-MODEL.md](../THREAT-MODEL.md), [../GLOSSARY.md](../GLOSSARY.md), `internal/spec/network.go`.

---

## Metadata

- **ID:** ADR-0024
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** proposed
- **Layer(s):** control plane (policy + signal carriage), discovery/membership (scope + bridge cuts),
  data plane (rate limit + transport cut enforcement), cross-cutting immune track
- **Phase:** cross-cutting. The cut and immune-signal **schemas are inert-typed now** (Phase 0-2,
  per [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)); **local** rate-limits,
  local quarantine, and the closed-by-default safe-defaults posture are **already-true / near-term**
  Phase-0 node behaviour (they follow from per-operator credentials and no open relay/egress, not from
  any cross-deployment machinery); **live** cross-deployment immune behaviour (gossiped immune signals,
  cross-Commune cut propagation, bridge-bound abuse propagation, quorum signers) is **Phase 5-6**.
- **Related:** the companion immunity/Communes Vision (the doctrine — Communes, Mycobiome, genetics,
  Anastomosis Bridges, sovereign defence, no global abuse oracle); VIS-0003 §4 (revocation/quarantine,
  merge-dominant quarantine, no auto-quarantine without an observable signal and a reversal path);
  VIS-0004 concept 9 (compartment wound response — *seal-before-global*; quarantine rides a
  threshold-signed, TTL-bounded spore); VIS-0006 / ADR-0021 (decentralized, no-central-collector
  observability — the immune signal is sensed locally and never tiles into a global map);
  ADR-0011 (bridges carry abuse-propagation / quarantine / revocation rules); ADR-0013 (inert
  Phase-0-2 schemas + vocabulary discipline); ADR-0014 (per-operator signer key material);
  ADR-0002 (no custom crypto — signers/quorum are standard primitives); ADR-0016 (software, not an
  operated network — no operator can flip a global switch); `internal/spec`
  (`TrustScope`, `StressSignal`, `ReasonCode`, `DecayPolicy`, `SporeEnvelope`, `SignerKeyID`,
  `QuarantinePolicy`-adjacent compartment state, `EdgeState` `dormant`/`scarred`).

## Context

Mycelium's prior canon optimises for **growth and reachability**: hyphae explore, anastomoses fuse,
cords carry, islands merge. That is the *heal* half of a living system. The missing half is **clot**.
A connectivity fabric that can grow through anything but cannot **cut** an infection is not resilient —
it is an attack substrate: a DDoS amplifier, a scanning relay, a malware command/control carrier, an
abuse-transit corridor, a platform one deployment can turn against another. **Resilience without
immunity turns a network into an attack substrate. A network that cannot cut infection is not alive —
it is already captured.**

This forces a defensive primitive into the architecture, and a hard constraint on how it may exist.

- **Adversary model.** This ADR addresses adversary capabilities the prior canon did not: **abuse
  *of* the fabric** (DDoS traffic, scanning, credential attacks, malware C2, hostile relay use, abuse
  transit, infrastructure attacks, one deployment using another as an attack platform), and the
  **inverse abuse — the cut itself as a weapon**: a global kill switch, a coercion-driven mass
  quarantine, a false-quarantine ratchet (VIS-0003 §4: a single coerced node asserting quarantines that
  dominate every future merge), or an immune signal that leaks the very thing the project hides (the
  **network map** — the adversary's single most valuable prize, [../THREAT-MODEL.md](../THREAT-MODEL.md)).
- **Affected asset.** Network map (an immune signal must not become a leaked topology) · ingress
  reachability · operators (a global cut authority is a coercion target) · the integrity of each
  deployment's right to defend itself · user identity/location (signals must never carry them).
- **Fundamental trade-off (the immune dilemma).** *Abuse resistance ↔ the global kill switch.* The
  obvious way to resist abuse is a global authority that can ban a bad node or deployment fabric-wide.
  That authority is exactly a global off-switch — the most dangerous artifact the project could ship,
  and a permanent coercion target ([ADR-0016](0016-software-releases-not-an-operated-network.md)). The
  companion trade-off is *defensive speed ↔ false-cut risk* (VIS-0003/VIS-0004: faster reaction buys
  faster false quarantine). This ADR resolves both by making the cut **local, scoped, reversible,
  time-bounded, and never globally authoritative.**

The schemas already encode the pieces this primitive composes from, all **inert** in Phase 0-2:
`TrustScope` (the bounded compartment a cut can isolate), `StressSignal` (a redacted, scoped,
aggregation-floored summary carrying a `ReasonCode` and a count, never raw traffic / identities /
location), `DecayPolicy` (how a record fades and is dropped — the basis for a time-bounded cut),
`SporeEnvelope` (the signed, TTL-bounded carrier whose revocation/quarantine spore type already
exists), `SignerKeyID` (per-operator signer, ADR-0014), and the `EdgeState` failure members
`dormant`/`scarred` (VIS-0004 §5 concept 6). VIS-0004 concept 9 already names the *seal-before-global*
compartment wound response. This ADR records the **bound decision** those pieces serve — that immunity
**is** canon, what a cut must be, and what a signal must (and must never) carry.

## Considered Options

> "Leave as is — grow only, never clot" is option 0 and is rejected by recording this ADR: a fabric
> that cannot cut infection is an attack substrate (the Canonical Rule).

1. **Global abuse oracle — a central authority (or quorum) that can ban a node/deployment fabric-wide.**
   - Pros: simplest mental model; one trusted list every node consults; instant fabric-wide ejection of
     a known-bad actor; familiar (CA-revocation / blocklist shaped).
   - Cons: **it is a global kill switch** — the single most dangerous artifact and a permanent coercion
     and seizure target; contradicts [ADR-0016](0016-software-releases-not-an-operated-network.md) (no
     operator owns the fabric); a compromise or coercion of the oracle bans honest deployments
     fabric-wide; centralises a decision that belongs to each sovereign deployment.
   - Impact on indistinguishability / survivability: catastrophic — one captured target controls
     reachability for everyone; abuse resistance becomes the adversary's off-switch.
2. **No immune system — rely on growth, decay, and operator firewalls only.**
   - Pros: no new cut authority to abuse; the architecture stays purely additive; no false-cut risk
     because there is no cut primitive.
   - Cons: leaves the fabric an attack substrate (the option-0 failure); decay is too slow and too
     coarse to clot an active DDoS/scan/C2; pushes every defence into ad-hoc per-operator firewalls
     with no shared vocabulary, no reversible/auditable contract, and no way for a bridge to express an
     abuse-propagation rule (ADR-0011 already requires one).
   - Impact on indistinguishability / survivability: negative — the fabric cannot defend itself, so a
     single abuser degrades shared transports for all participants.
3. **Local, scoped, reversible cuts + minimally-revealing immune signals; sovereignty per deployment;
   never a global authority (chosen).** Every deployment may **clot** — perform a temporary, scoped,
   reversible, time-bounded, auditable-in-deployment cut — and may emit/consume immune signals that
   carry only redacted decision metadata, never raw evidence. No global authority can ban anyone;
   fungi may *sign warnings*, deployments may *subscribe* or *ignore*, and bridge contracts decide
   which signals bind.
   - Pros: defends the fabric without ever building a global off-switch; matches the
     compartment-seal-before-global doctrine (VIS-0004 concept 9) and the bridge abuse-propagation
     contract (ADR-0011); a cut is auditable and self-healing by TTL, so a false or coerced cut decays;
     keeps each deployment sovereign over its own defence (ADR-0016); reuses existing inert schemas and
     standard-primitive signers (ADR-0002/ADR-0014).
   - Cons: a *local* cut cannot stop a fabric-wide abuser by itself (no global ejection — by design);
     requires careful signal design so the immune signal does not leak topology; cross-deployment
     propagation (Phase 5-6) re-introduces the false-quarantine-ratchet and merge-dominance hazards
     VIS-0003 §4 flags, which must be bounded (threshold/quorum, TTL, reversal path), not assumed away.
   - Impact on indistinguishability / survivability: strongly positive — no global target exists; a
     cut reveals minimal metadata, is reversible, and decays; the fabric clots locally and heals.

## Decision

**Option 3.** Immunity becomes canon. Mycelium supports **temporary scoped cuts (clotting)** and
**immune signals**, both governed by the invariants below. The Core provides the *compatibility* (the
cut and signal contract); each deployment provides the *life* (its own policy over that contract). No
global authority owns the fabric or its immune decisions.

**Commune-vs-plane note (binding terminology).** A **Commune** is a **new first-class sovereign
entity** introduced by this immune doctrine — a self-governing Mycelium deployment (family, company,
university, municipal, NGO, emergency-response society) with its own trust roots, governance, and
immune policy. A Commune is **not** an architectural layer. The architectural **planes** — *data
plane*, *control plane*, *routing plane*, *discovery plane* — are unchanged and are **not** renamed.
"Cut a Commune" means isolating a sovereign deployment-scope; it does not mean cutting a plane. Where
this ADR says "deployment-scope" it means the Commune scope; where it says "plane" it means the
architectural layer.

### Decision 1 — A cut is clotting: the seven cut properties

A **cut** is a defensive isolation of a compartment. Its scope may be a **node, a route, a transport,
a bridge, a corridor, a trust scope, or a Commune**. Every cut, in every phase, **must** be:

- **scoped** — it isolates exactly one named compartment (a `TrustScope`, an `EdgeState` edge, a
  transport, a bridge/corridor reference, or a Commune scope); it is never fabric-wide;
- **reversible** — there is always a defined un-cut path; a cut is a clot, not an amputation;
- **time-bounded** — it carries a TTL and **self-heals on expiry** (a `DecayPolicy`-governed lifetime),
  so a false or coerced cut decays rather than persisting;
- **auditable inside the affected Commune** — the Commune can see and account for its own cuts; audit
  is local to the deployment, never a global ledger;
- **minimally revealing** — a cut, and any signal announcing it, discloses only the decision metadata of
  Decision 2, never raw evidence;
- **independent of any global topology** — a cut neither requires nor produces a complete map; it acts
  on a local scope reference, consistent with VIS-0006/ADR-0021 (no central collector, no tiled map);
- **non-global** — no cut, and no composition of cuts, constitutes a fabric-wide ban (Decision 4).

**Canonical rule: the ability to heal requires the ability to clot.** Healing (growth, merge,
reinforcement) and clotting (the cut) are the two halves of one living system; the cut is the inverse
of the cord. This is the *seal-before-global* compartment wound response of VIS-0004 concept 9, here
made a bound primitive.

### Decision 2 — An immune signal: what it MUST and MUST NEVER carry

An **immune signal** is a redacted, scoped, TTL-bounded artifact announcing or requesting a defensive
action. The signal family is: **`abuse_signal`, `quarantine_signal`, `cut_signal`, `rate_limit_signal`,
`corridor_revocation`, `bridge_risk_signal`, `commune_policy_signal`.** Each rides the existing
`SporeEnvelope` carrier (signed, TTL-bounded — ADR-0011) and is **modelled inert now** alongside the
existing revocation/quarantine spore (no new signature or aggregation cryptography — ADR-0002/ADR-0014).

An immune signal **MUST NEVER contain** (hard NEVERs — these do not soften across phases):

- **raw traffic** (no payloads, no captured bytes, no flow records);
- **user identities** (no node-to-user binding, no account/credential material);
- **locations** (no IPs, no geography, no coordinates);
- **a complete topology map** (no full or tiling partial map — only a single scope reference; VIS-0006/
  ADR-0021).

An immune signal **MUST carry** exactly this decision metadata, and no free text that could smuggle PII:

- **scope** — the single compartment the action applies to (a `TrustScope` / edge / transport / bridge /
  corridor / Commune scope reference);
- **severity** — a coarse, enumerable severity class;
- **reason code** — a coarse, enumerable cause class (the `StressSignal.ReasonCode` discipline: a closed
  enum, never free-text PII);
- **TTL** — the expiry after which the signalled action self-heals (a `DecayPolicy`-governed lifetime);
- **evidence class** — a coarse, enumerable category of *what kind* of evidence motivated the action
  (never the evidence itself, never raw observations);
- **signer or quorum** — a per-operator `SignerKeyID` (ADR-0014) or a threshold/quorum of signers
  (standard primitive, ADR-0002), so a signal is attributable and a flood from one key is detectable;
- **reversible action hint** — the defined un-cut / recovery path for the action, so reversibility
  (Decision 1) is carried in the signal itself.

### Decision 3 — Local defence is near-term; cross-deployment immune behaviour is Phase 5-6

- **Already-true / near-term (Phase-0 node posture).** Local defence that needs **no** cross-deployment
  machinery is current or near-term, because it follows from the existing closed-by-default posture
  (per-operator credentials, no open relay, no public egress by default — ADR-0014, the safe defaults
  below): **local rate-limits** for untrusted scopes, **local quarantine** of suspicious behaviour, and
  the **safe-defaults** posture itself. These are a single node defending itself with its own policy and
  its own firewall — no signal needs to leave the node.
- **Inert-typed now (Phase 0-2).** The **cut schema** and the **immune-signal schemas** (Decision 1-2)
  are introduced **typed and inert** in `internal/spec`: schema-versioned, JSON-tagged, pure
  `Validate()`, signature only via standard primitive — **no emitter, no consumer, no propagation runs**
  (ADR-0013 Decision 2). A `cut_signal` you can *construct and validate* is not a `cut_signal` anything
  *acts on* before its phase.
- **Phase 5-6 (live).** **Cross-deployment** immune behaviour — gossiped immune signals, cross-Commune
  cut propagation, bridge-bound abuse propagation, quorum signers, subscribe/ignore of fungi-signed
  warnings — runs **no earlier than Phase 5-6**, after the Phase-transition principle is met, and only
  with the false-quarantine-ratchet and merge-dominance bounds VIS-0003 §4 requires (threshold/quorum
  signing, TTL self-heal, an observable signal + a reversal path — **no auto-quarantine without both**).

### Decision 4 — No global abuse oracle (the hard NEVER)

There is **NEVER** a global authority — no node, no operator, no fungi, no quorum — capable of banning
a node or a Commune fabric-wide. **Abuse resistance must not become a global kill switch.** Concretely:

- **fungi may *sign* warnings** (a `bridge_risk_signal` / `abuse_signal` is advisory, not a command);
- **Communes may *subscribe* to warnings, and may *ignore* them** — a warning binds a Commune only if
  the Commune's own genetics/policy says it does;
- **bridge contracts determine which signals are binding** across an Anastomosis Bridge (ADR-0011: a
  bridge already defines its abuse-propagation / quarantine / revocation rules; **no bridge exists
  unless explicitly established**);
- **all binding decisions are local** to the deciding Commune; no signal reaches across a deployment
  boundary as a command.

This preserves the existing hard NEVERs in one place: **never a global kill switch; signals never carry
raw traffic/identity/location/full map; anonymous egress is not a default primitive; no bridge without
an explicit contract.**

### Decision 5 — Safe defaults and capability classes (the closed-by-default posture)

The default node posture is **closed**: no open relay; no public egress by default; no unknown
third-party transit by default; no bridge without an explicit trust policy; no topology sharing by
default; rate limits for untrusted scopes; quarantine suspicious behaviour; local/community traffic
preferred over external transit. Traffic is distinguished by **capability class** (local control;
emergency coordination; messaging; signed-content replication; software updates; real-time media; relay
traffic; egress traffic; unknown bulk traffic): **higher-risk capabilities require stronger trust and
stronger immunity policy, and anonymous egress is NOT a default primitive.** No Commune is required to
relay all traffic, to trust all other Communes, or to remain connected during active abuse — these are
**policy-driven**, never controlled by a global authority. **Mycelium is not a universal bypass
substrate; it is a Mycobiome of sovereign Communes — the Core provides compatibility, the Communes
provide life.**

## Consequences

- **Positive:** the fabric can defend itself without ever building a global off-switch; a cut is
  scoped, reversible, time-bounded, auditable-in-Commune, and self-healing, so a false or coerced cut
  decays; immune signals carry only redacted decision metadata and never the network map; the contract
  reuses existing inert schemas (`TrustScope`, `StressSignal`, `DecayPolicy`, `SporeEnvelope`,
  `SignerKeyID`) and standard-primitive signers (ADR-0002/ADR-0014); each Commune stays sovereign over
  its own defence (ADR-0016); bridges gain a concrete abuse-propagation contract (ADR-0011).
- **Negative / cost (named honestly):**
  - A **local cut cannot stop a fabric-wide abuser** by itself — that is the deliberate price of
    refusing a global oracle; mitigation is per-Commune policy + bridge-bound, subscribable warnings,
    not a central ban.
  - **Cross-deployment propagation (Phase 5-6) re-opens the false-quarantine-ratchet and
    merge-dominance hazards** (VIS-0003 §4): a coerced node could assert false quarantines that
    dominate future merges. These are **bounded, not solved here** — they need threshold/quorum
    signing, TTL self-heal, and a reversal path, pinned by the spawned Phase-5-6 ADR, before any
    cross-Commune cut runs.
  - **A poorly designed signal could leak topology**; the closed reason/severity/evidence-class enums
    and the no-free-text rule are load-bearing and must be enforced, not assumed.
- **Impact on user security (requirement №1):** strongly positive — no global kill switch exists; no
  immune signal carries raw traffic, identity, location, or a map; cuts act on local scope references,
  not a global topology; defensive decisions stay local and auditable inside the Commune. The residual
  risk (cross-deployment propagation hazards) is named and deferred under a bound, not waved away.
- **Impact on observability/measurements:** the immune signal is **sensed locally and never tiles into
  a global view** (VIS-0006/ADR-0021); it adds a *defensive* signal class (severity + reason +
  evidence class) on top of the existing redacted `StressSignal`, with the same source-side redaction
  and no central collector. Cuts are observable only *within* the affected Commune's own audit.
- **Follow-on actions required:** add the immune-signal family + the cut schema to `internal/spec` as
  **inert typed** schemas (Decision 3) with `Validate()` and ADR-0002-compliant signer fields; add the
  Commune / Mycobiome / Anastomosis Bridge / immune-signal terms to [../GLOSSARY.md](../GLOSSARY.md)
  (distinguishing **Commune** from the architectural **planes**); land the companion immunity/Communes
  Vision as the home for the full doctrine; spawn the **Phase-5-6 cross-deployment immune ADR**
  (gossiped signals, cross-Commune cut propagation, quorum signers, with the false-quarantine /
  merge-dominance bounds); add the immune attack/abuse cases to [../THREAT-MODEL.md](../THREAT-MODEL.md)
  (the cut-as-weapon and abuse-of-fabric rows); reconcile the [refactoring.md](../refactoring.md) §7
  named-category table with the new Commune entity (distinct from planes).
- **What is now forbidden:** building a global abuse oracle / fabric-wide ban authority in **any**
  phase; a cut that is unscoped, irreversible, untimed, globally-authoritative, or that requires/produces
  a complete topology; an immune signal that carries raw traffic, identities, locations, or a full/tiling
  map, or that carries free-text where a closed enum is required; auto-quarantine without an observable
  signal **and** a reversal path; binding a Commune to a warning it did not subscribe to, or propagating
  a binding decision across a bridge without an explicit bridge contract (ADR-0011); running any
  cross-deployment immune propagation before Phase 5-6; renaming the architectural data/control/routing/
  discovery **planes** to "Commune".

## Compliance

How the decision is verified in practice:

- **`immune_signal_no_pii` conformance test** — asserts the immune-signal schemas
  (`abuse`/`quarantine`/`cut`/`rate_limit`/`corridor_revocation`/`bridge_risk`/`commune_policy`) carry
  **only** scope + severity + reason-code + TTL + evidence-class + signer/quorum + reversible-action-hint,
  and that no field admits free-text PII, raw traffic, identity, location, or more than a single scope
  reference (extends the existing `no_pii_in_telemetry` / aggregation-floor machinery; pairs with the
  `no_explorer_leak` posture of VIS-0006/ADR-0021).
- **`cut_is_reversible_and_bounded` conformance test** — asserts every cut schema requires a strictly
  positive TTL and a non-empty reversible-action / un-cut path, and that `Validate()` rejects an
  unscoped or unbounded (no-TTL) cut. A cut that cannot expire or cannot be reversed fails the gate.
- **`spec_inert` / `no_premature_mesh` (ADR-0013)** — the cut and immune-signal types import no network,
  file-I/O, or process-execution packages and link no emitter/consumer/propagation path; any
  cross-deployment immune propagation wired before Phase 5-6 fails the merge gate.
- **`no_global_oracle` review checkpoint** — code/doc review rejects any blocklist, ban list, or
  authority that is consulted fabric-wide or that can eject a node/Commune outside its own scope; a
  warning path must be advisory (signable, subscribable, ignorable), never a command, and any
  cross-bridge binding must trace to an explicit bridge contract (ADR-0011).
- **`no_custom_crypto` (ADR-0002)** — signer/quorum fields are key-id string(s) + signature bytes
  referencing a standard primitive only; defining any signature/threshold scheme fails.
- **Audit checkpoint** — a merge introducing an immune type also updates the GLOSSARY (with the
  Commune-vs-plane distinction) and the THREAT-MODEL immune rows, and references the companion Vision /
  the Phase-5-6 ADR; reviewers reject any softening of the hard NEVERs (global kill switch; raw
  traffic/identity/location/full-map in a signal; anonymous egress as a default; a bridge without a
  contract) and any cut that is not scoped-reversible-time-bounded-auditable-minimally-revealing-non-global.
