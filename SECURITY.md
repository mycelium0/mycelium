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

**Found a way to take over a node, get past the provenance gate _on a node that has armed it_, or
extract key material? Please tell us before you publish the exploitation details.** A 0-day in deployed connectivity software harms
its users directly, and an unattended node cannot patch faster than an attacker can act. See
[§2](#2-how-to-report).

**Found that a transport is detectable, fingerprintable, or otherwise distinguishable? Publish it —
we ask for nothing.** The adversary this project models measures that class better than we can, so
an embargo would hide it from operators and from nobody else.
[§6.1](#61-not-every-finding-wants-a-window) sets out where the line falls and why.

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

- **PGP: there is no project key yet — do not go looking for one.** This bullet used to offer PGP
  encryption and give a literal placeholder token as the fingerprint, which is an offer of a channel
  nobody can use. The GitHub advisory above is already private and carried over TLS; if you
  want out-of-band encryption on top of it, open the advisory, say so, and include **your** public
  key — we will reply encrypted to yours. A project key, a `security@<domain>` alias,
  `docs/security/pgp.asc` and `.well-known/security.txt` are open items pending an ADR
  ([§8](#8-open-questions-tbd)). None of them exist today and this policy will not imply otherwise.
- **Do not use** for exploitation details **of the control-plane class**
  ([§6.1](#61-not-every-finding-wants-a-window)): public GitHub issues, public chats/channels, or
  messengers without end-to-end encryption. For an observable/detection finding none of this
  applies — a public issue is a fine place for it.

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
   always triggers an **event-based audit** ([refactoring.md §4.4](docs/refactoring.md)), opened as
   `Audit-NNNN`. **That audit report is maintainer-local and is never published** — `docs/audits/` is
   gitignored by canon ([refactoring.md §1](docs/refactoring.md)), so do not expect your finding to
   appear there. The public record is the **commit that fixes it and the CHANGELOG entry for the
   release carrying that fix** ([§6.3](#63-what-we-do-with-our-own-defects)); this parenthetical used
   to imply a publication that does not happen.
3. **Joint work on the fix**, with you in the review loop if you wish.
4. **Coordinated disclosure** per [§6](#6-disclosure-timeline) and [§7](#7-public-disclosure-and-credit).

---

## 3. Good-faith research

We welcome good-faith security research and will work with researchers who follow this policy. On
request we will acknowledge your contribution ([§7](#7-public-disclosure-and-credit)).

We ask that you:

- for the **control-plane class** ([§6.1](#61-not-every-finding-wants-a-window)), report privately
  and give the project a window to fix before publishing exploitation details. An
  **observable/detection** finding needs no window and publishing one immediately **is** good-faith
  conduct under this policy — the asks below still apply to it, the timing ask does not;
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
  `fungi diag collect` for a public bug report — is **redacted by construction** (`internal/diag`
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
  a node that has armed the gate runs its update timer **only** in signature-verifying mode — note
  that arming is the operator's opt-in and [GOVERNANCE.md §7](GOVERNANCE.md) records the
  project-level interim as unsigned, so "the gate is off here" is a posture, not a finding
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

**We do not ask you to keep quiet about the existence of a finding — ever.** Reporting privately
first is a request about **exploitation details**, and only for the class named below. Saying
publicly "component X looks wrong" was never restricted, and reporting a finding here is not a
commitment to silence.

### 6.1. Not every finding wants a window

Delay costs something, so it has to buy something. It buys nothing at all for one whole class, and
that class is a large part of what this project gets reported:

First, so it is not buried: **severity and embargo value are different questions.** The severity
model ([§5](#5-severity-classification)) governs how fast *we* must fix a thing and what it blocks.
It says nothing about how long *you* should wait to publish. `DISTINGUISHABLE_TRANSPORT` is S0 and
also gets no window, and there is no contradiction in that.

**Publish immediately, we ask for nothing — the TRANSPORT-SHAPE class.** Narrowly: findings whose
whole content is that a *deployed, serving* shape is recognisable — `DISTINGUISHABLE_TRANSPORT`
([§1.1](#11-in-scope-priority--by-severity-see-5)). "This transport is distinguishable", "this shape
has a fingerprint", "this handshake is replayable by an observer", "this cover story does not hold".
Against the adversary this project models — ML flow classification and active probing of any
suspicious listener ([THREAT-MODEL.md](docs/THREAT-MODEL.md)) — **withholding that finding withholds
it from operators, not from the adversary, who is already measuring the shape we are running.** Every
hour of embargo is an hour operators keep serving something somebody has already learned to spot.

That rationale has a boundary, and the rule stops where it does: it holds for a shape that is
**deployed and serving**. It does not hold for a transport that is default-OFF, unshipped, or behind
a flag — nobody is measuring a shape that runs nowhere, so there the ordinary short window applies.
The project's own audit history is full of distinguishability findings on default-OFF families; on
the eve of a first release that is the common case, not the exception.

**Everything else takes the window.** Explicitly, and regardless of how it was discovered: anything
touching a **user's identity or the linkability of their traffic** (`USER_DEANON`,
`TRAFFIC_CORRELATION`), a **secret** (`SECRET_LEAK`), the **supply chain**, node **enumeration**, or
the **control plane** — a way past the provenance gate on a node that has armed it, a way to make a
node promote a config an attacker chose, a path that leaks key material, remote code execution. There
the attacker gains something observation cannot give them, and the asymmetry runs the other way: an
operator running an unattended node cannot patch faster than an attacker can use it.

If a finding sits between the two, treat it as the second and tell us why — we would rather argue
about a category than lose a report.

**No embargo is not the same as no notice.** When you publish an observable finding, please open the
advisory at the same moment — not before, not as a delay, simply so we learn about it from you rather
than from the same blog post as everyone else. This is a courtesy, not a condition.

### 6.2. Targets

| Stage | Target |
|---|---|
| **Receipt acknowledgement** of report | within **72 hours** |
| **Initial assessment + severity** (S0/S1 → event-based audit) | within **7 days** |
| **Regular status updates** to reporter | at least once every **2 weeks** until fix |
| **Default disclosure** (fix + public notice) | **when the fix ships — in practice days**, and **30 days** from acknowledgement at the outside |

Thirty, not the customary ninety, and the reason is structural rather than a show of virtue: ninety
days exists to buy a slow vendor time to coordinate with downstreams, and there are no downstreams
here to coordinate with. The team is one to three people and the fix path is one repository. If we
are still sitting on something at thirty days, the honest reading is that we failed to fix it, not
that we needed the time.

**How fast a fix actually reaches a node is a separate question, and the answer is "it depends on the
operator".** A node armed against a signed branch tip converges within one update cadence. A node
pinned to an immutable signed tag — which the runbook prescribes for any node not solely operated by
the person who controls the repository — converges when its operator cuts or re-pins to a new tag. A
staged node converges when someone acks. **The project can reach no third-party operator at all**;
publishing the fix is the whole of our delivery to them. That is why the clock above is about our
own diligence and not a claim about your exposure.

**Timeline adjustments:**

- **Active exploitation in the wild**, or a finding that hands an adversary a ready signature for
  **mass identity exposure or blocking** — maximum priority. To be unambiguous, since the same class
  can be one we ask you to publish immediately: emergency mode describes **our** response — we drop
  other work, fix, and notify — and is **not** a request that you hold anything back.
- If the fix requires a coordinated update with an upstream or hosting provider, the timeline may
  be extended by agreement with the reporter, with a stated reason.
- For the control-plane class we ask reporters **not to publish exploitation details before the fix
  is released** — because a 0-day in deployed connectivity software directly harms its users. That is
  the only reason for any delay we will ever give, and it is a request, not a condition of reporting.

### 6.3. What we do with our own defects

The same standard, applied to ourselves, and it is the fastest way to see what this policy actually
means in practice. This project publishes its own security defects in full and by name, in the
**commit that fixes them** and in the **CHANGELOG entry for the release that carries that fix** —
including the embarrassing ones. Four that are on the public record, each checkable:

- the operator's own nodes carried a deployed update unit with the provenance gate disabled, and the
  documented arming procedure would have started it;
- a revoked client stayed live on the second engine while the tool reported the credential gone from
  every inbound;
- the last-resort transport had no L7 liveness probe at all, and the first attempt at one was built,
  found to be measuring nothing, and removed rather than kept as decoration;
- the release verifier reported success for a download it had never checked, and the fingerprint A/B
  probe had never executed on any node for the whole life of the feature — both fixed in this
  release, both described in the commits that fixed them.

None of it was withheld, softened, or found by anyone outside the project — which is also the honest
limit of what this section proves. It shows how we treat our **own** findings; we have not yet had an
outside report to test it against.

If you report something and we fix it, expect it written up the same way — with your finding
described accurately rather than minimised. If that is not what you want, say so in the report.

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
([development.md §8 "Security"](docs/development.md),
[contributing.md §7 "Security of contributions"](docs/contributing.md)):

- **Dedicated security contact and PGP key.** Publishing a dedicated `security@<domain>` alias
  alongside the GitHub private-advisory channel, a real PGP fingerprint, `docs/security/pgp.asc`,
  and `.well-known/security.txt`. **None of these exist today** — [§2.1](#21-private-channel-default)
  says so plainly rather than listing them as available options, which is what it used to do. The
  last two are also pointless until the project serves a domain; there is none, so they wait for the
  same ADR.
<!-- RESOLVED: the licence is fixed as AGPL-3.0-or-later by ADR-0003 (accepted 2026-06-11), with the
     full text in LICENSE. No NOTICE.md is used. -->
- **Bug-bounty decision** (needed or not, scope, payments) — separate ADR.

Until those ADRs are adopted, this policy in its current version applies, and the channel for
private reporting is GitHub private vulnerability reporting (see [§2](#2-how-to-report)).

---

## 9. Governing rule

A vulnerability in Mycelium is measured by **risk to an operator or user, not "code criticality"**. A
finding that exposes identity, location, connection metadata, or secrets, or that makes the transport
trivially distinguishable, is priority 1, however "small" it may look technically. If you are unsure
whether something is a bug, **report it**: a false alarm is cheaper than silence.
