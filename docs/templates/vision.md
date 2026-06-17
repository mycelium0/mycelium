<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Vision & Scope — `<short initiative title>`

> **Document type.** Vision & Scope template. Describes the **direction** of a
> major initiative (phase, cross-cutting track, new layer/mechanism) — before
> ADR decisions and RP work items exist. This is "why and where", not "how".
> The finished document is saved as `docs/vision/NNNN-<slug>.md`, slug in
> kebab-case; ID — `VIS-NNNN` (zero-padded, monotonically increasing).
>
> **When to write a Vision.** Before launching a roadmap phase, before opening a
> cross-cutting track (bootstrapping, measurements, opsec/legal, governance),
> before introducing a new layer/mechanism (e.g. decentralised discovery), or
> when an RFC is required per
> [../refactoring.md](../refactoring.md). An accepted Vision produces ADRs
> (decisions) and RPs (work items).
>
> **What this is not.** Not a specification or design: no final interfaces,
> detector thresholds, or schemas here. Hypotheses are framed as research tasks,
> not as ready-made canon.
>
> **See also:** [adr.md](adr.md), [refactoring-proposal.md](refactoring-proposal.md),
> [research-note.md](research-note.md), [../ROADMAP.md](../ROADMAP.md),
> [../ARCHITECTURE.md](../ARCHITECTURE.md), [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Metadata
- **ID:** VIS-NNNN
- **Date:** YYYY-MM-DD
- **Author:** mindicator & silicon bags quartet
- **Status:** draft | review | accepted | superseded by VIS-MMMM | archived
- **Horizon:** Phase 0–5 / cross-cutting track (see [../ROADMAP.md](../ROADMAP.md))
- **Layer(s):** data plane | control plane | routing | discovery | infra | cross-cutting
- **Related:** <previous Vision / Audit-NNNN / research-note / ADR / RP>

## 1. Problem and context
Current situation and what is wrong. What adversary reality does the initiative
address (with reference to [../THREAT-MODEL.md](../THREAT-MODEL.md): large-scale
network degradation, ML-based traffic classification, active probing, IP/AS blocking, UDP
throttling/cutting, config-distribution blocking, sybil enumeration of ingress
points, protocol allowlisting shutdown, operator coercion). Why now.

## 2. Vision (desired outcome)
The desired state in one or two paragraphs. What **property for the user**
emerges when the initiative is complete. Anchor to the project's core property:
*reliable private connectivity for the people and groups who need it, given a
channel to the network and at least one reachable, working node in the mesh.*

## 3. Principles governing this initiative
Confirm compatibility with the project core (note specifically how each is
satisfied):
- [ ] **Do not reinvent cryptography or transport** — stand on proven foundations
  (Xray/sing-box, AmneziaWG, libp2p, Snowflake/Headscale patterns).
- [ ] **Indistinguishability over obfuscation** — statistical similarity to
  legitimate HTTPS/QUIC, not a "hidden VPN".
- [ ] **Redundancy by default** — multiple protocols/ports/SNI/IPs/ASes.
- [ ] **Degradation, not failure** — losing a node or coordinator slows, does
  not stop.
- [ ] **User security is function №1** — opsec/legal considerations are addressed
  here, not deferred.

## 4. Scope
### In scope
- …

### Out of scope / explicitly not doing now
- Any end-user client application or bespoke client is **out of scope**.
  Nodes expose standard protocol endpoints consumed by existing off-the-shelf
  clients (consumption interface — standard clients connect to standard
  endpoints); a bespoke client is possible future work only.
- …

### Deferred → future phase/Vision
- …

## 5. Target audience and scenarios
- **Who:** node operator / volunteer running a home machine behind NAT /
  community maintaining a mesh segment.
- **Key scenarios:** … (node joining the mesh via bootstrap config; auto-recovery
  after a blocking event; first contact when "everything is blocked"; node
  onboarding behind NAT).

## 6. Assets and trade-offs
- **Protected assets in focus:** user identity/location · traffic content ·
  ingress reachability · operators · network map.
- **Conscious trade-offs:** anonymity trilemma (latency ↔ capacity ↔ anonymity —
  which two and why), openness ↔ sybil-resistance, indistinguishability ↔
  cost/latency, adaptation speed ↔ false-migration risk, centralisation
  (simplicity) ↔ decentralisation (resilience).
- **Technical debt accepted knowingly:** … (e.g. central coordinator in Phase 3
  as a target — plan to remove in Phase 4).

## 7. Definition of Done (measurable, not a slogan)
How we will know the Vision is realised. Frame as measurable properties and
production checks with real users (modelled on DoD in
[../ROADMAP.md](../ROADMAP.md)):
- [ ] … (e.g. "we artificially block the active transport → nodes recover without
  human intervention within minutes").
- [ ] … (survivability metric / time to recovery / SLO).
- [ ] … (production check with an unprepared user).

## 8. Measurability and observability
Which signals/metrics will prove success and feed the adaptation layer
(self-tuning, layer 2): handshake success rates, TTFB, disconnections,
detector precision/recall on labelled incidents, time to recovery, share of
ingress points that survived targeted blocking. What OONI-style measurements
are needed up front (without data, adaptation is blind).

## 9. Dependencies and prerequisites
- **Preceding phases/Vision/ADR** that must complete before starting.
- **External stack/infra:** … (Cloudflare/CDN, provider with rapid IP rotation,
  hosting in "clean" ASes, libp2p, Headscale).
- **Cross-cutting tracks** that cannot be deferred: bootstrapping, security,
  measurements, legal/opsec, governance/funding.

## 10. Risks and open questions
- **Strategic risks:** … (what nullifies the initiative's value — e.g.
  allowlist-only scenario, the ongoing adaptation against ML classifiers, sybil attacks).
- **Fundamentally hard problems**, acknowledged honestly (not "we'll sort it
  out"): …
- **Open questions → research / RFC:** … (move to `docs/research/` or RFC).

## 11. What becomes possible next
Which subsequent phase/initiative builds on this result (the mesh is extended
on top of something working, not instead of it).

## 12. Next steps
- [ ] ADR for key decisions (`docs/adr/NNNN-...`).
- [ ] RP for work items (`docs/proposals/NNNN-...`).
- [ ] research-note for open questions (`docs/research/...`).
- [ ] Trigger an audit when a new layer/domain is connected, if required
  ([../refactoring.md](../refactoring.md)).
