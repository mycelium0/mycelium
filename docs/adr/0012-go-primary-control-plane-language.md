<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0012: Go as the primary implementation language for the control plane

> Records the decision to write Mycelium's executable control-plane components in **Go**,
> retaining shell+jq only for deploy glue and CI gates, and reserving **Rust** for sealed
> high-assurance components introduced later behind a shared specification.

---

## Metadata
- **ID:** ADR-0012
- **Date:** 2026-06-12
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** control plane (primary); cross-cutting track (tooling, observability)
- **Phase:** cross-cutting — the Go spine begins in the Phase 0 continuation (see [RP-0002](../proposals/0002-phase0-live-verified-hardened-node.md)) and carries through Phases 1–3
- **Related:** [ADR-0002](0002-no-custom-cryptography.md) (no custom cryptography), [ADR-0010](0010-phase0-transport-set.md) (transport set + engine selection), [ADR-0011](0011-carrier-agnostic-bridging.md) (carrier/spore channels), [RP-0002](../proposals/0002-phase0-live-verified-hardened-node.md), [../development.md](../development.md) §1, [../contributing.md](../contributing.md) §4.1

## Context

The Phase 0 scaffold implements `control/myceliumctl`, the offline conformance gates, and deploy
glue in **shell + jq**. That is appropriate for run-once, stateless, auditable work: rendering a
config from a template, generating key material by invoking the *sanctioned* generators
([ADR-0002](0002-no-custom-cryptography.md)), and grepping the tree in CI.

It is **not** adequate for the persistent control plane (Layer 2), which is the load-bearing
construction the rest of the roadmap rests on. That component must:

- run a **network-state detector** (thresholds, precision/recall) — real data structures and math;
- run an **auto-rotation** loop with limits, anti-flap, and rollback — a long-running state machine;
- emit **telemetry** that is aggregated, noised, and not linked to identity — typed, versioned schemas;
- expose **idempotent** control with retries, timers, and concurrent probing;
- later carry **libp2p** discovery and **spore** signing/verification;
- ship as a single, memory-safe, deployable binary that operators run under pressure.

Shell has no real state, types, concurrency, or testability for this, and its portability is
fragile (BSD vs GNU differences were already hit during Phase 0). The canon already required a
compiled binary ("control agents — Go or Rust", [../development.md](../development.md) /
[../contributing.md](../contributing.md) §4.1) but left the language unpinned. This ADR pins it.

- **Adversary model.** The control plane must be **as survivable as the data plane** — management
  must not be easier to block than traffic ([../THREAT-MODEL.md](../THREAT-MODEL.md)). The
  implementation language affects our ability to ship a robust single binary that drives sing-box,
  runs a correct fail-closed adaptation loop under behavioral-layer detection / active probing / IP-AS blocking / UDP
  throttling, and is operated reliably by non-experts.
- **Affected asset.** Ingress reachability and operators (operational simplicity → fewer failures →
  better availability); indirectly user safety, via correct idempotent, anti-flap behaviour.
- **Fundamental trade-off.** Adaptation speed ↔ false-migration risk (the loop must be correct and
  testable); operational simplicity ↔ maximal compile-time rigour.

## Considered Options

0. **Keep the control plane in shell + jq.**
   - Pros: no build step; fully transparent.
   - Cons: no real state/types/concurrency; fragile quoting and BSD/GNU portability; the detector
     and rotation loop are untestable; no libp2p or spore story. Unacceptable for the hard
     construction.
   - Impact on survivability: a fragile, hard-to-test control loop is itself an availability risk.

1. **Rust as the primary language.**
   - Pros: memory safety without GC; strong type system; mature `rust-libp2p`.
   - Cons: Rust's decisive advantage is in data-path and crypto-critical code that Mycelium
     **deliberately does not own** — the data plane is sing-box and [ADR-0002](0002-no-custom-cryptography.md)
     forbids custom cryptography. Against the project's actual dominant risk (complexity drift, not
     use-after-free) Rust adds compile-time/async/lifetime cost and a higher contributor barrier
     without reducing that risk. Integration friction with the Go-based upstreams.
   - Impact on survivability: neutral-to-negative near-term (slower iteration on stabilisation).

2. **Go as the primary language. (chosen)**
   - Pros: the entire upstream stack is Go — sing-box (primary engine), Xray (optional),
     `amneziawg-go` (userspace path), `go-libp2p` (reference libp2p), Caddy — so the control agent
     can embed/drive them and ship one static binary; goroutines/channels fit probing, measurement,
     timers, debounced rotation, and supervisor logic; memory-safe; low contributor barrier; "boring
     deployment".
   - Cons: garbage collector (immaterial — we orchestrate engines, we do not write a line-rate data
     plane); weaker compile-time guarantees than Rust (offset by architectural discipline, below).
   - Impact on survivability: positive — fewer operational failures, a testable adaptation loop.

## Decision

**Go is the primary implementation language for Mycelium's executable components**, because the
upstream ecosystem is Go, the control plane is an orchestration/measurement problem (not a data-path
or crypto problem), and operational simplicity directly serves survivability.

Specifically, the following become **canon**:

- **Go owns orchestration.** Components written in Go:
  - `cmd/myceliumd` — the long-running control agent: health probes, engine supervisor, transport
    state + stress memory, rotation planner (limits/anti-flap/rollback), Prometheus exporter,
    subscription/config-bundle generation, and (later) the coordinator/gossip client.
  - `cmd/myceliumctl` — the operator CLI (replacing the shell tool incrementally): render
    server/client configs, validate, identity add/revoke/list, inspect node.
  - `internal/engine` (sing-box / xray / amneziawg adapters), `internal/state` (node/identity/
    transport state machines), `internal/policy` (route scoring, decay, quarantine, fail-closed),
    `internal/observability` (metrics, alert-signal normalisation), `internal/spec` (typed schemas).
- **Upstream engines own the data plane.** Go drives sing-box/Xray/AmneziaWG; it does not replace
  them.
- **Shell + jq is retained ONLY** for: Ansible deploy glue, one-shot config rendering at bootstrap,
  key generation via the sanctioned generators, and the offline CI conformance gates.
- **Guiding principle:** *shell renders and deploys; the Go binary decides and adapts.* Anything
  stateful, long-running, contract-bearing, or safety-sensitive is Go; anything you run once and
  read is shell.

**Spec-driven boundary for a future second language.** Schemas and test vectors are defined first
(e.g. `spec/spore-envelope.md`, `spec/transport-health.md`, `spec/node-state-machine.md`;
`test-vectors/spores/*.json`, `test-vectors/route-scoring/*.json`) so a sealed component can be added
in another language later without splitting the project. Discovery is an **interface**
(`DiscoveryBackend`: `Announce` / `Find` / `ReportStress`) whose backend can move from local-file →
coordinator/bundle → Go libp2p → a Rust daemon behind gRPC/Unix socket — so the language choice does
not block any phase.

**Go discipline (canon, to offset the weaker type system):** explicit state machines;
`context.Context` throughout; bounded worker pools (no unbounded goroutine creation); the race
detector in CI; property tests for route/transport state; immutable snapshots for policy decisions;
strict, versioned telemetry and envelope schemas.

**Rust exception (allowed, secondary, only when justified):** sealed, high-assurance organs —
a spore-envelope validator; a carrier-capability parser for hostile-input schemas (LoRa, Bluetooth,
file/QR/USB hand-off); a route-state model checker / simulator; any parser exposed to hostile bytes
at scale; and possibly a future standalone hardened mesh node (Phase 4/5). Such a component starts
**only after** its spec and test vectors exist — never as the entry point.

## Consequences

- **Positive:** a single static binary tightly integrated with the Go upstreams; a testable control
  loop; a low contributor barrier; operational simplicity (survivability through fewer failures);
  a clear path to `go-libp2p` for Phase 4 without a rewrite.
- **Negative / cost:** GC (immaterial for orchestration; to be measured by profiling, not assumed);
  weaker compile-time guarantees than Rust (mitigated by the discipline above); introducing Rust
  later adds a second toolchain — gated behind a published spec + test vectors.
- **Impact on user security (requirement №1):** none of the invariants relax — the agent preserves
  no-PII / aggregated-noised telemetry and fail-closed behaviour regardless of language; idempotent,
  anti-flap rotation reduces false migrations that could expose a user.
- **Impact on observability/measurements:** enables a proper typed Prometheus exporter and typed
  detector/rotation signals, replacing shell scraping.
- **Follow-on actions required:** [RP-0002](../proposals/0002-phase0-live-verified-hardened-node.md)
  stands up the Go control-agent skeleton **after** the shell+Ansible live-node bring-up ("spine
  early, glue stays shell"); the shell `myceliumctl` is superseded incrementally; the package layout
  above is adopted.
- **What is now forbidden:** accreting stateful control logic (detector / rotation / policy) into
  shell; writing the data plane, a transport, an obfuscation primitive, or cryptography in Go
  ([ADR-0002](0002-no-custom-cryptography.md), [ADR-0010](0010-phase0-transport-set.md)); starting a
  Rust component without a published spec and test vectors.

## Compliance

How to verify the decision is respected in practice:

- a conformance check that **stateful control logic lives in the Go module, not shell** (flag
  detector/rotation/policy keywords appearing in shell scripts outside deploy glue);
- the existing gates still apply: `no_custom_crypto`, `no_pii` (when introduced),
  `no_hardcoded_secrets_endpoints`, `no_contact_leak`;
- CI builds the Go binary with the **race detector** (`go build -race` / `go test -race ./...`) and
  runs unit + contract + property tests; a red race detector blocks merge;
- before any Rust organ is added, CI verifies the shared `test-vectors/` exist and are exercised by
  the implementation.

> **Formula.** Use Go for the living node; use Rust for sealed organs, if they become necessary; do
> not let the language choice become a new Phase 0 blocker. **Go-first, Rust-compatible, spec-driven.**
