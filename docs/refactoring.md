<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium — Audit and Refactoring Policy

> **Status:** canon. Every architecturally significant change to Mycelium must
> comply with this document.
>
> **See also:** [README.md](../README.md), [ROADMAP.md](ROADMAP.md),
> [ARCHITECTURE.md](ARCHITECTURE.md), [THREAT-MODEL.md](THREAT-MODEL.md).
> Audit and refactoring proposal templates and ADRs are in [templates/](templates/);
> completed reports are in [audits/](audits/) and [proposals/](proposals/).

## 1. Purpose

This document establishes mandatory requirements for:
- architectural audits,
- technical audits,
- security, network-persistence, and anonymity audits,
- refactoring triggers,
- the refactoring process,
- artifact formatting,
- merge-gate criteria for changes to Mycelium.

The goal is to prevent the project from degrading toward:
- **reduced network persistence** (recognizable traffic, single points of failure,
  enumerable ingress endpoints);
- **weakened anonymity** (a node learns more about a user than necessary,
  correlation channels appear, logs accumulate);
- **loss of operational resilience** (no managed degradation, rerouting breaks,
  control plane health falls below data plane health);
- blurring of layer boundaries and hidden coupling between layers;
- accumulation of unmanaged technical debt;
- divergence between documentation and implementation.

Mycelium is a **persistent private network** in which user safety is functional
requirement #1 (see [THREAT-MODEL.md](THREAT-MODEL.md)). Auditing here is not
bureaucracy — it is the mechanism that keeps the system within the boundaries
where it remains safe for the people who use it and the people who operate it.

---

## 2. Core Principles

### 2.1. Auditing is mandatory
Every significant architectural evolution of Mycelium must be accompanied by an
audit. Unaudited changes are acceptable only for minor local edits that do not affect:
- contracts between layers (data / control / routing / discovery);
- attack surface or adversary model;
- traffic indistinguishability (transport profiles, obfuscation, fingerprints);
- the "what the node knows about the user" model and storage/logging;
- bootstrap / config distribution / discovery;
- sybil resistance and membership;
- auto-rotation, rerouting, and degradation logic.

### 2.2. Refactoring must be purposeful
Refactoring purely to "rewrite it cleanly" is prohibited.
Every refactoring must have:
- a documented problem,
- an expected outcome (including impact on survivability/anonymity, where applicable),
- affected layers and components,
- a set of verifiable success criteria,
- a rollback strategy or safe fallback.

### 2.3. Documentation is mandatory
If a change is architecturally significant but not reflected in the documentation,
it is considered incomplete. Code without an updated architectural description is
not considered the canonical state of the system. This is especially strict for
THREAT-MODEL: a new feature that changes the attack surface or the protected assets
is not considered finished until the threat model has been updated.

### 2.4. Do not fix chaos with more chaos
Resolving an architectural problem through any of the following is prohibited:
- adding hidden channels or dependencies;
- temporary "workarounds" without an explicit record and a trigger-to-remove;
- spreading responsibility across layers;
- moving survivability/policy logic into an inappropriate layer for the sake of speed.

In this project, chaos has a particular cost: a workaround that temporarily
restores reachability can simultaneously create a correlation channel or a
fingerprint. Any such outcome is recorded as a finding — not as "it works for now."

### 2.5. Audits must produce decisions
An audit that has not produced:
- recorded findings,
- severity assignments,
- action items,
- documentation updates,
- or a management decision,

is considered a formality and does not count.

### 2.6. Default to fail-closed for safety
When a change creates ambiguity between "more convenient/faster" and "safer for
the user," the safe outcome is chosen by default. Any fallback that sacrifices
anonymity or indistinguishability in order to maintain reachability must be an **explicit,
deliberate, and documented degradation policy**, not a silent branch in the code
(cf. §15.5).

---

## 3. What Constitutes an Architecturally Significant Change

A change is architecturally significant if it affects at least one of the following:

- the contract between layers (data ↔ control ↔ routing ↔ discovery);
- adding or removing a transport, or changing a transport profile (SNI, ALPN,
  padding, junk packets, congestion control, cover-site behavior);
- what **a node knows about the user**, or the storage/logging model;
- the telemetry and blockage-intelligence schema (what is collected, how it is
  aggregated, noised, or anonymized);
- the network-state detector logic or the auto-rotation loop;
- rerouting logic, ingress/egress separation, multi-hop;
- the bootstrap / config distribution / rendezvous mechanism;
- discovery (static config → coordinator → DHT+gossip);
- sybil resistance, trust/reputation model, invite tree, or proof-of-work;
- key and identity model (issuance/revocation, REALITY rotation);
- the error and degradation model;
- versioning rules or compatibility (node ↔ node ↔ config distribution endpoint);
- layer structure.

Auditing is mandatory for all such changes. The subset covering indistinguishability,
anonymity, bootstrap, discovery, sybil resistance, telemetry, and degradation must
additionally pass the **domain lenses** from §6.1 — even if the change appears small.

---

## 4. Audit Types

## 4.1. PR Audit
The minimum mandatory audit for every architecturally significant PR.

### Checked:
- are layer boundaries intact;
- has a hidden channel or direct cross-layer link appeared that bypasses the contract;
- has the "what the node knows about the user" model changed without explicit
  documentation;
- is compatibility preserved (node ↔ node ↔ config distribution endpoint ↔
  coordinator);
- has indistinguishability degraded (new fingerprint, banner, unexpected port);
- has a silent degradation appeared that sacrifices safety;
- does documentation need to be updated (including THREAT-MODEL).

### Format:
- checklist (§16),
- list of findings,
- verdict.

### Result:
- `pass`
- `pass_with_conditions`
- `fail`

---

## 4.2. Tactical Audit
Conducted regularly to evaluate accumulated changes.

### Checked:
- drift between code and documentation (including ARCHITECTURE and THREAT-MODEL);
- temporary workarounds (especially those that restored reachability at the cost of
  indistinguishability or anonymity);
- accumulation of technical debt;
- expansion of component boundaries and emergence of implicit dependencies;
- violations of project principles (indistinguishability over obfuscation,
  redundancy, resilient degradation-not-failure, user safety #1);
- correctness of contract and compatibility evolution.

### Format:
brief review memo.

---

## 4.3. Full-Scale Architectural Audit
A deep audit of the system covering multiple roles (§6) with a mandatory
Expert Lens block (§6.1–§6.2).

### Checked:
- does the current implementation match the canon (README/ARCHITECTURE/THREAT-MODEL);
- are layer boundaries clean and hidden channels absent;
- is the threat model current: every attack row in the THREAT-MODEL matrix has a
  working response in code;
- traffic indistinguishability across all active transports;
- the anonymity model: what nodes and the control plane know about the user;
- network persistence of the control plane itself and of bootstrap;
- sybil resistance of discovery (for phases 5–6);
- correctness of degradation, rerouting, and recovery scenarios.

### Format:
complete audit report (see [templates/audit.md](templates/audit.md)).

---

## 4.4. Event-Triggered Audit
An audit triggered by an event rather than a calendar schedule.

### Triggers:
- adding a new transport or substantially changing a transport profile;
- roadmap phase transitions (especially 3→4 and 4→5, see §5);
- changes to bootstrap, discovery, or sybil-resistance mechanisms;
- changes to the telemetry or blockage-intelligence schema;
- **a real blocking event**: how the system responded, what recovered and how quickly —
  a mandatory post-incident audit;
- suspected or confirmed compromise of a node or coordinator;
- suspected identity exposure or traffic correlation;
- a major refactor of the control / routing / discovery layer;
- technical debt reaching a critical threshold.

---

## 5. Recommended Audit Cadence

Cadence is tied to [ROADMAP.md](ROADMAP.md) phases — the system progresses from
a single node to an autonomous mesh, and the cost of an error increases at each
phase (in phases 5–6, an error in discovery or sybil resistance exposes the
network map to an adversary).

### Phases 0–3 (single node → multi-protocol → adaptation → living node: recovery/release)
Attack surface is limited to a single operator and their infrastructure.
- PR audit — on every architecturally significant PR;
- tactical audit — once per week;
- full-scale audit — once every 4–6 weeks;
- event-triggered audit — on every new transport, every blocking event or interference
  incident, every change to the detector or auto-rotation.

### Phase 4 (node network — per-Commune coordination)
A per-Commune coordinator exists — the highest-value target within that Commune;
compromise of that centre exposes the Commune's network map. Coordination is
per-Commune / per-operator self-coordination, not a global central authority over
the network as a whole (ADR-0016/0021/0023/0025).
- PR audit — mandatory;
- tactical audit — once every 2 weeks;
- full-scale audit — once every 6–8 weeks, **mandatory with Security/Threat and
  Anonymity lenses** for the coordinator boundary;
- event-triggered audit — mandatory on any change to what the coordinator knows,
  and to its own network persistence.

### Phases 5–6 (decentralization → autonomous mesh)
Open membership, DHT/gossip, ephemeral ingress endpoints, home nodes behind NAT.
Primary risks: sybil/enumeration, correlation, route poisoning.
- PR audit — mandatory for all discovery/routing/membership changes;
- tactical audit — once every 2 weeks;
- full-scale audit — once every 6–8 weeks, with **mandatory** domain lens passes
  (Security/Threat, Network-persistence, Anonymity, Resilience);
- event-triggered audit — mandatory on any change to discovery, sybil defenses,
  trust/reputation model, or multi-hop.

### Mature network (after phase 6 stabilization)
- PR audit — mandatory for significant changes;
- tactical audit — once per month;
- full-scale audit — once per quarter;
- event-triggered audit — on trigger (see §4.4); a network-interference event always triggers one.

---

## 6. Roles in a Full-Scale Audit

A full-scale audit should use the following roles. A single person or agent may
cover more than one role, but the roles themselves must remain conceptually distinct.

1. **System Architect**
   Verifies the integrity of the overall layered architecture and the stability of
   contracts between layers.

2. **Data-Plane Reviewer**
   Checks transports, obfuscation, indistinguishability, cover sites, and
   diversification of ports/SNI/donors.

3. **Control-Plane Reviewer**
   Checks keys and identities, the network-state detector, auto-rotation, telemetry,
   and the **persistence and resilience of the control plane itself**.

4. **Routing / Orchestration Auditor**
   Checks ingress→egress path selection, rerouting, multi-hop, and
   anti-flapping.

5. **Discovery / Membership Auditor**
   Checks bootstrap, registry/DHT/gossip, sybil resistance, trust model,
   and NAT traversal.

6. **Security / Threat Auditor**
   Cross-references the implementation against [THREAT-MODEL.md](THREAT-MODEL.md):
   every attack has a response; no new surfaces have appeared; protected assets are
   actually protected.

7. **Anonymity / Privacy Auditor**
   Verifies that nodes and the control plane know the minimum about the user; searches
   for correlation channels, identity leaks, and log accumulation.

8. **Operational / Resilience Auditor**
   Checks managed degradation, recovery, observability, and the SLO for recovery
   after blocking events.

9. **Measurement Auditor**
   Verifies the correctness of measurements and blockage intelligence (OONI-style
   approach): data is truthful, anonymized, and does not itself become an attack
   surface.

10. **Legal / Opsec Auditor**
    Checks knowledge minimization, role and jurisdiction separation, deniability,
    and protection of operators and volunteers (see THREAT-MODEL §"Law and opsec").

11. **Documentation Auditor**
    Checks drift between code, ADRs, RPs, ARCHITECTURE, THREAT-MODEL, and actual
    data flows.

---

## 6.1. Expert Evaluation Lenses

In addition to the mandatory roles from §6, every full-scale audit and major
event-triggered audit must include a brief expert evaluation of the system
through several independent engineering lenses.

These lenses carry no external authority, do not replace Mycelium's canon, and
do not override the severity model in §7. They exist to prevent audits from
becoming self-congratulatory and to ensure the system is examined from multiple
angles:

- maintainability and construction discipline;
- modularity and information hiding;
- conceptual integrity;
- simplicity and fault tolerance;
- **security against the threat model**;
- **network persistence** (indistinguishability, sybil/enumeration, AS diversity);
- **anonymity/privacy** (what the node knows about the user);
- **operational resilience** (degradation, rerouting).

The lenses are divided into **general-engineering** (Cormen, Tanenbaum, McConnell,
Parnas, Brooks, Dijkstra) and **domain** (Security/Threat, Network-persistence,
Anonymity/Privacy, Operational-resilience). Domain lenses matter more for this
project than general ones: the project's value is not "clean code" but remaining
persistently reachable and safe.

Scores are on a `0..10` scale.

Scale:

| Score | Meaning |
|---:|---|
| 0–2 | dangerous system: exposes users to risk or is trivially blocked |
| 3–4 | working prototype without mature security architecture |
| 5–6 | meaningful prototype with significant debt |
| 7 | strong architecture prototype |
| 8 | engineeringly strong system, not yet production-grade |
| 9 | near-reference system, surviving growth and adversary pressure |
| 10 | mature, reliably boring, proven against real blocking events |

A score below `6.0` on any mandatory lens must produce a finding of at least
`S2`. A score below `5.0` must produce a finding of at least `S1` if it is
linked to an architecturally significant risk. For **domain** lenses, the
threshold is stricter: a score below `5.0` on Security/Threat,
Network-persistence, or Anonymity/Privacy that is linked to a user risk
produces a finding of **S0** (see §7).

Scores must not be averaged mechanically. The auditor must explain why a score
was assigned, with a reference to the actual state of the repo/RP/ADR/tests.

---

### 6.1.1. Cormen Lens — algorithmic rigor and invariants

Checks how far the system behaves like a correctly specified formal construction:
clear invariants, states, transitions, contracts, and checkable properties. For
Mycelium this maps onto the fail-closed render→validate→promote→rollback pipeline,
the detector/rotation state machines, the byte-equivalence contracts, and the
closed vocabularies — correctness must be a property of the design, not of "how it
happens to be called."

Checked:

- is there an explicit invariant for each critical flow (render→validate→promote→
  rollback; reach→detect→tune→plan; rotation apply/record);
- does correctness depend on an implicit order of side effects;
- are state transitions formalized (detector states, rotation states) and
  expressible as a finite set of phases / a table;
- is failure behaviour bounded and fail-closed (§2.6 / §15.5);
- is there idempotency for repeated commands (node-apply no-op short-circuit; a
  re-run that does not double-actuate; a redactor that is idempotent);
- is there monotonicity where required (version/SourceRev never regresses;
  decay/hysteresis floors);
- does a hidden heuristic appear where an owner-owned contract is required (a
  closed vocabulary / single source of truth, ADR-0012);
- are invariants covered by conformance / property tests (the byte-equivalence
  gates, the no-PII gate);
- is there `magic` branching that cannot be explained through the canon (an ADR/RP).

Good-state examples:

- a flow has an explicit order: descriptor → validate → render → `sing-box check`
  → promote → reload → verify → rollback;
- the external client does not set the internal server target (ingress endpoints
  are rendered, not client-chosen);
- one source of truth (`spec.Version`; `vocab.json`; the engine manifest);
- a duplicate / byte-identical apply is a no-op, not a second mutation;
- a failed validate has a defined outcome (nothing promoted; node byte-identical).

Red flags:

- "it works because of how it is called right now";
- implicit ordering without a conformance gate;
- a heuristic living in a downstream component while the contract owner is another layer;
- an undefined failure path (a broad swallow in the detector / rotation loop);
- a state transition that cannot be written as a table;
- unknown retry / duplicate / restart behaviour.

```text
Cormen Lens: N / 10
Strengths:
- ...
Concerns:
- ...
Required findings:
- ...
```

---

### 6.1.2. Tanenbaum Lens — OS/runtime, processes, and fault tolerance

Checks whether a Mycelium node behaves like a well-structured operating runtime
layered on its substrate OS, rather than a bag of connected scripts. The node
**orchestrates** the substrate (systemd, ufw, the engine binaries); it must not
re-implement it.

Checked:

- is there a clear boundary between the substrate OS (systemd / ufw / the kernel)
  and the Mycelium control runtime — does Mycelium drive systemd/ufw rather than
  become a replacement for them;
- is there a process lifecycle for the managed units (sing-box / xray / myceliumd:
  active / inactive / failed, NRestarts), with supervision and a recovery strategy
  (systemd restart + validate→promote→rollback);
- are runtime fabric, routing, policy, state, and history cleanly separated (the
  data / control / routing / discovery planes; ADR-0034 engine-vs-transport-vs-capability);
- is there a clear engine / adapter boundary (the sing-box and xray engines; the
  renderer delegates per-engine; an adapter describes capability, it does not own policy);
- is there a timeout / cancel / retry / fault taxonomy for the device-edge — the
  engine subprocess calls (`sing-box check`, `xray run -test`, `journalctl`,
  `systemctl is-active`): a failed/absent binary or unreadable journal yields a
  typed, bounded outcome, not a crash or a silent success;
- does the node survive restart without losing safe state (idempotent build keyed
  on SourceRev; promoted-config persistence);
- is local autonomy preserved (a node keeps working without a coordinator — the
  Phase 1/2 posture);
- are host / IO faults isolated from domain semantics (a journalctl failure →
  "(journal unavailable)", not a panic);
- are protocol form, transport, and capability meaning kept distinct, not conflated.

Good-state examples:

- the substrate Linux owns the machine; Mycelium owns the node's serve/rotation world;
- the engine (sing-box/xray) owns dataplane transport, not control policy;
- node-bootstrap drives systemd units + ufw; it does not re-implement them;
- a failed `sing-box check` rolls back: the live config is untouched, NRestarts unchanged;
- the read-only diag collector runs only `is-active` / `version` / `journalctl` and
  degrades to "(journal unavailable)" on fault.

Red flags:

- a control/domain component talks directly to a vendor/engine internal instead of
  through the render/validate contract;
- an adapter stores routing/policy meaning;
- a policy check living in engine/driver code;
- a normal serve path mutating persistent node state as a side effect;
- a restart losing authority / promoted state;
- a physical/IO failure with no typed fault path;
- the engine-edge becoming an unbounded plugin zoo.

```text
Tanenbaum Lens: N / 10
OS/runtime strengths:
- ...
Operational gaps:
- ...
Required findings:
- ...
```

---

### 6.1.3. McConnell Lens — construction quality, maintainability, refactoring discipline

Checks the system's construction quality: readability, complexity localization,
documentation synchrony, and the team's ability to continue development safely.

Checked:

- is the change localized;
- are component and state names clear;
- is accidental complexity growing;
- do code / README / ARCHITECTURE / THREAT-MODEL / ADR / RP / CHANGELOG diverge;
- are there tests alongside the change;
- is there a migration and rollback;
- does the refactor introduce more ambiguity than it removes;
- does the version bump reflect the actual blast radius;
- have comments/docstrings become stale boundary sources.

Red flags:

- "we'll fix the docs later" after changing a transport profile or threat model;
- README/ARCHITECTURE describes an old set of transports or old discovery;
- a single refactor changes dozens of files without a staged migration;
- no rollback for a high-blast-radius change.

```text
McConnell Lens: N / 10
Construction strengths:
- ...
Maintainability risks:
- ...
Required findings:
- ...
```

---

### 6.1.4. Parnas Lens — information hiding and modularity

Checks whether decisions are hidden inside the correct layers, or whether the
system has begun leaking internal details outward. For Mycelium, this is primarily
**limiting knowledge between layers** — a direct analogue of the "node knows the
minimum" principle.

Checked:

- does one layer read another's internal fields, bypassing the contract;
- are transport-specific details hidden behind a common data-plane interface;
- does the consumption interface (out of scope — standard clients connect to
  standard endpoints) expose the internal network topology unnecessarily;
- can a transport/coordinator/discovery implementation be replaced without
  rewriting adjacent layers;
- has an auxiliary registry (config distribution endpoint, descriptor) become a
  runtime oracle that knows too much about the user.

Red flags:

- the routing layer reaches into private structures of a specific transport;
- a node knows the complete real map of the mesh (it should only know the needed ingress);
- swapping one core transport engine for another requires changes across all layers;
- a config distribution endpoint becomes a source of truth about connections it
  should not hold;
- a fetch path drops the `myc_fetch_artifacts` signature + checksum gate, or scatters fetch logic
  out of that single swappable step (ADR-0015);
- a served cross-node weather aggregator or any queryable network-state endpoint appears — emit-only
  is the contract (ADR-0030, `NO_SERVED_AGGREGATOR`).

```text
Parnas Lens: N / 10
Information hiding strengths:
- ...
Leaks:
- ...
Required findings:
- ...
```

---

### 6.1.5. Brooks Lens — conceptual integrity and accidental complexity

Checks whether the system maintains a single conceptual form as it grows, or is
becoming a collection of locally sensible but globally incompatible decisions.
The project's guiding metaphor is an interconnected mesh that reroutes around
damage: new entities must fit that model, not proliferate alongside it.

Checked:

- is there one architectural story (five layers are stable; implementation changes);
- are "managers" and "controllers" multiplying without clear responsibility;
- do a component's name, the mesh metaphor, and its actual role conflict;
- are entities being added for the convenience of a single phase or PR;
- is a temporary shape (e.g., the phase 4 coordinator) quietly becoming
  undeclared canon;
- can the system be explained through a few stable formulas.

Red flags:

- "another service because it's easier";
- the temporary phase 4 coordinator silently becomes permanently required;
- a component name is decorative and does not encode the component's role or failure mode;
- `temporary` without a trigger-to-remove;
- two deploy-path defaults (bootstrap vs Ansible/`group_vars`) are "reconciled" in a way that widens
  exposure — the conservative Vision-only Ansible default is an INTENTIONAL divergence, not a
  `CONFLICTING_SOURCE_OF_TRUTH` to fix (ADR-0022).

```text
Brooks Lens: N / 10
Conceptual integrity strengths:
- ...
Accidental complexity:
- ...
Required findings:
- ...
```

---

### 6.1.6. Dijkstra Lens — simplicity, correctness, and avoidance of cleverness

Checks whether the system is solving a simple problem with an overly clever
mechanism and whether complexity is being masked behind appealing names. In a
persistent private network, "cleverness" is doubly dangerous: a smart fallback can
silently break fail-closed and expose a user.

Checked:

- can the flow be simplified without losing safety properties;
- does an abstraction hide a real side effect (e.g., switching to a less anonymous
  path);
- is there a clever fallback that breaks fail-closed;
- are unrelated responsibilities mixed inside a single method;
- is the number of detector/rotation states growing without necessity.

Red flags:

- an implicit fallback to a bare transport without an explicit marker and policy
  consent;
- a broad `except` that swallows a critical failure in the network-state detector;
- a "smart" heuristic instead of an explicit transport-selection policy declaration;
- an extra layer that owns nothing;
- an architectural layer-**plane** and a **Commune** (a who/society) get conflated — "plane" names a
  layer (data / control / routing / discovery), "Commune" names a population + its fungi (ADR-0023).

```text
Dijkstra Lens: N / 10
Simplicity strengths:
- ...
Unnecessary cleverness:
- ...
Required findings:
- ...
```

---

### 6.1.7. Security / Threat Lens — threat-model compliance (domain, mandatory)

The primary domain lens. Checks that the implementation **has not fallen behind
[THREAT-MODEL.md](THREAT-MODEL.md)**: every known attack has a working response,
no new surfaces have appeared, and the protected assets are actually protected.

Checked:

- does working code cover every row in the "attack → response" matrix from
  THREAT-MODEL, not just stated intent;
- has a new attack surface appeared (new port, banner, endpoint, predictable
  identifier);
- are all five assets protected (user identity/location, traffic content,
  ingress reachability, operators, network map);
- does the system hold against **active probing** (the cover site returns a
  legitimate response; no extraneous behavior);
- is forward secrecy present where declared; are secrets not logged;
- are roles and jurisdictions separated such that compromise of one link does not
  expose the rest;
- does the change introduce a "silent emergency path" that bypasses the security
  model.

Red flags:

- an attack from THREAT-MODEL is "closed on paper" but has no code response;
- the server returns a recognizable response to a probe;
- a new component knows the mapping "this user ↔ this ingress ↔ this egress";
- a secret or key is in logs, code, or un-noised telemetry;
- attack surface has changed without an update to THREAT-MODEL.

```text
Security / Threat Lens: N / 10
Threat-coverage strengths:
- ...
Exposed surfaces / regressions vs THREAT-MODEL:
- ...
Required findings:
- ...
```

---

### 6.1.8. Network-persistence Lens — indistinguishability, sybil/enumeration, AS diversity (domain, mandatory)

Checks the project's key property: **does the system maintain reachability** under a
realistic adversary (large-scale behavioral-layer blocking, ML-based traffic classification, AS-level
blocking, UDP/QUIC cutting, ingress enumeration).

Checked:

- **Indistinguishability:** traffic is statistically similar to legitimate
  HTTPS/QUIC, not merely "obfuscated"; no unique fingerprint from ClientHello,
  timing, packet sizes, or probe behavior;
- **Redundancy:** multiple transports/ports/SNI/donors/IPs/ASes operate
  simultaneously; there is no single blockable point;
- **AS diversity:** infrastructure is not concentrated in a single "dirty"
  autonomous system; there are spare IPs across different ASes; the pattern
  "handshake passes, data dies" is accounted for;
- **Persistence of control plane and bootstrap:** configs, commands,
  and first-contact endpoints do not hang on a single domain that can be cut in
  minutes;
- **Sybil / enumeration (phases 5–6):** an adversary cannot cheaply enumerate
  most ingress endpoints; joining the network has a cost (invites/social
  graph/PoW); a knowledge gradient limits what a new node can see;
- **Adaptation speed:** when a transport is blocked, the system reconfigures in
  minutes, not hours (the core of the adaptation layer, phase 2).

Red flags:

- a new transport with a recognizable signature (bare protocol disguised as TLS);
- everything in one AS / on one distribution domain / on one SNI;
- discovery that allows ingress endpoints to be enumerated by a linear DHT walk;
- open membership without any entry cost at phase 5+;
- auto-rotation that in practice flaps and itself becomes a blocking signal.

```text
Network-persistence Lens: N / 10
Indistinguishability & redundancy strengths:
- ...
Blockability / enumeration risks:
- ...
Required findings:
- ...
```

---

### 6.1.9. Anonymity / Privacy Lens — what the node knows about the user (domain, mandatory)

Checks the "knowledge minimization" principle: the node, coordinator, and
telemetry know the **minimum** about the user; what is not collected cannot be
seized or compelled.

Checked:

- **Node knowledge:** what exactly the ingress/egress node knows about the user
  and their traffic; does the ingress simultaneously know "who" and "where";
- **Ingress/egress separation:** a single hop does not know the full path
  (multi-hop, phase 5+);
- **Logs:** none by default; what is logged is justified, minimal, free of PII,
  and not retained long-term;
- **Telemetry/blockage intelligence:** aggregated, noised, not linked to identity;
  does not itself become a exposing channel;
- **Correlation:** no timing/volume/identifier channels that link a user to a
  destination; client identifiers are not reused predictably;
- **Forward secrecy and revocation:** compromise of a key does not expose past
  traffic; client revocation does not require knowing more than necessary about them.

Red flags:

- an ingress node sees both the user and the final destination;
- the coordinator stores a "user → route" map;
- telemetry contains enough to isolate a specific person;
- a stable per-user identifier convenient for correlation;
- a "convenient" feature that improves UX at the cost of identity exposure
  (violates requirement #1).

```text
Anonymity / Privacy Lens: N / 10
Knowledge-minimization strengths:
- ...
Correlation / identity exposure risks:
- ...
Required findings:
- ...
```

---

### 6.1.10. Operational-resilience Lens — degradation and rerouting (domain, mandatory)

Checks the "degradation, not failure" principle: the loss of a node, coordinator,
or transport slows but does not stop the network; recovery is managed and
measurable.

Checked:

- **Managed degradation:** when a transport/node/coordinator is lost, the system
  explicitly transitions to a degraded-but-working mode rather than crashing or
  losing fail-closed;
- **Rerouting:** when a regional egress fails, traffic is redirected to another;
  the path is rebuilt around the failed segment;
- **Persistence of the coordinator (phase 4):** the coordinator remains
  reachable when its primary domain is blocked (anycast/CDN-front/P2P-fallback);
  the coordinator is not a kill switch;
- **Anti-flapping and rollback:** auto-rotation has limits, hysteresis, and
  rollback;
- **Recovery SLO:** recovery time after a blocking event is defined and measured;
  there is protection against spurious reroutes;
- **Restart/recovery:** a node survives a restart without losing safe state;
- **Bootstrap degradation:** a new node that is "everything is blocked" has at
  least one out-of-band path to a first ingress endpoint.

Red flags:

- loss of the coordinator causes a complete halt (the coordinator became a kill
  switch);
- auto-rotation without limits flaps and blocks itself;
- no measurable recovery time (SLO "by word only");
- rerouting breaks ingress/egress separation or leaks the path;
- degradation leads to an unsafe mode without an explicit policy.

```text
Operational-resilience Lens: N / 10
Graceful-degradation strengths:
- ...
Resilience gaps:
- ...
Required findings:
- ...
```

---

## 6.2. Mandatory Expert Lens Block in Full-Scale Audits

Every full-scale audit must contain the following block:

```markdown
## Expert Lens Scores

| Lens | Score | Verdict |
|---|---:|---|
| Security / Threat | N / 10 | ... |
| Network-persistence | N / 10 | ... |
| Anonymity / Privacy | N / 10 | ... |
| Operational-resilience | N / 10 | ... |
| Cormen | N / 10 | ... |
| Tanenbaum | N / 10 | ... |
| McConnell | N / 10 | ... |
| Parnas | N / 10 | ... |
| Brooks | N / 10 | ... |
| Dijkstra | N / 10 | ... |

### Summary
- Strongest lens:
- Weakest lens:
- Main reason for weakest score:
- Required action before next phase / major RP:
```

Minimum mandatory lenses (always):

- **Security / Threat**;
- **Network-persistence**;
- **Anonymity / Privacy**;
- McConnell.

**Operational-resilience** is additionally mandatory for any change to
routing/control/discovery, for every post-incident audit, and for every phase
transition.

Cormen, Tanenbaum, Parnas, Brooks, and Dijkstra are mandatory for:

- adding a new transport or transport profile;
- changing discovery / sybil resistance / trust model;
- changing the contract between layers;
- changing a public node-facing or config-distribution surface;
- roadmap phase transitions;
- a major refactor with a blast radius greater than 20 files.

---

## 6.3. Rules for Interpreting Expert Lens Scores

1. A high average score does not cancel an S0/S1 finding.
2. A low score must be explained with a concrete architectural or user risk.
3. A score must not be a compliment or an aesthetic opinion.
4. Every score references the actual state of the repo, RP, ADR, tests, docs,
   or a specific line in THREAT-MODEL.
5. If a lens score falls for two consecutive audits, an action item is opened.
6. If a lens score is below `6.0`, the next major RP or phase transition must
   explicitly explain why progress continues without a prior stabilization pass.
7. If a **domain** lens score (Security/Threat, Network-persistence,
   Anonymity/Privacy) is below `5.0`, **transitioning to the next roadmap phase**
   is prohibited, and expanding the surface (new transport, opening membership,
   new ingress class) is prohibited until the corresponding S0/S1 cluster is
   closed.

---

## 6.4. Recommended Summary Score

An audit may additionally publish a summary engineering score:

```text
engineering_maturity_score = weighted_summary(...)
```

Recommended weights (domain lenses dominate, because the project's value is
persistent reachability and user safety, not code beauty):

| Lens | Weight |
|---|---:|
| Security / Threat | 20% |
| Network-persistence | 20% |
| Anonymity / Privacy | 20% |
| Operational-resilience | 15% |
| Cormen | 5% |
| Tanenbaum | 5% |
| McConnell | 7% |
| Parnas | 3% |
| Brooks | 3% |
| Dijkstra | 2% |

The summary score is used only as a readability aid. It is **not** a merge gate
in itself. The merge gate remains the severity model from §7 and the gate
criteria from §14.

---

## 7. Severity Model

Every audit finding must have a severity. Categories are adapted to Mycelium's
three risk axes: **user safety**, **availability/reachability**, and **anonymity**.

### S0 — Critical
A critical violation of safety, reachability, or anonymity.
Requires immediate halt of merge / rollout / phase transition.

Examples:
- a node or telemetry exposes the "user ↔ destination" mapping (identity exposure);
- a transport/server is easily detected or fails active probing;
- a single point of block/failure for the entire network (coordinator became a kill
  switch without fallback);
- discovery allows cheap enumeration of most ingress endpoints;
- a silent emergency path that bypasses fail-closed, sacrificing safety;
- a secret or key leaks into logs, code, or un-noised telemetry;
- an irreversible compatibility break that leaves nodes without access.

### S1 — High
High risk. Must be fixed before the next major step or phase transition.

Examples:
- a measurable weakening of indistinguishability for one of the transports;
- path redundancy has degraded to a single real option (one AS / one SNI);
- auto-rotation is flapping and itself becomes a blocking signal;
- more is being logged than justified, even if no PII is leaking directly.

### S2 — Medium
Significant debt or architectural weakness. Address in the next work cycle.

### S3 — Low
Undesirable but non-critical state. Can be planned as an improvement.

### NOTE
Observation without mandatory immediate action.

### Lens-to-severity mapping

- Any mandatory lens score below `6.0` → finding ≥ **S2**.
- Any lens score below `5.0` linked to an architectural risk → finding ≥ **S1**.
- Any **domain** lens score (Security/Threat, Network-persistence,
  Anonymity/Privacy) below `5.0` linked to a user risk → finding **S0**.

### Named finding categories

Some findings have a fixed name and default severity so that auditors use
consistent naming when recurring patterns are detected:

| ID | Severity (default) | Description |
|---|---|---|
| `USER_DEANON` | **S0** | A node / coordinator / telemetry links user identity or location to their traffic or ingress endpoint. Violates requirement #1 and THREAT-MODEL §"Assets". |
| `TRAFFIC_CORRELATION` | **S0** | A timing/volume/identifier channel has appeared that links a user to a destination (including through a single hop that knows the full path). |
| `DISTINGUISHABLE_TRANSPORT` | **S0** | A transport/server is statistically distinguishable from legitimate HTTPS/QUIC, or fails active probing (recognizable fingerprint, banner, unexpected port). |
| `SINGLE_POINT_OF_BLOCK` | **S0** | A single point of block/failure for the entire network: coordinator without fallback, single distribution domain, single AS, single SNI as the only path. |
| `ENUMERATION_EXPOSURE` | **S1** | Discovery/DHT/registry allows an adversary to cheaply enumerate a significant fraction of ingress endpoints (sybil/enumeration). Default S1; **S0** if most ingress endpoints are enumerable at phase 5+. |
| `SILENT_DEGRADATION` | **S0** | A silent fallback/emergency path that sacrifices anonymity or indistinguishability for the sake of access, without an explicit degradation policy (violation of fail-closed). |
| `SECRET_LEAK` | **S0** | A secret/key/identity appears in code, logs, un-noised telemetry, or an unexplained artifact. |
| `THREAT_MODEL_DRIFT` | **S1** | A change to attack surface or assets is not reflected in THREAT-MODEL, or an "attack → response" matrix row is closed only on paper. |
| `REDUNDANCY_COLLAPSE` | **S1** | Declared path redundancy has effectively collapsed to a single real option (by IP/AS/SNI/transport/donor). |

In addition, the following **Mycelium-native** named categories cover the
mycelial layer (coordinator/DHT, layer boundaries, routing/bridging, carrier
adapters, telemetry, and topology centralization). They are scoped to the
project's own vocabulary (spore, cord, gradient, trust scope, carrier adapter,
coordinator, master map) and were introduced by `Audit-0001`
([audits/0001-preliminary-architecture-audit.md](audits/0001-preliminary-architecture-audit.md)):

| ID | Severity (default) | Description |
|---|---|---|
| `COORDINATOR_SUPERGOD_DRIFT` | **S1** | A coordinator / DHT / gossip component is accumulating more authority or knowledge than its scope allows — drifting toward a runtime oracle that the rest of the network depends on. Must stay bounded by a knowledge ceiling, TTL/decay, scopes, and an emergency quarantine path; none of these may become a permanent central brain. |
| `DIRECT_LAYER_BYPASS` | **S0** | A direct cross-layer link or hidden channel has appeared that bypasses the declared contract between layers (data ↔ control ↔ routing ↔ discovery). Direct access to a neighbouring layer's internals breaks "node knows the minimum" and can create a correlation channel. |
| `CONFLICTING_SOURCE_OF_TRUTH` | **S0** | Two or more components hold conflicting authority over the same **route**, **trust**, or **state** fact, with no single owner. Divergent route/trust/state copies cause split-brain routing, inconsistent trust scopes, and undefined recovery behaviour. |
| `UNSAFE_ROUTING_OR_UNAUTHORIZED_BRIDGE_USE` | **S0** | Traffic is routed along a path that fails its safety/quality contract, or a carrier bridge is used outside its authorised scope/flow class (e.g. promoting a bridge to a cord without measurement, or carrying a flow class the carrier cannot safely support). Risks operator/user safety and exposes a flow over an unsuitable or untrusted carrier. |
| `CARRIER_ADAPTER_DRIFT` | **S2** | A carrier adapter is absorbing routing, trust, or policy meaning instead of staying a convergence-layer adapter that only describes capability and risk. The adapter boundary must keep `CarrierCapability` / `CarrierRisk` descriptive; routing and trust decisions belong to their own layers. |
| `TELEMETRY_SAFETY_VIOLATION` | **S1** | Telemetry, stress memory, or a scoped summary carries more than the redacted, aggregated, decaying signal the doctrine permits — approaching raw traffic, identity, full peer lists, full maps, or a persistent behavioural profile. Default S1; escalates to **S0** if it links a user to identity, location, or destination (then also `USER_DEANON` / `TRAFFIC_CORRELATION`). |
| `FORBIDDEN_TOPOLOGY_CENTRALIZATION` / `MASTER_MAP_DRIFT` | **S1** | The system is accreting a global view of the topology — a master map — that no node is meant to hold by default. A registry, coordinator, DHT, or island-merge summary is becoming an authoritative full map instead of scoped, need-to-know route knowledge. Escalates to **S0** if a single such map becomes a point of block/failure for the whole network (then also `SINGLE_POINT_OF_BLOCK`). |

| `GLOBAL_KILL_SWITCH` | **S0** | A global authority is able to ban nodes or Communes network-wide, or a cross-Commune abuse oracle produces signals that are *binding* on Communes that did not consent. Any such network-wide ban power, mandatory blocklist, or coercible central decision point is a centralization/coercion kill switch. Abuse decisions belong to local Communes; fungi may *sign* warnings, Communes may *subscribe* to or *ignore* them, and only bridge contracts make a signal binding inside an explicit relationship. Abuse resistance must never become a global kill switch. |
| `OPEN_RELAY_OR_DEFAULT_EGRESS` | **S0** | A node defaults to open relay, public egress, anonymous egress as a primitive, or unknown third-party transit — turning Mycelium into an attack substrate (DDoS amplification, abuse transit, C2 carriage, one Commune using another as an attack platform). Safe default posture is closed: no open relay, no public egress by default, no unknown transit, no bridge without an explicit trust policy, rate limits for untrusted scopes. Higher-risk capability classes (relay, egress, unknown bulk) require stronger trust and immunity policy before they are enabled. |
| `OVERBROAD_GROWTH` | **S1** | A generated or templated client/route config grows the tunnel where it is not needed: it full-tunnels by default, or otherwise routes destinations whose **native path is unimpaired** through the tunnel instead of direct. This violates **Selective Growth** (§15.11) — *the mycelium does not grow where it is not needed*. The tunnel must carry **only** traffic whose native path is impaired (degraded/throttled/unreachable on the direct route); natively-reachable destinations route direct (split-tunnel by default). A full-tunnel default needlessly enlarges the volume, timing, and destination set that a single hop observes (correlation surface), and concentrates ordinary native traffic onto the impaired-path egress for no reachability gain. Default S1. Escalates to **S0** when the over-grown path also makes one hop see both the user and a native destination it had no need to carry (then also `USER_DEANON` / `TRAFFIC_CORRELATION`), or when it routes a user's traffic user-direct to an out-of-region egress across a high-interference border filter instead of via an in-region ingress with node-carried egress (an unsafe path; also `UNSAFE_ROUTING_OR_UNAUTHORIZED_BRIDGE_USE`). De-escalates to **S2** only for a test-only/example fixture clearly marked non-production. The precise instrument is a domain-aware split (the xray-class transports' geo-routing); CIDR-only transports (the WireGuard-class / AmneziaWG) approximate it via region-exclude route sets — a CIDR-only config that cannot express the split still owes a documented region-exclude route set, not a blanket default route. |
| `IMMUNE_SIGNAL_OVERREACH` | **S1** | An immune / abuse / cut / quarantine / rate-limit / bridge-risk / corridor-revocation signal carries more than the doctrine permits — approaching raw traffic, user identity, location, or a complete topology map. Permitted signal contents are bounded: scope, severity, reason code, TTL, evidence class, signer or quorum, and a reversible action hint. Default S1; escalates to **S0** if the signal carries user identity or location (then also `USER_DEANON`), or a destination linkage (then also `TRAFFIC_CORRELATION`). |
| `BRIDGE_WITHOUT_CONTRACT` | **S1** | An inter-Commune (Anastomosis) bridge exists, or traffic crosses between Communes, without an explicit contract that names the trust relationship, allowed and forbidden traffic/capability classes, abuse-propagation and quarantine rules, revocation and recovery rules, and evidence requirements. Default rule: no bridge exists unless explicitly established. A bridge used outside its declared scope or class is also `UNSAFE_ROUTING_OR_UNAUTHORIZED_BRIDGE_USE` (S0). |
| `UNCLOTTABLE` / `CUT_OVERREACH` | **S1** | A cut (of a node, route, transport, bridge, corridor, trust scope, or Commune) is not scoped, not reversible, not time-bounded, or not auditable inside the affected Commune; or it over-reveals (leaks more than the minimum about the cut); or it depends on a global topology view — *or* the system cannot perform a scoped, reversible cut at all. The ability to heal requires the ability to clot: clotting must be local, bounded, and independent of any global topology. A cut that becomes a network-wide ban is `GLOBAL_KILL_SWITCH` (S0). |

---

<!-- §15.10 — insert as a new subsection at the end of §15 (after §15.9 "Do not invent
     cryptography or transports", immediately before the closing `---` that precedes
     §16). It continues the existing 15.x numbering as 15.10. -->

### 15.10. Immunity, sovereign defense, and no global kill switch
Resilience without immunity is a defect, not a feature: a network that cannot
defend itself becomes a carrier for parasites. Mycelium is a **Mycobiome** of
sovereign **Communes** — a Commune being a first-class governance/deployment
entity (family, company, university, municipal, NGO, emergency-response, state),
each with its own trust roots, governance, update/bridge/immune/observability
policy, fungi quorum, and acceptable-use rules. The Commune is **not** one of the
architectural layers: data plane, control plane, routing plane, and discovery
plane keep their names and meaning and are **not** renamed. Two Communes may run
identical software with completely different genetics; they are compatible by
protocol, not by authority. A refactoring that erodes this sovereignty — that
makes one Commune able to dictate another's policy, or that collapses the
Mycobiome into a single owned network — is an architectural defect.

The following are mandatory and must not be watered down:

- **Clotting is the precondition for healing.** The system must be able to make
  temporary, scoped cuts — of a node, route, transport, bridge, corridor, trust
  scope, or Commune. Cuts must be scoped, reversible, time-bounded, auditable
  *inside the affected Commune*, minimally revealing, and independent of any
  global topology. A system that cannot clot, or whose cut over-reaches, is
  `UNCLOTTABLE` / `CUT_OVERREACH` (S1). A network that cannot cut infection is
  not alive — it is already captured.
- **No global abuse oracle; no global kill switch.** There must NEVER be a global
  authority capable of banning nodes or Communes network-wide. Local decisions
  belong to local Communes. Fungi may *sign* warnings; Communes may *subscribe*
  to or *ignore* them; only bridge contracts determine which signals are binding.
  Any network-wide ban power, mandatory blocklist, or coercible central decision
  point is `GLOBAL_KILL_SWITCH` (S0). Abuse resistance must never become a global
  kill switch.
- **Safe defaults: closed posture.** Default node posture is closed — no open
  relay, no public egress by default, no unknown third-party transit, no bridge
  without an explicit trust policy, no topology sharing by default, rate limits
  for untrusted scopes, quarantine of suspicious behaviour, and local/community
  traffic preferred over external transit. A node that defaults to open relay or
  default egress is `OPEN_RELAY_OR_DEFAULT_EGRESS` (S0). The closed-by-default
  posture, local rate limits, and local quarantine are *current* node properties
  (per-operator credentials, no open relay/egress); the cross-Commune machinery
  (Communes, Anastomosis bridges, immune signals, cross-Commune trust) is
  Phase 5–6, definable now only as inert typed schema hooks under phase
  discipline.
- **Capability classes gate risk.** Traffic capabilities are distinguished —
  local control; emergency coordination; messaging; signed content replication;
  software updates; real-time media; relay; egress; unknown bulk. Higher-risk
  classes require stronger trust and stronger immunity policy. **Anonymous egress
  is not a default primitive.** Enabling a higher-risk class without the matching
  trust and immunity policy is a defect.
- **Inter-Commune bridges require contracts.** Communes communicate only through
  explicit **Anastomosis bridges**. No bridge exists unless explicitly
  established; each bridge names its trust relationship, allowed/forbidden
  traffic and capability classes, abuse-propagation and quarantine rules, and
  revocation/recovery/evidence rules. A bridge without such a contract is
  `BRIDGE_WITHOUT_CONTRACT` (S1).
- **Immune signals never carry payload, identity, location, or the map.** Future
  immune-system signals (`abuse_signal`, `quarantine_signal`, `cut_signal`,
  `rate_limit_signal`, `corridor_revocation`, `bridge_risk_signal`,
  `commune_policy_signal`) must NEVER contain raw traffic, user identities,
  locations, or complete topology maps. They carry only scope, severity, reason
  code, TTL, evidence class, signer or quorum, and a reversible action hint. A
  signal that exceeds this envelope is `IMMUNE_SIGNAL_OVERREACH` (S1; S0 if it
  carries identity or location).

Canonical rule: Mycelium is not a universal bypass substrate. The Core provides
compatibility; Communes provide life. Communes may cooperate, isolate, defend
themselves, and evolve different genetics — no global authority owns the
Mycobiome. Mycelium must grow through anything, but must not attack through
everything.

The list of named categories is extended via separate RPs/ADRs. For unnamed
findings, the auditor assigns severity per §7.

---

## 8. When Refactoring Is Mandatory

Refactoring is mandatory when at least one of the following conditions is
identified:

- a layer is taking on the responsibility of another layer;
- a hidden channel or direct cross-layer link has appeared that bypasses the
  contract;
- a component has appeared that knows more about the user than necessary
  (`USER_DEANON` / `TRAFFIC_CORRELATION` risk);
- a transport has become distinguishable or has failed active probing;
- path redundancy has degraded to a single point of block;
- the compatibility contract has become fragile and risks leaving nodes without access;
- a temporary workaround (that restored reachability at the cost of indistinguishability
  or anonymity) has become permanent;
- documentation drift (especially in THREAT-MODEL) persists for more than one cycle;
- system degradation is undescribed and unmanaged (no explicit policy or SLO);
- a phase transition requires rewriting contracts between layers;
- changing one component systematically breaks multiple adjacent ones;
- the transport/route selection policy has diverged from actual execution.

---

## 9. When Refactoring Is Prohibited

Refactoring is prohibited when:

- the problem has not been articulated;
- the affected layers and components have not been identified;
- there are no success criteria;
- the impact on contracts and compatibility is not understood;
- there is no analysis of the impact on indistinguishability, anonymity, and
  attack surface;
- there is no plan for updating documentation (including THREAT-MODEL, where
  applicable);
- there is no test coverage or way to verify the outcome;
- the refactoring is motivated solely by aesthetics;
- it degrades observability, compatibility, indistinguishability, or anonymity;
- it hides the problem instead of addressing the root cause.

---

## 10. Required Artifacts Before Refactoring

Before beginning an architecturally significant refactoring, the following must
exist:

- problem description;
- description of current state;
- description of desired state;
- list of affected layers and components;
- risk analysis;
- impact on contracts and compatibility (node ↔ node ↔ config distribution
  endpoint ↔ coordinator);
- impact on indistinguishability / attack surface;
- impact on anonymity ("what the node knows about the user" before/after);
- impact on operational resilience and degradation;
- acceptance criteria (verifiable);
- documentation update plan.

Minimum format: ADR or Refactoring Proposal. See the template at
[templates/refactoring-proposal.md](templates/refactoring-proposal.md) and §13.

---

## 11. Required Artifacts After Refactoring

After refactoring is complete, the following must be updated:

- [ARCHITECTURE.md](ARCHITECTURE.md) (layer diagram / transport matrix / stack);
- [THREAT-MODEL.md](THREAT-MODEL.md), if the attack surface or assets changed;
- [ROADMAP.md](ROADMAP.md), if the phase scope or Definition of Done shifted;
- contracts between layers / telemetry schemas / config distribution format;
- tests (including measurable survivability/recovery checks, where applicable);
- documentation for flows (bootstrap, auto-rotation, rerouting);
- architectural decision log (ADR);
- audit record of the changes.

If any mandatory artifact has not been updated, the refactoring is considered
incomplete.

### 11.1. Red master freeze

If `main` or the current integration branch has red CI, a strict freeze applies:

- only fix-forward commits that directly target returning CI to green are permitted;
- new RP features, new scope expansions, and opportunistic "while we're at it"
  changes are prohibited;
- only minimal docs/version edits that are required for the correctness of the
  fix-forward commit itself are permitted;
- once CI returns to green, the normal RP flow may resume.

**Mycelium special case — "red production" during a network-interference incident.** If an
active blocking event is degrading user reachability in production, the same incident mode
applies: only changes that restore reachability **without weakening security or
anonymity** are permitted. Any temporary workaround that sacrifices these
properties is only acceptable as an explicit, documented degradation policy,
must be recorded as a finding, and must be removed as soon as the situation
stabilizes. After a series of fix-forward commits, a **Closure Verification**
(§12.9) is conducted, not a new full-scale audit.

---

## 12. Mandatory Audit Template

Every significant audit must be formatted according to the template.
The template is at [templates/audit.md](templates/audit.md).
Completed reports are stored in [audits/](audits/).

### 12.1. Header
- date;
- scope;
- roadmap phase / branch / commit range;
- participants;
- audit type (PR / tactical / full-scale / event-triggered / post-incident).

### 12.2. Executive Summary
- brief overall assessment;
- key risks (S0/S1);
- overall verdict (`pass` / `pass_with_conditions` / `fail`);
- brief Expert Lens Scores table per §6.2.

### 12.3. Objects under review
- layers and components;
- transports and transport profiles;
- contracts and compatibility;
- scenarios (blocking, degradation, recovery, bootstrap);
- docs (including THREAT-MODEL);
- observability and measurements;
- failure modes.

### 12.4. Findings
For each finding:
- ID;
- category (including named category from §7);
- severity;
- description;
- affected layers/components;
- root cause;
- risk (to user / availability / anonymity);
- recommendation.

### 12.5. Drift
- where code has diverged from canon;
- where canon (including THREAT-MODEL) is outdated;
- what must be updated.

### 12.6. Decisions
- accepted;
- rejected;
- deferred;
- requires additional RFC/ADR.

### 12.7. Action Items
- what to do;
- owner;
- deadline;
- blocking / non-blocking.

### 12.8. Follow-up
- date or condition for re-audit;
- gate criterion for follow-up review.

### 12.9. Closure Verification after a liquidation wave / incident

After a series of cleanup/liquidation RPs or a series of fix-forward commits
during a network-interference incident, a new full-scale audit is not triggered by
default. Instead, a short **Closure Verification** report is produced.

Closure Verification scope:

- claims that each RP/fix-forward declared as closed;
- conformance evidence for each claim or bundle (including reachability restoration and
  absence of security weakening);
- absence of new boundary drift and new hidden channels;
- CI green on the verified HEAD;
- README / ARCHITECTURE / THREAT-MODEL / CHANGELOG / version sync;
- list of remaining open findings with severity and owner;
- confirmation that temporary workarounds from the incident period have been
  removed.

Closure Verification does not re-search for all findings. Its purpose is to prove
that the incident-response sequence actually closed what was claimed and did not
create new debt of the same class.

---

## 13. Mandatory Refactoring Proposal Template

The template is at [templates/refactoring-proposal.md](templates/refactoring-proposal.md).
Completed proposals are stored in [proposals/](proposals/) as
`docs/proposals/NNNN-<slug>.md` (zero-padded, monotonically increasing number, ID `RP-NNNN`).

### 13.1. Title
Short name for the refactoring.

### 13.2. Rationale
What problem the change solves. Include references to audit findings where the
issue originated.

### 13.3. Scope
Which layers, components, transports, contracts, telemetry schemas, and flows
are affected.

### 13.3.1. Component participation table (mandatory)

**Every RP must contain a component participation table** — a small structured
grid that names every Mycelium component touched by the proposal and forces the
author to justify its presence (or remove it, merge it, or mark it deferred).

Table columns — five:

| Column | Meaning |
|---|---|
| **Component** | Mycelium layer/component (data plane, control-agent, coordinator, detector, config distribution endpoint, discovery, …) or external surface (CDN edge, core transport engine config, REALITY donor, DHT). |
| **Role in this RP** | One short sentence about what the component **does in this flow** (not its general project role). |
| **Status** | One of `active` / `passive` / `deferred` / `test-only`. |
| **External tech** | Non-proprietary technology used by the component **in this RP** (e.g., Xray, sing-box, AmneziaWG, Hysteria2, libp2p, Caddy, Cloudflare, Headscale, …). `none` when nothing external is used. |
| **Why not existing tool** | When External tech is named: one sentence of boundary argument explaining why an already-used technology in the project does not cover this work (and why we are not inventing our own — "do not invent crypto/transport" principle). When `External tech = none` → `—`. |

**Status — precise definitions:**

- **active** — the component performs runtime work as part of the proposed flow
  (carries traffic, mutates config/state, makes a detector decision, validates
  input on the hot path).
- **passive** — the component is read but not mutated; its existence is necessary
  for the flow, but the RP does no new work in it.
- **deferred** — the component is mentioned because a future phase will activate
  it, but it is intentionally inert in this RP. The RP body must specify the
  future phase/RP ("multi-hop — deferred, activates in Phase 5").
- **test-only** — the component participates only in conformance/smoke fixtures,
  not in the production runtime flow introduced by the RP.

**Gate applied by author and reviewer:**

> **If a component does not pass the table — it must be removed, merged, or
> marked deferred.** Listing a component without a justified role is a sign that
> the author is over-claiming participation.

### 13.3.2. RP blast-radius cap

An ordinary single-phase RP must not simultaneously change more than:

- **1 layer/boundary shift** — moving responsibility/source-of-truth/policy
  between layers (data ↔ control ↔ routing ↔ discovery);
- **1 transport / behavior shift** — adding or substantially changing one
  transport, detector, rotation loop, or the semantics of one flow;
- **1 node/config-distribution surface shift** — a new or substantially changed
  node-facing or config-distribution interface.

If a proposal exceeds any of these limits, the author must choose one of:

- split into multiple RPs;
- produce a pre-declared multi-phase RP where each phase has its own acceptance
  criteria and conformance evidence;
- explicitly justify emergency fix-forward mode if this is part of a red-master /
  incident stabilization.

The rule's goal is not to prohibit large changes, but to avoid mixing several
distinct risks (especially security risks) in a single review surface.

### 13.4. Current state
What is working poorly now. Specifically: which transports, which contracts,
which rotation/routing rules.

### 13.5. Target state
How things should look after the changes. Concrete interfaces, contracts,
policies, and knowledge boundaries.

### 13.6. Risks
- **Compatibility:** node ↔ node ↔ config distribution endpoint ↔ coordinator;
- **Loss of observability / measurements:** …
- **Impact on indistinguishability / attack surface:** …
- **Impact on anonymity ("what the node knows"):** …
- **Temporary degradation and rollback risk:** …

### 13.7. Acceptance Criteria
Verifiable success indicators (tests / scenarios / measurable survivability and
recovery metrics).

### 13.8. Documentation changes
What must be updated (with file references): ARCHITECTURE, THREAT-MODEL, ROADMAP,
contracts, ADR.

### 13.9. Migration Strategy
How to transition the system without breaking access: stages, parallel
coexistence of old/new transport/contract, the moment of final cutover,
dependencies.

### 13.10. Rollback / Fallback
What to do if the refactoring fails: how to roll back without losing user access,
which versions to keep in parallel, how not to leave nodes in an unsafe state.

---

## 14. Gate Criteria Before Merge

An architecturally significant refactoring may not be merged unless all of the
following conditions are met:

- PR audit passed (§16);
- contracts updated and node/config-distribution compatibility verified;
- documentation updated (ARCHITECTURE and, where applicable, THREAT-MODEL /
  ROADMAP);
- no unresolved S0 or S1 findings;
- tests green;
- no new hidden channels / direct cross-layer links that bypass contracts;
- indistinguishability not degraded (no new fingerprint / probe failure);
- the "what the node knows about the user" model not expanded without explicit
  justification;
- migration path formulated where needed;
- if a phase transition is involved — domain Expert Lens Scores have been
  assigned, and no domain lens is below `5.0` with an open S0/S1.

---

## 15. Mycelium-Specific Requirements

### 15.1. Hidden channels between layers are prohibited
data / control / routing / discovery interact only through declared contracts.
Direct access by one layer to another's internal structures, a "temporary"
side-channel, or an unexplained artifact is an architectural defect (risk of
leakage/correlation). This is a direct analogue of the "node knows the minimum"
principle.

### 15.2. Control plane and discovery must be at least as persistent and resilient as the data plane
It is pointless to have an reachable tunnel if configs, commands, and first
contact are served from a domain that can be cut in minutes. The contract
"data lives longer than management" is unacceptable: control plane and bootstrap
travel through the same covert channels (CDN-front, domain-fronting, anycast,
P2P-fallback) as the data. Violation: `SINGLE_POINT_OF_BLOCK` (S0).

### 15.3. Knowledge minimization is a boundary, not a preference
The node, coordinator, and telemetry know the minimum about the user by default;
there are no logs by default. Any change that expands a component's knowledge of
the user or of user connections requires explicit justification and an update to
THREAT-MODEL. An ingress endpoint must not simultaneously know "who" and "where"
(ingress/egress separation, multi-hop at phase 5+). Violation: `USER_DEANON` /
`TRAFFIC_CORRELATION` (S0).

### 15.4. Indistinguishability matters more than obfuscation
The goal is statistical resemblance to legitimate HTTPS/QUIC, not a "hidden VPN."
A REALITY/cover configuration always uses a real donor site that responds
legitimately to active probing. A new transport without an indistinguishability
check and probe-behavior test does not pass. Violation: `DISTINGUISHABLE_TRANSPORT`
(S0).

### 15.5. Degradation is an explicit policy, not a silent branch
"Degradation, not failure" means a managed transition to a degraded-but-working
mode. Any fallback that sacrifices anonymity or indistinguishability in order to
restore reachability (e.g., switching to a less covert path) must be an explicit,
bounded, and documented degradation policy with security-model consent. A silent
emergency bypass that breaks fail-closed is `SILENT_DEGRADATION` (S0).

### 15.6. Redundancy by default; a single point of block is prohibited
Multiple transports, ports, SNI values, donors, IPs, and ASes operate
simultaneously; the AS-block pattern ("handshake passes, data dies") is accounted
for. A state in which declared redundancy has effectively collapsed to a single
real path is `REDUNDANCY_COLLAPSE` (S1). A single point of failure for the entire
network is `SINGLE_POINT_OF_BLOCK` (S0).

### 15.7. Sybil resistance from the moment of open membership
As soon as joining the network becomes open (phases 5–6), discovery must resist
enumeration and flooding: joining has a cost (invites/social graph/PoW), a new
node routes little and knows little (knowledge gradient). Discovery that allows
cheap enumeration of most ingress endpoints is `ENUMERATION_EXPOSURE` (S1; S0 at
phase 5+).

### 15.8. Refactoring must not break phase transitions
Layers are stable across phases — implementation changes, but contracts between
layers do not. If after a refactoring the next roadmap phase cannot be reached
without rewriting the contracts between layers, the refactoring is considered a
failure.

### 15.9. Do not invent cryptography or transports
The project is built on proven, audited primitives and implementations (Xray/sing-box,
AmneziaWG, libp2p, Snowflake/Headscale patterns). Any proposal that introduces
custom cryptography or a custom transport protocol instead of a standard one
requires a separate RFC with justification and is rejected by default.

### 15.11. Selective Growth — the tunnel carries only impaired-path traffic
*The mycelium does not grow where it is not needed.* Split-tunnel is the default,
not a tuning option. A node, and every client/route config it renders, must carry
through the tunnel **only** traffic whose **native path is impaired** — degraded,
throttled, or unreachable on the direct route. Destinations whose native path is
unimpaired route **direct**. A generated config that full-tunnels by default, or
that routes natively-reachable destinations through the tunnel, is `OVERBROAD_GROWTH`
(S1; see §7).

This is not only frugality — it is a safety boundary. Over-broad growth enlarges,
for no reachability gain, the volume/timing/destination set a single hop observes
(a correlation surface, cf. §15.3) and concentrates ordinary native traffic onto
the impaired-path egress. The mechanism the empirical posture must respect: where
direct reach is degraded, the degradation is a destination-AS / subnet,
download-direction throughput filter hitting out-of-region hosters and CDNs **as a
class** — so fronting via any out-of-region CDN does not help, and a TLS-terminating
front additionally leaks the user's source address and destination hostnames to a
third party (worse where that party is compelled to log). The path that survives is
one that **never traverses the high-interference border filter**: an in-region
ingress, with out-of-region egress carried node-to-node (an anastomosis hop), never
user-direct to an out-of-region node. Routing native traffic over that scarce path,
or routing a user user-direct across the border filter, is the over-growth this
rule forbids.

The precise instrument is a **domain-aware split** (the xray-class transports'
geo-routing). CIDR-only transports (the WireGuard-class / AmneziaWG) can only
**approximate** it via region-exclude route sets; a CIDR-only config that cannot
express the split still owes a documented region-exclude route set — never a blanket
default route. (Manual operator-built two-hop and per-client split-tunnel routing
are **current-posture** deployment patterns; automated cross-node route selection
is Phase 4-6 — this rule governs the *config that is rendered now*, under that
phase discipline.)

---

## 16. Minimum PR Audit Checklist

- [ ] Layer boundaries not violated (data / control / routing / discovery)
- [ ] No new hidden channels / direct cross-layer links that bypass contracts
- [ ] "What the node knows about the user" model not expanded without justification
- [ ] Indistinguishability not degraded (no new fingerprint, banner, unexpected port)
- [ ] Cover site still returns a legitimate response to active probing
- [ ] Compatibility preserved (node ↔ node ↔ config distribution endpoint ↔ coordinator)
- [ ] Versioning complied with
- [ ] No silent degradation that sacrifices security/anonymity (fail-closed)
- [ ] Path redundancy has not collapsed to a single point of block
- [ ] Secrets/keys not in code, logs, or un-noised telemetry
- [ ] Telemetry/blockage intelligence remains aggregated and anonymous
- [ ] Documentation updated (ARCHITECTURE and, where required, THREAT-MODEL)
- [ ] Change is explainable and localized

---

## 17. Minimum Full-Scale Audit Checklist

- [ ] Layered model is current and contracts between layers are stable
- [ ] Every "attack → response" row in the THREAT-MODEL matrix is covered by code
- [ ] All five protected assets are actually protected
- [ ] Indistinguishability verified across all active transports (including probe)
- [ ] No component knows more about the user than necessary (deanon/correlation)
- [ ] Ingress/egress separation maintained; a single hop does not know the full path
- [ ] Control plane and bootstrap are at least as persistent and resilient as the data plane
- [ ] No single point of block/failure for the entire network
- [ ] Sybil/enumeration: joining has a cost, knowledge gradient exists (phase 5+)
- [ ] Managed degradation exists and the recovery SLO is measurable
- [ ] Auto-rotation has limits, hysteresis, and rollback (no flapping)
- [ ] Rerouting works and does not leak the path
- [ ] Transition to the next phase remains possible without rewriting contracts
- [ ] Domain Expert Lens Scores assigned: Security/Threat, Network-persistence, Anonymity/Privacy
- [ ] McConnell score assigned; where applicable — Operational-resilience, Cormen/Tanenbaum/Parnas/Brooks/Dijkstra
- [ ] The lowest lens score is explained by a finding/action item
- [ ] No domain lens below 5.0 with an open S0/S1 before a phase transition

---

## 18. Documentation Policy

### Must be documented:
- all S0 and S1 findings;
- all refactoring proposals;
- all decisions changing contracts and compatibility;
- any change to attack surface / protected assets (→ update THREAT-MODEL);
- any change to what the node knows about the user;
- addition/change of a transport or transport profile;
- changes to bootstrap, discovery, sybil resistance, or the trust model;
- changes to degradation policy and rerouting;
- post-incident analysis of every real blocking or network-interference event.

### May be documented briefly:
- S2 and S3 findings;
- local structural improvements;
- non-systemic observations.

### Not permitted:
- keeping architectural decisions only in someone's head;
- treating code as the sole documentation;
- deferring documentation "until later" once canon has already changed;
- leaving THREAT-MODEL behind the actual attack surface.

---

## 19. How Often to Update This Document

`refactoring.md` must be reviewed:
- after every roadmap phase transition;
- after every real blocking or network-interference event and associated post-incident audit;
- after every major change to the architecture or threat model;
- at minimum once per quarter;
- when systematic problems are identified in auditing or refactoring practice.

---

## 20. Final Rule

If a change:
- affects the architecture or contracts between layers,
- changes the attack surface or threat model,
- changes what the node knows about the user,
- changes indistinguishability, redundancy, or network persistence,
- changes bootstrap, discovery, sybil resistance, or degradation,
- changes the ability to transition between phases,

then it must pass an audit, must be documented (including THREAT-MODEL where
applicable), and must have a formally recorded outcome.

Mycelium must evolve through controlled changes, not through an accumulation of
architectural accidents. In a persistent private network, an accident is not just
debt: it is a potential fingerprint, a correlation channel, or a point of block.
User safety is functional requirement #1, and auditing exists to ensure that
requirement does not erode under pressure to restore reachability quickly.
