<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0028: `Dependency and transport-currency policy`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: because
> version currency of the transport stack is **load-bearing for indistinguishability** (not merely a
> hygiene nicety), the project adopts a **dependency- and transport-currency policy** — declared
> version **floors** to migrate toward, a **refresh cadence** tied to engine-pin bumps plus a
> quarterly source sweep, a recorded **engine-asymmetry** map (which hardening lives in which
> engine), and a **living landscape annex** that holds the evidence and watch-list. Saved as
> `docs/adr/0028-dependency-and-transport-currency-policy.md`.
>
> **Scope note.** This ADR records a **policy**, not a network change. The version floors below are
> **migration targets**: they declare the floor the repository's pins should move toward and the
> conformance that detects drift. Actually **bumping a live pin** is a separate, careful deploy —
> staged on **one node first** with the dependency-policy `Verification:` block and the conformance
> run, per [../dependency-policy.md](../dependency-policy.md) §3–§4 — and is out of scope here. This
> ADR does not bump any pin and does not change any deployed node. It is Phase-0 currency work
> (version-pin hardening of **existing** shapes), consistent with the inert-schema / hardening
> discipline of [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md); it introduces no
> automated selection, gossip, route-finding, or bridge logic (those remain Phase 3-5).
>
> **See also:** [0010-phase0-transport-set.md](0010-phase0-transport-set.md) (the transport set and
> engine selection this policy keeps current — sing-box primary, Xray optional, AmneziaWG a separate
> path), [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md) (currency is **adopting**
> upstream primitives, never forking them), [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md)
> (phase discipline — this is Phase-0 hardening), [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md)
> (software, not an operated network; **not a universal bypass substrate** — currency improves
> shapes, it does not make the set a universal reach guarantee), [0027-selective-growth-and-in-region-ingress.md](0027-selective-growth-and-in-region-ingress.md)
> (the destination-AS download-throughput throttle and the cross-layer RTT fingerprint are answered
> at the routing/topology layer, **never** claimed beaten by any transport-version bump here),
> [../dependency-policy.md](../dependency-policy.md) (the supply-chain mechanics — pin-by-hash,
> signature verification, staged update, `Verification:` block — that this policy's floors plug
> into), [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Metadata
- **ID:** ADR-0028
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** data plane (transport stack currency), touching infra (supply chain / CI) — cross-cutting track
- **Phase:** Phase 0 (version-pin hardening of existing shapes; see [../ROADMAP.md](../ROADMAP.md))
- **Related:** [ADR-0002](0002-no-custom-cryptography.md), [ADR-0010](0010-phase0-transport-set.md),
  [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md), [ADR-0016](0016-software-releases-not-an-operated-network.md),
  [ADR-0027](0027-selective-growth-and-in-region-ingress.md), [../dependency-policy.md](../dependency-policy.md),
  net4people/bbs (github.com/net4people/bbs), gfw.report

## Context

[ADR-0010](0010-phase0-transport-set.md) standardised the transport **set** and the engine
selection; [../dependency-policy.md](../dependency-policy.md) standardised the supply-chain
**mechanics** (pin by version and hash, verify signatures, stage updates, record a `Verification:`
block). What is missing between them is a **currency policy**: a declared statement of *which
versions the shapes must migrate toward, why, and how drift is detected* — independent of any single
update event.

A frontier review of the transport landscape (the living annex this ADR introduces) found that the
set already contains every distinct, currently-effective **shape** a frontier service deploys
(REALITY+Vision, REALITY+gRPC, REALITY+XHTTP, genuine-TLS XHTTP, WS+TLS, Hysteria2+Salamander,
TUIC, AmneziaWG, ShadowTLS). The honest weakness is not breadth — it is **maintenance currency**.
The same review found that several pieces of hardening shipped upstream in 2025–2026 are now
**load-bearing for indistinguishability**, meaning a node running the older pin is *more detectable*,
not merely less featureful:

- **uTLS fingerprint currency.** The TLS handshake mimicry that REALITY relies on must keep its
  fingerprint inside the live real-browser population; an out-of-date fingerprint is itself a
  detection handle, and two upstream advisories (CVE-2026-26995, CVE-2026-27017) bear on the
  fingerprint/GREASE-ECH surface. Currency here directly reduces a passive-detection signal.
- **Post-handshake mimicry (the Aparecium differential).** A laboratory technique distinguishes a
  REALITY endpoint from a genuine TLS-terminating donor by a **post-handshake** (NewSessionTicket)
  behavioural difference; the fix is shipped upstream and a node on the older pin remains
  distinguishable under active probing.
- **Post-quantum handshake population.** A rising share of ordinary browser handshakes now carry the
  X25519MLKEM768 key-share; a REALITY donor and engine that cannot speak it fall **outside** the
  growing real population — again a passive-detection signal.
- **Obfuscated-UDP per-packet currency.** The static-parameter form of the obfuscated WireGuard path
  was identified in a high-interference network; the per-packet-randomised successor (AmneziaWG 2.0)
  defeats the static-parameter fingerprint.

The second structural finding is **engine asymmetry**: the strongest 2025–2026 hardening lives in
the **Xray** and **awg** engines, **not** in sing-box (the [ADR-0010](0010-phase0-transport-set.md)
primary). Specifically, the post-quantum REALITY handshake, post-handshake mimicry, the
VLESS-Encryption construction, and AmneziaWG 2.0 are **xray-only or awg-only** today; sing-box
parity is unconfirmed or absent. This is exactly the situation
[ADR-0010](0010-phase0-transport-set.md)'s "Xray retained as an optional alternative engine" escape
hatch exists for, but it must be **recorded** so an operator who needs a given hardening knows which
engine to serve it on.

- **Adversary model** (see [../THREAT-MODEL.md](../THREAT-MODEL.md)): passive DPI signature matching
  and ML traffic classification (an aged TLS fingerprint or a non-PQ handshake is the signal), and
  **active probing** (the post-handshake differential). This ADR addresses the *currency* dimension
  of those detectors; it does **not** address — and must not be read as addressing — the destination-AS
  download-throughput throttle or the cross-layer RTT fingerprint, which are answered only at the
  routing/topology layer ([ADR-0027](0027-selective-growth-and-in-region-ingress.md)).
- **Affected asset:** ingress reachability and, through indistinguishability, user identity/location
  — a detectable handshake undermines every shape sharing that address.
- **Fundamental trade-off:** indistinguishability ↔ adaptation speed / false-migration risk.
  Chasing every upstream tag risks a bad pin reaching the network; never moving lets the shapes age
  into detectability. The resolution is to **separate the policy (floors + cadence, recorded here)
  from the act (a staged, one-node-first deploy under [../dependency-policy.md](../dependency-policy.md))**,
  so the target is declared and audited while the bump stays careful.

## Considered Options

1. **Leave currency implicit** — option 0, leave as is. Rely on
   [../dependency-policy.md](../dependency-policy.md)'s update cadence and ad-hoc judgement; record no
   floors and no engine-asymmetry map.
   - Pros: nothing new to maintain; no risk of a recorded floor going stale.
   - Cons: "what version should this shape be at, and why" stays in maintainers' heads; the
     engine-asymmetry finding is lost; nothing detects pin drift; the load-bearing nature of
     currency is not written down, so it is treated as optional.
   - Impact on indistinguishability / survivability: shapes silently age into detectability; the
     review's central finding (currency is load-bearing) is not actionable.

2. **Declare floors and force-bump all live pins to them now** — record the floors and immediately
   migrate the network to satisfy them in one move.
   - Pros: the deployed set is current the moment the ADR lands.
   - Cons: collapses the policy and the act; a single unvetted bump touching the whole network is
     exactly the staged-update anti-pattern [../dependency-policy.md](../dependency-policy.md) §3–§4
     forbids; one bad pin becomes a network-wide outage or a network-wide new signature.
   - Impact on indistinguishability / survivability: high blast radius; trades a slow detectability
     risk for an acute deployment risk.

3. **Adopt a currency *policy*: declared floors as migration targets, a cadence tied to engine-pin
   bumps plus a quarterly source sweep, a recorded engine-asymmetry map, an offline conformance gate
   that detects drift, and a living landscape annex — with the actual bump left to a separate,
   one-node-first deploy** (chosen).
   - Pros: separates the durable policy from the careful act; makes currency auditable without
     forcing a risky move; records the engine-asymmetry escape hatch; keeps the arms-race evidence
     in one maintained place instead of churning ADRs.
   - Cons: the floors and the annex must be kept honest (a stale annex is itself misleading); adds
     one offline gate and one runbook probe to maintain.
   - Impact on indistinguishability / survivability: currency becomes a tracked, gated property;
     shapes migrate toward the live population deliberately rather than aging silently.

## Decision

**Option 3.** The project adopts a **dependency- and transport-currency policy**. The floors below
are **migration targets** that the repository's pins must move toward; the **act** of bumping a live
pin is a separate, staged, **one-node-first** deploy governed by
[../dependency-policy.md](../dependency-policy.md) (pin by version and hash, verify the signature,
record a `Verification:` block, run conformance). This ADR records the policy and does **not** bump
any pin or change any deployed node.

### 1. Currency is load-bearing (the canon this ADR binds)

Version currency of the transport stack is hereby **canon** as a property of
indistinguishability, not an optional nicety. A shape running below its declared floor is treated as
a **detectability defect**, in the same family as shipping a fingerprintable legacy shape — to be
recorded and scheduled, not ignored. This does **not** alter
[ADR-0010](0010-phase0-transport-set.md)'s set or [ADR-0002](0002-no-custom-cryptography.md)'s
no-custom-crypto rule: currency means **adopting** vetted upstream primitives faster, never forking
or hand-rolling them.

### 2. Declared version floors (migration targets)

| Stack element | Floor (migrate toward) | What the floor buys | Engine |
|---|---|---|---|
| **uTLS fingerprint library** | `>= 1.8.2`-equivalent (whatever the pinned engines vendor) | Closes the CVE-2026-26995 / CVE-2026-27017 surface; keeps the handshake fingerprint inside the live real-browser population | both (vendored by sing-box and Xray) |
| **Xray-core** (post-handshake mimicry) | `>= v26.3.27` (minimum acceptable `v25.6.8`) | Closes the post-handshake (NewSessionTicket) active-probe differential vs OpenSSL-backed donors | **xray** |
| **Xray-core** (PQ REALITY handshake) | PQ-capable build (X25519MLKEM768; donor cert in the larger-record range) | Keeps the handshake inside the rising X25519MLKEM768 population | **xray** |
| **AmneziaWG** | 2.0-class (ranged headers, per-packet padding; retain the 1.5 control-plane-shaping fields; do **not** spec the removed timing fields) | Per-packet randomisation defeats the static-parameter fingerprint that exposed the 1.x form | **awg** (separate service) |
| **sing-box** | latest pinned release; **parity gaps noted, not assumed** | Keeps the QUIC/UDP and TLS-family shapes current where sing-box *does* have parity | **sing-box** |

Floors are expressed as **equivalents** ("`>= X`-equivalent", "PQ-capable build") because the exact
satisfying tag depends on what the pinned engine vendors at bump time; the conformance gate compares
the **recorded** pins against the **documented** floors (see Compliance), it does not fetch upstream.

**Machine-readable floors** — the exact grammar `tests/conformance/dependency_policy.sh` parses (a
recorded pin below any of these fails the gate; a line with no matching in-repo pin, such as uTLS, is
informational, never a failure). These are kept at or below the current recorded pins so a bump is a
deliberate, separate change, never a silent regression:

    floor: singbox v1.13.0
    floor: xray v26.3.27
    floor: node_exporter 1.8.0
    floor: utls 1.8.2

Verified `linux-amd64` checksums for the pins now recorded in `group_vars/all.yml.example` (public and
reproducible via `curl -sL <asset> | sha256sum`; the example keeps placeholders so a deploy fails closed
until the operator records these into the real `all.yml`):

- sing-box `v1.13.13` — `sing-box-1.13.13-linux-amd64.tar.gz` — `bb99cabf47694625db421ee17898f36cdc1f9c2cb5decf65b12bac8d8437e842`
- Xray-core `v26.3.27` — `Xray-linux-64.zip` — `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae`

### 3. Engine-asymmetry record

The following hardening is **engine-specific today** and is recorded so an operator who needs it
knows which engine to serve the affected shape on. sing-box parity is **tracked, not assumed**:

- **PQ REALITY handshake** — **xray-only**; serve PQ-sensitive REALITY shapes on Xray, gated off on
  sing-box until parity is confirmed.
- **Post-handshake (Aparecium) mimicry** — **xray-only confirmed**; treat REALITY-via-sing-box as
  **partial** for the post-handshake differential until a sing-box changelog entry confirms parity
  (file the upstream issue; prefer Xray where post-handshake conformance matters).
- **VLESS-Encryption construction** — **xray-only**; relevant only on CDN/XHTTP/WS paths, never on
  REALITY shapes; not adopted here (see the annex watch-list).
- **AmneziaWG 2.0** — **awg-only**; sing-box does not carry it, so the obfuscated-UDP path stays a
  **separate** service per [ADR-0010](0010-phase0-transport-set.md).

This record **activates**, and does not contradict, [ADR-0010](0010-phase0-transport-set.md)'s
"Xray retained as an optional alternative engine" clause: engine diversity is the mechanism by which
a node can stay current on hardening that has not yet reached the primary engine.

### 4. Refresh cadence

- **Engine-pin-bump trigger.** Every time an engine pin (sing-box / Xray / AmneziaWG) is bumped
  under [../dependency-policy.md](../dependency-policy.md), re-check the floors above and the
  annex's watch-list triggers in the **same** change, and update both. A bump and its currency
  re-check travel together.
- **Quarterly source sweep.** Once per quarter, sweep the public landscape sources
  (net4people/bbs-class threads and gfw.report) for new detection results and new hardening, and
  refresh the annex's `last-verified` dates and watch-list. A sweep that surfaces a new
  load-bearing floor is recorded as a floor change here (a small ADR amendment) and scheduled as a
  staged deploy — it does **not** auto-bump anything.

### 5. The landscape annex (living document)

A new maintained reference, `docs/reference/transport-technique-landscape.md`, holds the
HAVE / ADOPT / WATCH / SKIP evidence and the watch-list, each row carrying its primary source URL
(citations only — source URLs are references, not prose claims) and a `last-verified` date.
[ADR-0010](0010-phase0-transport-set.md) stays the **decision**; the annex holds the **evidence and
the watch-list**. This keeps the arms-race material in one auditable place and avoids ADR churn:
new findings update the annex; only a **floor** change touches an ADR.

**Fail-closed.** A pin below its declared floor is a recorded defect that blocks the **offline
currency gate** (below) — the build does not silently pass a below-floor pin. It does **not** trigger
any automatic upgrade: detection is gated; the remedy is the staged one-node-first deploy.

## Consequences

- **Positive:** currency becomes a tracked, auditable property of indistinguishability; the
  engine-asymmetry finding is recorded and actionable (an operator knows which engine carries which
  hardening); pin drift is caught offline; the landscape evidence lives in one maintained annex
  instead of churning ADRs; the policy is separated from the act, so the floors can be declared
  without forcing a risky network move.
- **Negative / cost:** the floors and the annex must be kept honest — a stale annex or a floor that
  has drifted past upstream is itself misleading; one new offline gate and one runbook probe to
  maintain; the quarterly sweep is recurring effort.
- **Impact on user security (requirement №1):** the node learns nothing new about users — this
  policy is about engine versions, not user data; no logging, attribution, or correlation is
  introduced. Currency **improves** the indistinguishability that protects user identity/location;
  confidentiality, deniability, and forward secrecy remain those of the audited upstream primitives
  ([ADR-0002](0002-no-custom-cryptography.md)).
- **Impact on observability/measurements:** adds two currency signals — the offline gate's
  pins-vs-floors / annex-currency result, and the live runbook probe's post-handshake conformance
  result. No new on-node telemetry and no central collector
  ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md) unaffected).
- **Follow-on actions required:** create `docs/reference/transport-technique-landscape.md` (the
  annex) from the HAVE/ADOPT/WATCH/SKIP tables; add the offline currency gate; add the
  post-handshake runbook probe; link the annex from
  [ADR-0010](0010-phase0-transport-set.md) as its rationale annex; record floor bumps as staged,
  one-node-first deploys per [../dependency-policy.md](../dependency-policy.md). The **act** of
  satisfying each floor on live nodes is tracked separately, not by this ADR.
- **What is now forbidden:** treating transport-version currency as optional once a load-bearing
  floor is declared; bumping a live pin **network-wide in one move** to satisfy a floor (the bump is
  staged, one node first, with a `Verification:` block); claiming any version bump here beats the
  destination-AS download-throughput throttle or the cross-layer RTT fingerprint (those are
  answered only at the routing/topology layer — [ADR-0027](0027-selective-growth-and-in-region-ingress.md));
  enabling PQ-REALITY or assuming post-handshake parity on sing-box before upstream parity is
  confirmed; letting the annex's `last-verified` dates go stale past one quarter without a sweep.

## Compliance

How to verify the decision is respected in practice:

- conformance test **`dep_currency`** (offline gate) — compares the **recorded** engine/library
  pins in the repository against the **documented** floors in this ADR and the annex, and checks the
  annex's `last-verified` dates are within the quarterly window. It reads repository state and the
  annex **only**; it does **not** reach the network and does **not** fetch upstream. A pin below its
  floor or a stale annex fails the gate;
- **post-handshake conformance probe** — the Aparecium-style post-handshake (NewSessionTicket)
  check is a **live runbook probe**, **not** an offline gate: it requires a reachable node and a
  donor comparison, so it runs as an operator runbook step against a node, not in CI. The runbook
  records its result and the engine the shape was served on;
- conformance test **`no_custom_crypto`** — currency is adoption of upstream primitives, never a
  fork ([ADR-0002](0002-no-custom-cryptography.md)); the currency policy must not introduce any
  hand-rolled primitive;
- dependency-policy check — every floor-satisfying bump is a separate commit with a `Verification:`
  block and the new hash, staged one node first ([../dependency-policy.md](../dependency-policy.md)
  §3–§4);
- CI gate that blocks merge on a failed `dep_currency` result or on a missing/stale annex.

