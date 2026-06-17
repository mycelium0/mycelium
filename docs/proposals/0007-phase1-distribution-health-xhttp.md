<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Phase 1: matured distribution, health/failover, and an XHTTP-over-real-TLS LTE channel

- **ID:** RP-0007
- **Slug:** `phase1-distribution-health-xhttp-tls`
- **Status:** **LANDED — Phase 1 closed, GO-signed 2026-06-17.** The Phase-1 → Phase-2 transition is authorized; the distinctive deliverables (genuine single-layer TLS, the two-hop in-region-ingress topology, multiplexed REALITY, the self-replenishing subscription seam) were proven on the operator's live restrictive link on both LTE and Wi-Fi. Authoritative phase/DoD status + the on-device evidence live in the acceptance ledger ([../phase1-acceptance-ledger.md](../phase1-acceptance-ledger.md)); this proposal does not snapshot the verdict. Named deferrals carried to Phase 2: the Xray-XHTTP serving path, the observability dashboard/alerting, and Hysteria2/Salamander.
- **Phase:** Phase 1 (gated behind a signed Phase-0 GO; ROADMAP Phase-transition principle)
- **Type:** pre-declared **multi-phase / multi-workstream RP** (§13.3.2) — four workstreams (a, b, c, d), each with its own acceptance criteria and conformance evidence
- **Supersedes / relates to:** matures the Phase-0 out-of-band hand-rendered subscription (ADR-0020 §1); is the §15.8 seam the fungi layer (VIS-0007) later sits behind; consumes the inert EdgeReport schema (RP-0006); fences the signed cross-node bundle to the Inoculum (RP-0005, Phase 2)

---

## GO precondition — SATISFIED (Phase-0 signed GO 2026-06-15)

**Phase 1 is now AUTHORIZED.** The Phase-0 acceptance ledger was signed **GO on 2026-06-15**. The
Phase-0 → Phase-1 transition gate (ROADMAP "Phase-transition principle") is met: the Phase-0 DoD was
demonstrated in production with a real user, both transport families were validated on-device, and the
operator recorded the GO signature. Phase-1 code may now merge per the workstreams below.

**The authoritative phase / per-DoD status lives in the acceptance ledger**
(`docs/phase0-acceptance-ledger.md`). This proposal deliberately does **not** re-snapshot that verdict
here — an embedded snapshot desyncs (this very section did: it read "NO-GO" with a stale D1–D5 list well
after the ledger flipped to GO). For the live state, read the ledger, not this file.

> **D1 caveat.** D1 passed over a **REALITY node in the local region** with client-side
> multi-endpoint failover — it does **not** pre-demonstrate the not-yet-built genuine-TLS-XHTTP shape
> on the blocked EU path. RP-a's LTE reachability proof for the new shape is kept **independent** of
> the D1 sign-off and is **not** treated as already demonstrated by it.

Every workstream below carries an explicit no-start-before-GO gate; scope is written in
forward-design voice (not build-now instructions).

---

## 13.1. Title

Phase 1: matured config distribution, per-transport health + client-side failover, and a
first-class **VLESS+XHTTP-over-real-TLS** channel to restore reachability on the operator's
TLS-in-TLS-blocking mobile carrier — single-operator, the §15.8 seam for VIS-0007.

## 13.2. Rationale

### Field findings (LTE, load-bearing)

On the operator's restrictive mobile carrier, **every TLS-in-TLS shape is blocked to EU nodes** —
VLESS+Vision/TCP, VLESS+gRPC, and **VLESS+REALITY+XHTTP (XHTTP framed _inside_ REALITY is still
TLS-in-TLS)**. Behavioural-layer detection now identifies TLS-in-TLS (~80% per 2025-26 research);
REALITY / Vision / gRPC **are** TLS-in-TLS. What **survives** the same hostile link is **VLESS+XHTTP over genuine,
single-layer TLS** (a real cert — **not** REALITY): single-layer HTTPS that evades the TLS-in-TLS
classifier. A commercial peer's dedicated mobile servers that survive are exactly this single-TLS
shape; their gRPC+REALITY servers fail on the same link. gRPC on the non-standard **port 8443** is a
confirmed additional per-path tell. The root cause is **not** IP reputation or geo — the operator's
IPs are clean fresh VDS. It is **in-region path/transport blocking** — the classic **vantage problem**
(VIS-0006 §1): a clean-network test cannot see it, only the edge can; server-side every node is
healthy and identical.

> **Canon distinction this RP encodes in code.** ADR-0010's "VLESS+REALITY+XHTTP" is XHTTP framing
> **inside REALITY** = still TLS-in-TLS = blocked on this link. The shape that survives is **XHTTP over
> genuine TLS** (single-layer HTTPS) — a **different, non-REALITY** transport family. These are not
> the same transport. The codebase today folds Vision/gRPC/XHTTP into a single `reality-tcp`
> TransportClass (`internal/spec/edgereport.go:36-37`); a clean-vantage probe sees that family as
> healthy and therefore **cannot represent the mobile block at all** unless the surviving single-TLS
> family is a **distinct** closed-vocab member.

### Engine reality (verified, corrects an over-claim)

`nodes/dataplane/singbox/protocols.md:73-80` states plainly: **XHTTP (SplitHTTP) is an Xray-core
transport and is _not_ available in pinned sing-box 1.11.x**; sing-box's closest equivalent is the
v2ray `http` transport — a **different wire format**. The operator's client is **Xray/Happ**, and the
proven-surviving peer shape is **Xray XHTTP over genuine TLS**. Therefore the genuine-TLS-XHTTP
family is served **first-class by the Xray engine** (engine diversity is already sanctioned by
ADR-0010), and sing-box's `http` transport is a **fallback that must independently pass the live LTE
vantage test** before it may substitute. We do not let "sing-box primary" silently swap the wire
format the field finding is actually about.

### Distribution / health gaps

The client today holds **N separate per-node servers** (manual / Happ-test failover): there is **no
single self-updating profile** and **no automatic health-based failover**. The Phase-0 subscription
is deliberately **not** self-updating (out-of-band, hand-rendered; ADR-0020 §1). Phase 1 matures
**distribution + health + failover** around the existing transports and makes "what exactly is
blocked, where" legible — it does **not** re-introduce transports (those exist from Phase 0,
ADR-0010).

### Audit-0004 readiness

Two findings are carried in as **by-construction, build-failing invariants**, not soft DoD lines:

- **F-020** — the bundle `region` metadatum is bound to a **closed, EdgeReport-disciplined
  vocabulary** so the bundle (and any later per-user slice) never becomes a user-location channel
  (`docs/ROADMAP.md:137`).
- **F-022** — the subscription/config-distribution channel must be **≥ as block-resistant as the data
  plane** and must **not collapse to a single blockable domain/endpoint** — a `SINGLE_POINT_OF_BLOCK`
  invariant carried into the Phase-1 RP (`docs/ROADMAP.md:182`). The ROADMAP DoD only made the
  enumeration half concrete; this RP makes the channel-block-resistance half concrete too.

## 13.3. Scope

### Workstream split (the §13.3.2 response)

The whole Phase-1 program (new genuine-TLS-XHTTP transport **+** matured self-replenishing
subscription **+** per-transport health/failover **+** CDN last-resort) **exceeds** the 1+1+1
blast-radius cap. It is therefore a **pre-declared multi-workstream RP**, each workstream a single
reviewable risk surface with its own acceptance criteria and conformance evidence:

| Workstream | Owns | One shift it spends |
|---|---|---|
| **RP-0007-a** (transport) | the genuine-TLS-XHTTP family + its mandatory cover/probe re-vet | **1 transport/behaviour shift** |
| **RP-0007-b** (matured subscription) | the matured, self-updating per-node subscription endpoint | **1 layer/boundary shift + 1 surface shift** (honest count) |
| **RP-0007-c** (health/failover) | per-transport health **legibility** + client-side within-node failover ordering; per-operator own-network dashboard | **1 behaviour shift** |
| **RP-0007-d** (seam + pins + client-side merge) | the bundle/health closed-vocab schema, the two Audit pins, the `xhttp-tls` enum member (single owner), the client-side merge contract | **1 config-distribution surface shift, 0 transport, 0 layer** |

> **Single-owner of the closed vocabulary.** To avoid `CONFLICTING_SOURCE_OF_TRUTH`, the new
> `xhttp-tls` TransportClass member in `internal/spec/edgereport.go` and the `family_of()` extension
> in `transport_family_independence.sh` are authored **solely by RP-0007-d** (it owns the
> taxonomy/closed-vocab pins and claims zero transport shift, so inert enum data fits its blast
> radius). **RP-0007-a depends on (consumes) that member and does not edit `edgereport.go` itself.**

> **Single-owner of the F-022 channel property.** The §15.2 covert-carriage + ≥2-independent-path
> property of the sub channel is authored by **RP-0007-d** (which owns `sub_channel_not_single_point`
> and claims zero transport shift). **RP-0007-b consumes that gate as a non-regression bar** and does
> **not** author the carriage behaviour — this keeps RP-0007-b at exactly 1 layer + 1 surface and
> stops three distinct risk classes (availability, distribution-topology, indistinguishability) from
> mixing in one review surface.

### Layers, transports, contracts touched

- **Data plane (Layer 1):** RP-0007-a adds one inbound (genuine-TLS-XHTTP), default-off, fail-closed
  to a green probe. No other transport changes.
- **Config distribution (Layer 2):** RP-0007-b matures the per-node subscription from local-render +
  out-of-band file (ADR-0020 §1) to an always-reachable, self-updating per-node Remote-Profile URL.
  Each node serves **only its own** bundle.
- **Contracts (NEW / matured):** the versioned per-node **bundle** (a "partial view" artifact); the
  XTLS `profile-update-interval` refresh-cadence header; the §15.2 sub-channel property; the
  client-side **merge** recipe + local `myceliumctl aggregate` helper; an inert typed bundle schema in
  `internal/spec` modeled on `edgereport.go`; the new `xhttp-tls` closed-vocab member.
- **Telemetry:** the bundle gains a coarse **advisory** health block; **Phase 1 emits
  `health = unknown` only** (the enum exists; the value is honest). No running per-transport
  collection, no edge reporting, no collector.

### Explicitly out of scope (deferred, named)

- Live per-transport health **collection** (handshake-rate / TTFB / RST) — wired later; Phase-1
  bundle health stays `unknown` and advisory (RP-0007-c defines the **legibility** substrate and the
  client-native failover, not a new collector).
- In-region **edge reporting** emission — Phase-2 opt-in (RP-0006 / VIS-0006 §4); only the inert seam
  here.
- The **CDN-fronted last-resort** path — declared as an inert low-priority bundle slot only; the
  working front is a later RP; the candidate is an RU-reachable CDN, **not Cloudflare** (ADR-0014 §6:
  blocked/throttled on target networks).
- Any **central cross-node endpoint**, per-user HMAC slice, churn-diff stream, invite/credit/
  reputation (Lox/rBridge), gossip/DHT/fungi distribution, coordinator intake — Phase 3-5 (VIS-0007).
- The **signed / TTL-bounded / cross-node** bundle — the Inoculum (RP-0005, Phase 2).
- **Automated/block-triggered REALITY rotation** — Phase 2 (ADR-0020 §3); Phase-1 rotation is the
  operator running the manual runbook, after which the bundle re-renders and propagates via the loop.

### 13.3.1. Component participation table (mandatory)

| Component | Role in this RP (this flow) | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| Data plane — genuine-TLS-XHTTP inbound (RP-a) | New default-off inbound: `vless` + `tls{enabled:true, real cert, server_name=own-domain}` + XHTTP framing, **no** `reality` block; single-layer HTTPS that evades the TLS-in-TLS classifier | active | **Xray-core** (first-class for this family) + sing-box `http` (fallback, must pass LTE test) | XHTTP is an Xray transport absent from pinned sing-box 1.11.x (`protocols.md:73-80`); the surviving peer shape and the operator's client are Xray XHTTP; ADR-0010 sanctions engine diversity; no custom transport (ADR-0002) |
| Data plane — existing REALITY inbounds | **Kept in parallel** where they still work (local-region node, non-mobile paths); not removed | passive | sing-box (REALITY) | Breadth/redundancy (§15.6), degradation-not-failure (§15.5); REALITY survives some paths |
| Cover origin (loopback, Caddy role) | Genuine self-steal target: unauthenticated/non-XHTTP-path requests fall back to a real cover site so an active probe sees ordinary HTTPS terminating on the node | active | **Caddy** (existing cover role) | Already deployed (`infra/ansible/roles/caddy`); reused, not a new tool; the real-cert shape terminates the probe on the node so a genuine cover is load-bearing |
| Config-distribution endpoint (per node) | Matures to an always-reachable, self-updating **per-node** Remote-Profile URL serving **only this node's** bundle | active | sing-box / Clash-Meta / XTLS subscription format | Off-the-shelf client loop mandated by ADR-0016; a bespoke endpoint protocol would break the §15.8 seam |
| Per-node bundle (NEW contract artifact) | Versioned "partial view": ordered endpoints with `{transport_class, priority, region, health}`; rendered into the stock `urltest`+`selector` the renderer already emits | active | stock sing-box / Clash-Meta subscription | No bespoke wire format (ADR-0002 / §15.9); the bundle **is** the contract a fungus view-plane later fills |
| `internal/spec` bundle schema (NEW, inert) | Typed, versioned schema + `Validate()`, modeled on `edgereport.go`; **no emission beyond local render**; the contract VIS-0007 later fills | deferred | none | — |
| `internal/spec` TransportClass `xhttp-tls` member (NEW, inert) | New closed-vocab family distinct from `reality-tcp`; `IsValid()` accepts it | deferred | none | — |
| `myceliumctl` `subscription` / `aggregate` (control spine) | `subscription` emits the matured per-node bundle; `aggregate` is a **local** helper that merges M per-node sub URLs into one local profile (writes a local file; **not** a served endpoint) | active | Go stdlib | The cluster set must live only client-side; a served aggregator would be the forbidden central map |
| `control/lib/render_singbox.sh` + `render.sh` | Render the bundle + the new inbound; reuse the existing cert plumbing and `urltest`/`selector` failover structure | active | sing-box config | Existing renderer; reused, not replaced |
| Stock clients (sing-box / Clash-Meta / Happ / Xray) | Consume the per-node bundle, run the native auto-update loop + native `urltest`/`leastPing` failover (the authoritative health signal); merge M per-node URLs client-side | passive | sing-box, Clash-Meta, Happ, Xray-core | ADR-0016 off-the-shelf clients; building a bespoke client breaks the §15.8 seam |
| Per-operator own-network dashboard (RP-c) | Operator scrapes **their own** nodes' loopback exporters over **their own** SSH tunnels into **their own** Prometheus/Grafana; per-transport-per-region panels | active | Prometheus + Alertmanager + Grafana | ADR-0021 interim option-3; explicitly **not** a cross-operator central Prometheus ("the network map") |
| Reach-monitor (`:9551`) + dataplane-stats (`:9550`) | Read-only node-local L0 inputs the dashboard scrapes; `spec.TransportHealth` window is the producer contract | passive | sing-box clash_api / node_exporter | ADR-0019 node-local sensing; not a new collector |
| `spec.EdgeReport` / `SporeEnvelope` / `DiscoveryBackend` | Declared-but-inert seam: the bundle health cell key is shaped so a Phase-2 edge signal / Phase-3 spore can later populate the same `(RegionBucket, TransportClass)` cells without a contract rewrite | deferred | none | — |
| CDN-fronted last-resort slot | Declared **inert** low-priority bundle slot; working front is a later RP | deferred | RU-reachable CDN (**not** Cloudflare) | ADR-0014 §6: the candidate CDN is blocked/throttled on target networks; declared, not relied upon |
| Conformance gates (`sub_channel_not_single_point`, `bundle_region_closed_vocab`, `active_probe_owncert`, extended `family_of()`) | New/extended build-failing checks enforcing F-022, F-020, probe-safety, and family independence | test-only | shell + Go | Existing conformance harness (`tests/conformance/`); reused |

> **Gate applied.** Every row above carries a justified role; CDN, edge/spore schema, and the
> `internal/spec` additions are marked **deferred/inert** with their activating phase named, per the
> §13.3.1 status rule.

### 13.3.2. RP blast-radius cap statement

This RP **exceeds** the 1+1+1 cap as a whole and is therefore a **pre-declared multi-workstream RP**;
each workstream holds within the cap:

- **RP-0007-a (transport):** **0** layer shift (the inbound lives in the data plane; the bundle gains
  a passive descriptor); **1** transport/behaviour shift (the genuine-TLS-XHTTP family + its mandatory
  cover/probe re-vet — exactly one new family per the ADR-0010 taxonomy, since genuine-TLS-XHTTP is a
  **new** family distinct from `reality-tcp`); **1** node-surface shift (the new toggleable inbound +
  its `PORTS.md` canonical row). It **consumes** the `xhttp-tls` enum member from RP-0007-d and does
  **not** edit `edgereport.go`.
- **RP-0007-b (matured subscription):** **1** layer/boundary shift (config-distribution source-of-
  truth moves from a hand-carried file to a polled always-on URL) **+ 1** node/config-distribution
  surface shift (the new per-node subscription URL). **0** transport shift — it **consumes**
  RP-0007-d's `sub_channel_not_single_point` gate as a non-regression bar rather than authoring the
  carriage behaviour. (This is the honest count; the workstream's own earlier "0 net-new
  transport/behaviour" framing under-counted by co-locating the §15.2 channel property — that property
  is moved to RP-0007-d.)
- **RP-0007-c (health/failover):** **0** layer shift (the health producer is a pure projection of
  existing node-local L0 contracts, not a new collector); **0** transport shift (no new on-wire
  shape); **1** behaviour shift (per-transport health legibility + client-side within-node failover
  ordering). **0** new node-facing surface — health is an advisory metadata block inside RP-0007-b's
  bundle surface.
- **RP-0007-d (seam + pins + merge):** **1** config-distribution surface shift (the matured bundle/
  health/region/family **descriptors** + the client-side merge contract); **0** transport shift (it
  only adds the inert closed-vocab member that **names** the new family); **0** layer/source-of-truth
  shift (health stays node-local L0; edge/spore stay inert and unwired).

## 13.4. Current state (what works poorly now)

- The client holds **N separate per-node servers**; failover is manual/Happ-test; there is **no
  single self-updating profile** and **no automatic health-based failover** (ledger D1 evidence).
- The Phase-0 subscription is **out-of-band, hand-rendered, deliberately not self-updating**
  (ADR-0020 §1): a rotated port/SNI/shortId or a newly enabled transport requires a **manual
  re-import**.
- **REALITY / TLS-in-TLS is blocked on the operator's mobile carrier** to EU nodes; there is **no
  non-REALITY single-TLS shape** in the stack to fail over to on that path.
- The closed transport vocabulary **folds** Vision/gRPC/XHTTP into one `reality-tcp` family
  (`edgereport.go:36-37`); `transport_family_independence.sh` `family_of()` classifies
  `enable_vless_reality_xhttp` as `reality-tls-tcp` and a new toggle would hit the `__UNKNOWN__`
  branch and **fail** the gate — so a single-TLS family cannot be advertised as an independent failure
  surface today.
- The active-probe gate `cover_site_probe.sh` asserts **donor**-cert identity (lines ~119-127) — it is
  REALITY-only and would **fail** a genuine own-cert shape; there is no own-cert probe mode.
- An existing latent defect: `render_singbox.sh:426` renders a **client** outbound
  `transport.type:"xhttp"` while the sing-box **server** template uses `transport.type:"http"`
  (`server.template.renderer.json`) — a server/client transport-name mismatch the new family must not
  inherit.
- The two Audit gates this RP leans on (`sub_channel_not_single_point`, `bundle_region_closed_vocab`)
  **do not exist** in `tests/conformance/` yet — block-resistance and closed-vocab are currently
  assertions, not enforced invariants.

## 13.5. Target state (concrete interfaces, contracts, knowledge boundaries)

### The new transport family (RP-0007-a)

- A **distinct** inbound/tag (e.g. `vless-xhttp-tls-in`), **separate** from `vless-reality-xhttp-in`:
  `type:vless` + `tls{enabled:true, certificate_path, key_path, server_name=own-domain}` + XHTTP
  framing, **no `reality` block** — single-layer HTTPS.
- **Engine:** **Xray-core first-class** for this family (it speaks the surviving XHTTP wire format and
  interops with the operator's Xray/Happ client); sing-box `http` only as a **fallback that must
  independently pass the live LTE-vantage test** before substituting. A bump of the sing-box pin to a
  version with native XHTTP is an explicit dependency-policy change (a separate decision), not a free
  assumption.
- **Cert:** the operator's **own** wildcard real cert (genuine TLS), per ADR-0014 — a transitional
  own-network convenience, with per-operator own-domain ACME as the canonical posture; **not** a REALITY
  donor-borrow and **not** a self-signed pin. Reuse the existing `fullchain/privkey` plumbing
  (`render_singbox.sh:124-128`).
- **Cover/self-steal:** unauthenticated/non-XHTTP-path requests fall back to the existing loopback
  Caddy cover origin so an active probe receives a genuine site over the genuine cert.
- **Port:** **not 8443** (a confirmed per-path mobile tell): 443-co-resident behind the real cert's
  SNI via TLS-front routing, or a fresh non-8443 high port. `PORTS.md` (single source of truth) gains
  the row first; `phase0_port_canon.sh` asserts agreement across `PORTS.md`, group_vars, role
  defaults, the **deployed** template (`server.template.renderer.json`), and `render_singbox.sh`.
- **Toggle:** `enable_vless_xhttp_tls`, **default-off**, **fail-closed**: the inbound is **not
  rendered** unless the own-cert probe passes **and** the cover origin is reachable.

### The matured per-node subscription (RP-0007-b)

- A **stable per-node** Remote-Profile URL that stock clients import **once** and thereafter
  self-update; rotated port/SNI/shortId or a newly enabled Phase-0 transport reaches the
  already-imported client on its **next** scheduled refresh with **no manual re-import**.
- Serves **only this node's own** enabled endpoints (a "partial view"), rendered into the stock
  `urltest`+`selector` (and Clash `url-test`) the renderer already emits, ordered by `priority`.
- Emits the XTLS `profile-update-interval` HTTP response header (integer **hours**) to influence
  cadence; relies on the sing-box-mandated Remote-Profile auto-update loop (60-min default). **No
  bespoke client, no custom push** (ADR-0016).
- **Fail-closed serve:** a bundle that fails `spec.Validate()` is **not served**; the node serves the
  last-known-good Phase-0 static artifact (the parallel rollback path) and **never** a malformed/weaker
  bundle.
- **Block-resistance is a hard precondition (consumed from RP-0007-d):** the endpoint ships **only if**
  it is reachable via **≥2 independent paths** (SNI/donor origins); otherwise the endpoint does **not**
  ship and Phase-0 out-of-band hand-off remains.

### Bundle contract (RP-0007-d owns the schema; the seam)

Each endpoint: `{ transport_class: <closed enum incl. new xhttp-tls, distinct from reality-tcp>,
priority: int (default = the render_singbox.sh canonical order), region: <coarse closed-vocab
RegionBucket discipline, F-020>, health: <coarse enum alive|degraded|unknown; Phase 1 emits only
unknown, advisory> }`. The artifact is a **partial view** from day one. The health field is **fast-class
advisory** and stays so across the seam (see §15.8 below).

### Health + failover (RP-0007-c)

- The bundle health block is an **advisory initial-ordering hint** only; the **authoritative** signal
  is the **client's own native `urltest`/`leastPing` live probe** of the endpoint it is using. A noisy
  node-local signal can never **force** migration; a health band can reorder/deprioritise but can
  **never** by itself revoke/quarantine/alter trust (signal-speed non-escalation, VIS-0006 §5).
- **Phase-1 acceptance is client-native failover only** — bundle-health-keyed selection is **inert /
  forward-compat** (health stays `unknown`) and is **removed from the Phase-1 DoD scenarios** until a
  later RP wires real collection. This keeps RP-0007-c honest and within its 1-behaviour-shift cap and
  avoids the forged-health dishonesty trap (VIS-0006 §6).
- Per-operator **own-network** dashboard renders per-transport-per-region state (e.g. "REALITY-TCP
  degraded in region X, AmneziaWG alive") from the operator's own loopback exporters over their own
  SSH tunnels — **never** a cross-operator collector.

### Client-side merge (RP-0007-d)

- One profile spans an operator's nodes by **client-side merge** of M per-node sub URLs (stock
  `selector`+`urltest` across nodes; Xray `observatory`+`leastPing` for the Xray path). Each node
  serves **only its own** bundle.
- The local `myceliumctl aggregate` helper writes a **local** merged profile (per-node tag
  namespacing; one top-level selector/urltest; per-leg `profile-update-interval` preserved). It is a
  local offline file generator, **not** a server.

### Knowledge boundaries (preserved)

- A node knows and advertises **nothing** about sibling nodes; the cross-node set lives **only**
  client-side.
- The bundle carries node endpoints + coarse health/region **only** — **no per-user attribution, no
  visitor tracking** (ADR-0019 / VIS-0006 §10 no-queryable-API discipline preserved for the
  static-snapshot shape).

## 13.6. Risks

### Compatibility (node ↔ node ↔ config-distribution endpoint)

The served bundle must remain valid for **stock** sing-box / Clash-Meta / Happ / Xray across
versions. Bounded by a schema-version field + parallel retention of the Phase-0 static-file form
(rollback). **Cross-engine wire-format risk (S1, gate-blocking for DoD-1):** sing-box `http` ≠ Xray
XHTTP (`protocols.md:73-80`); the operator's client is Xray XHTTP. Mitigation: Xray-served XHTTP is
first-class; sing-box `http` only as a fallback that must independently pass the live LTE test; a hard
cross-engine interop fixture; and the existing `http`-vs-`xhttp` server/client naming mismatch
(`render_singbox.sh:426`) is audited and fixed within RP-0007-a so the new family does not inherit it.

### Loss of observability / measurements

Emitting a `health` field while no live collection exists risks a misleading/forged signal.
Mitigation: Phase 1 emits **`health = unknown` only** (the enum exists; the value is honest);
alive/degraded are inert until a later RP wires real collection + the VIS-0006 edge signal. **Vantage
blindness (load-bearing):** node-local L0 health declares all nodes healthy on the LTE-blocked path
because the node's own clean network is not the blocked path — exactly the field finding. Phase-1
health is **honestly partial**: it catches own-egress/handshake death; the **client's own** live
probe catches the in-region block; the dashboard cannot show in-region truth until the Phase-2 edge
signal lands. This limit is documented (AC) and the EdgeReport seam reserved so the gap closes without
a contract rewrite.

### Impact on indistinguishability / attack surface

The genuine-real-cert TLS shape terminates the active probe **on** the node (not relayed to an
external donor), changing the probe story (ADR-0020 §2). A weak/empty cover or a cert/SNI mismatch
yields a tunnel tell = `DISTINGUISHABLE_TRANSPORT` (S0). Mitigation: a new `active_probe_owncert` gate
(own-domain publicly-valid leaf; genuine cover-site 200 on unauthenticated/non-XHTTP paths; no tunnel
tell); exposure is **fail-closed-bound** to that gate passing **and** the cover origin being reachable
— default-off is necessary but **not sufficient**. `cover_site_probe.sh` remains the REALITY-only
probe and is documented as not applying to this inbound. The sub-channel adds **no** new on-wire
fingerprint: it is served over an already-vetted Phase-0 transport (AC-8); RP-0007-c adds only
loopback-local computation + bundle metadata.

### Impact on anonymity ("what the node knows")

The node-knowledge-about-user model is **not** expanded: the bundle carries node endpoints + coarse
health/region only; no per-user attribution. **Cert-as-identity caveat (OPSEC):** the genuine cert
ties a node to the operator's own domain (an identity + renewal dependency + coercion handle ADR-0014
warns of), and a network-wide wildcard is a cross-node correlator. Mitigation: ADR-0014 per-node
own-domain ACME as canonical; wildcard only transitional; the domain is **never** written into docs or
the bundle vocabulary (English, no hostnames). **At-rest map (named bounded exception):** the
`myceliumctl aggregate` helper writes a **local** merged profile that **does** enumerate the
operator's own network at rest on the operator's disk — an exfiltrated/seized file yields the full
network map. This is acknowledged as a **named, bounded exception** (analogous to the per-operator
monitor's own-network history, ADR-0021 / VIS-0006 §7), identity-free and never transmitted. The honest
claim is **"no served/network artifact enumerates the cluster,"** not "no map exists." **Dashboard
retained history:** the per-operator monitor is **not** aggregate-and-forget — it retains durable
own-network history (forensic value **and** an own-boxes coercion surface); stated in THREAT-MODEL.

### Temporary degradation and rollback risk

A malformed bundle could break import mid-refresh. Mitigation: `Validate()` before serve (fail-closed:
serve last-known-good or nothing, never the malformed bundle); the static Phase-0 file kept in
parallel as cold-start/rollback; the updater mirrors the fail-closed apply model (ADR-0015). Removing
REALITY would collapse breadth on the local-region node — REALITY is **kept in parallel** (§15.6,
§15.5).

## 13.7. Acceptance criteria (verifiable; per workstream)

> **Cross-cutting gate (every workstream):** a machine-checkable assertion that
> `docs/phase0-acceptance-ledger.md` reads **GO-signed** before any RP-0007 code merges as "Phase-1
> in progress." The ledger is **GO-signed (2026-06-15)**, so the workstreams are authorized to merge.

### RP-0007-a — genuine-TLS-XHTTP transport

- **AC-a1 (DoD-1, the LTE fix proven — independent of D1):** on a vantage reproducing the restrictive
  mobile carrier (or the operator's live LTE link), a stock client holding the bundle with REALITY
  shapes **blocked** reaches the open internet over the genuine-TLS-XHTTP shape, with client-side
  `urltest`/`selector` failover selecting it automatically. The reachability proof uses the **same
  wire format proven to survive (Xray XHTTP over genuine TLS)**; if sing-box `http` is offered as a
  substitute it must **independently** pass this LTE test. REALITY-still-works paths are unaffected.
- **AC-a2 (canon distinction enforced in code):** a conformance check asserts the new inbound has
  `tls.enabled:true` **without** a `reality` block and is a **distinct** inbound/tag from
  `vless-reality-xhttp-in`. Toggle `enable_vless_xhttp_tls` default-off; `per_protocol_toggle.sh`
  stays green.
- **AC-a3 (probe-safety, fail-closed — mandatory named deliverable):** a **new** `active_probe_owncert`
  gate PASSES for this shape: (i) leaf cert identity == the operator's **own** domain on a
  publicly-valid chain (not the donor); (ii) an unauthenticated/non-XHTTP-path probe gets a genuine
  cover-site **200** from the loopback cover origin via fallback; (iii) **no tunnel tell**. **The
  inbound is not rendered unless this gate passes AND the cover origin is reachable** (fail-closed).
  The ADR records that this probe path **replaces** the donor-relay probe for this inbound and that
  `cover_site_probe.sh` applies only to REALITY inbounds. Violation = `DISTINGUISHABLE_TRANSPORT` (S0).
- **AC-a4 (port/SNI canon):** `phase0_port_canon.sh` PASSES with the new row and asserts the port is
  **not 8443**; `PORTS.md`, group_vars, role defaults, the **deployed** template
  (`server.template.renderer.json`), and `render_singbox.sh` all agree. SNI is the operator's own
  domain, distinct from the REALITY donor SNI.
- **AC-a5 (cross-engine interop — HARD, not a fallback):** an interop fixture proves the operator's
  actual client (**Xray/Happ**) imports the new bundle entry **unmodified** and establishes a working
  tunnel, with the entry emitting the wire format that client speaks (Xray XHTTP), not the sing-box
  `http` name. The existing `http`-vs-`xhttp` server/client naming mismatch (`render_singbox.sh:426`
  vs the renderer template) is fixed within this RP.
- **AC-a6 (§15.6 redundancy / no collapse):** with the new shape added, **≥2 independent transport
  families** remain reachable per node (REALITY-TCP, AmneziaWG-UDP, and now genuine-TLS-XHTTP as a
  **new** family); `transport_family_independence.sh` stays green **after** its `family_of()` is
  extended (owned by RP-0007-d) to classify `enable_vless_xhttp_tls` as a family **distinct** from
  `reality-tls-tcp`. An AC asserts the new family counts as **independent** so advertised redundancy
  is real (guards `REDUNDANCY_COLLAPSE`).
- **AC-a7 (no-custom-crypto / no-legacy):** `no_custom_crypto.sh`, `no_legacy_transport.sh`,
  `no_insecure_tls.sh` stay green — VLESS+XHTTP+genuine-TLS uses only audited upstream primitives;
  nothing hand-rolled (§15.9 / ADR-0002); no insecure-skip flag.
- **AC-a8 (template-correctness):** all RP-a file edits target the **deployed** artifact
  (`server.template.renderer.json` + `render_singbox.sh`), not the documentation template
  (`server.template.json`), so the gates and `node-bootstrap.sh` exercise the real change.

### RP-0007-b — matured self-replenishing subscription

- **AC-b1 (DoD-3, propagation):** enabling a new Phase-0 transport server-side, or rotating
  port/SNI/shortId, then re-rendering, is reflected at the **stable** sub URL; an already-imported
  stock client picks up the change on its **next** scheduled refresh with **no manual re-import**.
  Conformance: a scenario fetches the URL before/after a rotation, diffs the served bundle, and
  asserts the URL string is unchanged.
- **AC-b2 (refresh cadence):** the sub HTTP response carries a valid integer-hours
  `profile-update-interval` header; a stock client honoring the XTLS standard / sing-box loop refreshes
  on that cadence. **Documented gap:** hour-granular is too coarse for sub-hour rotation (VIS-0007
  open Q) — recorded, **not** solved here; **no** custom push, and **no** reliance on the **refuted**
  server-driven 301/308 endpoint-migration or sub-over-tunnel-by-default.
- **AC-b3 (fail-closed serve — promoted from risk to AC):** a bundle that fails `spec.Validate()` is
  **not served**; the node serves the last-known-good Phase-0 static artifact and emits no
  malformed/weaker bundle. Conformance: feed a malformed bundle and assert the served response is the
  prior valid artifact (or nothing), never the malformed one.
- **AC-b4 (§15.2 / F-022 — consumed as a non-regression bar from RP-0007-d, with a fail-closed
  binding):** the matured endpoint ships **only if** `sub_channel_not_single_point` proves it is
  reachable via **≥2 independent paths** (SNI/donor origins) and does not collapse to one blockable
  domain. **Tunnel-rideable fetch is a configurable best-effort, NOT an acceptance line** (it depends
  on a mechanism VIS-0007 refutes as not off-the-shelf). **If ≥2 independent paths cannot be
  demonstrated, the endpoint does NOT ship and Phase-0 out-of-band hand-off remains** (the S0 risk is
  enforced, not noted).
- **AC-b5 (indistinguishability):** the sub response is served over an already-vetted Phase-0
  transport; adds **no** new fingerprint/banner/port (AC-8 of §14).

### RP-0007-c — per-transport health + client-side failover

- **AC-c1 (DoD-1, within-node failover, client-native only):** with all Phase-0 transports enabled on
  node-A and the REALITY/TLS-in-TLS family forced to fail (the LTE block), a stock client switches to
  a surviving same-node endpoint (the genuine-TLS-XHTTP shape from RP-a, or AmneziaWG) **within the
  client's native health-check interval**, via the **client's own probe** — **not** a server push and
  **not** a bundle-health-keyed decision (health stays `unknown`). Measured: time-to-recover ≤ one
  `urltest` cycle.
- **AC-c2 (DoD-2, dashboard per-transport per-region):** the operator's own-network Grafana renders,
  per node and per coarse region bucket, a per-transport-family state panel reproducing the field
  finding shape, sourced **only** from that operator's own nodes' loopback exporters over SSH. A
  conformance/runbook check proves **no** exporter port is open on any public interface and **no**
  cross-operator node appears (ADR-0021 compliance).
- **AC-c3 (signal-speed non-escalation, VIS-0006 §5):** a conformance test asserts the coarse health
  band is **fast-class advisory only** — it can reorder/deprioritise but can **never** revoke,
  quarantine, or alter trust. No code path lets a band trigger actuation.
- **AC-c4 (vantage honesty + retained-history honesty):** a runbook/doc check asserts the project does
  **not** claim in-region visibility from node-local health, and that the per-operator dashboard
  **retains durable own-network history** (forensic value **and** an own-boxes coercion surface) and is
  **not** aggregate-and-forget — the bounded exception named in ADR-0021 / VIS-0006 §7, **stated in
  THREAT-MODEL**. The EdgeReport seam is present and inert (schema-presence + no-emission test).
- **AC-c5 (cap respected):** a review gate confirms RP-0007-c changes exactly one behaviour (health
  legibility + within-node failover ordering) — no new transport, no new distribution topology, no
  layer/source-of-truth shift; the producer is a projection of existing L0 contracts, not a collector.

### RP-0007-d — seam, pins, client-side merge

- **AC-d1 (F-020, closed-vocab region guard — EXPLICIT pin):** a new `bundle_region_closed_vocab`
  gate (mirroring `TransportClass.IsValid()`) **fails the build** on any bundle `region` outside the
  audited closed set, or any precise geo/city/ASN/IP. Region values are byte-identical in discipline
  to `spec.EdgeReport.RegionBucket`.
- **AC-d2 (F-022, §15.2 — EXPLICIT pin, the channel property RP-0007-b consumes):** a new
  `sub_channel_not_single_point` conformance-OR-runbook check proves (a) the subscription is served
  over a Mycelium-grade covert transport, not bare HTTPS on one cuttable domain, and (b) the channel
  is reachable via **≥2 independent paths** so an already-bootstrapped client keeps receiving updates
  over a surviving path when one origin is cut. A design that resolves to one blockable
  domain/endpoint **fails** the gate (S0). Resilient-update is asserted via what **is** off-the-shelf
  (already-bootstrapped client polling over a covert transport via ≥2 origins), **not** via
  sub-over-tunnel-by-default or 301/308 migration.
- **AC-d3 (taxonomy + DoD-1 routing — single owner of the enum):** the closed transport-family
  vocabulary contains a **distinct non-REALITY single-TLS member (`xhttp-tls`)** separate from
  `reality-tcp`, added to `internal/spec/edgereport.go` with `IsValid()` accepting it, and
  `family_of()` extended for `enable_vless_xhttp_tls`. Given a bundle marking the REALITY family
  degraded/unreachable and the single-TLS family healthy, a stock client fails over to the single-TLS
  family **within the same node** (matches the LTE finding). **RP-0007-a consumes this member; only
  RP-0007-d edits `edgereport.go`.**
- **AC-d4 (§15.8 seam invariance — shape AND speed-class):** a conformance fixture asserts the
  Phase-1 bundle artifact shape (fields, family descriptor, region descriptor, health-metadata
  projection) is superset-compatible such that a Phase-3 fungus serving a per-user **partial view**
  over the same transport requires **zero** change to the client loop or the inter-layer contract.
  Test: feed a synthetic "fungus-shaped" partial view (same schema, fewer endpoints) through the same
  client-consumption path and assert it parses + selects identically. **The seam preserves the
  signal-speed boundary too:** the bundle health field is and remains **fast-class advisory**; a
  Phase-2 EdgeReport / Phase-3 spore may populate the **same field shape** **only** as advisory
  ordering input and may **never**, through this field, actuate trust/revocation/quarantine (that path
  stays the hard-class SporeEnvelope, Phase 5; cite VIS-0006 §5).
- **AC-d5 (DoD-4, client-side merge, no enumeration — with the at-rest caveat):** an operator imports
  M per-node sub URLs into one stock profile; the client merges them and fails over across nodes;
  rotation/new-node is picked up on next refresh with no re-import. A conformance check asserts **no
  single served/network artifact** enumerates the cluster (each node serves only its own bundle). The
  `myceliumctl aggregate` output is **operator-local, identity-free, never transmitted, carries no
  per-user attribution** — and is documented as the **named bounded at-rest map exception**, not as
  "no map exists." The signed/TTL cross-node form stays fenced to the Inoculum (RP-0005, Phase 2).
- **AC-d6 (health-field source compatibility, no running emission):** the bundle health field is
  structurally a projection of inert `spec.TransportHealth` such that a Phase-2 `spec.EdgeReport` and a
  Phase-3 `SporeEnvelope` stress-digest can populate the **same** field with no schema change —
  verified by a schema-compatibility test mapping each source type onto the field, **without** running
  emission (VIS-0006 §10: no cross-operator collector ever; no telemetry collected Phase 0-2).
- **AC-d7 (blast-radius static check):** no new running behaviour, no `DiscoveryBackend` binding, no
  goroutine/I/O added to `internal/spec`.

### Cross-cutting §14 gate (phase transition involved)

- **AC-G1:** no unresolved S0/S1 across the workstreams; indistinguishability not degraded (AC-a3,
  AC-b5); no new hidden cross-layer channel; the node-knowledge-about-user model is **not** expanded.
- **AC-G2:** domain Expert Lens Scores assigned (Parnas/Brooks/Dijkstra + Security/Threat +
  Network-persistence + Anonymity), **none < 5.0** with an open S0/S1.
- **AC-G3 (no-central-endpoint, the doctrine line):** a static check across all four workstreams
  confirms no central cross-node enumerating endpoint, no master map at the server tier, no
  coordinator-shaped index of all ingress (`SINGLE_POINT_OF_BLOCK` / `FORBIDDEN_TOPOLOGY_CENTRALIZATION`).

## 13.8. Documentation changes

- **New ADR — genuine-TLS-XHTTP transport family + cover/probe re-vet:** records the single-TLS vs
  TLS-in-TLS distinction, the Xray-first-class engine decision (and the sing-box-`http`-as-fallback
  caveat with the `protocols.md:73-80` boundary), the own-cert probe path that **replaces** the
  donor-relay probe for this inbound, and the non-8443 port constraint.
- **New ADR (or fold) — matured per-node distribution contract as the fungi seam:** the
  bundle-is-a-partial-view shape, the F-020 / F-022 pins, the `xhttp-tls` taxonomy member, and the
  §15.8 frozen client loop.
- **ARCHITECTURE:** Layer 1 (new inbound + cover fallback); Layer 2 (the matured per-node endpoint +
  the client-side merge model); the per-operator own-network dashboard (ADR-0021 interim).
- **THREAT-MODEL:** the own-cert probe-termination surface; the at-rest aggregate-map bounded
  exception; the dashboard retained-history bounded exception; the sub-channel-is-not-a-single-point
  and region-is-not-a-location-channel invariants.
- **ROADMAP:** annotate Phase-1 lines (:131-186) to point at RP-0007 and its a/b/c/d split; mark the
  F-020 / F-022 pins as enforced by gate.
- **VIS-0007:** annotate §"What this spawns" to point at RP-0007-d as the seam deliverable.
- **`nodes/dataplane/PORTS.md`:** the new canonical port row (not 8443).
- **`internal/spec/edgereport.go`:** the new `xhttp-tls` member doc (single owner: RP-0007-d).
- **`docs/proposals/README.md`:** add the RP-0007 index row.
- **`docs/phase0-acceptance-ledger.md`:** referenced (not modified) as the GO gate.

## 13.9. Migration strategy

1. **Pre-GO (now):** RP-0007 reviewable; **no merges.** Land the **single-owner** inert pieces only
   when GO is signed: the `xhttp-tls` enum member (RP-0007-d), `family_of()` extension, and the new
   conformance gates (`bundle_region_closed_vocab`, `sub_channel_not_single_point`,
   `active_probe_owncert`) — gates first so subsequent behaviour is fail-closed against them.
2. **RP-0007-a (transport), parallel coexistence:** add the genuine-TLS-XHTTP inbound **alongside**
   REALITY (never replacing it). Default-off; rendered **only** when `active_probe_owncert` is green
   and the cover origin is reachable. Prove AC-a1 (LTE survival, Xray XHTTP) and AC-a5 (Xray/Happ
   interop) on a vantage reproducing the carrier **before** the family is advertised in any bundle.
3. **RP-0007-b (matured subscription):** stand up the per-node endpoint **alongside** the Phase-0
   static file (kept as the cold-start/rollback artifact). Ship the always-on URL **only** after AC-b4
   demonstrates ≥2 independent reach paths; otherwise hold and keep out-of-band hand-off.
4. **RP-0007-d (seam + merge):** publish the client-side merge recipe + the local `aggregate` helper;
   document the at-rest-map bounded exception. No served cross-node artifact at any stage.
5. **RP-0007-c (health/failover):** surface the advisory `health=unknown` field and stand up the
   per-operator own-network dashboard; client-native `urltest` is the only failover authority in Phase 1.
6. **Final cutover:** clients move from manual N-server profiles to the merged self-updating profile
   on their own refresh cadence; the Phase-0 static file remains a parallel cold-start path.
7. **Across the eventual fungi transition (§15.8):** the off-the-shelf Remote-Profile /
   `profile-update-interval` client loop is **frozen now**; VIS-0007 later changes only **who answers
   the URL and what it knows**, never the client loop or the inter-layer contract — so the
   Phase-1→Phase-3-5 transition requires **no** contract rewrite.

## 13.10. Rollback / fallback

- **Bundle / endpoint:** on any malformed-bundle or endpoint failure, the node serves the
  last-known-good Phase-0 **static** artifact (kept in parallel for exactly this); never a
  malformed/weaker bundle (fail-closed, mirroring the updater's apply model, ADR-0015). If the matured
  endpoint cannot meet AC-b4 (≥2 independent paths), it does **not** ship and Phase-0 out-of-band
  hand-off remains — no access is lost.
- **Transport:** the genuine-TLS-XHTTP inbound is default-off and rendered only behind a green
  own-cert probe + reachable cover; toggling it off (or a failing probe) removes it without touching
  REALITY/AmneziaWG, which continue to carry traffic — clients fail back via their own `urltest`. No
  node is left exposed with a weak/empty cover (fail-closed).
- **Schema / enum:** the `xhttp-tls` member and the bundle schema are inert data; reverting them
  reverts the conformance gates with no runtime behaviour to unwind.
- **Never leave a node unsafe:** every render path is fail-closed (serve nothing rather than a weaker
  artifact; do not expose a real-cert inbound without a genuine cover); REALITY breadth is preserved
  throughout (§15.6, §15.5).

---

### Appendix — verified code anchors (for the implementer)

- TLS-in-TLS REALITY-XHTTP client outbound: `control/lib/render_singbox.sh:426`
  (`transport:{type:"xhttp"}` under `reality_tls`).
- Cert plumbing to reuse: `control/lib/render_singbox.sh:124-128`.
- `urltest`+`selector` failover structure to reuse: `control/lib/render_singbox.sh` (auto/mycelium
  outbounds).
- Engine boundary (XHTTP is Xray, absent from pinned sing-box 1.11.x; v2ray `http` is the closest
  sing-box equivalent): `nodes/dataplane/singbox/protocols.md:73-80`.
- TransportClass currently folds Vision/gRPC/XHTTP into `reality-tcp`:
  `internal/spec/edgereport.go:36-37`; `RegionBucket`/`TransportClass` coarseness discipline:
  `internal/spec/edgereport.go:66-78`.
- `family_of()` `__UNKNOWN__` branch a new toggle would hit: `tests/conformance/transport_family_independence.sh` (≈ lines 59-67).
- Donor-cert assertion that would fail an own-cert shape: `tests/conformance/cover_site_probe.sh` (≈ lines 119-127).
- Deployed server template (edit this, not `server.template.json`):
  `nodes/dataplane/singbox/server.template.renderer.json`.
- Ledger GO gate: `docs/phase0-acceptance-ledger.md` (verdict NO-GO; D2/D4/runbook/GO-signature open).
