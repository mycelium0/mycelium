<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0015: Fingerprint-adaptivity — make the client TLS fingerprint a first-class, operator-settable, eventually self-rotating parameter

## Metadata
- **ID:** RP-0015
- **Slug:** `fingerprint-adaptivity`
- **Status:** **DRAFT** (2026-07-20). Two increments, each independently landable behind its own gate: **A** (the knob — make the fingerprint a configurable closed-vocab parameter, additive, zero behaviour change until set) first, then **B** (the rotation — drive it from the measure→detect→adapt loop, the fingerprint-level analogue of RP-0012 transport rotation).
- **Phase:** Phase 2 — single-node adaptivity. This RP adds a new ADAPTIVE parameter to the client-facing render; it adds no new transport and no federation runtime.
- **Type:** multi-increment RP. Increment A is a render-consistency + closed-vocab change (no rotation, no new signal). Increment B consumes the RP-0014 path-level + L7 signals (no new signal of its own) and reuses the RP-0012 rotation discipline.
- **Related:** [RP-0014](0014-phase2-detector-hardening.md) (the detector hardening whose L7 + path-level signals are increment B's trigger — a fingerprint that is filtered reads client-DEAD to the node-local L7 probe that mimics it); [RP-0012](0012-phase2-auto-rotation-actuation.md) (the gated rotation discipline increment B reuses at the fingerprint level); [RP-0013](0013-phase3-e2e-client-recovery.md) (the ≥2-independent-families backstop that already recovers a filtered fingerprint at the TRANSPORT level — fingerprint-adaptivity is necessary-not-sufficient, this is the real safety net); [ADR-0014](../adr/0014-tls-security-invariants.md) (TLS invariants the fingerprint sits inside); the maintainers' internal research digest on resilient-connectivity prior art (the "a unique fingerprint is itself a tell" lesson that shapes the design — **concepts only**, MIT-licensed prior art).

## Rationale

The client REALITY (and genuine-TLS) uTLS **fingerprint is hardcoded `chrome`** at every site that renders or verifies it: the Go spine (`internal/spec/subscription.go`, `internal/spec/aggregate.go`, `internal/spec/render_server.go`), the shell renderers (`control/lib/render.sh`, `control/lib/render_singbox.sh`), the donor-verify ephemeral client that mimics the client so the on-node handshake stays representative (`control/lib/nb_donor.sh`), and the ShadowTLS L7 probe (`control/lib/nb_selftest.sh`). One value, in seven-plus places, with no single source and no way to change it without a code edit.

A single static fingerprint is exactly the kind of single-point fragility Phase-2 adaptivity exists to remove. In a live 2026-05 event, an upstream network began **filtering that specific client TLS fingerprint** (and, separately and partially, TCP-RAW). Every affected node's REALITY path degraded for clients using the filtered fingerprint. The network held — clients recovered onto the genuine-TLS `vless-ws-tls` sibling (own cert, borrows no fingerprint) via the client-native `urltest` auto-failover, validated end-to-end at ~20s. So the **transport-level recovery already carries the incident**; there was no outage, and v0.2.29 shipped as-is by design. But the underlying fragility remains: the node cannot change its fingerprint, cannot detect that its fingerprint (rather than its transport) is the thing being filtered, and cannot adapt within REALITY the way it adapts across transports.

RP-0015 closes that gap in two steps.

## Design principles (load-bearing)

1. **Never blind-randomize the ClientHello.** A per-connection random fingerprint produces a *unique* JA4 that is itself an entropy/ML tell — the opposite of blending in. The prior art is explicit (an upstream client that tried this had the change rejected for exactly this reason). The adaptive set is therefore a **closed vocabulary of REAL, CURRENT browser presets** (the uTLS shipped fingerprints), never a randomizer. `random`/`randomized` are deliberately EXCLUDED from the closed set.
2. **Keep the presets current.** A stale pinned preset (an old Chrome build no real browser still sends) is itself a tell. The vocabulary is a maintained set, floored to presets the current engine actually ships, and is expected to be refreshed as browsers move — a currency obligation, tracked like the engine-manifest currency floor.
3. **Switch CONSISTENTLY or not at all.** The fingerprint the client renders, the fingerprint the donor-verify client mimics, and the fingerprint the L7 probe uses MUST be the same value. If they drift, the node's L7 liveness signal stops reflecting what real clients send — the node would report a filtered fingerprint healthy (or vice-versa). Consistency across all render + verify + probe sites is a hard invariant (gate-enforced).
4. **Necessary, not sufficient.** The same 2026-05 event partially filtered TCP-RAW, which no fingerprint switch fixes (REALITY is TCP-RAW; a framed/genuine-TLS family is more robust to it). Fingerprint-adaptivity sharpens ONE axis; the ≥2-independent-transport-families invariant (RP-0013 C1) remains the real backstop and is unchanged by this RP.

## Increment A — the knob (closed-vocab, operator-settable, consistent)

**What.** Make the client fingerprint a single-sourced, closed-vocabulary, operator-settable parameter defaulting to `chrome`, threaded through every render + verify + probe site. Additive: with no operator override, every rendered artifact and every probe is byte-identical to today.

**How.**
- **Closed vocabulary in Go (the single source), emitted to `control/vocab.json`.** A `FingerprintRegistry` in `internal/spec` enumerates the closed set of real presets (`chrome` (default), `firefox`, `edge`, `safari`, `ios`, `android`) with `chrome` as the default; it is surfaced by `myceliumctl vocab` and mirrored into `control/vocab.json`, exactly like the transport/class/region vocab (RP-0008 P2). The `vocab_single_source` gate keeps the Go source and the committed file in sync. `random`/`randomized` are not members (principle 1).
- **A `client_fingerprint` parameter**, defaulting to `chrome`, validated against the closed vocab (an unknown value fails closed), added to the `operator_toggle_keys` allowlist so an operator may set it in `operator-overrides.json` — a fingerprint block becomes an operator config toggle, not a code change.
- **Threaded consistently** through the Go render (`subscription.go`, `aggregate.go`, `render_server.go`), the shell renders (`render.sh`, `render_singbox.sh`), the donor-verify client (`nb_donor.sh`), and the ShadowTLS L7 probe (`nb_selftest.sh`) — all reading the one parameter, all defaulting to `chrome`.

**DoD.**
- A new `fingerprint_single_source` conformance gate: the fingerprint has ONE source (the Go registry ↔ `vocab.json`), every render/verify/probe site resolves it from the parameter (no drifting hardcoded `chrome` literal outside the default), the default is `chrome`, and the vocab excludes `random`/`randomized`.
- Go tests: the closed-vocab validation (unknown value rejected), and a render round-trip proving the client render, the donor-verify client, and the L7 probe all carry the SAME fingerprint for a given parameter value.
- `bash tests/run.sh` green; the Go touch points build/vet/fmt/test/race green.
- Additive proof: with no override, the rendered subscription/aggregate/server artifacts and the probe configs are byte-identical to the pre-RP output.

## Increment B — the rotation (measure→detect→adapt at the fingerprint level)

**What.** When the node's own L7 probe reports the CURRENT fingerprint client-DEAD while a genuine-TLS sibling (which borrows no fingerprint) stays alive — the signature of a *fingerprint-specific* filter rather than a transport-wide one — rotate the `client_fingerprint` to the next closed-vocab preset, under the same rate/hysteresis/rollback discipline RP-0012 applies to transport rotation. This is the fingerprint-level analogue of transport rotation: a per-parameter closed-set move, node-local, advisory-then-gated, never a protocol-set growth.

**How (sketch — resolved to a concrete mechanism in a follow-on design pass, like RP-0014 chunk B).**
- The trigger already exists: the L7 probe mimics the client fingerprint (principle 3), so a filtered fingerprint reads DEAD at the probe → the RP-0014 detector plane. The discriminator "fingerprint-specific vs transport-wide" is that a genuine-TLS/ws-tls sibling (no borrowed fingerprint) stays alive while the REALITY family is DEAD.
- The move is a closed-vocab rotation of `client_fingerprint`, applied through the existing node render→validate→promote→verify→rollback path (no new apply mechanism), gated by the RP-0012 limits so a fingerprint cannot flap.
- **Boundary:** node-local + closed-set. A fingerprint rotation can only ever move WITHIN the closed preset vocabulary (never a random ClientHello — principle 1), and is decided only from the node's OWN L7/path verdicts (never a cross-node signal).

**DoD (increment B, later).**
- The measure/detect plane distinguishes a fingerprint-specific fault from a transport-wide one and drives a gated `client_fingerprint` rotation to a live preset; a scripted fingerprint-specific filter flips the node to a working preset within single-digit minutes, with the ≥2-family transport recovery unaffected.

## Out of scope (named)
- **A random/randomized ClientHello** — excluded by design (principle 1), not deferred.
- **Server-side (inbound) fingerprint shaping** — this RP is about the CLIENT fingerprint the node renders for its subscribers; the REALITY server's own handshake mimicry (the borrowed donor SNI/cert) is unchanged.
- **The TCP-RAW axis** — the genuine-TLS/framed families and the ≥2-family invariant (RP-0013) cover it; fingerprint switching does not (principle 4).
- **Cross-node fingerprint weather** — the advisory-emit + federation seams stay inert (out of scope for a single-node parameter).

## Acceptance (RP-level)
- Increment A lands with its gate + tests, byte-identical under no-override; increment B lands later with its own gate + a live drill. Every OPSEC invariant holds: neutral vocabulary in repo/commits, no location/identity leak, the closed-vocab + advisory-never-actuates discipline enforced by gates.
