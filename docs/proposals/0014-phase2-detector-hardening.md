<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0014: Phase-2 detector hardening — full L7 liveness coverage, a path-level served-flow interference signal, and proactive transport selection

## Metadata
- **ID:** RP-0014
- **Slug:** `phase2-detector-hardening`
- **Status:** **DRAFT** (2026-07-13). Three chunks (A/B/C), each independently landable behind its own gate; A first (most tractable, highest immediate value), then B (the residual path-level gap), then C (the proactive-selection layer).
- **Phase:** Phase 2 — single-node adaptivity. This RP sharpens the **DETECT plane** (RP-0010 Plane 2); it adds no new transport and no federation runtime. It is the detector-quality foundation the fingerprint-adaptivity increment (RP-0015) depends on for its trigger.
- **Type:** multi-chunk RP; producer-wiring + coverage extension only — **no schema or classifier change** (the shapes and the classifier already exist and already consume every signal below).
- **Related:** [RP-0010](0010-phase2-adaptivity.md) (the detector/measure plane this hardens — `spec.DetectorSignal`, `internal/detect`, `internal/measure`, AC-6 "no new probing surface"); [ADR-0036](../adr/0036-node-local-l7-liveness-probe.md) (the node-local L7 self-probe this extends; its honest-coverage follow-on is chunk A, its **client-vantage boundary** governs chunk B); [ADR-0030](../adr/0030-advisory-network-awareness.md) + [ADR-0025](../adr/0025-no-global-abuse-oracle.md) (the advisory projection + advisory-never-actuates rule chunk C rides); [RP-0012](0012-phase2-auto-rotation-actuation.md) (the rotation plane that consumes the sharpened verdicts); [RP-0013](0013-phase3-e2e-client-recovery.md) (the client-recovery contract these signals protect); the maintainers' internal research digest on resilient-connectivity prior art (the current on-path interference behaviour that motivates the path-level signal; the auto-learned interference-signal taxonomy and the cheap-first liveness-selection algorithm that inform chunks B/C — **concepts only**, MIT-licensed prior art).

## Rationale

The DETECT plane is where the leverage is: rotation quality can never exceed detection quality. Today the detector's **typed schema is complete and its classifier already consumes every signal** — but two of the signal slots have **no producer**, and the one active-probe signal covers only three of the served transport families. So the node is partly blind in exactly the ways the 2026 frontier exploits.

Grounded in the code:

- **`spec.DetectorSignal`** ([internal/spec/detector.go:167-177](../../internal/spec/detector.go)) carries `ConnectOK`, `HandshakeOK`, `ConnectReset`, `PostConnectCollapse`, `ActiveProbeOK`, `SingleStreamDegraded`.
- **`detect.Classify`** ([internal/detect/detect.go:82-108](../../internal/detect/detect.go)) already maps all of them: `!ConnectOK`→shutdown; `!HandshakeOK && ConnectReset`→**blocked/connection-reset**; `!HandshakeOK`→blocked/handshake-timeout; `!ActiveProbeOK`→blocked/active-probe-failure; `PostConnectCollapse`→throttled; `SingleStreamDegraded`→throttled. Hysteresis + anti-flap are already in `Detector.Observe`.
- **The gaps are all on the PRODUCER side:**
  1. **L7 coverage is partial.** `measure_l7_probe` L7-probes exactly three inbound tags — `vless-reality-vision-in`, `vless-reality-grpc-in`, `vless-ws-tls-in` ([control/lib/nb_selftest.sh:47-51](../../control/lib/nb_selftest.sh)); HY2/TUIC/ShadowTLS/Trojan/xhttp keep an **L4-only** verdict (`ActiveProbeOK` is not meaningfully set for them — a bound-but-client-dead shape on those families is invisible). ADR-0036 records this as an explicit follow-on.
  2. **`ConnectReset` and `PostConnectCollapse` are never produced.** Both are *consumed* by `Classify`, but nothing in `internal/reach`/`internal/measure`/`cmd/myceliumd` ever sets them — they are constant `false` in production. The node's only detection input is a **node-local active self-probe** (reach against its own `127.0.0.1` listener; ADR-0036 L7 against its own listener/dest). A self-probe **cannot see interference on the path between the node and its real clients** — the on-path element sits there. This is the "connects, TLS completes, then Application-Data is silently dropped after ~30 s" symptom some on-path elements now produce (they reconstruct the flow before inspecting it): a loopback probe reports the transport **healthy** while real clients are being cut. `nb_measure.sh` itself documents this as out of scope — "a later edge-reporting plane."
  3. **No proactive full-set selection.** The measure plane assesses transports, but rotation is reactive (it moves off the *active* transport when it degrades). The node does not proactively answer "of my whole enrolled set, which shapes are alive from here right now, cheapest-first?" — the proactive-liveness question — so it cannot pre-select the best fallback or feed a fungi a per-family working-set for advisory weather.

RP-0014 fixes all three **without touching the schema or the classifier** — it wires the missing producers and extends the probe's family coverage, inside the existing OPSEC boundary.

## Non-negotiable invariants (all three chunks)

- **AC-6 — no new probing fingerprint.** Every added signal must come from a **by-product of work the node already does** (conntrack it already runs; the own-listener L7 handshake ADR-0036 already sanctions), never a new third-party or client-vantage probe. The `detector_pure_no_probe` gate stays green.
- **Node-local, never transmitted.** `ConnState`/`DetectReason` and every raw signal are node-local. Only the lossy `ConnState.AdvisoryHealth()` projection (alive/degraded/unknown) may ever leave the node, k-floored, TTL-bounded, class-aggregate, inside a `NodeStatusDigest` (ADR-0030). The `detector_state_closed_vocab` gate stays green. **Advisory never actuates trust** (ADR-0025).
- **ADR-0036 boundary preserved:** "no new EXTERNAL / third-party / **client-vantage** fingerprint." Chunk B observes the node's **own served traffic passively** — it is not a client-simulation surface and it does not target a peer or a client endpoint.
- **Inert-before-behaviour / gates-first.** Each chunk lands its conformance gate + Go/shell tests before it can change a verdict, per the codebase discipline.

## Chunk A — full L7 liveness coverage (extend `ActiveProbeOK` to every served family)

**What.** Extend `measure_l7_probe` so every enrolled, client-facing transport family gets a **family-appropriate node-local L7 handshake check** against the node's **own** listener, folded into `ActiveProbeOK` — retiring the L4-only verdict for HY2/TUIC/ShadowTLS/Trojan/xhttp.

**How (per family, own-listener only).**
- **Hysteria2 / TUIC (`quic-udp`):** a loopback QUIC/H3 (HY2) or QUIC (TUIC) handshake against the own UDP listener with the node's own credentials — success = the tunnel establishes at L7, not merely that the UDP socket is bound.
- **ShadowTLS (`shadowtls-tcp`):** the own-cover TLS handshake plus the inner ShadowTLS auth against the node's own listener.
- **Trojan (`trojan-tls`):** an own-cert TLS handshake + the Trojan password preface against the own listener (same own-cert SAN-match discipline as ws-tls).
- **xhttp (reality-xhttp / xhttp-tls):** the own XHTTP-over-(REALITY|genuine-TLS) L7 open against the own listener.
- Each reuses the ADR-0036 shape: budgeted, jittered, **debounced**, fail-safe (absent/stale/malformed marker → healthy, so a probe fault never fabricates a block), one producer per marker, gated on `MEASURE_L7_MIN_DEAD_GEN` distinct dead generations (the Audit-0007 S2 anti-replay).

**Boundary.** All checks are **loopback / own-dest** — no new client-vantage or third-party fingerprint (AC-6, ADR-0036).

**DoD.**
- `measure_l7_probe` L7-covers every enrolled client-facing family; the honest-coverage comment + the jq tag selector list the full set (no family silently defaulted-healthy).
- A bound-but-client-dead shape on each newly-covered family is detected on a live node (the ADR-0036 drill, per family).
- The `l7probe` coverage assertion in the conformance suite is extended to the full family set; `bash tests/run.sh` green.

## Chunk B — path-level served-flow interference signal (wire `ConnectReset` + `PostConnectCollapse`)

**What.** Give the detector its first **path-level** input: a passive, node-local observer of the node's **own served connections** that sets `ConnectReset` (served connections meeting RSTs at/near handshake) and `PostConnectCollapse` (served flows whose throughput collapses after a successful connect), per transport class. This closes the residual half of the L7 gap — the interference a loopback self-probe cannot see.

**How (by-product, not a new probe) — mechanism RESOLVED by a live-node design pass (2026-07-15). Grounding: the live node runs `nf_conntrack` but WITHOUT the `conntrack` tool, WITHOUT byte-accounting (`nf_conntrack_acct=0`), and with `/proc/net/nf_conntrack` unreadable — so the conntrack BYTE-based observation the draft assumed is unavailable; nftables IS the firewall and already carries `counter` rules. Decision: source the signal from a passive nft counter, split by feasibility.**
- **`ConnectReset` — a passive per-class nft counter (lands first).** One `counter` rule per served-listener-port group (mapped to its transport class) matching the **inbound TCP RST** the node receives on its OWN served sockets (the RST an on-path element injects toward the node's served endpoint). A pure by-product: no drop / no action, no payload, per-class. The node-local observer reads each counter as a rolling **delta** over a budgeted + jittered window and sets `ConnectReset` for a class whose RST rate exceeds a per-class threshold *relative to that class's new-connection rate* (a few benign resets never fault). Needs no conntrack tool, no acct, no sysctl change — only a counter rule installed alongside the firewall with the measure plane (removed with it).
- **`PostConnectCollapse` — deferred to a follow-on increment** (needs per-flow byte visibility the RST counter does not give). Options on record: (a) enable `nf_conntrack_acct` + install `conntrack` (a sysctl + package prerequisite) and sample per-flow bytes for the bytes-then-silence shape; (b) a coarser per-class nft byte / new-connection ratio (connections that establish but carry few bytes ~= collapse). Both are heavier than the RST counter; `ConnectReset` is the higher-value primary path-level input and lands first.
- **Wiring (mirrors `ActiveProbeOK`, no classifier change).** The observer writes a node-local marker (per-class `ConnectReset`/`PostConnectCollapse`). The measure daemon folds the two flags into `DetectorSignal` exactly as it folds the L7 marker into `ActiveProbeOK`: `internal/measure.detectorSignal()` gains the two flags, `Tick` threads a per-ref map (as it threads the L7 `activeProbe` map), and a generation-gate + a fail-safe (absent/stale/degraded -> the flag defaults **false**, never fabricating a block) mirror the L7-marker path in `cmd/myceliumd/measure.go`. `Classify` already maps the flags to `blocked/connection-reset` and `throttled/throughput-collapse`.
- **Superseded draft note.** The original bullets below (generic "conntrack, which the node already runs" + the byte-rate taxonomy) predate the grounding; the taxonomy (incoming-RST-at/near-handshake, retransmission-over-threshold, success = flow past a byte/seq threshold — concepts only, MIT-licensed prior art, applied to the node's OWN served flows as a class-aggregate rate) still holds, but the SOURCE is the nft counter above, not conntrack byte sampling.
- Source the signal from **conntrack, which the node already runs** for the data plane (`nf_conntrack` + the conntrack-liberal settings already in `common/nft.sh`). A lightweight node-local watcher samples the node's own served-connection outcomes by transport class (mapped from the served listener port → class): the **rate of connections that reset within the first N bytes / before handshake completion**, and the **rate of early-terminated / stalled flows** (bytes-then-silence). No packet capture, no payload, no per-peer identity is retained — only per-class counters over a window (the `TransportHealth` shape the detector already takes).
- The failure-signal taxonomy is lifted from resilient-connectivity prior art (MIT-licensed; see the internal research digest): incoming-RST-in-first-N-bytes, request-retransmission-over-threshold, success = flow progressed past a byte/seq threshold. We take the **taxonomy**, applied to the node's **own** served flows (not client-side, not per-host).
- Feed the per-class rates into the existing `DetectorSignal.ConnectReset` / `PostConnectCollapse` producers; `Classify` already maps them to `blocked/connection-reset` and `throttled/throughput-collapse` (no classifier change).

**Boundary (load-bearing).** Passive observation of the node's **own served traffic** only — never a client-vantage probe, never per-peer, never transmitted. Only the lossy per-class `AdvisoryHealth` projection is externalisable (ADR-0030/0025). This is the ADR-0036 boundary read correctly: watching your own served connections is a by-product, not a new fingerprint (AC-6).

**Mechanism question — RESOLVED (2026-07-15, see How above): a passive nft inbound-RST counter for `ConnectReset` (the nodes lack the conntrack tool + acct, and nft is already the firewall, so a counter is the cheapest by-product that needs no sysctl/package prerequisite); `PostConnectCollapse` keeps the conntrack-acct option open as its follow-on.** The originally-considered options were: conntrack-event stream (`conntrack -E`) vs periodic conntrack-table sampling vs a small eBPF/tc counter — pick the cheapest that yields per-class RST/stall rates without payload access and without pegging a core (the WinDivert/BSD lack-of-connbytes caveat does not apply — this is the Linux node).

**DoD.**
- **Increment 1 (`ConnectReset`):** set from the passive per-class nft inbound-RST counter on a live node; a scripted served-side block that RSTs real client flows (distinct from the ADR-0036 loopback drill) flips the verdict to `blocked/connection-reset` where the loopback probe alone reported healthy. **Increment 2 (`PostConnectCollapse`, follow-on):** set from per-flow byte visibility (conntrack-acct or the nft byte/new-connection ratio); a scripted post-connect throughput collapse flips the verdict to `throttled/throughput-collapse`.
- A new gate proves the observer is passive + node-local + payload-free + class-aggregate (no per-peer, no identity, no transmission of the raw signal); `detector_pure_no_probe` + `detector_state_closed_vocab` stay green.
- Fail-safe: absent/degraded conntrack visibility → the signal defaults false (never fabricates a block).

## Chunk C — proactive full-set transport selection

**What.** Turn reactive rotation into **proactive selection**: on the measure schedule, assess the L7 liveness of the node's **whole enrolled set** (not just the active transport) — cheapest-first — so the node holds a per-family "which of my shapes are alive from here" verdict, the rotation planner can pre-pick the best-alive fallback, and a **fungi** can aggregate the per-family verdicts into the class-aggregate advisory weather it already emits (ADR-0030) to serve the best transport by region.

**How.**
- Reuse chunk-A's per-family L7 probe over the **full enrolled set**, ordered cheapest→most-expensive (a cheap-first + greedy-pruning idea from prior art: once a cheap family is confirmed alive, skip its redundant supersets) — but **node-local against own listeners** (never client-simulating).
- The success signal borrows a content-validation discipline from prior art (reject a redirect injected on the path / a response that leaked to the real origin as "not really working"), applied to the own-listener L7 result.
- Output: a per-`(class,path)` verdict set feeding (a) the RP-0012 rotation candidate ranking (promote the best-alive, remember it — the "remember the winner" concept from prior art), and (b) the fungi's `NodeStatusDigest` per-class weather (advisory, k-floored, never per-node).

**Boundary.** Node-local + **advisory** — it informs selection, it does not itself actuate a rotation (that stays gated by RP-0012's rate/hysteresis/rollback), and it does not stand up any central collector (ADR-0021). "Smarter fungi" = better advisory weather from richer node-local verdicts, never a coordinator that decides for a node.

**DoD.**
- The measure plane produces a per-family alive/degraded verdict for the full enrolled set on a schedule; the rotation planner consumes it to rank candidates (the best-alive is preferred, a dead family is excluded — extends the existing "exclude L7-dead candidates from the rotation pool" behaviour to the whole set).
- A fungi's advisory weather reflects the per-family working-set (class-aggregate, k-floored); the advisory gates (`node_status_digest_emit_safe`) stay green.
- Deterministic + bounded: the full-set probe respects the same budget/jitter/debounce as chunk A and cannot itself become a detectable scan.

## Definition of Done (RP-level)

- All three chunks land with their gates + tests; `bash tests/run.sh` green; for the Go touch points, `make build vet fmt-check test race` green.
- On a live node: (A) every served family is L7-covered; (B) a served-side block that a loopback probe misses now flips the verdict; (C) the node holds a full-set working-set and the rotation ranks by it.
- Every OPSEC invariant above holds by construction (gates enforce: no new probe surface, no transmission of the fine state, advisory-only, node-local).
- The Phase-2 acceptance ledger records the detector-hardening close; RP-0015 (fingerprint-adaptivity) can then consume chunk B's path-level signal as its "my fingerprint is filtered" trigger.

## Out of scope (named)
- **Fingerprint rotation** — that is RP-0015 (it *depends* on this RP's chunk-B trigger).
- **Donor-validation upgrade** (A-record cross-check + ServerHello-mirroring) — a sibling deploy-time increment; tracked separately.
- **Any client-side or on-path packet-tampering** — Mycelium serves genuine transports; on-path packet-tampering techniques from prior art are reference only (we lift the detection/selection **concepts**, not the packet-tampering).
- **Cross-node correlation-dilution policy** — a rotation-policy increment, not a detector one.
