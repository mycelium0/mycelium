<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0036: Node-local L7 own-cert / cover-path liveness probe (extends ADR-0019)

> Records **one** decision: the Phase-2 detector's active-probe-failure signal
> (`spec.DetectorSignal.ActiveProbeOK`) MAY be produced by a **node-local L7 liveness probe** that
> completes a real per-transport handshake against the node's own listener/cover host — **extending,
> and reconciling with,** the probe shape frozen in [ADR-0019](0019-node-local-reachability-health.md).
> It pins the boundary ("**no new EXTERNAL / third-party / client-vantage fingerprint**", not "zero
> external packets") and the hyphal-probe invariants. The implementation lives in
> [RP-0010](../proposals/0010-phase2-adaptivity.md) (measure plane); this ADR is the durable contract
> behind the boundary. Saved as `docs/adr/0036-node-local-l7-liveness-probe.md`.

---

## Metadata
- **ID:** ADR-0036
- **Date:** 2026-07-02
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** control plane (measure / detect); cross-cutting (measurement boundary & indistinguishability)
- **Phase:** Phase 2 — single-node adaptivity (the L7 signal feeds the detector; extends the Phase-0 ADR-0019 probe)
- **Related:** [ADR-0019](0019-node-local-reachability-health.md) (**extends** its frozen probe shape),
  [ADR-0002](0002-no-custom-cryptography.md) (no custom cryptography),
  [ADR-0022](0022-two-port-reality-default.md) (REALITY dest / two-port default),
  [ADR-0030](0030-advisory-network-awareness.md) (advisory-never-actuates),
  [VIS-0004](../vision/0004-living-network-doctrine.md) (hyphal-probe invariants),
  [RP-0010](../proposals/0010-phase2-adaptivity.md) AC-6 (the measure plane + the AC-6 clarification),
  [../THREAT-MODEL.md](../THREAT-MODEL.md).

## Context

[ADR-0019](0019-node-local-reachability-health.md) froze the node-local reachability probe as a **TCP
connect or TLS handshake** against a configured anchor, produced by `internal/reach`, strictly
node-local, with the invariant that nothing leaves the node beyond that bounded anchor egress. That
L4/TLS shape has a blind spot proven live (2026-07-01): a transport whose listener is **bound** and
completes ordinary TLS can be **client-DEAD at L7**. A broken REALITY `dest` still completes plain TLS
*and* the server's **unauthenticated fallback relay** — only the **authenticated steal** breaks — so
`internal/reach` reports the transport healthy and the self-drive loop never rotates off it. Closing
DoD-1 (the node autonomously rotating off a truly-dead transport) needs an **L7** signal the frozen
shape does not contemplate.

[RP-0010](../proposals/0010-phase2-adaptivity.md) AC-6 added a clarification sanctioning a node-local
L7-liveness probe, but a reinterpretation of a **frozen, accepted** ADR's probe-shape / off-node-emit
clause must be recorded in the ADR corpus, not in a downstream RP acceptance criterion (refactoring.md
§2.5; and the [ADR-0030](0030-advisory-network-awareness.md) precedent — the isomorphic advisory
refinement was promoted to a full ADR rather than left as RP prose). This ADR is that record.

## Decision

The Phase-2 detector's `ActiveProbeOK` signal MAY be produced by a **node-local L7 liveness probe** of
the node's **own** transports — distinct from the `internal/reach` monitor, run **out-of-daemon** on a
budgeted, jittered systemd timer — realized per transport family:

1. **Genuine-TLS families (ws-tls / xhttp-tls):** an `openssl` handshake to the node's **own** listener
   over `127.0.0.1:<port>` — **pure loopback, no external packet**. The check MUST assert the served
   cert is **valid, non-expired, AND matches the served SNI** (SAN / hostname), not merely non-expiry —
   so it actually guards the cert/SNI-agreement invariant ([ADR-0014](0014-per-operator-node-credentials.md)),
   never re-admitting a cert/SNI mismatch.
2. **REALITY families:** an **authenticated ephemeral REALITY handshake** against the node's **own
   `dest`/cover host** (`donor_verify_reality`) — the plain-TLS fallback path cannot see the broken-steal
   failure, so the authenticated steal is required. This **does** emit one external contact to the
   node's own `dest`: that is **the cover traffic REALITY already produces**, indistinguishable from
   normal REALITY operation, and MUST target **only** the node's own cover host — **never** a peer /
   member reference, a client-vantage endpoint, or a third-party service.

**Boundary** (reconciling ADR-0019 and RP-0010 AC-6). The prohibition is "**no new EXTERNAL /
third-party / client-vantage fingerprint**", **not** "zero external packets". Loopback for genuine-TLS;
own-`dest` cover contact for REALITY. **Forbidden:** any synthetic request egressed to a **third party**
on a cadence (e.g. fetching a fixed `/generate_204` through the tunnel per tick — the exact beacon
VIS-0004 warns against).

**Invariants** (VIS-0004 hyphal-probe). The probe MUST be **budgeted, jittered, bounded**, and MUST NOT
run every tick (it is the expensive hyphal probe, not the cheap reach probe); it MUST **debounce**
(mark a member dead only after it fails **every** in-run retry, so a transient cover-host blip cannot
manufacture a false-dead that the persisted marker replays across daemon ticks); it MUST be
**fail-safe** — the daemon reads the marker such that an absent / stale / malformed / unstamped marker
yields **no** L7 signal (healthy), so a probe outage never rotates a healthy transport. Detection stays
**advisory** ([ADR-0030](0030-advisory-network-awareness.md)) — `ActiveProbeOK` folds only into a
`rotate.PlanInput`; rotate remains the sole actuator. **No custom crypto** ([ADR-0002](0002-no-custom-cryptography.md)):
sing-box + openssl + `crypto/tls` only.

**Not the pulsatile loop.** This is a node-local ADR-0019 **sense**, not the VIS-0004 pulsatile
**exploration** loop toward other nodes/paths (that stays Phase-4+ typed-inert). It is single-node.

## Consequences

- **Positive:** the reach L4-only blind spot is closed for the covered families; the self-drive loop can
  autonomously rotate off a bound-but-client-dead transport (proven live on a node); no new crypto, no
  third-party beacon, no per-node row or location in the marker (OPSEC clean).
- **Extends, does not override, ADR-0019:** `internal/reach`'s TCP/TLS-only, own-listener posture is
  unchanged; this ADR authorizes a **second** node-local producer for the L7 signal and relaxes AC-6's
  literal "fed from `internal/reach` only" — the L7 marker is produced by the node-local probe and read
  by `cmd/myceliumd` (`loadL7Liveness`).
- **One producer per marker (contract):** exactly **one** producer may write the daemon-consumed marker,
  with **one** schema (stamped `observed_at`) and **one** key convention (measure ref = inbound tag minus
  `-in`). A deploy-time acceptance self-test MUST use the same own-cover/loopback contact profile (no
  third-party beacon), never a divergent schema on the same path.
- **Honest coverage:** the probe covers the families it enrolls; today only the REALITY (vision/grpc) and
  ws-tls tags are probed — other enrolled transports (HY2/TUIC/shadowtls/trojan/xhttp) carry an **L4-only**
  verdict and MUST NOT be claimed L7-covered. Extending per-family L7 coverage is a follow-on.
- **REALITY liveness is inseparable from `dest` viability:** a flaky `dest` can produce a fresh-but-wrong
  DEAD marker; contained by the in-run debounce + the detector hysteresis + the rotate `MinInterval`
  ([ADR-0030](0030-advisory-network-awareness.md)), not eliminated.
- **Marker replay vs. anti-flap (known limitation — Audit-0007 S2):** the daemon re-reads the marker every
  tick until it ages past `L7_MAX_AGE_MS`, so a single DEAD probe *generation* faults the detector on every
  tick inside that window rather than once — one (already in-run-debounced) probe run can satisfy the
  tick-based anti-flap on its own. The blast radius is bounded (the `MinInterval`/`MaxPerWindow` limits cap
  it at one rotation then a cooldown), but requiring the marker to name a ref DEAD across ≥N *distinct*
  `observed_at` generations before it faults — so a rotation reflects sustained, not replayed, evidence — is
  a planned hardening. It is deferred because it shifts the drilled detect→rotate latency and so needs a
  self-drive re-drill to confirm the loop still rotates within the DoD-1 budget.
- **VIS-0004 phase table** is amended to record this L7 liveness loop as the sanctioned early realization
  of the Plane-2 own-cert/cover-path signal, armed only under `--measure-enable` (ships-disabled).

## What is now forbidden

- Egressing a synthetic request to a **third party** on any cadence (a beacon).
- Targeting a **peer / member reference** or a client-vantage endpoint — this is a node-local self-probe,
  never a discovery or client-simulation surface.
- Writing the daemon-consumed marker from **more than one** producer, or with a divergent schema/key.
- Claiming a transport family is L7-covered when the probe does not exercise it.

## Compliance

- **Fail-safe read (gate/test):** the daemon's marker read (`cmd/myceliumd.loadL7Liveness`) yields nil
  (healthy) for absent/stale/malformed/unstamped/empty-dead; only a **fresh** marker naming dead refs
  faults — a probe outage never rotates a healthy transport (covered by `TestLoadL7Liveness`).
- **No third-party beacon:** the cadenced probe + the deploy-time acceptance test contact only
  `127.0.0.1` (genuine-TLS) or the node's own `dest`/cover host (REALITY); a fixed third-party fetch on a
  cadence is a review-blocking finding.
- **Ships-disabled:** the L7 probe timer is written + enabled only by `--measure-enable`, removed by
  `--measure-disable`; nothing arms it at plain `--node-apply` (`measure_daemon_ships_disabled`).
- **Advisory-only:** `ActiveProbeOK` folds into a `rotate.PlanInput` behind the RP-0012 gate; it never
  auto-actuates ([ADR-0030](0030-advisory-network-awareness.md) advisory-never-actuates stays green).
- **No custom crypto** ([ADR-0002](0002-no-custom-cryptography.md)); **OPSEC** — the marker carries only
  opaque transport refs (no IP / SNI / host / port / ASN / geo / location), node-local under gitignored
  `$STATE_DIR`, never on the digest/emit path.
- **Cert/SNI match:** the genuine-TLS probe asserts SAN/hostname match, not merely non-expiry.
