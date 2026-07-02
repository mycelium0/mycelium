<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0019: `Node-local reachability and per-transport health measurement (Phase 0)`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: that
> `myceliumd` gains a **node-local** reachability/health measurement loop which periodically probes
> operator-configured anchors, records the result as the inert fast-class `spec.TransportHealth`
> shape (opaque refs only), and exposes a **redacted** snapshot on loopback — and that this is the
> Phase-0 measurement substrate the Phase-2 **network-state detector** (state classification +
> auto-rotation) and the Measurement cross-cutting track (the network-weather explorer) later consume.
> It deliberately does **not** classify channel state, rotate transports, actuate routing, or emit
> anything off the node.

---

## Metadata
- **ID:** ADR-0019
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (probe shape **extended by [ADR-0036](0036-node-local-l7-liveness-probe.md)** — a node-local L7 own-cert/cover-path liveness probe added alongside this TCP/TLS shape, 2026-07-02)
- **Layer(s):** control plane (the `myceliumd` spine, [ADR-0012](0012-go-primary-control-plane-language.md)); cross-cutting **Measurement** track
- **Phase:** Phase 0 (basic observability — see [../ROADMAP.md](../ROADMAP.md) Phase-0 scope/DoD; the
  classifying detector + auto-rotation are Phase 2, the off-node aggregated surface is the Measurement track)
- **Related:** [RP-0002](../proposals/0002-phase0-live-verified-hardened-node.md) (W4 PII-safe observability, W7 Go spine);
  [ADR-0012](0012-go-primary-control-plane-language.md) (Go control plane);
  [ADR-0013](0013-mycelial-vocabulary-and-phase-discipline.md) (Phase 0-2 inert schemas — this populates one);
  [ADR-0010](0010-phase0-transport-set.md) (the transports being measured);
  [ADR-0018](0018-fungi-role-and-opt-in-publish.md) (the opt-in publish path a future digest would ride);
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (telemetry is itself a signal; the network map is the prize);
  `internal/spec/network.go` (`TransportHealth`, `SignalSpeedFast`).

## Context
A Phase-0 node already speaks several transport shapes ([ADR-0010](0010-phase0-transport-set.md)), but
it has **no node-local sense of its own reachability**. The live nodes proved the gap concretely: one
node could not reach a destination class at all while another could — a per-node, per-channel
reachability fact the node itself was blind to, discoverable only by an operator probing by hand. The
Phase-0 Definition of Done already calls for *"basic observability: node liveness, per-transport
handshake success rate, utilisation"*; today that is satisfied only by external Prometheus blackbox
probing, not by anything the node knows about itself.

- **Adversary model.** IP/AS blocking and UDP throttling/cutting that make a specific transport or a
  specific egress destination unreachable from a specific node ([../THREAT-MODEL.md](../THREAT-MODEL.md));
  and — critically — the **telemetry-as-attack-surface** risk: any health signal a node keeps or emits
  must not become a node map or a user trail.
- **Affected asset.** Ingress/egress reachability (what we want to measure) **vs.** the network map and
  user identity/location (what we must not leak while measuring).
- **Fundamental trade-off.** Adaptation speed ↔ false-migration risk: a node cannot adapt to a block it
  cannot see, but a measurement layer that is too rich, too eager, or too talkative leaks topology and
  invites flapping. Phase 0 buys *visibility only*; acting on it is deferred so the measurement can be
  validated before it ever moves traffic.

This ADR decides the **measurement substrate**. It does not decide classification, rotation, or routing
— those are Phase 2 ([../ROADMAP.md](../ROADMAP.md) Phase 2: the network-state detector and auto-rotation
loop) and must build *on top of* this, not be smuggled into Phase 0 ([../ROADMAP.md](../ROADMAP.md)
"Scope discipline").

## Considered Options

1. **Leave observability to external Prometheus blackbox only (option 0).**
   - Pros: nothing to build; already present.
   - Cons: the node has no self-knowledge to ever feed a detector; external probing measures the
     monitoring host's reachability, not the node's egress; nothing produces the `TransportHealth`
     contract the later phases require.
   - Impact on survivability: the node stays blind to its own channel health — no foundation for adaptation.

2. **Node-local Go measurement loop producing `spec.TransportHealth`, exposed redacted on loopback (chosen).**
   - Pros: the node gains self-knowledge in the exact inert fast-class shape Phase 2+ consumes; stays on
     the node, loopback-only, opaque-ref-only; off unless an operator supplies a config; a clean,
     documented seam for the Phase-2 classifier/rotation and the network-weather digest.
   - Cons: a new running loop in the spine (concurrency to get right; a small egress probe budget);
     probe targets are operator-supplied state, not canon.
   - Impact on indistinguishability/survivability: probes are ordinary client-shaped dials to
     operator-chosen anchors; nothing new is exposed on the wire; the node can finally see which of its
     channels is alive.

3. **Build the Phase-2 classifying network-state detector now (state = clean/throttled/blocked/shutdown, plus auto-rotation).**
   - Pros: closes the operator's pain end-to-end (detect *and* route around).
   - Cons: a **phase violation** ([../ROADMAP.md](../ROADMAP.md) Phase 2 + Scope discipline) — channel-state
     classification needs labelled incidents and anti-flap design, auto-rotation needs rate-limits and
     rollback, and routing actuation is the adaptation layer; doing it now ships unvalidated migration logic.
   - Impact on survivability: high false-migration risk; acting on an unproven signal can *cause* outages.

## Decision
**Option 2.** `myceliumd` gains a node-local **reachability monitor** (`internal/reach`, consumed by the
daemon) that, **only when the operator supplies a reachability config**, periodically probes each
configured anchor (TCP connect or TLS handshake, with a timeout) on its own interval, records each
outcome into a per-anchor sliding window, and projects the window onto the inert fast-class
[`spec.TransportHealth`](../../internal/spec/network.go) shape (`SignalSpeedFast`). A redacted snapshot is
served on the daemon's existing **loopback** HTTP surface at `/reachability`.

Specifically, what becomes **canon**:
- **The produced contract is `spec.TransportHealth`** — opaque `transport_ref`, success/failure counters,
  window bounds. The monitor is a *producer* of that already-frozen schema; it adds no new wire type and
  no new crypto (TLS probing uses `crypto/tls` against the standard library only — [ADR-0002](0002-no-custom-cryptography.md)).
- **Opaque refs only.** A node's exposed/persisted reachability output carries the operator's **label**
  for an anchor (e.g. `anchor-a`), never an address, hostname, SNI, port, destination, peer identity, or
  location. The mapping label→address lives only in the operator's local config file, never in the
  snapshot and never in the repository.
- **Off by default, loopback by default.** No reachability config ⇒ the monitor does not run and the
  daemon behaves exactly as the current skeleton. The endpoint binds loopback like `/healthz`.
- **Operator-supplied targets, not canon.** Probe anchors are local operator state. The repository ships
  **only** an example config using allowlisted public-DNS anchors (`1.1.1.1`, `8.8.8.8`); real anchors
  are never committed.
- **Fail-closed.** When an operator supplies a reachability config that does not validate, the daemon
  **fails fast** (non-zero exit) rather than run a half-configured or silently-disabled monitor, so the
  error is visible to the operator (and to the supervising unit). With **no** config supplied the monitor
  simply does not exist and the daemon serves `/healthz`/`/version` as before. A probe error is *recorded
  as a failure*, never a crash; the snapshot exposes only redacted aggregates.

## Consequences
- **Positive:** the node finally knows its own per-channel reachability in the canonical fast-class shape;
  a documented, inert-schema-aligned foundation exists for the Phase-2 detector and the network-weather
  digest; zero new wire surface, zero new dependency (stdlib only).
- **Negative / cost:** a new concurrent loop in the spine (must pass `make race`); a small, bounded egress
  probe budget; one more operator-supplied config file to manage.
- **Impact on user security (requirement №1):** the node learns nothing about *users* — it probes
  operator-chosen infrastructure anchors, not user traffic; no connection is logged, no user identity or
  destination is recorded; the snapshot is opaque-ref aggregates only; nothing leaves the node.
- **Impact on observability/measurements:** adds the first node-produced signal — per-anchor/per-transport
  `TransportHealth`. It is **fast-class, routing-bound only** (concept 7); it is *not* a `StressSignal`
  (that is the medium-class, aggregation-floored, shareable summary — out of scope here).
- **Follow-on actions required:** Phase 2 — channel-state classification (`clean/throttled/blocked/shutdown`)
  and the auto-rotation loop consume this; the Measurement track — a future opt-in digest
  ([ADR-0018](0018-fungi-role-and-opt-in-publish.md)) may aggregate it under a floor. Each is its own ADR/RP.
- **What is now forbidden:** in Phase 0 this component must **not** classify channel state, rotate or
  switch any transport, actuate any routing/split-tunnel decision, assemble `EdgeState`/topology, emit or
  announce anything off the node (no `DiscoveryBackend`, no gossip, no telemetry upload), or record any
  address/SNI/destination/identity/location in its output.

## Compliance
How to verify the decision is respected:
- the reachability snapshot and the shipped example config carry **no** IP literal (beyond the allowlisted
  public-DNS anchors), hostname, SNI, port-as-endpoint, destination, identity, or location — the leak
  **invariant** enforced by the offline conformance suite (the concrete checks live in
  `tests/conformance/` + [../development.md](../development.md), not named here);
- the example config validates under the existing config-validation gate; real anchors are never committed;
- the monitor is concurrency-clean under `make race` ([ADR-0012](0012-go-primary-control-plane-language.md) Compliance);
- the daemon binds the reachability endpoint to loopback and the monitor is inert unless a config is supplied;
- code review confirms no channel-state classification, transport rotation, routing actuation, or off-node
  emission is present (the Phase-2/3-4 anti-pattern this ADR closes off).
