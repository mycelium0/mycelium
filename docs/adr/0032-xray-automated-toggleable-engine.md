<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0032: Xray as an automated, per-protocol-toggleable engine (dual-engine nodes)

## Metadata
- **ID:** ADR-0032
- **Date:** 2026-06-19
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (implementation staged — prototype first, full rollout a follow-on RP)
- **Layer(s):** dataplane / engine strategy
- **Phase:** Phase 2+ — binds the engine model from Phase 2 onward; **not a phase gate**
- **Related:** **amends** [ADR-0010](0010-phase0-transport-set.md) (closed transport set + the "Xray retained as an optional alternative engine" clause + per-protocol toggling); [ADR-0028](0028-dependency-and-transport-currency-policy.md) (engine-asymmetry record + currency floors — Xray is already a pinned, floored dependency); [ADR-0031](0031-build-vs-reuse-compose-proven-patterns.md) (compose proven prior art — Xray/XHTTP is proven, not reinvented); [RP-0010](../proposals/0010-phase2-adaptivity.md) (Phase-2 adaptivity — the rotation/MEASURE plane gains failure-independent targets); [ADR-0025](0025-no-global-abuse-oracle.md) + [ADR-0030](0030-advisory-network-awareness.md) (the operator-graph-leakage framing the co-location question is judged against). Prompted by an operator question — *"is dual-engine coherent with our canons and vision?"* — answered yes, with conditions, below.

## Context

The node data plane runs a **single automated engine: sing-box** ([ADR-0010](0010-phase0-transport-set.md) "Engine decision": "sing-box is the primary engine"). ADR-0010 also decided to keep **"Xray-core retained as an optional alternative engine"** and listed transport #10 — `vless-xhttp-tls` (VLESS + XHTTP over genuine single-layer TLS, own certificate, non-REALITY, CDN-frontable) — as **"Served on the Xray path."** That promise is unfulfilled in the automation:

- `control/lib/render.sh` (the Xray engine, reached via `myceliumctl render-server --engine xray`) renders **VLESS+REALITY+Vision only** — it has no `vless-xhttp-tls` render path.
- `control/lib/render_singbox.sh` **fail-closes** `vless-xhttp-tls` ("the xhttp transport is Xray-core ONLY … served via the Xray engine in a future RP"). The `engine_load_check` conformance gate exists precisely because `sing-box check` rejects `transport.type: "xhttp"`.
- `node-bootstrap` installs and manages **only** sing-box (`install_singbox` + the unit + `sing-box check` validate-before-apply). There is **no `install_xray`, no Xray render path, no `xray run -test` validate, no Xray service management** in the toolchain.
- Consequently `vless-xhttp-tls` — the registry's one Xray-only proto and the strongest genuine-TLS shape (it presents the flow profile of an ordinary HTTPS client to a real origin, with no nested-handshake handle) — is **served nowhere** today. The one node running Xray (call it the Xray node) does so as a **hand-rolled** config off the auto-update path, and it currently serves VLESS+WS+TLS (a shape sing-box can also serve), not XHTTP.

Two forces make this gap worth closing now:

1. **Engine diversity is a stated resilience mechanism.** [ADR-0028](0028-dependency-and-transport-currency-policy.md) records that "engine diversity is the mechanism by which" hardening is kept available, and that an operator must "serve a hardening shape on the engine that actually carries it." Xray is already a **first-class, version-floored** dependency there. The asymmetry canon is about *which engine carries which shape* — not about isolating engines to separate nodes.
2. **The Phase-2 rotation/MEASURE plane wants failure-independent targets.** A sing-box-only node can only rotate among shapes that fail under the *same* network-filtering signatures. `vless-xhttp-tls` fails differently (HTTP-framed genuine TLS to a real origin), so making it available per node strengthens the self-healing loop ([RP-0010](../proposals/0010-phase2-adaptivity.md)).

The open question is **per-node co-location**: should both engines run on one node/IP? There is no doctrine prohibiting it (the single-engine status quo is *pragmatic* — the automation only built sing-box — not a deliberate anti-correlation rule). But an IP exposing both a REALITY-ish endpoint and an XHTTP-TLS origin is a marginally richer correlation target than a single-shape node, which touches the operator-graph-leakage concern ([ADR-0030](0030-advisory-network-awareness.md)).

## Decision

**Promote Xray from a retained-but-manual alternative to an automated, per-protocol-toggleable engine, peer to sing-box — so any node *can* serve Xray-only transports, and each node serves only what its per-protocol toggles enable.**

1. **Toggleable, not forced (per-node opt-in).** Xray runs on a node **iff** at least one Xray-engine proto is toggled on in that node's params — reusing ADR-0010's existing canon that "every protocol is individually toggleable." Default-off. A node with no Xray proto enabled installs/starts no Xray and is byte-identical to today. This folds the co-location question into the existing toggle model: co-location is an *operator choice per node*, never an imposed dual-stack.
2. **Respect engine asymmetry; do not duplicate shapes.** Each transport is served on the single engine the registry assigns it (`vocab.json .protos[].engine`). `vless-xhttp-tls` → Xray. REALITY/ws-tls/hysteria2/tuic/etc → sing-box. We do **not** add a second implementation of a shape sing-box already serves; Xray carries only the shapes that need it. The registry's `engine` field stays the single source of truth.
3. **Full fail-closed parity with the sing-box path.** The Xray path mirrors sing-box's safety envelope: render config from params/state (no invented secrets) → **`xray run -test` validate (fail-closed)** → backup → promote → verify → **auto-rollback** on failure; a pinned binary + SHA256 (`install_xray`, like `install_singbox`) honouring the [ADR-0028](0028-dependency-and-transport-currency-policy.md) currency floor; a custom systemd unit with `ExecStartPre` validate.
4. **Gates-first, inert-before-behaviour.** A conformance gate that proves a rendered Xray config **actually loads in `xray run -test`** lands *before* the render path is wired into any live apply — exactly how the sing-box `engine_load_check` gate came to exist after the xhttp/sing-box incompatibility slipped through template-structure-only checks. The genuine-TLS own-cert invariants already enforced for sing-box (C03: own SNI, never the donor/localhost fallback) apply identically on Xray.
5. **Normalise the Xray node.** Once the managed Xray path exists, the hand-rolled Xray node is brought onto it (rendered config + the auto-update timer), removing its snowflake status. Its data plane is migrated with the same validate-before-apply/rollback discipline (no flag-day).
6. **Co-location trade-off — recorded and decided.** Running both engines on one IP is *marginally* more fingerprintable than a single-shape node. We judge the **transport-diversity and adaptivity gain to outweigh it**, because: (a) it is opt-in per node (an operator who wants single-shape nodes keeps them), (b) both shapes are independently designed to look like legitimate services (REALITY borrows a real donor handshake; xhttp-tls is a real-cert HTTPS origin), so the correlation handle is weak, and (c) the leakage concern in [ADR-0030](0030-advisory-network-awareness.md) is about *telemetry mapping the operator graph*, which this does not touch. Operators who federate ([ADR-0029](0029-community-federated-ingress.md)) may still choose single-engine nodes to keep the bar low; that remains valid.

## Consequences

**Positive**
- The full closed transport set — including the Xray-only `vless-xhttp-tls` — becomes servable on **any** node, not just one hand-configured host. ADR-0010's transport #10 promise is finally automated.
- The rotation/MEASURE plane ([RP-0010](../proposals/0010-phase2-adaptivity.md)) gains a genuinely failure-independent target to fail over to; engine diversity becomes a *per-node* resilience property, not a *between-nodes* one.
- The Xray node stops being a manual snowflake off the update path; one platform, one update discipline.
- No new doctrine: this completes ADR-0010 + ADR-0028 rather than departing from them.

**Negative / costs**
- More standing per-node surface where Xray is enabled (a second engine binary, unit, render path, validate). Mitigated: opt-in + default-off + fail-closed parity.
- Dual-engine **port coordination** becomes load-bearing: sing-box and Xray inbounds must not collide. The closed port canon (`phase0_port_canon`) must cover both engines' ports.
- A slightly higher bar for federated operators who enable Xray; kept optional to preserve the low federation floor.
- A second engine to keep current under [ADR-0028](0028-dependency-and-transport-currency-policy.md) — but Xray is *already* a floored dependency, so this is bookkeeping, not new policy.

## Failure modes & blast radius

- **Port collision (dual-engine):** two engines binding the same port → one fails to start. Caught fail-closed by `xray run -test` / `sing-box check` at render-validate time and by an extended port-canon gate; never reaches a live swap.
- **Co-location correlation:** see Decision §6 — judged acceptable, opt-in, weak handle. Re-open if field evidence shows dual-engine IPs are distinguished as a class.
- **Xray currency drift:** an out-of-floor Xray pin → `dependency_policy` gate fails (Xray already has a floor). No new exposure.
- **Inert-until-toggled:** until a node enables an Xray proto, nothing changes — zero blast radius on existing nodes. The prototype (render + load gate) is inert by construction: no install, no service, no apply.

## Relationship to other records

- **Amends [ADR-0010](0010-phase0-transport-set.md):** the "Xray retained as an optional alternative engine" clause is upgraded from *manual* to *automated + per-protocol-toggleable*; the closed transport set and the per-protocol-toggle canon are unchanged.
- **Consumes [ADR-0028](0028-dependency-and-transport-currency-policy.md):** Xray inherits the currency floor + the engine-asymmetry record (which engine carries which shape).
- **Instance of [ADR-0031](0031-build-vs-reuse-compose-proven-patterns.md):** Xray/XHTTP is composed proven prior art, not reinvented network biology.
- **Feeds [RP-0010](../proposals/0010-phase2-adaptivity.md):** dual-engine nodes give the rotation plane failure-independent transports to adapt across.
- **Implementation:** staged — (P1) gates-first prototype: an Xray `vless-xhttp-tls` render path + a `xray_engine_load_check` gate proving the rendered config loads in `xray run -test` (inert, default-off, no deploy); (P2, follow-on RP) `install_xray` + the validate/promote/rollback service path + dual-engine port coordination + normalising the Xray node + a live drill.

### P2 implementation record

- **P2-1** `install_xray` — pinned, checksum-verified, gated on `node_needs_xray`, default-off/inert.
- **P2-2** `myceliumctl render-server --engine xray --proto vless-xhttp-tls` dispatch — the legacy REALITY+Vision path stays byte-identical; the `xray_engine_load_check` gate renders through the CLI. (Also fixed a render-vocabulary slip: the xhttp-tls renderer now reads the canonical `tls_key_path`.)
- **P2-3** the gated Xray serve spine — `render_xray_candidate → validate_xray_config (xray run -test) → promote_xray_config (known-good backup) → rollback_xray_config`; `install_xray_unit` (hardened unit kept in lockstep with the Ansible template + sing-box unit via `unit_netlink_parity`; `ExecStartPre xray run -test` = fail-closed start); `harden_ufw` opens the separate Xray-config ports (dual-engine port-canon); reached only under the `node_needs_xray` guard in `flow_bootstrap`. Gate `xray_serve_gated_inert` pins the inert/default-off + fail-closed properties.
- **Engine-delegation fix:** the sing-box renderer now *skips* (delegates) an enabled xray-only proto instead of fatally refusing the whole render — so a node that enables `vless-xhttp-tls` still boots its sing-box engine (which renders before the Xray engine comes up). `myc_vocab_protos_singbox` narrows the sing-box render/subscription set; the bundle keeps the full registry.
- **P2-4 / P2-5 — live migration on the Xray node (drill record).** The Xray node's hand-rolled engine was brought onto the managed platform **additively**: a managed `vless-xhttp-tls` inbound on the canonical port `2087`, rendered by `myceliumctl`, `xray run -test`-validated, promoted, and served by the hardened managed `xray.service` — **alongside the node's pre-existing, proven channel, which was never touched** (the live channel serves a *different* genuine-TLS shape on its own port; that shape is a sing-box-engine transport, so a managed replacement of it is a separate, deliberately-deferred step). The migration ran fail-closed under a snapshot + a single-arm teardown trap + a dead-man switch, with a hard guard rejecting any candidate that binds the live port, a cert-readability precondition for the unprivileged runtime user, and split enable/start. **Server-side verified:** `xray.service` active with `NRestarts=0` (clean single start), a genuine TLS handshake completes on the managed port, and the live channel stayed active + listening throughout. The on-device, real-network reach test of the managed `vless-xhttp-tls` endpoint is operator-owned (Phase-1-style acceptance). Retiring the hand-rolled channel onto the managed platform is a future step, gated on that field test.
- **P2-5 field-test outcome (real mobile network).** The managed `vless-xhttp-tls` **engine is sound** — the node completes genuine TLS, presents a valid CA-signed certificate, and is reachable from clean vantages (the field test also caught + fixed a real deploy gap: the unprivileged runtime user could not read the operator's CA-signed wildcard key, which the validate-as-root step masked; granting the runtime group read on the key fixed it). On a real high-interference mobile network, however, the endpoint on its canonical **non-443** port (2087) did not carry traffic while the **same node on 443 did** — a **port-keyed** download throttle, not a transport or engine defect, isolated by a same-node / same-transport / same-cert control on a second non-443 port (see [THREAT-MODEL.md](../THREAT-MODEL.md) "non-443 port throughput degradation"). Operating shape on such networks: the genuine-TLS family is reached on **443** — `ws-tls` on 443 is the field-validated working shape; `xhttp-tls` is reachable there only behind a 443 SNI-passthrough front ([ADR-0033](0033-operator-cdn-front-relay-byod.md)). The dual-engine xhttp-tls capability is therefore **proven as an engine**; its on-network reach on a port-filtering carrier is a fronting/topology question, not a transport one.
