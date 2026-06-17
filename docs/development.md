<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium — Engineering Charter

> **Status:** canon. Primary development reference.
>
> **See also:** [ROADMAP.md](ROADMAP.md), [ARCHITECTURE.md](ARCHITECTURE.md),
> [THREAT-MODEL.md](THREAT-MODEL.md), [refactoring.md](refactoring.md),
> [contributing.md](contributing.md).
>
> **Relationship to the current implementation.** The Phase 0 scaffold has **landed** (see
> [README.md](../README.md)): a multi-protocol sing-box data plane (PRIMARY) with an optional
> Xray alternative engine and a separate AmneziaWG UDP path, the `myceliumctl` control tooling,
> the Ansible deployment, observability, the conformance tests, and the operational runbooks are
> all present in the tree. What remains is **live deployment and Definition-of-Done verification**,
> which await an operator-provided server (the DoD checklist is validated against a real node, not
> in CI). This document describes the *idealised* structure (`nodes/`, `control/`, `infra/`); the
> actual tree may differ — that is acceptable under §6 ("if the structure differs, it must preserve
> the same architectural boundaries"). Any accepted deviation is recorded in an ADR, not silently
> absorbed.

This document is the primary development reference for the Mycelium project. It establishes
code standards, architectural layers and their boundaries, hard prohibitions, layer-specific
rules, git workflow, testing (including network-degradation-resistance / obfuscation and network-condition simulation),
security, observability/measurement, CI/CD, agentic-development requirements, and documentation
policy.

Mycelium is a resilient, self-adapting mesh of VPN/relay nodes — a persistent private network
(PPN) that maintains private, reliable connectivity across unreliable, high-interference, or
restrictive networks: an interconnected mesh that reroutes around damage. The architecture is divided into five layers
(see [ARCHITECTURE.md](ARCHITECTURE.md)); the layers are stable across phases, but their
**implementation** evolves (from "a single node" to "the full mesh"), not the contracts between
them:

- **Layer 1 — Data plane** — the tunnel itself plus obfuscation: multi-protocol,
  statistical indistinguishability from HTTPS/QUIC (Xray-core, sing-box, AmneziaWG,
  Hysteria2/TUIC, cover site on Caddy/nginx).
- **Layer 2 — Control plane** — keys and identities, config distribution, the network-state
  detector, the auto-rotation loop, telemetry, and policy (the adaptation layer).
- **Layer 3 — Routing and orchestration** — path selection ingress→egress, multi-hop,
  rerouting.
- **Layer 4 — Discovery and membership** — who is in the mesh, how to join,
  sybil-resistance, NAT traversal (Phase 3: coordinator; Phase 4–5: libp2p DHT + gossip).
- **Layer 5 — Consumption interface (out of scope — standard clients connect to standard
  endpoints)** — nodes expose standard protocol endpoints; a bespoke end-user client
  application is explicitly out of scope (possible future work).

The primary goal of this document is to enable Mycelium to evolve through controlled changes
rather than architectural chaos, and to ensure that **user safety remains functional
requirement #1 on every commit**, not an afterthought.

Cross-cutting invariants of the project (violating any one of them is a development defect,
even if the code "works"):

1. **Do not invent cryptography or transports.** We stand on standard, audited primitives
   and libraries. Innovation lives in layers 2–4 (adaptation, routing, decentralisation),
   not in new crypto or transport.
2. **Indistinguishability over obfuscation.** The goal is not to "hide a VPN" but to be
   statistically indistinguishable from legitimate HTTPS/QUIC.
3. **Redundancy and graceful degradation by default.** Multiple protocols, ports, SNIs, IPs,
   and ASes active simultaneously; losing a node or coordinator slows the mesh but does not
   shut it down.
4. **Adaptation is measurement-driven.** Every automatic selection (transport, path,
   obfuscation parameters) rests on telemetry, not guesswork.
5. **Minimal knowledge equals security.** What is never collected cannot be seized, logged,
   or compelled to disclose. A node knows the minimum about any user.

---

## 1. Code Standards

### 1.1. Control agents and node software (Go primary; Rust for sealed organs)

The primary language for control agents, the coordinator, node software, and mesh software is
**Go** ([ADR-0012](adr/0012-go-primary-control-plane-language.md)): the upstream stack is Go
(sing-box, Xray, `amneziawg-go`, `go-libp2p`, Caddy), so the control plane embeds/drives it and
ships a single static binary. Shell+jq is retained only for deploy glue, one-shot config rendering,
and the CI conformance gates — *shell renders and deploys; the Go binary decides and adapts.*

**Rust** is reserved for **sealed, high-assurance organs** introduced later behind a shared
specification and test vectors (e.g. a spore-envelope validator, a hostile-input carrier parser, a
route-state model checker, or a future standalone hardened mesh node) — never as the entry point,
and only once its `spec/` + `test-vectors/` exist. Mixing Go and Rust within a single binary
requires explicit justification; the language for any new service is recorded in an ADR.

**Go:**
- **Code style:** `gofmt` + `goimports` (mandatory; enforced in CI).
- **Linting:** `golangci-lint` (including `govet`, `staticcheck`, `errcheck`, `gosec`).
- **Version:** pinned in `go.mod`; never "latest".
- **Errors:** wrapped (`fmt.Errorf("...: %w", err)`); do not swallow errors with blank `_`;
  do not panic in library code.
- **Context:** `context.Context` is threaded into all blocking/network calls as the first
  argument; no bare `time.Sleep` in hot-path network loops.
- **Concurrency:** every launched goroutine has a clear owner and a defined termination
  condition (no "leaking" goroutines); shared state lives behind channels or explicit mutexes.

**Rust:**
- **Code style:** `rustfmt` (mandatory; enforced in CI).
- **Linting:** `clippy` with `-D warnings` (a clippy warning is a build error).
- **Edition:** a fixed Rust edition in `Cargo.toml`.
- **Errors:** `Result<T, E>` with typed errors (`thiserror` in libraries; `anyhow` is
  acceptable in binaries/tests); `unwrap()` / `expect()` on production paths are **forbidden**
  without an explicit invariant comment.
- **`unsafe`:** forbidden without a `// SAFETY:` justification comment and reviewer sign-off;
  code touching crypto/FFI receives dedicated audit attention.

#### Mandatory requirements (both languages):
- Public functions, methods, and interfaces carry explicit types and doc-comments
  (Go doc / rustdoc) describing the contract: what it does, invariants, and error conditions.
- **Magic strings and magic numbers in logic are forbidden** — extract them into named
  constants (this is critical for network-persistence work: SNIs, donor names, detector
  timeouts, rotation limits — everything must be configurable; see §2.2).
- **Cross-service string identifiers are centralised** (transport names `vless_reality`,
  `amneziawg`, ...; link states `clean/throttled/blocked/shutdown`; control-plane message
  types) — one source of truth, not scattered literals.
- No "arbitrary timeout" — numeric network parameters are named and tied to a
  measurement or design decision.

**Example (Go):**
```go
// ClassifyLink diagnoses the current state of a transport link from observed
// network signals. It is pure: same signals → same verdict, no side effects.
//
// Returns one of the canonical LinkState values. It never panics; on insufficient
// signal it returns LinkStateUnknown rather than guessing.
func ClassifyLink(signals LinkSignals, thr ClassifierThresholds) LinkState {
    ...
}
```

---

### 1.2. Versioning and hygiene rules

Each independently versioned component (control agent, coordinator, config distribution
endpoint, mesh node) uses **SemVer (X.Y.Z)**:

- new services start at `0.1.0`;
- contracts (config-bundle format, control-plane envelope, telemetry schema) start at
  `1.0.0`;
- **a breaking contract change = major bump** with a N=2 parallel-release coexistence window
  (an older client in the field must not be bricked by a server update — this is an access
  concern, not merely a convenience concern).

Each submodule has:
- a single **runtime source of truth** for its version (`version` in the module manifest /
  build-time ldflags for Go / `CARGO_PKG_VERSION` for Rust) — what the component reports to
  observability;
- `CHANGELOG.md` — append-only history of all changes linked to an RP / commit
  (Keep-a-Changelog format; the newest `## [X.Y.Z]` section at the top);
- `README.md` with a `**Version:** \`X.Y.Z\` ...` header — a visible snapshot.

**Hygiene rule** (version drift between these three points is a desynchronisation that
erodes audit discipline):
- When the runtime version is bumped, **in the same commit** update the `README.md` header
  and add an entry to `CHANGELOG.md`.
- When a new entry is added to `CHANGELOG.md`, **in the same commit** update the runtime
  version and the README header.
- A draft entry goes into the `## [X.Y.Z]` section at the **top** of `CHANGELOG.md`;
  history is append-only below.
- **Bump-per-chunk — the obligation, not just the three-point sync.** Every change that lands a
  unit of Go spine work (`internal/**`, `cmd/**`) bumps the runtime version **in the same
  commit**. During the 0.x alpha the scheme is `0.<phase>.<patch>`: the MINOR tracks the
  lifecycle phase (0.1.x = Phase 1, 0.2.x = Phase 2, …) and one PATCH lands per phase increment
  (chunk); a `v0.<phase>.<patch>` git tag marks a phase close. *Forgetting to bump a feature
  chunk* — not three-point drift — is the failure this rule exists to prevent.

Enforcement: the offline gate `version_changelog_sync` asserts `internal/spec.Version` equals
the newest `## [X.Y.Z]` CHANGELOG heading (the const and the changelog can never drift apart);
CI additionally checks that a touched version file carries its README + CHANGELOG edits in the
diff. Neither gate can prove a chunk *should* have bumped — that stays the bump-per-chunk
discipline above, enforced at review.

The platform (root) version and the version table in the root `README.md` are updated only
when a **platform-level** bump is warranted (an RP introducing a new public surface or new
phase), not on every sub-component bump.

### 1.3. Authorship

Commits in this repository are authored by **mindicator** (the operator) only. The operator's
identity is configured in local git config (`user.name` / `user.email`) — it is not written into
the docs, and it is the only place the operator's contact details appear.

**AI/tool/model attribution in commit messages or trailers is forbidden.** Do not add
`Co-authored-by:` trailers naming any AI system, model, or code-generation tool. The old
convention of adding such a trailer is replaced by this rule: documentation credit is carried
at the doc level as **mindicator & silicon bags quartet**; individual commits carry no AI
attribution.

This applies in both ordinary commits and RP-implementing commits. The operator remains the
sole author and reviewer of every change.

Repo-local template: [`commit-template.txt`](commit-template.txt). Set the operator identity
once per clone so every commit carries it automatically:

```bash
git config user.name  "mindicator"
git config user.email "<your-operator-email>"
```

No AI co-author trailer follows.

---

### 1.4. Consumption interface (out of scope)

Nodes expose **standard protocol endpoints consumed by off-the-shelf clients** (VLESS+REALITY,
AmneziaWG, Hysteria2/TUIC, CDN-fronted, gRPC). A bespoke end-user client application — its
UX, QR/subscription-profile distribution, per-client failover as a UI feature — is explicitly
**out of scope** for this codebase (possible future work tracked separately). All client-side
deliverables and any TypeScript/React UI work described in earlier drafts are deferred.

---

## 2. Architectural Layers and their Boundaries

### 2.1. Dependency direction

Permitted direction (top-down; callbacks go only through events / contracts, not via direct
internal calls):

```text
Layer 5. Consumption interface (out of scope — standard clients connect to standard endpoints)
    ↓ (config bundle, health signals)
Layer 2. Control plane
    ↕ (policy "what lives where" ↔ blocking intelligence)
Layer 3. Routing and orchestration
    ↓ (path selection)
Layer 4. Discovery and membership
    ↓ (peer reachability, NAT traversal)
Layer 1. Data plane (tunnel + obfuscation)
```

**Primary architectural invariant (from ARCHITECTURE.md):** *the control plane and discovery
must themselves be persistent and resilient against network interference.* There is no point
having an unblockable tunnel if the config that configures it is served from a domain that can
be cut in minutes. The contract: "**data must not outlive the control plane**" — control and
discovery ride the same covert channels (CDN fronting, anycast, P2P fallback, bootstrap
configs distributed out-of-band) as the data.

What each layer does (roles, not implementations):

- **Layer 1 (Data)** carries traffic and is responsible for indistinguishability; it makes no
  decisions about "where to go" or "is this path alive" — it only executes the selected
  transport and surfaces raw signals upward.
- **Layer 2 (Control)** issues identities/configs, diagnoses links, runs the auto-rotation
  loop, accumulates telemetry, and builds policy. **The brain of adaptation.**
- **Layer 3 (Routing)** selects the ingress→egress path and reconstructs it when blocking
  occurs (rerouting); multi-hop from Phase 4 onward.
- **Layer 4 (Discovery)** answers "who is in the mesh and who has the right to be"; it
  provides sybil-resistance and NAT traversal.
- **Layer 5 (Consumption interface)** is out of scope: standard clients connect to standard
  endpoints.

### 2.2. Hard prohibitions

These are not recommendations. Violation is a development defect at severity S0/S1
(see [refactoring.md](refactoring.md)).

#### Absolutely forbidden:

1. **Inventing or modifying cryptographic / transport primitives.**
   Use only standard, audited libraries and protocols (REALITY/Vision via Xray/sing-box,
   Noise, the upstream TLS stack, WireGuard/AmneziaWG as-is). Any hand-rolled "cipher",
   "custom handshake", "improved" padding algorithm on top of crypto primitives, or a
   modified fork of a crypto library is **S0**, merge blocked. Home-grown crypto almost
   always produces a recognisable fingerprint or vulnerability — at audit this maps to
   `DISTINGUISHABLE_TRANSPORT` (if it damages indistinguishability) or `SECRET_LEAK` (if it
   weakens key protection) per §7.4 of [refactoring.md](refactoring.md). Tuning *parameters*
   (AmneziaWG junk packets, ClientHello/Reality-Vision padding, timing) is configuration on
   top of standard primitives and is permitted (§4.1 / §4.2); modifying the primitives
   themselves is not.

2. **Logging PII or user-identifying data.** Writing to logs, events, metrics, telemetry,
   crash reports, or storage the following is forbidden: source IP addresses of clients,
   client UUIDs linked to activity, SNI/donors linked to a specific client, the content or
   destination of traffic, geolocation at finer than a broad region, any stable identifier
   capable of linking requests from a single user across time. At audit this is `USER_DEANON`
   (a node/telemetry entry links an identity to traffic/ingress) or `TRAFFIC_CORRELATION`
   (an identifying channel has appeared) — severity **S0** per §7.4. What is never collected
   cannot be seized or compelled to disclose (THREAT-MODEL: minimal knowledge). Blocking
   telemetry (§9) is **aggregated, noised, and unlinked to any identity** — it is a signal
   about *network* state, not a log of *individual* behaviour.

3. **Hardcoding endpoints, keys, donors, SNIs, IPs, or coordinator/bootstrap addresses.**
   Literal secrets and network identifiers in code are forbidden. The reason is twofold,
   and each half is a separate S0 category per §7.4: (a) a secret/key in code is
   `SECRET_LEAK`; (b) a hardcoded endpoint/SNI/donor is a single point of blocking
   (`SINGLE_POINT_OF_BLOCK`: an adversary reads our own open/leaked code and cuts the
   address in minutes), directly violating the redundancy principle. All of these live in
   configuration / config-bundle distribution / discovery / ENV (§8.1), are loaded at
   runtime, and rotate without a rebuild.

#### Forbidden as architectural violations:

4. **A silent emergency path that bypasses rotation policy.** Any auto-rotation (transport /
   IP / SNI change, REALITY regeneration) must go through the explicit Layer 2 loop with
   rate limits, anti-flapping, and rollback; there is no "hidden emergency mode" that
   silently bypasses limits. An emergency is an explicit policy strategy, not a backdoor.
   A silent fallback that trades anonymity/indistinguishability for reachability without an
   explicit degradation policy is `SILENT_DEGRADATION` (**S0**, §7.4).

5. **Making the coordinator (Phase 3) an indispensable kill-switch.** The coordinator must
   be persistent and resilient against network interference in its own right
   (fronting/anycast/P2P fallback) and know the minimum; its compromise must not expose the
   mesh map. The architecture must have a path
   to operating *without* the coordinator (Phase 4). A centre with no fallback is
   `SINGLE_POINT_OF_BLOCK` (**S0**, §7.4).

6. **Making a node "know too much."** A node/hop does not accumulate what it does not need
   for its role: the ingress node need not know the final egress, and the egress node need
   not know the client; multi-hop is designed so that no single hop knows the full path.

7. **Connecting a new transport / node type via manual core surgery.** If adding a transport
   or node role requires edits "across the whole tree", that is a defect in the contract
   model; an RFC is needed. Transports are connected through a single adapter contract (§4.1).

8. **Duplicating a source of truth.** One truth type — one owner (see §2.4). Two locations
   storing the same truth type diverge and produce conflicting diagnoses/policy — that is an
   architectural defect (severity per §7 of [refactoring.md](refactoring.md); typically
   **S1**, **S0** if the divergence leads to an unsafe path selection or de-anonymisation).

9. **Covert network channels that bypass contracts** (undocumented "callback home", hidden
   telemetry channel, a node contacting a third-party service not declared in its passport)
   — these expand the attack surface and de-anonymise users. S0/S1 depending on context.

10. **Behaviour ahead of its phase / premature mesh.** Ship, run, or auto-enable no DHT,
    gossip/anti-entropy, distributed registry, announce-into-mesh, global-topology exchange, or
    autonomous cord promotion before its ROADMAP phase (ADR-0013 phase discipline; VIS-0003 §4).
    A Phase-0-2 spec type whose backing behaviour is unauthorized stays **inert by construction**:
    pure data + `Validate()`, importing no `net` / `os` / `os/exec` / DHT package, exposing no
    server or goroutine entrypoint, and `DiscoveryBackend` Announce/Find/ReportStress stay no-op
    stubs. "Not yet wired" must never be one careless import from "accidentally live" — the
    `internal/detect` and `internal/tune` purity gates enforce exactly this for the Phase-2
    detector/tuner. S0/S1.

11. **Shipping "everything on."** The default data-plane posture is **minimal exposure** — an
    operator-chosen subset, never the full transport matrix. A fresh `node-bootstrap.sh` node
    defaults-on EXACTLY {`vless_reality_vision`, `vless_reality_grpc`} (ADR-0022) and no other
    always-on ingress; widening the default set is a lockstep change (ADR-0022 + THREAT-MODEL port
    posture + `live_artifact_posture.sh`, in one commit). An advertised obfuscation/shape whose
    render path does not yet exist is likewise forbidden — wire it before enabling its inbound.

#### Permitted (how layers communicate):
- through **contracts** (config-bundle format, control-plane envelope, telemetry schema,
  transport adapter, discovery API);
- by publishing **events** (blocking detected, node joined/left, path reconstructed);
- tuning **obfuscation/timing parameters** on top of standard primitives;
- rotating endpoints/keys/SNIs **from configuration/discovery** at runtime.

### 2.3. Control-plane traffic-type separation

The control plane (Layer 2) and inter-node communication must have distinct message types;
mixing them into a single universal payload is forbidden:

- **Command** — "do this" (rotate transport, revoke identity, switch IP);
- **Event** — "this happened" (blocking diagnosed, node left, path reconstructed);
- **Measurement / Signal** — "here is a link observation" (timeouts, RSTs, throughput
  collapse, loss/jitter; aggregated and anonymous — see §8.5);
- **Query** — "report current known state" (node health, current regional policy);
- **PolicyUpdate** — "the policy 'what lives where' has changed" (distributed in the
  config bundle);
- **Ack / Failure** — confirmation or error.

Telemetry/Signal is a separate, most-sensitive type: it is subject to special anonymisation
rules (§8.5) and **never** carries PII.

### 2.4. Ownership: a single owner for each truth type

If the same truth type suddenly begins to be stored in two places, that is an architectural
defect: the sources diverge and produce conflicting diagnoses/policy
(severity per §7 of [refactoring.md](refactoring.md)):

| Truth type | Owner |
|---|---|
| Client identities/keys, issuance/revocation | Layer 2 (identity/keys) |
| Active transport configuration of a node | Layer 2 (config) |
| Current link diagnosis (`clean/throttled/blocked/shutdown`) | Layer 2 (detector) |
| Policy "which transport lives where" | Layer 2 (policy), distributed in config bundle |
| Node registry and reachability/health | Layer 4 (Phase 3: coordinator; Phase 4+: DHT/gossip) |
| Ingress→egress path selection | Layer 3 (routing) |
| Raw/aggregated measurement signals | Layer 2 (telemetry store) |

> **Note:** stores/registries record truth but do **not execute**. The node registry does
> not route traffic — Layer 3 does; policy does not run rotation itself — that is the Layer 2
> auto-rotation loop. Covert merging of "know" and "execute" violates layer boundaries.

---

## 3. Contracts

### 3.1. Single control-plane envelope

All inter-service / inter-node control-plane messages must contain at minimum:

- `message_id`
- `correlation_id`
- `causation_id`
- `type` (Command / Event / Measurement / Query / PolicyUpdate / Ack / Failure)
- `schema_version`
- `source` (role/class of sender — **not** a user identity)
- `target` or topic
- `timestamp`
- `idempotency_key` (for commands)
- `payload`

Additionally permitted: `trace_id`, `ttl_ms`, `region` (broad, not fine-grained),
`security_context`.

**Forbidden** in the envelope: the client's source IP, client UUID linked to activity, any
PII (§8.5).

### 3.2. Config-bundle format contract

The config bundle (an endpoint bundle distributed to clients) is a separately versioned
contract (sing-box / Clash-Meta-compatible bundle + metadata: priorities, transport, region,
"health"). Rules:
- semver; a breaking change = major bump with N=2 coexisting versions (an older client in the
  field must not break when the server is updated);
- the config bundle updates without reinstalling a client;
- the bundle **does not contain** long-lived secrets beyond what is needed to connect;
  endpoints are treated as rotatable and ephemeral.

### 3.3. Telemetry contract

The blocking-signal schema is a separately versioned contract. Invariants:
- only aggregated/noised link observations, tied to a broad region and a transport type,
  **not** to an individual (§8.5);
- semver; adding a field = minor; removing / redefining a field = major;
- any field capable of re-identifying a user is **never added** to the schema (this is a
  blocking code-review criterion).

### 3.4. Idempotency

For all control-plane commands:
- `idempotency_key` is mandatory;
- the handler detects a duplicate;
- a repeated command does not create a new side effect without explicit intent.

This is especially important for auto-rotation: a duplicate "change IP" command must not burn
two fresh IPs in sequence (both a resource concern and an exposure concern).

---

## 4. Layer-Level Development Rules

### 4.1. Layer 1. Data plane

- Behind REALITY/cover there is always a real donor site: active probing receives a
  legitimate response; no "suspicious" open ports or banners.
- Multiple transports run concurrently (VLESS+REALITY+Vision as primary; gRPC and
  CDN-fronted as fallbacks; AmneziaWG as the non-TLS path; Hysteria2/TUIC for
  UDP-friendly networks). Which is active is decided by Layer 3, not by Layer 1 itself.
- A transport is connected **via the single adapter contract** (see §2.2 item 7): one
  interface — bring up/tear down/health/apply obfuscation parameters. A new transport
  is a new adapter; no core edits.
- Obfuscation parameters (AmneziaWG junk, ClientHello/Reality-Vision padding,
  packet sizes/timings) are **not constants** — they are inputs to the adapter; they are
  tuned by Layer 2.
- Layer 1 does **not** diagnose links, does **not** select paths, and does **not** store
  truth about network health — it only executes and surfaces raw signals upward.
- Vendor specifics (Xray vs sing-box vs AmneziaWG) are hidden inside the adapter; nothing
  above Layer 1 should need to know them.

### 4.2. Layer 2. Control plane + adaptation layer

- **The network-state detector** produces the diagnosis `clean / throttled / blocked /
  shutdown` from signals (handshake timeouts, RST injection, post-connect throughput
  collapse, probe failure, loss/jitter). The detector must be **deterministic and
  measurable**: the same signals produce the same verdict; precision/recall are measured
  against labelled incidents (see §8.4).
- **The auto-rotation loop** responds to a block: change transport/port/SNI, regenerate
  REALITY, switch IP, narrow down to CDN front. Mandatory: rate limits, **anti-flapping**
  (protection against oscillation), and **rollback** on degradation. No silent bypass of
  limits (§2.2 item 4).
- **Telemetry → policy**: anonymised signals build the policy "which transport lives where";
  the policy differs by region and is updated from telemetry. An ML link-state classifier
  is an **optional enhancer**: the heuristics must work without it (this is a fundamental
  requirement, not "to be refined later").
- Layer 2 does **not** execute tunnels (that is Layer 1) and does **not** select the final
  path (that is Layer 3); it produces *diagnoses*, *configs*, and *policy*.
- **Persistence and resilience of Layer 2 itself**: configs/commands/config-bundle
  distribution ride CDN fronts, domain fronting, anycast, and P2P fallback. The contract
  "data may outlive the control plane" is not acceptable (§2.1).

### 4.3. Layer 3. Routing and orchestration

- **Ingress/egress separation**: the ingress node is close to the user (low latency, may
  have a "dirty" reputation); the egress node has a clean reputation; in Phases 0–2 they
  coincide.
- **Rerouting**: when an egress is unreachable from region R, clients in R are directed to
  an alternative egress; the path is reconstructed around the dead segment automatically.
- **Multi-hop (Phase 4+):** onion/garlic style — no single hop knows the full path. The
  tradeoff latency ↔ unblockability ↔ anonymity is chosen **deliberately by scenario**
  (the anonymity trilemma, THREAT-MODEL) and communicated honestly.
- Layer 3 does **not** maintain the node registry (Layer 4) and does **not** diagnose links
  (Layer 2); it *reads* from them and *selects* paths.
- **Closed default posture** (ADR-0026): the shipped default is closed — no open relay, no public
  egress by default, no unknown third-party transit, no bridge without explicit policy, no topology
  sharing; untrusted scopes are rate-limited, suspicious behaviour quarantined, and local/community
  traffic is preferred over external transit (`no_default_egress_or_relay` lens / `OPEN_RELAY_OR_DEFAULT_EGRESS`).
- **In-region ingress, node-carried egress** (ADR-0027): place ingress in-region; carry out-of-region
  egress **node-to-node** (an anastomosis hop), **never** user-direct to an out-of-region node and
  **never** through a TLS-terminating third-party front (which leaks source address + destination
  hostnames). The Phase-1 two-hop egress is node-local (never committed), scoped, and fail-closed —
  an absent/empty `via_user` is refused at render; only the named client routes out-of-region
  (`node_two_hop_failclosed`).
- **Split-tunnel by default** (ADR-0027): generated client configs carry only the traffic that needs
  the tunnel; a full-tunnel default (`0.0.0.0/0, ::/0`) is forbidden — a CIDR-only engine
  (AmneziaWG) still ships a documented region-exclude set, and full-tunnel requires an explicit
  `--full-tunnel` marker (`no_full_tunnel_default`).

### 4.4. Layer 4. Discovery and membership

- Evolution: Phase 0–2 — static config/config-bundle; Phase 3 — coordinator registry
  (Headscale-style); Phase 4–5 — libp2p Kademlia DHT + GossipSub.
- **Sybil-resistance** is mandatory from the moment membership becomes open (the primary
  threat for Phases 4–5): invite tree / social-graph trust / PoW; **knowledge gradient** —
  a new node routes little and "knows little", and trust grows with verifiable history.
  Design enumeration resistance from the **first day** of the relevant phase, not after.
- **NAT traversal**: AutoNAT determines the NAT type, hole-punching establishes a direct
  connection, otherwise a relay is used (DERP-style / circuit-relay). This makes a machine
  behind a home NAT a full mesh node (volunteer model analogous to Snowflake).
- Layer 4 does **not** route traffic and does **not** determine transport policy; it answers
  "who is in the mesh and who has the right to be" and surfaces reachability upward.

### 4.5. Layer 5. Consumption interface (out of scope)

Nodes expose standard protocol endpoints (VLESS+REALITY, AmneziaWG, Hysteria2/TUIC,
CDN-fronted, gRPC). Off-the-shelf clients connect to these endpoints. A bespoke client
application is explicitly out of scope — see §1.4.

---

## 5. Repository Structure

Recommended structure (idealised; the actual tree may differ while preserving boundaries —
§6 lead-in; any deviation is recorded in an ADR):

```text
mycelium/
  docs/
    ARCHITECTURE.md
    ROADMAP.md
    THREAT-MODEL.md
    development.md          (this document)
    refactoring.md
    contributing.md
    adr/                    (NNNN-<slug>.md)
    audits/                 (NNNN-<slug>.md)
    proposals/             (RP-NNNN, NNNN-<slug>.md)
    research/               (measurement experiments, incident labelling)
    runbooks/               (operational procedures: IP/AS migration, incident response)
    templates/             (adr.md, refactoring-proposal.md, audit.md)
    vision/
  contracts/
    envelope/               (control-plane envelope schema)
    subscription/           (config-bundle format)
    telemetry/              (blocking-signal schema)
    discovery/              (membership/discovery API)
  nodes/                    (node software, Layers 1+2)
    dataplane/              (transport adapters: vless_reality, amneziawg, hysteria, ...)
    control-agent/          (network-state detector, auto-rotation loop, telemetry)
    cover/                  (cover-site / donor configs)
  control/
    coordinator/            (Phase 3: registry, config distribution, blocking intelligence)
    subscription-server/    (config-bundle distribution)
    policy/                 (policy "what lives where")
  mesh/                     (Phase 4+: libp2p DHT, gossip, NAT traversal, multi-hop)
  infra/
    terraform/              (VPS provisioning, fast IP/AS migration)
    ansible/                (node deployment from zero in a single command)
  measurement/              (OONI-style measurements of what is blocked where)
  tests/
    unit/
    contract/
    integration/
    conformance/            (incl. network-degradation-resistance / obfuscation / no-PII)
    netsim/                 (network-condition simulation: RST, throttling, loss, shutdown)
  scripts/
  tools/
```

If the structure differs, it must preserve the same architectural boundaries (Layers 1–5,
contract separation, separate measurement subsystem).

---

## 6. Git Workflow

### 6.1. Branches

- `main` — stable branch;
- `feature/*` — feature changes;
- `refactor/*` — refactoring;
- `fix/*` — bug fixes;
- `rfc/*` — preparation of architectural changes.

### 6.2. Commits

**Subject — always a type-prefix line** (Conventional Commits):
```text
type: brief imperative description
```
Types: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `perf:`, `ci:`.

The subject does **not** start with the project name and does **not** start with an
`RP-XXXX` / `ADR-XXXX` id. The proposal/decision linkage lives in a **trailer**, never in the
subject — this keeps the subject readable and stops a commit from being confused with the
document it implements.

**Linking to an RP/ADR.** Every architecturally-significant change is recorded in an RP or ADR
([contributing.md §1.2](contributing.md)) and the implementing commit references it with a
trailer at the foot of the message:
```text
docs: clarify netem scenarios in netsim §7.3

Summary:
- <what changed>
- <why this is one coherent step (no scope expansion)>

Verification:
- <local command or CI check + what was observed>

Refs: RP-XXXX          # work implementing a Refactoring Proposal
# or: Implements: ADR-XXXX   # the commit that lands an Architectural Decision
```
A change with no RP/ADR behind it is either trivial (a type-prefix commit with no trailer) or it
is missing its proposal — write the RP/ADR first. See [`commit-template.txt`](commit-template.txt)
for the full skeleton.

**Commit authorship:** commits are authored by **mindicator** (the operator) only. No
`Co-authored-by:` trailer naming any AI system, model, or tool is added — see §1.3.
Documentation credit is carried at the doc level as "mindicator & silicon bags quartet".

### 6.3. Pull Request policy

For architecturally significant changes a PR must contain:
- description of the problem;
- list of affected layers/components;
- updated contracts (config bundle / envelope / telemetry / discovery);
- tests (including, where relevant, network-degradation-resistance/obfuscation conformance and netsim, §8);
- updated documentation;
- **threat-model impact** — does the change affect THREAT-MODEL assets (user identity/
  location, ingress reachability, operators, mesh map) and how; does it introduce new
  PII/hardcoded values/custom crypto;
- indication of whether an event-driven audit is needed (new transport, new node class,
  change to the trust model, change to the control plane — typically yes).

See checklists in [refactoring.md §16](refactoring.md).

### 6.4. Red master freeze

If `main` is red in CI, normal flow stops. Until green is restored only **fix-forward**
commits are permitted:
- fixing the root cause of the red CI;
- minimal version / CHANGELOG / README sync edits required by the fix itself;
- verification evidence.

New RP features, unrelated cleanup, "while I'm here" changes, and any scope expansion are
forbidden. After the remediation sequence: **Closure Verification** ([refactoring.md §12.9])
in place of a full new audit.

---

## 7. Testing

### 7.1. Test categories

- **Unit** — local logic (network-state detector, path selection, config-bundle parser).
- **Contract** — schema conformance: control-plane envelope, config-bundle format,
  telemetry schema, discovery API, transport adapter.
- **Integration** — neighbouring-layer interaction (Layer 2 → Layer 1: applying obfuscation
  parameters; Layer 3 → Layer 4: reading reachability).
- **Conformance** — does the component obey Mycelium invariants (see §7.4): no-PII,
  no-hardcoded-secrets/endpoints, no-custom-crypto, envelope discipline, idempotency,
  rotation anti-flapping, network-degradation-resistance/obfuscation invariants.
- **Netsim (network-condition simulation)** — behaviour under network-interference conditions (§7.3).
- **Network-degradation-resistance / obfuscation** — statistical indistinguishability (§7.2).

### 7.2. Network-degradation-resistance / obfuscation conformance

Because "indistinguishability over obfuscation" is a project principle, it is verified by
tests, not by eye:

- **Active probing of the cover site**: an automated test knocks on the node as a probe and
  verifies that a *genuine* donor site response is returned (legitimate answer), that there
  are no "suspicious" banners/ports, and that behaviour matches the declared site.
- **ClientHello profile**: the test verifies that the REALITY/Vision handshake has the
  expected shape (TLS fingerprint within upstream bounds, no "custom" fingerprint). We do
  **not** generate a custom TLS stack (§2.2 item 1) — the test catches regressions if an
  update accidentally breaks mimicry.
- **Statistical stream shape (best-effort)**: for each transport — verify that packet
  size/timing distributions remain within the "looks like HTTPS/QUIC" corridor and do not
  reveal a VPN signature. This is the symmetric answer to the adversary's ML-based behavioural-layer detection.
- **Obfuscation parameters are applied**: a test that the AmneziaWG junk / padding
  parameters selected by Layer 2 actually reach Layer 1 and change the observable shape.

These checks may require real sockets/containers — see §7.5.

### 7.3. Netsim: network-condition simulation

The adaptation layer (Layer 2) must be verifiable under controlled network-interference conditions. Minimum
netsim scenario set (via tc/netem, proxy faults, behavioural-layer-blocking emulator):

- **TCP RST injection** on the handshake of the selected transport → the detector must
  produce `blocked`, the loop must switch to a fallback **within the defined SLO**,
  without human intervention;
- **Post-connect throttling** (AS-level pattern "data dies": handshake succeeds, throughput
  collapses) → diagnosis `throttled`, correct migration;
- **Handshake timeouts / drops** → `blocked`/`shutdown` at the defined thresholds;
- **Loss/jitter** (UDP-unfriendly network) → graceful degradation to a TCP/TLS path, not
  failure;
- **Full shutdown of the selected transport** → client recovers on a working endpoint
  within the node/network within the SLO;
- **Anti-flapping**: an oscillating link (alternately alive and dead) → the loop does
  **not** enter an infinite rotation cycle; hysteresis/backoff is present.

Each netsim scenario has a measurable criterion (recovery time ≤ SLO; detector produced the
correct diagnosis; no false migration on a healthy link).

### 7.4. Mycelium conformance rules (gate-suite)

Each component must pass the conformance suite verifying the invariants in §2.2:

- **`no_pii`** — static + runtime scan: no source client IPs, client UUIDs linked to
  activity, precise geolocation, traffic content/destination, or other re-identifying fields
  appear in logs/events/metrics/telemetry (§8.5);
- **`no_hardcoded_secrets_endpoints`** — no literal keys, donors, SNIs, IPs, or
  coordinator/bootstrap addresses in code (§2.2 item 3); everything from config/ENV/
  config-bundle;
- **`no_custom_crypto`** — no hand-rolled crypto primitives/handshakes/crypto-library
  forks (§2.2 item 1);
- **`envelope_discipline`** — mandatory envelope fields present, no PII in envelope;
- **`idempotency`** — commands are idempotent (§3.4);
- **`rotation_safety`** — the auto-rotation loop has rate limits, anti-flapping, and
  rollback; no silent bypass of limits (§2.2 item 4);
- **`transport_adapter_contract`** — a new transport is connected only via the adapter
  contract, with no core edits (§2.2 item 7).

### 7.5. Local profile for socket/Docker-bound tests

Some network-degradation-resistance and netsim tests require real sockets, netem, or Docker. Such checks are
**not** considered failed simply because a standard sandbox prohibits bind/connect/Docker.
They are run in a local developer environment and the result is recorded in the RP report.
Examples (names are illustrative; updated as implementation progresses):

- `make test-degradation` (active cover-site probe + ClientHello profile);
- `make netsim SCENARIO=rst_injection|throttle|shutdown|flapping`;
- `docker compose -f tests/netsim/compose.yml up --build` before the run.

### 7.6. Mandatory rules

- every new component — unit + contract tests;
- every new contract (config bundle/envelope/telemetry/discovery/adapter) — contract tests;
- every new transport adapter — network-degradation-resistance conformance (§7.2) + adapter-contract;
- every change to the detector/rotation loop — netsim scenarios (§7.3) with a measurable
  SLO + regression on labelled incidents (precision/recall);
- every regression bug — regression test;
- any component touching user data — `no_pii` conformance.

---

## 8. Security

Security here is not "a section at the end" but functional requirement #1 (THREAT-MODEL
§"User protection over functionality"). Any feature that improves convenience at the cost of
de-anonymisation **does not pass**.

### 8.1. Secrets

- only via ENV / secrets manager;
- forbidden: storing secrets in code, in git-tracked config, or in a config bundle beyond
  what is strictly necessary for connection;
- forbidden: logging secrets;
- test keys are explicitly marked (`TEST_ONLY`) and are not valid in production;
- secret rotation (REALITY parameters, coordinator keys) is a routine operation, not a
  "set once and forget" procedure.

### 8.2. No user logs (threat-model-driven)

- **By default a node keeps no logs about users.** What is never collected cannot be seized
  or compelled to disclose (THREAT-MODEL: minimal knowledge).
- Operational logs (health, errors, link diagnosis) are **anonymised**: no source IPs, no
  client UUIDs linked to activity, linked at most to a broad region and a transport type.
- Enabling more verbose logging (for debugging in dev only) requires an explicit flag that
  is disabled in production builds, and that flag must **not** be capable of logging PII
  even when enabled.

### 8.3. Minimal knowledge and role separation

- a node knows the minimum about any user; ingress/egress are separated; multi-hop is
  designed so that no hop knows the full path (§4.3, §4.4);
- coordination, ingress, and egress operate in different hands and jurisdictions, so that
  compromising one component does not expose the others;
- **deniability of operator participation** is built into the design, not appended later.

### 8.4. Production access

- production connections follow the principle of least privilege;
- mutating production operations (IP/AS migration, identity revocation, coordinator rotation)
  are explicitly documented (runbook in `docs/runbooks/`);
- read-only diagnostics go through separate, restricted access paths;
- **direct production writes via agentic tools are forbidden by default** (§10).

### 8.5. PII / sensitive data

Categories of data that the project **does not collect and does not publish** (violation is
`USER_DEANON` / `TRAFFIC_CORRELATION`, S0, §7.4 of [refactoring.md](refactoring.md)):

- the client's source IP address;
- client UUID/identity linked to activity or time;
- SNI/donor/endpoint linked to a specific client;
- traffic content and destination;
- geolocation at finer than a broad region;
- any stable identifier linking requests from a single user.

Blocking telemetry (§11) is only permitted aggregated, noised, and unlinked to any identity.
Any new field capable of re-identifying a user is never added (blocking code-review
criterion, §3.3).

### 8.6. Legal and operational security

Distribution and operation of persistent private networking tools is subject to legal
restriction in certain jurisdictions; egress nodes bear liability for traffic that passes
through them (THREAT-MODEL §"Legal and operational security"). Consequences for development:
- protecting operators (deniability, clear responsibility boundaries, informed consent from
  Phase 4–5 volunteers) is a design requirement, not a disclaimer;
- before deploying nodes in a specific jurisdiction — a separate legal assessment for that
  jurisdiction is required (outside the scope of code, but it affects defaults: what is
  collected and stored).

### 8.7. Update path and node identity (ADR-0014, ADR-0015)

The self-update path and node credentials are supply-chain surface of the first order (a
poisoned update equals network-wide compromise):
- **Provenance before execution.** Verify the operator's signature on the pinned ref (SSH
  `allowedSigners` or GPG, established out-of-band) **before** any fetched code merges, installs,
  or executes; an unverifiable ref is refused. The network-update timer runs **only** in
  signature-verifying mode — `--insecure-no-verify` is a local-test escape hatch, never a deployed
  posture. All artifact-fetch logic stays in the single swappable `myc_fetch_artifacts` step; a
  replacement (signed tarball, OS packages) MUST preserve the provenance gate (`node_update_artifact_root`).
- **No shared key material.** Never copy a private key or node key material between operators or
  distribute it network-wide. Per-node credentials (REALITY keypair, AmneziaWG keypair, and a
  self-signed cert only if that transport is enabled) are generated **locally at bootstrap**; the
  bootstrap never fetches shared key material.
- **Certificate pinning, never blanket trust.** For self-signed Hysteria2/TUIC, pin the certificate
  by SHA-256 (cert / SPKI) in the per-node client config; `insecure: true` is forbidden
  (`no_insecure_tls`). TLS is transport security only — **never** node identity; membership is
  decided by the inviter-vouched trust layer, never by a certificate.
- **Stable identity across updates.** `--update` re-renders from the **local pinned identity** — it
  never regenerates per-node identity or the once-pinned donor SNI; it rolls back to last-known-good
  on any validation or post-apply failure, and treats a byte-identical candidate as a no-op (no
  needless engine restart).

---

## 9. Observability and Measurement (feeding the adaptation layer)

Observability here serves two purposes: operational (is the node alive) and **adaptive**
(feeding the policy "what lives where"). The boundary with §8.2 is strict: observability is
**anonymised by construction**.

### 9.1. Mandatory operational signals

Each node/service publishes (anonymised):
- health (alive; are handshakes completing);
- version + transport-manifest/policy version;
- structured logs (no PII, §8.2) with `correlation_id`/`causation_id`;
- critical errors;
- current per-transport link diagnosis.

### 9.2. Metrics

Minimum (per transport and broad region, no PII):
- handshake success rate;
- time to first byte (TTFB);
- post-connect RST/drop rate;
- post-connect throughput collapse (AS-level "data dies" signal);
- loss/jitter;
- active-probe failure rate;
- auto-rotation frequency and outcome (how many, where migrated, did it help);
- flapping indicator (is the link oscillating).

### 9.3. Measurement subsystem (OONI-style)

- measurements of "what is blocked where" (measurement, not guesswork) — a separate
  subsystem (`measurement/`), feeding policy and incident labelling for detector evaluation
  (precision/recall, §7.3/§7.6);
- measurements from clients — **only with explicit opt-in**, aggregated and anonymous (§8.5);
- the measurement dataset is Project Materials under license; third-party ML training on it
  requires written permission (§13).

### 9.4. Observability–adaptation link

Every decision made by the auto-rotation loop must be explainable through the metrics in §9.2
(which signal produced the diagnosis, why that fallback was chosen). "Magic" branching without
a measurable basis must not exist — this is a Cormen/Dijkstra-lens requirement at audit
([refactoring.md](refactoring.md)).

### 9.5. Local health vs. advisory weather (ADR-0021, ADR-0030)

Two strictly separate things. **Local health** (§9.1–9.2) is operational and stays on the node;
**advisory weather** is the only thing that may ever cross to another node, and it is fiercely
constrained because telemetry is itself a fingerprint / topology-map surface:
- **Loopback-only health.** A node's health/metrics exporters bind loopback **only**; the host
  firewall opens no exporter port on any public interface — off-loopback health is an enumeration
  surface (`live_artifact_posture`, `no_dataplane_pii`).
- **No cross-operator collector — ever.** Never build a cross-operator central collector, scrape
  coordinator, node directory, or discovery service in ANY phase; the only sanctioned collector is
  a **per-operator** monitor over that operator's OWN loopback exporters (ADR-0021;
  `no_operated_network_claim`).
- **Weather is opt-in fungi-only.** A node emits weather digests only if its operator explicitly
  opts into the fungi (cache-custodian) niche — **off by default**, individually revertible, never
  inferred; a non-fungi node emits **zero** digests.
- **Per-CLASS aggregate only.** Anything emitted is a per-CLASS aggregate (a `NodeStatusDigest`:
  TransportClass × HealthValue, order-of-magnitude buckets not exact counts, opaque non-geographic
  scope, TTL-bounded, per-operator-signed) — **never** a per-node row, per-node health vector, or
  stable per-node correlator. The Go shape makes a per-node row unrepresentable; keep it that way.
- **Omit, never zero.** A cell below the aggregation floor *k* is **omitted entirely** — never shown
  as 0, imputed, or blurred near-zero (a shown zero discloses the cell exists). `Validate()` enforces
  `sample_count ≥ min_aggregate`.
- **Opaque, non-geographic scope.** Every published scope-id is opaque and reversible to nothing —
  never a country, location code, ASN, region, or any geo-bearing value; size figures are
  order-of-magnitude buckets, lifecycle a distribution summing to 100%, never raw counts.
- **Aggregate-and-forget; emit-only.** A fungi applies the floor + noise **at the source** then
  forgets the raw inputs — it retains no raw observations, no node list, no topology, no per-edge
  weights, and never opens a queryable weather endpoint. Successive snapshots must not, in
  aggregate, disclose more than any single one (stable buckets + stable opaque scope-ids).

The fine connectivity-state detector value (`clean/throttled/blocked/shutdown`, `internal/spec`
`ConnState`) is **node-local and never transmitted**; only its lossy `AdvisoryHealth()` projection
to the coarse `HealthValue` is emittable, inside the digest above (the `detector_state_closed_vocab`
gate enforces the boundary).

---

## 10. CI/CD

### 10.1. Minimum pipeline

```text
Stage 1:
- format check (gofmt/rustfmt) + lint (golangci-lint / clippy -D warnings)
- version-hygiene check (§1.2)

Stage 2:
- unit tests
- contract tests (envelope / subscription / telemetry / discovery / adapter)

Stage 3:
- conformance tests (no_pii, no_hardcoded_secrets_endpoints, no_custom_crypto,
  envelope_discipline, idempotency, rotation_safety, transport_adapter_contract)
- secret scan (gitleaks/trufflehog) — no keys/endpoints in diff

Stage 4 (local/self-hosted profile, §7.5):
- network-degradation-resistance conformance (cover-site probe, ClientHello profile)
- netsim scenarios (rst/throttle/shutdown/flapping) with SLO verification

Stage 5:
- build (reproducible binary)
- staged deploy to canary node + post-deploy verification (probe + health)
```

### 10.2. Merge gate

Merge is blocked if:
- format/lint fails;
- version-hygiene check fails;
- contract tests fail;
- conformance tests fail (especially `no_pii`, `no_custom_crypto`,
  `no_hardcoded_secrets_endpoints` — these are security blockers, not style issues);
- secret scan triggers;
- documentation is not updated (§12);
- there are unresolved S0/S1 findings from a related audit.

Network-degradation-resistance and netsim suite (Stage 4), which require sockets/Docker, are not treated as failed
due to sandbox limitations — they are run locally and recorded in the RP report (§7.5). Where
a self-hosted runner is available, they are also merge-blockers.

### 10.3. Red master freeze

If `main` is red — §6.4 applies: fix-forward only; no new features or "while I'm here"
cleanups until green is restored; then Closure Verification.

---

## 11. Agentic Development Requirements

When Mycelium development involves AI coding agents:

### 11.1. Agents must not:
- change contracts/core without explicit scope;
- bypass tests and audits;
- make direct production mutations (IP migration, key revocation, coordinator rotation via an
  agentic tool — forbidden by default, §8.4);
- add hidden dependencies or **covert network channels** (callback-home, rogue telemetry) —
  these are a direct de-anonymisation threat;
- introduce PII, hardcoded endpoints/keys, or custom crypto (§2.2) — even "temporarily";
- change canon without an RFC / ADR;
- bundle multiple architectural steps into a single un-reviewable commit.

### 11.2. Agents must:
- work via PR;
- update docs alongside code;
- respect contracts and envelope discipline;
- run tests (and record which socket/Docker-bound suites were run locally, §7.5);
- leave a clear, reviewable diff;
- flag threat-model impact explicitly in the PR when touching any user-data-adjacent code
  (§6.3).

### 11.3. Commit authorship for agent-assisted work

Commits remain authored by **mindicator** (the operator). No AI co-author trailer is
added to commit messages or trailers — see §1.3. Documentation credit is carried at the doc
level as "mindicator & silicon bags quartet".

### 11.4. MCP servers for agents

Project-scoped MCP servers live in `.mcp.json` at the repository root (committed to git).
Policy:
- added **for a specific need**, not "just in case" — each server expands the attack surface
  and operational dependency (for a persistent private network this literally means a new
  surface for an adversary or legal compulsion);
- before adding — record in the commit *what*, *why*, and what *credentials/permissions* are
  required;
- tokens go through ENV, **not** in `.mcp.json` (no secrets in the file);
- do not duplicate native tools without added value (scope restriction / custom API);
- removing a server is an ordinary commit; "might come in handy" is not justification.

### 11.5. Preferred mode
- one agent writes;
- a second verifies (special attention: no-PII / no-hardcode / no-custom-crypto);
- a human approves canon.

---

## 12. Documentation

### 12.1. Required Mycelium documents

Minimum set:
- `docs/development.md` (this document);
- `docs/refactoring.md` (audit and refactoring policy);
- `docs/ARCHITECTURE.md` (architectural canon, Layers 1–5);
- `docs/ROADMAP.md` (Phases 0→5, Definition of Done);
- `docs/THREAT-MODEL.md` (adversary, assets, attack surface, legal/opsec);
- `docs/contributing.md` (new-component onboarding);
- per-component `README.md` + `CHANGELOG.md` (service passports);
- `docs/adr/` (architectural decision records);
- `docs/audits/` (audit reports);
- `docs/proposals/` (refactoring proposals / RFC, RP-NNNN);
- `docs/runbooks/` (operational procedures: IP/AS migration, blocking-incident response,
  coordinator rotation).

### 12.2. Documentation must be updated when:
- layers or their boundaries change;
- contracts change (config bundle / envelope / telemetry / discovery / adapter);
- ownership changes (who owns which truth type, §2.4);
- a new transport or node class is added;
- the trust model / sybil-protection / NAT-traversal approach changes;
- the network-state detector logic or auto-rotation loop changes;
- **what is collected/stored** about users changes (triggers an update to THREAT-MODEL, not
  just code);
- the version changes (version-hygiene, §1.2);
- versioning/compatibility rules change.

### 12.3. Code without documentation is not done

If an architecturally significant change is not reflected in documentation, the task is not
closed. A canon changed only in code is not canon. In particular: any change to the threat
model or collected data not reflected in THREAT-MODEL and development.md is a defect.

---

## 13. License and copyright headers

Mycelium is licensed under the **GNU Affero General Public License v3.0 or later
(AGPL-3.0-or-later)** — see [adr/0003-licensing-and-jurisdiction.md](adr/0003-licensing-and-jurisdiction.md)
(ADR-0003, accepted 2026-06-11). Canonical documents at the repository root:

- `LICENSE` — the full AGPL-3.0 text.

Rules for development:
- for **new** source files (Go/Rust) and significant markdown files add a copyright header
  carrying the `AGPL-3.0-or-later` SPDX identifier per the canonical form; retroactive sweep
  over existing files is not required;
- third-party libraries (Xray, sing-box, AmneziaWG, libp2p, ...) retain their own licenses —
  those licenses apply only to their materials, not to Mycelium;
- imports from projects with licenses incompatible with AGPL-3.0-or-later require explicit
  sign-off from the Owner;
- visual assets / diagrams / measurement datasets are Project Materials and fall under
  LICENSE;
- AI/ML training or dataset construction on Mycelium materials (including blocking-measurement
  datasets) is forbidden without written permission.

---

## 14. Checklists

### 14.1. New component checklist
- [ ] README (service passport) + CHANGELOG + runtime version exist (§1.2)
- [ ] Component contract is described and versioned (semver)
- [ ] No PII in logs/events/metrics (`no_pii` conformance, §7.4)
- [ ] No hardcoded endpoints/keys/donors/SNIs (`no_hardcoded...`, §7.4)
- [ ] No custom crypto (`no_custom_crypto`, §7.4)
- [ ] Unit + contract tests
- [ ] Anonymised observability (health/version/metrics, §9)
- [ ] Documentation updated (§12)
- [ ] Threat-model impact assessed (§6.3)

### 14.2. New transport (Layer 1) checklist
- [ ] Connected via adapter contract, no core edits (§2.2 item 7)
- [ ] Cover/anti-probing configured; probe returns a legitimate response
- [ ] Network-degradation-resistance conformance passed (probe + ClientHello profile + stream shape, §7.2)
- [ ] Obfuscation parameters are adapter inputs, not constants (§4.1)
- [ ] Netsim: block of this transport → correct diagnosis + fallback within SLO (§7.3)
- [ ] Per-transport metrics published (§9.2)
- [ ] Documentation (ARCHITECTURE transport matrix) updated

### 14.3. Network-state detector / auto-rotation loop change (Layer 2) checklist
- [ ] Detector is deterministic and measurable (precision/recall on labelled incidents, §7.3)
- [ ] Rate limits, anti-flapping (hysteresis/backoff), and rollback exist (`rotation_safety`, §7.4)
- [ ] Netsim scenarios (rst/throttle/shutdown/flapping) green with SLO (§7.3)
- [ ] No silent limit bypass / emergency bypass (§2.2 item 4)
- [ ] Decisions are explainable through metrics §9.2 (no "magic" branching, §9.4)
- [ ] Documentation (ARCHITECTURE Layer 2) updated

### 14.4. Architectural change checklist
- [ ] RFC / ADR / proposal exists (RP-NNNN)
- [ ] Problem and scope are clearly described
- [ ] Contracts updated
- [ ] Docs updated (including THREAT-MODEL if the threat model or collected data changes)
- [ ] Tests updated (incl. conformance / network-degradation-resistance / netsim, where relevant)
- [ ] Audit passed ([refactoring.md](refactoring.md))
- [ ] No unresolved S0/S1 findings
- [ ] No new single point of blocking/de-anonymisation introduced (redundancy preserved)

---

## 15. Inadmissible States

The following states are architecturally inadmissible (development defects, even if the code
"works"):

- custom-written or modified crypto/transport primitive
  (`DISTINGUISHABLE_TRANSPORT` / `SECRET_LEAK`, S0);
- PII in logs/events/metrics/telemetry (`USER_DEANON` / `TRAFFIC_CORRELATION`, S0);
- hardcoded keys/secrets (`SECRET_LEAK`, S0) or endpoints/donors/SNIs/coordinator address
  (`SINGLE_POINT_OF_BLOCK`, S0);
- silent emergency path bypassing auto-rotation limits/policy (`SILENT_DEGRADATION`, S0);
- coordinator as an indispensable kill-switch with no fallback and no path to operating
  without it (`SINGLE_POINT_OF_BLOCK`, S0);
- declared path redundancy that in practice reduces to a single real path
  (`REDUNDANCY_COLLAPSE`, S1);
- duplicated source of truth (diverging truth sources);
- covert network channel bypassing contracts (callback-home, rogue telemetry);
- untraceable control-plane commands; contracts without versioning;
- connecting a new transport/node class via manual core surgery;
- detector/rotation with "magic" branching lacking a measurable basis;
- drift between docs (including THREAT-MODEL) and code;
- inability to describe a component's role in one or two sentences.

---

## 16. Closing Rule

Mycelium must evolve as a contract-driven, loosely coupled, observable, verifiable, and
**user-safe by construction** system. The hard prohibitions are §2.2; the inadmissible end-states
are catalogued in §15 (each keyed to a §7.4-of-[refactoring.md](refactoring.md) finding ID and
severity). Any change that violates one is a development defect **even if it "works"** — the value
of the project is people's sustained, private, reliable connectivity and their safety, so code that
improves a metric at the cost of any of those invariants is a regression, not progress.
