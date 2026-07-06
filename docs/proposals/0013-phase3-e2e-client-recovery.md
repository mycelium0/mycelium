<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0013: Phase-2 first-release milestone — end-to-end client recovery (measured at the client)

## Metadata
- **ID:** RP-0013
- **Slug:** `phase3-e2e-client-recovery`
- **Status:** **IN PROGRESS** (2026-07-03) — first workstream of the Phase-2 closing first-release milestone,
  opened right after the Phase-2 single-node-adaptivity GO-sign ([phase2-acceptance-ledger.md](../phase2-acceptance-ledger.md)). **C1 (contract + gates) LANDED:**
  the serve-time fallback invariant is codified (`Bundle.IndependentFallbackOK` / `DistinctClasses`) with
  the `e2e_recovery_fallback` gate + Go tests. **C2 (repeatable recovery harness) LANDED + validated:**
  `tests/e2e/` (reversible scoped block + Clash-API-driven client recovery probe); a live drill on a node
  measured a genuine cross-family failover (REALITY → GENUINE_TLS, `failover_confirmed`, recovered in ~40s
  at a 30s urltest interval). C3 (both-direction + on-device drill → Phase-2 first-release acceptance ledger) next.
- **Phase:** Phase 2 — closing first-release milestone (end-to-end client recovery + the reproducible signed release; the fungi/advisory boundary is built here as an inert seam that goes live in Phase 3)
- **Type:** single-workstream RP with three chunks (contract + gates / repeatable recovery harness / drill)
- **Related:** [RP-0012](0012-phase2-auto-rotation-actuation.md) AC-1 (this RP *is* that AC, promoted to a
  Phase-2 first-release-milestone DoD — the Phase-2 single-node self-drive proved the node-side rotation; this proves the **client** recovers); [RP-0010](0010-phase2-adaptivity.md)
  (the detector/measure plane the recovery leans on); [RP-0007](0007-phase1-distribution-health-xhttp.md)
  AC-a5/AC-b1 (the served subscription + the self-replenishing seam); [ADR-0025](../adr/0025-no-global-abuse-oracle.md)
  (advisory-never-actuates); the `sub_channel_not_single_point` + `transport_family_independence` gates
  (the ≥2-independent-siblings invariants this contract makes load-bearing); the Phase-1 on-device
  acceptance method ([phase1-acceptance-ledger.md](../phase1-acceptance-ledger.md) §"On-device acceptance test").

## Rationale

Phase 2 made a **node** heal itself: it detects its own channel degrading and rotates the transport it
serves, under rate limits + rollback. But a **stock client that has already connected to a now-blocked
endpoint does not benefit from the node rotating a *different* transport** — the client must itself notice
the dead path and fail over to a live sibling it already holds. The Phase-2 first-release-milestone e2e
recovery is therefore about the **client's** experience, measured **at the client**, not "node-side serving looks ok":

> A stock client on a standard subscription, holding a sibling endpoint, survives a real/artificial block
> of its active endpoint and is **carrying traffic again on a sibling within single-digit minutes, with no
> human action** — and this is **repeatable** (a scripted block → a measured recovery), not a one-off
> manual observation.

Three things must hold together for that: (1) the served subscription **always** offers ≥2 endpoints that
fail **independently** (so a live fallback always exists); (2) the client's **own** health-check + auto-
switch is exercisable against that subscription (stock-client behaviour — the server must not shape the
subscription so as to defeat it); (3) when the node rotates or an endpoint dies, the subscription at the
**stable URL refreshes** so the client's next auto-pull is current. Phase 1 already proved the raw
transports survive on the operator's real restrictive link; Phase 2 proved the node adapts; this RP proves
the *loop closes at the client*.

**This RP adds no cross-node coordination and no new actuation.** Recovery is client-native failover +
the node's own Phase-2 rotation + the existing self-replenishing subscription. A global/peer signal never
enters it (AC-4 stays intact); the transport set never grows (AC-5 stays intact).

## The e2e recovery contract (what the server must guarantee)

1. **Always a live fallback.** Every served subscription carries **≥2 endpoints that fail independently** —
   distinct transport *families* and/or distinct nodes — so no single block removes the client's last path.
   Made load-bearing by `sub_channel_not_single_point` + `transport_family_independence` (already green);
   this RP adds an e2e-shaped assertion that the *served* bundle (not just the template) satisfies it at
   serve time.
2. **Client failover is not defeated.** The subscription is shaped as a multi-endpoint profile the stock
   client can health-check and auto-switch across (no all-on-one-IP/one-SNI collapse that a single block
   would take out wholesale; siblings on independent reachability). The client's failover *policy* is a
   client-side setting (documented, not server-enforced), but the server must never emit a shape that makes
   failover impossible.
3. **Freshness after change.** When a node rotates its active transport (Phase 2) or an endpoint goes dark,
   the subscription at the **stable sub URL** refreshes so the client's next scheduled auto-pull receives a
   working set (RP-0007 AC-b1, the self-replenishing seam). Recovery must not *require* a manual re-import.

## Scope — three chunks (proposed)

1. **CONTRACT + GATES + SERVE-TIME ENFORCEMENT — LANDED.** The fallback invariant is codified on the
   **rendered** artifact: `spec.Bundle.IndependentFallbackOK` / `DistinctClasses` (`internal/spec/e2e_recovery.go`)
   assert a served bundle spans ≥2 **distinct transport families** (TransportClass), so a single-family
   block never removes the client's last path (AC-2). Family-level, not endpoint-level — REALITY
   Vision/gRPC/XHTTP are ONE family and fail together. **Now ENFORCED fail-closed at serve time** (not just
   offline-gated): `RenderBundle` and `RenderSubscription` refuse to emit a single-family artifact, so a
   node — which serves via `myceliumctl bundle`/`subscription` (the Go spine) — cannot publish an
   unrecoverable subscription. Consistent with AC-6 (≥2 independent families per node). Rotation-safe by
   construction: a RP-0012 rotation stays in the closed set and has no family-disable action, so it can
   never reduce the served family set.
   Pinned by the `e2e_recovery_fallback` conformance gate (registry ≥2 families · render stamps the family
   per endpoint · the invariant is codified + requires ≥2 · a single-family bundle is proven rejected) +
   Go tests (`TestBundleIndependentFallbackOK` / `…SingleFamily` / `…DistinctClassesDeterministic`).
   Nothing actuates.
2. **REPEATABLE RECOVERY HARNESS — LANDED (`tests/e2e/`).** A scripted, reversible, **surgical** block of a
   node's active endpoint (`block_endpoint.sh` — a `--source`-scoped `iptables` DROP, so a live population on
   the same port is unaffected; never a change to what the node *serves*) + a **client-side recovery probe**
   (`client_recovery_probe.sh`): a headless stock-equivalent client (a second sing-box using the node's own
   rendered subscription — the SAME `urltest` auto-failover a stock client uses; `gen_client_config.sh`
   wraps it + refuses a single-family sub, mirroring C1). It reads the live `urltest` selection via the
   Clash API, blocks exactly the **active** endpoint, and times the wall-clock until traffic flows again on
   the independent sibling — asserting the selection actually **changed families** (a real failover, not a
   lucky already-on-the-sibling pass). Emits a JSON verdict + `recovery_seconds`. Validated by a live drill:
   REALITY (Vision) → GENUINE_TLS (ws-tls), `failover_confirmed=true`, recovered in **42s** (30s urltest
   interval; the served 5m interval bounds real-world recovery), node left byte-identical. This is the
   "repeatable auto-test" the DoD names; the **on-device** manual measurement on the operator's real client
   (Phase-1 method) is the authoritative companion (C3). Not a CI gate — it moves real packets — so it is
   not registered in `tests/run.sh`; its serve-time precondition IS offline-gated (C1).
3. **THE DRILL.** Run the harness on a live node (block the active → measure client recovery → restore),
   plus one on-device confirmation on the operator's real client, and record the result in the Phase-2
   first-release acceptance ledger. Reversible; leaves the node byte-identical.

## Acceptance criteria (verifiable — the Phase-2 first-release e2e DoD)

- **AC-1 (recover-at-the-client, no human):** under a real/artificial block of its active endpoint, a stock
  client holding the served subscription is carrying traffic again on a sibling within **single-digit
  minutes**, with **no manual action** — measured **at the client**, not node-side.
- **AC-2 (always a live fallback):** every served subscription resolves to **≥2 independently-reachable**
  siblings; no single block removes the last path. Gate-enforced at serve time and across a rotation.
- **AC-3 (freshness after change):** after a node rotation or an endpoint going dark, the subscription at
  the stable URL refreshes so the client's next auto-pull is current — recovery never *requires* a manual
  re-import.
- **AC-4 (repeatable):** recovery is demonstrated by a **scripted block → measured recovery** harness that
  reproduces the result, plus one on-device confirmation — not a single hand-observed run.
- **Invariants preserved:** AC-4-advisory (no global/peer signal enters recovery) and AC-5-closed-set (no
  protocol growth) from RP-0010/0012 stay green throughout.

## The drill / measurement method

Mirrors the Phase-1 on-device acceptance test (authoritative, real link) + adds the repeatable harness:

- **Repeatable (harness):** a controlled test client subscribes to node **A**; the harness drops A's active
  endpoint (node-local firewall rule, reversible) and times the client until traffic resumes on a sibling
  (either A's rotated transport or a sibling node's endpoint). Records recovery-time; asserts ≤ the
  single-digit-minute bound.
- **On-device (authoritative):** the operator's real stock client, on the real restrictive link, holding the
  served subscription; the same block is induced; recovery is observed on-device (traffic resumes on a
  sibling with no re-import). This is the go/no-go signal, as in Phase 1.

Nodes are abstract (A/B/C/D); no IPs/hostnames/donor-mappings/locations appear in the ledger, per the
project OPSEC rule.

## Risks / notes

- **Client failover is partly outside the server.** The stock client's health-check + switch policy is a
  client-side setting; this RP guarantees the server never *defeats* it and documents the recommended
  client policy, but cannot force a particular client's behaviour. The on-device test is what proves the
  real client actually recovers.
- **Block realism.** A node-local firewall drop approximates a path block; it is not identical to an
  upstream/AS-level block. The on-device test on the real link is the realism backstop; the harness is for
  repeatability + regression.
- **No new actuation, no coordination.** Recovery is client-native failover + Phase-2 node rotation + the
  self-replenishing subscription. This RP introduces no global signal and no new mutate-a-node path.
- **Depends on:** the Phase-2 self-drive (accepted); the self-replenishing subscription (Phase 1); the
  ≥2-independent-siblings invariants (green). It does **not** depend on the advisory/fungi seam (a
  separate piece of Phase-2 inert groundwork that goes live in Phase 3).
