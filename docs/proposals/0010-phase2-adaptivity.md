<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0010: Phase-2 adaptivity — detect → adapt → self-tune over the closed transport set

## Metadata
- **ID:** RP-0010
- **Slug:** `phase2-adaptivity`
- **Status:** **DRAFT — proposed** (Phase-2 work; gated behind the signed Phase-1 GO, which is recorded in [phase1-acceptance-ledger.md](../phase1-acceptance-ledger.md))
- **Phase:** Phase 2 (Adaptation layer and self-tuning)
- **Type:** single-workstream RP with three planes (detect / adapt / measure)
- **Related:** [ROADMAP.md](../ROADMAP.md) Phase 2 + the "Phase 2 = adaptivity, not new protocols" scope discipline; [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md) (the ADOPT/WRAP/BUILD verdicts this RP executes); [ADR-0010](../adr/0010-phase0-transport-set.md) (closed transport set); [ADR-0019](../adr/0019-node-local-reachability-health.md) (node-local reachability health); [ADR-0030](../adr/0030-advisory-network-awareness.md) (class-aggregate advisory; advisory-never-actuates); [ADR-0027](../adr/0027-selective-growth-and-in-region-ingress.md) (the destination-AS throughput-collapse signature); [ADR-0012](../adr/0012-go-primary-control-plane-language.md) + [RP-0008](0008-go-spine-distribution-rendering.md) (Go spine); `internal/reach` (Monitor/Registry/Prober → `spec.TransportHealth`), `internal/spec.DecayPolicy`.

## Rationale

Mycelium is **software for resilient, secure connectivity**. What an operator previously did by hand over hours after a connectivity-loss event — migrating one transport shape to another, rotating parameters — the node should do **itself, in minutes**. That is Phase 2.

**Scope discipline (binding).** Phase 2 is **adaptivity, not new protocols.** The transport set is universal and **closed** ([ADR-0010](../adr/0010-phase0-transport-set.md)), and Phase 1's on-device acceptance proved the existing shapes suffice on a real restrictive link ([phase1-acceptance-ledger.md](../phase1-acceptance-ledger.md)). Phase 2 adapts the **route and behaviour** (detect → adapt → self-tune); it does **not** grow the protocol list. New/studied protocols are out of scope unless a specific gap is proven that the closed set cannot cover. Per [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md), Phase 2 **reuses bricks** (the Physarum control law + the already-built `internal/reach` monitor) and **builds** only the one thing no prior art provides.

## Scope — three node-local planes

### Plane 1 — MEASURE (WRAP, no new code)
Reuse the already-built `internal/reach` Monitor/Registry/Prober, which produces fast-class `spec.TransportHealth` (successes/failures over a window), strictly node-local per [ADR-0019](../adr/0019-node-local-reachability-health.md) — it never classifies state, rotates, actuates, or assembles topology. Phase 2 consumes this signal; it adds no new measurement surface.

### Plane 2 — DETECT (the one true BUILD)
A **connectivity-state detector** that classifies the channel into a small closed set — `clean / throttled / blocked / shutdown` — from signals that are **by-products of work the node already does**, so detection adds no new probing fingerprint:
- handshake timeout / connection reset on connect;
- **throughput collapse *after* a successful connect** — the destination-AS "data dies after a small initial transfer" signature ([ADR-0027](../adr/0027-selective-growth-and-in-region-ingress.md) / THREAT-MODEL); the discriminator is *where* bytes go, so transport-shaping cannot mask it;
- active-probe response failure (own-cert / cover path);
- single-stream behavioral degradation (the Phase-1 on-device finding: a single-stream TLS-over-TCP shape degrades while a multiplexed shape on the same node does not).

No prior-art primitive classifies these Mycelium-specific signatures, which is why this is a BUILD. Detector decisions MUST be **measurable** (precision/recall on a labelled-incident corpus) with anti-flapping / false-migration protection.

### Plane 3 — ADAPT (auto-rotation + self-tune; ADOPT the control law)
On a degradation event, the node rotates within the **closed** set — transport / port / SNI, regenerate REALITY parameters, switch address, fall back to a non-degraded shape — under **rate limits, hysteresis, and rollback** (reusing the Phase-0/1 candidate → validate (`sing-box check`) → promote → verify → rollback path).

The selection is driven by the **ADOPTed Physarum/Tero-2010 control law**, expressed directly on the existing `spec.DecayPolicy`: per `(transport-class, path)` keep a weight `W` that is **reinforced** on observed reachability/goodput and **decays continuously** (`HalfLife`) so a just-degraded shape *fades without explicit teardown* and *re-promotes automatically* when a block lifts; `Hysteresis` damps flapping; `RetentionFloor` is "scar memory" so a repeatedly-blocked shape is not eagerly retried. This is a few-line scoring update — **not** a routing/discovery protocol.

## Out of scope (deferred, named)
- **New or additional transport protocols** — the set is closed (above).
- **Fungi peering / federation / the anastomosis introduction** — Phase 3–4 ([ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md) federation section / ADR-0029); Phase 2 builds only the inert seams. The **advisory class-aggregate weather publish** ([ADR-0030](../adr/0030-advisory-network-awareness.md)) is the one federation-adjacent piece that rides Phase 2, emit-only, operator-local.
- **Anonymity** — Mycelium does not claim or guarantee it; out of scope by design.
- **Cross-node coordination / DHT / gossip** — Phase 3+ (ROADMAP scope discipline / MYC-F006).

## Acceptance criteria (verifiable)
- **AC-1 (recover-without-human):** artificially degrading the active transport on a node causes a stock client holding the bundle to recover within single-digit minutes **with no manual action**, via client-native failover + the node's rotation; the node records a class-level event.
- **AC-2 (detector measurable):** the connectivity-state detector reports precision/recall on a labelled-incident corpus; anti-flapping and false-migration guards are tested.
- **AC-3 (self-tuner = DecayPolicy):** the `(transport-class, path)` weight update is implemented on `spec.DecayPolicy` (reinforce / HalfLife decay / Hysteresis / RetentionFloor); a unit test shows a blocked shape fades and re-promotes on recovery without teardown.
- **AC-4 (advisory-never-actuates):** any event the node emits is the [ADR-0030](../adr/0030-advisory-network-awareness.md) class-aggregate shape (no per-node row, k-floored, TTL, signed) and feeds ranking input only — it can never auto-ban / force-route / hard-trust (`no_global_abuse_oracle` / ADR-0025 stays green).
- **AC-5 (no protocol growth):** the closed transport set is unchanged; `per_protocol_toggle` / `phase0_port_canon` / `transport_family_independence` stay green; the detector/rotator add no new inbound shape.
- **AC-6 (no new measurement surface):** detection is fed from `internal/reach` only; no new active-probing fingerprint is introduced (the WRAP, not a rebuild).

## Risks / notes
- Telemetry is itself a signal — events are class-aggregate, TTL-bound, advisory-only ([ADR-0030](../adr/0030-advisory-network-awareness.md)); the honest boundary (managed, not absolute; topology-graph axis, not anonymity) is recorded there.
- Rotation is observable — rate limits + hysteresis keep it from becoming its own beacon.
- ML, if added, **amplifies** the heuristics and must never replace them: the detector and self-tuner must work without it (ROADMAP Phase-2 note).
