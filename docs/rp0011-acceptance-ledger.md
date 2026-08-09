<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0011 acceptance ledger — Phase-2 fungi packaging + management CLI

**Scored:** 2026-08-09 · **Against:** `internal/spec.Version` 0.2.75 · **Verdict: NOT ACCEPTED.**

[RP-0011](proposals/0011-phase2-fungi-packaging-and-cli.md) has been `Status: active` with no ledger
behind it. Audit-0011 #19 named that as the defect: an RP with ten acceptance criteria and no scoring is
a plan that cannot fail, and three of its criteria were being read as met when they were not.

This file scores AC-1..AC-10 and says which are deferred and why. It is the document to resync at tag
time — the sentence in [phase2-acceptance-ledger.md](phase2-acceptance-ledger.md) that claimed a signed
release tag existed stood uncorrected for eight days precisely because nothing owned re-reading it.

## The scoring rule

**MET** requires evidence that some *mechanism* produced, not a reading of the source. A gate that runs,
a measured value, an artifact. "The code looks right" is UNMET. This is the same rule the audits apply,
and it is not academic: the dominant defect class in this project all year has been a component
reporting confidently on something it cannot observe, and its twin is a criterion scored from intent.

| | Criterion | Verdict | What decides it |
|---|---|---|---|
| **AC-1** | Deployable release — a first install from the release package succeeds with no manual fixups (see "What AC-1 actually asks", below) | **UNMET** | No release package exists — no tag, `release.yml` has zero runs — so nobody, human or machine, can have installed from one. The deploy path itself is measured: a deliberately wiped node, from-zero, `rc=0` in 50s on 2026-08-09, a client on a second host reaching it over the public internet. Two blockers found since, both live: `fungi deploy` refused `--singbox-sha256`, which QUICKSTART tells every non-amd64/arm64 operator to pass; and the default AmneziaWG client config carries `AllowedIPs = <tunnel>/24`, so it handshakes and routes nothing while every status surface reports success — QUICKSTART did not mention routing at all. Both fixed in 0.2.75. |
| **AC-2** | The four functions — holds its population, serves/refreshes its bundle, publishes a redacted class-aggregate weather snapshot | **PARTIAL** | Population and bundle: MET, exercised on live nodes and by gates. The weather half is **inert** — the aggregate exists, nothing publishes it. Deferred to Phase 3 per Decision B. |
| **AC-3** | Introduction — a TTL-bounded, depth/degree-capped, double-opt-in bridge invitation; a gate proves no path enumerates a neighbour list | **UNMET, DEFERRED** | No `bridge` or `invite` verb exists in either surface; full dispatch was read to confirm it. The **must-not-enumerate** half is MET and gated independently, which is the half with a safety property attached. Deferred to Phase 4/5 per Decision C. |
| **AC-4** | Anastomosis survives the introducer | **DEFERRED** | Explicitly scoped by the RP itself to the Phase-4 → 5 boundary. Not a debt against this release. |
| **AC-5** | Go spine, not bash — no new control decisions in bash | **MET** | `no_new_control_decisions_in_bash` is green in the suite. ADR-0038 tightened the pattern: Go owns the predicate and emits numbers into `control/vocab.json`; shell compares and never re-derives. |
| **AC-6** | Framing — no apparatus-specific or jurisdiction vocabulary, no anonymity claim, no per-node/IP/location leakage | **MET** | `check_ppn_wording` gates it and also scans **commit messages** (it has caught a real one). Every IPv4 literal in the tree is a well-known or an IETF assignment; identity, params, rendered configs, snapshots and audits are gitignored. One live regression was found and fixed under this criterion: THREAT-MODEL carried a "no logs" sentence the engine configuration contradicts. |
| **AC-7** | One node form — a single node-local descriptor, no node-TYPE enum, byte-identical render for a node adopting no new field | **MET** | `node_profile_single_source` and the `write_params` byte-identity pin are both green. |
| **AC-8** | Reachability opt-in and persistent — default-off, fail-closed at bind *and* firewall, sshd anti-lockout preserved, survives `--update` | **MET** | Gated, and confirmed on a from-zero install: the converge is ordered so a dying run leaves the node firewalled, and the ufw step parses the live sshd port and only ADDS rules. |
| **AC-9** | The bug-report bundle is PII-free by construction | **MET as a mechanism, was UNREACHABLE as a product** | `log_bundle_redaction` drives 21 real values across every PII class through the real binary, plus three over-redaction invariants. But until 0.2.74 **nothing put any `myceliumctl` on `$PATH`** and the only file of that name on a node is the shell tool, whose dispatch has no `diag` verb — while `SECURITY.md` and the bug-report template both told reporters to run `myceliumctl diag collect`. The redactor existing is not the redactor being reachable. Closed by `fungi diag`, gated by `fungi_scoped.sh`. |
| **AC-10** | Honest CI + positioning-clean badges | **MET** | The merge gate compiles, vets, tests and race-checks the Go spine. One dishonesty was found and fixed under this criterion: the gates pill counted *files* — including one gate CI can never run — and called the number "passing". It now says "defined". |

**Met: 5 · Partial: 1 · Unmet: 2 (one deferred) · Deferred outright: 2.**

## What AC-1 actually asks — and why it does not ask for a second human

The audit proposed closing AC-1 with "a fresh VPS, a second pair of hands, QUICKSTART verbatim". The
project operator objected: three disposable test nodes exist precisely so that a machine can do this.
They are right that **"a second operator" is a proxy, not the property.** The property is:

> A machine carrying none of this project's state installs a node using only what the documentation
> says, and ends with a client on a different host actually carrying traffic through it.

A machine is *better* than a human at most of that: it is repeatable, it can be turned red by a mutation,
it cannot quietly apply knowledge the doc does not contain, and one human succeeding proves nothing about
the next reader. So the bar above replaces the person.

**But the substitution has a real limit, and pretending otherwise would repeat the mistake this audit
exists to correct.** A harness is the maintainer's tacit knowledge compiled to executable form: every
assertion it makes is a decision, and — decisively — **every assertion it omits leaves no trace**. A gate
re-answers a question someone already thought to ask. It cannot ask a new one.

That is not theoretical. It is how the two live defects above were found. Neither is a comprehension
failure a doc reviewer could catch, because the doc was not ambiguous — it was *silent*. And neither
would have failed any rung of the obvious assertion ladder: `deploy` exits 0, `fungi status` shows the
listeners, the port answers from a second host, and the AmneziaWG **handshake completes**, because
`AllowedIPs` is client-side routing policy and has no bearing on a handshake. A harness written before
the finding passes at every rung. Only "compare the observed egress address, per family" catches it —
and that assertion exists solely because someone asked why their address had not changed.

So AC-1 is scored against the property, and the drill is machine-driven — with two conditions recorded
here rather than discovered later:

1. **The end-state assertion is per-family egress, from off the node**, not `rc=0` and not the node's
   own self-report. `fungi status` reads local binds and the L7 probe is loopback-only by design
   (ADR-0036); neither observes whether a client's traffic actually arrives.
2. **The harness's own inputs are published as a diff against the document** — every parameter it
   supplies and every placeholder it resolves. A parameter the doc does not tell a reader to supply is a
   documentation defect the harness would otherwise absorb silently.

What this bar does **not** cover, stated so the ledger does not overclaim: whether the prose is
comprehensible to someone who has never seen the system, and whether the stated prerequisites can be
obtained at all. The second is currently failing — QUICKSTART lists the maintainer's signing key as a
requirement and then says it is not published anywhere. No machine can notice that a prerequisite is
unobtainable; it just takes the other branch.

## What actually blocks the tag

Not the unmet criteria — AC-3 and AC-4 are deferred by decision, and AC-2's inert half is Phase 3. One
thing blocks it:

**The signing key is unpublished.** `allowed_signers` is not tracked, so nothing can verify a tag, and
`scripts/verify-release.sh` cannot run in signed mode for anyone. As of 0.2.74 the release workflow
**refuses to publish** when that file is absent (`release.yml`, "the tag is signed by the operator key")
rather than producing an artifact whose authenticity root is unverifiable. That refusal is deliberate:
it converts an invisible gap into a loud one at exactly the moment it matters.

Two things remain unrehearsed and should be done in the same sitting as the tag:

- **`release.yml` has never executed.** `gh release create` and the asset upload are a hypothesis. A
  failure there leaves a pushed *signed* tag with no assets — the worst state, because QUICKSTART then
  resolves to a real, empty release directory. Push a throwaway RC as a draft, confirm both assets land,
  delete it.
- **AC-1's real bar needs a second pair of hands** — someone who is not the maintainer, following
  QUICKSTART verbatim, with nothing else open, on a fresh VPS. That run is simultaneously the proof for
  AC-1 and the first execution of the tag-resolution and `verify-tag` branches in the update path.

## The finding this ledger exists to record

The from-zero measurement on 2026-08-09 was run to *confirm* a deploy path everyone believed worked.
It failed — `rc=1` after 50 seconds with **not one line of error**, sing-box already promoted, AmneziaWG
half-configured. The cause was one line resolving the AmneziaWG port from a cache that does not exist on
a machine that has never run this software; under `set -euo pipefail` the assignment's failure status
killed the bootstrap, and a `2>/dev/null` swallowed the only clue.

**The first install had therefore never worked for anyone without pre-existing state.** Every node in
this network was bootstrapped before that shape existed, so none of them could notice, and no gate
looked — the whole suite runs against fixtures that already have state. Five more instances of the same
construct were found and fixed as a class; `bootstrap_from_zero_survives.sh` now drives the exact line
against a genuinely empty state directory and greps the class across every lib.

That is the argument for AC-1 being scored UNMET rather than "basically fine": the one property nobody
had measured is the one that was broken, and it took wiping a production node to see it.
