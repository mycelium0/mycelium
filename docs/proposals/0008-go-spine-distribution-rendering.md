<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Consolidate distribution-rendering control logic in the Go spine

## Metadata
- **ID:** RP-0008
- **Date:** 2026-06-16
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** cross-cutting (control-plane consolidation); P1 may land during Phase 1, P3 not before Phase 2
- **Related documents:** Audit-0005 (C33 umbrella; C11, C12, C13, C14, C10; N1 root-cause); RP-0007 (the Phase-1 build whose bash renderers this migrates); RP-0002 §W7 (the original `render-server`/`subscription` "not yet ported" stub); ADR-0025 (no-global-abuse-oracle — the C13 region-vocab closure rides on it); ADR-0029 (community-federated ingress / two-hop, whose `via_user` routing decision P3 moves out of bash)

## 1. Title

Move the distribution-rendering control logic (bundle / aggregate / subscription emission, vocab, mapping, version, validation, and two-hop routing policy) out of `bash`/`jq` and into the Go spine (`internal/spec`), behind typed contracts, by a strangler migration — and adopt a "no new control-decisions-in-bash" rule so the gap cannot re-open.

## 2. Reason

Audit-0005's single highest-leverage finding is **not** any one fingerprint — it is the **architectural fact that bundle/aggregate/subscription control logic now lives entirely in `bash`/`jq` while the Go spine (`internal/spec`) is inert with zero production callers (C33)**. That gap is what let the one *functional* break of Phase 1 ship undetected: **N1** — the aggregate path emitted a non-dialable ShadowTLS outbound while the shell selftest gave it a false PASS, because no production code round-trips rendered JSON through the authoritative `spec.Bundle.Validate()`. N1 is now fixed (Audit-0005 step-1), but the *mechanism that allowed it* is structural and remains: control meaning is duplicated across shell sites with no typed owner.

Concretely, the duplication the audit verified:

- **C33 (CARRIER_ADAPTER_DRIFT, S2)** — bundle/aggregate/subscription rendering and the two-hop `via_user` routing decision are all decided in shell; `cmd/myceliumctl/main.go` stubs `render-server`/`subscription` ("not yet ported, RP-0002 W7") and has no `bundle`/`aggregate` command at all; the `internal/spec` types have no production caller. The authoritative schema is decorative.
- **C11 (CONFLICTING_SOURCE_OF_TRUTH, S2)** — bundle validation is hand-mirrored across the Go type and ≥2 shell sites; nothing round-trips the rendered JSON through `spec.Bundle.Validate()` in production.
- **C12 (CARRIER_ADAPTER_DRIFT, S2)** — the protocol→transport-class mapping is owned by three non-Go sites; Go validates only set membership (`IsValid()`), never mapping correctness, so a mis-edit emits a wrong-but-valid class Go accepts.
- **C14 (CONFLICTING_SOURCE_OF_TRUTH, S2)** — the shell bundle-version constant and the Go `NetworkStateVersion` are kept equal only by a hand comment.
- **C13 (ENUMERATION_EXPOSURE, S2-latent)** — the bundle `Region` is open-vocab in Go (`Region != ""` only); the coarseness gate never checks `region`.

This is a Parnas/conceptual-integrity defect (lens-brooks 5.5, lens-parnas in §3 of the audit): the *decisions* live outside their owning layer. `node-bootstrap.sh` bloat (~1800 lines) is the visible symptom but is **secondary** — the bug is that decisions (fail-open on malformed two_hop, no re-render on revoke, mapping/version/validation meaning) are embedded in a shell monolith with no typed contract. Left as-is, every new transport class, routing rule, or validation invariant adds another untyped, untestable shell branch, and the next N1 ships the same way.

## 3. Scope

- **Layers:** control plane (config distribution + routing policy).
- **Components:** `myceliumctl` (Go CLI), `internal/spec` (typed schema + validation), the shell renderers (`control/lib/render_bundle.sh`, `render_aggregate.sh`, `render_singbox.sh`), `scripts/node-bootstrap.sh` (served-bundle gate + two-hop write_params), the conformance suite.
- **Contracts:** the distribution **Bundle** schema (`internal/spec/bundle.go`), the **TransportClass** closed vocab (`internal/spec/edgereport.go`), the schema **version** (`internal/spec/network.go` `NetworkStateVersion`), the **region** bucket vocab, and the two-hop routing contract (`auth_user`/`via_user`).
- **Storage / state:** none changed — the same params/state/identity files; this RP changes *who computes the rendered artifact from them*, not where state lives.
- **Flows:** config delivery (served bundle), client-side aggregate merge, subscription emission, two-hop egress routing.
- **Schemas / formats:** no wire-format change. The migration is required to be **byte-output-equivalent** (see §9); the artifacts clients consume are identical before and after each phase.

### 3.1. Component participation table (mandatory)

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| `internal/spec` (Go) | Becomes the authoritative owner of schema, vocab, proto→class mapping, version, and `Validate()`; gains pure render helpers in P3 | active | none | this is the project's own control-plane contract layer — the boundary it owns is exactly "what is a valid distribution artifact"; no external tool defines our Bundle |
| `myceliumctl` (Go) | Gains `validate-bundle` (P1) and the ported `bundle`/`aggregate`/render commands (P3); exposes mapping/version via `--json` (P2) | active | none | the CLI is the seam shell calls; keeping it Go-side is the whole point |
| `control/lib/render_*.sh` | P1–P2: unchanged emitters whose output is round-trip-checked against Go; P3: reduced to thin callers of the Go renderer (or removed) | active → passive | system shell + `jq` | shell is the wrong layer for state-machine/rollback/policy invariants (the audit's finding); it stays only as the deploy-time invocation glue |
| `scripts/node-bootstrap.sh` | Served-bundle gate delegates to `myceliumctl validate-bundle` (P1); two-hop routing-policy decision moves to Go (P3) | active | system shell | bootstrap orchestration stays in shell; control *decisions* it currently embeds move behind the Go contract |
| conformance suite | Gains `bundle_go_roundtrip` and a bash↔Go equivalence gate (P1/P3) | test-only | system shell | the gate proves the migration is lossless before any cutover |

## 3.2. Blast-radius cap

- **Responsibility boundaries affected:** 1 (rendering ownership shifts shell → Go) — but staged.
- **Layers affected (behaviour):** 1 (control plane), behaviour held invariant by the equivalence requirement.
- **Config-distribution surfaces affected:** 1 (the Bundle/subscription artifact producer).
- **Files in diff (estimate):** P1 ~6, P2 ~6, P3 ~12.

- [ ] Within cap — single-step RP.
- [x] Exceeds cap → **declared multi-phase** (a single-commit shell→Go port of the whole renderer would be a big-bang rewrite of a working deployed path — explicitly forbidden by the audit §4: "Do **not** attempt a big-bang rewrite of `node-bootstrap.sh` — it works on the deployed path. Strangler-pattern it.").

  **Phase breakdown (strangler):**
  - **P1 — Typed boundary contracts (no logic moved).** Go gains a `validate-bundle` command that Unmarshals a rendered bundle and runs `spec.Bundle.Validate()`; a `bundle_go_roundtrip` conformance gate runs render→Unmarshal→Validate so bash output is locked to the Go type. `RegionBucket` becomes an inert closed enum enforced in `Validate()` (C13); `GeneratedAt` is validated (C15); a `TestBundleJSONRoundTrip` lands (C16). The served-bundle gate in `node-bootstrap.sh` delegates to the Go validator (C10's authoritative form). **Closes C11/C13; makes C10 authoritative. No rendering logic moves yet — output is unchanged, now *proven* unchanged.** Eligible to land during Phase 1.
  - **P2 — Go owns vocab + mapping + version.** `spec.ProtocolToTransportClass` and the version constant become Go-owned; the CLI exposes them via `--json`; shell and the family gate consume Go instead of hand-mirroring. `MYC_BUNDLE_VERSION` is generated from `NetworkStateVersion` (`go:generate`) or schema-checked. **Closes C12/C14 at the root (kills three CONFLICTING_SOURCE_OF_TRUTH findings).**
  - **P3 — Port the renderers.** `bundle`/`aggregate`/subscription emission and the two-hop `via_user` routing decision move into Go pure functions; shell becomes a thin invoker. Gated by a **bash↔Go equivalence suite** that requires byte-identical output before cutover. **Closes C33.** Not before Phase 2.

## 4. Current state

- `internal/spec` (`bundle.go`, `edgereport.go`, `network.go`) defines the types and `Validate()` but has **zero production callers**. `cmd/myceliumctl/main.go` stubs `render-server`/`subscription` with "not yet ported (RP-0002 W7)" and has **no `bundle`/`aggregate` command** — those live only as the shell `myceliumctl bundle`/`aggregate` subcommands dispatching to `control/lib/render_*.sh`.
- **Validation is triplicated**: `spec.Bundle.Validate()` (authoritative-by-design, uncalled), `render_bundle.sh` producer checks, `render_aggregate.sh` input assert, and the `node-bootstrap.sh` served-bundle jq gate. Chunk B (Audit-0005 step-2) brought the shell copies to parity with the Go branches, but parity-by-hand is exactly the C11 debt — there is still no round-trip through the Go type in production.
- **Vocab/mapping/version live in shell**: `myc_bundle_class_of` (proto→class), `MYC_BUNDLE_VERSION`, and the family gate's `family_of` each restate knowledge Go also holds, with no drift guard.
- **Routing policy is decided in shell**: `render_singbox.sh` makes the two-hop egress/route decision (`auth_user: [ $th.via_user ]`) in `jq`.
- `Region` is `string` with only a non-empty check; the closed-vocab hardening is a `// Phase-2` comment.

## 5. Target state

- **One owner per fact.** The Bundle schema, the transport-class vocab, the proto→class mapping, the schema version, the region-bucket vocab, and bundle validation each have exactly one authoritative definition — in Go (`internal/spec`). Shell reads them through the CLI; it never restates them.
- **Every rendered artifact round-trips through the Go validator before it is served or merged.** A bundle that does not Unmarshal-and-`Validate()` is refused fail-closed; there is no shell path that can emit a structurally-broken-but-served artifact.
- **Routing policy is typed.** The two-hop ingress→egress decision is a Go function with a unit test, not a `jq` expression.
- **Governance: no new control-decisions-in-bash.** A new transport class, routing rule, region bucket, or validation invariant lands in Go first; shell may only *invoke* it. New shell branches that encode a control decision are rejected in review (and, where mechanizable, by a conformance check).

Effect on the four axes:
- **indistinguishability** — unchanged at the wire (output is byte-equivalent); improved against the *mis-edit* failure mode (a wrong-but-valid class can no longer be hand-typed past Go).
- **survivability / path redundancy** — unchanged in transports; improved in correctness-survivability (N1-class lossy round-trips are caught by the equivalence gate, not by a user's dead endpoint).
- **adaptation speed** — improved: a new transport/route is one typed change with a test, not a shell edit replicated across sites.
- **control-plane persistence** — unchanged; this is a build-time/render-time consolidation, no new runtime dependency or coordinator.

## 6. Risks

- **Compatibility:** none at the wire — the migration is gated on byte-identical output (§9). No client/config/node sees a different artifact. No schema bump (the version stays `NetworkStateVersion`); if P2/P3 ever *does* change the schema that is a separate, normally-versioned change, not part of this consolidation.
- **User security (requirement №1):** no new data is collected, logged, or correlated; identities/region buckets stay as coarse as today (C13 *tightens* region toward a closed vocab, never widens it). No de-anonymisation surface is added. The two-hop routing move is a representation change, not a policy change.
- **Indistinguishability / probe surface:** unchanged — same emitted artifacts; the equivalence gate is the proof.
- **Loss of observability:** none removed; P1 *adds* a round-trip signal and (per C25, tracked in chunk D) a served-bundle age metric is a sibling improvement.
- **Temporary degradation:** during P3 cutover, a Go renderer bug could emit a non-equivalent artifact — prevented from shipping by the equivalence suite (fail-closed: non-equivalent ⇒ keep shell output, do not cut over).
- **Flapping / false migrations:** N/A — no auto-rotation behaviour changes.
- **Rollback risk:** low and staged — see §10. Shell renderers remain in place and authoritative until P3's equivalence suite is green; P1/P2 are additive (Go validates/owns, shell still emits).
- **Decentralisation:** none — no coordinator, no network call; the Go code runs in the same `myceliumctl` the operator already runs.

## 7. Acceptance Criteria

P1:
- [ ] `myceliumctl validate-bundle <file>` Unmarshals and runs `spec.Bundle.Validate()`; exits non-zero on any invalid bundle (negative fixtures: bad version, empty endpoints, unknown class, empty tag/region, negative priority, non-`unknown` health, empty link).
- [ ] `bundle_go_roundtrip` conformance gate: render a bundle → Unmarshal → `Validate()` passes, on the same fixtures the shell selftest uses.
- [ ] `spec.RegionBucket` closed enum enforced in `Endpoint.Validate()` (C13); `GeneratedAt` validated as RFC-3339 UTC (C15); `TestBundleJSONRoundTrip` lands (C16).
- [ ] `node-bootstrap.sh` served-bundle gate calls the Go validator (C10 authoritative), retaining the jq pre-check as defence-in-depth.
- [ ] Conformance green; `no_custom_crypto`, `bundle_region_closed_vocab`, and the existing offline gates unchanged in verdict (no regression).

P2:
- [ ] `spec.ProtocolToTransportClass` is the single mapping; `myceliumctl` exposes it (and the version) via `--json`; `family_of`/`myc_bundle_class_of` consume the Go output (C12).
- [ ] `MYC_BUNDLE_VERSION` is generated from `NetworkStateVersion` (or a schema-check test fails on drift) (C14).
- [ ] A drift test proves a Go-only vocab/version edit is reflected in shell without a second hand-edit.

P3:
- [ ] A **bash↔Go equivalence suite** renders the same params/state through both and asserts byte-identical bundle/aggregate/subscription output across the fixture matrix; cutover is blocked while any case differs.
- [ ] The two-hop `via_user` routing decision is a Go function with a unit test (ingress≠egress preflight included, cf. chunk-D C21).
- [ ] After cutover, shell renderers are thin invokers (or removed); `cmd/myceliumctl/main.go` no longer stubs render commands.

## 8. Documentation changes
- [ ] [../ARCHITECTURE.md](../ARCHITECTURE.md) — control-plane section: record that `internal/spec` is the authoritative owner and the "no control-decisions-in-bash" rule.
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — note the mis-edit (wrong-but-valid class) failure mode is closed by Go-owned mapping.
- [ ] [../refactoring.md](../refactoring.md) — add the "no new control-decisions-in-bash" rule to the policy.
- [ ] `docs/adr/` — a short ADR may record the decision "control logic lives in the Go spine, shell only invokes" if reviewers want the rationale separated from this RP's *work*.
- [ ] `control/README.md` + `cmd/myceliumctl` help — document `validate-bundle` and the `--json` mapping/version output.
- [ ] [0007-phase1-distribution-health-xhttp.md](0007-phase1-distribution-health-xhttp.md) — cross-reference: RP-0007's bash renderers are what RP-0008 migrates.

## 9. Migration Strategy

Strangler, three phases, each independently shippable and each leaving a green tree:

1. **P1 — wrap, don't move.** Add the Go validator + round-trip gate *around* the existing shell renderers. Shell still produces the artifact; Go now *checks* it on every render/serve. Output is unchanged and now provably so. Land during Phase 1.
2. **P2 — pull the facts up.** Move vocab/mapping/version ownership into Go and have shell read them via `--json`. Still shell-rendered, but the *knowledge* is single-owner. Each removed duplication is replaced by a Go read, verified by a drift test.
3. **P3 — move the logic.** Implement the renderers as Go pure functions; run them in parallel with shell under the equivalence suite; cut over a producer only when its output is byte-identical across the fixture matrix. Two-hop routing moves last. Not before Phase 2.

Rollout order is node-agnostic: this changes how the *operator's* `myceliumctl`/bootstrap computes artifacts, not a wire contract, so there is no node→config→client ordering dependency and no parallel-contract release. Old nodes keep working because the emitted artifact is identical.

## 10. Rollback / Fallback

- **P1/P2 are additive** — to roll back, drop the Go validator/gate (or the `--json` consumption) and the shell path is exactly today's. No data, key, or IP migration is involved.
- **P3 is gated, not flipped** — the shell renderer stays the authoritative emitter until the equivalence suite is green; cutover is per-producer. If a ported renderer regresses post-cutover, revert that one producer to its shell emitter (kept in tree until the suite has been green across at least one full phase) — recovery is a one-line invoker switch, well inside the "people without network access" downtime bar.
- **Fail-closed during rollback:** at every phase, an artifact that fails Go `Validate()` is refused, never served. There is no rollback state in which a structurally-broken bundle reaches a client.
