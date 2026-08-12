<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0039: Client-vantage reachability is not node-observable — the signal, and what a node may do without it

> Records **one** decision: a node **cannot** determine whether a client can reach it over a given
> transport, and therefore **must not act as though it can**. The only evidence of client-vantage
> reachability is evidence that originates at a client. This ADR names that signal, fixes its privacy
> shape by reference to [ADR-0017](0017-network-weather-data-contract.md) and
> [ADR-0030](0030-advisory-network-awareness.md), and — until it is wired — **constrains what the
> rotation loop is permitted to conclude from the signals a node does have**.
>
> The constraint half is **binding now**. The signal half is scheduled for the next phase.
> Saved as `docs/adr/0039-client-vantage-reachability-signal.md`.

---

## Metadata
- **ID:** ADR-0039
- **Date:** 2026-08-12
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (constraint in force; signal deferred to Phase 3)
- **Layer(s):** control plane (measure / detect / rotate); cross-cutting (measurement boundary, privacy)
- **Phase:** the **constraint** applies from Phase 2; the **signal** is Phase-3 work
- **Related:** [ADR-0036](0036-node-local-l7-liveness-probe.md) (the loopback boundary this ADR reasons
  from), [ADR-0019](0019-node-local-reachability-health.md) (the frozen probe shape),
  [ADR-0030](0030-advisory-network-awareness.md) (class-aggregate advisory federation — the vehicle),
  [ADR-0017](0017-network-weather-data-contract.md) (weather-publishing privacy contract),
  [RP-0013](../proposals/0013-phase3-e2e-client-recovery.md) (≥2 independent families per node)

---

## 1. Context — the question a node cannot answer

[ADR-0036](0036-node-local-l7-liveness-probe.md) fixes the node-local L7 probe as **pure loopback, no
external packet**, deliberately: an outward probe would manufacture exactly the third-party,
client-vantage fingerprint the project refuses to create. That decision is sound and is not reopened
here. Its consequence, however, was never written down:

> The loopback probe answers *"is my listener serving?"* It does not answer, and cannot answer,
> *"can a client reach me over this transport?"* — because the node is not on the client's network.

Those are different questions with different failure modes. A listener can be perfectly healthy while
every client on a given path fails to reach it, and the node's own evidence is identical in both cases.

**This was measured, not reasoned.** On 2026-08-11, a deliberate loopback-only fault was injected on
three live nodes against the transport each was treating as active. On every node the loop behaved
exactly as designed on the way down — verdict `clean → throttled → shutdown`, `impaired_streak` reached
`flip_confirmations=3`, and it applied a rotation unattended, removing the impaired inbound. And on the
way back: within one minute of the fault clearing, the verdict returned to `clean` — **for a transport
that was no longer being served at all.** `internal/measure/measure.go` seeds every registry member
`spec.ConnStateClean` at construction, and the daemon restarts on every spine change, so a `clean`
verdict for an unserved member is *manufacturable* rather than observed.

So the rotation loop was consuming, for a client-vantage question, a signal that is
(a) about the listener, not the client, and (b) not even meaningful once the member stops being served.

## 2. Decision

### 2.1 The constraint — binding now

A node **MAY** suppress a served transport only on evidence it is **entitled to produce**: that the
transport is faulty *at the node*. Concretely, the permitted evidence is the loopback L7 verdict, engine
liveness, listener bind state, and render/validate refusal — all of which are statements about the node
itself.

A node **MUST NOT** suppress, demote, or otherwise remove a served transport on the basis of any
inference about the client's network. In particular it must not treat **absence of traffic** as
impairment: silence is indistinguishable from "nobody needed that family today", and the two demand
opposite responses.

Where a node holds only client-vantage *suspicion*, the correct action is to **report and preserve
diversity**, never to reduce it. This follows from [RP-0013](../proposals/0013-phase3-e2e-client-recovery.md):
a client blocked on family A is served by family B, so the cost of wrongly removing A — a family that
works for somebody else — strictly exceeds the cost of leaving A standing for clients who cannot use it.

**Corollary, stated because it was violated:** a node serves a **set** of transports, for clients with
different constraints. There is no single "active member" whose health stands for the node's. Any
planner input shaped around one active transport is a defect against this ADR and against
[ADR-0034](0034-unified-node-profile.md).

### 2.2 The signal — Phase 3

The only evidence of client-vantage reachability is evidence that **originates at a client**. Three
sources exist; exactly one is direct.

| # | Source | What it establishes | Strength |
|---|---|---|---|
| 1 | **A client reports it** — "family A did not come up for me", sent over a family that did | Client-vantage reachability, directly | The only direct evidence |
| 2 | **Traffic disappearance against the node's own baseline** — per-inbound session counts (sing-box Clash API exposes `inboundTag` per connection; verified present on a live node) | That a family which *was* being used stopped being used | Evidence, not proof. Says nothing about a family nobody uses |
| 3 | **Another node dials it** | That the listener is reachable **from that node's network** | Settles "listener broken"; says nothing about the client's path |

Source 1 is the one this ADR schedules. It is **not a new mechanism**: it is the client-side half of the
class-aggregate weather shape already adopted in [ADR-0030](0030-advisory-network-awareness.md) and
constrained by [ADR-0017](0017-network-weather-data-contract.md), which ships **inert** today
(RP-0011 AC-2 is scored PARTIAL for exactly this reason). What is new here is naming *why* it is
load-bearing rather than merely nice: without it, no node in this design can ever learn that a transport
has become unreachable for the people it exists to serve.

**Privacy shape — inherited, not invented.** Whatever a client emits is bound by the existing contract:
per-**class** health only, never per-node or per-endpoint; k-floored aggregates; no client identifier, no
per-client history, nothing that reconstructs "who used what". A report that cannot be aggregated
k-anonymously is not sent. The node stores the aggregate, not the reports.

**Explicitly out of scope**, so the deferral is not read as a blank cheque: no client telemetry beyond
per-class reachability outcome; no timing, volume, or destination data; no always-on reporting channel
(a report rides an already-open session, or it does not happen); and no coordination — this is advisory
federation, per ADR-0030, not a control channel.

## 3. Consequences

**Positive.** The rotation loop stops drawing conclusions from a signal that does not contain them. The
node's own faults remain fully actionable, which is the majority of what a single node can fix. The
client-vantage gap becomes *stated* rather than silently mis-served, and the work to close it has a home.

**Negative, and accepted.** Until the signal ships, a transport that is blocked for every client while
its listener stays healthy will not be detected by the node, and the node will keep serving it. That is
the correct behaviour under this ADR — it costs a family's worth of capacity, not a client's
connectivity, because ≥2 independent families is the floor — but it must not be described as detection.

**Operational.** Because the node cannot see the failure, the operator must be able to. A suppression,
and a family whose traffic has vanished against its own baseline, are both **reportable events** —
metric, alert, and a line in `fungi status` — not silent state.

## 4. What would change this decision

- A probe shape that produces client-vantage evidence **without** creating a third-party fingerprint.
  ADR-0036 currently judges this impossible; a concrete construction would reopen it.
- Evidence that source 2 (traffic-baseline disappearance) discriminates reliably enough on real
  populations to act on. It would still not license suppression on its own — but it could raise an
  alert with a much lower false-positive rate than "family idle".
