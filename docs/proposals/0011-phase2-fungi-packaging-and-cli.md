<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0011: Phase-2 fungi-role packaging + deployment/management CLI

## Metadata
- **ID:** RP-0011
- **Slug:** `phase2-fungi-packaging-cli`
- **Status:** **active** (Phase-2 **Operability & Release** track; the signed Phase-1 GO is recorded in [phase1-acceptance-ledger.md](../phase1-acceptance-ledger.md)). Scope **expanded 2026-06-20** to the full operability program — the unified node model, the installer + management CLI, node diagnostics + a redacted bug-report bundle, and the CI/release/badges surface — sibling to the cross-cutting Advisory Network Awareness increment ([ADR-0030](../adr/0030-advisory-network-awareness.md)); **no phase renumber** (the ADR-0030 no-ladder-number precedent).
- **Phase:** Phase 2 — **Operability & Release track** ([ROADMAP](../ROADMAP.md) Phase-2 deliverable (b)): the package + installer + management CLI + diagnostics + CI, plus the introduction *mechanism* (inert seam); the live anastomosis *bridge runtime* is exercised at the Phase-2 → 3 boundary and matures in Phase 3–4
- **Type:** multi-chunk operability RP (unified node model + installer + CLI + diagnostics + CI/release), with an inert federation seam
- **Related:** [ADR-0034](../adr/0034-unified-node-profile.md) (**the unified node profile this CLI writes** — one node-local descriptor, capabilities-not-types, the decision behind chunk B); [ADR-0018](../adr/0018-fungi-role-and-opt-in-publish.md) (fungi role / opt-in publish — fungi is a reversible niche, not a type) + [ADR-0029](../adr/0029-community-federated-ingress.md) (anastomosis bridges / two-hop ingress) — this RP specifies the introduction constraints those ADRs deferred; [ADR-0033](../adr/0033-operator-cdn-front-relay-byod.md) (the opt-in BYOD relay-preferred CDN front the CLI's `cdn` verb wires) + [ADR-0032](../adr/0032-xray-automated-toggleable-engine.md) (additive engines); [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md) (build-vs-reuse / F2F federation); [ADR-0030](../adr/0030-advisory-network-awareness.md) (class-aggregate redacted weather — the **sibling** cross-cutting increment + the inert weather slot the node profile reserves); [ADR-0024](../adr/0024-immunity-temporary-cuts-and-signals.md) (Communes/immunity); [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md) (software, not an operated network — the installer's honest framing); [ADR-0012](../adr/0012-go-primary-control-plane-language.md) + [RP-0008](0008-go-spine-distribution-rendering.md) (the Go spine this CLI is built on); [RP-0010](0010-phase2-adaptivity.md) (Phase-2 adaptivity, sibling). Prompted by an operator design note (2026-06-17) and an operator directive (2026-06-20) — *"unify what we have into one node form including the CDN layer; work out the installer + CLI; local log collection for bug reports; a CI pipeline + badges."*

## Rationale

Phase 2 needs Mycelium to become **deployable and manageable by others as a release** — a package with a minimal **deployment + management CLI** — so that additional **fungi** can be stood up and **anastomosis** can be tested at the Phase-2 → 3 boundary. This is the concrete enabler for the federation layer: you cannot test communes joining until a second operator can stand up a fungi from a release in minutes.

It is also the natural home for the maturing Go spine: **continue the shell → Go migration ([RP-0008](0008-go-spine-distribution-rendering.md) P3) through Phase 2**, so the management CLI is the Go-spine binary (already render-time-resident on nodes since RP-0008 P3 chunk 1), not new bash.

Framing: this is **software for resilient, secure connectivity**. It does **not** claim or guarantee anonymity (an anonymity-focused variant is out of scope and may be forked).

## The model

**Commune = a population + its fungi** (the existing immunity/Commune doctrine, [ADR-0024](../adr/0024-immunity-temporary-cuts-and-signals.md)):

```
Commune A:  ordinary nodes A1 A2 A3  +  fungi FA
Commune B:  ordinary nodes B1 B2     +  fungi FB
Commune C:  ordinary nodes C1 C2 C3  +  fungi FC
```

**Fungi is a ROLE / niche, not a second node *type*.** Any sufficiently capable node may temporarily take the fungi-role. Biological framing (also the UX vocabulary):
- ordinary node = **hypha / tissue**;
- fungi = **fruiting body / cap (шляпка) / population coordinator** ("fruiting node").

A fungi does **four things**:
1. **holds** its own node population;
2. **issues/updates the bundle** for its population (the RP-0007 self-replenishing subscription it already serves);
3. **collects redacted network-weather** — class-aggregate, no per-node row ([ADR-0030](../adr/0030-advisory-network-awareness.md));
4. **establishes private bridges with other fungi** (anastomosis).

An ordinary node may "grow" to a fungi if it knows its **address/key** — but an ordinary node need **not** know the whole commune, and certainly not neighbouring communes. Knowledge is local and need-to-know.

## Anastomosis — the introduction model

The key property: **the introducer is not a permanent route.** It *initiates fusion* and can then step away.

```
FA knows FB and FC.
FA is NOT obliged to be the forever-route between FB and FC.
FA MAY offer to introduce them.
If FB and FC BOTH consent, they create a direct private bridge.
FA can then be turned off; FB ↔ FC stay connected.
```

This is *stronger* than ordinary friend-to-friend: the network can **close useful links itself**, so it survives the loss of any single fungi. (Briar-style contact-introduction is the proven primitive — see [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md).)

### Hard constraints — no auto-clique
Auto-introducing everyone to everyone produces a fast-growing clique → structure leakage, attack-surface growth, uncontrolled trust, and a near-global map via neighbours. Therefore, by construction:

- **max introduction depth: 1–2 hops** (a policy, not a constant);
- **max degree per fungi** (bounded number of live bridges);
- **TTL on bridge invitations** (a scoped, expiring capability — a spore, [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md));
- **double opt-in** (both fungi must consent; never one-sided);
- **no neighbour-list sharing** (a fungi never reveals who else it peers with);
- **no automatic transitive trust**; **no "friend-of-friend is trusted."**

Plus the [ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md) anastomosis rules: a **new** bridge starts **thin** and cannot become thick without earned, observed good behaviour (anti population-on-population attack); a captured node/fungi is **contained** (no malicious propagation along anastomoses).

### The invariant
> **A fungi MAY introduce. A fungi MUST NOT enumerate.**

This is the federation analogue of [ADR-0030](../adr/0030-advisory-network-awareness.md)'s "advisory, never a map": introduction is a consented, scoped, expiring act; enumeration (a list/graph of peers, transitive neighbour discovery) is forbidden by construction.

## Scope

**In scope (Phase 2):**
- A **release package** of the Go-spine control binary + the deployment/management CLI (continuing [RP-0008](0008-go-spine-distribution-rendering.md) P3 so the renderers are Go, not bash).
- A **minimal management CLI** for the fungi-role: stand up / tear down a fungi; manage its population; issue/refresh its bundle; publish its redacted class-aggregate weather ([ADR-0030](../adr/0030-advisory-network-awareness.md)); and the **bridge-invitation mechanism** with all constraints above (double opt-in, TTL, depth/degree caps).
- The introduction mechanism's **inert/seam parts** land behind proof gates (like the existing weather/immunity schemas) — the *issuing and consuming of a scoped, double-opt-in, TTL-bounded bridge invitation*, with **no neighbour enumeration anywhere**.

**Deferred (Phase 2 → 3 boundary / Phase 3–4):** the live anastomosis bridge runtime (FB ↔ FC carrying traffic, FA stepping away), per the trajectory discipline (ROADMAP / MYC-F006). Phase 2 proves the package, the CLI, and the introduction *mechanism*; the federation *runtime* is exercised at the boundary and matures next.

**Out of scope:** anonymity; global discovery / DHT / gossip; auto-clique / transitive trust (forbidden above); new transport protocols (the set is closed, [ADR-0010](../adr/0010-phase0-transport-set.md)).

## Operability & Release scope (expanded 2026-06-20)

The operator directive of 2026-06-20 expands this RP from "package + CLI" to the full **Operability & Release** track — making a node *one form* that a second operator can deploy and shape in minutes, and making the project's public surface trustworthy and contributable. This is **Phase-2 deliverable (b)**, a **sibling** of the cross-cutting Advisory Network Awareness increment ([ADR-0030](../adr/0030-advisory-network-awareness.md)); it is **not** a new phase number (the ADR-0030 precedent: a ladder number for bridge work invites actuation drift and churns the Phase 3–5 fences for zero benefit — **rejected** there, and the same reasoning holds here).

Gates-first, inert-schema-before-behaviour, additive (a node that adopts nothing new renders byte-identically), and every public artifact positioning-clean. Ordered chunks:

- **Chunk A — CI pipeline + README badges + repo-meta (safe, no live-node touch).** Commit the drafted `.github/` scaffold and **add the missing Go lane** (`go build/vet/test`, `gofmt -l`, `go test -race`, coverage) so a *build-passing* signal is honest rather than a jq-only false-green; make `gofmt`/`shellcheck` strict; add `CONTRIBUTING.md`, a `bug_report` issue template (the landing pad for chunk E), and `CODE_OF_CONDUCT.md`. Badge row mapped from the PyO3 set onto this Go+bash project: **build · gates N/N · coverage · version · go-version · AGPL-3.0 · contribute** — coverage via a **self-hosted shields-endpoint JSON** emitted by CI (no third-party account/token), and a **GitHub Discussions** "discuss" pill in place of a chat channel (decided 2026-06-20). No `codspeed`/`crates.io` analog (no perf harness; Go has no central registry page). No live-node or `operates-a-network` claim in any pill.

- **Chunk B — the unified node descriptor (inert schema + gate first).** Implement [ADR-0034](../adr/0034-unified-node-profile.md): the Go `internal/spec` node-profile type + `control/node.config.example.json` + the `node_profile_single_source` gate; bootstrap/update read it **additively** behind the `write_params` byte-identity pin (a no-new-field node is unchanged). Capabilities, not types; engines stay additive; the [ADR-0030](../adr/0030-advisory-network-awareness.md) weather opt-in slot reserved inert.

- **Chunk C — the management CLI verbs (Go spine, AC-5).** On the existing `myceliumctl` surface (a `fungi` entrypoint/alias): `deploy` (stand up a node from the descriptor + the pinned engine versions), `transport {list|enable|disable} <proto>` (validated against `vocab.json` `operator_toggle_keys`; surfaces the second-engine cost of an Xray-only proto), `status` (what this node is/serves). Each writes/validates the descriptor and shells the existing fail-closed render → validate → promote → rollback path with its no-op-on-identical guard; no new control-decisions-in-bash.

- **Chunk D — the reachability posture (live path + gate).** The `reachable {on|off}` verb + a node-local sentinel/posture (loopback-bind **and** firewall-skip, fail-closed, sshd-anti-lockout preserved), default-on for a public entry but default-**off** for a freshly-installed node that has not opted to advertise; a gate pins default-off + survive-`--update` (the override-merge-persistence pattern). Composes with `ingress`/`front`.

- **Chunk E — node diagnostics + a redacted bug-report bundle.** A `diag collect` verb (Go) that captures versions + unit status + selftest/gate summary + **redacted** recent engine errors into a human-readable bundle the operator eyeballs, then attaches to a GitHub issue. A **redactor** (drops IPv4/v6, the journald `_HOSTNAME`/FQDN, SNI, client UUIDs, REALITY/x25519 and per-protocol secrets, AS/country tokens) and a **`log_bundle_redaction` gate** (cloned from `no_dataplane_pii`, run against a synthetic node seeded with a fake FQDN/IP/UUID/key) **land before** the collector is usable — a raw `journalctl` paste to a public issue is an S0 leak. The bug-report issue template steers user-exposing reports to the private Security advisory and carries a privacy notice. **Landed** (`diag redact` + `diag collect`, v0.2.25–v0.2.28); the redaction *contract* is recorded in [ADR-0035](../adr/0035-diagnostics-bundle-redaction-contract.md) and audited in [Audit-0006](../audits/0006-diagnostics-redactor-pr-audit.md) (`pass`, all conditions closed).

- **Chunk F — CDN-in-CLI + the live local test.** The `cdn enable --domain <subdomain> --transport <frontable> [--mode relay|terminate --ack]` verb that writes/validates the front field (only `{vless-xhttp-tls, vless-ws-tls}`; **relay default**; terminate **requires** `--ack`; never echoes/commits the domain), prints the DNS target + the exact BYOD edge steps, and re-runs the front compile. Then the operator-owned [ADR-0033](../adr/0033-operator-cdn-front-relay-byod.md) P2-4 reachability field test with the operator's own test domain (node-local only) — closing the one outstanding front deliverable.

## Acceptance criteria
- **AC-1 (deployable release):** a second operator can stand up a fungi from the release package via the CLI in minutes (mirrors the Phase-0 one-command bootstrap), with no manual fixups.
- **AC-2 (the four functions):** a stood-up fungi holds its population, serves/refreshes its bundle, and publishes a redacted class-aggregate weather snapshot (ADR-0030 gates stay green).
- **AC-3 (introduction, constrained):** the CLI can issue a bridge invitation that is double-opt-in, TTL-bounded, and depth/degree-capped; a conformance gate proves **no code path enumerates or shares a neighbour list** ("must not enumerate"), and that a new bridge cannot start thick.
- **AC-4 (anastomosis survives the introducer — boundary test):** two fungi introduced via the CLI form a direct bridge; turning the introducer off leaves the bridge intact. (Exercised at the Phase-2 → 3 boundary.)
- **AC-5 (Go-spine, not bash):** the CLI is the Go spine (RP-0008 P3); no new control-decisions-in-bash; `no_new_control_decisions_in_bash` stays green.
- **AC-6 (framing):** the resilient-secure-connectivity voice throughout (no apparatus-specific or jurisdiction framing), no anonymity claim, and no per-node/IP/location leakage in any artifact or CLI output.
- **AC-7 (one node form):** every node is provisioned from **one** node-local descriptor ([ADR-0034](../adr/0034-unified-node-profile.md)); the `node_profile_single_source` gate proves there is no node-TYPE enum and no second divergent default-on profile, postures are default-off/safe-default, and the transport-name mapping is read from `control/vocab.json`. A node that adopts no new field renders **byte-identically** (the `write_params` byte-identity pin stays green).
- **AC-8 (reachability is opt-in and persistent):** the `reachable` posture is **default-off** for a freshly-installed node (no auto-advertise), holds at **both** the bind and firewall layers fail-closed, preserves the sshd-anti-lockout ordering, and survives `--update`; a gate pins all of this.
- **AC-9 (the bug-report bundle is PII-free by construction):** the `log_bundle_redaction` gate runs `diag collect` against a synthetic node seeded with a fake FQDN/IP/UUID/key and asserts the output contains **none** of them (and no real contact); the gate is in the CI merge gate **before** the collector ships.
- **AC-10 (honest CI + positioning-clean badges):** the CI merge gate compiles, vets, tests, and race-checks the Go spine (not jq-only) so a *build-passing* badge reflects a real build; every README pill is positioning-clean (no banned framing, no `operates-a-network`/uptime claim, no contact leak), and the version/go-version pills derive from `internal/spec.Version` + `go.mod` to avoid drift.

## Risks / notes
- The release widens who can run a fungi → the sybil/abuse surface; mitigated by invite-only peering + the thin-by-default / earned-thickness rule + capture-containment ([ADR-0031](../adr/0031-build-vs-reuse-compose-proven-patterns.md)).
- "Must not enumerate" is the load-bearing privacy invariant — it must be a *gate*, not a guideline.
- This RP depends on RP-0008 P3 maturing the Go renderers; sequence it after the bundle renderer ports so the CLI manages Go-rendered artifacts.
