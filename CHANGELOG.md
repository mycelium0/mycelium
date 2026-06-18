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
