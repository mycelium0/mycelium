<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0027: `Selective growth and in-region ingress topology`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: the tunnel
> carries **only** traffic whose native path is impaired (**Selective Growth** — split-tunnel by default
> in generated client configs; native-reachable destinations route direct); **ingress is placed in-region**,
> on a path that never traverses the high-interference border filter; and **out-of-region egress is carried
> node-to-node (an anastomosis hop), never user-direct to an out-of-region node** — because out-of-region
> direct reach is degraded by a **destination-AS / subnet, download-direction throughput filter** that hits
> out-of-region hosters/CDNs as a **class**, and because **out-of-region CDN fronting** is neither a reliable
> primary path (it shares that degraded class) **nor metadata-safe** (a TLS-terminating front leaks the
> user's source address and destination hostnames to a third party). Saved as
> `docs/adr/0027-selective-growth-and-in-region-ingress.md`.
>
> **Scope note.** This ADR pins the **default routing posture of generated configs** (split-tunnel by
> default) and the **ingress/egress topology** (in-region ingress; out-of-region egress via a node-to-node
> hop) as a **current-posture deployment doctrine** — the deployment shapes an operator builds **by hand
> today**: a manually-established two-hop (in-region ingress node → out-of-region egress node) and
> per-client split-tunnel route sets. It does **NOT** introduce automated cross-node bridging, automated
> route selection, gossip, or dynamic path-finding — those remain Phase 3-5 per
> [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md). The cross-Commune **contract** that an
> automated node-to-node hop will eventually ride is [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md);
> this ADR records **why** the topology is shaped this way and what the **manual** form is now.
>
> **See also:** [0010-phase0-transport-set.md](0010-phase0-transport-set.md) (the engine matrix:
> the xray-class TLS engines vs. the WireGuard-class non-TLS path — the precision of the split differs by
> engine), [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md)
> (phase discipline: manual operator topology now, automation Phase 3-5),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md) (the self-sufficient node;
> the egress node a hop reaches is another operator's box, not a shared relay),
> [0016-software-releases-not-an-operated-network.md](0016-software-releases-not-an-operated-network.md)
> (software, not an operated network; **not a universal bypass substrate**),
> [0021-decentralized-observability-not-a-central-collector.md](0021-decentralized-observability-not-a-central-collector.md)
> (the vantage problem: the impairment that shapes this topology cannot be measured from the operator's own
> clean network), [0026-anastomosis-bridges-and-safe-defaults.md](0026-anastomosis-bridges-and-safe-defaults.md)
> (Anastomosis Bridges + closed-by-default safe defaults — the contract grammar an automated node-to-node
> egress hop must satisfy, and the closed posture this ADR's split-tunnel default is consistent with),
> [../vision/0006-decentralized-observability.md](../vision/0006-decentralized-observability.md) (VIS-0006,
> the vantage problem in full), [../THREAT-MODEL.md](../THREAT-MODEL.md),
> [../GLOSSARY.md](../GLOSSARY.md), [../refactoring.md](../refactoring.md) §7, `scripts/node-bootstrap.sh`
> (`setup_amneziawg` — the generated client config whose `AllowedIPs` default this ADR governs).

---

## Metadata

- **ID:** ADR-0027
- **Date:** 2026-06-14
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** routing/orchestration (split-tunnel default + ingress/egress placement), data plane
  (generated client config route sets; the node-to-node egress carriage), infra (the manual two-hop
  deployment shape); cross-cutting reachability track
- **Phase:** the **split-tunnel default in generated configs** and the **manual in-region-ingress /
  node-to-node-egress two-hop** are **current-posture deployment patterns** — an operator builds them by
  hand today, and they follow from per-operator nodes ([ADR-0014](0014-per-operator-node-credentials.md))
  and the existing engines ([ADR-0010](0010-phase0-transport-set.md)), not from any cross-node machinery.
  **Automated** cross-node bridging, automated route/path selection, and dynamic egress-hop discovery are
  **Phase 3-5** (the gossip/DHT/bridge machinery, riding the
  [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) contract).
- **Related:** [ADR-0010](0010-phase0-transport-set.md) (xray-class domain-aware split vs. WireGuard-class
  CIDR-only route sets — the instrument precision this ADR depends on);
  [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md) (manual now / automated later split);
  [ADR-0014](0014-per-operator-node-credentials.md) (the egress hop terminates on another operator's
  self-sufficient node, never a shared relay); [ADR-0016](0016-software-releases-not-an-operated-network.md)
  (not a universal bypass substrate — Selective Growth is the structural expression of that rule in the data
  plane); [ADR-0021](0021-decentralized-observability-not-a-central-collector.md) / VIS-0006 (the vantage
  problem — the destination-AS throughput filter that motivates this topology is an **in-region edge** signal
  the operator's clean network cannot see, corroborated only by a two-vantage test);
  [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) (the node-to-node egress hop is, when automated,
  an **egress-capability** Anastomosis Bridge under an explicit contract — anonymous egress is **not** a
  default primitive); `scripts/node-bootstrap.sh` (`setup_amneziawg`, whose generated client `AllowedIPs`
  default this ADR governs); [../refactoring.md](../refactoring.md) §7
  (`OPEN_RELAY_OR_DEFAULT_EGRESS`, `BRIDGE_WITHOUT_CONTRACT`, `TELEMETRY_SAFETY_VIOLATION`).

## Context

What prompted this decision is an **empirical reachability finding**, corroborated by the operator's own
two-vantage test, about **how** out-of-region direct reach is degraded from a high-interference network —
and what topology survives it.

The finding, stated as mechanism (neutral, no loaded access framing):

- **The impairment is destination-keyed and download-direction.** Out-of-region direct reach is degraded by
  a **destination-AS / subnet, download-direction throughput filter**: a connection to an out-of-region host
  completes and passes a small amount of data (~16 KB observed), then the **download direction stalls**.
  The filter keys on the **destination** address range, not on the protocol shape of the first bytes — the
  TLS handshake and the first response chunk succeed, then the egress download is throttled to a stall.
- **It hits out-of-region hosters/CDNs as a CLASS.** Because the filter is keyed on out-of-region egress
  **destination ranges**, it degrades out-of-region hosters and CDNs **as a class**, not host-by-host.
  **Therefore fronting via any out-of-region CDN does not help**: a different out-of-region front is still an
  out-of-region destination range, and shares the degraded class. CDN fronting is **not a reliable primary
  path** against a destination-AS throughput filter.
- **A TLS-terminating front is also metadata-unsafe.** Even where it appears to work, a TLS-terminating CDN
  front **leaks the user's source address and the destination hostnames to a third party** — and is worse
  precisely where that third party is compelled to log. Routing the user's traffic through a TLS-terminating
  third party trades an impaired path for a deanonymizing one.
- **The path that survives never crosses the border filter.** The surviving shape is **in-region ingress** —
  the user connects to an **in-region** node over an **in-region path** that does not traverse the
  high-interference border filter — with **out-of-region egress carried node-to-node** (an **anastomosis
  hop**, in-region node → out-of-region node), **never user-direct to an out-of-region node**. The border
  filter is on the user↔out-of-region direct path; an in-region ingress with an internal node-to-node
  egress hop simply never offers that path the filter is watching.

The forces this finding puts in tension:

- **Adversary model.** A **destination-AS / subnet, download-direction throughput degradation** of
  out-of-region egress ranges, applied to out-of-region hosters/CDNs as a **class** ([../THREAT-MODEL.md](../THREAT-MODEL.md)
  — destination/AS-keyed throughput throttling, distinct from DPI handshake-shape blocking and from UDP
  cutting). Secondarily, **operator/third-party coercion**: a TLS-terminating front is a compelled-logging
  surface that links source address to destination hostnames.
- **Affected asset.** Ingress reachability (the surviving path must be an in-region one the filter does not
  watch) · the **user's source address + destination hostnames** (which a TLS-terminating front would expose
  to a third party) · the **absence of a default egress / open relay** (an out-of-region egress hop must not
  become a default-on relay — [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)).
- **The vantage problem (why this is in an ADR, not a config tweak).** This destination-AS throughput filter
  **cannot be measured from the operator's own clean network** ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md);
  VIS-0006): external probing from a transit-clean vantage sees a healthy out-of-region path. The impairment
  is only visible from an **in-region** vantage — which is exactly why it took a **two-vantage** test to
  corroborate, and why the topology must be designed around a signal the operator cannot routinely see.
- **Fundamental trade-off (reach ↔ exposure ↔ overhead).** A full tunnel (carry *everything*) is simplest
  but needlessly routes natively-reachable, in-region traffic through the hop — added latency, added node
  load, and a larger correlated flow. A split tunnel (carry *only the impaired*) minimizes all three but
  needs an accurate "which destinations are impaired" boundary, and the precision of that boundary differs by
  transport engine (see Decision 3). The doctrine resolves this toward **carrying only what is impaired**:
  *the mycelium does not grow where it is not needed.*

This ADR composes with the closed-by-default posture already in canon. The out-of-region egress hop is, the
moment it is **automated** across operators, an **egress-capability** connection — and
[ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) already binds that: **anonymous egress is not a
default primitive**, an egress capability crosses only under an explicit Anastomosis-Bridge contract. This
ADR adds the **reachability reason** the hop is shaped node-to-node rather than user-direct; it does not
loosen ADR-0026's contract requirement for the automated form.

## Considered Options

> "Leave the generated config as a full tunnel and let users reach out-of-region nodes directly / front via
> a CDN" is **option 0** and is rejected by recording this ADR: a user-direct out-of-region path is exactly
> the path the destination-AS throughput filter degrades, and a CDN front shares the degraded class while
> leaking destination metadata to a third party.

1. **Full tunnel + user-direct out-of-region reach (and/or out-of-region CDN fronting) (option 0).** The
   generated client config carries all traffic (`AllowedIPs = 0.0.0.0/0`); the user reaches an out-of-region
   node directly, or fronts through an out-of-region CDN.
   - Pros: simplest possible config and mental model; one route set; no per-destination boundary to maintain;
     CDN fronting reuses ubiquitous infrastructure.
   - Cons: the user-direct out-of-region path **is** the path the destination-AS / download-direction
     throughput filter degrades (~16 KB then stall); CDN fronting **shares the degraded out-of-region class**,
     so it is not a reliable primary path; a TLS-terminating front **leaks source address + destination
     hostnames to a third party** (worse under compelled logging); a full tunnel needlessly routes
     in-region, natively-reachable traffic through the path too, adding latency, node load, and a larger
     correlated flow.
   - Impact on survivability: poor — the primary path is the one under the filter, and the "fallback" (CDN)
     is both in the same degraded class and a deanonymizing third party.

2. **Out-of-region ingress with obfuscation tuned to beat the filter at the user's direct edge.** Keep the
   user connecting directly to an out-of-region node, but invest in transport obfuscation to evade the
   throughput filter.
   - Pros: no second node needed; a single-hop deployment.
   - Cons: the filter is **destination-AS / subnet keyed, not handshake-shape keyed** — it degrades the
     out-of-region **destination range** regardless of how the first bytes look; obfuscation that defeats a
     DPI handshake classifier does **not** move the destination out of the throttled class. This spends
     effort on the wrong layer.
   - Impact on survivability: poor against this specific filter — wrong instrument for a destination-keyed
     throughput degradation.

3. **In-region ingress + node-to-node out-of-region egress + split-tunnel-by-default (chosen).** The user
   connects to an **in-region** ingress node over an in-region path the border filter does not watch; the
   out-of-region egress is carried **node-to-node** (in-region node → out-of-region node), never user-direct;
   and the **generated config carries only impaired traffic** (Selective Growth — split-tunnel default;
   native-reachable destinations route direct).
   - Pros: the surviving path **never traverses the border filter**, because the user never offers a
     user↔out-of-region direct path; no user traffic is TLS-terminated by a third-party front, so source
     address + destination hostnames are not leaked; the split tunnel keeps in-region native traffic off the
     hop (less latency, less node load, a smaller correlated flow); it is the structural data-plane
     expression of *not a universal bypass substrate* ([ADR-0016](0016-software-releases-not-an-operated-network.md))
     — the tunnel grows only where reach is impaired; the **manual** two-hop is buildable today from existing
     per-operator nodes and engines.
   - Cons: requires a **second node** (an out-of-region egress box) for the out-of-region case — more
     operational cost and a hop of added latency; the split-tunnel boundary ("which destinations are
     impaired") must be maintained, and its **precision depends on the engine** (Decision 3); the
     **automated** form of the egress hop is an egress-capability connection that needs the
     [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) contract and is therefore Phase 3-5, not now.
   - Impact on survivability: strongly positive — the primary path avoids the filter by construction, no
     third-party front sees user metadata, and the data plane carries only what it must.

## Decision

**Option 3.** Selective Growth and in-region ingress topology become **canon** for generated configs and the
deployment doctrine.

### Decision 1 — Selective Growth: the tunnel carries ONLY impaired traffic (split-tunnel by default)

The generated client config **carries only traffic whose native path is impaired**; **native-reachable
destinations route direct** (split-tunnel **by default**). This is the data-plane expression of the
operator's principle — **"the mycelium does not grow where it is not needed"** — named **Selective Growth**.
A full tunnel (carry everything) is **not** the default; carrying in-region, natively-reachable traffic
through the hop is the anti-pattern this decision closes.

This is the same closed-by-default spirit as [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)'s
safe defaults applied to **routing**: by default, route the **minimum**; widen only where reach is actually
impaired.

### Decision 2 — Ingress is in-region; out-of-region egress is node-to-node, never user-direct

**Ingress is placed in-region.** The user connects to an **in-region** node over an **in-region path** that
does **not** traverse the high-interference border filter.

**Out-of-region egress is carried node-to-node** — an **anastomosis hop**, in-region ingress node →
out-of-region egress node — and is **NEVER user-direct to an out-of-region node**. The reason is the
destination-AS / download-direction throughput filter: a user↔out-of-region **direct** path is precisely
what the filter degrades; an in-region ingress with an **internal** node-to-node egress hop never offers that
path. The egress node a hop reaches is **another operator's self-sufficient node**
([ADR-0014](0014-per-operator-node-credentials.md)), **not** a shared relay or a default egress
([ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)).

### Decision 3 — Out-of-region CDN fronting is not a reliable primary path AND leaks metadata

**Out-of-region CDN fronting is not adopted as a reliable primary path**, for two independent reasons, either
sufficient:

- **It shares the degraded class.** The throughput filter is keyed on out-of-region **destination ranges**;
  any out-of-region CDN front is still an out-of-region destination, so fronting does **not** move the path
  out of the throttled class.
- **It leaks destination metadata to a third party.** A **TLS-terminating** front sees the user's **source
  address and the destination hostnames** and exposes them to a third party — worse where that party is
  compelled to log. This is unacceptable under requirement №1.

CDN/front infrastructure may still appear as **one shape among many** for ingress reach where it is honestly
metadata-safe and not in the degraded class, but it is **not** the primary out-of-region egress path and is
**never** a TLS-terminating front for user traffic.

This rejection is **scoped to the impaired out-of-region path**, not to the transport. Per **transport
universality** ([VIS-0009](../vision/0009-selective-growth-reachability-topology.md) §3), a CDN-fronted
transport stays a **first-class transport wherever its native path is unimpaired** — it is degraded *here*,
by this environment's destination-class filter, not unfit *everywhere*. Mycelium keeps the **full** transport
set; what this Decision rejects is *relying on it as the primary out-of-region egress through a
high-interference border* and *terminating user TLS at a third party* — never the transport's place in the
universal set, and never the transport itself for the networks that do not degrade it.

### Decision 4 — Engine note: the precision of the split differs by transport class

The instrument that implements the split-tunnel boundary differs by engine
([ADR-0010](0010-phase0-transport-set.md)):

- **The xray-class TLS engines** (the VLESS/REALITY engines — sing-box primary, Xray-core optional) support
  **domain-aware split / geo-routing**: the boundary can be expressed by **destination domain**, which is the
  **precise** instrument for "route this impaired destination through the hop, route that native one direct."
- **The WireGuard-class non-TLS path** (AmneziaWG) is **CIDR-only**: it can only **approximate** the boundary
  via **region-exclude route sets** (an `AllowedIPs` set that excludes in-region native ranges), because it
  has no domain awareness. This approximation is acknowledged as **coarse**, not a defect to hide.

The generated AmneziaWG client config (`scripts/node-bootstrap.sh` `setup_amneziawg`) renders a
**split-tunnel** client by default — it no longer emits `AllowedIPs = 0.0.0.0/0, ::/0`. With an operator-
supplied region-exclude route set (`--region-exclude`) it installs that set; with none it emits a
**safe-narrow** client (tunnel ranges only) and warns. It **never silently full-tunnels**; a deliberate full
tunnel requires the explicit `--full-tunnel` opt-out, which records a documented marker. This posture is
enforced by the `no_full_tunnel_default.sh` conformance gate. The render can only **approximate** the boundary
by CIDR (per this Decision); the precise domain-aware split is the property of the xray-class engines. (The
Ansible `amneziawg` role default still full-tunnels and is tracked separately as a follow-on.)

### Decision 5 — Phase discipline: manual two-hop now; automation later

Per [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md):

- **Current posture (allowed now):** the **split-tunnel default in generated configs**, and a **manually
  operator-built two-hop** (in-region ingress node → out-of-region egress node) with **per-client
  split-tunnel route sets**. These are deployment patterns an operator constructs by hand from existing
  per-operator nodes and engines — no cross-node machinery is required.
- **Phase 3-5 (NOT now):** **automated** cross-node bridging, **automated** route/path selection, dynamic
  egress-hop discovery, and any gossip/DHT-driven topology. When the node-to-node egress hop is **automated
  across operators**, it is an **egress-capability Anastomosis Bridge** and **MUST** ride an explicit
  contract ([ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)): **anonymous egress is not a default
  primitive.** This ADR does not authorize an automated egress hop without that contract.

### Decision 6 — The hard NEVERs (in one place)

- **Never user-direct out-of-region egress** as the primary path (Decision 2) — it is the path the filter
  degrades.
- **Never a TLS-terminating third-party front for user traffic** (Decision 3) — it leaks source address +
  destination hostnames.
- **Never a full tunnel as the generated default** (Decision 1) — carry only the impaired; the mycelium does
  not grow where it is not needed.
- **Never an automated node-to-node egress hop without an [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)
  egress-capability contract** (Decision 5) — anonymous egress is not a default primitive, and the egress
  node is never a shared/open relay ([ADR-0014](0014-per-operator-node-credentials.md)/[ADR-0016](0016-software-releases-not-an-operated-network.md)).

**Canonical Rule (preserved).** Mycelium is **not a universal bypass substrate**. Selective Growth is that
rule made structural in the data plane: the tunnel carries only traffic whose native path is impaired, and it
grows only where direct reach is degraded.

## Consequences

- **Positive:** the surviving path **avoids the destination-AS throughput filter by construction** (no
  user↔out-of-region direct path is ever offered); no user traffic is TLS-terminated by a third-party front,
  so source address + destination hostnames are not leaked; the split tunnel keeps in-region native traffic
  off the hop (lower latency, lower node load, a smaller correlated flow); the design is the data-plane
  expression of *not a universal bypass substrate* ([ADR-0016](0016-software-releases-not-an-operated-network.md))
  and is consistent with the [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) closed-by-default
  posture; the **manual** two-hop is buildable today, with no new automation.
- **Negative / cost (named honestly, not soft-pedalled):**
  - **A second node is required** for the out-of-region case (an out-of-region egress box) — added
    operational cost and one hop of added latency.
  - **The split-tunnel boundary must be maintained**, and its **precision depends on the engine**: the
    xray-class engines do a precise domain-aware split; the **WireGuard-class (AmneziaWG) can only
    approximate** via region-exclude route sets (Decision 4). A coarse CIDR boundary will sometimes route a
    native destination through the hop, or fail to catch an impaired one.
  - **The motivating impairment is hard to observe** ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md):
    the destination-AS throughput filter is invisible from the operator's clean network), so the boundary is
    maintained against a signal the operator cannot routinely see — corroborated only by an in-region
    vantage / two-vantage test.
  - **The automated egress hop is deferred** (Phase 3-5) behind the [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)
    contract; today the topology is operator-manual.
- **Impact on user security (requirement №1):** strongly positive — the user's traffic is **not** routed
  through a TLS-terminating third party, so source address + destination hostnames are not exposed; the user
  never offers the user-direct out-of-region path that links them to the filtered destination range; the
  egress hop terminates on another operator's self-sufficient node, never a shared/open relay; carrying only
  impaired traffic keeps the correlated flow minimal.
- **Impact on observability/measurements:** none added to the collection path; a split-tunnel route set and a
  node-to-node hop are **routing posture**, not a measurement feed, and carry no raw traffic, identity,
  location, or topology map ([ADR-0021](0021-decentralized-observability-not-a-central-collector.md);
  refactoring §7 `TELEMETRY_SAFETY_VIOLATION`). The decision **underscores** the in-region vantage gap
  (VIS-0006): the impairment that justifies the topology is exactly the edge signal the fabric cannot see
  centrally.
- **Follow-on actions required:** move the AmneziaWG generated client config (`scripts/node-bootstrap.sh`
  `setup_amneziawg`) from the full-tunnel `AllowedIPs = 0.0.0.0/0, ::/0` default toward a **region-exclude
  route-set** split-tunnel default (acknowledging it can only approximate — Decision 4); document the
  **manual two-hop** (in-region ingress → out-of-region egress) and the per-client split route set as a
  current-posture deployment pattern; add **Selective Growth**, **in-region ingress**, and **anastomosis hop
  (node-to-node egress)** to [../GLOSSARY.md](../GLOSSARY.md); add the **destination-AS / download-direction
  throughput filter** and the **TLS-front metadata-leak** rows to [../THREAT-MODEL.md](../THREAT-MODEL.md);
  spawn the **Phase 3-5** automated egress-hop work **under** the
  [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) egress-capability contract.
- **What is now forbidden:** a **full-tunnel generated default** (carry-everything) as the shipped posture; a
  **user-direct out-of-region egress** path as the primary route; a **TLS-terminating third-party front** for
  user traffic, or treating **out-of-region CDN fronting** as a reliable primary out-of-region path; standing
  up an **automated** node-to-node egress hop **without** an explicit
  [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) egress-capability contract, or any **automated**
  cross-node bridging / route selection / egress-hop discovery **before its phase** (Phase 3-5); an egress
  hop that terminates on a **shared / open / default-on relay**
  ([ADR-0014](0014-per-operator-node-credentials.md)/[ADR-0016](0016-software-releases-not-an-operated-network.md)/[ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md)).

## Compliance

How the decision is verified in practice:

- **`split_tunnel_default` conformance gate** — asserts that no generated client config ships a **full-tunnel
  carry-everything** default as the doctrine posture; the xray-class engine configs express the split by
  domain-aware routing, and the WireGuard-class (AmneziaWG) client `AllowedIPs` default is a **region-exclude
  route set**, not `0.0.0.0/0, ::/0`. (Reproduces the `setup_amneziawg` render and inspects the emitted
  `AllowedIPs`.)
- **`no_user_direct_oor_egress` review checkpoint** — code/doc review rejects any generated config or
  documented deployment that makes the user connect **direct** to an **out-of-region** egress node as the
  primary path, or that documents an **out-of-region CDN front** as the reliable primary out-of-region path.
  Ingress must be in-region; out-of-region egress must be node-to-node.
- **`no_tls_terminating_user_front` review checkpoint** — rejects any path that routes user traffic through a
  **TLS-terminating third-party front** (which would expose source address + destination hostnames); any such
  metadata exposure is a `TELEMETRY_SAFETY_VIOLATION` (refactoring §7) and escalates if it links a user to a
  destination.
- **`no_default_egress_or_relay` / `OPEN_RELAY_OR_DEFAULT_EGRESS`**
  ([ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md); refactoring §7) — an **automated** node-to-node
  egress hop without an explicit egress-capability Anastomosis-Bridge contract, or an egress hop terminating
  on a shared/open/default-on relay, is an **S0** and blocks merge. Anonymous egress is not a default
  primitive.
- **`no_premature_mesh`** ([ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md)) — any **automated**
  cross-node bridging, route/path selection, or egress-hop discovery wired before Phase 3-5 fails the merge
  gate; the **manual** two-hop and per-client split route sets are the only current-posture form.
- **`check_ppn_wording`** — the reachability/topology vocabulary stays neutral PPN language: mechanism terms
  only (destination-AS / subnet throughput degradation, download-direction throttling of out-of-region egress
  ranges, in-region path, out-of-region node, impaired path, native path); **no country names**, **no loaded
  access framing** beyond the one allowed verbatim Canonical Rule.
- **Audit checkpoint** — a merge that changes the generated split-tunnel posture or the ingress/egress
  topology also updates the GLOSSARY (Selective Growth, in-region ingress, anastomosis hop) and the
  THREAT-MODEL (destination-AS throughput filter; TLS-front metadata leak); reviewers reject any softening of
  the hard NEVERs (full-tunnel default; user-direct out-of-region egress; TLS-terminating user front;
  automated egress hop without an ADR-0026 contract).

