<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# RP-0016: Transport-delivery hardening — an engine-native client-handshake fragmentation knob

## Metadata
- **ID:** RP-0016
- **Slug:** `transport-delivery-hardening`
- **Status:** **DRAFT** (2026-07-22). One landable increment first — **A** (the knob: an operator-settable, closed-vocab client TLS-fragmentation parameter, engine-native, additive, zero behaviour change until set), threaded through the client renders exactly like the RP-0015 fingerprint parameter; **B** (adaptivity — enable/rotate fragmentation from a signal) is a deferred design-panel follow-on.
- **Phase:** Phase 2 — single-node adaptivity. Adds a new ADAPTIVE parameter to the client-facing render; no new transport, no new engine, no federation runtime.
- **Type:** a render-consistency + closed-vocab change that flips an ENGINE-NATIVE flag. It authors NO packet-manipulation code (principle 1).
- **Related:** [RP-0015](0015-fingerprint-adaptivity.md) (the sibling axis — RP-0015 hardens the *content* of the client ClientHello, this hardens its *delivery*; the two are orthogonal and compose); [RP-0013](0013-phase3-e2e-client-recovery.md) (the ≥2-independent-transport-families backstop — this is necessary-not-sufficient, that remains the real safety net); [ADR-0002 / ADR-0031](../adr/) (reuse proven transport, never reinvent crypto/transport — the reason this is engine-native, not a bespoke desync tool); [ADR-0014](../adr/0014-tls-security-invariants.md) (the TLS invariants the client handshake sits inside).

## Rationale

RP-0015 made the client TLS **fingerprint** (the *content* of the ClientHello) a single-sourced, closed-vocab, operator-settable, self-rotating parameter. But the fingerprint is only one of two axes an on-path element on the **client→node** path can key on. The other is **delivery**: an on-path filter can reassemble the client's TLS ClientHello from the wire and match its plaintext **SNI**, or reassemble enough of the handshake to compute a fingerprint — **even when that fingerprint is a real, current browser preset.** This is exactly the residual RP-0015 named and could not close: its same-listener A/B discriminator sees faults from the node's own vantage (preset-viability, node-egress), but it cannot positively observe a purely **client-access-vantage** on-path filter — the shape of the live 2026-05 event that partially affected raw-TLS-over-TCP. There, the ClientHello stays valid on the node's vantage; the interference sits on the client→node segment.

The standard delivery-layer hardening for that class is **handshake fragmentation**: split the ClientHello across multiple TCP segments (or multiple TLS records) so a trivial on-path reassembly of the SNI / a single-segment fingerprint match no longer lines up. It is a *delivery* change, not a *content* change, so it composes cleanly with RP-0015: the fingerprint decides what the handshake looks like; fragmentation decides how it is delivered. Neither is sufficient alone; together they harden both axes of the client→node handshake.

Crucially, this is **already a first-class, client-side, engine-native option** in the client engines Mycelium renders — so Mycelium adds a render knob, not a packet-manipulation engine.

## Design principles (load-bearing)

1. **Engine-native only — no bespoke packet manipulation.** The fragmentation is performed by the client engine's own, documented, client-side TLS-fragmentation feature. Mycelium authors **no** raw-socket / segment-crafting / kernel-interception (NFQUEUE/WinDivert) code. This is ADR-0002 / ADR-0031 verbatim: reuse the proven transport, never reinvent it. A `custom` / free-form desync value is **excluded from the vocabulary by design** — the closed set is only the engine's own modes.
2. **Off by default, additive.** With no operator override the rendered client artifacts are byte-identical to today. Fragmentation is opt-in.
3. **Switch CONSISTENTLY.** The value the served subscription renders and the value a share-link/aggregate carries (where the engine reads it) MUST agree — the same single-source discipline RP-0015 enforces for the fingerprint (gate-pinned).
4. **Necessary, not sufficient.** Fragmentation sharpens ONE axis of ONE path (the client→node TLS delivery). The ≥2-independent-transport-families invariant (RP-0013) and the framed/genuine-TLS families remain the real backstop; this does not replace them.
5. **Client→node only.** This is the CLIENT's outbound TLS handshake to the node. The node's own REALITY steal / donor handshake (the borrowed cover SNI/cert) is unchanged — server-side shaping is out of scope.

## Increment A — the knob (engine-native, closed-vocab, operator-settable, consistent)

**What.** Make client TLS-handshake fragmentation a single-sourced, closed-vocabulary, operator-settable parameter defaulting to **off**, threaded through every client render site, additive.

**Grounded mechanism (already resolved — engine-native).**
- **sing-box** (the primary client engine; the nodes pin **v1.13.13**, and the feature exists since **v1.12.0**) exposes two client-only outbound-TLS options in the SAME `tls` block where RP-0015 threads `utls.fingerprint`:
  - `record_fragment` (bool) — fragment the handshake into multiple TLS records (the engine docs recommend this first for performance);
  - `fragment` (bool) — fragment the handshake across TCP segments, with `fragment_fallback_delay` (default `500ms`).
- **A closed vocabulary in Go (the single source), emitted to `control/vocab.json`.** A `TlsFragmentModes` registry in `internal/spec` enumerates the closed set `off` (default) / `record` / `packet`, mapped to the engine flags (`off` → neither; `record` → `record_fragment: true`; `packet` → `fragment: true` + the fallback delay). `random` / `custom` / any free-form value is **not** a member (principle 1). `myceliumctl vocab` surfaces it; the `vocab_single_source` gate keeps Go ↔ the file in sync.
- **A `client_tls_fragment` parameter**, defaulting to `off`, validated against the closed vocab (unknown → fail-closed to `off`), added to the `operator_toggle_keys` allowlist — so a delivery-layer block becomes an operator config toggle (and, in increment B, an adaptive one), not a code change.
- **Threaded consistently** through the sing-box client render (`subscription.go` / `render_singbox.sh`) — the reality-tls + genuine-tls outbounds that carry `utls` gain the fragment flags when the mode is set. (The Xray-only `vless-xhttp-tls` family's fragment path — xray's freedom-outbound `fragment` — is scoped to a follow-up, like its L7 probe was; increment A covers the sing-box families where the option is a clean boolean in the same block already threaded.)

**DoD.**
- A `client_tls_fragment` closed-vocab parameter (`off` default), rejecting `random`/`custom`/unknown, added to `operator_toggle_keys`, single-sourced Go → `vocab.json`.
- Threaded through the sing-box client render (with the fingerprint-consistency gate extended, or a sibling `fragment_single_source` gate): every rendered site resolves it from the one parameter, no drifting literal.
- Go tests: closed-vocab rejection; a render round-trip proving `off` is byte-identical to pre-RP output and that `record`/`packet` set exactly the engine flags.
- An engine-currency floor: the pinned sing-box version is ≥ v1.12.0 (it is — v1.13.13), pinned in `engines.manifest.json`.
- `bash tests/run.sh` green; the Go touch points build/vet/fmt/test/race green; the `share_link_go_equiv` / `subscription_go_equiv` byte-equivalence gates stay green (byte-identical under no override).

## Increment B — adaptivity (deferred, design-panel-worthy)

**What (sketch).** Enable (or step through) fragmentation when a **delivery-layer** client→node filter is indicated. The hard part is the SIGNAL: a client-access-vantage filter is, by construction, the residual the RP-0015 node-vantage A/B cannot positively observe — so increment B likely needs either an operator trigger, a client-reported signal, or a distinct node-side heuristic, resolved in a follow-on design pass (like RP-0014 chunk B and RP-0015 increment B). It reuses the RP-0012 gated render→validate→promote→verify→rollback path and the RP-0015 render-threading; it is node-local, closed-set, advisory-then-gated, and ships disarmed. **Explicitly deferred** — increment A (the knob) stands alone and is useful as an operator toggle from day one.

## Out of scope (named)
- **Bespoke packet manipulation / raw-socket desync / kernel interception** — excluded by design (principle 1), not deferred. Mycelium flips an engine flag; it does not become a packet-manipulation tool.
- **A `random`/`custom` fragmentation value** — not a vocabulary member (principle 1).
- **Server-side / inbound shaping** — this RP is the CLIENT's outbound TLS to the node; the node's REALITY steal / donor handshake is unchanged.
- **The fingerprint axis** — RP-0015 owns the *content* of the ClientHello; this owns its *delivery*.
- **QUIC / h3 families** — fragmentation here is a TLS/TCP-handshake concept; the QUIC families have their own delivery characteristics and are out of scope.
- **The Xray `vless-xhttp-tls` family in increment A** — its fragment path is a follow-up (increment A is the clean sing-box boolean).

## Acceptance (RP-level)
Increment A lands with its gate + tests, byte-identical under no override, and a live check that a fragmented client→node handshake still connects to a node; increment B lands later behind its own gate + a signal design pass. Every OPSEC invariant holds: neutral vocabulary in repo/commits, no location/identity leak, the closed-vocab + engine-native (no bespoke desync) + advisory-never-actuates discipline enforced by gates.
