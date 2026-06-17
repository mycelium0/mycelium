<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR — Architecture Decision Records

Each ADR records **one** architecturally significant decision and its context. An ADR is the "why
this way" (decision); the "how we migrate the system" is described by an RP in [../proposals/](../proposals/).

- **Template:** [../templates/adr.md](../templates/adr.md)
- **When to write / policy:** [../development.md](../development.md), [../refactoring.md](../refactoring.md)
- **Numbering:** `NNNN-<slug>.md`, slug kebab-case, `NNNN` zero-padded and monotonically increasing (separate sequence from RP/Audit/Vision).
- **How to add:** copy the template → next free `NNNN` → fill in → Status `proposed`; commit with a type-prefix subject (`docs: …`) and an `Implements: ADR-NNNN` trailer — never the ADR id in the subject (see [../development.md](../development.md) §6.2).

## Current records
| ID | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Maintain ADRs | accepted |
| [0002](0002-no-custom-cryptography.md) | Do not reinvent cryptography | accepted |
| [0003](0003-licensing-and-jurisdiction.md) | Licence and jurisdiction | **accepted** |
| [0010](0010-phase0-transport-set.md) | Phase 0 modern transport set + engine selection | **accepted** |
| [0011](0011-carrier-agnostic-bridging.md) | Carrier-agnostic bridging and spore channels | proposed |
| [0012](0012-go-primary-control-plane-language.md) | Go as the primary control-plane language (Rust for sealed organs) | **accepted** |
| [0013](0013-mycelial-vocabulary-and-phase-discipline.md) | Mycelial vocabulary discipline + Phase 0-2 inert schemas | **accepted** |
| [0014](0014-per-operator-node-credentials.md) | Per-operator node credentials — no shared network key material | **accepted** |
| [0015](0015-network-artifact-delivery-and-node-update.md) | Network artifact-delivery and node-update model (signature-gated pull, fail-closed apply) | **accepted** |
| [0016](0016-software-releases-not-an-operated-network.md) | Software releases, not an operated network; community-consensus governance | **accepted** |
| [0017](0017-network-weather-data-contract.md) | Network-weather data contract + aggregation floor (definitions only; running publisher deferred) | **accepted** |
| [0018](0018-fungi-role-and-opt-in-publish.md) | Fungi role + the opt-in weather publish path (opt-in, aggregate-and-forget) | **accepted** |
| [0019](0019-node-local-reachability-health.md) | Node-local reachability + per-transport health measurement (Phase-0; classification/rotation/routing stay Phase 2) | **accepted** |
| [0020](0020-phase0-scope-reconciliations.md) | Phase-0 scope reconciliations (out-of-band delivery, donor-as-cover, manual REALITY rotation, Terraform deferred, D2 = independent families) | **accepted** |
| [0021](0021-decentralized-observability-not-a-central-collector.md) | Decentralized aggregate-and-forget observability, not a central collector (per-operator own-network monitor only; in-region edge reporting is the priority) | **accepted** |
| [0022](0022-two-port-reality-default.md) | Two-port REALITY default on the bootstrap path (Vision 443 + gRPC 8443, same family, for client failover; conservative Ansible default stays Vision-only; pinned by a posture gate) | **accepted** |

| [0023](0023-communes-mycobiome-genetics.md) | Mycelium is a Mycobiome of sovereign Communes with their own genetics (Commune = a first-class society entity, explicitly distinct from the architectural layer-planes; compatible by protocol, not by authority) | **accepted** |
| [0024](0024-immunity-temporary-cuts-and-signals.md) | Immunity — temporary scoped cuts (clotting) of node/route/transport/bridge/corridor/trust-scope/Commune (scoped, reversible, time-bounded, auditable-in-Commune, minimally-revealing, global-topology-independent, non-global) + immune signals that never carry raw traffic/identity/location/full-map and do carry scope/severity/reason-code/TTL/evidence-class/signer-or-quorum/reversible-action-hint; heal requires clot | proposed |
| [0025](0025-no-global-abuse-oracle.md) | No global abuse oracle — abuse resistance is not a global kill switch (fungi may sign warnings; Communes may subscribe or ignore; bridge contracts decide what binds; local decisions stay local) | **accepted** |
| [0026](0026-anastomosis-bridges-and-safe-defaults.md) | Anastomosis Bridges, traffic capability classes, and closed-by-default safe defaults (no bridge without an explicit contract; higher-risk classes need stronger trust; anonymous egress is not a default primitive) | proposed |
| [0027](0027-selective-growth-and-in-region-ingress.md) | Selective growth and in-region ingress topology (tunnel carries only impaired traffic — split-tunnel by default; ingress in-region; out-of-region egress is node-to-node, never user-direct, because out-of-region direct reach is degraded by a destination-AS/subnet download-throughput filter; out-of-region CDN fronting is not a reliable primary path and leaks destination metadata to a third party) | **accepted** |
| [0028](0028-dependency-and-transport-currency-policy.md) | Dependency and transport-currency policy (version currency is load-bearing for indistinguishability; declared version floors as migration targets — uTLS, Xray, sing-box, AmneziaWG; higher hardening targets recorded as prose, pin bumps a separate staged deploy; refresh cadence on engine-pin bumps + quarterly source sweep; engine-asymmetry record; the landscape reference as living annex; offline `dependency_policy` gate + a live post-handshake runbook probe) | **accepted** |
| [0029](0029-community-federated-ingress.md) | Community-federated ingress edges (the "CDN layer") — the in-region ingress that fronts an out-of-region egress is a federated, community-contributed role, not a central service; resilience comes from the diversity of community-provided edges/domains/jurisdictions; binds via the bridge-contract + capability model (ADR-0026); relay-preferred; no central registry-as-chokepoint and no global abuse oracle (ADR-0025); first instance is the Phase-1 two-hop, the federated mechanism is Phase 2+ | **accepted** |
| [0030](0030-advisory-network-awareness.md) | Advisory Network Awareness — the bridge between Phase-2 self-healing and Phase-3 coordination, as a cross-cutting Measurement & Immunity increment (federation, not coordination). Class-aggregate node-status digest (no transmitted node_ref / no per-node row — the per-node design reconstructs the network map, rejected); the stable own-node handle lives only in the operator-local at-rest cache; `cell-pack` = `aggregate --sign --ttl`; fungi-lite publisher = RP-0004 operator-local; advisory-never-actuates; activates the inert `internal/spec` weather/immunity schemas behind 10 proof gates | accepted |
| [0031](0031-build-vs-reuse-compose-proven-patterns.md) | Build-vs-reuse — Mycelium is an engineering composition of proven patterns, not novel network biology; compose/reuse proven prior art rather than reinvent. Per-component ADOPT/WRAP/BUILD/DEFER: ADOPT the Physarum control law (→ `spec.DecayPolicy`) + BPv7 spore field-set (control-plane only); WRAP `internal/reach`; BUILD the Phase-2 connectivity-state detector; DEFER libp2p (connectivity-only, private + behind own transports) / Yggdrasil-cjdns / Snowflake-architecture to Phase 3+. Federation = friend-to-friend (invite-only, Briar-style introduction, bounded horizon); amends ADR-0018/0029 with variable-weight anastomoses, new-link-can't-thicken, capture-containment | **accepted** |

> Reserved (produced by ADR-0003): 0004 no-logs/retention ·
> 0005 classification as encryption item · 0006 legal wrapper for egress · 0007 role/jurisdiction
> separation · 0008 applicable-sanctions screening · 0009 distribution channels.
