<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Phase-1 GO/NO-GO acceptance ledger

The single artifact that authorizes the **Phase-1 → Phase-2 transition**. Per
[ROADMAP.md](ROADMAP.md) ("Phase-transition principle"), **Phase 2 does not begin until Phase-1's
Definition of Done is met in production with real users** — not when the code merely exists. This
ledger maps the Phase-1 RP ([proposals/0007-phase1-distribution-health-xhttp.md](proposals/0007-phase1-distribution-health-xhttp.md))
acceptance criteria to status, evidence, and owner. It is the authoritative phase status that RP-0007
points to (the proposal deliberately does not snapshot the verdict, to avoid desync).

> **Current verdict: GO — Phase-1 → Phase-2 transition AUTHORIZED 2026-06-17** (operator sign-off recorded
> below). The distinctive Phase-1 deliverables were proven on the operator's real restrictive link on **both
> LTE and Wi-Fi**: genuine single-layer TLS reached the open internet (full traffic), the two-hop
> in-region-ingress → out-of-region-egress path carried full traffic, and multiplexed REALITY (gRPC)
> reached the internet, all imported unmodified into the operator's stock client off the served
> subscription. 28 offline conformance gates green; the Go spine builds/tests/`-race` green. The observed
> transport weaknesses (single-stream REALITY degraded on the restrictive link; one node detected on a
> too-recognizable SNI donor; the CDN-fronted path throttled) are **known and explained** by the
> transport-technique landscape ([reference/transport-technique-landscape.md](reference/transport-technique-landscape.md)),
> not architectural failures — they are hardening inputs carried into Phase 2, recorded below.
> (Node identifiers are abstracted as node-A/B/C/D; no IPs/hostnames/donor-mappings/locations appear here,
> per the project OPSEC rule.)

## On-device acceptance test (2026-06-17)

A flat subscription of **every endpoint the population serves, each as a separate manually-selected
server, with NO auto-switching** (deliberately, to test each shape in isolation), plus the two-hop, was
imported into the operator's stock client and each entry exercised on **both LTE and Wi-Fi** against real
traffic (general web, a video platform, a messenger, app traffic). Results by transport shape:

| Transport shape | LTE | Wi-Fi | Reading |
|---|---|---|---|
| **Genuine single-layer TLS** (VLESS+WebSocket over the node's own cert, direct) | full traffic, fast | full traffic, fast | **the core Phase-1 deliverable — proven** |
| **Two-hop** (in-region ingress → out-of-region egress) | full traffic | full traffic | **the in-region-ingress topology — proven on-device** |
| **Multiplexed REALITY** (gRPC over HTTP/2) | full traffic | full traffic | multiplexed survives, as the landscape annex predicts |
| **Single-stream REALITY** (Vision over TCP) | degraded / blocked | degraded / slow | behavioral-layer detection of the single-stream flow (annex); de-prioritized in hostile regions |
| Same family on a node with a **too-recognizable SNI donor** | blocked | blocked | SNI/ASN-mismatch tell (annex); node healthy + donor reachable from it, yet detected → **corrected to a ubiquitous donor** |
| **CDN-fronted** genuine TLS | throttled | partial (messenger only) | destination-AS / CDN download-throttle (annex); the direct genuine-TLS path is the working alternative |

The pattern is a clean, point-by-point match to the documented transport landscape: multiplexed +
genuine single-TLS + the node-to-node two-hop survive the restrictive link; single-stream TLS-in-TLS and
the CDN-fronted path do not. Degradation-not-failure held throughout — a reachable shape always existed.

## Acceptance scorecard (RP-0007 workstreams)

| AC | Criterion | Status | Evidence |
|---|---|---|---|
| **AC-a1** | Genuine-TLS shape reaches the open internet where REALITY is blocked, on the live restrictive link | **PASS** | On-device 2026-06-17: the genuine single-layer-TLS shape (WebSocket over the node's own publicly-valid cert — the sing-box-servable substitute AC-a1 explicitly permits "if it independently passes this LTE test") carried full traffic on LTE **and** Wi-Fi. |
| **AC-a2/a3/a4/a7/a8** | Own-cert canon, probe-safety fail-closed, port/SNI canon, no-custom-crypto, deployed-template correctness | **PASS** | Offline gates green at HEAD: `active_probe_owncert`, `engine_load_check`, `phase0_port_canon`, `no_custom_crypto`/`no_legacy_transport`/`no_insecure_tls`, `live_artifact_posture`. |
| **AC-a5** | Operator's stock client imports the bundle entry unmodified and establishes a working tunnel | **PASS (via the genuine-TLS WebSocket shape)** | The served subscription imported unmodified into the operator's stock client; the genuine-TLS entry established and carried traffic. The **Xray-XHTTP-specific** wire-format path is **deferred** (sing-box cannot serve `xhttp`; WS+TLS was chosen as the immediate servable genuine-TLS shape) — see Deferrals. |
| **AC-a6** | ≥2 independent transport families remain reachable per node | **PASS** | `transport_family_independence.sh` green; on-device, REALITY-TCP, AmneziaWG-UDP, and genuine-TLS (WS) are independently reachable; the genuine-TLS family is the on-device LTE survivor. |
| **AC-b1** | Server-side change reflected at the stable sub URL; stock client picks it up with no manual re-import | **PASS** | The self-replenishing subscription seam was demonstrated earlier (auto-pull propagation) and rode this test's served URL; the URL string is stable. |
| **AC-b3/b4** | Fail-closed serve (no malformed/weaker bundle); sub channel is not a single point | **PASS** | `bundle_go_roundtrip` (shell render → Go `spec.Bundle.Validate`), `sub_channel_not_single_point` green; the served bundle spans ≥2 independent families. |
| **AC-d** | Bundle schema + client-side merge (local-only, no central endpoint) | **PASS** | `internal/spec.Bundle` + `bundle_region_closed_vocab`, `vocab_single_source` (Go-owned transport vocabulary) green; aggregate is local-only. |
| **AC-c** | Health + failover | **inert by design (Phase-1 scope)** | Bundle-health-keyed selection is forward-compat only — health stays `unknown` (ADR-0025); Phase-1 acceptance is client-native failover, which the multi-endpoint subscription provides. The measurement track that populates health is Phase 2. |

## Deferrals (named, not blockers)

- **Xray-XHTTP serving path** — sing-box cannot serve the `xhttp` transport (engine asymmetry, ADR-0010
  amendment). The genuine-TLS LTE objective was met via the sing-box-servable **WS+TLS** shape (AC-a1's
  permitted substitute, on-device proven), so the Xray-XHTTP path is a follow-up RP, not a Phase-1 blocker.
- **Observability dashboard / alerting** — node-side producers are live loopback-only (ADR-0021); the
  dashboard + per-transport handshake-success alerting remain the per-operator-monitor / Phase-2 work.
- **Hysteria2 + Salamander (and the broader QUIC obfuscation set)** — declared, default-off, not part of
  the Phase-1 on-device DoD.

## Hardening follow-ups surfaced by the on-device test (carried into Phase 2)

These are the *wrong-defaults / next-generation* items the test made concrete; each is consistent with the
transport-technique landscape annex:

1. **De-prioritize single-stream REALITY (Vision/TCP) in hostile regions** — it loses at the behavioral
   layer; lead with multiplexed (gRPC) and genuine-TLS shapes.
2. **SNI-donor hygiene** — a too-recognizable donor (ASN-mismatch tell) is detectable even when the node is
   healthy; one node was corrected on 2026-06-17. A donor-choice guard belongs in the hardening pass.
3. **Client failover must not create handshake bursts to one SNI** — the behavioral parallel-handshake
   signal can be self-triggered; stagger probes and spread across distinct SNIs.
4. **Center of gravity is the adaptation loop** — the filter adapts on a timescale of days; the
   detect-block → auto-adapt loop (Phase-2 measurement track) is where the real fight is.

## Sign-off

- **Operator GO:** recorded 2026-06-17 — Phase-1 deliverables proven on-device on the live restrictive
  link (LTE + Wi-Fi); Phase-1 → Phase-2 transition **AUTHORIZED**. The pre-Phase-2 research is the
  next gate before the Phase-2 detector/measurement track opens.
- **Engineering plane:** 28 offline conformance gates green; Go spine builds/tests/`-race` green; the
  control-plane vocabulary is Go-owned (RP-0008 P2) and the Go spine binary is render-time-resident on
  nodes (RP-0008 P3 chunk 1, inert).
