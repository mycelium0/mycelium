<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0011: Carrier-Agnostic Bridging and Spore Channels

## Metadata

- **ID:** ADR-0011
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** proposed
- **Layer(s):** cross-cutting; data plane, control plane, discovery, bootstrapping
- **Phase:** cross-cutting; interfaces begin in Phase 0, full behavior Phase 4+
- **Related:** `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `docs/THREAT-MODEL.md`,
  the internal research baseline (maintainers' knowledge base)

## Context

The project goal is not simply to maintain a fleet of reachable endpoints. The target is a living
private connectivity fabric that can remain useful under disruption, split, partial isolation, and
heterogeneous link availability.

If Mycelium assumes that all useful links are continuous, IP-based, high-bandwidth, and bidirectional,
then the architecture will fail exactly where it should be strongest: local islands, low-rate emergency
links, satellite links, Wi-Fi Direct, Bluetooth, LoRa-style radio meshes, physical hand-off, and future
carriers.

The biological analogy points to spores and hyphae as much as cords. A mycelium does not require every
connection to be a high-capacity cord. Weak exploratory links and small portable artifacts can be
survival-critical.

## Decision

Mycelium adopts a **carrier-agnostic bridge model**.

Any carrier that can move authenticated bytes can be a Mycelium bridge. Examples include:

- ordinary IP over TCP/UDP/QUIC/TLS;
- LTE/5G and fixed broadband;
- satellite links;
- Wi-Fi Direct, local Ethernet, and local Wi-Fi;
- WebRTC volunteer ingress;
- Bluetooth or Bluetooth Mesh;
- LoRa-style low-rate radio meshes;
- QR code, file, USB, NFC, memory card, and other physical hand-off;
- future radio or optical links.

A carrier adapter is not a new Mycelium protocol. It is a convergence-layer adapter with a capability
and risk descriptor. The carrier constrains the flow class; it must not define the whole system.

Mycelium also adopts **spore artifacts**: compact, signed, portable, replay-bounded objects that can be
carried across any bridge.

Spores may contain:

- bootstrap hints;
- route capsules;
- trust invitations;
- revocation notices;
- signed update manifests;
- stress summaries;
- cache manifests;
- delayed messages;
- emergency coordination messages.

Spores must be compact, signed, optionally encrypted to a scope or recipient, TTL-bounded, deduplicable,
safe to carry through untrusted bridges, and useful without revealing a full topology map.

## Options Considered

### 1. IP-only mesh

Use IP transports only and treat non-IP links as external hacks.

- **Pros:** simpler early implementation.
- **Cons:** fails under islanding, excludes local/low-rate carriers, makes first-contact and recovery
  too dependent on internet reachability.

### 2. Separate protocol per carrier

Build different bridge semantics for Bluetooth, LoRa, files, satellite, WebRTC, and so on.

- **Pros:** can optimize each carrier independently.
- **Cons:** fragments the architecture, creates inconsistent trust and replay semantics, makes safety
  review difficult.

### 3. Carrier-agnostic adapter + spore model (chosen)

Define one artifact and adapter contract, with carrier-specific capability/risk descriptors.

- **Pros:** supports any carrier without rewriting the protocol; matches DTN convergence-layer design;
  gives low-rate carriers a safe role; preserves decentralization; makes bridge safety review uniform.
- **Cons:** requires careful schema design and strict metadata minimization; not all carriers support
  all flow classes.

## Consequences

### Positive

- Separated network islands can reconnect through any available bridge.
- Low-bandwidth channels become useful for bootstrap, manifests, revocation, and delayed messages.
- The architecture avoids assuming permanent IP reachability.
- Carrier diversity raises the cost of selective network breakage.
- Bridge behavior becomes measurable and comparable across carriers.

### Negative / cost

- Spore schemas and replay protection must be designed carefully.
- Carrier adapters add implementation surface area.
- Low-rate channels can leak metadata if scopes and summaries are too rich.
- Malicious bridge custody, replay, drop, and delay become first-class attack cases.

## Required properties

Every carrier adapter must expose:

- maximum safe payload size;
- expected bandwidth;
- latency/delay distribution;
- intermittent or continuous availability;
- bidirectional or unidirectional behavior;
- broadcast/multicast/unicast behavior;
- custody model;
- deduplication support;
- encryption envelope support;
- replay/expiration support;
- detectability and collateral-risk class;
- operator/user risk;
- supported flow classes.

## Flow-class policy

Default degradation ladder:

`HD video -> low video -> audio -> interactive text/events -> delayed message -> signed manifest -> bootstrap spore`.

A carrier may only be used for a flow class it can safely support. Real-time flows require measured
quality. Low-rate/intermittent carriers participate through store/carry/forward and bootstrap semantics.

## Security implications

Threats to include in `docs/THREAT-MODEL.md`:

- bridge enumeration;
- malicious custody;
- replay of stale spores;
- route-capsule poisoning;
- metadata leakage from summaries;
- bridge flooding;
- carrier-specific coercion;
- false bridge-capability advertisement;
- local-island Eclipse attacks;
- over-trusting satellite or radio carriers as safe by default.

Mitigations:

- scoped signatures;
- TTL and replay protection;
- artifact deduplication;
- route-summary minimization;
- trust-scoped exchange;
- bridge diversity;
- local quarantine;
- stress memory and decay;
- no full topology exchange during island merge.

## Compliance

- New bridge code must implement `CarrierCapability` and `CarrierRisk` descriptors.
- New spore types must define signing, encryption scope, TTL, replay behavior, and maximum metadata.
- A bridge must not be promoted to a cord without measurements.
- A carrier adapter must document degraded mode and operator/user risk.
- Low-bandwidth bridges must be tested with worst-case duplication, delay, replay, and drop behavior.
