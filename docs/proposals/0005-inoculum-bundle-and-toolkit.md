<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Inoculum: a signed operator-provided starter bundle, its v0 schema, and a local-only verify/inspect/export toolkit

> **Document type.** Refactoring / Change Proposal. Structure matches
> [../refactoring.md](../refactoring.md) and
> [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md).
> This RP **defines a concept and its contracts**; it implements nothing. It names the canonical
> mycelial term **Inoculum** under the vocabulary discipline of
> [ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md), fixes an **Inoculum v0**
> schema, and specifies a local-only toolkit (validator, signer/verifier, inspector, exporters,
> a `mycelium inoculum` CLI) that sits **between** an operator's node state and the standard
> off-the-shelf clients those configs already feed. It is the safe, contract-anchored replacement
> for the loaded word "client": Mycelium ships **no** consumer client and operates **no** public
> network ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).
>
> **Phase.** Not before **Phase 2**. Phases 0–1 may only **mention** the Inoculum as future work;
> nothing in this RP is built, wired, or auto-enabled before its phase. The schema and tooling are
> designed now so the future does not have to break them (the same posture
> [ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md) takes for `internal/spec`).

---

## Metadata
- **ID:** RP-0005
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** **not before Phase 2** (concept + v0 schema + toolkit + CLI; Phases 0–1 may only mention it). See [../ROADMAP.md](../ROADMAP.md).
- **Related documents:**
  [ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md) (mycelial vocabulary discipline — "Inoculum"/"spore"/"fungi" name real contracts; Phase 0-2 inert schemas);
  [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md) (software releases, not an operated network — the project ships no client and operates no public network);
  [ADR-0014](../adr/0014-per-operator-node-credentials.md) (per-operator node credentials — no shared key material; public key + per-node pin only);
  [ADR-0002](../adr/0002-no-custom-cryptography.md) (no custom cryptography — signatures are a key-id + signature-bytes reference to a standard primitive);
  [ADR-0011](../adr/0011-carrier-agnostic-bridging.md) (carrier-agnostic bridging + the spore artifact an Inoculum may contain);
  [ADR-0010](../adr/0010-phase0-transport-set.md) (the standard transport set an exporter targets);
  [VIS-0002](../vision/0002-carrier-agnostic-mycelial-doctrine.md) (spores; never carry identities/full maps);
  [VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md) (no node holds the global topology);
  [RP-0003](0003-network-rollout-signed-self-updating.md) (the signed node-state → standard-client subscription render this artifact would later sit downstream of);
  [internal/spec/network.go](../../internal/spec/network.go) (`SporeEnvelope`/`TrustScope`/`NodeRole` — the inert schemas an Inoculum reuses);
  [control/lib/render_singbox.sh](../../control/lib/render_singbox.sh) and [scripts/node-bootstrap.sh](../../scripts/node-bootstrap.sh) (the current node-state → sing-box/Clash-Meta subscription rendering this artifact would later be derived from);
  [docs/refactoring.md](../refactoring.md) §13.

## 1. Title
Define **Inoculum** — a signed, TTL-bounded, operator-provided starter bundle of public access
parameters (optionally containing spores, config, and a trust policy) — fix its **v0** schema, and
specify a **local-only** verify/inspect/export toolkit and `mycelium inoculum` CLI that turns
operator node state into standard sing-box / Clash-Meta / AmneziaWG client configs **without
shipping a consumer client, a public network, or any endpoint registry**.

## 2. Reason
Today the project has two endpoints of a chain and **no named, signed, portable artifact in the
middle**:

- **Upstream:** a node's local identity → a rendered server config and **per-client subscriptions**.
  [control/lib/render_singbox.sh](../../control/lib/render_singbox.sh) already emits per-client
  sing-box JSON and Clash-Meta YAML for the enabled protocols
  (`myceliumctl subscription --engine singbox|xray`), and
  [RP-0003](0003-network-rollout-signed-self-updating.md) makes the *server-side* delivery signed
  and self-updating. But the per-user export is an **ad-hoc directory of client files** handed off
  out-of-band — not a single, signed, expiry-bounded, inspectable object with a declared trust scope.
- **Downstream:** off-the-shelf clients (sing-box, Clash-Meta, AmneziaWG/WireGuard) consume those
  configs directly.

The gap has a name problem and a contract problem.

- **The name problem.** Pressure to "ship a client" recurs. A consumer client is exactly what the
  project must **not** build: it would manufacture a single coercion/liability target, imply an
  operated network the architecture rejects ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md),
  [ADR-0014](../adr/0014-per-operator-node-credentials.md)), and re-introduce a central default
  endpoint. The project needs a **precise, contract-anchored word** for "the thing an operator hands
  a user so a *standard* client can connect," so that "client" can be retired without leaving a hole.
- **The contract problem.** The handoff today is an unsigned, untyped, non-expiring file pile. There
  is no artifact that (a) **proves** which operator produced it, (b) **expires** on a TTL, (c) carries
  a **trust scope**, (d) is mechanically guaranteed to hold **public keys/pins only** (never private
  material), and (e) can be **verified and exported** by an independent tool without that tool
  connecting anywhere. Without such an artifact, a third-party application that wants to "import a
  Mycelium config" has nothing stable to import, and any verification is by eye.

**Inoculum** closes both: it is the canonical mycelial term for an **operator-provided, signed,
TTL-bounded starter bundle** that local tools and third-party apps **verify, inspect, and export to
standard clients**, and that **gives no access by itself** — it connects nowhere, registers nothing,
and is meaningless without an operator's independently-run nodes behind it. This RP defines the
concept, fixes the v0 schema, and specifies the toolkit. It builds **no** running service.

> **Why an RP and not only an ADR.** This is architecturally significant: it introduces a new
> config-distribution *format* (the Inoculum bundle) and a new vocabulary contract ("Inoculum"), and
> it reshapes the operator→user handoff. The "why this canonical shape" decision is recorded in a new
> ADR in §8; this RP describes the artifact, its v0 schema, the toolkit, and the migration from the
> current ad-hoc subscription directory.

## 3. Scope
- **Layers:** a thin **export/packaging** layer over the existing control surface, plus a
  **local-only verification** surface. **No** data-plane transport is added (Inoculum is a bundle
  over the **standard** transports of [ADR-0010](../adr/0010-phase0-transport-set.md)); **no**
  routing, discovery, coordinator, registry, or carrier runtime is added.
- **Components:** the **Inoculum v0 schema** (`*.myc-inoculum.json`); a **validator**; a
  **signer/verifier** (standard primitive only, [ADR-0002](../adr/0002-no-custom-cryptography.md));
  an **inspector**; **exporters** (sing-box, Clash-Meta, AmneziaWG/WireGuard where applicable); QR/file
  import-export helpers; a **local-only trust-policy evaluator**; reference libraries; an optional demo
  UI component set; and the `mycelium inoculum` CLI. Upstream:
  [control/lib/render_singbox.sh](../../control/lib/render_singbox.sh) /
  [scripts/node-bootstrap.sh](../../scripts/node-bootstrap.sh) (the node-state source the operator
  packages **from**; reused, not rewritten).
- **Contracts:** the **Inoculum v0** bundle schema (§3 below / the v0 schema section); the immutable
  **signed-content** boundary (key-id + signature bytes, [ADR-0002](../adr/0002-no-custom-cryptography.md));
  reuse of the inert [internal/spec/network.go](../../internal/spec/network.go) `TrustScope`,
  `SporeEnvelope`, and `NodeRole` shapes; the export contracts to standard client formats. **No new
  wire protocol and no client-facing transport schema is invented.**
- **Storage / state:** an Inoculum is a **file the operator produces and hands off**; a consuming tool
  reads it **locally** and writes standard client configs **locally**. The operator's **private**
  identity stays on-node (`/var/lib/mycelium`, 0600, [ADR-0014](../adr/0014-per-operator-node-credentials.md));
  **only public keys, short ids, donor SNIs, and per-node certificate pins** ever enter an Inoculum.
  **No user PII is stored anywhere; no central store exists.**
- **Flows:** operator node/operator state → (later) **signed Inoculum** → **local export** to standard
  client configs → an existing off-the-shelf client connects. Independent operators **create** Inocula;
  independent applications **consume** them. The official project ships neither end as a running app.
- **Schemas / formats:** **one new file format** (`*.myc-inoculum.json`, the "Mycelium Bundle" by its
  boring external name) plus its exporters' **existing** target formats (sing-box JSON, Clash-Meta
  YAML, AmneziaWG/WireGuard). No new transport format.

### 3.1. Component participation table (mandatory)

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| Inoculum v0 schema (`*.myc-inoculum.json`) | The signed, TTL-bounded bundle format this RP defines: operator identity, trust scope, node/transport profiles (public keys + pins only), optional spores, signatures, export targets, local policy hints | deferred (Phase 2 design; defined here, built no earlier) | none (JSON + standard-primitive signature) | A bundle/manifest *format* is project canon, not a third-party tool; signatures are delegated to a standard primitive ([ADR-0002](../adr/0002-no-custom-cryptography.md)). |
| validator | Checks an Inoculum against the v0 schema and the safety invariants (no private material, valid TTL, present scope/signature) before any export | deferred | jq / a Go validator per [ADR-0012](../adr/0012-go-primary-control-plane-language.md) | Pure schema + invariant checking is project logic over a standard JSON parser; no external validator knows these invariants. |
| signer / verifier | Produces and checks the detached signature over the immutable bundle content; refuses on bad/missing signature | deferred | `ssh-keygen -Y sign/verify` / standard signing tool (operator choice) | Signing is delegated to an audited standard primitive ([ADR-0002](../adr/0002-no-custom-cryptography.md)); the project invents no scheme. |
| inspector | Renders an Inoculum's public, non-sensitive contents human-readably for review (issuer, scope, expiry, transports present, export targets) — **connects nowhere** | deferred | jq / Go | Read-only presentation of a local file; no service. |
| exporters (sing-box / Clash-Meta / AmneziaWG · WireGuard) | Transform a verified Inoculum into a standard off-the-shelf client config for the enabled transports; reuse the existing subscription-render logic | deferred | sing-box / Clash-Meta / AmneziaWG · WireGuard | The clients are the standard engines ([ADR-0010](../adr/0010-phase0-transport-set.md)); the exporter only places already-public values into their native formats — no custom transport ([ADR-0002](../adr/0002-no-custom-cryptography.md)). |
| QR / file import-export helpers | Carry an Inoculum across a file/QR bridge (an [ADR-0011](../adr/0011-carrier-agnostic-bridging.md) carrier) for the verify/export step | deferred | a standard QR library / filesystem | Carrier hand-off is convergence-layer glue over a standard encoder; not a new protocol ([ADR-0011](../adr/0011-carrier-agnostic-bridging.md)). |
| local-only trust-policy evaluator | Applies the operator-supplied **local** trust hints + the **consumer's** own trust set to decide whether to export (e.g. require a known signer); never a global reputation | deferred | Go (reuses the inert `TrustScope` shape) | Local, scoped policy over a typed shape ([internal/spec/network.go](../../internal/spec/network.go)); never a global score or registry ([ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md), [VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md)). |
| reference libraries | Importable verify/inspect/export functions third-party apps can embed, so they need not ship a client to consume an Inoculum | deferred | Go (and a future binding) per [ADR-0012](../adr/0012-go-primary-control-plane-language.md) | A library is how the project enables third-party consumers without itself shipping an app ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)). |
| `mycelium inoculum` CLI | `verify` · `inspect` · `export singbox|clash|awg`; **validates and exports only — never connects** | deferred | the components above | A neutral local CLI over the toolkit; it dials nothing, so it is not a client. |
| [control/lib/render_singbox.sh](../../control/lib/render_singbox.sh) / [scripts/node-bootstrap.sh](../../scripts/node-bootstrap.sh) | The operator-side node state an Inoculum is **packaged from** (the same public values today's subscription render emits); reused unchanged as the source | passive | sing-box / system shell / jq | The render already exists ([RP-0003](0003-network-rollout-signed-self-updating.md)); the Inoculum is a packaging step **after** it, not a replacement. |
| `SporeEnvelope` / `TrustScope` / `NodeRole` ([internal/spec/network.go](../../internal/spec/network.go)) | The inert typed shapes an Inoculum reuses for any contained spore and for its scope/role fields | passive | none | Already canon and inert ([ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)); the Inoculum binds to them rather than inventing parallel types. |
| coordinator / registry / discovery | **Not built here** — an Inoculum is handed off out-of-band by an operator; there is no endpoint directory, no announce, no lookup | deferred | none | A registry/discovery layer is later-phase and forbidden in Phase 0-2 ([ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md), [VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md)); an Inoculum deliberately needs none. |
| consumer VPN / GUI client | **Not built here, ever by the project** | deferred | none | The project ships software, specs, and tools, not a default-access app ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)); third-party apps may consume Inocula. |

### 3.2. Blast-radius cap
> One RP = one manageable step.

This RP is **design-only**: it introduces **one** new config-distribution surface (the Inoculum
bundle format) and **one** new vocabulary contract, and writes **no** runtime code. It is within the
single-step cap as a *specification* RP. The implementation that follows is itself bounded — the
exporters reuse the existing render logic, the signer/verifier reuse a standard primitive, and the CLI
**connects to nothing** — so the future build step touches the export/packaging boundary only and
adds no transport, routing, discovery, or registry behaviour.

- **Responsibility boundaries affected:** 1 (a new **export/packaging** boundary between node state and
  standard clients; the data-plane, identity, and provenance boundaries are reused unchanged).
- **Layers affected (behaviour):** 0 in this RP (design only); the future build adds **no** data-plane
  or control-plane *behaviour* — exporting is a pure transform of already-public values.
- **Config-distribution surfaces affected:** **+1** (the Inoculum bundle), which **supersedes** the
  ad-hoc subscription directory as the handoff unit (a consolidation, not a second parallel channel).
- **Files in diff (estimate):** ~1 for this RP (this file) + the index row a maintainer adds; the
  future implementation is a separate, later RP.

- [x] Within cap — single-step **specification** RP (defines a format + a toolkit + a CLI; implements
  nothing). The follow-on build lands under its own RP(s), bounded to the export/packaging boundary.
- [ ] Exceeds cap → split / multi-phase.

## 4. Current state
- **Subscriptions are an ad-hoc directory, not a signed bundle.**
  [control/lib/render_singbox.sh](../../control/lib/render_singbox.sh) emits, per client, a sing-box
  JSON and a Clash-Meta YAML for the enabled protocols (`myceliumctl subscription`). These are correct
  client configs, but they are: **unsigned** (no proof of which operator produced them), **non-expiring**
  (no TTL), **un-scoped** (no declared trust scope), and **un-bundled** (a loose file set handed off
  out-of-band per [ADR-0014](../adr/0014-per-operator-node-credentials.md) delivery method B). A
  consuming tool cannot verify provenance, cannot know when the material goes stale, and cannot
  mechanically confirm the files carry **only public** material.
- **The server-side delivery is signed; the user-side handoff is not.**
  [RP-0003](0003-network-rollout-signed-self-updating.md) makes the operator's *node* delivery signed
  and self-updating (signed tag → per-node render). It deliberately leaves **client-facing UX** out of
  scope. So provenance stops at the node; nothing carries a signature down to the user-facing config.
- **There is no canonical word for the handoff object.** "Client" is wrong (the project ships none and
  must not, [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)); "subscription" names
  the loose directory; "spore" is the **atomic** signed artifact
  ([internal/spec/network.go](../../internal/spec/network.go) `SporeEnvelope`,
  [VIS-0002](../vision/0002-carrier-agnostic-mycelial-doctrine.md) §3), not a starter bundle. There is
  no term for "a signed starter bundle that may *contain* spores plus config plus a trust policy."
- **Third-party consumption has nothing stable to import.** An independent application that wants to
  let a user "import a Mycelium config" must today parse a loose subscription directory by convention.
  There is no schema, no version, no signature, and no library to verify or export against.

## 5. Target state
A single, named, signed, TTL-bounded **Inoculum** sits between operator node state and standard
clients, with a local-only toolkit to verify, inspect, and export it — and **nothing in the toolkit
ever connects**.

### 5.1 What is an Inoculum
An **Inoculum** is an **operator-provided, signed, TTL-bounded configuration artifact** that lets a
local tool or a third-party app **understand, verify, and export** access configuration for
**independently-operated** nodes to **standard** clients. Precisely:

- It is **not** a running access service and **connects nowhere itself** — it is data.
- It implies **no public default network**, exposes **no public endpoint registry**, and is **not a
  consumer VPN app**.
- It is **not a new transport** — it is a **bundle/spec/tooling layer over the standard existing
  transports** ([ADR-0010](../adr/0010-phase0-transport-set.md)).
- **It gives no access by itself.** An Inoculum is inert without the operator's independently-run
  nodes behind it; possessing one connects nobody to anything.
- **Independent operators create Inocula; independent applications may consume them.** The official
  project ships the **format, the spec, and the tools** — never a default-access app
  ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).

**Distinguished precisely from:**

- **Spore** ([internal/spec/network.go](../../internal/spec/network.go) `SporeEnvelope`,
  [VIS-0002](../vision/0002-carrier-agnostic-mycelial-doctrine.md) §3) — an **atomic** signed,
  TTL-bounded, portable artifact (one bootstrap hint, route capsule, trust invitation, etc.). An
  **Inoculum is a starter bundle** that may *contain* one or more spores **plus** transport config
  **plus** a local trust policy. Spore : atom :: Inoculum : starter bundle.
- **Bundle** — the neutral **external** container term. The boring external name may remain
  "**Mycelium Bundle**" (and the file extension `*.myc-inoculum.json`); "**Inoculum**" is the
  **canonical mycelial term** for the same object inside the doctrine.
- **Node config** — what runs **on** a node (server side). An Inoculum is the **user-facing** export of
  the *public* parameters needed to reach such nodes.
- **Subscription** — the current **direct** sing-box/Clash render
  ([control/lib/render_singbox.sh](../../control/lib/render_singbox.sh)). An Inoculum is the **signed,
  scoped, expiry-bounded** superset that an exporter turns **back into** exactly such a subscription
  locally.
- **Client app** — **no.** Mycelium ships none; an Inoculum feeds an *existing* client.
- **Public registry / discovery protocol** — **no.** An Inoculum carries the operator's chosen public
  parameters and is handed off out-of-band; it announces nothing and looks nothing up.

### 5.2 Why "Inoculum" (mycelial fit)
The metaphor names a real contract, as [ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md)
requires (a mycelial term is used **only** where it denotes a schema/state/policy/behaviour):

- **Spore** — the **atomic** signed artifact (the seed unit).
- **Inoculum** — the **operator starter bundle**: spores + transport config + trust policy. In biology
  an inoculum is the prepared starter culture an operator introduces to a substrate; here it is the
  prepared starter material an operator hands a consumer to *begin* connectivity through that
  operator's own nodes. It germinates **nothing** by itself.
- **Hypha** — the **exploratory / probed** path that exists **after** an exported config is tried (the
  `probed` edge-lifecycle stage; a later-phase behaviour, mentioned, not built here).
- **Cord** — the **reinforced / promoted** path after measured usefulness
  ([internal/spec/network.go](../../internal/spec/network.go) `CordPromotion`; later phase).

The Inoculum is therefore the **starter** stage that precedes any hypha or cord — exactly the missing
word between "spore" (atom) and "the connectivity that grows from it."

### 5.3 Inoculum v0 schema (minimal)
A minimal, forward-shaped JSON shape. **Public material only.** It binds to the inert
[internal/spec/network.go](../../internal/spec/network.go) shapes (`TrustScope`, `SporeEnvelope`) and
references signatures by a standard primitive only
([ADR-0002](../adr/0002-no-custom-cryptography.md)). Fields:

| Field | Type | Meaning / constraint |
|---|---|---|
| `version` | int | Inoculum schema version (v0 = `0`); bumped independently. |
| `inoculum_id` | string | opaque bundle identifier (no PII, no location). |
| `issued_at` | RFC 3339 UTC | when the operator produced the bundle. |
| `expires_at` | RFC 3339 UTC | **TTL** — must be strictly after `issued_at`; an expired Inoculum **refuses export**. |
| `operator` | object | the **independent operator's** declared identity: an opaque handle + the **signer key-id** (`signer_key_id`, the public reference of [ADR-0002](../adr/0002-no-custom-cryptography.md)). **No** real name/email/jurisdiction. |
| `trust_scope` | `TrustScope` | the bounded scope this bundle is valid within (reuses the inert shape); never a global identity. |
| `node_profiles` | array | per reachable node, the **public** reach parameters only (an operator-chosen address/host the operator already publishes to its own users, a per-protocol public reference) — **no** topology map, **no** global node list. |
| `transport_profiles` | array | per enabled transport, **public** parameters only: REALITY **public key** + `short_id` + donor SNI; for HY2/TUIC an optional **certificate PIN** (SHA-256 of cert/SPKI) — **never** `insecure: true` ([ADR-0014](../adr/0014-per-operator-node-credentials.md), [ADR-0010](../adr/0010-phase0-transport-set.md)). |
| `spores` | array of `SporeEnvelope` | **optional** contained spores (e.g. a bootstrap hint / trust invitation), each independently signed and TTL-bounded; never carrying identities or full maps ([VIS-0002](../vision/0002-carrier-agnostic-mycelial-doctrine.md) §3). |
| `health_metadata` | object | **optional**, only if **locally produced and safe**: coarse, redacted, aggregated hints (e.g. transport-class health) — **never** raw traffic, per-user data, or a map. Omitted by default. |
| `local_policy_hints` | object | operator-supplied hints for the **consumer's local** trust-policy evaluator (e.g. preferred-transport order); advisory, never a global directive. |
| `export_targets` | array | which standard client formats this bundle is meant to export to (`singbox`, `clash`, `awg`). |
| `signatures` | array | one or more detached signatures over the **immutable** bundle content, each `{signer_key_id, signature}` (standard primitive only, [ADR-0002](../adr/0002-no-custom-cryptography.md)); no key material, only a key-id + bytes. |

The signed content is the canonicalised bundle **minus** the `signatures` array; verification recomputes
the canonical form and checks each signature against the named key-id. Validation mirrors the inert
`Validate()` discipline of [internal/spec/network.go](../../internal/spec/network.go): version known,
scope valid, TTL strictly positive, signer key-id and signature bytes present, and the safety
invariants of §5.4 hold.

### 5.4 What must NEVER be inside an Inoculum
Hard, fail-closed exclusions (a bundle violating any of these is **invalid** and **refuses export**):

- **private keys** or any secret material (REALITY private key, per-protocol passwords, cert private
  keys, AmneziaWG private keys) — **public keys / short ids / pins only**
  ([ADR-0014](../adr/0014-per-operator-node-credentials.md));
- **raw traffic** of any kind;
- **user identities** or any PII (no real name, email, jurisdiction name, location code);
- **full topology maps** or complete peer/node lists
  ([VIS-0002](../vision/0002-carrier-agnostic-mycelial-doctrine.md) §3,
  [VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md));
- a **public global node list** or any **public endpoint registry**;
- **official public endpoints** of "the network" (there are none —
  [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md));
- a **hidden default network** or any implied default access;
- **route instructions to specific public resources**, or **regulator-specific bypass language** /
  anti-regulator framing (neutral technical language only);
- **project-controlled telemetry endpoints** or any call-home;
- **`insecure: true`** / disabled TLS verification — a self-signed HY2/TUIC cert is carried as a
  **pin**, never as blanket trust ([ADR-0014](../adr/0014-per-operator-node-credentials.md), enforced
  like the existing `no_insecure_tls` gate);
- anything that would make the **official project** an **operator of a public network**.

### 5.5 The toolkit (what the project MAY eventually publish — and MUST NOT)
**MAY publish** (all local-only; none connect):

- the **schema files** for Inoculum v0 (and a JSON-schema-style description);
- a **validator** (schema + the §5.4 safety invariants, fail-closed);
- a **signer / verifier** over the immutable content (standard primitive only,
  [ADR-0002](../adr/0002-no-custom-cryptography.md));
- an **inspector** that prints the public, non-sensitive contents for human review;
- **exporters** to **sing-box**, **Clash-Meta**, and **AmneziaWG / WireGuard** (where applicable),
  reusing the existing render logic ([control/lib/render_singbox.sh](../../control/lib/render_singbox.sh));
- **QR / file import-export helpers** (an [ADR-0011](../adr/0011-carrier-agnostic-bridging.md) carrier
  hand-off);
- a **local-only trust-policy evaluator** (operator hints + the consumer's own trust set; scoped,
  never global);
- **reference libraries** so third-party apps can verify/inspect/export without shipping a client;
- **optional demo UI components** (illustrative, not a shipped consumer app).

**MUST NOT publish** (the boundary that keeps the project software-not-a-network,
[ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)):

- a **consumer VPN app** / GUI client;
- a **default public network** or any default access;
- a **preloaded endpoint directory** / public node list;
- **one-click official access** of any kind;
- a **centrally-operated bootstrap service**;
- **marketing around accessing specific restricted resources** (neutral technical language only; no
  anti-regulator framing).

### 5.6 CLI (neutral; validate/export only — never connects)
A neutral local CLI; every verb operates on a **file** and **dials nothing**:

```
mycelium inoculum verify   <file.myc-inoculum.json>     # signature + schema + safety invariants; fail-closed
mycelium inoculum inspect  <file.myc-inoculum.json>     # human-readable public contents; connects nowhere
mycelium inoculum export singbox <file.myc-inoculum.json>   # -> standard sing-box client config
mycelium inoculum export clash   <file.myc-inoculum.json>   # -> standard Clash-Meta client config
mycelium inoculum export awg     <file.myc-inoculum.json>   # -> standard AmneziaWG/WireGuard config (where applicable)
```

(A standalone spelling — `myc-inoculum verify|inspect|export-singbox` — is an acceptable equivalent.)
`export` **refuses** on an invalid / expired / untrusted Inoculum (§5.8). No verb opens a network
socket; the CLI is a transformer, not a client.

### 5.7 Relation to current subscriptions
Today: node/operator state → **direct** sing-box/Clash render
([control/lib/render_singbox.sh](../../control/lib/render_singbox.sh)). With Inoculum v0 (Phase 2+),
the same public values flow through an **intermediate, signed artifact**:

```
node / operator state  ──►  signed Inoculum  ──►  local export  ──►  standard client (sing-box / Clash-Meta / AmneziaWG)
   (existing render)         (this RP's format)     (this RP's exporter)      (off-the-shelf, unchanged)
```

So a **third-party app imports an Inoculum** and exports it locally **without Mycelium shipping an
app**. The exporter's output is **byte-compatible** with what a direct subscription render produces for
the same inputs (so existing clients keep working), but it now arrives inside a signed, scoped,
expiry-bounded envelope instead of a loose directory.

### 5.8 Security model
- **Signatures over immutable content.** Each signature covers the canonicalised bundle minus the
  `signatures` array; any mutation invalidates it. Standard primitive only — key-id + signature bytes,
  no in-house scheme ([ADR-0002](../adr/0002-no-custom-cryptography.md)).
- **TTL / expiry + replay-bound fields.** `issued_at`/`expires_at` bound validity; an expired bundle is
  inert. Contained spores carry their own replay-bounded TTLs
  ([internal/spec/network.go](../../internal/spec/network.go) `SporeEnvelope`).
- **Trust scope, not global trust.** `trust_scope` bounds where the bundle applies; the consumer's
  **local** trust-policy evaluator combines operator hints with the **consumer's own** trust set — never
  a global reputation, score, or registry ([VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md)).
- **No private key material; pin self-signed TLS.** Public keys / short ids / donor SNIs / certificate
  **pins** only; **never** `insecure: true` ([ADR-0014](../adr/0014-per-operator-node-credentials.md)).
- **Safe failure (fail-closed).** An **invalid, expired, or untrusted** Inoculum **refuses export** and
  exits non-zero with no partial output — the safe state is *verified-or-nothing*, never
  *exported-but-unverified* (mirrors the project's fail-closed posture).
- **No raw telemetry, no full map, no central-network claim.** Optional `health_metadata` is coarse,
  aggregated, and local-only; there is no full topology and no call-home, consistent with
  [ADR-0002](../adr/0002-no-custom-cryptography.md), [ADR-0014](../adr/0014-per-operator-node-credentials.md),
  and [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md).

### 5.9 Governance / legal boundary (explicit)
- Mycelium **publishes software, specs, and tools** — the Inoculum **format**, the **validator/
  signer/verifier/exporters**, and the **CLI/libraries**.
- **Independent operators create and distribute Inocula** out-of-band; the official project does **not**
  produce, host, or distribute them and does **not** operate a public network
  ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).
- A **release signature on the toolkit is not an operational command** to any node and grants no access;
  it only attests the *software's* provenance ([RP-0003](0003-network-rollout-signed-self-updating.md),
  [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).
- An **Inoculum is supplied by an independent operator**; possession grants no access without that
  operator's own nodes.
- **Third-party apps may import Inocula**, but the project ships **no** default public-access app
  ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).

### 5.10 Effect on the four template axes
- **Indistinguishability.** Unchanged at the transport layer — exporters emit the **same** standard
  client configs over the **same** standard transports ([ADR-0010](../adr/0010-phase0-transport-set.md));
  the bundle adds no on-wire signal.
- **Survivability / path redundancy.** An Inoculum can carry **multiple** node/transport profiles in one
  signed object, and travels over any [ADR-0011](../adr/0011-carrier-agnostic-bridging.md) carrier
  (file/QR), so handoff and recovery do not depend on a live service — improving robustness of the
  *handoff*, not adding a transport.
- **Adaptation speed.** A re-issued, signed Inoculum lets an operator refresh a user's public parameters
  in one verified object; automated detection-driven rotation remains **deferred** (later phase).
- **Control-plane network persistence.** No central coordinator is introduced — an Inoculum is produced
  by an independent operator and handed off out-of-band; the toolkit reads a local file and writes local
  configs, depending on **no** online service.

### 5.11 Deferred (explicitly not in this RP, and not before their phases)
- a **mobile app** or any **GUI client**;
- **automatic discovery**, **DHT/gossip**, a **public registry**;
- **global route scoring** or any global trust/reputation;
- **distributed topology merge**;
- **DTN / carrier transport runtime** (the Inoculum is *carried* over a carrier, but no carrier runtime
  is built here, [ADR-0011](../adr/0011-carrier-agnostic-bridging.md));
- **autonomous cord promotion** ([internal/spec/network.go](../../internal/spec/network.go)
  `CordPromotion` stays operator-driven and inert);
- a **public official network** of any kind ([ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).

## 6. Risks
- **Compatibility.** The exporter's output is **byte-compatible** with the current direct subscription
  render for the same inputs, so existing off-the-shelf clients keep working; the Inoculum is an
  *envelope around* those configs, not a new client contract. v0 is explicitly versioned for forward
  evolution.
- **User security (requirement №1).** No de-anonymisation, logging, PII, or correlation is introduced.
  An Inoculum carries **public material only** ([ADR-0014](../adr/0014-per-operator-node-credentials.md));
  the toolkit **connects nowhere** and has no telemetry. The §5.4 exclusions are enforced fail-closed,
  *strengthening* the discipline relative to the loose subscription directory.
- **Indistinguishability / probe surface.** Unchanged — same standard transports, same client configs;
  the bundle adds no on-wire artifact.
- **Operated-network misread.** The dominant *positioning* risk: a signed, branded bundle could be
  misread as the project providing access itself, which it does not. Mitigated by §5.9 and the
  doctrine — independent operators create Inocula, the project ships only the format and tools, no
  endpoint registry or default network exists, the project operates no public network, and the
  `no_operated_network_claim` gate keeps owner/operate-a-network language out of the tree.
- **Misuse as a registry.** Someone could try to publish a directory of Inocula. Mitigated structurally:
  the format carries **no global node list**, the project hosts none, and the toolkit performs no lookup
  or announce; a directory is an *external* operator's choice, never a project feature.
- **Loss of observability/measurements.** None removed; optional `health_metadata` is coarse and
  local-only, and omitted by default.
- **Temporary degradation.** None — this is a design RP; the future exporter is a pure transform that
  changes no running config.
- **Flapping / false migrations.** N/A — no auto-rotation is introduced (deferred).
- **Rollback risk.** Trivially reversible: an operator who does not adopt Inocula keeps using the direct
  subscription render; nothing on a node changes.
- **Impact on decentralisation.** None — no coordinator/registry/discovery is added; the toolkit reads a
  local file and depends on no online service ([VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md),
  [ADR-0014](../adr/0014-per-operator-node-credentials.md)).

## 7. Acceptance Criteria
Since this RP is **design-only**, acceptance is on the *specification* and its conformance posture; the
runtime checks below bind the **future** implementation.

- [ ] This document defines the Inoculum concept, the v0 schema (§5.3), the never-inside exclusions
  (§5.4), the toolkit (§5.5), the neutral connects-nowhere CLI (§5.6), the relation to current
  subscriptions (§5.7), the security model (§5.8), the governance boundary (§5.9), and the deferred set
  (§5.11).
- [ ] The proposal lands the **core statement** verbatim in sense: *Mycelium ships no consumer client;
  Mycelium defines Inoculum, a signed operator-provided starter bundle; tools may verify, inspect, and
  export it to standard clients; it gives no access by itself; independent operators create Inocula and
  independent applications may consume them.*
- [ ] `bash tests/run.sh` stays green (12/12) with this file added — in particular `check_headers`
  (SPDX header present), `no_operated_network_claim` (**no** affirmative "operates a public network"
  claim), `no_insecure_tls` (the doc mandates pins, never `insecure: true`), `no_custom_crypto`
  (signatures are a key-id + bytes reference, no scheme defined), and `no_contact_leak` /
  `check_ppn_wording` (no PII; neutral framing).
- [ ] *(future build, separate RP)* a validator rejects any Inoculum containing private material,
  missing/expired TTL, or `insecure: true`; `export` refuses on invalid/expired/untrusted input and
  exits non-zero with no partial output.
- [ ] *(future build)* a verified Inoculum exports to sing-box / Clash-Meta / AmneziaWG configs that are
  byte-compatible with the direct subscription render for the same inputs; no CLI verb opens a socket.

> No netsim/netem scenario applies: this RP adds no transport and no running behaviour. Its only
> adversary surfaces are *positioning* (the operated-network gate) and *artifact provenance* (the
> signature/TTL/safety invariants), both addressed in §5.8–§5.9.

### Non-goals (deferred — not in this RP)
- A **consumer client / VPN app / GUI** of any kind (the project ships none —
  [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md)).
- A **public registry, endpoint directory, discovery, DHT/gossip, global route scoring, or distributed
  topology merge** (later phases; forbidden in Phase 0-2 —
  [ADR-0013](../adr/0013-mycelial-vocabulary-and-phase-discipline.md),
  [VIS-0003](../vision/0003-node-interaction-and-distributed-awareness.md)).
- A **carrier transport runtime** (an Inoculum is *carried* over a carrier; no DTN runtime is built —
  [ADR-0011](../adr/0011-carrier-agnostic-bridging.md)).
- **Autonomous cord promotion** ([internal/spec/network.go](../../internal/spec/network.go)
  `CordPromotion` stays inert/operator-driven).
- Any **implementation** — this RP is specification only; the build lands under a later RP, not before
  **Phase 2**.

## 8. Documentation changes
- [ ] `docs/adr/NNNN-<slug>.md` (**new**, authored alongside the implementing RP) — *"Inoculum: a
  signed operator starter bundle, not a client"*: records **why** a signed, TTL-bounded, public-only
  bundle is the canonical replacement for the word "client," why the toolkit must connect nowhere, and
  how the boundary upholds [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md). Add the
  row to [../adr/README.md](../adr/README.md).
- [ ] [../GLOSSARY.md](../GLOSSARY.md) — add **Inoculum** to the *Mycelial doctrine* section (operator
  starter bundle: spores + config + trust; distinct from **Spore**), and note **Hypha** (probed path)
  and **Cord** (reinforced path) as the stages that follow import.
- [ ] [../vision/0004-living-network-doctrine.md](../vision/0004-living-network-doctrine.md) — add
  **Inoculum** to the naming-discipline term list (§4) as the starter-bundle contract between the spore
  atom and the connectivity that grows from it.
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — record the artifact-provenance posture (signature +
  TTL + safety invariants) and confirm the toolkit adds no telemetry, no map, and no operated-network
  surface.
- [ ] [../ROADMAP.md](../ROADMAP.md) — note the Inoculum bundle + toolkit as **Phase 2+** work; Phases
  0–1 may **mention** it only.
- [ ] [internal/spec/network.go](../../internal/spec/network.go) (**future**, with the implementing RP)
  — an inert `Inoculum` typed schema + `Validate()` reusing `TrustScope`/`SporeEnvelope`, with the §5.4
  exclusions as validation invariants; `NetworkStateVersion`-style versioning.
- [ ] `tests/conformance/` (**future**) — a `no_private_material_in_inoculum` / `inoculum_safety` gate
  enforcing §5.4 fail-closed (extends the existing `no_insecure_tls` / `no_custom_crypto` posture);
  wired into [`tests/run.sh`](../../tests/run.sh) when the build lands.
- [ ] Component README/CHANGELOG + version bump (with the implementing RP) for the new toolkit
  component and any touched control surface.
- [ ] [docs/proposals/README.md](README.md) — add the RP-0005 row (a maintainer adds the row).

## 9. Migration Strategy
This RP changes **nothing running**; it specifies a future artifact. The migration is from the
**ad-hoc subscription directory** to the **signed Inoculum**, additively and reversibly:

- **Stages.** (1) Land this spec + the new ADR (§8). (2) *(later RP)* implement the validator /
  signer-verifier / inspector / exporters / CLI, with the inert `Inoculum` schema in
  [internal/spec/network.go](../../internal/spec/network.go) and the safety gate. (3) Operators
  optionally package their existing public subscription values into an Inoculum and hand **that** off
  instead of a loose directory.
- **Parallel coexistence.** The **direct subscription render**
  ([control/lib/render_singbox.sh](../../control/lib/render_singbox.sh)) and the **Inoculum export**
  coexist indefinitely: the exporter is byte-compatible with the direct render, so an operator may adopt
  Inocula gradually and a consumer may export an Inoculum **into** exactly the client configs they
  already use. No old/new client split is forced.
- **Final cutover.** There is **no forced cutover** — Inocula are an operator's *option*. The project
  never produces or hosts them; adoption is per independent operator.
- **Old-version consumers during transition.** A consumer with no Inoculum tooling keeps using the
  direct subscription files unchanged; an Inoculum-aware tool/app simply gains verification + a single
  signed object.
- **Dependencies (rollout order).** spec + ADR (this RP) → inert `Inoculum` schema + safety gate
  ([internal/spec/network.go](../../internal/spec/network.go), `tests/conformance/`) → toolkit + CLI →
  optional operator adoption. Each step is independently revertible.

## 10. Rollback / Fallback
- **How to roll back, and how fast.** Immediate and total at any stage: because the Inoculum path is
  **additive** and the exporter is **byte-compatible** with the existing render, an operator or consumer
  who stops using Inocula falls straight back to the **direct subscription** they already have — no node
  change, no client change, no downtime. Reverting the spec/tooling removes a *capability*, never a
  running service.
- **Data/keys/IPs to preserve.** Nothing new to preserve: the operator's private identity stays on-node
  (`/var/lib/mycelium`, 0600, [ADR-0014](../adr/0014-per-operator-node-credentials.md)); an Inoculum
  holds only already-public material that the direct render also emits.
- **Contract/config versions kept in parallel.** The direct subscription render and the Inoculum export
  run in parallel by design; `version` on the bundle allows v0→vN evolution without breaking older
  consumers (a breaking schema change is a major bump with the usual N=2 parallel-release rule).
- **Fail-closed behaviour during rollback.** No silent bypass: the toolkit **refuses export** on any
  invalid/expired/untrusted Inoculum and never emits `insecure: true`; falling back to the direct render
  preserves the same pinned, no-insecure-TLS posture
  ([ADR-0014](../adr/0014-per-operator-node-credentials.md), the `no_insecure_tls` gate). The safe state
  is always *verified-or-direct-render*, never *exported-but-unverified*.

---

## No-secrets / no-IP / no-location note (explicit)
This RP and every artifact it specifies obey the project's public-repo discipline. **No** node
IP/IPv6 literal, hostname, jurisdiction/country name, location code, personal email, real
secret/key/UUID, or AI/tool vendor fingerprint (nor a `Co-Authored-By:` line) is written into any
committed file. An **Inoculum carries public material only** — REALITY public key / short id / donor
SNI, and an optional HY2/TUIC certificate **pin**; it **never** carries a private key, raw traffic, a
user identity, a full topology map, a public global node list, an official public endpoint, a hidden
default network, regulator-specific bypass language, or a project-controlled telemetry endpoint
([ADR-0014](../adr/0014-per-operator-node-credentials.md), [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md),
[VIS-0002](../vision/0002-carrier-agnostic-mycelial-doctrine.md) §3). The toolkit **connects nowhere**.
The official project publishes software, specs, and tools and **operates no public network**; an
Inoculum is supplied by an **independent operator** and grants no access by itself.
