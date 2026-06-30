<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0035: Diagnostics-bundle redaction contract

> ADR — records **one** decision: how the operator diagnostics bundle (`diag collect`) is made
> PII-safe before it can leave a node for a public bug report. The implementation lives in RP-0011
> chunk E; this ADR is the durable contract behind it.

---

## Metadata
- **ID:** ADR-0035
- **Date:** 2026-06-30
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** control plane (operator tooling) / cross-cutting (logging & knowledge-minimisation)
- **Phase:** Phase 2 — Operability & Release track
- **Related:** [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) chunk E (the diagnostics
  bundle + AC-9); [Audit-0006](../audits/0006-diagnostics-redactor-pr-audit.md) (the PR audit that
  prompted this record); [SECURITY.md §4.2](../../SECURITY.md); [THREAT-MODEL.md](../THREAT-MODEL.md)
  → *"Attack surface: the node diagnostics bundle"*; [refactoring.md §15.3](../refactoring.md)
  (knowledge minimisation is a boundary).

## Context
`myceliumctl diag collect` assembles a node diagnostics bundle (spine/engine versions, unit states, the
recent engine journal) that an operator may **attach to a public bug report** — so it leaves the node.
A raw `journalctl` paste to a public issue is an S0 leak: engine journals carry client/source IPs,
the journald `_HOSTNAME` and SNI/FQDN, client UUIDs, REALITY/x25519 and per-protocol key material, and
AS numbers — and the node's own hostname may be **location-coded** (it encodes country/role, which the
project's OPSEC doctrine treats as top-severity disclosure).

- **Adversary model:** an observer who reads a published bug-report bundle (no network capability
  required). Not a transport-distinguishability adversary — the redactor does not touch the data plane.
- **Affected asset:** operator/node identity & location (asset #1), and any client identity/secret a
  journal line happens to carry.
- **Trade-off:** completeness of redaction ↔ usefulness of the bundle. Redacting *everything* that
  *might* be identifying (e.g. every dot-less token) destroys the triage value the bundle exists for;
  redacting too little leaks PII. The contract must pick a principled line and name what it does not
  cover.

## Considered Options

1. **No structured redactor — rely on operator review only.**
   - Pros: simplest; zero false-redaction.
   - Cons: an S0 leak is one careless paste away; "review carefully" is not a control. Rejected by AC-9.
2. **Whole-line / allowlist redaction (emit only known-safe fields).**
   - Pros: maximal safety.
   - Cons: throws away the journal body that makes a bundle useful for triage; brittle as engines evolve.
3. **Class-based over-redaction with a named residual (chosen).**
   - Pros: scrubs every *structured* PII class fail-safe (when in doubt, scrub more); keeps the bundle
     readable; the residual is small, named, and gated.
   - Cons: a free-floating, unlabelled, dot-less, sub-8-char opaque value is indistinguishable from
     prose and is left intact — an explicit, documented residual the operator reviews.

## Decision
**Option 3 — class-based, fail-safe-by-over-redaction, with a named residual and an own-host belt.**

The contract, now canon:

- **`internal/diag.Redact(s string) string`** is the pure core: an **ordered** set of regex passes,
  deterministic and **idempotent**. Order is load-bearing — the labelled `key=value` and verb-anchored
  passes run first, then the structural classes that own their delimiters (UUID / IPv6 / MAC / IPv4 /
  FQDN), then the generic opaque-token passes — so a broad pass can never fragment a structured value a
  specific rule would scrub whole. **Covered classes:** labelled sensitive fields (bare or quoted
  value), dial/lookup/connect error operands, IPv4/IPv6/MAC addresses, dotted FQDN/SNI, client UUIDs,
  key material (64-hex, x25519 base64url) and opaque tokens (≥8 hex / ≥32 chars), and AS numbers.
- **`internal/diag.RedactBundle(s, selfHost string) string`** is the entry point a **collector** uses:
  it first scrubs the node's own hostname (`selfHost`) by a **word-anchored, length-floored (≥4)** exact
  match — the one node-identifying value a message body may echo unlabelled — then runs `Redact`. Both
  the `diag collect` collector and the `diag redact` stdin verb route through `RedactBundle`. The
  collector additionally reads the journal with `journalctl -o cat` so no per-line `<host>` prefix is
  emitted at the source.
- **Fail-closed posture:** the collector prints **only** `RedactBundle(...)` output, never the raw
  builder; a subprocess fault (missing binary, non-zero exit with no output, or a 10 s timeout) yields a
  bounded `("", false)` / `"(journal unavailable)"`, never a hang or a raw dump.
- **Named residual (accepted):** a free-floating, **unlabelled, dot-less, sub-8-char** opaque value with
  no surrounding key or verb is left intact (redacting every dot-less word would destroy the bundle).
  It carries no structured identity/location linkage, so it is not by itself a `USER_DEANON`. The
  operator remains responsible for a final eyeball before publishing.
- **Accepted design notes:** a redaction sentinel labels the **rule** that fired, not the PII class
  (cheap, honest; no downstream tool reasons by sentinel). The labelled-key list is an **intentional
  superset** of the spec's sensitive JSON tags — it also covers journal/log key shapes
  (`_hostname=`/`peer=`/`sni=`) — so it cannot equal a single spec constant and is owned by the redactor.

No custom cryptography or transport is involved (it is a text redactor). The decision keeps the control
plane's knowledge-minimisation boundary (SECURITY.md §4.2): the one artifact that may leave a node is
redacted by construction.

## Consequences
- **Positive:** an operator can attach a bundle to a public issue with a defined, gated guarantee; the
  redaction is fail-safe, idempotent, and unit/conformance-tested; the contract is documented end to end.
- **Negative / cost:** over-redaction loses some debuggability (absolute journal timestamps dropped via
  `-o cat`; an occasional benign token redacted); the regex set is moderately intricate and must be
  prototyped before edits.
- **Impact on user security (req. №1):** strictly *reduces* what leaves the node; introduces no logging,
  collection, or correlation. The collector is read-only.
- **Impact on observability:** the bundle trades absolute timestamps (PII-adjacent) for chronological
  order; engine versions / unit states / recent (redacted) errors remain.
- **Follow-on actions:** none open — RP-0011 chunk E implements it; Audit-0006 closed the conditions.
- **What is now forbidden:** emitting a diagnostics bundle (or any node-egress artifact) that is not
  routed through `RedactBundle`; printing the raw collector builder; claiming an *absolute* "no PII"
  guarantee in code or docs (the residual must be named).

## Compliance
- **Conformance gate:** `tests/conformance/log_bundle_redaction.sh` — seeds a synthetic bundle with a
  fake value of every class (incl. bare/location-coded host, quoted secret, short `short_id`, MAC,
  mapped IPv6), asserts none survive, asserts the collector prints only `diag.RedactBundle(...)`, and
  pins the non-over-redaction invariants (clock time + "as"+digits survive) and the rule-order invariant
  (no FQDN fragmentation).
- **Runtime tests:** `internal/diag` — `TestRedactScrubsEveryNeedle`, `TestRedactIsDeterministicAndIdempotent`,
  `TestRedactBundleSelfHost` (scrub + word-anchor + length floor + no-corruption).
- **CI gate:** the above run in the strict Go + conformance lanes; merge blocks on a leak or an
  un-redacted collector path.
