<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Changelog — Mycelium control-plane spine

Notable changes to the Go control-plane spine (`cmd/myceliumctl`, `cmd/myceliumd`,
`internal/*`). Format: Keep a Changelog; versioning: SemVer. The single runtime source of
truth for the version is `internal/spec.Version`.

## [Unreleased]

## [0.2.72] — 2026-08-07

> Two causes had put every node into "refusing to update" — and both were invisible from every surface
> anyone watches. Fixed at the shared root rather than one at a time.

### Added
- **The node publishes the FAILURE side of the update outcome**, not only the success timestamp:
  `mycelium_update_consecutive_failures` and `mycelium_update_last_failure_reason` (a closed-vocab
  integer: 1 signature, 2 fast-forward, 3 validate, 4 post-apply, 9 other — never the error text, which
  can carry a path or a ref, and this file is read by node_exporter). A success resets both, so a
  recovered node stops reporting a stall. A staleness-only signal could not express this: "how long is
  too long" depends on the timer period, which the metric does not carry.
- The two refusals that actually stalled the network record themselves at the point of refusal, guarded
  by `command -v` so a bookkeeping call can never change the shape of a fail-closed refusal.
- `tests/conformance/update_chain_is_unbroken.sh` — guards the CAUSE and the REPORTING. The cause is
  offline-checkable: a merge made with GitHub's button carries the committer `GitHub
  <noreply@github.com>`, and CI can see that even though it cannot verify the operator's key (the
  allowed-signers file is out-of-band by design, §8.7). The baseline is named: PRs #10–#17 were merged
  with the button before this was understood, and a gate that stays red over landed history is one
  people learn to skip.

### Fixed
- **`vless-reality-vision` restored on m1** and proven to carry traffic from a second host (HTTP 200).
  The rotation loop had demoted it on 2026-08-05; the donor negotiates h2 again, so the demote is stale.

## [0.2.71] — 2026-08-06

> A correction to 0.2.70, and the last two open audit findings.

### Corrected — 0.2.70 reported a defect that is not one
- **The anti-beacon cap is not weaker than its name.** 0.2.70 recorded that any rolling hour holds
  `MaxPerWindow + 1` acts and left it as an operator decision. That measurement used a **closed**
  interval `[t-W, t]`, which double-counts the point on the boundary. Measured both ways:
  `cap=2, closed=3, half-open=2`. With `MinInterval * MaxPerWindow >= Window` the cooldown places acts
  exactly `W/M` apart, so every **half-open** window `(t-W, t]` holds exactly `MaxPerWindow` — which is
  the correct convention for a rate cap. There is nothing to change in `MinInterval`, `Window` or the cap.
  The convention is now stated on the field itself, and the test measures it that way.

### Fixed
- **The renderer half of the hop-range collision refusal** (F-001, previously deferred). The firewall
  refused a range containing another served UDP port; the renderers still emitted it, so a client was
  handed a range the node had already decided not to make real. Both now refuse. The policy — WHICH keys
  name a UDP-served port — is emitted (`params_validation.udp_port_keys`), so the two halves compare
  against one list instead of each holding their own idea of it.
- **`ServesUDP` is declared in the registry, not inferred from the class.** Deriving the UDP set from
  class names silently omitted shadowsocks-2022, which is class `shadowsocks-tcp` and serves UDP anyway —
  so a range covering its port would have been accepted by the renderers.
- **The IPv6 twin REDIRECT** (F-010a). The inbounds listen on `::` and `resolve_node_address` falls back
  to a global IPv6 address, so on such a node every client dials v6 — and no `ip6tables` rule existed,
  while the IPv4-only verifier reported the range "verified". Both families are now installed,
  reconciled and verified; an IPv4-only redirect FAILS verification.

## [0.2.70] — 2026-08-06

> A constraint census of the rotation planner, run because six patches in a row each spawned a defect of
> the same class. It found that the gate guarding the reserved-move set had been disarmed by the fix for
> the reserved-move set, that the per-window budget guard could never run, and that the anti-beacon cap
> has always been one weaker than its name.

### Fixed
- **The reserved-move gate was disarmed by the commit that strengthened the reservation.**
  `rotate_apply_executes.sh` decides whether a declared move is "requestable" by grepping for `= <konst>`
  — and `!= RotationActionRotatePort`, added to `RotationPlan.Validate` to ENFORCE the reservation,
  matched it. The gate concluded `rotate-port` was requestable and stopped demanding a reason for it.
  The detector now requires a real assignment (an `=` not preceded by `! = < >`) and additionally sees
  struct-literal assignment `Action: <konst>`, which the old pattern could not see at all.
- **`RotationLimits.Validate` used integer division.** `MinInterval < Window/MaxPerWindow` enforces
  `I >= floor(W/M)`, leaving a `W mod M` NANOSECOND slit. It multiplies now: `I*M >= W`, exactly, with an
  overflow ceiling on `MaxPerWindow`.
- **`CooldownAfterRollback` accepted zero**, which silently disables the rollback latch: `RecordOutcome`
  sets `HoldUntil = now` and `Now.Before(HoldUntil)` is false at that instant and forever. Every other
  duration in that validator is gated `<= 0`; this one was the exception, and the exception was a valid
  configuration in which a safety mechanism did not exist.

### Removed
- **The per-window budget guard, in both planners.** It could not bind: an act sets `LastRotateAt`, the
  cooldown then forces `Now - WindowStart >= MaxPerWindow * MinInterval` before a tick can reach it, and
  the window rolls at `>= Window`. Dead code that read exactly like enforcement — and the reason three
  separate attempts to test it produced three assertions that could not fail. `RotationReasonNoBudget`
  goes with it.
- The two tests that asserted it, both of which injected `RotationsInWindow = MaxPerWindow` — a state no
  schedule can produce, since reaching it needs two acts closer together than `MinInterval`.

### Found, and NOT fixed here — it is an operator decision
- **The anti-beacon cap bounds a TUMBLING window, not a rolling one.** With the shipped defaults
  (`30m x 2 == 1h`) the cooldown permits acts at 0, I, 2I…, so any rolling hour holds
  `MaxPerWindow + 1`. Measured, and measured to be **pre-existing**: the identical schedule overruns by
  the same margin on `e52813e`, which still contains the guard. Bounding the rolling window needs a
  STRICT inequality (`I*M > W`), which the defaults do not satisfy — making it strict means changing
  MinInterval, Window or the cap on three live nodes. Recorded in the test that measures it.

## [0.2.69] — 2026-08-06

> The two posture-shaped findings from Audit-0010. Both were claims stated in a document and enforced by
> nothing.

### Fixed
- **`live_artifact_posture.sh` could not see a non-boolean posture knob** (F-019). It builds its
  assertion set from `<proto>_enabled: true|false` greps, so `hysteria2_hop_ports` — the one knob that
  widens a node's observable port footprint — was outside it by construction, while THREAT-MODEL says it
  "must stay off by default" and development.md §2.2 item 11 makes widening the default posture a
  lockstep change gated exactly here. The gate now asserts the default is empty, and fails if a fresh
  node would advertise a range.

### Documentation
- **ADR-0038 §3 records the posture-conflict decision** (F-023): a node whose firewall posture is off
  while a range is configured FAILS the converge tail rather than logging and continuing. The state is
  genuinely broken — `reconcile_hy2_hop_nat` runs inside `harden_ufw` and never executes there, so every
  issued config advertises a range with no rule — and nothing else can report it. The run is explicitly
  NOT allowed to install the rule itself: `--no-harden` means this run does not manage the host firewall,
  and writing a nat rule anyway would substitute our judgement on the one subsystem the operator reserved.

## [0.2.68] — 2026-08-06

> The rest of the Audit-0010 tail. Two more were assertions that could not fail, one was a metric that
> reported success for work that had not happened, and one was a rule whose lifetime did not match the
> listener it serves.

### Fixed
- **The reserved-move rule now lives in the contract, not only in the planner** (F-016). It was two
  assignments inside `rotate.Plan`; nothing related `To.Action` to `To.ToPort`, so a plan from any other
  producer — a hand-written `rotate_plan.json`, a replayed stale plan — validated and moved a served
  port under an authorised action. `RotationPlan.Validate` refuses it. The reserved action itself stays
  REPRESENTABLE: it is unrequestable, not unexpressible, and the difference matters the day it is unreserved.
- **The netsim budget assertion could not fail** (F-012). `MinInterval` (30 min) is four times wider than
  the six 90-second ticks it ran over, so the cooldown blocked everything after the first act and the
  comparison was always `1 > 2`. That scenario now pins exactly one act (which is what the cooldown
  guarantees) and the budget has its own scenario, ticking past the cooldown so the cap is what binds.
- **`record_converge_ok` stamped success before the tail ran** (F-014). A tail failing on every tick kept
  advancing "last successful converge" — the one fact that separates a healthy node from one whose timer
  died. Both calls stay bare so `set -e` aborts before the stamp; wrapping the tail in `if` would have
  swallowed a fatal convergence failure into a silent success.
- **The hop REDIRECT did not survive a reboot** (F-008) while the ufw half of the same design did — one
  promise with two lifetimes. The sing-box unit reinstalls it in `ExecStartPre`, tying the rule's
  lifetime to the listener it serves. Non-fatal by construction, so a node without a range still starts.
- **The appointed owner had no behavioural test** (F-007). Its only coverage was a gate driving the SHELL
  comparator and a grep for the function's name — proof that it exists, not that it decides correctly.
- **The gate's function-body extraction silently inspected nothing** for nine functions (F-013), keyed on
  a literal `name() {` that misses padded alignment, and ran one-line bodies to the next `^}`. Rewritten
  with a bounded awk extraction plus a self-check: an empty body is now reported, not skipped.

### Documentation
- `common.sh`'s header names the third responsibility it acquired, with the reason it lives there (F-024).
- The measure config records that a hop range is unmeasurable from the node **by construction** (F-009):
  the anchor is the served port, the clients dial range ports, and the REDIRECT is `-i <wan>` in
  PREROUTING, which loopback never traverses. A green hysteria2 weight is not evidence that hopping works.

## [0.2.67] — 2026-08-06

> Audit-0010 tail: the second S1 and the load-bearing S2s. Two of them were defects in tests I wrote
> this week — one gate that accepted values its own owner rejects, and one row that skipped the branch
> it was written to cover.

### Fixed
- **The shell comparator accepted values the owner rejects** (F-006). Ownership had been collapsed for
  the NUMBERS and left restated for the SHAPE, so `001024:065535` and
  `0000000000000000000000000000002000:3000` passed the shell — `test -ge` parses base 10, so a
  zero-padded field clears every numeric check — while `ValidHysteria2HopRange` refused all of them. The
  field-digit cap is now emitted (`params_validation.max_port_field_digits`) and applied, and the value
  table carries the padded forms as regression rows.
- **`hysteria2_hop_interval` was operator-settable and judged by nobody** (F-005), contradicting the
  ownership rule ARCHITECTURE gained in the same commit range. A duration cannot be bounded by two
  integers, so the owner emits the SHAPE — an ERE — and both renderers fall back to the emitted default
  rather than letting a mistyped value reach sing-box, which refuses the whole document and turns an
  operator typo into a converge that fails every tick with a message about JSON.
- **The demote branch of the reserved-move fix was covered by nothing** (F-011). The row `t.Skipf`-ed:
  served was `{vision, grpc}`, both reality-tcp, which fold to ONE block family, so the independent-
  fallback floor refused and the planner held. A skip is indistinguishable from a pass. The fixture now
  ranks three distinct families, the row FAILS instead of skipping, and removing `to.ToPort = 0` from
  the demote branch is caught.
- **`verify_hy2_hop_nat` claimed more than it checked** (F-010). `grep -F -- "--dport $want"` matched a
  rule whose range merely BEGINS with the advertised one, so a redirect over `20000:210000` satisfied a
  check for `20000:21000` — the collision case, silently swallowing the excess. Anchored. And the
  success message said "verified" after inspecting the IPv4 table alone, on a project whose inbounds
  listen on `::` and whose address resolution falls back to IPv6; it now names the family it checked.

### Documentation
- **THREAT-MODEL gains the node-side half of the hop-range shape** (F-002, S1). ARCHITECTURE forward-
  references it for "the node's observable port footprint" and the section described only the client's
  cadence — a dangling pointer in the document RP-0017 designated as the deliverable. What a scanner
  sees is now written down: N contiguous UDP ports answering identically from one certificate, cheap to
  confirm once suspected, standing whether or not a client is hopping, and unreadable from the firewall's
  rule list because the REDIRECT precedes filter.

## [0.2.66] — 2026-08-05

> Audit-0010 (event-triggered, §4.4; six lenses, each adversarially verified) returned
> `pass_with_conditions`. This closes the two live-node harms that were reachable without a design
> decision. The S1 it found was produced by the previous commit's own fix.

### Fixed
- **A hop range containing another served UDP port is refused.** The single owner judges the range's
  ENDPOINTS and knows nothing about the node — so `1024:65535` validated cleanly while a REDIRECT over it
  swallows every inbound packet for tuic, shadowsocks and AmneziaWG. **Nothing on the node could report
  it:** every reach anchor is `127.0.0.1:<port>`, and loopback never traverses a `-i <wan>` PREROUTING
  rule, so the measure daemon would keep scoring the dead family alive and the rotation planner could
  promote it as the safe fallback. `reconcile_hy2_hop_nat` now refuses, naming the collisions — the one
  place that both knows this node's served ports and installs the rule.
- **The ufw admission for the hop range is removed.** It was malformed (`${_hop//:/\:}` emitted
  `20000\:21000/udp`, which ufw rejects) and it was unnecessary: nat/PREROUTING rewrites the destination
  port before filter/INPUT ever sees the packet — measured, not argued, since `tests/netsim/lib.sh` had to
  move its own impairments out of filter for exactly that reason. Its side effect was worse than its
  absence: the un-parseable range token in the served set made `verify_ufw_exposure` report a missing
  admission on every converge, forever.

## [0.2.65] — 2026-08-05

> The netsim harness §7.3 has required since the charter was written, and the first thing it measured
> disproved the sentence the hysteria2 hop range shipped on.

### Added
- `tests/netsim/` — two isolated network namespaces joined by a veth, a REAL sing-box on each side, an
  HTTP origin inside the server namespace, and the §7.3 impairment primitives (netem loss/delay/rate,
  UDP DROP, TCP RST injection). The fixture refuses to start unless it can prove the namespaces have no
  default route: these scenarios drop packets, and on a live node that guarantee is the whole safety
  argument. Deliberately NOT wired into `tests/run.sh` — §7.5 runs socket-bound suites on a node and
  records the result, and a green offline suite must not imply coverage that never ran.

### Fixed — a documented claim that was false
- **"A block on one UDP port no longer takes the family down" is false as stated**, and both
  ARCHITECTURE.md and THREAT-MODEL.md said it. sing-box hops on a TIMER: it does not avoid dead ports
  and has no signal that one is dead, so the client is down while it sits on a blocked port. Measured,
  two points at a 3 s interval: a range of 3 with 1 blocked gapped 6 of 24 samples (25 %); a range of 11
  with 1 blocked gapped 2 of 36 (6 %) — the outage fraction tracks blocked/total. **The range dilutes an
  outage rather than removing it.** Both documents now say so, and the corollary that a WIDER range
  dilutes better inverts the "prefer narrow" guidance into an explicit trade with no free side.
- Recorded alongside it: an intermittently working member is not a cleanly dead one. A urltest group
  re-selects on health, so a member answering most probes keeps its place while delivering periodic gaps
  — and nothing on the node reports that, because the member is genuinely alive most of the time.

### Fixed — in the fixture itself
- Impairments moved from `filter/INPUT` to `raw/PREROUTING`. The hop range arrives through a REDIRECT in
  `nat/PREROUTING`, and nat runs before filter — by the time a packet reaches INPUT its port has already
  been rewritten, so a filter rule naming the RANGE can never match. Every impairment in the first
  version was a no-op, and the scenario's own control row is what caught it. The same arithmetic applies
  on a real node: a host firewall rule written against the advertised range does not do what its author
  expects.

## [0.2.64] — 2026-08-05

> RP-0017 phase C. The rotation-loop change shipped two commits ago without the netsim scenarios
> development.md §14.3 makes mandatory for any such change. They exist now, with the SLO measured in
> ticks — and the socket/netem half is recorded as deferred with its reason rather than passed over.

### Added
- `internal/rotate/netsim_test.go` — the §7.3 signal patterns driven through the REAL planner with
  state carried forward tick to tick: RST injection, handshake timeout, post-connect throttle and full
  shutdown must each act exactly on the hysteresis boundary (no earlier, no later) and stay inside the
  per-window budget; an oscillating link must not produce one move per oscillation; a clean link must
  produce none at all — the control, without which every other row is consistent with a loop that
  rotates unconditionally. A final scenario asserts that no signal pattern makes the loop emit a port
  move, which is the scenario-level form of the reserved-move guard: the failure was never a single
  malformed call, it was the unattended loop ticking every 90 s on a value nothing resets.

## [0.2.63] — 2026-08-05

> RP-0017 phases D+E. Front configuration gets a single owner, and the documentation the earlier work
> owed and did not deliver — including the observable-shape assessment of a hop range, which is the one
> genuine cost of the feature and had never been written down.

### Changed
- `spec.LoadFrontConfig` accepts either a bare `FrontConfig` document or the node profile carrying one,
  so `node.config.json` (ADR-0034) is the single owner of front configuration and `front_setup` hands
  the profile to the spine directly. The derived `front.from-profile.json` is gone — materialising the
  profile's `.front` into a third file was the same one-truth-two-locations defect being removed.
- `front_setup` reads the enabled flag shape-aware; reading only the root would have reported "disabled"
  for every operator who configured the front where ADR-0034 tells them to.

### Documentation
- `ARCHITECTURE.md`: the hysteria2 row records the port-range dimension and that the rule making it real
  is invisible to every node-local check; Layer 2 gains the params-validation ownership rule and the
  reserved-move semantics (enforced on the field, not the action name).
- `THREAT-MODEL.md`: a new section assesses what a hop range COSTS — a client walking a contiguous port
  block on a fixed cadence is a distinguisher no ordinary QUIC client produces. Off by default, width
  keyed to an observed port-filter, prefer narrow, and the interval owned as a timing parameter (§4.1).

## [0.2.62] — 2026-08-05

> RP-0017 phases A+B. The hop-range rule had three hand-maintained implementations and a gate that
> policed their agreement — a duplicated source of truth (development.md §2.2 item 8) dressed up as a
> fix. It now has one owner, in Go, whose bounds are emitted into the vocab artifact the shell reads.

### Changed
- `internal/spec` is the sole owner of the hysteria2 hop-range predicate. Its bounds and the hop-interval
  default are named constants with a recorded basis (§1.1), emitted into `control/vocab.json` under a new
  additive `params_validation` block (ADR-0038).
- Both shell consumers — the client renderer and the firewall reconcile — delegate to one comparator in
  `common.sh`, the only file both shell entrypoints source. Neither holds any expression of the rule.
  A vocab without bounds, or no vocab at all, refuses every range: no `server_ports`, no REDIRECT.

### Added
- `docs/proposals/0017-params-knob-validation-single-owner.md`, `docs/adr/0038-params-validation-single-owner.md`.
- `tests/conformance/params_validation_single_owner.sh` replaces `hy2_hop_halves_agree.sh`. It asserts
  that no second implementation exists — function-scoped, because per-file was too coarse (it flagged
  libraries bounding an unrelated single port) and per-line was too narrow: a mutation restoring the
  parser into `_hy2_hop_range` never names the key again and left the per-line version fully green.

### Fixed
- `hy2_hop_redirect_kept.sh` sourced `nb_harden.sh` without `common.sh`, which the lib now depends on —
  every row read "no range" and the gate was testing a different program.

## [0.2.61] — 2026-08-05

> An audit of everything still marked deferred, reserved or known-unfixed. The headline: the `rotate-port`
> reservation was enforced on the ACTION NAME while the capability rode in under `promote-sibling`. Six
> more, three of them in gates written this week — including one whose header claimed a check it did not
> perform.

### Fixed
- **`rotate-port` was reserved in name only.** `Plan`'s promote branch copied the ranked candidate wholesale
  and normalised only `Action`, so a `to_port` reaching a candidate from the node-local measure config was
  emitted under `promote-sibling` — and the executor applies `.to.to_port` without consulting `.to.action`,
  with port keys in the operator allowlist so the move survives `write_params`. An unattended 90-second loop
  could move a served port that every issued client config still names, with no channel to re-fetch: the
  exact outage the reservation exists to prevent. The demote branch had defended itself since it was
  unreserved; this one never did. `to.ToPort = 0`, plus a planner test that asserts on the FIELD, not the name.
- **The Go unit test pinning the operator allowlist was left red** by the previous commit, and `make test`
  is the blocking half of CI. Every real regression until now would have arrived under a known failure.
- **`converge_node_tail` verified the hysteria2 redirect before the step that installs it**, and verified it
  unconditionally on a node whose firewall posture is off — where `reconcile_hy2_hop_nat` never runs at all.
  Ordering fixed; the posture-off case now reports the conflict (a range advertised to clients that this
  node is not permitted to make real) instead of asserting a rule nothing installs.
- **`spec.NodeProfile.Front` was declared, validated and reported by `node plan`, and consumed by nothing** —
  `front_setup` read only the standalone `front.config.json`, so an operator following the unified profile
  configured a front that never existed. The profile is now the fallback source; the standalone file still wins.

### Fixed — in the gates themselves
- `hy2_hop_halves_agree.sh` executed a `sed`-extracted copy of the client renderer's validation and its
  header claimed the copy's currency was checked. It was not. A second, unvalidated read added anywhere
  after the block would have left all 19 rows green. Now checked, both count and position.
- The same gate's round-trip row REPRODUCED `merge_operator_overrides` rather than driving it — so removing
  the key from the real reduce left the row green and the defect just fixed fully reintroducible. It drives
  the shipped function now.
- `rotate_rollback_executes.sh` "step 3" was a membership test satisfied by the Phase-B `write_params`,
  which always precedes Phase C. Deleting the rollback's own call left the row green. Now an ORDER assertion.
- `reach_method_matches_transport.sh` only ever iterated what was EMITTED, so a family dropped from the
  member enumeration vanished from both configs and passed — the two agreeing precisely because it was
  absent from both. The forward direction its own comment promised is now checked.
- `vocab_single_source.sh` printed "in sync with the Go source of truth" after SKIPPING the only check that
  establishes it. On every jq-only lane — including a node, where the committed file is authoritative and
  nothing regenerates it — it could not fail while claiming it had checked.

## [0.2.60] — 2026-08-05

> hysteria2 port hopping shipped as "off by default". It was not off — it was UNSETTABLE. The key was in
> neither the generated params object nor the Go-owned operator allowlist, so a hand-set range was erased
> by the next converge, i.e. by every timer tick. The capability existed, its gate passed, and no operator
> could reach it. Now settable, validated by ONE predicate on both sides of the promise, and verified
> end-to-end against a live node with a real client.

### Fixed
- **`hysteria2_hop_ports` could not be set by anyone.** `write_params` regenerates params.json from a fixed
  object and `merge_operator_overrides` honours only `spec.OperatorToggleKeys()`; the key was in neither.
  Both hop keys are now emitted as defaults and are operator-settable, and the overlay round-trip is gated.
- **The client renderer and the firewall judged the range by different rules.** The subscription renderer
  emitted whatever was configured; only `_hy2_hop_range` validated. An operator typo therefore reached every
  issued client config while no matching nat/PREROUTING rule existed — hysteria2 dead for the population,
  with every node-local check green, because `verify_post_apply` is firewall-blind (loopback traffic never
  traverses PREROUTING). All three deciders now share one predicate, `spec.ValidHysteria2HopRange`.
- **Both shell halves accepted `2000:3000:4000`.** `${r%%:*}`/`${r##*:}` take the OUTER fields, so lo=2000
  and hi=4000 — in range, lo<hi — and the value reached iptables verbatim as `--dport 2000:3000:4000`,
  which it refuses. A value that passes validation and cannot become a rule is precisely the disagreement
  the validation exists to prevent. Go already rejected it.

### Added
- `tests/conformance/hy2_hop_halves_agree.sh` — drives all three deciders over one 19-row value table and
  fails when any two disagree. Plus the GENERAL form of the unsettable-knob defect: every params key the
  renderers consume must be reachable by one of the three legitimate routes (generated by `write_params`,
  in the operator allowlist, or stamped by a dedicated posture step), so the next knob added cannot repeat it.

### Verified on a live node
- The range was enabled through the operator overlay, survived a converge, produced both halves (client
  `server_ports: ["20000:20100"]` and `-A PREROUTING … --dport 20000:20100 … REDIRECT --to-ports 8444`),
  and carried real traffic: a sing-box client on a SECOND host reached HTTP 200 through it, with the
  REDIRECT rule's own packet counter incrementing — the proof the range, not the fixed port, was dialled.

## [0.2.59] — 2026-08-04

> The rotation's rollback branch had never been executed — by anything. It is the node's whole safety net
> for an unattended rotation, and every assurance about it came from reading it. It now runs in the suite,
> on both failure edges, and the run found that its closing message claimed the rollback had been recorded
> on four paths where it had not.

### Added
- `tests/conformance/rotate_rollback_executes.sh` — drives the REAL `rotate_apply_live` through both ways a
  live apply fails (the restart itself; the health check after it) and asserts the whole recovery sequence:
  last-known-good bytes restored, the operator-overrides overlay byte-reverted, params regenerated, the
  service restarted onto the restored config, the rollback budget spent and the hold latch armed, and a
  fail-closed exit. Plus three rows nothing else covers: a recovery step that itself fails must not skip the
  ones after it; a degraded bookkeeping step must not undo the recovery; and a HEALTHY apply through the
  same harness must roll back nothing — the control row, without which every assertion above is equally
  consistent with a harness in which nothing can succeed.

### Fixed
- **`rotate_apply_live` told the operator the rollback was recorded when it was not.** The closing `die`
  said "rollback recorded" unconditionally, while `record_rotation_rollback` degrades to a warning on four
  separate paths (no spine binary, no limits, unassemblable input, a refused `rotate-record`). On each of
  them the budget was unspent and no hold latch armed — and the latch is the only thing that stops a node
  which *cannot* rotate from restarting sing-box every 90 seconds. `record_rotation_rollback` now returns
  non-zero on every unrecorded path (never fatal — a bookkeeping failure must not undo a completed
  recovery) and the message is written from that result.

## [0.2.58] — 2026-08-04

> hysteria2 port hopping: a range the client is handed UP FRONT, so the served port can move inside it
> and no client has to learn anything. Off by default; a node that does not configure a range renders
> byte-identically to one that never heard of the feature.

### Added
- **`hysteria2_hop_ports` / `hysteria2_hop_interval`.** When set, every issued sing-box config carries
  `server_ports` + `hop_interval` on the hysteria2 outbound. Verified against sing-box 1.13.13: this is
  the ONLY family that accepts a range — tuic rejects `server_ports` as an unknown field — so the
  capability is one protocol wide and the changelog should not pretend otherwise. Both renderers emit it
  byte-identically.
- **The server half is a REDIRECT, and it reconciles.** The hysteria2 INBOUND cannot listen on a range
  either (same verification), so nat/PREROUTING delivers the range onto the single served port. It
  reconciles rather than appends: `harden_ufw` never removes anything, so a range that CHANGED would
  otherwise leave the old redirect pointing at whatever it used to.
- **`verify_hy2_hop_nat`, fail-closed, in the converge tail.** The range is a promise the CLIENT CONFIG
  makes and the FIREWALL keeps, and nothing else on the node can see whether it is kept: post-apply
  verification checks the service is active, the socket is bound and a LOOPBACK handshake completes —
  and loopback traffic never traverses PREROUTING. A missing or drifted rule would kill hysteria2 for the
  whole population with every green light still green.
- `tests/conformance/hy2_hop_redirect_kept.sh` — a value table over range parsing (malformed and
  out-of-bounds yield NO rule), install, replace-on-change, remove-on-clear, and the three ways
  verification must notice: no rule, wrong range, wrong port.

### Note
- `rotate-port` stays reserved. The mechanism now exists for hysteria2, but unreserving it means an
  unattended loop moving a served port behind a firewall rule; that comes after the redirect has run
  in production, not in the same change that introduces it.

## [0.2.57] — 2026-08-04

### Changed
- **The client urltest interval drops from 5m to 90s**, matching the node's own rotate tick so the system
  has one control period instead of two. The interval is what a client's blackout costs: sing-box's
  urltest re-selects on its interval and on nothing else, so an outage shorter than the interval produces
  no failover at all. It also bounds recovery from a block the NODE CANNOT SEE — the case this product
  exists for, where the client's own re-test is the entire recovery mechanism.
- **Measured, not assumed.** Same fault, same vantage, before and after: **276s of total blackout at 5m,
  169s at 90s.** Not 90s — the interval sets how often the group re-tests, and the re-test must itself
  time out before the member is abandoned. sing-box exposes no per-test timeout (its urltest surface is
  interval / tolerance / idle_timeout / interrupt_exist_connections, verified against the 1.13.13
  binary), so ~169s is near this mechanism's floor.
- `idle_timeout` stays 30m: the group stops probing when nothing uses the tunnel, so a shorter interval
  does not turn an idle client into a heartbeat.

### Fixed
- **A conformance check restated the interval as a literal.** `control/selftest.sh` asserted
  `interval=="5m"`, so a deliberate, measured retune read as a regression — and the obvious way out is to
  edit the number in the test, which is how a check stops checking. The three knobs now live in
  `control/lib/urltest_defaults.sh`, a values-only file both the renderer and the check source. Not the
  renderer itself: `render_singbox.sh` calls `myc_vocab_protos` at top level, so sourcing it standalone
  dies command-not-found — the cross-lib dependency a gate sourcing a lib always trips over.

## [0.2.56] — 2026-08-04

> Two gate rows that asserted nothing, and the broken seam that made the rotation rollback path
> untestable in the first place.

### Fixed
- **The documented test seam killed its own caller.** `MYC_NB_NO_DISPATCH=1` is meant to let a test
  SOURCE `node-bootstrap.sh` and exercise the functions the entrypoint defines — `verify_post_apply`
  among them. The trailing `exit 0` sat OUTSIDE the guard that skips dispatch, so sourcing exited the
  sourcing shell and no test could ever reach those functions. That is precisely why the rotation
  rollback branch has never been executed by anything: it was unreachable, not merely uncovered.
- **`rotate_apply_executes` row 4 asserted nothing.** It narrowed `OPERATOR_TOGGLE_KEYS` so that neither
  the enable key nor the port key was allowed, so `apply_rotation_to_params` aborted at the enable-key
  resolution and `_rotation_port_key_if_moving` was never reached — the port read its original value
  because NOTHING RAN. Proven by deleting the port-key guard outright: the gate stayed fully green. The
  row now allows the enable key and excludes only the port key, and the same mutation fails it.

### Known, unfixed
- `fp_ab_probe_producer`'s final row is vacuous by the same mechanism: deleting the rc-2 break in
  `nb_selftest.sh` leaves the gate green. Its expectation is byte-identical to the preceding row's, so
  it cannot distinguish the case it names.

## [0.2.55] — 2026-08-04

> **Rotation can finally do something.** The move that works is the one that was dismissed as having no
> successor semantics: stop serving the broken member and let the client — which already holds every
> endpoint and health-checks them itself — move to one of its own accord.

### Fixed
- **The executor was ACTION-BLIND.** `nb_rotate_apply.sh` never read `.to.action` — zero occurrences —
  and `_rotation_set_delta` hardcoded `.[$ek] = true`. The first `demote-active` a planner emitted would
  have ENABLED the transport it had just decided to stop serving, unattended, every 90 seconds. The
  action is now load-bearing and an unrecognised one fails closed rather than being guessed at.
- **A `die` inside `$( )` kills only the substitution.** `_rotation_enable_key` refuses a proto whose
  enable key is outside `OPERATOR_TOGGLE_KEYS`, and that refusal arrived at the caller as an empty
  string — which the delta then wrote into params as a key literally named `""`. A fail-closed that did
  not close, quietly corrupting the file it was protecting. Found by a leaking test fixture, which is
  now also fixed: a narrowed toggle surface no longer escapes the row that narrowed it.

### Added
- **`demote-active` is unreserved**, gated on `DemoteKeepsIndependentFallback`: after ceasing to serve a
  member, the INTERSECTION of what the node serves and what issued clients hold must still span >= 2
  independent block families. The floor is over the intersection, never the served set — see the test
  for the config that satisfies a served-set floor while stranding every client already holding one.
  Unknown baseline fails closed: not knowing what was issued is not permission to remove something.
- **The issued baseline is stamped** at every subscription render, by BOTH renderers. A Go half that did
  not would make the move go silently mute the moment the strangler cuts over.
- Value-table tests for the floor, the executor's action handling, and the empty-key refusal.

### Changed
- The `e2e_recovery` invariant — "a rotation can never reduce the served family set" — moves out of a
  doc comment and into an executable precondition. Prose cannot fail a build.
- `rotate-port` and `regen-reality` stay reserved, now for a stated reason rather than an assumption:
  both change what a client must DIAL, and unlike a demote the client cannot discover the new value from
  a set it already holds.

### Fixed
- **`--awg-revoke-peer` reported "already clean" for a peer that was in the config.** It matched the
  PublicKey line with an ERE built from the key itself, and a base64 key contains `+` — an ERE
  metacharacter — so the pattern silently failed and the operator was told the credential had never been
  there. Found on a live node while VERIFYING a cleanup rather than trusting its message; the gate could
  not see it because every fixture key was letters and hyphens. Keys are compared as field VALUES now,
  and a fixture key carries `+` and `/`.

### Fixed
- **A demote spent no budget.** The promote branch advances `LastRotateAt`, increments
  `RotationsInWindow` and clears the impaired streak; the demote branch did none of it. The 30-minute
  cooldown never bit, the two-per-hour anti-beacon cap was never spent, and an uncleared streak made the
  very next tick qualify again — an unattended loop free to demote a transport every ninety seconds, on
  a node whose entire design is to not beacon. **Found by the first real execution of the apply path**,
  not by a review that had read the same code twice.

### Measured
- A real client on one node, through another node's `urltest` group, with the active member's port
  DROPped: dead at once, recovered **276 s later with the port still blocked** — one full urltest
  interval. Failover works and costs up to one interval of total blackout; an outage shorter than the
  interval produces no failover at all.

## [0.2.54] — 2026-08-03

> **Two of three nodes held a UDP port open with nothing behind it, and it was the WireGuard default.**
> `$STATE_DIR/awg.port` exists so the firewall knows which port to admit. It was written once at
> bootstrap with the canonical default and never with the port the node ended up using.

### Fixed
- **The AmneziaWG port is resolved from the LIVE config, not from a remembered default.** Measured:
  m1 had no marker at all, so the firewall's AWG branch never fired; m2 and m4 held `51820` while
  `awg0.conf` listened on `443`, so ufw admitted a silent port and never admitted the real one on this
  transport's account. Worse than a wasted rule: 51820 is the WireGuard default, so a host with it open
  and SILENT while the tunnel runs elsewhere announces "there is WireGuard here" without serving it — a
  distinguishing mark on a node designed to carry none. The marker is now a CACHE of the config and is
  corrected on every resolution; `harden_ufw` no longer requires it to exist.

### Added
- **`LoopDrift` + `myceliumctl loop-drift`** — reconciles the loops a node profile REQUESTS against the
  loops actually running. The profile's `loops` field is a request that nothing consumes (arming is a
  node-local sentinel, never a committable file — the RP-0012 triple gate, and that is right). The
  consequence nobody stated: the field can say one thing while the node does another and nothing
  notices. All three live nodes declared every loop `false` while all three were running. A declaration
  that cannot be enforced must at least be reconciled and reported, or it is worse than absent — absent
  says nothing, stale says something false. Advisory, never fatal.
- Each loop's owning module now exposes a `*_loop_running` predicate, so the converge asks rather than
  naming a unit. Two gates enforce that and both are right: a second file naming a unit is a second
  thing that could arm or stop it. The update loop is deliberately NOT probed — its unit has no in-tree
  owner and `update_unit_template_shape` refuses any tracked reference precisely so nothing claims one
  by accident.
- `tests/conformance/awg_served_port_is_real.sh` — a value table over (config port, marker) including
  both live states verbatim, asserting the config wins, the marker is corrected, a malformed value never
  propagates, and repeated resolution is stable. Mutation-verified.

### Fixed
- `timer_trigger_form` identified a unit's path-helper by any one-line function that MENTIONED the unit.
  Adding a `rotate_loop_running` predicate was enough to make it hunt for a heredoc written by a
  function that writes nothing, and report the real emitter as unexaminable. It now requires the helper
  to actually print a systemd path. Still checks all five emitted timers.

## [0.2.53] — 2026-08-03

> The AmneziaWG revoke DECISIONS move out of bash. Not tidiness: every one of them was wrong in bash at
> least once, in ways a value table finds instantly and an awk rewrite hides.

### Added
- `internal/spec/awg_revoke.go` — `ParseAWGConf`, `AWGRevokeTargets`, `StripAWGPeers`, `VerifyAWGStrip`,
  `CountAWGDialectLines`, `AWGRevokeNeeded`. Pure, table-tested. The shell keeps only the EFFECTS:
  removing a peer from the running interface, writing files, restarting units.
- `myceliumctl awg-revoke-plan` and `awg-strip-peers`. The strip VERIFIES its own output before a byte
  reaches stdout — strip and check are one call deliberately, because a caller that can obtain the
  rewrite without the arithmetic will eventually promote an unverified one.
- `tests/conformance/awg_revoke_go_equiv.sh` — byte-equivalence across a matrix built from the shapes
  that produced each real bug: a key that is a prefix of another, `PublicKey=K` with no spaces, a name
  marker that FOLLOWS the key, an unnamed peer, and a config already carrying the blank-line bloat the
  old stripper produced.
- The revoke gate now also asserts the Go producer and the shell fallback yield the same config byte for
  byte. Otherwise a machine with Go never exercises the fallback and a machine without it never
  exercises Go — whichever this host lacks would go untested forever.

### Fixed
- `VerifyAWGStrip` derives "how many peers should have gone" from the peers actually PRESENT in the
  before-config, not from the length of the removal request. Naming a key the config does not carry is a
  no-op, not an error — and the request may legitimately name one twice.

## [0.2.52] — 2026-08-03

> **Correcting v0.2.50.** An independent review of the revoke verb shipped hours earlier found three real
> defects, all confirmed on live nodes. The worst is the one this project has spent the day hunting: the
> verb printed a guarantee it had not established.

### Fixed
- **`--awg-revoke` could report success while a peer it never saw stayed valid.** A `[Peer]` block with
  no `# name =` marker is reachable by neither resolution path, and one exists on a live node — holding
  a key whose private half is still stored on that same host. The closing "is revoked" line printed
  unconditionally. It is now gated: an unreachable peer means a non-zero exit, no guarantee, the peer's
  public key printed, a `REVOKE_INCOMPLETE` marker written, and the exact command to finish the job.
- **`--awg-revoke-peer PUBKEY`** — the only way to retire a peer no name can address.
- **The strip was not idempotent.** It captured the blank line between sections into the preceding block
  and re-added one when emitting, so every pass grew the file by one blank per surviving peer, without
  bound: five no-op passes over a live 31-line config produced 41 lines. The v0.2.50 gate could not see
  it, because after the first revoke the name owns nothing and the second call short-circuits before the
  stripper runs. A no-op strip is now byte-identical to its input.
- **The live removal was assumed, not verified.** Failures were downgraded to a warning whose own text
  pre-excused them, and the guarantee printed regardless — including when nothing had been removed. The
  interface is now read back; a surviving peer fails closed with nothing written to disk.
- **The verb's own snapshot outlived it.** `awg0.pre-revoke.conf` holds the server private key and every
  peer block; `--awg-issue` deletes its equivalent on success and this one kept it forever (found on a
  live node). Removed on the success path.
- Public keys are matched with the separator normalised: `PublicKey=KEY` is legal syntax that a rule
  anchored on `PublicKey = ` cannot see — which here means failing to revoke while reporting success.
- Backup copies are only rewritten when they actually change, so an untouched restore source keeps its
  mtime and it stays visible which backups a revoke really reached.
- The DRY-RUN discloses unreachable peers too. Withholding "there is a peer I cannot reach" until after
  the operator commits defeats the only purpose a dry run has.
- The verb no longer claims to "shred" what it `rm -f`s.
- **The remaining review items, all of which I had left undone.** An evidence sweep that derives
  `awg pubkey` from every `*.private` and every nested `private_key` in every `*.json`, under BOTH state
  roots — `$STATE_DIR` and `/var/lib/mycelium/amneziawg`, the Ansible role's `awg_state_dir`, which is
  where a live node held the private half of a peer the bash path could not see. The guarantee is now
  withheld while any such key survives. A cross-family warning, because `--revoke` and `--awg-revoke`
  are separate namespaces and both hold a `phone` on the live nodes. Serialisation against the L7 AWG
  probe, which mutates the running interface every ~120s. A sanity check with teeth: peer arithmetic,
  a non-blank line count that must fall, and a dialect-line count that must not change. And an early
  return that consults the backups, since a peer surviving only inside one is exactly what a failed
  dialect rollback restores.

### Fixed elsewhere
- **`exec 200>file 2>/dev/null` silences stderr for the rest of the process.** `exec` applies every
  redirection on its line to the shell itself, so the L7 AmneziaWG probe — which `verify_post_apply`
  calls on the converge path — was discarding every `warn` and every `die` that followed it. Proven by
  writing to stderr either side of the line: the first appears, the second does not. Both sites now
  pre-test that the lock file is openable and redirect only the lock fd.
- **`grep -c` prints `0` AND exits 1 on no match**, so the `|| printf '0'` fallback in
  `_awg_dialect_lines` appended a SECOND zero and every arithmetic comparison was reading `"0\n0"`.
  This is what made the new sanity check reject a correct rewrite.

### Added
- Five gate sections for the above, including a stateful `awg` stub that models a removal which reports
  success and does not take. The v0.2.50 gate also ran without the library's `log`/`warn`/`die`, so
  `die` was a command-not-found that RETURNED — every fail-closed path under test silently continued.

## [0.2.51] — 2026-08-03

> **The rotation apply path had never executed.** Not "was not covered by a test" — had never run, on
> any node, ever. The loop fires every 90 seconds and had returned HOLD every time for months, and a
> live fault-injection drill walked the planner through `active-clean → streak-too-short →
> no-better-candidate` without ever reaching an act plan. This is the code that would run for the first
> time during a real outage.

### Added
- `tests/conformance/rotate_apply_executes.sh` — RUNS `apply_rotation_to_params` over a value table
  instead of reading it: promote-sibling onto an already-enabled proto (a no-op, which is exactly why
  the live path short-circuits), onto a disabled one (the enable key flips and nothing else), a plan
  carrying `to_port` (the port really moves — the executor half that existed and had never run), a port
  key outside the operator toggle surface (not moved: an unattended loop may not reach past the
  operator's own switches), and a plan with no target (fails closed, params byte-unchanged).
  Mutation-verified against four reintroductions.
- The same gate refuses a **phantom move**: every member of the `RotationAction` closed set must either
  be assigned somewhere in production Go or be named in a RESERVED list with the reason it is held back.

### Documented, not changed
- Three of the five declared rotation moves — `rotate-port`, `regen-reality`, `demote-active` — appear
  in production code exactly once each, inside the validity switch. Nothing assigns them. They are now
  RESERVED with their reasons rather than looking like capability the project has.
- `rotate-port` is deliberately still unrequestable. The executor half is complete and now proven by
  test, but emitting it unattended would change a served port while every subscription already in a
  client's hands names the old one, and the rendered bundle is served on loopback only — there is no
  live channel for a client to learn the new port. That channel is the prerequisite, not the planner.

## [0.2.50] — 2026-08-03

> **The node could issue AmneziaWG clients and had no way to un-issue one.** Every peer ever enrolled
> stayed valid forever; retiring a leaked key meant hand-editing `awg0.conf` on a live node, which is
> the operation most likely to leave the interface unable to come up.

### Added
- **`--awg-revoke NAME`** — retires an AmneziaWG credential everywhere it is honoured. Order is the
  design: the RUNNING interface is cleared FIRST with `awg set ... peer ... remove`, so the key cannot
  handshake even if every later step fails; the reverse order leaves a window in which the operator has
  been told "revoked" while the key still works. No interface restart, so other peers keep their
  sessions. It resolves the peer BOTH by the stored key and by the `# name =` marker, because
  `--awg-issue` keys re-issue on the presence of `clients/NAME.private` and therefore enrols a SECOND
  peer under the same name when that material is missing — a state reached on a live node. It then
  shreds the stored material and purges the dialect backups, because `_awg_rollback` restores both
  `awg0.conf` and `clients/` from `backup-*/` on a failed regen/rotate and would otherwise resurrect the
  peer and its private key. Idempotent; revoking a name that owns nothing is a success.
- `tests/conformance/awg_revoke_is_final.sh` — executes the verb against a throwaway node root with a
  recording `awg` stub. Mutation-verified against five reintroductions, including "clears the file but
  not the running interface" and "resolves only by the stored key".

### Fixed
- The revoke's own post-rewrite sanity check compared public keys by substring, so a key that is a
  prefix of another reported as still-present and aborted a revoke that had in fact succeeded. Found by
  mutation-testing the gate, not by reading the code.

## [0.2.49] — 2026-08-03

> **The two transports most likely to survive a block were the two the failover mechanism could never
> choose.** hysteria2 and tuic reported 0 successes against 8 failures on every node, permanently,
> since the measurement plane was enabled — because their reachability anchor probed a UDP-only
> listener with a TCP connect. A real off-host client carried HTTP 204 through both the whole time, and
> the node's own L7 probe (which does speak QUIC) reported both alive. Three signals; the wrong one won.

### Fixed
- **`generate_measure_configs` emitted `method: "tcp"` for every member.** The method is now derived
  from the transport CLASS, and a UDP class with no method that can express it fails the generator
  closed instead of silently receiving one that cannot. A confidently wrong measurement is worse than
  none: eight real failures are not an empty window, so the assembler's zero-sample guard — which
  exists precisely so silence is never read as a black-hole — could not help. The tuner floored both
  weights and the planner marked the pair `promoted:false`.
- **`myceliumd` was replaced on every converge and never restarted.** `install_tooling` overwrites the
  binary each 15 minutes while an enabled `mycelium-measure` keeps executing the unlinked inode: every
  `/proc/<pid>/exe` on all three nodes read `(deleted)`, and one node served version 0.2.29 — 27 days
  and 97 commits behind its own disk. The rotate loop re-execs `myceliumctl-go` fresh every 90s, so
  PlanInput was assembled by old code and the plan computed by new code on the same tick. `measure_enable`
  already restarted for exactly this reason; the reasoning was right and applied at only one of the two
  sites that replace the binary.

### Added
- `internal/reach.MethodQUIC` — a UDP liveness probe that sends a QUIC long-header packet carrying a
  version no implementation supports, so RFC 9000 §6 obliges a server to answer with Version
  Negotiation. ALIVE is a datagram arriving, DEAD is the ICMP port-unreachable a connected UDP socket
  surfaces as ECONNREFUSED: both verdicts are observations. `net.Dial` on UDP is connectionless and
  would succeed against a dead port, which is the same lie inverted — the closed-port test forbids it.
- `tests/conformance/reach_method_matches_transport.sh` and `internal/reach` QUIC probe tests, both
  mutation-verified, including the one-sided "fix" that switches every family to the QUIC probe.

### Verified live
- hysteria2 and tuic went from 0/8 failures to 2/0 successes on a live node and now rank
  `promoted:true` at the top of the rotation candidate list.

## [0.2.48] — 2026-08-03

> **A client could reach the node's own loopback services from the internet.** Measured, not theorised:
> from a second host, through a `vless-xhttp-tls` subscription, `http://127.0.0.1:9100/metrics` on the
> TARGET node returned HTTP 200 and 59868 bytes of real node_exporter output; `127.0.0.1:9551`
> (`myceliumd`) answered 404 and `127.0.0.1:9090` (the sing-box Clash API) answered 401. All three are
> bound to loopback precisely so that cannot happen. `169.254.169.254` was reachable by the same path.

### Fixed
- **The xray engine forwarded everywhere.** `nodes/dataplane/vless-xhttp-tls/xray.server.template.json`
  had no `routing` key at all and a single untagged `freedom` outbound, and the live config on every
  node matched it exactly. It now blocks private, loopback, link-local, CGNAT and reserved destinations
  and bittorrent, through a tagged `blackhole`. The sing-box engine was never affected — it has carried
  `{"ip_is_private":true,"outbound":"block"}` all along. Two engines serve the same clients from the
  same node and only one had the guard.
- **`geoip:private` is no longer used.** The REALITY template expressed the same control through a geo
  asset that no node carries, so xray refused to load that config (`failed to open file: geoip.dat`) —
  which is exactly how a security control becomes invisible. Both templates now use literal CIDRs and
  need no asset. This is also why `validate_configs` failed on every node; it now passes because the
  control is present and loadable, not because the check was relaxed.

### Added
- `tests/conformance/private_destinations_blocked.sh` — per engine, from a rendered server config:
  a destination-IP rule exists, its outbound TAG actually resolves (a rule aimed at an undefined tag
  forwards while reading like a block), the rule needs no external geo asset, and — computed with
  `ipaddress`, not asserted as text — every address in a value table of internal destinations falls
  inside the blocked set while ordinary public addresses do not. Mutation-tested against six
  reintroductions, including dropping only `169.254.0.0/16` and blocking `0.0.0.0/0`.

## [0.2.47] — 2026-08-03

> **Four of six served protocols carried no traffic for any client, while every node reported them
> alive.** Found by running a real sing-box client from a second host against one protocol at a time
> (`tests/e2e/protocol_matrix_probe.sh`) instead of asking each node about its own listeners. The
> listeners were never the problem — the config the node HANDS OUT was, and nothing compared the two
> halves the node emits. Verified fixed end to end on all three nodes: 6/6 in both directions.

### Fixed
- **hysteria2 and tuic were undialable in every subscription ever issued.** One shared `plainTLS`
  helper served both the TCP and the QUIC families, so both QUIC outbounds carried `tls.utls`. uTLS
  rewrites a TCP TLS ClientHello and has no QUIC path; sing-box refuses such an outbound outright
  (`unsupported usage for uTLS`) rather than ignoring the key. Split out a QUIC TLS helper in both
  renderers. `sing-box check` passes on the broken form, which is part of why it survived.
- **ShadowTLS failed x509 on every connection.** The handshake outbound verified the donor's
  certificate against the node's own `tls_sni`; ShadowTLS relays the DONOR's real certificate. Now
  emits `donor_sni`.
- **Shadowsocks was silently dropped.** The public inbound is SS-2022 multi-user (a server PSK *and* a
  users list), so the client owes the pair `<serverPSK>:<userPSK>`; a bare PSK is not rejected — the
  server cannot derive the session key and drops the connection with no error on either side.
- **The Shadowsocks inbound behind ShadowTLS is single-user** and takes the bare server PSK, not the
  per-client one. Both forms are live on every node at once; the emitted credential now follows the
  inbound's shape.
- **Clash output**: TUIC sent the client's UUID as its password (wrong whenever an identity carries its
  own password), and Shadowsocks sent a bare PSK. Both corrected in the Go and shell renderers.

### Added
- `tests/conformance/client_server_credential_agreement.sh` — renders the server config and the client
  subscription from the SAME params and asserts they agree: every credential, every verified SNI, and
  no TLS option a transport cannot use. Expectations are DERIVED FROM the rendered server config rather
  than hardcoded, because the correct Shadowsocks credential form depends on the inbound's shape and
  both shapes ship at once. Mutation-tested: reintroducing any of the four defects above fails it.
- `tests/e2e/protocol_matrix_probe.sh` — a real client, off-host, one protocol at a time, no `urltest`
  group. The failover group that makes a subscription resilient is exactly what hides a dead member.

## [0.2.46] — 2026-08-01

> **Version resynchronisation.** The version sat at 0.2.29 for 27 days and 97 commits (67 of them
> `feat`/`fix`) because the bump is a manual step in the release procedure and no release was cut. The
> gate that exists checks that `spec.Version` and the newest CHANGELOG heading AGREE — which is
> trivially satisfied while both are frozen — so nothing noticed. This entry folds the whole backlog
> under one version rather than reconstructing seventeen bumps that never happened; the number comes
> from this repository's own demonstrated rate (~4 `feat`/`fix` commits per patch across 0.2.17→0.2.29).
> `version_changelog_sync.sh` now also refuses a non-empty `[Unreleased]`, which is the condition that
> would have failed on every one of those 27 days.
### Changed
- **`fungi deploy` no longer arms unattended config promotion.** Rotation is protected by a triple gate —
  dry-run by default, `--apply-rotation` required, and a node-local `rotate-live.enabled` sentinel — and
  the doctrine around it said a deploy could never actuate a node. That was true of the auto-pull path and
  false of the documented deploy command: `fungi deploy` placed the sentinel, and the rotation loop's own
  unit hardcodes `--rotate --apply-rotation` in its `ExecStart`, so one command satisfied all three legs,
  with no prompt and no `--yes`, and the first tick fired during the deploy itself. Every leg was present
  and correctly nested; one caller simply supplied all of them.

  The default now brings up **detection** — the measure plane, the L7 liveness probe, and the rotation
  loop — which plans and reports and **refuses to promote**. Unattended promotion is `--auto-rotate`.
  `--no-arm` is unchanged (none of the three). Existing armed nodes are unaffected: the sentinel is
  node-local state that no push can add or remove.

  `tests/conformance/fungi_scoped.sh` now drives the real script against a recording stub and asserts the
  resulting argv for all three invocations, instead of grepping that an arm chain exists — existence was
  what it checked, and existence is not posture.

### Fixed
- **An unattended updater had no memory of what had already failed, so it could flap forever.**
  `sing-box check` validates schema; `verify_post_apply` is what catches a candidate that fails at
  *runtime* — a port already taken, a cert unreadable under the service sandbox, a bind failure. The
  rollback that follows is correct but keeps no record, and `merge --ff-only` is a no-op once merged,
  so the checkout stays at the same revision and the next tick re-renders the identical candidate. On
  a timer that is promote → restart → fail → roll back → restart, on every tick, indefinitely. The
  failed update was always contained; the **flap** was the damage, at two data-plane restarts per
  tick, each dropping live client connections.
  `flow_update` now declines to re-promote a candidate byte-identical to the one that last failed,
  for a bounded, escalating hold — `clamp(1h, 6h, how long this same candidate has been failing)`,
  derived from two file mtimes so there is no counter and no JSON to parse on a root-privileged path.
  Steady state drops from roughly 192 restart-pairs a day to four. The key is the **bytes, not the
  revision**: `verify_post_apply` fails on what was promoted, so a push that changes what this node
  renders escapes the hold immediately, while an unrelated commit cannot reset it to zero — which on
  a branch-tracking node would defeat the guard entirely.
  It is deliberately fail-**safe**, not fail-closed: a throttle over an already fail-closed path can
  only decline to re-apply something that already failed *on this node*, so its own failure (no
  snapshot, unreadable mtime, absent `stat`/`date`, a clock that moved backwards) falls through to
  promote — the worst case of a broken guard is exactly the previous behaviour. It can never become
  permanent: the hold expires and the candidate is retried unconditionally, `--ack` and `--node-apply`
  are never gated, and a node fixed out of band self-clears on the byte-identical path and goes green
  with nothing to clean up. A guard that could wedge updates would be worse than the flap it removes.
  Pinned by `update_flap_guard` (9 assertions; 8 fail on the unpatched tree), which checks not just
  that the refusal exists but that it stays bounded, capped, self-clearing and narrow.
- **Three paths that promote a config each converged a different subset of the node — including one
  that left a revoked client live.** `flow_node_apply` ends with a convergence tail: reconcile the
  xray engine, reconcile the firewall, re-render the served bundle. The other promote paths each
  carried a different fragment of it, and the gaps were invisible because every one of them logged
  success. `flow_update` reconciled sing-box and the bundle but never the xray engine or the
  firewall — and it reached even the bundle only on the apply branch, returning early whenever the
  rendered candidate was byte-identical, which is *most* ticks on a cadence. `flow_ack` — the
  stricter, operator-gated mode — promoted a staged candidate and converged **nothing**. Worst,
  `flow_revoke` re-rendered the sing-box config and the bundle but not the xray config, which is
  rendered from `identities.json` and carries client UUIDs: a revoked client stayed **valid on the
  xray inbound** of every xray-serving node until someone happened to run `--node-apply`, while that
  same code path logged that the UUID was "gone from every inbound". Verified live on a node: the
  xray inbound does carry the identity.
  All four now end in one shared `converge_node_tail`. The order is load-bearing — xray first,
  because `harden_ufw` reads the xray config's ports and would otherwise open the previous set;
  firewall second; bundle last, so the served distribution only describes a node that is already
  live and already reachable. Every step is idempotent and self-no-ops, which is what makes it safe
  on a timer: the xray step returns immediately on a node with no xray family enabled. The
  byte-identical short-circuit is now a flag rather than a return, so a change that touches only the
  xray or firewall side still converges. `--staged` deliberately keeps no tail (nothing is promoted;
  the ack carries it). Two gates were updated rather than worked around: the served-bundle check was
  branch-blind and reported green while the bundle was skipped on every byte-identical tick, and the
  xray "no auto path starts xray" ban would have been evaded by one level of indirection, so it now
  also asserts the stock-node guard is the first statement of the function the tail calls. Four
  mutations verified caught.
- **The one unit nothing owns had drifted on two live nodes, and the documented install procedure
  would have armed it.** `mycelium-update.{service,timer}` are the only systemd units here with no
  code path behind them: every other unit is written by a heredoc in `control/lib` and rewritten on
  every apply, while these two are templates the operator copies by hand (RP-0003 workstream W3).
  Nothing reconciles a deployed copy — not `--node-apply`, not `--update`, not any gate — so a local
  edit persists forever and is invisible to a suite that can only see the repo. Two nodes were found
  carrying a hand-written unit predating the shipped template (no `[Install]` section at all) whose
  `ExecStart` had grown `--insecure-no-verify`, a literal node address and a client list. That flag
  makes `verify_signed_ref` return before it checks anything — ADR-0015's provenance gate — so the
  unit was one `systemctl enable` away from a periodic, root-level, unauthenticated fetch-merge-
  install-compile. Nothing had run: the timer was disabled and had been since a single failed run
  weeks earlier. But the arming command was not hypothetical, it was **step three of the runbook**,
  and `verify-phase0-acceptance.md` listed an *active* timer as a precondition — the exact state
  RP-0003 forbids before a signed release exists.
  The runbook now separates installing from arming, with the signing precondition stated **before**
  the `enable` rather than in a paragraph below it; the Phase-0 precondition is corrected; and the
  template header records the ownership asymmetry explicitly, because implicit ownership is what
  produced the drift. Two new checks split by what each can actually see: the offline gate
  `update_unit_template_shape` keeps the shipped template node-agnostic, bypass-free and unarmed-on-
  copy (7 checks, 10 mutations verified — including the exact deployed shape), and the on-node drill
  `scripts/update_unit_drift_drill.sh` diffs a *deployed* unit against the template and fails on a
  provenance bypass or a timer armed without `--allowed-signers` + `--repo-ref`. The gate is honest
  about its limit in its own header: it would have passed on the day the drift was introduced, since
  the defect never existed in the repo. The drill is what closes that class.

### Added
- **L7 liveness for standalone Shadowsocks — the last-resort transport is no longer measured only by
  whether its port is bound.** Standalone Shadowsocks is the lowest exposure tier
  (`spec.ExposureNoCover`), the shape a node falls back to when nothing safer is viable, and it was the
  one served family with no L7 probe: SS-2022 completes no observable handshake, so the criterion every
  other family is judged by — "the connection was still open when the timeout killed it" — reads **ALIVE
  against a listener whose key no longer matches**. A first attempt was built and removed for exactly
  that reason. `_l7_probe_shadowsocks_dial` replaces the criterion instead of the implementation: it
  judges by a **data round trip**, dialling a target that speaks first (the node's own sshd) THROUGH its
  own SS listener, because bytes coming back cannot be produced by anything but a server that decrypted
  the request. Three properties make the verdict trustworthy rather than merely available. (a) The target
  is the node's **own public address**, taken from its own interface list — the served config blocks
  private destinations by design and that control is not weakened for a self-test; because the address is
  one the host already holds, the kernel routes the dial through `lo`, so nothing goes on the wire and
  nothing depends on the provider hairpinning. A private target would be blocked in the tunnel but not in
  the probe's own config, manufacturing a false DEAD. (b) **DEAD requires positive evidence**: silence
  inside the tunnel is ambiguous, so it is only a dead verdict once a control dial over a plain `direct`
  outbound proves the same target answers; every other outcome is cannot-judge. (c) The credential is
  rebuilt from the live config in the multi-user `server_psk:user_psk` form — the server PSK alone is
  rejected exactly like a wrong key, which would make the "correct" arm fail for the same reason as a
  dead listener. Measured on a live node: correct key returns the banner, a wrong user key and a wrong
  server key both return nothing. Pinned by the new `ss_l7_probe_failsafe` gate (21 checks; 13 bypass
  mutations verified caught), and ADR-0036 is amended for the non-loopback target rather than the shape
  being changed quietly.
- **trojan is enrolled in the L7 probe.** Its own-cert genuine-TLS shape was already covered by the
  existing loopback SAN check, but the tag had never been added to the enrolled set — so a served family
  carried a silent L4-only verdict while the code claimed honest coverage. The Xray-served
  `vless-xhttp-tls` inner layer is now the single remaining documented residual.
- **AmneziaWG per-node obfuscation dialect + its operator verbs (Audit-0008 S1-4).** The dialect
  (`H1..H4` + `Jc/Jmin/Jmax/S1/S2`) is no longer a network-wide constant committed in the public repo — a
  published constant is a free network-wide block, since ONE passive UDP payload-match rule keyed on the
  known `H1` drops the AmneziaWG family on every node at once, collapsing a default node's two-family
  redundancy to REALITY-only. Each node now DERIVES its own from its own AmneziaWG key
  (`derive_awg_dialect`, SHA-256 over a per-node value): deterministic, so a node's server config and all
  its clients agree; keyed per node, so no two nodes share a dialect and the repo discloses none. Per
  ADR-0002 this is header randomisation + junk sizing — obfuscation the ADR explicitly permits, producing
  no key material and forming no confidentiality boundary. The committed literals are gone from the shell,
  the Ansible role, `group_vars`, and the docs; a fresh `fungi deploy` gets a per-node dialect with no
  operator action. Three verbs, all `--dry-run`-able and root-only:
  `--awg-regen` (migrate a live node onto its per-node dialect; **idempotent**, it re-derives the CURRENT
  epoch), `--awg-rotate` (move to a genuinely FRESH dialect by bumping a node-local epoch and re-deriving
  from the SAME key — no key, peer or address changes), and `--awg-issue NAME` (the node itself mints the
  keypair + PSK, enrols the `[Peer]`, and renders a COMPLETE ready-to-import client config at the node's
  current dialect; idempotent re-issue is how clients are refreshed after a regen/rotation). All three are
  surgical (only the nine `[Interface]` dialect lines are rewritten; every key, peer and address is
  preserved), backup-first, and fail-closed: a failed bring-up OR a DEAD L7 handshake selftest restores the
  config and reverts the epoch in lockstep, so a node is never left on a dialect it cannot serve. Epoch 0
  derives from the key ALONE, so introducing rotation reproduced every already-migrated node's dialect
  byte-for-byte. Pinned by `awg_regen_failsafe` (15 checks: backup-first, restore-on-failure, surgical,
  key-preserving, dry-run, epoch-0 compatibility, lockstep rollback, re-render epoch awareness).
- **AmneziaWG control logic moved into the Go spine (RP-0008).** The dialect derivation, the
  Selective-Growth route decision and the client-config render were shell arithmetic and shell text —
  control decisions outside their owning layer, and the only renderers in the tree with no Go twin and no
  equivalence pin. Now `internal/spec`: `DeriveAWGDialect(key, epoch)` with `Valid()` stating the AmneziaWG
  constraints (`H1..H4` distinct and > 4 so they never collide with the WireGuard message types,
  `Jmin < Jmax`, `(S1+56) != S2`) and refusing to emit a dialect that violates them; `ResolveAWGRoutes`
  (VIS-0009/ADR-0027, including the IPv6-leak guard) as a pure function over a policy struct;
  `NextAWGPeerHost`/`UsedAWGPeerHosts` (fails closed at `.239` rather than reaching into the `.240–.254`
  probe range); and `RenderAWGClientConfig`, whose `Validate()` refuses a full tunnel WITHOUT the recorded
  Selective-Growth marker — the silent full tunnel the doctrine forbids. New verbs `myceliumctl
  awg-dialect | awg-routes | awg-client-conf`; every secret is read from a file or stdin, never argv, so
  none can land in a process listing. Per the RP-0008 strangler pattern the bash twins stay and are pinned
  byte-identical by `awg_dialect_go_equiv` (25 key×epoch vectors), `awg_routes_go_equiv` (25 decisions) and
  `awg_client_conf_go_equiv` (36 renders); each also asserts the underlying PROPERTY on BOTH producers —
  no input except the deliberate opt-out may yield a default route — because two implementations can agree
  and still both be wrong. The shell client render is now a single shared function used by both the
  first-time render and the live issue path.
- **Fingerprint-adaptivity — the gated actuator (RP-0015 increment B, B3; ships disarmed).** `flow_rotate_fingerprint`
  (`control/lib/nb_rotate_apply.sh`) is the scalar twin of the transport `flow_rotate`: it drives the SAME
  proven render→validate→promote→apply→verify_post_apply→rollback primitives behind its OWN triple gate
  (dry-run default + `--apply-rotation` + a SEPARATE node sentinel `fp-rotate-live.enabled`), persisting the
  one delta `.client_fingerprint=<target>` through the operator-overrides overlay — a closed-vocab toggle key,
  so the rotation survives `--update` and re-resolves through `myc_client_fingerprint` at every render/verify/
  probe site (increment A's consistency invariant closes the loop). It never grows the protocol set; it only
  moves the client uTLS preset WITHIN the closed vocabulary. `refresh_rotate_fp_plan_from_daemon` folds the B2
  daemon's `FingerprintPlanInput` into the plan via `myceliumctl fingerprint-plan` (self-drive; stale-refuse);
  the measure config gained fp fields + a durable `fp-rotate-live.enabled`→`fp_rotate_enabled` arm fold (like
  the collapse sentinel); the fp A/B probe now runs on the existing L7-probe timer (a second `ExecStart`, no
  new timer). New verbs `--fp-rotate` / `--fp-rotate-arm` / `--fp-rotate-disarm`. SHIPS DISARMED: reached only
  by the explicit `--fp-rotate` dispatch (never bootstrap/update), dry-run unless armed, sentinel never in git.
  Pinned by `fp_rotate_gated` (triple gate + dispatch-only + ships-disarmed + scalar-delta-only) +
  `fp_closed_set_only` (no randomiser, no off-vocab target, at planner + Validate + actuator + vocab) + a
  `fingerprint_single_source` post-rotation-consistency extension (the delta key IS the key the renders read).
  The transport rotation path is untouched (its gates stay green). The live arming drill is B4.
- **Fingerprint-adaptivity — the Go fold + planner (RP-0015 increment B, B2; disarmed).** The daemon now folds
  the B1 `fp_probe.json` marker through a PARALLEL scalar plane (the transport member planner is untouched):
  `readFpMarker` (fail-safe like `readL7Marker`) → `foldFpGate`, which REUSES the RP-0014 `l7GenerationGate`
  keyed on the synthetic ref `client-fingerprint` and faults only when a `fingerprint-specific` verdict with a
  STABLE `(current,target)` pair recurs across ≥ `fp_min_generations` DISTINCT marker generations (a target/
  current change — an unstable pick or a completed rotation — or a `transport-wide`/`clean`/stale marker resets
  the streak). The gate shadow-advances every tick so arming has no cold start; the assembled
  `spec.FingerprintPlanInput` is written to `fp_plan_input_path` only when `fp_rotate_enabled` (default false).
  `internal/rotate.PlanFingerprint` is the pure decision — the scalar twin of `rotate.Plan`, mirroring its guard
  order (clean → rollback-latch → hysteresis → cooldown → per-window budget → a valid closed-vocab target) and
  REUSING `spec.RotationLimits`/`RotationState` verbatim on a SEPARATE fp state so the two budgets never
  contend; `spec.FingerprintPlan.Validate` requires the target be a closed-vocab preset distinct from the
  current (a randomiser can never validate). A `myceliumctl fingerprint-plan` verb (twin of `rotate-plan`)
  exposes it. DISARMED + advisory: the daemon only PRODUCES a plan input, never actuates (the gated actuator is
  B3). Pinned by Go tests: the `PlanFingerprint` guard order + the `FingerprintPlan.Validate` closed-set rules +
  a `measure_test.go` real-fold wiring test (fp_probe.json → the reused generation gate → FingerprintPlanInput,
  driving the actual daemon fold, not a re-implementation). Advisory/pure/ships-disabled discipline gates green.
- **Fingerprint-adaptivity — the A/B discriminator producer (RP-0015 increment B, B1; inert).** `measure_fp_ab_probe`
  (`control/lib/nb_selftest.sh`) resolves whether a client-DEAD verdict on a fingerprint-carrying member
  (a REALITY family, or ShadowTLS) is caused by the CURRENT uTLS preset or by the transport underneath it,
  via a same-listener A/B: it consumes the L7 marker's dead list and, for the first dead fingerprint-carrying
  member, re-dials the IDENTICAL dest/cover/port/engine/auth changing ONLY the preset, walking the closed
  vocab (current excluded, canonical order) and stopping at the first ALIVE. Verdicts (neutral tokens, own
  advisory marker `fp_probe.json`): `fingerprint-specific` (current dead + an alternate alive → target =
  first-alive), `transport-wide` (all alternates dead → defer to the ≥2-family backstop), `clean`,
  `cannot-judge`. Holding everything but the ClientHello preset constant means only a preset-keyed filter can
  produce the DEAD/ALIVE asymmetry — so the useless "rotate the fingerprint when the transport is blocked"
  case reads `transport-wide` and emits no signal. INERT: it never rotates and is not folded into the
  transport L7 marker (the daemon fold + gated actuation are B2/B3). Pinned by the `fp_ab_probe_producer`
  conformance gate (the four-verdict table + walk-to-first-alive + the closed-set/no-randomiser/own-marker/
  inert invariants). A `fp-probe` node subcommand invokes it. Mechanism resolved via a design panel (proposal
  updated).
- **Fingerprint-adaptivity — the operator knob (RP-0015 increment A).** The client uTLS ClientHello preset
  ("fingerprint"), previously the literal `chrome` hardcoded in a dozen render/verify/probe sites with no
  single source, is now a single-sourced, closed-vocabulary, operator-settable parameter (`client_fingerprint`,
  default `chrome`). The closed vocab lives once in Go (`internal/spec`: `ClientFingerprints` /
  `ValidClientFingerprint` / `NormalizeClientFingerprint` — real current presets only: chrome/firefox/edge/
  safari/ios/android; a per-connection randomiser is deliberately excluded, a unique JA4 being itself a tell)
  and is mirrored into `control/vocab.json`; `client_fingerprint` joined the `operator_toggle_keys` allowlist.
  Threaded consistently through every client-facing site — the sing-box subscription + Clash render
  (`subscription.go` / `render_singbox.sh`), the legacy vision render (`render.sh`), the share-link
  (`link.go` / `render_bundle.sh`), the aggregate fold, the donor-verify client (`nb_donor.sh`), and the
  ShadowTLS L7 probe (`nb_selftest.sh`) — so the value clients dial, the value the on-node handshake mimics,
  and the value the liveness probe uses can never drift. Additive: with no override every rendered artifact
  and probe is byte-identical to before (default `chrome`). Pinned by the new `fingerprint_single_source`
  conformance gate + Go tests; the `share_link_go_equiv` / `subscription_go_equiv` byte-equivalence gates now
  exercise a non-default preset. The rotation (drive it from the measure→detect loop) is increment B, later.

## [0.2.29] — 2026-07-04
### Added
- **Phase-2 inert federation seam (groundwork) — hypha built, Anastomosis-Bridge declared (ADR-0037).** The
  substrate-agnostic contract schema for node-to-node federation, all inert (typed data + pure `Validate()`,
  **zero production callers**). Built: `IdentityHandle` (substrate-agnostic — a Nebula CA-fingerprint+cert
  identity for a hypha, or a libp2p peer-id for a bridge), the 9-value `TrafficCapabilityClass` +
  `CapabilityPolicy` (ADR-0026 Decision 3), `SiblingDescriptor` (the intra-Commune, same-CA hypha bond) and
  `HyphaInvitation` (the double-opt-in, depth-1–2, degree-capped introduction — a fungi MAY introduce, MUST
  NOT enumerate, ADR-0029). Declared (Phase-5 deferred): the full 8-term `AnastomosisBridge` contract grammar
  (ADR-0026 Decision 2). Live transport is **reused, not reinvented** — Nebula (hypha) + libp2p (bridge),
  chosen in ADR-0037; the CA boundary is the Commune boundary. No crypto/transport authored (ADR-0002/0031).
  Pinned by the `federation_inert` gate (zero callers · pure · no neighbour-list/topology field) + Go tests.
- **Phase-2 e2e client-recovery fallback contract (RP-0013 C1).** `spec.Bundle.IndependentFallbackOK` /
  `DistinctClasses` codify the serve-time invariant that a served subscription spans ≥2 **distinct
  transport families** (`TransportClass`), so a single-family block never removes the client's last path
  (RP-0013 AC-2). Family-level, not endpoint-level — REALITY Vision/gRPC/XHTTP are one family and fail
  together. Pinned by the `e2e_recovery_fallback` conformance gate + Go tests (a single-family bundle is
  proven rejected). Inert — a pure invariant on the rendered artifact; nothing actuates.
- **Phase-2 e2e client-recovery harness (RP-0013 C2, `tests/e2e/`).** A repeatable, reversible, **surgical**
  block of a node's active endpoint (`--source`-scoped `iptables` DROP — external clients unaffected; the
  served config is never touched) + a headless client recovery probe that drives the node's own rendered
  subscription (the SAME `urltest` auto-failover a stock client uses), reads the live selection via the
  Clash API, blocks exactly the active endpoint, and times the failover to the independent sibling —
  asserting the selection changed families. Live-validated: REALITY → GENUINE_TLS, recovered in 42s. Not a
  CI gate (moves real packets); its serve-time precondition is the C1 gate above.
- **L7 own-cert/cover-path liveness detection — closes the reach L4-only blind spot for the REALITY + genuine-TLS families (DoD-1 detection-fidelity).**
  A bound listener that is client-DEAD at L7 (a broken REALITY dest) previously probed healthy (TCP connect
  only), so the self-drive loop never rotated off it. Now `measure_l7_probe` (`control/lib/nb_selftest.sh`)
  does a node-local handshake per client-facing transport — genuine-TLS: an own-cert loopback handshake
  whose leaf must be non-expired **and** carry the SNI in its SAN (a wrong-domain cert is caught; a
  self-signed own-cert still passes — the check is a SAN match, not CA-chain trust);
  REALITY: an authenticated ephemeral-loopback steal against `dest` (`donor_verify_reality`) — with a
  probe-side retry-debounce, and writes `$STATE_DIR/l7_selftest.json`. `cmd/myceliumd` folds a *fresh* marker
  into `spec.DetectorSignal.ActiveProbeOK` (`loadL7Liveness`; fail-safe: absent/stale/malformed → healthy, so a
  probe outage never rotates a healthy transport), so `detect.Classify` flips the active to
  `blocked`/`active-probe-failure`. `nb_measure.sh` emits `l7_liveness_path` + `l7_max_age_ms` into
  `measure.config` and installs a budgeted, jittered `mycelium-l7probe.timer` (ships-disabled, armed by
  `--measure-enable`); the entrypoint gains `--l7-probe`. The deploy-time post-apply acceptance hook shares
  the *same* probe, writing a DISTINCT `$STATE_DIR/l7_postapply.json` so it never clobbers the daemon marker
  (single producer per marker), and no probe egresses a third-party beacon — genuine-TLS is pure loopback and
  REALITY touches only the node's own cover/`dest` host (ADR-0036). Proven on m1: an induced L7-dead active drives an
  autonomous recorded rotation, a too-soon second rotation is correctly rate-limited, and the node recovers to
  clean once the fault clears.
- **L7 liveness coverage for the AmneziaWG data-plane (RP-0014 chunk A).** AmneziaWG rides a separate UDP
  engine (`amneziawg-go` on `awg0`), never appears in the sing-box config, and its UDP listener defeats the
  L4 reach probe (a TCP connect to a UDP port is meaningless) — so its acceptance was L4-only: a bound
  UDP/443 with a *wedged* engine (crash-looping but holding the socket, or not processing handshakes) passed
  `verify_listen_ports`. `measure_l7_probe_amneziawg` (`control/lib/nb_selftest.sh`) now closes that with a
  real loopback WireGuard handshake — it briefly enrols an ephemeral dead-end probe-peer on `awg0` (a `/32`
  from a reserved `.240–.254` block `render_awg0` now fails closed before ever assigning to a client), brings
  up a throwaway userspace interface with `awg0`'s own junk params + a `127.0.0.1` endpoint, polls
  `latest-handshakes`, and tears everything down under an `EXIT/INT/TERM/HUP`-trap so the peer + interface are
  always removed. Fail-safe (ADR-0036): absent tools / no `awg0` / any setup failure → healthy (never dead);
  only a fully-set-up probe whose handshake never completes → dead. Serialized by a non-blocking `flock`
  (a concurrent run skips), idempotent self-heal of a stray peer/iface. **Advisory/acceptance scope:** it
  writes its OWN marker (`$STATE_DIR/l7_awg.json`; a distinct `l7_awg_postapply.json` at deploy acceptance)
  and WARNs; it is **not** folded into the sing-box rotation loop (AmneziaWG is not a rotatable measure
  member — no in-engine sibling to promote). Wired into the post-apply acceptance hook + an on-demand
  `--l7-probe-awg` verb; not on the cadenced daemon timer. No schema/classifier change. Validated live on a
  node: alive, clean teardown, idempotent, concurrent-run skip.
- **L7 liveness coverage for the QUIC families hysteria2/tuic (RP-0014 chunk A).** The reach probe is
  L4-only (a TCP connect to a UDP port is meaningless) and openssl cannot speak QUIC, so a bound-but-DEAD
  hysteria2/tuic listener (wrong/rotated auth, an expired cert, a wedged engine holding the socket)
  previously passed. `measure_l7_probe` now covers them with a real QUIC handshake using sing-box as the
  client (`_l7_probe_quic_dial`, `control/lib/nb_selftest.sh`): (a) an openssl EXPIRY check on the served
  cert file (expiry-only — the own-cert is self-signed/no-SAN/sha256-pinned per ADR-0014, so a SAN/CA check
  would false-DEAD a healthy node), then (b) an ephemeral sing-box client outbound (creds read from the live
  config into a 0600 temp file) `tools connect` to a closed loopback target under a timeout set ABOVE
  sing-box's ~5s QUIC handshake timeout — a healthy data-plane holds past it (exit 124 = alive) while a
  wedged/down/mis-authed one fails fast with an unambiguous `connect to server`/`application error`/
  `authenticat` signature (dead). Unlike AmneziaWG, hysteria2/tuic ARE rotatable measure members (class
  quic-udp), so the dead ref folds into the rotation marker `l7_selftest.json` →
  `DetectorSignal.ActiveProbeOK`. Fail-safe (ADR-0036): sing-box/timeout/openssl absent, an unbuildable
  config, or an unrecognized failure → cannot-judge (never dead); a probe-side retry-debounce. No
  schema/classifier change. Validated live (sing-box 1.13.13): healthy alive, a wedged (bound non-QUIC) port
  dead, closed/wrong-port/wrong-auth dead, empty-sni cannot-judge; the full probe covers 4 families.
  shadowtls + the Xray-served vless-xhttp-tls remain L4-only (the next chunk-A follow-ons).
- **L7 liveness coverage for ShadowTLS v3 (RP-0014 chunk A).** The QUIC dial + classify was extracted into a
  shared `_l7_singbox_dial` (exit 124 = held = alive; a fast exit with an unambiguous server-side
  `connect to server`/`application error`/`authenticat` signature = dead; else cannot-judge), and
  `_l7_probe_shadowtls_dial` (`control/lib/nb_selftest.sh`) added. ShadowTLS's client-facing inbound wraps a
  hidden loopback shadowsocks-2022 detour and its outer TLS handshake is a genuine relay to the node's cover
  host, so the probe reconstructs the real two-outbound client (inner SS-2022 detoured through outer
  ShadowTLS-v3) from the live config and dials it (no node-cert-expiry check — the outer handshake presents
  the cover's relayed cert). The dial timeout is 17s, ABOVE sing-box's ~15s TLS handshake deadline, so a
  bound-but-black-holed listener (accepts TCP, never completes the handshake) fails → dead rather than being
  killed mid-handshake → false-alive (validated live: a black-hole handshake times out at 15s). ShadowTLS IS
  a rotatable measure member (class shadowtls-tcp), so the dead ref folds into the rotation marker
  `l7_selftest.json`. A legacy config with an empty ss/shadowtls secret reads cannot-judge, never
  spurious-dead. No schema/classifier change. Validated live: shadowtls healthy alive, wrong-port +
  black-hole dead; the full probe covers 5 families. Only the Xray-served vless-xhttp-tls remains L4-only.
- **L7 liveness coverage for the Xray-served vless-xhttp-tls (RP-0014 chunk A) — completes chunk-A: every
  closed transport family now has an L7 probe.** vless-xhttp-tls is in the SEPARATE xray config, a sing-box
  client cannot dial xhttp, and it is not a sing-box measure member (nb_measure filters engine==sing-box), so
  — like the AmneziaWG probe — `measure_l7_probe_xhttp` (`control/lib/nb_selftest.sh`) is an
  ADVISORY/ACCEPTANCE signal on its OWN marker, NOT folded into rotation. xhttp-tls presents its own cert as
  its outer layer, so it reuses the ws-tls genuine-TLS mechanism: an openssl loopback handshake whose leaf
  must be non-expired AND carry tls_sni in its SAN. Honest scope (ADR-0036): catches an xray engine that is
  down or serving a broken/expired/wrong own cert (the L4-only reach window cannot see this), but does not
  verify the inner xhttp/VLESS layer (a bound-but-xhttp-wedged xray whose TLS still completes reads alive — a
  documented residual). Wired into the post-apply acceptance hook + an on-demand `--l7-probe-xhttp` verb.
  Fail-safe: absent openssl/jq, no xray config, a malformed config, or an unidentifiable inbound → skip.
  Validated live: healthy alive, wrong-port/malformed dead/skip.
- **RP-0014 chunk B (increment 1) — passive path-level served-flow interference observer (ConnectReset).**
  The detector's first PATH-LEVEL input, closing the residual gap a loopback self-probe cannot see: real
  client flows being reset by an on-path element while the own-listener handshake stays healthy. A dedicated
  ADDITIVE nft table (`inet mycelium_measure`, input hook, `policy accept` — it NEVER drops, only counts +
  falls through to ufw, so it cannot alter the firewall) carries a per-served-TCP-port inbound-RST + SYN
  counter; `measure_pathsig_probe` (`control/lib/nb_measure.sh`) reads the deltas over a budgeted+jittered
  window and writes a node-local marker (`$STATE_DIR/path_signal.json` = {reset:[class refs]}), flagging a
  class whose inbound-RST rate is a high fraction (≥ ½) of its new-connection rate AND above an absolute
  floor (≥ 5) with a non-zero connection rate. Pure by-product (AC-6, ADR-0036): no drop, no payload, no
  per-peer identity — only per-class RST/SYN counts; UDP families (QUIC/AmneziaWG) have no TCP RST and are
  not observed. Armed with the measure plane (`--measure-enable` installs the counters + a `--pathsig-probe`
  oneshot timer; `--measure-disable` removes both, idempotently). Fail-safe: absent nft/jq/table/baseline, a
  malformed config, or a counter reset → no signal (never fabricates a block); the first read only baselines.
  Validated live: a scripted RST spike on a served class flips `reset:[<class>]`, others clean;
  adversarially reviewed (nft cannot open the firewall; set-e guard + false-positive fix applied). **Folded
  into the daemon (increment 1b).** The measure daemon reads the marker through the SAME generation gate as
  the L7 probe — a class must read RESET across ≥ `path_min_reset_generations` DISTINCT observer generations
  before it faults (hardening against a one-off RST spike or a replayed marker) — then overrides that
  member's loopback `HandshakeOK` and sets `ConnectReset`, so `detect.Classify` reaches
  blocked/connection-reset (the classifier is UNCHANGED: this is the fold, not a new branch). A co-reset
  sibling is excluded from the rotation pool via `RotationCandidate.PathReset`, mirroring `L7Dead` — never
  rotate ONTO a member whose own served flows are being reset. The measure.config gains
  `path_signal_path`/`path_max_age_ms`/`path_min_reset_generations` (emitted by `nb_measure.sh`, mirroring
  the L7 marker fields). Fail-safe throughout (an absent/stale/malformed marker → no fault → healthy). Still
  ADVISORY-only: the daemon assembles a PlanInput; nothing actuates without the separate rotate loop.
  **Increment 1c — the observer's safety pinned + the fold proven end to end.** A new offline conformance gate
  (`tests/conformance/pathsig_passive_observer.sh`) mechanically pins that the observer is a PASSIVE,
  NODE-LOCAL, PAYLOAD-FREE by-product: a dedicated additive nft table with `policy accept` whose rules ONLY
  count (no drop/reject/nat/redirect/tproxy/queue/log/ct-set — it cannot alter the live firewall) and match
  ONLY `tcp dport` + `tcp flags` (never a source address, meta selector, payload, interface, or per-connection
  ct state — no per-peer identity), never open an off-node transmit, write an aggregate-only marker
  ({observed_at, checked, reset}), fail safe on a missing nft/jq, and actuate nothing. The nft-semantic checks
  run over the FULL emitted ruleset and rest on a structural precondition — the `{...} | nft -f -` block must
  be built ONLY from literal echo/printf (no helper call or bare-variable payload may smuggle in rule text the
  gate cannot read) — with every nft invocation vetted PER INVOCATION (a compound `nft list … && nft add rule
  … drop` cannot launder past a line-based filter) and no nft emission permitted outside the observer region.
  Negative-tested against 13 unsafe mutations — a drop verdict, a source-IP match, a shared table, a
  policy flip, an extra marker key, a removed fail-safe guard, a ct-state/meta match, an out-of-region rule
  add, a helper-emitted rule, a laundered compound line, a bare-variable payload, and an indirect transmit —
  each makes it FAIL, while the real observer passes. A new
  daemon-integration test (`TestPathSignalMarkerDrivesBlockedReset`) feeds a marker in the observer's EXACT
  on-disk format through `readPathMarker` → the generation gate → `gateToResetMap` → `assemblePlanInput` and
  asserts the active verdict reaches blocked/connection-reset once the class is flagged across ≥
  `path_min_reset_generations` distinct generations — pinning the ref seam (member ref == proto == the
  sing-box inbound tag minus `-in`) the live fold depends on, so a naming drift cannot silently make it a
  no-op. A committed on-node drill (`tests/e2e/pathsig_reset_drill.sh`, run-by-hand, not a CI gate) closes the
  full live loop: a served-side `SO_LINGER=0` RST burst → observer marker → daemon PlanInput verdict
  blocked/connection-reset, with generations spaced wider than a daemon tick.
  **Increment 2 — PostConnectCollapse (the throughput-collapse signal), producer shipped DISARMED.** The
  detector's second path-level input, resolved by an adversarial design panel (4 mechanisms → 3 judges →
  synthesis). A post-connect "data dies" collapse happens DOWNSTREAM of the node, so a local egress byte
  counter cannot see it — but it leaves a node-LOCAL kernel signature: an ESTABLISHED served socket whose
  send backlog (`tx_queue`) stays non-empty AND whose unrecovered-retransmit count climbs, because `snd_una`
  advances only on a real inbound client ACK (retransmits alone never clear it). `_collapse_classes`
  (`control/lib/nb_measure.sh`) reads `/proc/net/tcp{,6}` (no new nft rule, no conntrack, no sysctl) and,
  gated by the existing increment-1 `syn_<port>` churn counter, flags a class when a majority of ≥8 concurrent
  established flows are stuck — writing a `collapse` list into the same marker. It is mawk-safe (fixed-width
  hex compared lexically, not `strtonum`) and reads the remote address ONLY to exclude loopback, then
  discards it (never stored). The daemon folds `collapse` through its own generation gate into
  `PostConnectCollapse` (leaving HandshakeOK/ActiveProbeOK untouched, unlike ConnectReset), so
  `detect.Classify` reaches throttled/throughput-collapse; a co-collapsing sibling is pool-excluded
  (`RotationCandidate.PathCollapse`, mirroring PathReset). **It ships DISARMED** (`path_collapse_enabled`
  false by default): the marker's collapse list is written in SHADOW for observation, but the fold is inert
  until an on-node drill validates the `/proc` field parse (`retrnsmt` is field 7, NOT the field-8 uid — the
  false-fire landmine the panel caught) and the fire/silence behaviour. The gate is extended to pin the new
  `/proc` reader as fail-safe + address-free and to allow the `collapse` marker key; new Go tests cover the
  fold, the pool exclusion, and the armed→throttled / disarmed→clean control. **Validated live (2026-07-19,
  m1):** the parse-proof confirmed the field layout (sing-box uid in `/proc` field 8, retrnsmt in field 7) on
  the real kernel; a synthetic ≥8-flow fire-proof (client ACKs dropped so the node's sent data goes
  unacknowledged) drove all flows to retransmit and the observer fired; and the full arming drill on the REAL
  reality-vision class (8+ live reality sessions downloading, then their ACKs dropped) produced
  `marker.collapse=["vless-reality-vision"]` and, with the fold armed, the daemon verdict
  **throttled/throughput-collapse** — recovering to clean once the loss stopped. A DURABLE arm sentinel
  (`$STATE_DIR/collapse-armed.enabled`, mirroring `rotate-live.enabled`) keeps an operator-armed node armed
  across a config regen / auto-update; absent, the `false` default holds.
  **Chunk C — proactive full-set selection: the node-local digest projection seam.** Chunk C's node-local
  DoD was already met by chunks A/B — the L7 probe assesses the WHOLE served set every run (not just the
  active), and the planner ranks candidates by tuner weight while hard-excluding the L7-dead / path-reset /
  path-collapse ones across the pool. The one genuinely-missing node-local piece was the glue between the
  measure plane's held per-member verdicts and the (already-present, inert) `spec.BuildNodeStatusDigest`:
  `measure.Assembler.StatusObservations()` projects each member's fine ConnState DOWN to its lossy
  `AdvisoryHealth` (throttled/blocked/shutdown all collapse to `degraded`, ADR-0030), grouped by transport
  class — the per-CLASS observation map the digest builder's k-floor consumes. It is PURE (no I/O, no
  emission): a single node's own multi-member classes (reality-tcp = 3 members, quic-udp = 2) already clear a
  k≥2 floor, so it feeds a valid class-aggregate digest with no second node. Deliberately does NOT build,
  serve, sign, or transmit — the live advisory emitter/cache/publisher is a future cross-cutting RP, and
  cross-node aggregation + region-keyed weather stay on the inert Phase-5 federation seam (the
  `federation_inert` + `node_status_digest_emit_safe` gates stay green). This connects the two existing pure
  halves so that future emitter has a node-local input.
### Fixed
- **`--measure-enable` now restarts the long-lived measure daemon onto the current binary.** It used
  `systemctl enable --now mycelium-measure.service`, which never restarts an already-active service — so a
  spine rebuild followed by a re-`--measure-enable` silently left the OLD `myceliumd` running and the code
  update never took effect (found live: an m1 reset drill saw the observer marker flip but the daemon fold
  never fired, because the daemon was an 11-day-old binary with no `readPathMarker`). Now `enable` +
  `restart` (fail-closed), so the current binary always loads. The l7probe/pathsig units are oneshot
  (re-exec node-bootstrap fresh each timer fire) and were never affected.
- **Pinned, non-distro Go toolchain for the node spine build.** A node built its Go control-plane spine
  (`myceliumctl-go` + `myceliumd`) and the AmneziaWG userspace tools from whatever `go` the distro shipped
  (varying wildly node-to-node), and the timer-driven `--update` could not build the spine at all. A new
  `toolchains.go` pin in `control/engines.manifest.json` (`go1.23.12` + per-arch sha256, `go.dev/dl`),
  resolved by `manifest_toolchain_pins`, is downloaded + **checksum-verified fail-closed** + extracted by
  `install_go_toolchain` (called from `install_spine`, so bootstrap / `--update` / `--node-apply` all
  self-heal the toolchain and build the same reproducible binary; `GOTOOLCHAIN=local`). `golang-go` is
  dropped from the base deps. `engine_manifest_shape` validates the pin (version, arch hex, `dl_base ==
  GO_DL_BASE`, a go.mod currency floor). Validated on live nodes — the spine rebuilt to 0.2.29 from the
  pinned toolchain over the real `--update` path.
- **`fungi deploy` self-arms single-node adaptivity (`--no-arm` to opt out).** Deploy sequences the explicit
  `--measure-enable` + `--rotate-arm` + `--rotate-enable-loop` dispatches after convergence, so one command
  yields a serving, self-driving node. The ships-disabled contract holds — only the explicit flags arm, and
  the timer-driven `fungi update` (`flow_update`) never arms, so an auto-pull still cannot self-arm a node
  (`measure_daemon_ships_disabled` unchanged).
- **Turnkey transport/CDN profile selection — `myceliumctl front` verbs + `fungi` passthroughs.**
  `myceliumctl front enable|disable|show` creates/toggles the node-local `front.config.json` (the ADR-0033
  bring-your-own-domain CDN/ingress front), validated (an enabled front needs the operator's own domain over
  a frontable transport; terminate mode needs the explicit trade-off ack) — removing the last
  hand-authored-JSON step. `fungi transport|reachable|front` thin passthroughs delegate to the Go spine so
  the whole node lifecycle runs through one `fungi` surface. Both stay write-only intent / orchestration-only
  (`node_cli_no_actuation` + `fungi_scoped` green).
### Changed
- **Self-drive L7 liveness cadence tightened to single-digit-minute recovery.** The L7 probe now runs every
  120s ±45s (was 300 ±120) with `MEASURE_L7_MAX_AGE_MS` 900k → 420k (still ≥2× the worst-case probe gap);
  `MEASURE_L7_MIN_DEAD_GEN` stays 2 (the Audit-0007 S2 marker-replay hardening is preserved). A live re-drill
  on a node — an L7-DEAD REALITY active → autonomous rotation to the genuine-TLS sibling — measured **~8 min**
  end-to-end recovery (single-digit; the planner anti-flap `flip_confirmations` × the ~90s rotate-loop
  cadence, not the probe interval, now bounds the tail).
- **Serve-time independent-fallback enforcement (RP-0013 AC-2, fail-closed).** `RenderBundle` and
  `RenderSubscription` now REFUSE to emit a served artifact that spans fewer than 2 independent transport
  families — so a node (which serves via `myceliumctl bundle`/`subscription`, the Go spine) cannot publish a
  single-family subscription a client could never recover from. Previously the ≥2-family invariant
  (`Bundle.IndependentFallbackOK`) was offline-gated only, with zero production callers; it is now enforced
  on the node at render time, consistent with AC-6 (≥2 independent families per node).
- **RP-0010 AC-6 clarified** — "no new active-probing fingerprint" means no new EXTERNAL / third-party
  fingerprint. A node-local loopback own-cert/cover-path probe (genuine-TLS pure-loopback; REALITY touching
  only the node's own cover/`dest` host — the cover traffic REALITY already produces) is the sanctioned
  realization of the Plane-2 `active-probe response failure (own-cert / cover path)` signal, under the
  hyphal-probe invariants (budgeted, jittered, bounded).
### Fixed
- **`--node-apply` silently never served the xray engine (dual-engine gap).** `flow_node_apply` handled only
  sing-box and early-returned when the sing-box candidate was byte-identical to the live config — so enabling
  an xray-engine transport (vless-xhttp-tls, which leaves the sing-box config unchanged) never installed or
  started xray. `flow_node_apply` (`control/lib/nb_render_params.sh`) now promotes/reloads sing-box ONLY when
  its config changed (a restart drops live client connections on an always-on PPN), then ALWAYS applies the
  optional xray engine via the new `apply_node_xray_engine` — the same fail-closed spine as bootstrap
  (install → render → `xray run -test` → no-op-if-unchanged → promote-with-known-good-backup → unit → restart).
  A stock node (no xray transport) is a no-op. Validated live: enabling vless-xhttp-tls served xray on its
  port with the sing-box inbounds untouched (not restarted), rollback-safe.
- **Legacy identities can't enable shadowsocks/shadowtls/trojan — empty per-proto secret → `sing-box check`
  "missing psk".** A node bootstrapped before ss/trojan/shadowtls were added to the identity secrets block
  carries those keys present-but-EMPTY (only `hysteria2_password` + `clash_secret` were minted), and
  `ensure_identity` kept the existing `identity.json` whole without backfilling — so enabling one of those
  families rendered an empty password and the candidate failed the fail-closed `sing-box check`, silently
  blocking the family. `ensure_identity` (`control/lib/nb_identity.sh`) now backfills: per secret, keep the
  existing value iff present AND non-empty, else mint a fresh one; other secret keys + reality/donor/created
  are preserved; the file is rewritten atomically (fresh temp → `mv`) so a jq/mv failure leaves the identity
  untouched. A node with all secrets present is unchanged (no live secret is ever rotated). Dry-run safe.
- **Clean-machine deploy of the default REALITY-only profile aborts silently (`set -euo pipefail`).**
  `nb_render_params.sh` derives the genuine-TLS SNI from the served cert's SAN with `grep -oE 'DNS:…'`; a
  REALITY-only node's CN=donor cover cert has NO subjectAltName, so `grep` matches nothing and exits 1,
  `pipefail` propagates it to the bare `tls_domain="$(…)"` assignment, and `set -e` aborts the WHOLE deploy
  with nothing printed. An empty `tls_domain` is the intended, handled result there, so the openssl read and
  both grep pipelines now end in `|| true` (this also fixes a latent `grep`→`head -1` SIGPIPE on a multi-SAN
  cert). Nodes that served a genuine-TLS family (a real SAN cert) never hit it. Found by a clean-machine
  deploy drill (a node wiped to bare OS with distro Go removed).
- **Pinned Go toolchain too old to build the AmneziaWG engine without a distro Go.** The
  `engines.manifest.json` build-toolchain pin `go1.23.12` satisfied the spine's `go.mod` floor (1.23) but not
  `amneziawg-go`, whose `go.mod` requires `>= 1.24.4`; under `GOTOOLCHAIN=local` the engine build failed on a
  machine with no newer distro Go (the existing nodes had built it with distro go1.26). Bumped the pin to
  **go1.24.13** (new per-arch checksums; the `engine_manifest_shape` currency floor still holds). Same drill.
- **Self-drive timers fail to arm on a relative invocation (systemd rejects a relative `ExecStart`).**
  `scripts/node-bootstrap.sh` wrote its own path (`NB_SELF`) verbatim into the `mycelium-l7probe` /
  `mycelium-rotate` unit `ExecStart`, but only *absolutised* it when it was a symlink — a plain relative
  invocation (`cd /opt/mycelium && bash scripts/node-bootstrap.sh --measure-enable`) left it relative, so
  systemd refused the units ("Neither a valid executable name nor an absolute path") and the timers never
  enabled (the node silently never self-drove). `NB_SELF` is now anchored to the already-absolute `NB_DIR`,
  so any invocation yields an absolute self-path. Found by the pre-release arm drill on a fresh node.
- **Genuine-TLS `tls_sni` = the node's own cert-SAN domain, not the donor SNI** — the client bundles were
  emitting the donor SNI against a `*.example.com` certificate.
- **REALITY donor validation** — donors are validated with a real ephemeral-loopback REALITY handshake
  (`donor_verify_reality`); `www.microsoft.com` (TLS-fine but steal-breaking) dropped from the candidate set.
- **Conformance-gate lockstep** — `node_update_artifact_root` derives its staged-lib set from the entrypoint
  source loop (single source of truth), and `nb_selftest` is registered in that loop.
- **Rotation never lands on a co-failed sibling** (Audit-0007 S2) — the auto-rotation planner
  (`internal/rotate`) now excludes any candidate this node's own L7 probe reports client-DEAD from the
  ranked pool. A new `spec.RotationCandidate.L7Dead` (zero value = eligible) is set in `measure.Tick` from
  the same node-local liveness map that faults the active's `ActiveProbeOK`, and `rotate.Plan` skips a dead
  candidate BEFORE the weight-margin/promote checks — so a broken REALITY `dest` can no longer make the loop
  rotate from a dead `reality-vision` onto an equally-dead `reality-grpc` that shares it, and a dead-but-
  promoted candidate no longer mislabels the hold as *target-not-promoted*.
- **REALITY donor probe: no false-DEAD from a port race** (Audit-0007 S2) — `donor_verify_reality` spun its
  ephemeral loopback server/client on the FIXED ports 29443/29444, so a deploy-time donor pick overlapping a
  timer-fired L7 probe collided on the bind and reported a *healthy* donor DEAD (→ a spurious rotation). The
  ports are now randomized per attempt (retried), the handshake runs under an `flock` (node-shared under
  `STATE_DIR`), and a bind failure returns *cannot-judge* rather than *dead*; the `measure_l7_probe` call
  site is made `set -e`-safe so a broken-dest verdict on the timer path can no longer abort the probe before
  its marker is written.
- **L7 marker replay no longer defeats the anti-flap** (Audit-0007 S2) — the daemon re-reads the L7 marker
  every tick, so a single DEAD probe *generation* used to fault the detector on every tick until it aged
  out, letting one probe run satisfy the tick-based anti-flap on its own. `cmd/myceliumd` now gates the
  fault through an `l7GenerationGate`: a member must read DEAD across ≥`l7_min_dead_generations` **distinct**
  `observed_at` generations (default **2**) before it faults, so a rotation reflects sustained, not replayed,
  evidence; a fresh-clean or absent/stale marker resets the streak (fail-safe), and an explicit `1` restores
  the prior behaviour. Also fail-closes `donor_verify` on an un-judgeable REALITY donor at deploy (rc 2 →
  reject, since the engine is present before donor selection), and the genuine-TLS probe now requires the
  SNI in the leaf's SAN (a wrong-domain cert is caught; a self-signed own-cert still passes).

## [0.2.28] — 2026-06-30
### Security
- **Diagnostics-redactor audit remediation (RP-0011 chunk E)** — close the conditions a planned PR audit
  (refactoring.md §4.1, full 10-lens panel) raised on the v0.2.27 hardening:
  - **Bounded own-hostname scrub.** The collector's node-hostname scrub moved into the diag package as
    `diag.RedactBundle(s, selfHost)` — a WORD-ANCHORED, length-floored (≥4) match instead of an
    unbounded `strings.ReplaceAll`, so a short/common hostname can no longer corrupt the bundle.
    `diag redact` (stdin) now applies the same belt. Covered by `TestRedactBundleSelfHost`.
  - **Dial/lookup/connect error operands** (`dial tcp <host>:443`, `lookup <host>`) are now redacted —
    closes the unlabelled bare-hostname residual the audit raised to S1.
  - **Quoted field values** (`password="a b"`) are redacted whole.
  - **ASN rule** is AS/ASN-anchored + case-sensitive, so the English word "as" followed by digits is no
    longer over-redacted.
  - **Subprocess timeout.** `diagRun` uses `exec.CommandContext` with a 10s deadline, so a wedged
    journald / D-Bus can no longer hang `diag collect`.
  - **Honest docstrings.** The `internal/diag` package header + `Redact` doc no longer claim "NONE of
    the PII" / "every PII class"; they state the over-redaction guarantee and the documented residual.
  - **Docs.** THREAT-MODEL.md gains an *"Attack surface: the node diagnostics bundle (diag collect)"*
    section and SECURITY.md §4.2 cross-references it (closes the THREAT_MODEL_DRIFT finding).
  - The runtime test + `log_bundle_redaction` gate now pin the new classes, the rule-order invariant
    (no FQDN fragmentation), and the non-over-redaction invariants (clock time + "as"+digits survive).

## [0.2.27] — 2026-06-30
### Security
- **Harden the diagnostics redactor (`internal/diag`) — close PII gaps found in a pre-release review of
  chunk E**. The bundle is meant to be attached to a public bug report, so the redactor must leave NO
  PII; the prior rules missed several classes that real journal lines carry:
  - **Bare single-label hostnames** (no dot) are now scrubbed via a labelled-field pass — `_HOSTNAME=`,
    `hostname=`, `host=`, `sni=`, `server_name=`, `peer=`, `domain=` — which the dotted-FQDN rule could
    not match. The collector now also (a) reads the journal with `-o cat` so no per-line
    `<time> <hostname> <unit>` prefix is emitted at all, and (b) scrubs the node's own hostname by exact
    match. Field secrets (`password=`, `psk=`, `private_key=`, `short_id=`, …) are redacted whole,
    length- and charset-agnostic.
  - **Short hex tokens (≥8)** — e.g. a REALITY `short_id` — that fell in the gap between the UUID/64-hex
    rules and the ≥32-char secret pass are now redacted.
  - **IPv6**: the rule is re-anchored (a captured leading delimiter, since `\b` cannot anchor before a
    leading `:`) so `::`-compressed and IPv4-mapped (`::ffff:a.b.c.d`) forms are caught; it is also
    tightened so a clock time `HH:MM:SS` is **not** over-redacted (log chronology is preserved).
  - Added **MAC address**, **ASN variants** (`ASN 64999`, `as=…`), and **`$HOME` username** passes.
  - `Redact` is now **idempotent** (a second pass over redacted text is a no-op). The runtime test and
    the `log_bundle_redaction` gate seed every new class so the gaps cannot regress. Verified on a Go node.
  - Known residual (honest scope): a free-floating bare hostname or sub-8-char opaque secret that appears
    with no labelling key and no dot is not redacted — labelling every dot-less word would destroy the
    bundle's usefulness; structured fields, addresses, and dotted names are covered.

## [0.2.26] — 2026-06-30
### Added
- **RP-0011 Operability & Release, chunk E-2 — `diag collect` collector**: `myceliumctl diag collect`
  assembles a node diagnostics bundle — spine version, engine versions (sing-box/xray), unit status
  (is-active + NRestarts for sing-box/xray/myceliumd), and the recent sing-box journal — and pipes the
  WHOLE bundle through `internal/diag.Redact` before printing, so it is **PII-safe by construction**
  (AC-9): an operator can attach it to a public bug report. It is READ-ONLY (only is-active / version /
  journalctl), and lives below `usage()` — OUTSIDE the `node_cli_no_actuation` block — because reading
  live state via a subprocess is that gate's concern for the edit verbs but is the point of a collector.
  `log_bundle_redaction` now also pins that the collector prints only `diag.Redact(...)` output (never
  the raw builder). Closes chunk E (the redactor E-1 + the collector E-2). Verified on a Go node.

## [0.2.25] — 2026-06-30
### Added
- **RP-0011 Operability & Release, chunk E-1 — diagnostics PII-redactor (AC-9, gate-before-collector)**:
  a new pure Go package `internal/diag` whose `Redact()` scrubs every PII class the project forbids
  collecting (SECURITY.md §4.2) from arbitrary text — IPv4/IPv6, FQDN/hostname/SNI, client UUIDs, key
  material (64-hex + base64url), long opaque secrets/PSKs, AS numbers — fail-safe by over-redaction,
  and preserves structural context (it redacts values, not the `key=` labels). New thin verb
  `myceliumctl diag redact` (stdin → scrubbed stdout) so any diagnostics can be made safe to attach to
  a public bug report. New gate `log_bundle_redaction` seeds a synthetic bundle with fake PII of every
  class, pipes it through `diag redact`, and asserts NONE survive (+ requires the Go runtime redaction
  test) — it lands BEFORE any `diag collect` collector. Verified on a Go node: TestRedactScrubsEveryNeedle
  + idempotency, full offline suite 62/62.
  > **Note (superseded scope).** The "scrubs every PII class" wording above describes the *structured*
  > classes only. v0.2.27/v0.2.28 + [ADR-0035](docs/adr/0035-diagnostics-bundle-redaction-contract.md)
  > record the honest contract: fail-safe by over-redaction with a small **named residual** (a
  > free-floating, unlabelled, dot-less, sub-8-char value the operator reviews). Read this entry against
  > that contract, not as an absolute guarantee.

## [0.2.24] — 2026-06-30
### Added
- **RP-0011 Operability & Release, chunk C-3 — pure `deploy-plan` verb + `spec.EngineManifest`**: a new
  read-only Go type `internal/spec.EngineManifest` parses `control/engines.manifest.json` and resolves
  `{version, sha256, dl_base}` for an engine on a normalised arch (amd64/arm64; armv7 uncovered →
  required-flag fallback). New CLI verb `myceliumctl deploy-plan [FILE] [--arch A] [--manifest F]`:
  parses the node descriptor, reads the manifest READ-ONLY, resolves the pinned engine version + archive
  SHA256 for the target arch, and PRINTS the one-command on-ramp plus the equivalent direct
  node-bootstrap invocation with the pins filled in. It is PURE — reads the two input files and prints,
  spawns nothing, touches no live node state — so `node_cli_no_actuation` stays green (its dispatch check
  now also asserts `deploy-plan`). Verified on a Go node: resolves the correct per-arch pins for the
  example descriptor (amd64 vs arm64), both arg forms, suite 60/60. Builds on chunks C-1 (the committed
  manifest + resolver) and C-2 (node-bootstrap reads it as default pins).
- **RP-0011 Operability & Release, chunk C-4 — `scripts/fungi` one-command entrypoint**: the operator-facing
  surface for a node — `fungi deploy|update|apply|plan|status`. ORCHESTRATION ONLY: `deploy`/`update`/`apply`
  actuate solely by exec-ing `node-bootstrap.sh` (the fail-closed render→validate→promote→rollback actuator;
  engine pins auto-fill from the manifest, C-2); `plan` delegates to the pure `deploy-plan`; `status` is a
  read-only probe (service state / listeners / engine versions — never starts/stops/restarts anything). fungi
  embeds NO render/validate/promote/config-mutation logic. New gate `fungi_scoped` pins both halves
  (actuation-only-via-bootstrap + orchestration-only); `scripts/fungi` ships in `make dist`. Drilled on a Go
  node: `status` read-only, `update --dry-run` promotes nothing (NRestarts=0), `plan` resolves pins; suite 61/61.

## [0.2.23] — 2026-06-21
### Added
- **RP-0011 Operability & Release, chunk D — reachability posture (ADR-0034 §3)**: a node can be
  provisioned + converged but NOT a public entry. Mechanism = a single render-time `node_bind` param
  (default `"::"`, **byte-identical to today**; `apply_node_profile` stamps `"127.0.0.1"` only when the
  descriptor declares `reachable: false`), applied identically by the shell renderer and
  `internal/spec.RenderServer` so every PUBLIC inbound binds loopback (the hidden ShadowTLS detour stays
  loopback regardless). The firewall follows automatically — `harden_ufw`'s loopback exclusion is
  generalised to all inbound types, so a loopback-bound port is never opened (anti-lockout: sshd-allow
  stays first). New CLI verb `myceliumctl reachable on|off [--config FILE]` (write-only on the descriptor,
  apply with `--node-apply`). The bind layer holds on every flow the instant `reachable: false` is set
  (never fail-open); the firewall layer converges at bootstrap (ADR-0034 §3 staging note). New gate
  fixture `render_server_go_equiv` case D (reachable=false byte-identical shell↔Go) + Go unit test
  `TestRenderServerReachable` (absent → `"::"`, `node_bind:"127.0.0.1"` → loopback). Verified on a Go node
  + drilled DRY-RUN on a live node.
  Hardened after an adversarial review: (1) the firewall port selection is extracted to a pure, unit-tested
  helper `myc_firewall_singbox_ports` with a **null-tolerant** `listen` test (a missing `listen` defaults
  public instead of aborting `harden_ufw`); (2) a **fail-closed foreign-engine guard** — `apply_node_profile`
  refuses `reachable: false` while a non-sing-box-engine transport (e.g. the Xray-only `vless-xhttp-tls`) is
  enabled, since `node_bind` is sing-box-only and that inbound would otherwise stay public (ADR-0034 §4;
  dual-engine reachability is a tracked follow-up); (3) `.reachable` is read as a **strict JSON boolean**
  (parity with Go's typed parse); (4) `reachable on` warns that going public also needs a full bootstrap to
  open the firewall; (5) the doc contract is corrected (an absent `reachable` key renders public for
  byte-identity). New gate `reachable_firewall_loopback` pins the firewall half (public ports opened,
  loopback never opened) + `node_cli_no_actuation` now asserts the `reachable` verb is dispatched.
- **RP-0011 Operability & Release, REL-1 — release artifact (`make dist`)**: a `dist` Makefile target builds a
  DETERMINISTIC source tarball (= the AGPL Corresponding Source) of the committed tree via `git archive`,
  named `mycelium-<spec.Version>.tar.gz` (the name cannot drift from the spine version), plus a `SHA256SUMS`.
  `git archive` ships ONLY tracked files (per-node identity/secrets/rendered configs are gitignored + never
  tracked → they can never leak into the artifact) and `gzip -n` makes two builds byte-identical. The release
  is authenticated by a SIGNED git tag (ADR-0015 SSH-sig, the scheme `verify_signed_ref` already uses) — not
  produced here (the maintainer signs locally; see `docs/RELEASING.md`). New gate `release_dist_sane` pins
  version-naming, contents, secret-freeness, and reproducibility (SKIPS without a git work tree).

## [0.2.22] — 2026-06-21
### Added
- **RP-0011 Operability & Release, chunk B2c — transport writer CLI verbs**: `myceliumctl transport
  enable|disable PROTO [--config FILE]` edit the node-profile descriptor's `transports[]` (validated
  against the Go-owned registry, fail-closed) and write `node.config.json` (0600). They are WRITE-ONLY on
  the descriptor — no subprocess, no live-node mutation; the operator applies the change with the
  explicit `node-bootstrap.sh --node-apply` (B2b). New pure `internal/spec.NodeProfile.WithTransport`
  (dedup + order-stable list edit). The chunk-C gate `node_cli_readonly` is renamed/refined to
  `node_cli_no_actuation` (the verbs may now write the descriptor, but still never exec a subprocess,
  mutate live state, or perform a destructive op; the descriptor write is 0600). Also corrected the
  `usage` text. Verified on a Go node: build / vet / fmt-check / test / race green.

## [0.2.21] — 2026-06-21
### Added
- **RP-0011 Operability & Release, chunk C — read-only operator CLI verbs** on the Go spine
  (`myceliumctl`): `node validate FILE|-` (parse + fail-closed-validate a node profile — ADR-0034),
  `node plan FILE|-` (a DRY-RUN preview of what a descriptor resolves to — the enable-keys its
  transports turn on via the registry, plus the reachability / front / ingress / loops summary; no
  mutation), and `transport list [--json]` (the closed transport registry: proto / class / port /
  engine / frontable / toggleable). New pure resolver `internal/spec.NodeProfile.EnabledKeys()` (the
  descriptor → params-toggle translation the bootstrap will later apply additively) + exported
  `spec.ProtoByName`. New gate `node_cli_readonly` (offline suite 51 → 52): the verbs are READ-ONLY —
  no write / rename / remove / exec — so they cannot change a live node; the live-mutating verbs
  (`deploy`, `transport enable|disable`) land once the bootstrap reads the descriptor. Also corrected
  the stale `usage` "not yet ported" line (render-server / subscription are ported; only reality-keys
  remains). Verified on a Go node: build / vet / fmt-check / test / race green.

## [0.2.20] — 2026-06-21
### Added
- ADR-0034 **unified node profile (RP-0011 Operability & Release, chunk B)** — the INERT, node-local
  descriptor that unifies what a node IS into ONE declaration: `internal/spec.NodeProfile`, where
  transports / reachability / CDN front / two-hop ingress / background loops / (reserved) weather opt-in
  are **default-off CAPABILITY fields of one node form**. There is deliberately NO node-TYPE enum (fungi
  is a reversible niche — ADR-0018) and NO engine selector (engines stay additive — ADR-0032; the engine
  is derived from the enabled transports, never chosen). `Validate()` is fail-closed: transport names are
  checked against the Go-owned registry (never a restated `<proto>_enabled` rule), the front delegates to
  the ADR-0033 invariants (relay default, frontable-only, terminate-needs-ack), the two-hop minimal shape
  is required, and the reserved weather slot is refused while inert. `ParseNodeProfile` refuses unknown
  fields, so a stray node-"type" enum fails closed. Committed example `control/node.config.example.json`
  (all default-off; the real descriptor is node-local / never committed). New gate
  `node_profile_single_source` (one schema, capabilities-not-types, registry-read, example inert, no
  bootstrap path writes it). Nothing consumes it yet — the bootstrap reads it ADDITIVELY in a later chunk
  (byte-identical for a node that adopts no new field). Suite 50 → 51.

## [0.2.19] — 2026-06-20
### Added
- ADR-0033 **CDN/ingress front P2-2 (edge config compiler) + P2-3 (bundle integration + deploy wiring)**.
  - **P2-2:** `internal/spec.RenderFrontProxy` compiles a `FrontConfig` into the nginx config the OPERATOR
    deploys on their own edge: RELAY (default) → an `ssl_preread` SNI-routed TLS-PASSTHROUGH `stream` server
    (the edge terminates nothing, holds no key — the node's own cert is served end to end); TERMINATE
    (ack-gated) → a TLS-terminating reverse proxy (the metadata trade-off, emitted only with the explicit
    ack). Operator-supplied domain/host are config-injection-guarded (`isSafeHost`). `myceliumctl
    front-render --front F --params P` resolves the node address + transport port and emits it.
  - **P2-3:** `spec.RenderBundleFront` APPENDS one fronted endpoint (distinct `-front` tag, last-resort
    priority) to the bundle for the configured frontable transport — purely additive (a disabled /
    not-served front leaves the bundle byte-identical, so `bundle_render_go_equiv` stays green; the base
    LinkParams resolution was extracted to `bundleBaseLinkParams` so direct and fronted Links cannot drift).
    `bundle --front F` wires it in. Deploy wiring `control/lib/nb_front.sh` `front_setup` (run at the tail of
    `render_serve_bundle`, default-OFF): when a node-local `front.config.json` is enabled it compiles the
    edge config + re-renders the SERVED bundle WITH the fronted endpoint (fail-closed), the Go spine doing
    the render. New gate `front_deploy_inert` pins default-off / read-only-on-config / no-auto-enable; the
    front gate also pins the compiler (relay=passthrough/keyless, terminate ack-gated, injection-guarded).
  - REMAINING: only the operator reachability field test (P2-4), which needs a real bring-your-own domain.
    Additive; default-off; a node without a front is unchanged. Suite 49/49 on a Go node.

## [0.2.18] — 2026-06-20
### Added
- ADR-0033 **CDN/ingress front P2-1 (fronted-endpoint render)** — `internal/spec.FrontLinkParams` re-points
  a frontable transport's client endpoint at the operator's bring-your-own-domain front: the client dials
  `front-domain:443` (SNI = the front domain, so the edge routes on it) while the encrypted tunnel passes
  through to the node (default relay mode → the node's own-cert pin is unchanged end to end). It is a
  fail-safe NO-OP for a disabled / non-matching / non-frontable front, and mode-agnostic at the client
  (relay vs terminate is an EDGE concern, compiled into the edge proxy config by a later chunk). For
  vless-ws-tls the front domain drives both `sni=` and `host=`. INERT: nothing wires it into the bundle
  yet (that + the edge TLS-passthrough config compiler + deploy-time BYOD wiring are the next chunks).
  `front_relay_preferred` extended to pin the render (re-points server/SNI to the front on 443, no-op when
  disabled); `TestFrontLinkParams*` prove it. Additive; default-off; no wire change on a node without a front.

## [0.2.17] — 2026-06-20
### Added
- RP-0008 **P3-e (render-server → Go) + the two-hop via_user routing** — the LAST renderer port.
  `internal/spec.RenderServer` + `myceliumctl render-server --engine singbox` build the node's sing-box
  SERVER config on the Go spine, byte-identically to `myc_sb_render_server`: one inbound per enabled,
  sing-box-ENGINE protocol (the xray-only `vless-xhttp-tls` is dropped — dual-engine, ADR-0032) in the
  template's inbound order, the hidden ShadowTLS detour SS inbound when ShadowTLS is on, the static
  direct/block outbounds + private/bittorrent route rules, the loopback `clash_api` with an optional
  Bearer secret (omitted when unprovisioned, so legacy nodes render identically), and — when params
  declare a `two_hop` upstream — a VLESS+WS+TLS egress outbound + an `auth_user` route rule (ADR-0029
  in-region-ingress → out-of-region-egress, P3-e). The Go renderer encodes the template's per-inbound
  key order in typed structs (the only faithful way to reproduce jq's order in Go); the
  `render_server_go_equiv` gate keeps the structs in lockstep with the shipped template. Resolution +
  fail-closed checks mirror the shell exactly: REALITY material is consulted ONLY when a REALITY proto is
  on (so a non-reality node's shadowtls handshake defaults to www.microsoft.com and tls_sni to localhost);
  short_ids must be non-empty under REALITY; the own-cert families require an explicit tls_sni (C03); the
  per-identity password falls back via jq `//` (absent/null only, never ""); the two-hop is fail-closed
  (C17 shape/port, C18 via_user is a known client, C21 distinct hop). Verified byte-identical across 16
  adversarial fixtures on a Go node; `TestRenderServer{Shape,ClashSecretOmitted,FailClosed}` pin the
  structure where Go is unavailable. Additive; the shell stays authoritative until cutover. **RP-0008 P3
  (renderer porting → Go) is now COMPLETE (P3-a..P3-e).**

## [0.2.16] — 2026-06-20
### Added
- RP-0008 **P3-d (subscription → Go)** — `internal/spec.RenderSubscription` + `myceliumctl subscription
  --engine singbox` port the per-client sing-box client config + Clash-Meta YAML emission to the Go spine
  (the strangler continues; the shell stays authoritative until the gate is green). Per client it emits
  `<safe>.singbox.json` (one outbound per enabled sing-box-engine protocol, the ShadowTLS handshake detour,
  a urltest "auto" + "mycelium" selector + direct/block) and `<safe>.clash.yaml` (the Clash-supported
  subset). It carries the **dual-engine** update (ADR-0032): the enabled set is filtered to the sing-box
  ENGINE, so the xray-only `vless-xhttp-tls` is **skipped** (a sing-box client cannot dial the xhttp
  transport — the Xray client dials it), and resolution uses the canonical `tls_key_path`. Resolution
  mirrors the shell EXACTLY (per-identity password → shared-secret fallback, TUIC-uses-UUID, the C03
  own-cert-SNI fail-closed, registry-priority order, `tr -c` name sanitisation). New gate
  `subscription_go_equiv` byte-diffs both producers across two fixtures (all transports + 2 clients incl.
  the skipped xray proto and a sanitised name; a subset with an empty client password → shared-secret
  fallback); `TestRenderSubscriptionShape` pins the structure where Go is unavailable. Additive; no wire change.

## [0.2.15] — 2026-06-19
### Added
- RP-0010 **C5 (advisory emit)** — the inert constructor for the ADR-0030 advisory-emit seam:
  `internal/spec.BuildNodeStatusDigest` turns per-class `AdvisoryHealth()` projections (the lossy,
  externalisable view — never the fine `ConnState`) into a `NodeStatusDigest`, enforcing the privacy
  invariants BY CONSTRUCTION: **k-floor with omit-not-zero** (a class with `< k` member observations is
  DROPPED, never zeroed/imputed; below the floor entirely it returns `ErrAggregationFloor` — emit
  nothing, never a sub-floor digest), **class-aggregate** alive-dominant (one `(class, HealthValue)`
  cell, no per-member row, no node ref), region forced `RegionUnspecified`, deterministic (sorted class
  order). Pure, no I/O, no live emission/signing — the live emitter/cache/publisher remain a future
  cross-cutting RP (ADR-0030). The `NodeStatusDigest` type + `Validate` were already the landed seam;
  this adds the safe constructor + tests. Gate `node_status_digest_emit_safe` pins the emit-safety at
  the conformance layer (no per-node/identity/location field in the type; the builder omits sub-floor
  cells + forces unspecified region) so it holds where `go test` does not run. Additive: no wire change.

## [0.2.14] — 2026-06-19
### Added
- RP-0010 **Plane-1 C5c-1 (deploy seam)**: `install_spine` now builds BOTH Go binaries from the fetched
  source — the control CLI (`myceliumctl-go`) and the daemon (`myceliumd`, the MEASURE-plane host) —
  into `$TOOLING_DIR/bin`, with the same idempotent rev-keyed skip (`myceliumd version` added). The
  daemon runs under systemd **`Type=notify` + `WatchdogSec`**: `myceliumd` sends `sd_notify(READY=1)`
  once its listener is bound + monitors are up and pings the watchdog (zero-dependency; reuses systemd's
  liveness contract rather than a hand-rolled supervisor — ADR-0031). New `control/lib/nb_measure.sh`
  `measure_enable` / `measure_disable` (`--measure-enable` / `--measure-disable`) write + enable the
  `mycelium-measure.service` unit — **SHIPS DISABLED**: the unit is written + enabled ONLY by the
  explicit flag, NEVER by `flow_bootstrap` / `flow_update` / `install_tooling` / `install_spine`, so an
  auto-pull deploys the (always-built, inert) binary but can never start the advisory plane (the C4c-2
  pattern). `measure_enable` is fail-closed (requires the binary + both node-local configs). Gate
  `measure_daemon_ships_disabled` pins the no-auto-arm contract. The daemon is strictly ADVISORY —
  actuation stays behind the RP-0012 triple gate. Node-local config generation (C5c-2), the bash-loop
  wiring (C5c-3), and the live drill (C5c-4) follow. Additive: no wire/output change on a stock node.

## [0.2.13] — 2026-06-19
### Added
- ADR-0033 (extends ADR-0029) + the inert `internal/spec.FrontConfig` schema for an OPTIONAL
  operator-provided CDN/ingress front: bring-your-own-domain, opt-in, default-off. `FrontConfig.Validate`
  pins the doctrine fail-closed — an enabled front requires the operator's own domain, may sit in front
  of ONLY the genuine-single-TLS own-cert HTTP transports (`vless-xhttp-tls` / `vless-ws-tls` via the
  closed `IsFrontableTransport` set; REALITY/raw/UDP refused), and is RELAY-PREFERRED: `FrontMode` is a
  closed `{relay, terminate}` enum where `relay` is the default (`EffectiveMode`) and `terminate`
  requires an explicit `ack_terminate_tradeoff` (a TLS-terminating edge is the metadata leak
  THREAT-MODEL calls "worse than neutral" — ADR-0026). The schema records the efficacy framing: a front
  is COMPLEMENTARY / last-resort (reachability on IP/SNI-blocking networks + control-plane hardening),
  NOT a fix for the destination-class throttle, where the in-region two-hop is primary (ADR-0027). Gate
  `front_relay_preferred` pins the closed vocab + the relay-preferred / frontable-only / domain-required
  invariants + the efficacy framing (and runs the Go tests where a toolchain is present).
  `control/front.config.example.json` documents it. INERT: nothing consumes `FrontConfig` yet — the
  fronted-endpoint render + the deploy-time bring-your-own-domain wiring + an operator reachability field
  test are a follow-on RP (ADR-0033 §Implementation). Additive: no wire/output change.

## [0.2.12] — 2026-06-19
### Added
- RP-0010 **Plane-1 C5b (daemon embed)**: `myceliumd` now hosts the MEASURE plane. Given a
  `--measure-config` (alongside `--reachability-config`), it builds an `internal/measure.Assembler`
  ONCE (so the per-member detector hysteresis + tuner pheromone persist across ticks) and runs a tick
  loop that folds each `reach.Monitor` snapshot into a `rotate.PlanInput`, writes it atomically to the
  configured `output_path` (the file `myceliumctl rotate-plan` consumes), and serves the latest on a
  loopback `/rotation/plan-input`. The active member, between-tick `RotationState` (`rotate_state.json`)
  and output paths are re-read each tick so a rotation is picked up without losing accumulated state.
  At startup the daemon cross-checks the measure config against the reachability config and refuses to
  run on a dangerous mismatch (an active ref that is not a member; a member with no reach probe — it
  would stay seeded-clean and never be rotated away from; a `tick_ms` below the slowest probe interval
  — it would re-fold the same window and defeat the detector anti-flap / over-reinforce the tuner). The
  reach snapshot is filtered to member refs before the fold (reach may probe context anchors the node
  does not rotate among). The written `PlanInput.now` is its freshness stamp (the file freezes at the
  last good tick across failing ticks, so the consuming loop rejects a stale one); the loopback
  endpoint always surfaces `tick_at` + `last_error`.
  Strictly ADVISORY (AC-4): it assembles + serves a plan input and never spawns a process, invokes the
  engine, or actuates — rotation stays behind the RP-0012 triple gate. INERT until a measure config is
  supplied (nodes have none yet; deployment + bash-loop wiring + the live drill are C5c). New gate
  `measure_daemon_advisory` pins the daemon's no-actuation surface (denylist: no `os/exec`,
  `exec.Command`, `syscall.*Exec`, or sing-box invocation; asserts the measure+reach wiring is present).
  `control/measure.config.example.json` documents the schema. `cmd/myceliumd` tests cover config
  validation, fail-closed assembler build, the assemble golden (+ planner round-trip), and the file
  round-trips. Additive: no wire/output change.

## [0.2.11] — 2026-06-19
### Changed
- Post-review hardening of the RP-0010 Plane-1 MEASURE plane and the Phase-2 purity gates (from the
  `internal/measure` adversarial review):
  - `internal/measure.New` now rejects two members sharing a `proto` — the planner keys candidate
    selection on proto (rotate.Plan skips `c.Proto == active.Proto` and ranks by registry order), so a
    duplicate would leave one member permanently un-selectable. Mirrors the existing duplicate-ref
    rejection.
  - The four Phase-2 purity gates (`detector_pure_no_probe`, `tuner_pure_advisory`,
    `rotator_pure_planner`, `measure_pure_advisory`) shared determinism token-bans a future edit could
    evade. Hardened all four: the wall-clock ban now matches `time.Now`/`time.Since` with or without a
    trailing `(` (catches `var f = time.Now`); the channel ban catches the directional `chan<-`
    spelling; and an ALIASED `import x "time"` (which slipped past the alias-blind path allowlist) is
    now refused. `measure_pure_advisory` additionally forbids calling `rotate.Plan` (assemble-only,
    AC-4). No production code path changed.

## [0.2.10] — 2026-06-19
### Added
- RP-0010 **Plane 1 (MEASURE)**: `internal/measure.Assembler` — the node-local seam that folds the
  existing `internal/reach` health signal through the detector and the self-tuner into a
  `rotate.PlanInput`, closing the adaptivity loop measure → detect → tune → assemble → plan. It WRAPs
  existing components and adds NO new measurement surface (RP-0010 AC-6): it consumes only the
  fast-class `spec.TransportHealth` window (success/failure per opaque transport ref) and never dials,
  reads a file, or runs a process. Because reach reports only success/failure, the `DetectorSignal` is
  DERIVED from the window — a window with ≥1 success proves the channel connects and handshakes; zero
  successes is read as a black-hole; the by-products reach never measures (active-probe, post-connect
  collapse, single-stream comparison) are presented as non-faulted — and the success ratio then grades
  a connecting channel clean vs throttled inside the detector. Strictly ADVISORY (AC-4): it only
  assembles a plan input, never actuates — actuation stays behind the RP-0012 triple gate. Stateful
  across ticks (per-member detector hysteresis + evaporating tuner weight) and deterministic (the clock
  is injected). Conformance gate `measure_pure_advisory` pins the purity (allowlist {fmt, sort, time,
  internal/detect|rotate|spec|tune}; no socket/file/process/clock) and that it genuinely wires
  detect+tune+spec → `rotate.PlanInput`. Tests cover the fold, the end-to-end loop-closes-and-acts
  path, determinism, idle evaporation + verdict carry, and fail-closed construction. Daemon embedding
  and live-loop wiring follow (C5b). Additive: no wire/output change.
### Changed
- The Go module path is now `github.com/mycelium0/mycelium` (was `github.com/mindicator/mycelium`),
  aligning it with the repository home so `go get`/`go install` resolve and every import matches the
  canonical location. Mechanical rename across `go.mod`, all `internal/` + `cmd/` imports, the
  spine-build ldflags (`-X …spec.SourceRev`), and the purity-gate import allowlists; no behaviour
  change.

## [0.2.9] — 2026-06-19
### Added
- RP-0008 **P3-c (part 2 — the aggregate fold)**, completing the aggregate port: `internal/spec.RenderAggregate`
  + `myceliumctl aggregate --out F --bundle F [--name L] ...` — the Go port of the shell
  `myc_render_aggregate`: fold ≥2 per-node Bundles into ONE sing-box client profile (each endpoint a
  namespaced `<label>.<tag>` outbound via `outboundValue`, then ONE urltest "auto" + ONE selector
  "mycelium"/default "auto" + direct/block). Pure + LOCAL-only; fail-closed (ASCII labels, unique labels,
  scheme↔transport_class consistency, ShadowTLS refused, port range), byte-identical to the shell
  (`MarshalIndent` 2-space + `SetEscapeHTML(false)`; `URLTEST_*` defaults shared with `render_singbox`).
  Conformance gate `aggregate_render_go_equiv` folds two shell-rendered bundles through both producers and
  raw-byte-diffs the profile; the shell stays authoritative (no cutover). `TestRenderAggregate`/
  `TestRenderAggregateFailClosed` pin it. With P3-a/P3-b/P3-c-1 this brings bundle + aggregate fully into
  the Go spine (subscription + two-hop routing remain). Additive: no wire/output change.

## [0.2.8] — 2026-06-19
### Added
- RP-0008 **P3-c (part 1 — the link parser)**: `internal/spec.OutboundFromLink(tag, link)` +
  `myceliumctl link-outbound --tag T LINK` — the Go port of the shell `myc_agg_link_outbound`, the
  inverse of `ShareLink`: parse an opaque `vless://`/`hysteria2://`/`tuic://`/`ss://`/`trojan://`
  share-link into a sing-box client outbound. Pure string parsing (`uriDecode` is the inverse of
  `uriEncode`; query/authority split mirror the shell jq `before`/`after`); outbound shapes are typed
  structs whose field order + `omitempty` reproduce the shell jq construction byte-for-byte. A ShadowTLS
  ss-link and any unknown scheme fail closed to `null` (the inner-only material cannot rebuild the v3
  detour). Conformance gate `aggregate_outbound_go_equiv` generates links via the proven `share-link`
  (reserved char in every field) and asserts the shell + Go parsers agree byte-for-byte; the shell stays
  authoritative (no cutover). `TestUriDecodeRoundTrip`/`TestOutboundFromLinkGolden`/`TestShareLinkOutboundRoundTrip`
  pin it. P3-c part 2 (the profile fold — urltest/selector) follows. Additive: no wire/output change.

## [0.2.7] — 2026-06-19
### Added
- RP-0008 **P3-b**: `internal/spec.RenderBundle` + `myceliumctl bundle --params F --state F [--out F|-]` —
  the Go port of the shell bundle producer (`render_bundle.sh`). One Endpoint per enabled transport in
  registry/priority order, each via `spec.ShareLink`; resolution mirrors the shell exactly (params
  defaults via the `myc_params_get` `// empty` semantics, the per-identity password fallback to the
  shared secret, the C03 own-cert-tls_sni and C09 port-range fail-closed checks). Marshalled jq-style
  (2-space indent, `SetEscapeHTML(false)` so `&` in links stays literal, trailing newline). Conformance
  gate `bundle_render_go_equiv` renders the same params+identity through BOTH producers and asserts a
  raw byte diff (the `generated_at` instant text-normalized) — the strangler equivalence proof; the
  shell stays authoritative until green. `TestRenderBundleShape`/`TestRenderBundleFailClosed` pin it.
  Additive: no wire/output change.

## [0.2.6] — 2026-06-19
### Added
- RP-0008 **P3-a** (the renderer-porting phase begins): `internal/spec.ShareLink(proto, LinkParams)` +
  `uriEncode` — the Go port of the shell `myc_bundle_link` (the dialable client share-link / Bundle
  Endpoint Link). Pure + deterministic, byte-identical to the shell template across the 10 link-bearing
  transports; `uriEncode` matches `jq @uri` (RFC-3986 unreserved set, uppercase `%XX`, byte-wise).
  `myceliumctl share-link --proto P FILE|-` exposes it. Conformance gate `share_link_go_equiv` drives
  BOTH renderers with the same values (incl. reserved chars) and asserts identical output — the
  strangler equivalence proof; the shell renderer stays authoritative (no cutover) until it is green.
  Additive: no wire/output change. (`TestUriEncodeMatchesJqAtUri`, `TestShareLinkGolden`,
  `TestShareLinkEncodesReservedChars` pin it where Go is unavailable.)

## [0.2.5] — 2026-06-19
### Changed
- RP-0008 (Go-spine migration): the operator-override allowlist is now GO-OWNED. `internal/spec`
  gains `OperatorToggleKeys()` (every params-toggled proto's `*_enabled`/`*_port` key from the
  registry, plus the tunable knobs `xhttp_path`/`xhttp_path_tls`/`ws_path`/`grpc_service_name`/
  `region_bucket`), emitted into the `Vocab` (`myceliumctl vocab` / `control/vocab.json` →
  `.operator_toggle_keys`). `control/lib/nb_render_params.sh` reads the allowlist from `vocab.json`
  instead of a hardcoded bash array — the single source consumed by BOTH the override merge
  (`write_params`) and the auto-rotation executor (enable-key validation). Fail-closed: a real write
  refuses an empty/missing allowlist. `TestOperatorToggleKeysMatchesLegacy` pins the registry-derived
  set to the exact legacy 25-key list (lossless migration); `vocab_single_source` keeps Go ↔ `vocab.json`
  in lockstep. No wire/output change.

## [0.2.4] — 2026-06-19
### Added
- `myceliumctl rotate-record FILE|-` (RP-0012 C4c): folds an apply outcome into the rotation state via the
  pure `rotate.RecordOutcome` — on a rollback it spends the per-window rollback budget and latches the
  planner to hold for `CooldownAfterRollback` (no rollback thrash). Validates limits (fail-closed); clock
  from the system when `now` is zero. Pure read + compute.
- LIVE rotation in `control/lib/nb_rotate_apply.sh` + `scripts/node-bootstrap.sh --rotate --apply-rotation`
  (RP-0012 C4c), behind a TRIPLE GATE: dry-run is still the default; the live promote→verify→rollback path
  is reached only when `--apply-rotation` (`ROTATE_APPLY=1`) is set AND the node is ARMED (the node-local
  sentinel `$STATE_DIR/rotate-live.enabled`, placed via `--rotate-arm`, never committed — so an auto-pull
  can never actuate a node). The live path validates first against a temp params copy, then PERSISTS the
  rotation through the operator-overrides overlay (snapshot taken) so it survives `write_params`/`--update`,
  re-renders the authoritative config, and runs the existing `promote_config → apply_singbox →
  verify_post_apply` with `rollback_config` on failure. Every failure edge REVERTS the overlay (and records
  the rollback) so a rolled-back rotation cannot re-apply on the next tick — no persistent self-outage.
  `flow_rotate` is still reached only by the explicit `--rotate` dispatch (never `flow_bootstrap`/
  `flow_update`); the unattended timer is C4c-2 and ships disabled.
### Changed
- Gate `rotate_dry_run_default` → `rotate_apply_gated` (RP-0012 C4c): now enforces the full triple gate
  (dry-run default · `promote_config` confined to the live path · live reachable only under
  `ROTATE_APPLY` + `rotate_live_armed`, with `ROTATE_APPLY` defaulting to 0), the no-implicit-actuation
  rule (`flow_rotate` appears only in the `rotate)` dispatch), the overlay snapshot+revert (no persistent
  self-outage), and the no-auto-arm rule. `apply_rotation_to_params` / `persist_rotation_to_overlay` /
  `revert_rotation_overlay` / `record_rotation_rollback` / `rotate_apply_live` added to the
  `no_new_control_decisions_in_bash` denylist (control-logic stays in the sourced lib).

## [0.2.3] — 2026-06-18
### Added
- `myceliumctl rotate-plan FILE|-` (RP-0012 C4b): the shell-invocable boundary of the Plane-3 ADAPT
  decision — reads a node-local `rotate.PlanInput` JSON, runs the pure `rotate.Plan`, and emits the
  `RotationPlan` as JSON (the CLI fills `Now` from the system clock when the caller leaves it zero;
  the planner itself stays clock-free). No network, no mutation.
- `control/lib/nb_rotate_apply.sh` + `scripts/node-bootstrap.sh --rotate` (RP-0012 C4b): the DRY-RUN
  executor seam. `flow_rotate` reads a `RotationPlan` (default `$STATE_DIR/rotate_plan.json`, override
  `ROTATE_PLAN`); a HOLD plan is a no-op, an ACT plan applies its params delta to a TEMP params copy
  (`apply_rotation_to_params` enables the To-sibling's key, fail-closed against the closed
  `OPERATOR_TOGGLE_KEYS` allowlist), renders a candidate via the existing `render_candidate`, and runs
  the real `validate_config` (`sing-box check`) — then STOPS. It never calls `promote_config`: the
  persisted params, the operator-overrides overlay, and the live config are left byte-identical. The
  live promote/verify/rollback loop and the unattended timer are C4c, behind the RP-0012 §6 go/no-go.
- Gate `rotate_dry_run_default` (RP-0012 C4b): pins the dry-run boundary — `flow_rotate` never calls
  `promote_config`, reuses `render_candidate`/`validate_config`, the entrypoint wires the seam, and
  nothing auto-arms `--rotate` on a timer/cron. `apply_rotation_to_params` added to the
  `no_new_control_decisions_in_bash` denylist (control-logic stays in the sourced lib).

## [0.2.2] — 2026-06-18
### Added
- `internal/spec/rotate.go` + `internal/rotate` (RP-0012 C4a, executing the RP-0010 Plane-3 ADAPT
  decision): the auto-rotation PLANNER — the inert rotation schema (`RotationAction` / `RotationReason` / `RotationCandidate` /
  `RotationLimits` / `RotationState` / `RotationPlan`, all with pure `Validate`) and the pure,
  deterministic `Plan(PlanInput) -> RotationPlan` decision: clean → hold, then hysteresis
  (`FlipConfirmations`) → cooldown (`MinInterval`) → rate budget (`MaxPerWindow`) / rollback latch →
  pick the highest-weight tuner-promoted closed-set candidate that beats the incumbent by
  `MinWeightMargin`. `RecordOutcome` spends the rollback budget and latches to hold. The decision is
  node-LOCAL (no global/peer signal can reach it — AC-4) and stays WITHIN the closed transport set
  (no add-transport action; an out-of-registry proto fails `Validate` — AC-5); the clock is a
  parameter (deterministic). Gates: `rotator_pure_planner` (allowlist `{fmt, time, internal/spec}`,
  no clock/goroutine), `rotate_closed_set_only` (AC-5). INERT: nothing calls `Plan` in production yet
  (the executor seam + gated live loop are C4b/C4c).

## [0.2.1] — 2026-06-17
### Added
- `internal/tune` (RP-0010 C3): the self-tuner — the Physarum/Tero-2010 reinforce-and-evaporate
  control law expressed on `spec.DecayPolicy`, as a per-(transport-class, path) `Weight`. Each good
  connectivity `Verdict` reinforces the weight; it decays continuously by `HalfLife` toward
  `RetentionFloor`, so a blocked shape fades WITHOUT teardown and re-promotes automatically when the
  block lifts (`RetentionFloor` is scar memory — a repeatedly-blocked shape settles low but is never
  forgotten). A `Hysteresis` band damps the promote/demote flag. `NewWeight` is fail-closed; the
  weight is a ranking input only and NEVER actuates (ADR-0025 / AC-4). Gate `tuner_pure_advisory`
  enforces the package imports only `internal/spec` + pure stdlib (no net/os/syscall, no
  internal/reach|detect). Still inert: nothing consumes the ranking yet (auto-rotation is a later
  chunk).

## [0.2.0] — 2026-06-17
### Added
- **Phase 2 (adaptivity) opens — the connectivity-state detector, detect plane (RP-0010).** This
  release marks the two detect-plane chunks that landed under the Phase-1 version; the version line
  moves to the Phase-2 `0.2.x` track, and subsequent chunks bump the patch individually.
- `internal/spec/detector.go` (RP-0010 C1): the inert, node-local detector schema — the closed
  `ConnState` {clean/throttled/blocked/shutdown}; its lossy `AdvisoryHealth()` projection to the
  coarse advisory `HealthValue` (the OPSEC boundary — only the projection is emittable, k-floored,
  ADR-0030; impaired states collapse to one value); the closed `DetectReason` cause vocabulary; the
  `DetectorSignal` input and `Verdict` output; pure `Validate` throughout. Gate
  `detector_state_closed_vocab` keeps the vocab closed and enforces, by construction, that no
  transmitted artifact embeds the fine `ConnState`/`DetectReason`.
- `internal/detect` (RP-0010 C2): the connectivity-state classifier — `Classify`, a pure
  signature-priority function, plus a stateful `Detector` with a success-ratio hysteresis dead-zone
  (route-flap damping) and an anti-flap confirmation count. A held impaired state is never latched:
  once its boolean fault flag clears it is capped at aggregate degradation, so a recovered path
  climbs back out. `New` is fail-closed; decisions are deterministic and measured by a
  labelled-incident corpus (per-class precision/recall). Gate `detector_pure_no_probe` enforces the
  classifier adds no new probe surface (imports only `internal/spec` + pure stdlib; AC-6).
- `spec.ReasonDegradedWindow` for aggregate (non-point-signature) degradation.

### Note
- The detector is INERT in this release: nothing calls it in production yet (the `internal/reach`
  → signal wiring, the self-tuner, and auto-rotation are later RP-0010 chunks).

## [0.1.1] — 2026-06-17
### Added
- `internal/spec/transport.go`: Go-owned canonical transport registry (proto→class, default
  ports, params keys, scheme, engine) + closed transport/region/health vocabularies + `Vocab`
  aggregate. `myceliumctl vocab` emits it deterministically; committed `control/vocab.json` is the
  artifact the shell renderer reads (RP-0008 P2). The shell stops being a second source of truth
  for the transport taxonomy.
- `myceliumctl version` now appends the build-stamped source revision (`-ldflags -X
  spec.SourceRev`) when present, preserving the `myceliumctl <ver>` prefix.
- node-bootstrap `install_spine`: builds + installs the Go control binary
  (`$TOOLING_DIR/bin/myceliumctl-go`) from the deployed source on bootstrap and update — inert in
  this phase (the shell tool stays authoritative), warn-not-die, idempotent on the stamped source
  rev (RP-0008 P3 chunk 1).
- `ws-tls` transport class (VLESS+WebSocket over genuine single-layer TLS) is first-class and
  sing-box-servable (the on-device-proven Phase-1 genuine-TLS shape).
- Conformance gates: `vocab_single_source`, `spine_binary_build`, `no_reserved_jq_vars`.

### Fixed
- `merge_operator_overrides` / `seed_operator_overrides` named a jq variable `def` (a jq keyword);
  jq 1.6 fails to parse `$def`, so a jq-1.6 node's every `--update` died at the operator-override
  merge and rolled back. Renamed to `base`; added the `no_reserved_jq_vars` static gate.
- `sub_channel_not_single_point` sourced `render_bundle.sh` standalone after it began delegating to
  the shared vocab accessor; the gate now sources the same dependency chain.

### Changed
- The shell renderers consume the Go-owned vocabulary: `render_bundle.sh` (proto→class +
  closed-vocab list), `render_singbox.sh` (`MYC_SB_PROTOS` + per-proto default ports), via the new
  `control/lib/vocab.sh`; `OPERATOR_TOGGLE_KEYS` is gate-policed against the registry (RP-0008 P2).
- Terminology swept repo-wide to consistent network/population vocabulary.

### Notes
- During the 0.x alpha the SemVer minor digit tracks the lifecycle phase (0.1.x = Phase 1); patch
  increments per landed increment, with a git tag at phase close. Per-build identity is
  `internal/spec.SourceRev` (the git rev stamped into the binary).

## [0.1.0] — 2026-06-12
### Added
- Go module and the ADR-0012 layout: `internal/spec` (shared typed schemas), `cmd/myceliumctl`,
  `cmd/myceliumd`.
- `internal/spec`: typed `Identity` / `IdentityState` model with pure `Add` / `Revoke` /
  `Validate`, and an RFC 4122 v4 `NewUUID` from the OS CSPRNG (`crypto/rand`) — no custom
  cryptography (ADR-0002). Unit-tested.
- `internal/identity`: file-backed state store with atomic `0600` writes; a missing file yields
  a fresh empty state. Unit-tested.
- `cmd/myceliumctl`: `identity add|revoke|list` and `version`, at parity with the shell tool's
  identity surface. `reality-keys` / `render-server` / `subscription` report a parity gap and
  defer to the shell `control/myceliumctl` for now (RP-0002 W7).
- `cmd/myceliumd`: Phase 0 skeleton daemon — PII-safe `/healthz` + `/version`, loopback by
  default, graceful shutdown. No network-state detector or auto-rotation (Phase 2).
- `Makefile`: `build` / `test` / `race` / `vet` / `fmt-check` targets; `conformance` runs the
  shell suite.

### Notes
- First slice of RP-0002 W7 ("spine early, glue stays shell"). Build & verify with
  `go build ./... && go test -race ./...`; the offline shell conformance suite remains all green.
