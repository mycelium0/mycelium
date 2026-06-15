<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0029: `Community-federated ingress edges (the CDN layer)`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: the **ingress
> edge** that ADR-0027 places in-region (the "CDN layer" that fronts an out-of-region egress) is a
> **federated, community-contributed role** — not a central service and not a single maintainer-run edge —
> and its **resilience comes from diversity**: many independent contributors providing ingress edges, with
> their own domains, across varied providers and jurisdictions. The more varied the community-provided
> ingress set, the more reachable and harder-to-disrupt the network is, and the less any single party or
> place concentrates trust or reachability.

## Status

**Proposed.** Phase 2+ for the federated mechanism (discovery, contracts, distribution); Phase 0/1 keep only
inert schema/role hooks. The first concrete instance — an operator-contributed in-region ingress relaying to
an out-of-region egress (a node-to-node "two-hop") — is Phase-1 work.

## Context

ADR-0027 established the topology: in-region **ingress** + out-of-region **egress** carried node-to-node (an
anastomosis hop), because direct out-of-region reach is degraded by a destination-AS / subnet throughput
filter and out-of-region CDN fronting is not a reliable primary path. That leaves an open question — **who
provides the in-region ingress, and how many?**

A single ingress (one maintainer-run edge, or one commercial CDN) is the weak form: it is **one point to
disrupt**, and it concentrates reachability and trust in one place and one provider. Reachability is most
**resilient** when the ingress layer is **plural and diverse** — many independent edges, contributed by the
community, each well-placed and using its own domains. This is the mycobiome growth model (ADR-0023): the
network grows ingresses **organically** as members contribute them, and **diversity is the property that
makes the set durable** — provider diversity, domain diversity, jurisdictional diversity. No single edge,
provider, or place is load-bearing; losing any subset degrades gracefully rather than failing.

## Decision

1. **The ingress edge ("CDN layer") is a federated, community-contributed role.** It is not central and not
   maintainer-only. Many independent contributors each provide ingress edges and their own domains. Mycelium
   specifies the **role and its contract**, not a single provider.

2. **Diversity is a first-class resilience property.** Variety across providers, domains, and jurisdictions
   is the explicit goal — the broader and more varied the community-provided ingress set, the more resilient
   and reachable the network, and the less any one party concentrates trust or reachability.

3. **Ingress edges bind to the mesh via the bridge-contract + capability-class model (ADR-0026).** An ingress
   is a declared capability with an explicit contract; communes and users **choose which ingresses to
   trust**; no ingress is a default or a single point. There is **no central registry that is itself a point
   of disruption**, and **no global abuse oracle** (ADR-0025).

4. **Relay-preferred over termination.** An ingress edge SHOULD forward the encrypted tunnel — it learns only
   that a client reached *a* Mycelium edge, not the inner destination or content. A termination-style edge is
   a deliberate fallback with a documented metadata trade-off, chosen explicitly per ADR-0026, never a
   default. Ingress contributors are kept distinct from egress operators.

## Consequences

- **First instance is Phase-1:** an operator-contributed in-region ingress that relays to an out-of-region
  egress node-to-node (the "two-hop"). It is a single, concrete realization of the role; the federation
  around it is later.
- **Mechanism is Phase 2+:** ingress discovery, contract issuance, reputation, and fungi-served ingress
  distribution build on VIS-0007 (fungi-served subscription) + ADR-0026 (bridges). Phase 0/1 carry only inert
  schema hooks; no cross-contributor machinery ships before then.
- **Framing:** this is about **resilient, diverse, community-grown reachability** — many hands providing
  varied ingresses — not any one party, provider, or place.

## Relationship to other records

- **ADR-0027** (selective growth + in-region ingress topology) — this ADR answers *who provides the ingress*
  for that topology: the community, plurally.
- **ADR-0026** (anastomosis bridges + capability classes + contracts) — the binding mechanism for an ingress
  edge.
- **ADR-0023** (communes / mycobiome) — the organic, community-grown model this follows.
- **ADR-0025** (no global abuse oracle) — invariant: the federated ingress set has no central control point.
- **VIS-0007** (fungi-served subscription) — the Phase 2+ seam through which diverse ingresses are
  distributed.
