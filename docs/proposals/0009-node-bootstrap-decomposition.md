<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Decompose the node-bootstrap orchestrator (god-object → modules)

## Metadata
- **ID:** RP-0009
- **Date:** 2026-06-16
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** cross-cutting (control-plane structure); converges with [RP-0008](0008-go-spine-distribution-rendering.md)
- **Related documents:** Audit-0005 **C33** (control logic in bash, Go spine inert) + **C19/C25** (decisions embedded in the monolith); [RP-0008](0008-go-spine-distribution-rendering.md) (the Go-spine migration this feeds); [ADR-0012](../adr/0012-go-primary-control-plane-language.md) (Go is the primary control-plane language); [ADR-0015](../adr/0015-network-artifact-delivery-and-node-update.md) (the signed pull/fail-closed apply path the orchestrator runs); the target file `scripts/node-bootstrap.sh`.

## 1. Title

Cut the 2130-line `scripts/node-bootstrap.sh` god-object into an **orchestration-only** entrypoint plus focused, independently-testable `control/lib/*.sh` modules — keeping OS-glue in bash and earmarking the control-logic modules for the RP-0008 Go migration.

## 2. Reason

`scripts/node-bootstrap.sh` is **2130 lines / ~55 functions** and is no longer a bootstrap script — it is the node **control-plane god-object**: bootstrap + `--update`/`--staged`/`--ack` + `--revoke` + `--disable-two-hop` + observability (node_exporter, the dataplane-metrics generator) + AmneziaWG dialect/rendering + selective-growth split-tunnel knobs + served-bundle logic + donor selection + SSH/journald/ufw hardening + the signed-pull/promote/rollback apply path. This is the architectural risk the deep audit named **C33** ("bundle/aggregate/subscription + routing policy decided in bash; the Go spine inert") and that surfaced as **C19** (fail-open `write_params` + toggle-revert) and **C25** (revoke didn't re-render the served bundle): *decisions embedded in a monolith with no typed contract and no module boundary*.

Left as one file, the next defect is not architectural — it is **bash-hell**: a change to one concern (say, observability) risks the bootstrap path; nothing can be unit-tested in isolation; the file is unreviewable as a whole; and every new feature widens the blast radius of the single most load-bearing script on every node. The selftest + conformance suite exercise it end-to-end, but a 2130-line file is exactly where a one-line edit ships an outage.

This RP does **not** propose a behaviour change. It is a structure change: extract the function groups into sourced modules so each concern is a bounded, testable unit, and the entrypoint becomes thin orchestration.

## 3. Scope

- **Layers:** control plane (node orchestration) + infra (the deployed bootstrap/update path).
- **Components:** `scripts/node-bootstrap.sh` (the entrypoint), the new `control/lib/*.sh` modules, the conformance suite, the `--update` re-exec path.
- **Contracts:** none change — the params/identity/state files, the rendered configs, the systemd units, and the CLI surface (`--update`/`--revoke`/`--disable-two-hop`/…) are byte-for-byte preserved. This is a behaviour-preserving refactor.
- **Storage / state:** unchanged.
- **Flows:** bootstrap, update (re-exec from the immutable copy), revoke, disable-two-hop — all preserved; only their *implementation* moves behind module boundaries.

### 3.1. Component participation table (mandatory)

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| `scripts/node-bootstrap.sh` | Reduced to **orchestration only**: arg parse, the `flow_*` dispatchers, sourcing the libs, post-apply verification | active | system shell | the entrypoint is genuine OS-orchestration glue (systemd, apt, re-exec) — correctly bash, just far thinner |
| `control/lib/identity.sh` | key/uuid/shortid/secret generation + `ensure_identity` + `verify_signed_ref` | active | openssl/sing-box/xray gens | standard generators (ADR-0002); shell only marshals |
| `control/lib/donor.sh` | donor candidate selection + verification (`pick_donor` etc.) | active | curl/openssl | probes a real external host; shell glue |
| `control/lib/render_params.sh` | `write_params` + operator-override seed/merge + `resolve_node_address` | active | jq | **control logic** — earmarked for the RP-0008 Go migration |
| `control/lib/two_hop.sh` | `assert_two_hop_shape` + `flow_disable_two_hop` | active | jq | **routing-policy logic** — earmarked for the RP-0008 Go migration |
| `control/lib/render_awg.sh` | `compute_client_allowed` + `sg_allowed_join` + `render_awg0` + awg tool build/setup | active | amneziawg-go/awg-quick | userspace-WG setup is OS-glue; the AllowedIPs split-tunnel policy is control logic (RP-0008 candidate) |
| `control/lib/observability.sh` | node_exporter + the dataplane-metrics generator + `setup_observability` | active | node_exporter | metrics wiring; OS-glue |
| `control/lib/serve_bundle.sh` | `render_serve_bundle` + `bundle_served_age*` (the served last-known-good gate) | active | jq + myceliumctl | **validation logic** — RP-0008 already owns the authoritative `validate-bundle`; this becomes its caller |
| `control/lib/update_apply.sh` | `myc_fetch_artifacts` + `render_candidate`/`validate_config`/`promote_config`/`rollback_config` | active | system shell | the signed-pull/fail-closed-apply state machine (ADR-0015) — the highest-value Go-migration candidate |
| `control/lib/harden.sh` / `control/lib/install.sh` | `harden_*` / `install_*` + `ensure_singbox_*` + cert | active | system shell | host hardening + package install = OS-glue, correctly bash |

### 3.2. Blast-radius cap

- **Responsibility boundaries affected:** 1 (the orchestrator's internal structure) — staged.
- **Layers affected (behaviour):** 0 — behaviour is held invariant (byte-identical render + flow output).
- **Files in diff (estimate):** ~12 (the entrypoint + ~10 new libs + the suite registration), staged across chunks.

- [ ] Within cap — single-step.
- [x] Exceeds cap → **declared multi-phase**. A single-commit explosion of a 2130-line live-fleet script is exactly the big-bang the audit warns against. Extract **one module group per chunk**, each landing suite-green + node-verified, behaviour byte-identical, before the next.

  **Chunks (each a commit, suite-green + node-verified):**
  - **C1 — scaffold + leaf libs:** establish `control/lib/` sourcing in the entrypoint; extract the pure leaves first (`identity.sh`, `donor.sh`, `harden.sh`, `install.sh`) — lowest risk, no flow change.
  - **C2 — render/serve:** extract `render_params.sh` + `serve_bundle.sh` (the C19/C10/C25 logic, now a bounded unit; `serve_bundle` calls the RP-0008 `validate-bundle`).
  - **C3 — two-hop + awg:** extract `two_hop.sh` + `render_awg.sh` (the routing/split-tunnel policy).
  - **C4 — observability + update_apply:** extract `observability.sh` + `update_apply.sh` (the signed-pull/promote/rollback state machine — verify the re-exec-from-immutable-copy path most carefully here).
  - **C5 — entrypoint diet + the governance gate:** the entrypoint is now orchestration-only; add the `no_new_control_decisions_in_bash` gate (below).

## 4. Current state

One file, ~55 functions, ≥6 concerns interleaved (see §2 and the participation table). The `--update` path **re-execs from an immutable copy before fetch**, so the entrypoint's structure is load-bearing for the update flow; the file is the single most-deployed script in the project. The Go spine (`internal/spec`, `cmd/myceliumctl`) is the right home for the *control logic* embedded here (RP-0008), but nothing has been extracted, so the monolith keeps absorbing every new concern.

## 5. Target state

- `scripts/node-bootstrap.sh` is **orchestration only**: usage, arg parse, `source control/lib/*.sh`, the `flow_*` dispatchers (bootstrap/update/ack/revoke/disable-two-hop), and post-apply verification — on the order of a few hundred lines.
- Each `control/lib/*.sh` is a **bounded, sourceable, independently-testable** module with a single concern and a header stating its responsibility + its OS-glue-vs-control-logic classification.
- The **control-logic** modules (`render_params`, `two_hop`, `serve_bundle`, the split-tunnel policy in `render_awg`, the `update_apply` state machine) are explicitly **earmarked as the RP-0008 Go-migration front line** — they are the units that will be ported to `internal/spec`/`cmd` next. The **OS-glue** modules (`install`, `harden`, the awg userspace setup, observability wiring) stay bash by design.

Effect: indistinguishability/survivability **unchanged** (byte-identical artifacts); maintainability + testability **strongly improved**; the C33 risk is cut from "one 2130-line god-object" to "thin orchestrator + bounded modules, control logic queued for Go."

## 6. Risks

- **Compatibility:** none at the wire/contract — behaviour is byte-identical (the equivalence bar in §7). The CLI, params, configs, and units are preserved.
- **The live `--update` re-exec path** is the delicate bit: the entrypoint re-execs from an immutable copy *before* fetch, so the sourcing of libs must resolve correctly from the re-exec'd copy (the `CHECKOUT_DIR`/`ARTIFACT_ROOT` discipline that `node_update_artifact_root.sh` already gates). C4 verifies this on a node explicitly.
- **Sourcing order / shared state:** functions share globals (paths, `STATE_DIR`, params); extraction must preserve the shared-variable contract. Mitigated by behaviour-equivalence testing + the existing selftest, which exercises the full render/flow surface.
- **Rollback risk:** low — each chunk is an isolated, revertible commit; behaviour-preserving.
- **No new attack surface, no de-anonymisation, no decentralisation impact** — pure structure.
- **Temporary degradation:** none expected (no behaviour change); the fleet auto-pulls, and node-bootstrap.sh changes take two `--update` cycles, so each chunk must be node-verified before push.

## 7. Acceptance Criteria

- [ ] `scripts/node-bootstrap.sh` is orchestration-only (dispatchers + sourcing + verify), materially smaller (target: well under ~500 lines), with every concern extracted to a `control/lib/*.sh`.
- [ ] Each new lib is independently `bash -n`-clean and sourceable; `control/selftest.sh` + the conformance suite stay green at **every** chunk.
- [ ] **Behaviour equivalence:** a representative bootstrap/update/revoke render produces byte-identical params + configs before and after each chunk (a fixture diff in the selftest).
- [ ] The `--update` re-exec path is node-verified after C4 (the most delicate chunk).
- [ ] **`no_new_control_decisions_in_bash` gate** (C5): a conformance check that fails if `node-bootstrap.sh` re-grows a control-decision function (render/validate/policy/merge) instead of delegating to a lib or the Go spine — operationalising RP-0008's "no new control-decisions-in-bash" rule.
- [ ] Conformance green; the existing offline gates unchanged in verdict.

## 8. Documentation changes
- [ ] [../ARCHITECTURE.md](../ARCHITECTURE.md) — record the node control-plane module layout (entrypoint + libs) and the OS-glue-vs-control-logic split.
- [ ] `control/README.md` — the `control/lib/*.sh` module map + each module's responsibility.
- [ ] [RP-0008](0008-go-spine-distribution-rendering.md) — cross-reference: the control-logic libs extracted here are RP-0008's Go-migration front line.
- [ ] `scripts/node-bootstrap.sh` header — state it is orchestration-only and where each concern lives.

## 9. Migration Strategy

Strangler, behaviour-preserving, one module group per chunk (C1→C5 above). For each chunk: extract the function group verbatim into a `control/lib/*.sh`; `source` it from the entrypoint at the existing call sites; run `control/selftest.sh` + `tests/run.sh` (must stay green) + the byte-identical fixture diff; node-verify the flow the chunk touches; commit. No chunk changes behaviour. The control-logic libs, once bounded, are handed to RP-0008 for the Go port (this RP cuts the monolith; RP-0008 moves the logic up a layer). Rollout is the normal fleet `--update`; because node-bootstrap.sh changes take two cycles, each chunk is node-verified before push.

## 10. Rollback / Fallback

Each chunk is a single revertible commit with byte-identical behaviour, so rollback is `git revert` of one chunk with zero state/key/IP migration. If a chunk's node verification reveals a sourcing/re-exec issue, revert that chunk (the entrypoint falls back to the previous structure) — the fleet keeps running the prior immutable copy until the fix lands. Fail-closed is preserved throughout: the signed-pull/validate/promote/rollback path (`update_apply.sh`) keeps its existing fail-closed semantics; a refactor that cannot prove byte-identical output does not ship.
