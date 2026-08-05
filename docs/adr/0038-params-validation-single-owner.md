<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0038: `params-knob validation has one owner, and it is the Go spine`

## Metadata
- **ID:** ADR-0038
- **Date:** 2026-08-05
- **Author:** mindicator & silicon bags quartet
- **Status:** proposed
- **Layer(s):** control plane
- **Phase:** Phase 2
- **Related:** [RP-0017](../proposals/0017-params-knob-validation-single-owner.md),
  [RP-0008](../proposals/0008-go-spine-distribution-rendering.md) (the precedent: Go owns the
  vocabulary, the shell reads the generated artifact),
  [RP-0016](../proposals/0016-transport-delivery-hardening.md) (introduced the knob),
  [ADR-0034](0034-unified-node-profile.md) (`node.config.json` is the node profile),
  [development.md §2.2 item 8](../development.md), [refactoring.md §7](../refactoring.md)

## Context

A params knob whose value is *structured* — a port range, a path, a duration — is judged by more than
one consumer. `hysteria2_hop_ports` is judged by three: the Go subscription renderer, the shell client
renderer, and the firewall reconcile that turns the range into a nat/PREROUTING REDIRECT. Two of the
three emit it to clients; the third is the only one that makes it real.

When those three disagree, the node enters a state that **no check on it can observe**. A range the
renderers accept and the firewall rejects means every issued hysteria2 client hops across ports nothing
serves, while `verify_post_apply` reports healthy — it checks that the service is active, that the
socket is bound, and that a **loopback** handshake completes, and loopback traffic never traverses
PREROUTING. This is not hypothetical: it shipped, and both shell halves additionally accepted
`2000:3000:4000` (the outer-field expansions `${r%%:*}` / `${r##*:}` yield 2000 and 4000, both in
bounds, ordered) which iptables then refuses — a value that passes validation and cannot become a rule.

The first remediation added a Go predicate and hand-copied it into both shell halves, then added a gate
driving all three against one value table. That is a policed duplication, and development.md §2.2 item
8 forbids it outright: *"One truth type — one owner. Two locations storing the same truth type diverge
and produce conflicting diagnoses/policy — that is an architectural defect."* The gate makes the
duplication permanent and introduces a fourth copy (its own `sed` extraction) that must itself be kept
current.

The same shape appears a second time in the same commit: `front_setup` materialises
`node.config.json .front` into a derived `front.from-profile.json`, giving front configuration two
files holding one truth.

- **Adversary model.** An adversary who blocks a UDP port. Port hopping exists so that losing one port
  does not lose the family. The failure this ADR prevents is self-inflicted: the node *believes* it has
  the port dimension and does not, so the mitigation is absent exactly when the block arrives.
- **Affected asset.** Ingress reachability. No user-identifying data is involved; nothing here is
  collected, logged, or transmitted.
- **Fundamental trade-off.** None of the anonymity trilemma. The trade-off is local: a Go-owned
  predicate consumed through a generated artifact costs one regeneration step and a build dependency in
  the emission path, against a class of silent, unobservable divergence.

## Considered Options

1. **Keep three implementations, gate their agreement.** What was shipped. Cheap, no new mechanism,
   works today. Rejected: forbidden by §2.2 item 8, and the gate is load-bearing forever — every future
   edit must touch three sites plus the gate's extraction, and the gate cannot see a *fourth* consumer
   added later. It also failed on its own terms: the gate's header claimed the extracted copy's
   currency was checked when it was not.

2. **Shell calls the spine binary at render time.** One owner, no artifact. Rejected: the shell
   renderer runs where no Go binary is guaranteed (RP-0008 established exactly this constraint — nodes
   carry a spine but the renderer must not depend on invoking it per value), and it would put a process
   spawn inside a per-client render loop.

3. **Go owns the predicate and emits its bounds into the generated vocab; consumers compare against
   the emitted numbers.** Chosen. It is the mechanism the project already uses for the transport
   registry, the closed vocabularies and the operator allowlist, and `vocab_single_source` already
   proves the artifact matches the Go emission byte-for-byte.

4. **Move the firewall reconcile into Go.** Would collapse the consumers to one. Rejected for this ADR
   as out of scope and disproportionate: it moves an effect (writing an iptables rule) into the
   decision layer, against the RP-0008/RP-0009 split — *shell renders and deploys; the Go binary
   decides and adapts*.

## Decision

**Every validation predicate for an operator-settable params knob lives in `internal/spec` and nowhere
else. Its bounds and defaults are named constants in that package and are emitted into
`control/vocab.json`. Every other consumer — Go or shell — reads the emitted values; no consumer
re-derives the rule.**

Consequences of the rule, stated so they are testable:

1. A shell consumer may compare a value against emitted numbers. It may **not** contain a second
   expression of the *policy* (which bounds, which shape, which ordering).
2. Bounds and structured defaults are named constants with a stated basis (§1.1: "no arbitrary
   timeout — numeric network parameters are named and tied to a measurement or design decision").
3. A knob that no operator can set is not "off by default" — it is unreachable, and shipping one is a
   defect. Every params key a renderer reads must be reachable by exactly one of three routes:
   generated by `write_params`, present in `spec.OperatorToggleKeys()`, or stamped by a named posture
   step. The conformance suite enforces this as a class, not per knob.
4. The conformance gate asserts **single-sourcing** — that no second implementation exists — rather
   than agreement between implementations. A gate that watches N copies agree is evidence the rule was
   not applied.

**§2 — front configuration.** ADR-0034 made `node.config.json` the node profile. Its `.front` object is
therefore the single owner of front configuration. `front.config.json` remains supported as an
explicit node-local override and **wins when present**, because an operator who placed it there meant
it; when absent, `front_setup` reads the profile **directly**. No derived third file is written.

## Consequences

**Positive.**
- The divergence class disappears by construction rather than by vigilance. There is nothing for two
  copies to disagree about.
- The bounds become inspectable in one place — `myceliumctl vocab` — which is also what an operator
  reads to learn what a knob accepts.
- The reachability rule (consequence 3) is what turns "the feature shipped and nobody could enable it"
  into a gate failure instead of a field report.

**Negative / costs.**
- One more field in the vocab contract, and one more thing that must be regenerated when it changes.
  `vocab_single_source` already fails on drift, so the cost is bounded and visible.
- The shell fail-closed path grows a case: no bounds in the vocab → no range → no rule. That path must
  be exercised in tests, because it is the state a partially-updated node is in.
- Shell readability drops slightly: the rule is no longer legible at the point of use. Mitigated by a
  comment at each consumer naming the owner.

**Neutral.**
- No client-visible change. The config-bundle format is untouched; a node with no range configured
  renders byte-identically to one that never heard of the feature.

## Compliance

- **development.md §2.2 item 8** (one truth type, one owner) — satisfied by construction.
- **development.md §1.1** (no magic numbers; cross-service identifiers centralised) — satisfied by the
  named constants and their emission.
- **development.md §4.1** (obfuscation/timing parameters are adapter inputs, not constants) — the hop
  interval becomes an input carried by the contract rather than a literal in two renderers.
- **development.md §2.2 item 11** (nothing advertised whose render path does not exist) — consequence 3
  is the generalisation of that clause to the operator-settable surface.
- **THREAT-MODEL.** No asset changes. The observable-shape question a hop range raises is owned by
  RP-0017 Phase E and is not decided here.
