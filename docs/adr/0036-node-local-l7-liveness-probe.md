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
3. **Standalone Shadowsocks-2022 (amended 2026-07-27):** a **data round trip through the node's own SS
   listener to a target that speaks first**, judged on **bytes returned**, with a **control dial** of the
   same target over a plain `direct` outbound deciding the ambiguous no-bytes case. SS-2022 completes no
   observable handshake, so the criteria in (1) and (2) — and the hold-until-timeout criterion the QUIC /
   ShadowTLS probes use — read **ALIVE against a listener whose key no longer matches**. Only bytes that
   came *back* through the tunnel prove a server decrypted the request. Two constraints are load-bearing
   and are pinned by gate (`ss_l7_probe_failsafe`):
   - **The target is the node's own PUBLIC address, not `127.0.0.1`.** The served config blocks private
     destinations (`route.rules: ip_is_private -> block`) — a deliberate control that MUST NOT be
     weakened for a self-test. The address MUST be one **this host already holds** (taken from its own
     interface list, never from the operator-settable `params.node_address`, which may be a hostname
     pointing at a front or another host), so the kernel routes the dial through `lo`: **still no packet
     on the wire**, and no dependence on the provider hairpinning its own public address. A **private**
     target would be blocked in the tunnel but *not* in the probe's own route-rule-free config, so the
     control dial would succeed where the tunnel failed — **manufacturing a false DEAD**.
   - **DEAD requires positive evidence.** Silence inside the tunnel is ambiguous (dead listener vs. no
     sshd vs. a firewalled hairpin), so a DEAD verdict is reachable **only** after the control dial
     proves the target itself answers. Everything else — no public own-address, no banner-first target,
     no tooling, a secret-less inbound — is **cannot-judge**, never dead.

**Boundary** (reconciling ADR-0019 and RP-0010 AC-6). The prohibition is "**no new EXTERNAL /
third-party / client-vantage fingerprint**", **not** "zero external packets". Loopback for genuine-TLS;
own-`dest` cover contact for REALITY; an **own-address, host-local** round trip for Shadowsocks — the
target is this node's own service, reached at an address the node itself holds, so nothing is contacted
off-host and no third party is involved. **Forbidden:** any synthetic request egressed to a **third
party** on a cadence (e.g. fetching a fixed `/generate_204` through the tunnel per tick — the exact
beacon VIS-0004 warns against), and — for the Shadowsocks round trip specifically — any target that is
**not an address of this host**.

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
- **Honest coverage:** the probe covers the families it enrolls, and the claim is asserted in the code,
  never assumed. *Originally* only the REALITY (vision/grpc) and ws-tls tags were probed, with
  HY2/TUIC/shadowtls/trojan/xhttp carrying an **L4-only** verdict. RP-0014 chunk A closed HY2/TUIC and
  ShadowTLS; the 2026-07-27 amendment closes **standalone Shadowsocks** (3, above) and enrols **trojan**,
  whose own-cert genuine-TLS shape the existing loopback SAN check already covered but which had never
  been added to the enrolled set — a silent L4-only verdict on a served family. The **one** remaining
  residual is the **inner** layer of the Xray-served `vless-xhttp-tls`: a sing-box client cannot dial
  xhttp, so its sibling probe (`measure_l7_probe_xhttp`) checks the outer own-cert TLS only. Nothing else
  may be claimed L7-covered without a probe that exercises it.
- **A per-family criterion is not a per-family implementation detail.** Shadowsocks proved that a probe
  can be *structurally* correct — right engine, right config, right port — and still be **hollow**: the
  first build of it reported ALIVE against a listener whose key had been changed, because it inherited
  the TLS families' hold-until-timeout criterion. A family whose failure mode is *silence* cannot be
  judged by a criterion whose ALIVE signal is also silence. Any future family added here MUST state the
  observable that distinguishes its healthy case from its dead one, and a probe that cannot name one is a
  documented residual, not a probe.
- **REALITY liveness is inseparable from `dest` viability:** a flaky `dest` can produce a fresh-but-wrong
  DEAD marker; contained by the in-run debounce + the detector hysteresis + the rotate `MinInterval`
  ([ADR-0030](0030-advisory-network-awareness.md)), not eliminated.
- **Marker replay vs. anti-flap — hardened (Audit-0007 S2):** the daemon re-reads the marker every tick
  until it ages past `L7_MAX_AGE_MS`, so a single DEAD probe *generation* would fault the detector on every
  tick inside that window — one (already in-run-debounced) probe run satisfying the tick-based anti-flap on
  its own. The daemon now gates the fault through `l7GenerationGate`: a member must read DEAD across **≥N
  distinct `observed_at` generations** (default `l7_min_dead_generations = 2`) before it faults, so a
  rotation reflects sustained, not replayed, evidence; a fresh-clean generation or an absent/stale marker
  resets that ref's streak (fail-safe), and an explicit `1` restores the pre-gate behaviour. This shifts the
  detect→rotate latency (a rotation now needs ≥2 probe generations of deadness on top of the detector
  hysteresis). **Field-confirmed on a live node (2026-07-03):** on the gated daemon at the live tick, one
  dead generation replayed across ticks held the active verdict **clean**, and a second **distinct**
  generation flipped it to **blocked / active-probe-failure** (stable) — the gate faults at exactly N=2
  distinct generations and replay is harmless. (The re-drill drove the generations directly to exercise the
  gate; the end-to-end wall-clock at the default L7 cadence follows arithmetically — ≈2 probe intervals for
  the two generations, then the detector hysteresis, then the rotation.)
- **Zero-sample reach window vs. the L7 fold:** the L7 signal is applied *inside* a member's detector
  `Observe`, which the assembler runs only for a member that has fresh reach samples this tick (a
  zero-sample window carries no information and is skipped — "no data" must never read as a black-hole).
  So a member with a fresh DEAD L7 marker but **no reach samples that tick** is not L7-faulted until its
  next non-empty reach window. In practice the reach probe (own-listener TCP, ~tens of seconds) is far
  more frequent than the L7 probe (minutes), so a live listener always has reach samples when its L7
  marker matters; a member with *neither* reach samples nor a fresh L7 marker simply evaporates on its
  tuner decay, as intended. Documented so the coupling is explicit, not accidental.
- **VIS-0004 phase table** is amended to record this L7 liveness loop as the sanctioned early realization
  of the Plane-2 own-cert/cover-path signal, armed only under `--measure-enable` (ships-disabled).

## What is now forbidden

- Egressing a synthetic request to a **third party** on any cadence (a beacon).
- Targeting a **peer / member reference** or a client-vantage endpoint — this is a node-local self-probe,
  never a discovery or client-simulation surface.
- For the Shadowsocks round trip: targeting an address this host does **not** hold, targeting a
  **private** address, or returning **DEAD** without a control dial that proves the target answers.
- **Weakening a served-config control to make a self-test work** — in particular relaxing the
  `ip_is_private -> block` route rule so a probe can use a loopback target. The probe adapts to the
  control, never the reverse.
- Writing the daemon-consumed marker from **more than one** producer, or with a divergent schema/key.
- Claiming a transport family is L7-covered when the probe does not exercise it.

## Compliance

- **Fail-safe read (gate/test):** the daemon's marker read (`cmd/myceliumd.loadL7Liveness`) yields nil
  (healthy) for absent/stale/malformed/unstamped/empty-dead; only a **fresh** marker naming dead refs
  faults — a probe outage never rotates a healthy transport (covered by `TestLoadL7Liveness`).
- **No third-party beacon:** the cadenced probe + the deploy-time acceptance test contact only
  `127.0.0.1` (genuine-TLS, QUIC, ShadowTLS), the node's own `dest`/cover host (REALITY), or an address
  the node itself holds (Shadowsocks); a fixed third-party fetch on a cadence is a review-blocking
  finding.
- **Shadowsocks fail-safe (gate):** `ss_l7_probe_failsafe` pins, on the shell directly, that the DEAD
  verdict is control-gated, that private/ULA/CGNAT candidates are rejected, that the verdict is the size
  of the captured round-trip output rather than an exit status, that a payload is sent before reading
  (SS-2022 flushes its request header only with the first payload — an empty-stdin dial reads DEAD on a
  healthy listener), that the target comes from the host's own interface list, and that the ShadowTLS
  inbound's hidden loopback inner SS is never enrolled as a served family.
- **Operator-visible footprint (Shadowsocks):** the round trip leaves one benign line per probe run in
  the node's **own** sshd log, from the node's own address. If a node runs `fail2ban`/`sshguard` in an
  aggressive mode that bans on it, the ban lands on the node's own address and the probe degrades to
  **cannot-judge** (the control dial stops answering too) — fail-safe, not a false dead.
- **Ships-disabled:** the L7 probe timer is written + enabled only by `--measure-enable`, removed by
  `--measure-disable`; nothing arms it at plain `--node-apply` (`measure_daemon_ships_disabled`).
- **Advisory-only:** `ActiveProbeOK` folds into a `rotate.PlanInput` behind the RP-0012 gate; it never
  auto-actuates ([ADR-0030](0030-advisory-network-awareness.md) advisory-never-actuates stays green).
- **No custom crypto** ([ADR-0002](0002-no-custom-cryptography.md)); **OPSEC** — the marker carries only
  opaque transport refs (no IP / SNI / host / port / ASN / geo / location), node-local under gitignored
  `$STATE_DIR`, never on the digest/emit path.
- **Cert/SNI match:** the genuine-TLS probe asserts SAN/hostname match, not merely non-expiry.
