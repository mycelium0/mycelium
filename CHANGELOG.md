<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Changelog — Mycelium control-plane spine

Notable changes to the Go control-plane spine (`cmd/myceliumctl`, `cmd/myceliumd`,
`internal/*`). Format: Keep a Changelog; versioning: SemVer. The single runtime source of
truth for the version is `internal/spec.Version`.

## [0.2.24] — 2026-06-30
### Added
- **RP-0011 Operability & Release, chunk C-3 — pure `deploy-plan` verb + `spec.EngineManifest`**: a new
  read-only Go type `internal/spec.EngineManifest` parses `control/engines.manifest.json` and resolves
  `{version, sha256, dl_base}` for an engine on a normalised arch (amd64/arm64; armv7 uncovered →
  required-flag fallback). New CLI verb `myceliumctl deploy-plan [FILE] [--arch A] [--manifest F]`:
  parses the node descriptor, reads the manifest READ-ONLY, resolves the pinned engine version + archive
  SHA256 for the target arch, and PRINTS the one-command on-ramp plus the equivalent direct
  node-bootstrap invocation with the pins filled in. It is PURE — reads the two input files and prints,
  spawns nothing, touches no live node state — so `node_cli_no_actuation` stays green (its dispatch check
  now also asserts `deploy-plan`). Verified on a Go node: resolves the correct per-arch pins for the
  example descriptor (amd64 vs arm64), both arg forms, suite 60/60. Builds on chunks C-1 (the committed
  manifest + resolver) and C-2 (node-bootstrap reads it as default pins).

## [0.2.23] — 2026-06-21
### Added
- **RP-0011 Operability & Release, chunk D — reachability posture (ADR-0034 §3)**: a node can be
  provisioned + converged but NOT a public entry. Mechanism = a single render-time `node_bind` param
  (default `"::"`, **byte-identical to today**; `apply_node_profile` stamps `"127.0.0.1"` only when the
  descriptor declares `reachable: false`), applied identically by the shell renderer and
  `internal/spec.RenderServer` so every PUBLIC inbound binds loopback (the hidden ShadowTLS detour stays
  loopback regardless). The firewall follows automatically — `harden_ufw`'s loopback exclusion is
  generalised to all inbound types, so a loopback-bound port is never opened (anti-lockout: sshd-allow
  stays first). New CLI verb `myceliumctl reachable on|off [--config FILE]` (write-only on the descriptor,
  apply with `--node-apply`). The bind layer holds on every flow the instant `reachable: false` is set
  (never fail-open); the firewall layer converges at bootstrap (ADR-0034 §3 staging note). New gate
  fixture `render_server_go_equiv` case D (reachable=false byte-identical shell↔Go) + Go unit test
  `TestRenderServerReachable` (absent → `"::"`, `node_bind:"127.0.0.1"` → loopback). Verified on a Go node
  + drilled DRY-RUN on a live node.
  Hardened after an adversarial review: (1) the firewall port selection is extracted to a pure, unit-tested
  helper `myc_firewall_singbox_ports` with a **null-tolerant** `listen` test (a missing `listen` defaults
  public instead of aborting `harden_ufw`); (2) a **fail-closed foreign-engine guard** — `apply_node_profile`
  refuses `reachable: false` while a non-sing-box-engine transport (e.g. the Xray-only `vless-xhttp-tls`) is
  enabled, since `node_bind` is sing-box-only and that inbound would otherwise stay public (ADR-0034 §4;
  dual-engine reachability is a tracked follow-up); (3) `.reachable` is read as a **strict JSON boolean**
  (parity with Go's typed parse); (4) `reachable on` warns that going public also needs a full bootstrap to
  open the firewall; (5) the doc contract is corrected (an absent `reachable` key renders public for
  byte-identity). New gate `reachable_firewall_loopback` pins the firewall half (public ports opened,
  loopback never opened) + `node_cli_no_actuation` now asserts the `reachable` verb is dispatched.
- **RP-0011 Operability & Release, REL-1 — release artifact (`make dist`)**: a `dist` Makefile target builds a
  DETERMINISTIC source tarball (= the AGPL Corresponding Source) of the committed tree via `git archive`,
  named `mycelium-<spec.Version>.tar.gz` (the name cannot drift from the spine version), plus a `SHA256SUMS`.
  `git archive` ships ONLY tracked files (per-node identity/secrets/rendered configs are gitignored + never
  tracked → they can never leak into the artifact) and `gzip -n` makes two builds byte-identical. The release
  is authenticated by a SIGNED git tag (ADR-0015 SSH-sig, the scheme `verify_signed_ref` already uses) — not
  produced here (the maintainer signs locally; see `docs/RELEASING.md`). New gate `release_dist_sane` pins
  version-naming, contents, secret-freeness, and reproducibility (SKIPS without a git work tree).

## [0.2.22] — 2026-06-21
### Added
- **RP-0011 Operability & Release, chunk B2c — transport writer CLI verbs**: `myceliumctl transport
  enable|disable PROTO [--config FILE]` edit the node-profile descriptor's `transports[]` (validated
  against the Go-owned registry, fail-closed) and write `node.config.json` (0600). They are WRITE-ONLY on
  the descriptor — no subprocess, no live-node mutation; the operator applies the change with the
  explicit `node-bootstrap.sh --node-apply` (B2b). New pure `internal/spec.NodeProfile.WithTransport`
  (dedup + order-stable list edit). The chunk-C gate `node_cli_readonly` is renamed/refined to
  `node_cli_no_actuation` (the verbs may now write the descriptor, but still never exec a subprocess,
  mutate live state, or perform a destructive op; the descriptor write is 0600). Also corrected the
  `usage` text. Verified on a Go node: build / vet / fmt-check / test / race green.

## [0.2.21] — 2026-06-21
### Added
- **RP-0011 Operability & Release, chunk C — read-only operator CLI verbs** on the Go spine
  (`myceliumctl`): `node validate FILE|-` (parse + fail-closed-validate a node profile — ADR-0034),
  `node plan FILE|-` (a DRY-RUN preview of what a descriptor resolves to — the enable-keys its
  transports turn on via the registry, plus the reachability / front / ingress / loops summary; no
  mutation), and `transport list [--json]` (the closed transport registry: proto / class / port /
  engine / frontable / toggleable). New pure resolver `internal/spec.NodeProfile.EnabledKeys()` (the
  descriptor → params-toggle translation the bootstrap will later apply additively) + exported
  `spec.ProtoByName`. New gate `node_cli_readonly` (offline suite 51 → 52): the verbs are READ-ONLY —
  no write / rename / remove / exec — so they cannot change a live node; the live-mutating verbs
  (`deploy`, `transport enable|disable`) land once the bootstrap reads the descriptor. Also corrected
  the stale `usage` "not yet ported" line (render-server / subscription are ported; only reality-keys
  remains). Verified on a Go node: build / vet / fmt-check / test / race green.

## [0.2.20] — 2026-06-21
### Added
- ADR-0034 **unified node profile (RP-0011 Operability & Release, chunk B)** — the INERT, node-local
  descriptor that unifies what a node IS into ONE declaration: `internal/spec.NodeProfile`, where
  transports / reachability / CDN front / two-hop ingress / background loops / (reserved) weather opt-in
  are **default-off CAPABILITY fields of one node form**. There is deliberately NO node-TYPE enum (fungi
  is a reversible niche — ADR-0018) and NO engine selector (engines stay additive — ADR-0032; the engine
  is derived from the enabled transports, never chosen). `Validate()` is fail-closed: transport names are
  checked against the Go-owned registry (never a restated `<proto>_enabled` rule), the front delegates to
  the ADR-0033 invariants (relay default, frontable-only, terminate-needs-ack), the two-hop minimal shape
  is required, and the reserved weather slot is refused while inert. `ParseNodeProfile` refuses unknown
  fields, so a stray node-"type" enum fails closed. Committed example `control/node.config.example.json`
  (all default-off; the real descriptor is node-local / never committed). New gate
  `node_profile_single_source` (one schema, capabilities-not-types, registry-read, example inert, no
  bootstrap path writes it). Nothing consumes it yet — the bootstrap reads it ADDITIVELY in a later chunk
  (byte-identical for a node that adopts no new field). Suite 50 → 51.

## [0.2.19] — 2026-06-20
### Added
- ADR-0033 **CDN/ingress front P2-2 (edge config compiler) + P2-3 (bundle integration + deploy wiring)**.
  - **P2-2:** `internal/spec.RenderFrontProxy` compiles a `FrontConfig` into the nginx config the OPERATOR
    deploys on their own edge: RELAY (default) → an `ssl_preread` SNI-routed TLS-PASSTHROUGH `stream` server
    (the edge terminates nothing, holds no key — the node's own cert is served end to end); TERMINATE
    (ack-gated) → a TLS-terminating reverse proxy (the metadata trade-off, emitted only with the explicit
    ack). Operator-supplied domain/host are config-injection-guarded (`isSafeHost`). `myceliumctl
    front-render --front F --params P` resolves the node address + transport port and emits it.
  - **P2-3:** `spec.RenderBundleFront` APPENDS one fronted endpoint (distinct `-front` tag, last-resort
    priority) to the bundle for the configured frontable transport — purely additive (a disabled /
    not-served front leaves the bundle byte-identical, so `bundle_render_go_equiv` stays green; the base
    LinkParams resolution was extracted to `bundleBaseLinkParams` so direct and fronted Links cannot drift).
    `bundle --front F` wires it in. Deploy wiring `control/lib/nb_front.sh` `front_setup` (run at the tail of
    `render_serve_bundle`, default-OFF): when a node-local `front.config.json` is enabled it compiles the
    edge config + re-renders the SERVED bundle WITH the fronted endpoint (fail-closed), the Go spine doing
    the render. New gate `front_deploy_inert` pins default-off / read-only-on-config / no-auto-enable; the
    front gate also pins the compiler (relay=passthrough/keyless, terminate ack-gated, injection-guarded).
  - REMAINING: only the operator reachability field test (P2-4), which needs a real bring-your-own domain.
    Additive; default-off; a node without a front is unchanged. Suite 49/49 on a Go node.

## [0.2.18] — 2026-06-20
### Added
- ADR-0033 **CDN/ingress front P2-1 (fronted-endpoint render)** — `internal/spec.FrontLinkParams` re-points
  a frontable transport's client endpoint at the operator's bring-your-own-domain front: the client dials
  `front-domain:443` (SNI = the front domain, so the edge routes on it) while the encrypted tunnel passes
  through to the node (default relay mode → the node's own-cert pin is unchanged end to end). It is a
  fail-safe NO-OP for a disabled / non-matching / non-frontable front, and mode-agnostic at the client
  (relay vs terminate is an EDGE concern, compiled into the edge proxy config by a later chunk). For
  vless-ws-tls the front domain drives both `sni=` and `host=`. INERT: nothing wires it into the bundle
  yet (that + the edge TLS-passthrough config compiler + deploy-time BYOD wiring are the next chunks).
  `front_relay_preferred` extended to pin the render (re-points server/SNI to the front on 443, no-op when
  disabled); `TestFrontLinkParams*` prove it. Additive; default-off; no wire change on a node without a front.

## [0.2.17] — 2026-06-20
### Added
- RP-0008 **P3-e (render-server → Go) + the two-hop via_user routing** — the LAST renderer port.
  `internal/spec.RenderServer` + `myceliumctl render-server --engine singbox` build the node's sing-box
  SERVER config on the Go spine, byte-identically to `myc_sb_render_server`: one inbound per enabled,
  sing-box-ENGINE protocol (the xray-only `vless-xhttp-tls` is dropped — dual-engine, ADR-0032) in the
  template's inbound order, the hidden ShadowTLS detour SS inbound when ShadowTLS is on, the static
  direct/block outbounds + private/bittorrent route rules, the loopback `clash_api` with an optional
  Bearer secret (omitted when unprovisioned, so legacy nodes render identically), and — when params
  declare a `two_hop` upstream — a VLESS+WS+TLS egress outbound + an `auth_user` route rule (ADR-0029
  in-region-ingress → out-of-region-egress, P3-e). The Go renderer encodes the template's per-inbound
  key order in typed structs (the only faithful way to reproduce jq's order in Go); the
  `render_server_go_equiv` gate keeps the structs in lockstep with the shipped template. Resolution +
  fail-closed checks mirror the shell exactly: REALITY material is consulted ONLY when a REALITY proto is
  on (so a non-reality node's shadowtls handshake defaults to www.microsoft.com and tls_sni to localhost);
  short_ids must be non-empty under REALITY; the own-cert families require an explicit tls_sni (C03); the
  per-identity password falls back via jq `//` (absent/null only, never ""); the two-hop is fail-closed
  (C17 shape/port, C18 via_user is a known client, C21 distinct hop). Verified byte-identical across 16
  adversarial fixtures on a Go node; `TestRenderServer{Shape,ClashSecretOmitted,FailClosed}` pin the
  structure where Go is unavailable. Additive; the shell stays authoritative until cutover. **RP-0008 P3
  (renderer porting → Go) is now COMPLETE (P3-a..P3-e).**

## [0.2.16] — 2026-06-20
### Added
- RP-0008 **P3-d (subscription → Go)** — `internal/spec.RenderSubscription` + `myceliumctl subscription
  --engine singbox` port the per-client sing-box client config + Clash-Meta YAML emission to the Go spine
  (the strangler continues; the shell stays authoritative until the gate is green). Per client it emits
  `<safe>.singbox.json` (one outbound per enabled sing-box-engine protocol, the ShadowTLS handshake detour,
  a urltest "auto" + "mycelium" selector + direct/block) and `<safe>.clash.yaml` (the Clash-supported
  subset). It carries the **dual-engine** update (ADR-0032): the enabled set is filtered to the sing-box
  ENGINE, so the xray-only `vless-xhttp-tls` is **skipped** (a sing-box client cannot dial the xhttp
  transport — the Xray client dials it), and resolution uses the canonical `tls_key_path`. Resolution
  mirrors the shell EXACTLY (per-identity password → shared-secret fallback, TUIC-uses-UUID, the C03
  own-cert-SNI fail-closed, registry-priority order, `tr -c` name sanitisation). New gate
  `subscription_go_equiv` byte-diffs both producers across two fixtures (all transports + 2 clients incl.
  the skipped xray proto and a sanitised name; a subset with an empty client password → shared-secret
  fallback); `TestRenderSubscriptionShape` pins the structure where Go is unavailable. Additive; no wire change.

## [0.2.15] — 2026-06-19
### Added
- RP-0010 **C5 (advisory emit)** — the inert constructor for the ADR-0030 advisory-emit seam:
  `internal/spec.BuildNodeStatusDigest` turns per-class `AdvisoryHealth()` projections (the lossy,
  externalisable view — never the fine `ConnState`) into a `NodeStatusDigest`, enforcing the privacy
  invariants BY CONSTRUCTION: **k-floor with omit-not-zero** (a class with `< k` member observations is
  DROPPED, never zeroed/imputed; below the floor entirely it returns `ErrAggregationFloor` — emit
  nothing, never a sub-floor digest), **class-aggregate** alive-dominant (one `(class, HealthValue)`
  cell, no per-member row, no node ref), region forced `RegionUnspecified`, deterministic (sorted class
  order). Pure, no I/O, no live emission/signing — the live emitter/cache/publisher remain a future
  cross-cutting RP (ADR-0030). The `NodeStatusDigest` type + `Validate` were already the landed seam;
  this adds the safe constructor + tests. Gate `node_status_digest_emit_safe` pins the emit-safety at
  the conformance layer (no per-node/identity/location field in the type; the builder omits sub-floor
  cells + forces unspecified region) so it holds where `go test` does not run. Additive: no wire change.

## [0.2.14] — 2026-06-19
### Added
- RP-0010 **Plane-1 C5c-1 (deploy seam)**: `install_spine` now builds BOTH Go binaries from the fetched
  source — the control CLI (`myceliumctl-go`) and the daemon (`myceliumd`, the MEASURE-plane host) —
  into `$TOOLING_DIR/bin`, with the same idempotent rev-keyed skip (`myceliumd version` added). The
  daemon runs under systemd **`Type=notify` + `WatchdogSec`**: `myceliumd` sends `sd_notify(READY=1)`
  once its listener is bound + monitors are up and pings the watchdog (zero-dependency; reuses systemd's
  liveness contract rather than a hand-rolled supervisor — ADR-0031). New `control/lib/nb_measure.sh`
  `measure_enable` / `measure_disable` (`--measure-enable` / `--measure-disable`) write + enable the
  `mycelium-measure.service` unit — **SHIPS DISABLED**: the unit is written + enabled ONLY by the
  explicit flag, NEVER by `flow_bootstrap` / `flow_update` / `install_tooling` / `install_spine`, so an
  auto-pull deploys the (always-built, inert) binary but can never start the advisory plane (the C4c-2
  pattern). `measure_enable` is fail-closed (requires the binary + both node-local configs). Gate
  `measure_daemon_ships_disabled` pins the no-auto-arm contract. The daemon is strictly ADVISORY —
  actuation stays behind the RP-0012 triple gate. Node-local config generation (C5c-2), the bash-loop
  wiring (C5c-3), and the live drill (C5c-4) follow. Additive: no wire/output change on a stock node.

## [0.2.13] — 2026-06-19
### Added
- ADR-0033 (extends ADR-0029) + the inert `internal/spec.FrontConfig` schema for an OPTIONAL
  operator-provided CDN/ingress front: bring-your-own-domain, opt-in, default-off. `FrontConfig.Validate`
  pins the doctrine fail-closed — an enabled front requires the operator's own domain, may sit in front
  of ONLY the genuine-single-TLS own-cert HTTP transports (`vless-xhttp-tls` / `vless-ws-tls` via the
  closed `IsFrontableTransport` set; REALITY/raw/UDP refused), and is RELAY-PREFERRED: `FrontMode` is a
  closed `{relay, terminate}` enum where `relay` is the default (`EffectiveMode`) and `terminate`
  requires an explicit `ack_terminate_tradeoff` (a TLS-terminating edge is the metadata leak
  THREAT-MODEL calls "worse than neutral" — ADR-0026). The schema records the efficacy framing: a front
  is COMPLEMENTARY / last-resort (reachability on IP/SNI-blocking networks + control-plane hardening),
  NOT a fix for the destination-class throttle, where the in-region two-hop is primary (ADR-0027). Gate
  `front_relay_preferred` pins the closed vocab + the relay-preferred / frontable-only / domain-required
  invariants + the efficacy framing (and runs the Go tests where a toolchain is present).
  `control/front.config.example.json` documents it. INERT: nothing consumes `FrontConfig` yet — the
  fronted-endpoint render + the deploy-time bring-your-own-domain wiring + an operator reachability field
  test are a follow-on RP (ADR-0033 §Implementation). Additive: no wire/output change.

## [0.2.12] — 2026-06-19
### Added
- RP-0010 **Plane-1 C5b (daemon embed)**: `myceliumd` now hosts the MEASURE plane. Given a
  `--measure-config` (alongside `--reachability-config`), it builds an `internal/measure.Assembler`
  ONCE (so the per-member detector hysteresis + tuner pheromone persist across ticks) and runs a tick
  loop that folds each `reach.Monitor` snapshot into a `rotate.PlanInput`, writes it atomically to the
  configured `output_path` (the file `myceliumctl rotate-plan` consumes), and serves the latest on a
  loopback `/rotation/plan-input`. The active member, between-tick `RotationState` (`rotate_state.json`)
  and output paths are re-read each tick so a rotation is picked up without losing accumulated state.
  At startup the daemon cross-checks the measure config against the reachability config and refuses to
  run on a dangerous mismatch (an active ref that is not a member; a member with no reach probe — it
  would stay seeded-clean and never be rotated away from; a `tick_ms` below the slowest probe interval
  — it would re-fold the same window and defeat the detector anti-flap / over-reinforce the tuner). The
  reach snapshot is filtered to member refs before the fold (reach may probe context anchors the node
  does not rotate among). The written `PlanInput.now` is its freshness stamp (the file freezes at the
  last good tick across failing ticks, so the consuming loop rejects a stale one); the loopback
  endpoint always surfaces `tick_at` + `last_error`.
  Strictly ADVISORY (AC-4): it assembles + serves a plan input and never spawns a process, invokes the
  engine, or actuates — rotation stays behind the RP-0012 triple gate. INERT until a measure config is
  supplied (nodes have none yet; deployment + bash-loop wiring + the live drill are C5c). New gate
  `measure_daemon_advisory` pins the daemon's no-actuation surface (denylist: no `os/exec`,
  `exec.Command`, `syscall.*Exec`, or sing-box invocation; asserts the measure+reach wiring is present).
  `control/measure.config.example.json` documents the schema. `cmd/myceliumd` tests cover config
  validation, fail-closed assembler build, the assemble golden (+ planner round-trip), and the file
  round-trips. Additive: no wire/output change.

## [0.2.11] — 2026-06-19
### Changed
- Post-review hardening of the RP-0010 Plane-1 MEASURE plane and the Phase-2 purity gates (from the
  `internal/measure` adversarial review):
  - `internal/measure.New` now rejects two members sharing a `proto` — the planner keys candidate
    selection on proto (rotate.Plan skips `c.Proto == active.Proto` and ranks by registry order), so a
    duplicate would leave one member permanently un-selectable. Mirrors the existing duplicate-ref
    rejection.
  - The four Phase-2 purity gates (`detector_pure_no_probe`, `tuner_pure_advisory`,
    `rotator_pure_planner`, `measure_pure_advisory`) shared determinism token-bans a future edit could
    evade. Hardened all four: the wall-clock ban now matches `time.Now`/`time.Since` with or without a
    trailing `(` (catches `var f = time.Now`); the channel ban catches the directional `chan<-`
    spelling; and an ALIASED `import x "time"` (which slipped past the alias-blind path allowlist) is
    now refused. `measure_pure_advisory` additionally forbids calling `rotate.Plan` (assemble-only,
    AC-4). No production code path changed.

## [0.2.10] — 2026-06-19
### Added
- RP-0010 **Plane 1 (MEASURE)**: `internal/measure.Assembler` — the node-local seam that folds the
  existing `internal/reach` health signal through the detector and the self-tuner into a
  `rotate.PlanInput`, closing the adaptivity loop measure → detect → tune → assemble → plan. It WRAPs
  existing components and adds NO new measurement surface (RP-0010 AC-6): it consumes only the
  fast-class `spec.TransportHealth` window (success/failure per opaque transport ref) and never dials,
  reads a file, or runs a process. Because reach reports only success/failure, the `DetectorSignal` is
  DERIVED from the window — a window with ≥1 success proves the channel connects and handshakes; zero
  successes is read as a black-hole; the by-products reach never measures (active-probe, post-connect
  collapse, single-stream comparison) are presented as non-faulted — and the success ratio then grades
  a connecting channel clean vs throttled inside the detector. Strictly ADVISORY (AC-4): it only
  assembles a plan input, never actuates — actuation stays behind the RP-0012 triple gate. Stateful
  across ticks (per-member detector hysteresis + evaporating tuner weight) and deterministic (the clock
  is injected). Conformance gate `measure_pure_advisory` pins the purity (allowlist {fmt, sort, time,
  internal/detect|rotate|spec|tune}; no socket/file/process/clock) and that it genuinely wires
  detect+tune+spec → `rotate.PlanInput`. Tests cover the fold, the end-to-end loop-closes-and-acts
  path, determinism, idle evaporation + verdict carry, and fail-closed construction. Daemon embedding
  and live-loop wiring follow (C5b). Additive: no wire/output change.
### Changed
- The Go module path is now `github.com/mycelium0/mycelium` (was `github.com/mindicator/mycelium`),
  aligning it with the repository home so `go get`/`go install` resolve and every import matches the
  canonical location. Mechanical rename across `go.mod`, all `internal/` + `cmd/` imports, the
  spine-build ldflags (`-X …spec.SourceRev`), and the purity-gate import allowlists; no behaviour
  change.

## [0.2.9] — 2026-06-19
### Added
- RP-0008 **P3-c (part 2 — the aggregate fold)**, completing the aggregate port: `internal/spec.RenderAggregate`
  + `myceliumctl aggregate --out F --bundle F [--name L] ...` — the Go port of the shell
  `myc_render_aggregate`: fold ≥2 per-node Bundles into ONE sing-box client profile (each endpoint a
  namespaced `<label>.<tag>` outbound via `outboundValue`, then ONE urltest "auto" + ONE selector
  "mycelium"/default "auto" + direct/block). Pure + LOCAL-only; fail-closed (ASCII labels, unique labels,
  scheme↔transport_class consistency, ShadowTLS refused, port range), byte-identical to the shell
  (`MarshalIndent` 2-space + `SetEscapeHTML(false)`; `URLTEST_*` defaults shared with `render_singbox`).
  Conformance gate `aggregate_render_go_equiv` folds two shell-rendered bundles through both producers and
  raw-byte-diffs the profile; the shell stays authoritative (no cutover). `TestRenderAggregate`/
  `TestRenderAggregateFailClosed` pin it. With P3-a/P3-b/P3-c-1 this brings bundle + aggregate fully into
  the Go spine (subscription + two-hop routing remain). Additive: no wire/output change.

## [0.2.8] — 2026-06-19
### Added
- RP-0008 **P3-c (part 1 — the link parser)**: `internal/spec.OutboundFromLink(tag, link)` +
  `myceliumctl link-outbound --tag T LINK` — the Go port of the shell `myc_agg_link_outbound`, the
  inverse of `ShareLink`: parse an opaque `vless://`/`hysteria2://`/`tuic://`/`ss://`/`trojan://`
  share-link into a sing-box client outbound. Pure string parsing (`uriDecode` is the inverse of
  `uriEncode`; query/authority split mirror the shell jq `before`/`after`); outbound shapes are typed
  structs whose field order + `omitempty` reproduce the shell jq construction byte-for-byte. A ShadowTLS
  ss-link and any unknown scheme fail closed to `null` (the inner-only material cannot rebuild the v3
  detour). Conformance gate `aggregate_outbound_go_equiv` generates links via the proven `share-link`
  (reserved char in every field) and asserts the shell + Go parsers agree byte-for-byte; the shell stays
  authoritative (no cutover). `TestUriDecodeRoundTrip`/`TestOutboundFromLinkGolden`/`TestShareLinkOutboundRoundTrip`
  pin it. P3-c part 2 (the profile fold — urltest/selector) follows. Additive: no wire/output change.

## [0.2.7] — 2026-06-19
### Added
- RP-0008 **P3-b**: `internal/spec.RenderBundle` + `myceliumctl bundle --params F --state F [--out F|-]` —
  the Go port of the shell bundle producer (`render_bundle.sh`). One Endpoint per enabled transport in
  registry/priority order, each via `spec.ShareLink`; resolution mirrors the shell exactly (params
  defaults via the `myc_params_get` `// empty` semantics, the per-identity password fallback to the
  shared secret, the C03 own-cert-tls_sni and C09 port-range fail-closed checks). Marshalled jq-style
  (2-space indent, `SetEscapeHTML(false)` so `&` in links stays literal, trailing newline). Conformance
  gate `bundle_render_go_equiv` renders the same params+identity through BOTH producers and asserts a
  raw byte diff (the `generated_at` instant text-normalized) — the strangler equivalence proof; the
  shell stays authoritative until green. `TestRenderBundleShape`/`TestRenderBundleFailClosed` pin it.
  Additive: no wire/output change.

## [0.2.6] — 2026-06-19
### Added
- RP-0008 **P3-a** (the renderer-porting phase begins): `internal/spec.ShareLink(proto, LinkParams)` +
  `uriEncode` — the Go port of the shell `myc_bundle_link` (the dialable client share-link / Bundle
  Endpoint Link). Pure + deterministic, byte-identical to the shell template across the 10 link-bearing
  transports; `uriEncode` matches `jq @uri` (RFC-3986 unreserved set, uppercase `%XX`, byte-wise).
  `myceliumctl share-link --proto P FILE|-` exposes it. Conformance gate `share_link_go_equiv` drives
  BOTH renderers with the same values (incl. reserved chars) and asserts identical output — the
  strangler equivalence proof; the shell renderer stays authoritative (no cutover) until it is green.
  Additive: no wire/output change. (`TestUriEncodeMatchesJqAtUri`, `TestShareLinkGolden`,
  `TestShareLinkEncodesReservedChars` pin it where Go is unavailable.)

## [0.2.5] — 2026-06-19
### Changed
- RP-0008 (Go-spine migration): the operator-override allowlist is now GO-OWNED. `internal/spec`
  gains `OperatorToggleKeys()` (every params-toggled proto's `*_enabled`/`*_port` key from the
  registry, plus the tunable knobs `xhttp_path`/`xhttp_path_tls`/`ws_path`/`grpc_service_name`/
  `region_bucket`), emitted into the `Vocab` (`myceliumctl vocab` / `control/vocab.json` →
  `.operator_toggle_keys`). `control/lib/nb_render_params.sh` reads the allowlist from `vocab.json`
  instead of a hardcoded bash array — the single source consumed by BOTH the override merge
  (`write_params`) and the auto-rotation executor (enable-key validation). Fail-closed: a real write
  refuses an empty/missing allowlist. `TestOperatorToggleKeysMatchesLegacy` pins the registry-derived
  set to the exact legacy 25-key list (lossless migration); `vocab_single_source` keeps Go ↔ `vocab.json`
  in lockstep. No wire/output change.

## [0.2.4] — 2026-06-19
### Added
- `myceliumctl rotate-record FILE|-` (RP-0012 C4c): folds an apply outcome into the rotation state via the
  pure `rotate.RecordOutcome` — on a rollback it spends the per-window rollback budget and latches the
  planner to hold for `CooldownAfterRollback` (no rollback thrash). Validates limits (fail-closed); clock
  from the system when `now` is zero. Pure read + compute.
- LIVE rotation in `control/lib/nb_rotate_apply.sh` + `scripts/node-bootstrap.sh --rotate --apply-rotation`
  (RP-0012 C4c), behind a TRIPLE GATE: dry-run is still the default; the live promote→verify→rollback path
  is reached only when `--apply-rotation` (`ROTATE_APPLY=1`) is set AND the node is ARMED (the node-local
  sentinel `$STATE_DIR/rotate-live.enabled`, placed via `--rotate-arm`, never committed — so an auto-pull
  can never actuate a node). The live path validates first against a temp params copy, then PERSISTS the
  rotation through the operator-overrides overlay (snapshot taken) so it survives `write_params`/`--update`,
  re-renders the authoritative config, and runs the existing `promote_config → apply_singbox →
  verify_post_apply` with `rollback_config` on failure. Every failure edge REVERTS the overlay (and records
  the rollback) so a rolled-back rotation cannot re-apply on the next tick — no persistent self-outage.
  `flow_rotate` is still reached only by the explicit `--rotate` dispatch (never `flow_bootstrap`/
  `flow_update`); the unattended timer is C4c-2 and ships disabled.
### Changed
- Gate `rotate_dry_run_default` → `rotate_apply_gated` (RP-0012 C4c): now enforces the full triple gate
  (dry-run default · `promote_config` confined to the live path · live reachable only under
  `ROTATE_APPLY` + `rotate_live_armed`, with `ROTATE_APPLY` defaulting to 0), the no-implicit-actuation
  rule (`flow_rotate` appears only in the `rotate)` dispatch), the overlay snapshot+revert (no persistent
  self-outage), and the no-auto-arm rule. `apply_rotation_to_params` / `persist_rotation_to_overlay` /
  `revert_rotation_overlay` / `record_rotation_rollback` / `rotate_apply_live` added to the
  `no_new_control_decisions_in_bash` denylist (control-logic stays in the sourced lib).

## [0.2.3] — 2026-06-18
### Added
- `myceliumctl rotate-plan FILE|-` (RP-0012 C4b): the shell-invocable boundary of the Plane-3 ADAPT
  decision — reads a node-local `rotate.PlanInput` JSON, runs the pure `rotate.Plan`, and emits the
  `RotationPlan` as JSON (the CLI fills `Now` from the system clock when the caller leaves it zero;
  the planner itself stays clock-free). No network, no mutation.
- `control/lib/nb_rotate_apply.sh` + `scripts/node-bootstrap.sh --rotate` (RP-0012 C4b): the DRY-RUN
  executor seam. `flow_rotate` reads a `RotationPlan` (default `$STATE_DIR/rotate_plan.json`, override
  `ROTATE_PLAN`); a HOLD plan is a no-op, an ACT plan applies its params delta to a TEMP params copy
  (`apply_rotation_to_params` enables the To-sibling's key, fail-closed against the closed
  `OPERATOR_TOGGLE_KEYS` allowlist), renders a candidate via the existing `render_candidate`, and runs
  the real `validate_config` (`sing-box check`) — then STOPS. It never calls `promote_config`: the
  persisted params, the operator-overrides overlay, and the live config are left byte-identical. The
  live promote/verify/rollback loop and the unattended timer are C4c, behind the RP-0012 §6 go/no-go.
- Gate `rotate_dry_run_default` (RP-0012 C4b): pins the dry-run boundary — `flow_rotate` never calls
  `promote_config`, reuses `render_candidate`/`validate_config`, the entrypoint wires the seam, and
  nothing auto-arms `--rotate` on a timer/cron. `apply_rotation_to_params` added to the
  `no_new_control_decisions_in_bash` denylist (control-logic stays in the sourced lib).

## [0.2.2] — 2026-06-18
### Added
- `internal/spec/rotate.go` + `internal/rotate` (RP-0012 C4a, executing the RP-0010 Plane-3 ADAPT
  decision): the auto-rotation PLANNER — the inert rotation schema (`RotationAction` / `RotationReason` / `RotationCandidate` /
  `RotationLimits` / `RotationState` / `RotationPlan`, all with pure `Validate`) and the pure,
  deterministic `Plan(PlanInput) -> RotationPlan` decision: clean → hold, then hysteresis
  (`FlipConfirmations`) → cooldown (`MinInterval`) → rate budget (`MaxPerWindow`) / rollback latch →
  pick the highest-weight tuner-promoted closed-set candidate that beats the incumbent by
  `MinWeightMargin`. `RecordOutcome` spends the rollback budget and latches to hold. The decision is
  node-LOCAL (no global/peer signal can reach it — AC-4) and stays WITHIN the closed transport set
  (no add-transport action; an out-of-registry proto fails `Validate` — AC-5); the clock is a
  parameter (deterministic). Gates: `rotator_pure_planner` (allowlist `{fmt, time, internal/spec}`,
  no clock/goroutine), `rotate_closed_set_only` (AC-5). INERT: nothing calls `Plan` in production yet
  (the executor seam + gated live loop are C4b/C4c).

## [0.2.1] — 2026-06-17
### Added
- `internal/tune` (RP-0010 C3): the self-tuner — the Physarum/Tero-2010 reinforce-and-evaporate
  control law expressed on `spec.DecayPolicy`, as a per-(transport-class, path) `Weight`. Each good
  connectivity `Verdict` reinforces the weight; it decays continuously by `HalfLife` toward
  `RetentionFloor`, so a blocked shape fades WITHOUT teardown and re-promotes automatically when the
  block lifts (`RetentionFloor` is scar memory — a repeatedly-blocked shape settles low but is never
  forgotten). A `Hysteresis` band damps the promote/demote flag. `NewWeight` is fail-closed; the
  weight is a ranking input only and NEVER actuates (ADR-0025 / AC-4). Gate `tuner_pure_advisory`
  enforces the package imports only `internal/spec` + pure stdlib (no net/os/syscall, no
  internal/reach|detect). Still inert: nothing consumes the ranking yet (auto-rotation is a later
  chunk).

## [0.2.0] — 2026-06-17
### Added
- **Phase 2 (adaptivity) opens — the connectivity-state detector, detect plane (RP-0010).** This
  release marks the two detect-plane chunks that landed under the Phase-1 version; the version line
  moves to the Phase-2 `0.2.x` track, and subsequent chunks bump the patch individually.
- `internal/spec/detector.go` (RP-0010 C1): the inert, node-local detector schema — the closed
  `ConnState` {clean/throttled/blocked/shutdown}; its lossy `AdvisoryHealth()` projection to the
  coarse advisory `HealthValue` (the OPSEC boundary — only the projection is emittable, k-floored,
  ADR-0030; impaired states collapse to one value); the closed `DetectReason` cause vocabulary; the
  `DetectorSignal` input and `Verdict` output; pure `Validate` throughout. Gate
  `detector_state_closed_vocab` keeps the vocab closed and enforces, by construction, that no
  transmitted artifact embeds the fine `ConnState`/`DetectReason`.
- `internal/detect` (RP-0010 C2): the connectivity-state classifier — `Classify`, a pure
  signature-priority function, plus a stateful `Detector` with a success-ratio hysteresis dead-zone
  (route-flap damping) and an anti-flap confirmation count. A held impaired state is never latched:
  once its boolean fault flag clears it is capped at aggregate degradation, so a recovered path
  climbs back out. `New` is fail-closed; decisions are deterministic and measured by a
  labelled-incident corpus (per-class precision/recall). Gate `detector_pure_no_probe` enforces the
  classifier adds no new probe surface (imports only `internal/spec` + pure stdlib; AC-6).
- `spec.ReasonDegradedWindow` for aggregate (non-point-signature) degradation.

### Note
- The detector is INERT in this release: nothing calls it in production yet (the `internal/reach`
  → signal wiring, the self-tuner, and auto-rotation are later RP-0010 chunks).

## [0.1.1] — 2026-06-17
### Added
- `internal/spec/transport.go`: Go-owned canonical transport registry (proto→class, default
  ports, params keys, scheme, engine) + closed transport/region/health vocabularies + `Vocab`
  aggregate. `myceliumctl vocab` emits it deterministically; committed `control/vocab.json` is the
  artifact the shell renderer reads (RP-0008 P2). The shell stops being a second source of truth
  for the transport taxonomy.
- `myceliumctl version` now appends the build-stamped source revision (`-ldflags -X
  spec.SourceRev`) when present, preserving the `myceliumctl <ver>` prefix.
- node-bootstrap `install_spine`: builds + installs the Go control binary
  (`$TOOLING_DIR/bin/myceliumctl-go`) from the deployed source on bootstrap and update — inert in
  this phase (the shell tool stays authoritative), warn-not-die, idempotent on the stamped source
  rev (RP-0008 P3 chunk 1).
- `ws-tls` transport class (VLESS+WebSocket over genuine single-layer TLS) is first-class and
  sing-box-servable (the on-device-proven Phase-1 genuine-TLS shape).
- Conformance gates: `vocab_single_source`, `spine_binary_build`, `no_reserved_jq_vars`.

### Fixed
- `merge_operator_overrides` / `seed_operator_overrides` named a jq variable `def` (a jq keyword);
  jq 1.6 fails to parse `$def`, so a jq-1.6 node's every `--update` died at the operator-override
  merge and rolled back. Renamed to `base`; added the `no_reserved_jq_vars` static gate.
- `sub_channel_not_single_point` sourced `render_bundle.sh` standalone after it began delegating to
  the shared vocab accessor; the gate now sources the same dependency chain.

### Changed
- The shell renderers consume the Go-owned vocabulary: `render_bundle.sh` (proto→class +
  closed-vocab list), `render_singbox.sh` (`MYC_SB_PROTOS` + per-proto default ports), via the new
  `control/lib/vocab.sh`; `OPERATOR_TOGGLE_KEYS` is gate-policed against the registry (RP-0008 P2).
- Terminology swept repo-wide to consistent network/population vocabulary.

### Notes
- During the 0.x alpha the SemVer minor digit tracks the lifecycle phase (0.1.x = Phase 1); patch
  increments per landed increment, with a git tag at phase close. Per-build identity is
  `internal/spec.SourceRev` (the git rev stamped into the binary).

## [0.1.0] — 2026-06-12
### Added
- Go module and the ADR-0012 layout: `internal/spec` (shared typed schemas), `cmd/myceliumctl`,
  `cmd/myceliumd`.
- `internal/spec`: typed `Identity` / `IdentityState` model with pure `Add` / `Revoke` /
  `Validate`, and an RFC 4122 v4 `NewUUID` from the OS CSPRNG (`crypto/rand`) — no custom
  cryptography (ADR-0002). Unit-tested.
- `internal/identity`: file-backed state store with atomic `0600` writes; a missing file yields
  a fresh empty state. Unit-tested.
- `cmd/myceliumctl`: `identity add|revoke|list` and `version`, at parity with the shell tool's
  identity surface. `reality-keys` / `render-server` / `subscription` report a parity gap and
  defer to the shell `control/myceliumctl` for now (RP-0002 W7).
- `cmd/myceliumd`: Phase 0 skeleton daemon — PII-safe `/healthz` + `/version`, loopback by
  default, graceful shutdown. No network-state detector or auto-rotation (Phase 2).
- `Makefile`: `build` / `test` / `race` / `vet` / `fmt-check` targets; `conformance` runs the
  shell suite.

### Notes
- First slice of RP-0002 W7 ("spine early, glue stays shell"). Build & verify with
  `go build ./... && go test -race ./...`; the offline shell conformance suite remains all green.
