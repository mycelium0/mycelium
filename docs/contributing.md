<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Contributing to Mycelium

> **Status:** canon-adjacent. Onboarding guide for making changes to Mycelium. Does not supersede
> canon — it makes canon concrete for contributors.
>
> **See also:** [development.md](development.md) (primary reference),
> [refactoring.md](refactoring.md) (audits, severity, gate criteria),
> [ARCHITECTURE.md](ARCHITECTURE.md) (layers 1–5),
> [THREAT-MODEL.md](THREAT-MODEL.md) (adversary, assets, opsec),
> [ROADMAP.md](ROADMAP.md) (phases 0→5), [commit-template.txt](commit-template.txt).

Mycelium is a persistent private network that protects real people. The contribution bar is
therefore higher than a typical OSS project: **user safety is functional requirement #1**
([THREAT-MODEL.md](THREAT-MODEL.md)), not a checkbox at the end of a list. This document traces
the path from "I see what needs doing" to "change lands in `main`": how to scope work through
RP/ADR, how a unit of change is structured, what code/tests/docs are required, how authorship is
tracked, which contributions are disqualified on security grounds, how review works, and what the
licensing situation is.

If you are reading this before writing your first line — good. Read [THREAT-MODEL.md](THREAT-MODEL.md)
and [ARCHITECTURE.md](ARCHITECTURE.md) first: half of what looks like a "useful feature" is an
attack surface in this project.

---

## 1. Before writing code

### 1.1. Understand the layer and its boundary

Every change lives in one of five layers ([ARCHITECTURE.md](ARCHITECTURE.md)):

| Layer | Responsibility | What it does NOT do |
|---|---|---|
| **1. Data** | tunnel + obfuscation, multi-protocol, indistinguishability | does not select routes, does not hold a network map |
| **2. Control** | keys, configs / config distribution, network interference detector, auto-rotation, telemetry | does not tunnel traffic, does not hold PII |
| **3. Routing** | path selection ingress→egress, multi-hop, rerouting | does not implement transport, does not distribute membership |
| **4. Discovery** | who is in the mesh, how to join, sybil defence, NAT traversal | does not select obfuscation parameters |
| **5. Consumption interface** | standard protocol endpoints consumed by off-the-shelf clients (out of scope — a bespoke client is explicitly out of scope; possible future work) | does not make control-plane decisions for the server |

> **Boundary reminder:** layer 1 does not route; layer 2 does not tunnel and does not log PII;
> a node/hop "knows little" (development.md §2.2 point 6); the coordinator (phase 3) is not an
> indispensable kill-switch (§2.2 point 5).

If your change blurs a layer boundary it is not a "minor tweak" — it is an architecturally
significant change and needs an RP or ADR (see below).

### 1.2. Choosing work: via RP or ADR, not "I'll just push"

Mycelium is driven by documents, not commits. Which artefact is required depends on the nature
of the change:

| What you are doing | Required artefact | Location |
|---|---|---|
| Adopting an architectural **decision** (choosing a transport, trust model, truth-ownership, config-distribution format) | **ADR** | `docs/adr/NNNN-<slug>.md`, ID `ADR-NNNN` |
| **Structural change** to something existing (refactor, new component, contract change, new transport adapter) | **Refactoring Proposal** | `docs/proposals/NNNN-<slug>.md`, ID `RP-NNNN` |
| Trivial truth (typo in a doc, docstring, local fix with no contract/boundary change) | nothing — ordinary type-prefix commit | — |
| Broken `main` (red CI) | **fix-forward only** (see §6.4) | — |

"Architecturally significant" is defined by the criteria in
[refactoring.md §3](refactoring.md): new or changed contract (config distribution endpoint,
control-plane envelope, telemetry schema, discovery API, transport adapter), change of
truth-ownership (§2.4 development.md), new transport or node class, change to the trust model /
sybil defence / NAT traversal, change to the network interference detector or auto-rotation loop, change
to **what is collected about users**.
When in doubt, open an RP: a redundant RP is cheaper than irreversible drift.

**Numbering** (zero-padded, 4 digits, monotone, separate sequence per type): `ADR-NNNN`,
`RP-NNNN`, audits `Audit-NNNN`. Slug — kebab-case
(`0007-vless-reality-as-primary-transport.md`). Templates live in
[templates/](templates/): [adr.md](templates/adr.md),
[refactoring-proposal.md](templates/refactoring-proposal.md),
[audit.md](templates/audit.md).

> **Rule:** every architecturally significant commit references an RP or an ADR in a **trailer**
> (`Refs: RP-NNNN` / `Implements: ADR-NNNN`), never in the subject (development.md §6.2). The
> subject itself is a type-prefix line. This requirement is also embedded in
> [commit-template.txt](commit-template.txt).

### 1.3. Align before you implement

Mycelium **does not accept large unsolicited changes** as a surprise. The order is:

1. Open an RP/ADR in status `draft` (for RP) / `proposed` (for ADR) and discuss.
2. Wait for it to move to `approved` / `accepted`.
3. Only then implement.

An RP that touches security/network resilience (new transport, control plane, trust model,
what is collected about users) almost always triggers an **event audit**
([refactoring.md §4.4](refactoring.md)) — factor this into your plan; do not leave it as an
afterthought.

---

## 2. Anatomy of a single change

A good Mycelium change is **small, verifiable, single-step, and auditable**. One RP = one
coherent step. Do not bundle multiple architectural shifts into one un-reviewable commit
(development.md §11.3 — this is an explicit prohibition for agents and bad practice for humans).

Typical composition:

1. **Branch** by prefix (development.md §6.1):
   `feature/*` · `refactor/*` · `fix/*` · `rfc/*`. `main` is stable; direct pushes to it are
   not made.
2. **Code** in the correct layer, without violating boundaries (§1.1).
3. **Tests alongside the change** (§4): unit + contract at a minimum; transport/detector/rotation —
   plus network-degradation conformance and/or netsim.
4. **Documentation in the same change** (§5): code without updated documentation is not done
   (development.md §12.3).
5. **Commit(s)** per [commit-template.txt](commit-template.txt): a type-prefix subject, a
   `Verification:` block, and the RP/ADR reference in a trailer (`Refs:`/`Implements:`) (§3).
6. **PR** with required sections (§6), including **threat-model impact**.

> **Where things live.** Idealised repository tree (development.md §6) —
> `nodes/` (node: data plane, local control-agent), `control/` (control plane / coordinator),
> `infra/` (Terraform/Ansible), `docs/`, `tests/`. The actual tree may differ — that is
> acceptable **if the same architectural boundaries are preserved**; accepted deviations are
> recorded in an ADR, not silently tolerated.

---

## 3. Authorship

### 3.1. Author is always the operator

The commit `Author` in the repository is always **mindicator** (the operator)
(development.md §1.3) — the identity is set in local git config, not spelled out in the docs.
The operator remains the author and reviewer of canon.

### 3.2. No AI/tool/model attribution in commit messages

Commit messages and trailers must contain **no AI, tool, or model attribution of any kind**.
Remove every `Co-authored-by:` trailer that names an AI system, model, or code-generation
tool. Documentation-level credit is carried at the doc level as
**mindicator & silicon bags quartet**; it does not appear in git history.

When an agent prepares a delta, the operator reviews and commits it as their own work — the
commit carries only **mindicator** (the operator) as author, with no model footer. This is the
required practice, not a style preference.

**Why this rule exists.** Clear, unambiguous commit history is part of the auditability of a
tool that protects people operating across unreliable networks. Commit history must reflect human-reviewed,
human-owned decisions without noise or external attribution that could complicate legal or
operational review.

### 3.3. Rules for agents (development.md §11)

An agent **must**: work through a PR; update documentation alongside code; respect
contract/envelope discipline; run tests; leave a clean, reviewable diff. An agent **must not**:
change the core without explicit scope; bypass tests or audits; make direct mutations in
production; add hidden dependencies; change canon without an RFC/ADR; introduce PII, hardcoded
endpoints or keys, or custom cryptography; bundle multiple architectural steps into one
un-reviewable commit.

Preferred model: one agent writes, a second reviews (particular attention to `no_pii` /
`no_hardcoded...` / `no_custom_crypto`), human approves canon.

---

## 4. Code and test requirements

### 4.1. Code

- **Language for control agents** — Go ([ADR-0012](adr/0012-go-primary-control-plane-language.md)):
  a single static binary in the libp2p/sing-box ecosystem. Rust is reserved for sealed
  high-assurance components behind a shared spec. Any consumption-interface layer (out of scope —
  standard off-the-shelf clients connect to standard endpoints) would use TypeScript/React, strict.
- **Standards** — linter/formatter/typing per [development.md §1](development.md); public surface
  with types and docstrings; no magic strings/numbers, no hardcoded network identifiers, no
  unnecessary `Any`.
- **Contracts, not internals.** Layers communicate through contracts (config-distribution format,
  control-plane envelope, telemetry schema, discovery API, transport adapter), through events,
  and through selecting *parameters* on top of standard primitives — do not reach into the
  internal fields of another component (development.md §2.2).
- **New transport/node type — only through the adapter contract**, with no changes scattered
  "across the whole tree" (§2.2 point 7). If manual core surgery is required, that is a defect in
  the contract model; open an RFC.
- **Idempotency and anti-flap.** Control-plane commands are idempotent; the auto-rotation loop
  has limits, anti-flap guards, and rollback — no silently bypassing limits (§2.2 point 4).

### 4.2. Tests (development.md §7)

A test goes **in the same change** as the code. Categories:

- **Unit** — local logic (network interference detector, path selection, config-distribution parser).
- **Contract** — schema conformance (envelope, config distribution, telemetry, discovery,
  transport adapter).
- **Integration** — interaction between adjacent layers.
- **Conformance (gate-suite, §7.4)** — `no_pii`, `no_hardcoded_secrets_endpoints`,
  `no_custom_crypto`, `envelope_discipline`, `idempotency`, `rotation_safety`,
  `transport_adapter_contract`.
- **Network-degradation / obfuscation (§7.2)** — active probing of the cover site returns the real donor
  site; ClientHello profile within upstream corridor; statistical flow shape resembles HTTPS/QUIC;
  obfuscation parameters chosen by layer 2 actually reach layer 1.
- **Netsim (§7.3)** — behaviour under controlled network interference (tc/netem, RST injection,
  throttling, shutdown, flap) with a **measurable recovery SLO** and regression on labelled
  incidents (detector precision/recall).

Minimum per §7.6: every new component — unit + contract; every new contract — contract; every
transport adapter — network-degradation conformance + adapter-contract; every detector/rotation change —
netsim with SLO; every regression bug — regression test; everything that touches user data —
`no_pii`.

> **Socket/Docker/netem tests (§7.5).** Some network-degradation and netsim suite tests open real sockets,
> netem, or Docker. They **must not** be treated as failing merely because a standard sandbox
> blocks bind/connect/Docker. Run them in your local dev environment
> (`make test-degradation`, `make netsim SCENARIO=...`,
> `docker compose -f tests/netsim/compose.yml up --build`) and record this in the RP report
> and in the commit's `Verification:` block.

---

## 5. Documentation requirements

Documentation is updated **in the same change**. Code without it is not done
(development.md §12.3); canon changed only in code is not canon.

Required updates when (development.md §12.2):
- layer or boundary changes;
- contract changes (config distribution / envelope / telemetry / discovery / adapter);
- truth-ownership change (§2.4);
- new transport or node class is added;
- trust model / sybil defence / NAT traversal changes;
- network interference detector or auto-rotation loop changes;
- **what is collected/stored about users changes** — this triggers an update to
  [THREAT-MODEL.md](THREAT-MODEL.md), not just the code;
- version bump (version-hygiene §1.2: touching a version constant → update the component's
  README header and its CHANGELOG entry in the same commit).

A new component carries a **service passport**: `README.md` (version, layer, role in one
paragraph, "knows / does not know" table, public API, config distribution / events,
honest limitations) and `CHANGELOG.md` (Keep-a-Changelog, SemVer; first entry
`## [0.1.0] — YYYY-MM-DD`).

Architectural decisions and contracts do not live "in someone's head" and are not deferred:
the ADR/RP is opened at the same time as canon changes.

---

## 6. Review process

### 6.1. A PR must contain (development.md §6.3)

For architecturally significant changes:
- description of the problem;
- list of affected layers/components;
- updated contracts (config distribution / envelope / telemetry / discovery / adapter);
- tests (including, where relevant, network-degradation conformance and netsim);
- updated documentation;
- **threat-model impact** — does the change affect assets in THREAT-MODEL (user identity/location,
  traffic content, ingress reachability, operators, network map) and how; does it introduce new
  PII, hardcoded values, or custom cryptography;
- indication of whether an **event audit** is needed (new transport, new node class, trust-model
  change, control-plane change — usually yes).

### 6.2. Audit and gate criteria

A PR audit is conducted for every architecturally significant PR
([refactoring.md §4.1, §16](refactoring.md)). Merge is **blocked** if
(development.md §10 / refactoring.md §14):
- lint or type-check fails;
- contract / conformance tests fail (especially `no_pii`, `no_custom_crypto`,
  `no_hardcoded_secrets_endpoints`);
- documentation has not been updated;
- unresolved **S0/S1** findings remain in the associated audit.

Severity reminder: `CUSTOM_CRYPTO`, `PII_LEAK`,
`HARDCODED_ENDPOINT_OR_SECRET`, `STATE_DUPLICATION` are **S0**, blocking merge
(development.md §2.2). These are not style comments.

### 6.3. Who approves

Canon is approved by the operator. Preferred model: one person writes, a second reviews, the
human approves (development.md §11). Authorship follows §3.

### 6.4. Red master freeze (development.md §6.4)

If `main` is red in CI, the normal flow stops. Only **fix-forward** commits are permitted:
fixing the root cause of the red, minimal version/CHANGELOG/README sync edits required by the
fix-forward itself, and verification evidence. New RP features, unrelated cleanup, and
"while I'm here" changes are forbidden. After the remediation series — a **Closure Verification**
([refactoring.md §12.9](refactoring.md)), not a new full-scale audit.

---

## 7. Security of contributions (read this twice)

This is a persistent private network. The following are not "bad practice" — they are
**disqualifying states for Mycelium** (development.md §2.2, §13). A contribution containing any
of these items is rejected regardless of its merit in all other respects.

### 7.1. No custom cryptography

Only standard, audited libraries and protocols: REALITY/Vision via Xray/sing-box, Noise, the
upstream TLS stack, WireGuard/AmneziaWG **as-is**. Any custom "cipher", "own handshake",
"improved" padding algorithm on top of crypto, or a modified fork of a crypto library — category
`CUSTOM_CRYPTO`, **severity S0**, merge blocked. Selecting *parameters* (AmneziaWG junk packets,
ClientHello/Reality-Vision padding, timings) is configuration on top of standard primitives and
is **permitted**; changing the primitives themselves is not. Crypto/FFI review is especially
strict.

### 7.2. No surveillance telemetry and no PII

Forbidden in logs, events, metrics, telemetry, crash reports, or storage: client source IPs,
client UUIDs linked to activity, SNI/donors linked to a specific client, traffic
content/destination, geolocation finer than a broad region, any stable identifier linking
requests to one user. Category `PII_LEAK`, **S0**. Blocking telemetry is
**aggregated, noised, and not linked to identity** — it is a signal about the state of the
*network*, not a behaviour log of *people*. What is not collected cannot be seized or compelled
(knowledge minimisation, THREAT-MODEL).

### 7.3. No backdoors and no covert channels

- **No silent emergency path** bypassing the rotation policy: all auto-rotation goes through the
  explicit layer-2 loop with limits/anti-flap/rollback. An emergency strategy is an explicit
  policy strategy, not a backdoor (§2.2 point 4).
- **No hidden network channels** bypassing contracts: an undocumented "callback home", hidden
  telemetry channel, or a node contacting an external service not described in its service
  passport — these expand the attack surface and enable de-anonymisation (S0/S1 by context,
  §2.2 point 9).
- **A node "knows little"** (§2.2 point 6) and **the coordinator is not a kill-switch** (§2.2
  point 5): do not give a node/hop knowledge beyond what its role requires.

### 7.4. No hardcoded endpoints or keys

Literal keys, donors, SNI values, IPs, coordinator/bootstrap addresses in code are forbidden
(`HARDCODED_ENDPOINT_OR_SECRET`, **S0**). The reason is twofold: a secret in code is a leak; a
hardcoded endpoint is a single point of blockage (an adversary reads our own code and cuts the
address in minutes). Everything of this kind is configuration / config-distribution / discovery /
ENV — loaded at runtime and rotated without rebuilding.

### 7.5. Dependencies and MCP servers

- A new external dependency expands the attack surface and supply chain — add only for a specific
  need; record *what* and *why*. Imports from projects with licences incompatible with
  proprietary commercial use (GPL-family etc.) require explicit sign-off from Owner
  (development.md §13).
- MCP servers (development.md §11): in `.mcp.json` at the root (committed), added for a specific
  need, tokens via ENV — **not** in the file; what/why is recorded in the commit; removal is an
  ordinary commit; "just in case" is not justification.

> **If you find a vulnerability** (in Mycelium's code or in the way it exposes users) — do not
> open a public issue with exploitation details. Report it privately through GitHub private
> vulnerability reporting (see [SECURITY.md](../SECURITY.md)) and open an event audit if needed.
> For a project that protects people operating across unreliable networks, a public 0-day is a
> direct risk to users.

---

## 8. Licence and contribution rights

Mycelium is **free software**, licensed under the **GNU Affero General Public License v3.0 or
later (AGPL-3.0-or-later)** — see [LICENSE](../LICENSE) at the repository root. Contributions
are accepted under the same license (AGPL-3.0-or-later).

**License rules (development.md §13):**
- for **new** source files (Go/Rust) and significant markdown files, add the copyright header
  per the canonical form carrying the `AGPL-3.0-or-later` SPDX identifier;
- third-party libraries (Xray, sing-box, AmneziaWG, libp2p, …) retain their own licences —
  those apply only to their materials, not to Mycelium;
- visual assets / diagrams / **blocking-measurement datasets** are Project Materials under the
  project licence (AGPL-3.0-or-later);
- AI/ML training or dataset construction on Mycelium materials (including measurement datasets)
  is **prohibited without written permission**.

By submitting a contribution you confirm that you have the right to license it, and you agree
that it is contributed under the AGPL-3.0-or-later terms.

---

## 9. Checklist before opening a PR

- [ ] There is an RP (`RP-NNNN`) or ADR (`ADR-NNNN`) behind the change, and it is `approved`/`accepted` (or this is a trivial type-prefix fix / fix-forward).
- [ ] The change is in the correct layer; layer boundaries are not blurred (§1.1).
- [ ] One coherent step; no bundle of multiple architectural shifts (§2).
- [ ] No PII in logs/events/metrics/telemetry (`no_pii`).
- [ ] No hardcoded endpoints/keys/donors/SNI (`no_hardcoded_secrets_endpoints`).
- [ ] No custom or modified cryptography (`no_custom_crypto`).
- [ ] No silent emergency path and no hidden network channels (§7.3).
- [ ] Unit + contract tests; for transport/detector/rotation — network-degradation and/or netsim with SLO (§4.2).
- [ ] Socket/netem/Docker tests run locally and reflected in `Verification:` (§7.5).
- [ ] Documentation updated in the same change; THREAT-MODEL updated if what is collected about users changed (§5).
- [ ] version-hygiene: touched a version constant → README header + CHANGELOG in the same commit.
- [ ] Commit(s) per [commit-template.txt](commit-template.txt): type-prefix subject, RP/ADR in a trailer (`Refs:`/`Implements:`), `Verification:` block present, no AI/tool/model attribution anywhere in the message or trailers.
- [ ] PR contains threat-model impact and an indication of whether an event audit is needed (§6.1).
- [ ] Copyright header added to new source / significant markdown files (§8).

---

## 10. The governing rule

In Mycelium **user safety is functional requirement #1**.
A change that improves convenience or performance at the cost of de-anonymisation, exposing
ingress points, or weakening indistinguishability **does not pass** — even if it is otherwise
ideal by every other metric. If you are torn between "convenient" and "safe for the user",
choose safety and record the choice in the RP/ADR.
