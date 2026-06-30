<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Security Policy

> **Status:** canonical. Security policy and coordinated / responsible disclosure.
>
> **See also:** [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) (adversary, assets, attack surface),
> [docs/development.md](docs/development.md) (invariants, forbidden states),
> [docs/refactoring.md](docs/refactoring.md) (severity, audits, named findings),
> [docs/contributing.md](docs/contributing.md) (§7 "Security of contributions"),
> [docs/dependency-policy.md](docs/dependency-policy.md) (supply chain).

Mycelium is software for resilient, private connectivity over degrading or unreliable networks. A
vulnerability in Mycelium is therefore not just "a software bug" — it can **expose an operator's or
user's identity or connection metadata, leak a secret, or compromise a node**. The cross-cutting
principle of the project is that **user safety is functional requirement 1**
([README](README.md), principle 5).

This document describes: what is in scope, how to report a vulnerability privately, how we work with
good-faith researchers, our commitments (no user-tracking telemetry, no backdoors), our supply-chain
posture, and the disclosure timeline.

> **Software, not an operated network.** This security policy covers the software this repository
> publishes. As stated in the [README separation statement](README.md#what-this-is):
> the repository publishes server-side software; it does not operate a public network; it does not
> publish public endpoints; it does not distribute public client configs; and each operator
> independently deploys and controls their own node. Reports about a *specific operator's*
> deployment go to that operator; reports here concern the published software.

**If you have found a vulnerability that exposes users, do not open a public issue with
exploitation details.** A public 0-day is a direct risk to the software's users and operators.
Report privately (see [§2](#2-how-to-report)).

---

## 1. Scope

"Vulnerability" in Mycelium is broader than a classic CVE. We evaluate findings on three project
risk axes — **user safety**, **availability / reachability**, and **metadata confidentiality /
privacy** — graded by the project severity model ([refactoring.md §7](docs/refactoring.md)).

### 1.1. In scope (priority — by severity, see [§5](#5-severity-classification))

- **User identity / metadata exposure** — any means of linking a user's identity or location to
  their traffic or ingress point (`USER_DEANON`, **S0**).
- **Traffic correlation** — a timing / volume / identifier channel linking a user to a destination,
  including via a single hop with knowledge of the full path
  (`TRAFFIC_CORRELATION`, **S0**).
- **Transport distinguishability** — any means of statistically distinguishing Mycelium traffic or
  a Mycelium server from legitimate HTTPS/QUIC, or of triggering a failure under active probing
  (recognisable fingerprint, banner, "extra" port) — anything that gives an adversary a signature
  for mass blocking (`DISTINGUISHABLE_TRANSPORT`, **S0**).
- **Secret / identity leak** — a key, client UUID, REALITY parameters, bootstrap secret, or join
  token appearing in code, logs, unnoised telemetry, or a build artefact
  (`SECRET_LEAK`, **S0**).
- **Hidden channel / backdoor** — an undocumented "call home", covert telemetry, a node contacting
  a service not listed in its service passport, or a silent emergency path that bypasses the
  rotation policy (see [§4](#4-project-commitments)).
- **Single point of blocking/failure** — an architectural defect in which the entire mesh collapses
  or is blocked through one domain, one AS, one SNI, or one indispensable hub with no fallback
  (`SINGLE_POINT_OF_BLOCK`, **S0**).
- **Node enumeration (enumeration / sybil)** — a means of cheaply enumerating a significant
  proportion of ingress nodes through discovery/DHT/registry (`ENUMERATION_EXPOSURE`, S1;
  escalates to **S0** if the majority of ingress nodes are enumerable at phase 4+).
- **Silent degradation** — a fallback that trades indistinguishability / metadata confidentiality
  for availability without an explicit policy (fail-closed violation, `SILENT_DEGRADATION`, **S0**).
- **Cryptographic defects** — incorrect use of standard primitives (broken forward secrecy, nonce
  reuse, downgrade, certificate-verification bypass), and equally any **custom / modified
  cryptography** (`CUSTOM_CRYPTO`, **S0**; see [§4.1](#41-no-custom-cryptography)).
- **Memory safety and RCE** — memory safety, injection, or deserialisation issues in node, control-
  plane, or client code leading to compromise of a node or client.
- **Supply-chain compromise** — a poisoned dependency, upstream substitution, or non-reproducible
  build ([dependency-policy.md](docs/dependency-policy.md)). The self-update path reaches every node,
  so this is especially critical: one poisoned dependency = network-wide compromise.
- **Deployment / infrastructure vulnerabilities** — Terraform/Ansible/CI configurations that
  expose secrets, endpoints, or permit node takeover.

### 1.2. Out of scope

- Reports that amount to "connectivity can be disrupted" or "traffic can be throttled" — this is a
  **known and fundamental** property ([THREAT-MODEL.md "What the project does NOT promise"](docs/THREAT-MODEL.md)).
  Mycelium aims for fast recovery and path redundancy, not guaranteed reachability. A report has
  value only if it demonstrates a *new* class of distinguishability or *degraded adaptation speed*.
- Social engineering of contributors/operators, physical access, brute-force DoS without an
  architectural defect.
- Findings in **third-party upstreams as such** (Xray, sing-box, libp2p, AmneziaWG, Caddy/nginx).
  Report those to the respective project under its own policy; send to us only if the finding
  concerns *specifically* how Mycelium integrates them, or if it affects our supply chain.
- Absence of security hardening that does not lead to a real exploitation vector (best-practice
  observation without exploitable consequence) — welcome as an ordinary RP/audit-finding, not as
  a security report.
- Self-inflicted configurations (a user deliberately disabled indistinguishability, hard-coded
  their own endpoint, etc.).

> **A boundary worth understanding.** Mycelium addresses *technical* connectivity and its security
> properties only. Legal compliance in any given jurisdiction is the operator's responsibility and is
> beyond the power of code; it is not a "vulnerability" in the sense of this document.

---

## 2. How to report

### 2.1. Private channel (default)

Report privately through **GitHub private vulnerability reporting**: open the repository's
**Security** tab and choose **"Report a vulnerability"**
(`https://github.com/mycelium0/mycelium/security/advisories/new`). This opens a private
security advisory visible only to you and the maintainers — no public issue, and no report
contents travelling over plain email.

- **PGP (optional, for out-of-band encryption):** encrypt your report with our public key.
  - **Fingerprint:** `<PGP-FINGERPRINT-PLACEHOLDER>`
    *(Placeholder; the real key and fingerprint will be published and fixed in an ADR —
    see [§8](#8-open-questions-tbd). Until then, request a secure channel through the private
    advisory above and offer your own public key for an encrypted reply.)*
  - The key will also be published in `.well-known/security.txt` and in the repository
    (`docs/security/pgp.asc`) after the ADR is fixed.
- **Do not use** for exploitation details: public GitHub issues, public chats/channels, or
  messengers without end-to-end encryption.

### 2.2. What to include (helps us triage faster and more accurately)

- Finding type and **affected layer** ([ARCHITECTURE.md](docs/ARCHITECTURE.md): data / control /
  routing / discovery / consumption interface) and component.
- Reproduction: steps, versions (component + upstreams), environment, PoC — where possible, a
  netsim scenario ([development.md §7.3](docs/development.md)).
- **Which THREAT-MODEL asset is at risk** (identity/location, traffic content, ingress reachability,
  operators, network map) and how.
- Estimated severity per [§5](#5-severity-classification) and your assessment of impact on a
  *user in the field*, not only technical impact.
- Whether the finding exposes distinguishability usable for **mass** blocking or identity exposure
  (this raises priority).

> **Minimise harm during research.** Do not attack live nodes with real users; do not collect, log,
> or publish third-party traffic, IPs, client UUIDs, or other PII — these are exactly the data
> that the project consciously **does not collect** ([§4.2](#42-no-surveillance-telemetry-and-no-pii)).
> If a PoC requires traffic, use your own or set up an isolated test environment.

### 2.3. What happens next

1. **Receipt acknowledgement** — see timeline in [§6](#6-disclosure-timeline).
2. **Triage and severity** per [refactoring.md §7](docs/refactoring.md). An S0/S1 finding almost
   always triggers an **event-based audit** ([refactoring.md §4.4](docs/refactoring.md)) and is
   opened as `Audit-NNNN` in `docs/audits/` (exploitation details withheld from publication until
   after the fix).
3. **Joint work on the fix**, with you in the review loop if you wish.
4. **Coordinated disclosure** per [§6](#6-disclosure-timeline) and [§7](#7-public-disclosure-and-credit).

---

## 3. Good-faith research

We welcome good-faith security research and will work with researchers who follow this policy. On
request we will acknowledge your contribution ([§7](#7-public-disclosure-and-credit)).

We ask that you:

- report privately and give the project a reasonable time to fix ([§6](#6-disclosure-timeline))
  before any public disclosure;
- **cause no harm to users, operators, or third parties**: do not touch live nodes with real users;
  do not obtain, modify, store, or publish third-party data/traffic; use only your own resources or
  an isolated environment for a PoC;
- **minimise impact**: no more than is needed to demonstrate the finding; no service degradation,
  data deletion, persistence, lateral movement, or exfiltration;
- do not use the finding for extortion and do not trade it;
- comply with applicable law.

This section describes how the project handles reports — it is **not a legal indemnity**. It cannot
grant authorisation you do not otherwise have, and it does not bind third parties: infrastructure the
project does **not** own (a hosting provider, CDN, upstream, or a node run by someone else) has its
own rules and jurisdictions. If you are unsure whether your planned testing is in scope, **ask in
advance** via the channel in [§2](#2-how-to-report), before acting.

---

## 4. Project commitments

These commitments are not marketing — they are **invariants fixed in canon**: a violation of any of
them in code is a blocking merge defect ([development.md §2.2, §10.2](docs/development.md);
[contributing.md §7](docs/contributing.md)). Any contribution that contains any of the items below
does not pass review — regardless of how useful it is in other respects.

### 4.1. No custom cryptography

Only standard, audited libraries and protocols: REALITY/Vision via Xray/sing-box, Noise, the
upstream TLS stack, WireGuard/AmneziaWG **as-is** ([README](README.md) principle 1). Any custom
"cipher", "home-made handshake", "improved" padding algorithm on top of crypto, or modified fork
of a cryptographic library falls into category `CUSTOM_CRYPTO`, **severity S0**, and blocks merge.
Choosing *parameters* on top of standard primitives (AmneziaWG junk packets, ClientHello/Reality-
Vision padding, timings) is permitted; modifying the primitives themselves is not.

### 4.2. No surveillance telemetry and no PII

The project **does not collect** and deliberately **cannot produce** data linking a user to their
activity. It is forbidden to write to logs, events, metrics, telemetry, crash reports, or storage:
client source IPs; client UUIDs in association with activity; SNI/donor in association with a
specific client; traffic content or destination; geolocation more precise than a broad region; any
stable identifier linking requests from the same user (`PII_LEAK` / `USER_DEANON`, **S0**).

- Blocking telemetry is transmitted **aggregated, noised, and not linked to any individual** — it
  is a signal about *network* state, not a log of *people's* behaviour
  ([THREAT-MODEL.md](docs/THREAT-MODEL.md)).
- The target posture for nodes is **no-logs by design**, RAM-only / diskless, with a third-party
  no-logs audit. What is not collected cannot be seized, logged, or compelled (knowledge
  minimisation).
- The one operator-facing artifact that may **leave the node** — the diagnostics bundle produced by
  `myceliumctl diag collect` for a public bug report — is **redacted by construction** (`internal/diag`
  scrubs every structured PII class, fail-safe by over-redaction, with a small documented residual the
  operator reviews). Its full treatment is in
  [THREAT-MODEL.md](docs/THREAT-MODEL.md) → *"Attack surface: the node diagnostics bundle"*.

### 4.3. No backdoors and no hidden channels

- **No silent emergency path** that bypasses the rotation policy: all auto-rotation runs through
  the explicit layer-2 control loop with limits / anti-flapping / rollback. An emergency scenario
  is an explicit strategy within policy, not a backdoor
  ([development.md §2.2](docs/development.md)).
- **No hidden network channels** outside documented contracts: no undocumented "call home", no
  covert telemetry channel, no node contacting a third-party service not described in its service
  passport.
- **A node "knows little", and the coordinator is not a kill switch**: no knowledge is added to a
  node or hop beyond what is necessary for its role.

> **Knowledge-minimisation corollary.** These invariants also bound what an operator can be asked to
> produce: logs, a backdoor, or a single central kill switch that do not exist cannot be handed over.
> This follows the mere-conduit / no-logs posture.

### 4.4. Transparency and reproducibility

- Mycelium is **source-available** ([contributing.md §8](docs/contributing.md)): source code is
  open for audit (this is also part of the legal posture — "publicly available encryption item",
  consistent with the dual-use export-control published-source position).
- Builds are **reproducible** ([dependency-policy.md](docs/dependency-policy.md)): a published
  binary can be matched against source to rule out silent substitution. Reproducibility is the
  verifiable consequence of commitments 4.1–4.3.

### 4.5. Supply-chain and the update path

The self-update path is a first-order supply-chain surface — a poisoned update equals network-wide
compromise — so it is held to *provenance before execution*:

- **Signed before run.** A node verifies the operator's out-of-band signature on the pinned ref
  **before** any fetched code is merged, installed, or executed; an unverifiable ref is refused, and
  the network-update timer runs **only** in signature-verifying mode
  ([development.md §8.7](docs/development.md),
  [ADR-0015](docs/adr/0015-network-artifact-delivery-and-node-update.md)).
- **No shared key material.** Per-node credentials (REALITY / AmneziaWG keypairs, and a self-signed
  certificate only where that transport is enabled) are generated **locally at bootstrap**; key
  material is never copied between operators or distributed network-wide
  ([ADR-0014](docs/adr/0014-per-operator-node-credentials.md)).
- **Certificate pinning, never blanket trust.** Self-signed transports pin the certificate by
  SHA-256; `insecure: true` is forbidden. TLS is transport security only — never node identity.
- **Fail-closed apply.** An update re-renders from the **local** pinned identity (never regenerating
  it), validates before applying, and rolls back to last-known-good on any validation or post-apply
  failure; a byte-identical candidate is a no-op, so an unchanged push causes no needless restart.

---

## 5. Severity classification

Severity of findings follows the project's unified model ([refactoring.md §7](docs/refactoring.md)).
It is built around the three project risk axes (user safety / reachability / metadata
confidentiality), not "code criticality".

| Severity | Description | Examples | Primary-response SLA |
|---|---|---|---|
| **S0 — Critical** | Critical violation of safety, reachability, or metadata confidentiality | `USER_DEANON`, `TRAFFIC_CORRELATION`, `DISTINGUISHABLE_TRANSPORT`, `SECRET_LEAK`, `SILENT_DEGRADATION`, `SINGLE_POINT_OF_BLOCK`, `CUSTOM_CRYPTO`, RCE on node/client, poisoned dependency | see [§6](#6-disclosure-timeline) |
| **S1 — High** | Serious risk without immediate identity exposure; auto-rotation flapping as a signal; `ENUMERATION_EXPOSURE`; `THREAT_MODEL_DRIFT`; `REDUNDANCY_COLLAPSE` | partial ingress enumeration; hardening defect with a real exploitation vector | see [§6](#6-disclosure-timeline) |
| **S2 — Medium** | Localised risk, limited vector, requires special conditions | — | best-effort |
| **S3 — Low** | Minor risk / glass hardening | — | best-effort |

S0/S1 findings are opened as event-based audits (`Audit-NNNN`) and block merge of related changes
until closed ([refactoring.md §14](docs/refactoring.md)).

---

## 6. Disclosure timeline

Coordinated disclosure. Timelines are targets (the project is at an early stage, team of 1–3
people); where there is risk to users we move faster.

| Stage | Target |
|---|---|
| **Receipt acknowledgement** of report | within **72 hours** |
| **Initial assessment + severity** (S0/S1 → event-based audit) | within **7 days** |
| **Regular status updates** to reporter | at least once every **2 weeks** until fix |
| **Default disclosure** (fix + public notice) | **90 days** from acknowledgement, or sooner — once the fix is ready |

**Timeline adjustments:**

- **Active exploitation in the wild**, or a finding that hands an adversary a ready signature for
  **mass identity exposure or blocking** — maximum priority; fix and user notification are prepared
  in emergency mode.
- If the fix requires a coordinated update with an upstream or hosting provider, the timeline may
  be extended by agreement with the reporter, with a stated reason.
- We ask reporters **not to publish exploitation details before the fix is released** — precisely
  because a 0-day in deployed connectivity software directly harms its users. This is the only
  reason for any delay, not an attempt to suppress the issue.

---

## 7. Public disclosure and credit

- After the fix, we publish a notice: affected versions, impact (without a ready weapon where that
  would still endanger users), the fix, and update recommendations.
- The change is recorded in `CHANGELOG.md` for the affected component and, if the attack surface
  or assets have shifted, in [THREAT-MODEL.md](docs/THREAT-MODEL.md) (otherwise
  `THREAT_MODEL_DRIFT` is itself a finding).
- **Credit at the reporter's discretion:** we are happy to acknowledge you (name/handle/link) or
  keep you anonymous — whichever you prefer. Respect for your own opsec is part of the culture.
- There is currently **no bug bounty programme**; if one is introduced it will be announced
  separately and fixed in an ADR.

---

## 8. Open questions (TBD)

Part of the disclosure infrastructure will be finalised by separate ADRs
([development.md §12](docs/development.md), [contributing.md §8](docs/contributing.md)):

- **Dedicated security contact and PGP key.** Publishing a dedicated `security@<domain>` alias
  alongside the GitHub private-advisory channel, the real PGP fingerprint, `docs/security/pgp.asc`,
  and `.well-known/security.txt`.
- **Exact licence text** (`LICENSE` / `NOTICE.md`) in its final wording — synchronised with the
  licensing ADR (`docs/adr/NNNN-licensing.md`).
- **Bug-bounty decision** (needed or not, scope, payments) — separate ADR.

Until those ADRs are adopted, this policy in its current version applies, and the channel for
private reporting is GitHub private vulnerability reporting (see [§2](#2-how-to-report)).

---

## 9. Governing rule

A vulnerability in Mycelium is measured by **risk to an operator or user, not "code criticality"**. A
finding that exposes identity, location, connection metadata, or secrets, or that makes the transport
trivially distinguishable, is priority 1, however "small" it may look technically. If you are unsure
whether something is a bug, **report it**: a false alarm is cheaper than silence.
