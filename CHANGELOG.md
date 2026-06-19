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
