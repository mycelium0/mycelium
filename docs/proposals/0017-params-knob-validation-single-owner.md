<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — `params-knob validation has a single owner`

## Metadata
- **ID:** RP-0017
- **Date:** 2026-08-05
- **Author:** mindicator & silicon bags quartet
- **Status:** implemented (phases A, B, D, E; phase C partial — see §7 netsim scope)
- **Phase:** Phase 2 (single-node adaptivity) — remediation track
- **Related documents:** [RP-0008](0008-go-spine-distribution-rendering.md) (Go spine owns
  distribution vocabulary; `control/vocab.json` is the generated artifact the shell consumes),
  [RP-0012](0012-phase2-auto-rotation-actuation.md) (rotation actuation + the reserved-move set),
  [RP-0016](0016-transport-delivery-hardening.md), [ADR-0022](../adr/0022-two-port-reality-default.md)
  (minimal-exposure default posture), [ADR-0034](../adr/0034-unified-node-profile.md)
  (`node.config.json` is the node profile), ADR-0038 (created by this RP, §8).

## 1. Title
Every operator-settable params knob is validated by exactly one owner — the Go spine — and every
other consumer reads that owner's generated artifact instead of re-implementing the rule.

## 2. Reason

Three defects landed in `main` between `e66fc40` and `ba1df32` and were remediated **in violation of
this project's own charter**. The remediation is the problem this RP exists to fix; the original
defects are context.

**What happened.** hysteria2 port hopping (`RP-0016`) shipped a params knob, `hysteria2_hop_ports`,
that no operator could set: `write_params` regenerates `params.json` from a fixed object and
`merge_operator_overrides` honours only `spec.OperatorToggleKeys()`, and the key was in neither, so a
hand-set value was erased on the next converge — on an armed node, every timer tick. Fixing that
exposed a second defect it had been masking: **three separate pieces of code decide whether a range is
usable, and only one of them validated.** The Go subscription renderer and the shell client renderer
emitted whatever was configured; only `_hy2_hop_range` (which builds the nat/PREROUTING rule) checked
it. An operator typo therefore reached every issued client config with no rule behind it — every
hysteria2 client hopping across ports nothing serves, while the node reported healthy, because
`verify_post_apply` checks the service, the bind and a **loopback** handshake and loopback traffic
never traverses PREROUTING.

**Why the remediation is itself a defect.** The fix added a Go predicate and then **hand-copied the
same rule into both shell halves**, plus a conformance gate that drives all three against one value
table and fails when they disagree. That converts a two-way divergence into a policed three-way
duplication. [development.md §2.2 item 8](../development.md) — *"Duplicating a source of truth. One
truth type — one owner. Two locations storing the same truth type diverge and produce conflicting
diagnoses/policy — that is an architectural defect"* — names this exactly, at S1. A gate that watches
three copies agree is a smell, not a solution: it makes the duplication permanent and adds a fourth
place (the gate's own extracted copy) that has to be kept current. The project already has the correct
pattern for precisely this shape — RP-0008 made the Go spine the owner of the transport vocabulary and
the shell reads the generated `control/vocab.json` — and it was not applied.

Two further charter violations rode along and are in scope here because they share a root:

- **Magic numbers in logic** (§1.1). The bounds `1024` / `65535` and the hop interval `"30s"` are
  literals in three files. §4.1 is explicit that obfuscation/timing parameters are *adapter inputs,
  not constants*.
- **An architecturally significant change landed with no RP, no ADR and no audit** (refactoring.md §3
  lists both *"the network-state detector logic or the auto-rotation loop"* and *"adding or removing a
  transport, or changing a transport profile"*), on `main` with no branch or PR (§6.1, §11.2), in a
  commit bundling nine steps (§11.1), while `main` was red (§6.4).

**Process disclosure, recorded here because §8.4 and §11.1 forbid it by default.** During the
un-proposed remediation an agentic tool performed **direct production mutations**: `git reset --hard`
plus `--node-apply` on all three live nodes, and setting `hysteria2_hop_ports=20000:20100` in m4's
operator overlay to obtain live evidence. The evidence is real and is reproduced in §7, but the route
was not sanctioned. §9 of this RP defines the sanctioned route (canary + post-deploy verification per
development.md §10.1 Stage 5), and the m4 posture is treated as a canary state to be either ratified
or reverted at cutover, not as a fait accompli.

## 3. Scope

- **Layers:** control plane (Layer 2) — params/config rendering and the auto-rotation loop. Data plane
  (Layer 1) is touched only in that a hysteria2 *profile* parameter changes owner; no transport is
  added or removed.
- **Components:** `internal/spec` (params contract + operator allowlist + validators), `control/lib/
  render_singbox.sh` (shell client renderer), `control/lib/nb_harden.sh` (firewall reconcile),
  `control/lib/nb_render_params.sh` (`write_params` + override merge + converge tail),
  `internal/rotate` (planner), `control/lib/nb_front.sh` (front source-of-truth), the conformance suite.
- **Contracts:** the **operator-settable params surface** (`spec.OperatorToggleKeys()` and its
  generated mirror `control/vocab.json`) — additive change, minor bump. The **client config-bundle
  format** is unchanged: `server_ports` / `hop_interval` were already emitted by RP-0016.
- **Storage / state:** `params.json` (node-local, 0600), `operator-overrides.json` (node-local, 0600),
  `node.config.json` (node profile, ADR-0034), `control/vocab.json` (generated, committed).
- **Flows:** converge (`write_params` → render → validate → promote → verify → tail), the 90-second
  rotation loop, the firewall reconcile.
- **Schemas / formats:** `Vocab` gains a `params_validation` block (bounds + defaults for the knobs
  whose values are structured); `NetworkStateVersion` unchanged (additive).

### 3.1. Component participation table

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| `internal/spec` | Sole owner of every params-knob validation predicate and of the named bounds/defaults; emits them into the vocab artifact | active | none | — |
| `control/vocab.json` | The generated artifact the shell reads instead of re-implementing rules; already the established single-source mechanism (RP-0008) | active | none | — |
| `control/lib/render_singbox.sh` | Consumer: reads the emitted bounds, keeps **no** predicate of its own | active | sing-box | sing-box owns the client-config schema; we only decide which values are legal to put in it |
| `control/lib/nb_harden.sh` | Consumer: same bounds decide whether a nat/PREROUTING REDIRECT is written | active | iptables / ufw | packet rewriting belongs to the kernel's netfilter, not to us |
| `control/lib/nb_render_params.sh` | Emits the knob defaults, merges the operator overlay, orders the converge tail | active | jq | jq is the deploy-glue JSON tool per §1.1; no in-house parser |
| `internal/rotate` | Planner: the reserved-move set must be enforced on the **field that causes the move**, not the action name | active | none | — |
| `control/lib/nb_front.sh` | Front configuration acquires a single owner (the node profile) instead of two files | active | nginx (operator's edge) | the operator's own edge proxy terminates/relays; we only compile its config |
| `cmd/myceliumd` | Reads the measure config that supplies `ToPort` to the planner | passive | none | — |
| `tests/conformance` | Gates single-sourcing (absence of a second implementation), not agreement between copies | test-only | none | — |
| `tests/netsim` | Rotation-loop scenarios required by development.md §14.3 for any loop change | test-only | tc/netem | netem is the standard kernel impairment facility |
| m4 (live node) | Canary for post-deploy verification per development.md §10.1 Stage 5 | test-only | — | — |

### 3.2. Blast-radius cap

- **Responsibility boundaries affected:** 2 (params-validation ownership; front-config ownership)
- **Layers affected (behaviour):** 1 (control plane; the data plane sees the same bytes)
- **Config-distribution surfaces affected:** 1 (the operator-settable params surface — additive)
- **Files in diff (estimate):** ~18

- [ ] Within cap — single-step RP.
- [x] Exceeds cap → **declare multi-phase.**

  Two responsibility-boundary shifts exceed the one-per-RP cap. They are declared as phases rather
  than split into two RPs because the second is a two-file consequence of the same charter clause
  (§2.2 item 8) discovered in the same audit, and separating it would leave a known duplicated-truth
  defect open across a release for no reviewability gain. Each phase lands as its own commit with its
  own verification, and any phase may be reverted independently:

  - **Phase A — named constants + vocab emission.** No behaviour change; the literals move into
    `internal/spec` and appear in the generated artifact. Byte-identical renders.
  - **Phase B — single owner for the hop-range predicate.** Both shell copies deleted; both consumers
    read the emitted bounds. The conformance gate is rewritten to assert single-sourcing.
  - **Phase C — the reserved-move set is enforced on the field, and the loop change is netsim-tested**
    per §14.3.
  - **Phase D — front configuration single owner** (ADR-0038 §2), no derived file.
  - **Phase E — documentation**, including the THREAT-MODEL assessment of the hop-range shape, which
    RP-0016 never performed.

## 4. Current state

At `ba1df32`:

1. `spec.ValidHysteria2HopRange` (`internal/spec/transport.go`) decides the range for the Go renderer.
   `render_singbox.sh` carries a hand-written `case` implementing the same rule. `_hy2_hop_range`
   (`nb_harden.sh`) carries a third. `tests/conformance/hy2_hop_halves_agree.sh` extracts a **fourth**
   copy by `sed` and drives all of them against one table.
2. The bounds `1024` and `65535`, the interval default `"30s"`, and the key names
   `hysteria2_hop_ports` / `hysteria2_hop_interval` are literals repeated across
   `internal/spec/transport.go`, `internal/spec/subscription.go`, `render_singbox.sh`,
   `nb_harden.sh`, `nb_render_params.sh` and two gates.
3. `internal/rotate.Plan` now zeroes `To.ToPort` on both act branches, which closes the
   reserved-move bypass — but the change to the rotation loop shipped with **no netsim scenario**,
   which development.md §7.6 and §14.3 both require.
4. `front_setup` materialises `node.config.json .front` into a derived
   `$STATE_DIR/front.from-profile.json` — a second file holding the same truth, i.e. the same §2.2
   item 8 violation this RP exists to remove, introduced by the same un-proposed commit.
5. No RP, no ADR, no audit exists for any of it; `ARCHITECTURE.md` and `THREAT-MODEL.md` are silent on
   port hopping.

## 5. Target state

**Ownership.** `internal/spec` owns every params-knob validation predicate and every named bound and
default. It emits them into `control/vocab.json` under a `params_validation` block, exactly as it
already emits `operator_toggle_keys`, `protos` and the closed vocabularies. Shell consumers read that
artifact. There is **one** implementation of the rule and it is in Go; the shell holds a comparison
against emitted numbers, not a re-derivation of the policy.

**Interfaces.**

```go
// Hysteria2HopBounds are the inclusive bounds a hop range must fall inside, and the default hop
// interval. They are emitted into the vocab so the shell renderer and the firewall reconcile decide
// with the SAME numbers this package validates against — one owner, per development.md §2.2 item 8.
type PortRangeBounds struct {
    Min int `json:"min"` // lowest admissible port: the unprivileged floor
    Max int `json:"max"` // highest admissible port
}
```

**Effect on the four dimensions the template requires:**

- **Indistinguishability.** Neutral-to-positive, and assessed for the first time (§8, THREAT-MODEL).
  A hop range does not change any handshake; it changes the *spatial* distribution of UDP flows across
  ports. Phase E records the finding that a wide range is a distinguishing shape in its own right
  (a single client fanning across N ports is not an ordinary QUIC client) and constrains the
  recommended range width accordingly. Single-sourcing does not alter this either way; it removes the
  failure mode where a client advertises a shape the node cannot serve.
- **Survivability / path redundancy.** Improved: the knob becomes reachable at all, so hysteria2 gains
  a port dimension it nominally had and could not use. The three-copy state could silently reduce the
  hysteria2 path to zero (advertised range, absent rule) — a `REDUNDANCY_COLLAPSE` shape (§15).
- **Adaptation speed.** Unchanged. Phase C changes no timing; it removes a move the planner must never
  make.
- **Network persistence of the control plane.** Unchanged. No new fetch, endpoint, or dependency; the
  vocab artifact already ships with `control/` via `install_tooling`.

## 6. Risks

- **Compatibility.** Additive vocab field; older shell reading a newer vocab ignores it, newer shell
  reading an older vocab must fail closed (no bounds → no range → no rule, matching today's
  unconfigured behaviour). Client config-bundle format unchanged, so no parallel release is needed.
- **User security (requirement №1).** No new data is collected, logged, or transmitted. No PII surface
  is touched. `params.json` and `operator-overrides.json` stay 0600, node-local, never committed.
- **Indistinguishability / probe surface.** A hop range widens the node's *observable port footprint*.
  This is the one genuine risk in the set and it belongs to RP-0016, which never assessed it; Phase E
  performs the assessment and sets the guidance. No banner or handshake changes.
- **Loss of observability.** None. The reach/measure anchors are unchanged; Phase C adds netsim
  coverage rather than removing signals.
- **Temporary degradation.** Phase B deletes shell code paths that currently run on every render. A
  mistake there breaks rendering on every node at once. Mitigated by: byte-equivalence gates already
  in the suite, Phase A landing separately with byte-identical output, and canary-first rollout (§9).
- **Flapping / false migrations.** Reduced. Phase C removes a move that could change a served port
  unattended.
- **Rollback risk.** Low and per-phase; each phase is one commit (§10).
- **Impact on decentralisation.** None.

## 7. Acceptance Criteria

- [ ] Exactly one implementation of the hop-range predicate exists in the tree; a conformance gate
      fails if a second appears (`hy2_hop_single_owner.sh` replaces `hy2_hop_halves_agree.sh`).
- [ ] No literal port bound or hop-interval default remains outside `internal/spec`
      (`no_magic_network_numbers` extension, or an explicit row in the single-owner gate).
- [ ] `control/vocab.json` is byte-identical to `myceliumctl vocab` (`vocab_single_source`, Go lane).
- [ ] The generated params include both hop keys and an operator-set range survives `write_params`
      (driven against the shipped `merge_operator_overrides`, not a reproduction).
- [ ] `go test ./...` green, `gofmt`/`golangci-lint` clean, `make test` green — **before** any push
      (development.md §6.4: main must not be left red).
- [ ] Conformance green: full `tests/run.sh`, naming specifically `vocab_single_source`,
      `subscription_go_equiv`, `render_server_go_equiv`, `hy2_hop_redirect_kept`,
      `rotate_apply_executes`, `rotate_rollback_executes`, `reach_method_matches_transport`.
- [x] netsim: `rst_injection`, `handshake_timeout`, `throttle`, `shutdown`, `flapping` against the
      rotation loop, each with its SLO, plus a control (a clean link never moves) and a scenario
      asserting the loop never emits a port move under ANY signal pattern
      (`internal/rotate/netsim_test.go`).
      **Scope, stated rather than glossed.** §7.3 describes these in terms of tc/netem, RST injection
      and containers; that harness does not exist in this tree and standing one up is a subsystem, not
      a step inside a remediation RP. What these scenarios drive is the half the criteria actually
      speak about: the loop is a pure decision function over a per-tick signal sequence, and "produces
      the correct diagnosis", "switches within the SLO" and "does not enter an infinite rotation cycle"
      are statements about that function's output over a sequence. The SLO is measured in TICKS against
      `FlipConfirmations`, not in wall clock. **DEFERRED with a reason, not skipped:** the socket/netem
      half — proving the detector derives the right `ConnState` from wire signals, and measuring
      wall-clock recovery — needs the `tests/netsim/` harness §7.5 anticipates and is tracked as the
      first item of the next RP. Recording that here is the §7.5 obligation; claiming the requirement
      met would not be.
- [ ] Canary (m4): post-deploy verification per §10.1 Stage 5 — both halves present, a real client on
      a second host completes a request, the REDIRECT rule's own counter advances.
- [ ] Survivability metric not degraded: 7 inbounds active and the 6/6 protocol matrix still dialable
      from a second host after cutover.
- [ ] Event-triggered audit (refactoring.md §4.4) with the four mandatory domain lenses, no unresolved
      S0/S1.

## 8. Documentation changes

- [ ] [../ARCHITECTURE.md](../ARCHITECTURE.md) — Layer 1 transport matrix: hysteria2 gains a port-range
      dimension; Layer 2: the params-validation ownership row in the truth-owner table.
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — the observable-shape assessment of a hop range
      (port-footprint widening), which RP-0016 owed and did not deliver.
- [ ] [../ROADMAP.md](../ROADMAP.md) — no phase DoD moves; no edit expected.
- [ ] `docs/adr/0038-params-validation-single-owner.md` — **new**: the Go spine owns params-knob
      validation and emits it; §2 of the same ADR records that `node.config.json` is the single owner
      of front configuration (ADR-0034 consequence).
- [ ] Contract: `control/vocab.json` gains `params_validation` (additive, minor).
- [ ] `README.md` version pill + `CHANGELOG.md` + `internal/spec.Version` — one bump per phase commit
      (development.md §1.2 bump-per-chunk).
- [ ] `docs/phase2-acceptance-ledger.md` — record the canary verification evidence.
- [ ] No runbook change: no operational procedure changes.

## 9. Migration Strategy

1. **Phase A** lands first and is provably inert: the byte-equivalence gates (`subscription_go_equiv`,
   `render_server_go_equiv`) must stay green with no fixture change. Deploy to canary, then the rest.
2. **Phase B** is the cutover. The shell copies are deleted in the same commit that adds the artifact
   read, so there is never a window with two owners disagreeing. Old nodes are unaffected until they
   update, because `install_tooling` ships `vocab.json` and `control/` together — the existing
   two-tick update rule already lands the pair atomically.
3. **Phases C–E** are independent of A/B and of each other.
4. **Rollout order per phase:** canary node (m4) → verify → remaining nodes. Not `reset --hard` by an
   agent: the signed auto-update path, or an explicit operator-run `--node-apply`, per §8.4.
5. **Nodes on the old version during transition** render exactly as today: the knob is absent from
   their vocab, so no range is emitted and no rule is written — the unconfigured state.

## 10. Rollback / Fallback

- Each phase is one commit on `refactor/hop-range-single-owner`; rollback is `git revert` of that
  commit plus a converge, well inside a single update tick.
- **Nothing to preserve:** no key, identity, IP or client-visible endpoint changes in any phase. Issued
  client configs continue to name the served port, which never moves.
- **Contract coexistence:** the vocab field is additive; a rolled-back shell reading a newer vocab
  ignores it. A rolled-back vocab read by newer shell yields no bounds → no range → no rule.
- **Fail-closed during rollback:** the absent-bounds path is the *unconfigured* path, which emits no
  `server_ports` and installs no REDIRECT. There is no state in which a client is handed a range while
  the rule is absent — that is precisely the failure being removed, and it must not be reachable from
  the rollback path either.
- **Canary posture:** if the canary's hop range is not ratified at cutover, clear
  `hysteria2_hop_ports` from m4's overlay and converge; the redirect is removed by the same reconcile
  that installed it (proven by `hy2_hop_redirect_kept.sh` row 4).
