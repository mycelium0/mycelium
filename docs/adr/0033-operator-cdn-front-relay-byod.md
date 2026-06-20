<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0033: Self-hosted operator CDN/ingress front — relay-preferred, bring-your-own-domain, opt-in

## Metadata
- **ID:** ADR-0033
- **Date:** 2026-06-19
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (implementation staged — inert schema + gate first, render/deploy a follow-on RP)
- **Layer(s):** ingress / topology (dataplane edge)
- **Phase:** Phase 2+ — binds the fronting option from Phase 2 onward; **not a phase gate**
- **Related:** **extends** [ADR-0029](0029-community-federated-ingress.md) (the federated "CDN layer" — community/operator ingress edges + their own domains, relay-preferred); [ADR-0027](0027-selective-growth-and-in-region-ingress.md) (in-region ingress / selective growth — the path that survives the destination-class throttle); [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md) (bridge-contract + the metadata trade-off a terminating edge makes explicitly); [ADR-0010](0010-phase0-transport-set.md) (transport #10 `vless-xhttp-tls` is "CDN-frontable"); [ADR-0032](0032-xray-automated-toggleable-engine.md) (the HTTP-framed engines a front sits in front of); [ADR-0025](0025-no-global-abuse-oracle.md) + [ADR-0030](0030-advisory-network-awareness.md) (no global oracle / advisory-never-a-map — the operator-graph-leakage frame); [THREAT-MODEL.md](../THREAT-MODEL.md) ("why out-of-region CDN fronting does not mitigate" the destination-class throttle). Prompted by an operator question — *"can we also think through a CDN option, operators bring their own domain?"*

## Context

ADR-0029 already names the ingress edge **"the CDN layer"** and makes it a **federated, community-/operator-contributed role**: many independent contributors provide ingress edges **and their own domains**; diversity across providers/domains/jurisdictions is the resilience goal; edges are **relay-preferred** (forward the encrypted tunnel; learn only that a client reached *an* edge, never the inner destination); a terminating edge is a deliberate fallback with a documented metadata trade-off (ADR-0026). The project deliberately owns **no** fronting domain — the positioning canon keeps core/operator from registering domains in hostile jurisdictions; operators bring their own.

So the operator's proposal — *"add a CDN option where the operator connects their own domain"* — is ADR-0029 made concrete as a **deploy-time option**, not a new direction. Two things make it worth pinning now:

1. **It composes with the work just landed.** A CDN/ingress front sits **in front of an HTTP-framed transport** — `vless-xhttp-tls` (Xray, ADR-0032) or `vless-ws-tls` (sing-box). REALITY **cannot** be fronted (a front that inspects/terminates TLS breaks REALITY's borrowed-donor handshake). So the frontable set is exactly the genuine-single-TLS own-cert HTTP transports.
2. **A hard finding must be honoured, not re-discovered.** [THREAT-MODEL.md](../THREAT-MODEL.md) already records that a naive **out-of-region CDN front does not mitigate the primary (destination-class throughput) threat and worsens metadata**: (a) the throttle is by destination *class*, and the CDN's own egress ranges are in that class, so swapping fronts "buys nothing"; (b) a **TLS-terminating** front sees the user's source address + destination hostnames and hands both to a third party — *"worse than neutral"* against a compelled-logging adversary. The path that survives the hard target is **topology** (in-region ingress + node-to-node egress — the operator-built two-hop), not fronting.

A front is therefore **complementary, not primary**: it adds reachability on the *many* networks that block by IP/SNI rather than destination-class throttle, and it hardens **control-plane** distribution (configs via fronts/anycast) — but it is a *last resort* for the hard target, where the two-hop remains the answer.

## Decision

**Add an OPTIONAL, opt-in, default-off, bring-your-own-domain CDN/ingress front, defined as a node-local descriptor, governed by ADR-0029's relay-preferred rule.**

1. **Opt-in, per-node, default-off.** A node fronts only if the operator enables it and supplies their own domain — reusing the per-protocol/per-node opt-in canon (ADR-0010). A node with no front enabled is byte-identical to today.
2. **Bring-your-own-domain.** The operator provides the fronting domain at install / first deploy; core registers none (positioning + ADR-0029). The domain + its CDN/edge are the operator's registration and legal surface.
3. **Frontable transports only.** A front may sit in front of **only** the genuine-single-TLS own-cert HTTP transports — `vless-xhttp-tls`, `vless-ws-tls`. REALITY/raw/UDP transports are refused fail-closed (a front would break or not apply to them).
4. **Relay-preferred; terminate is an explicit, acknowledged trade-off.** `mode: relay` is the default and the doctrine-clean shape (the edge forwards the encrypted tunnel; no TLS termination, no hostname/source exposure). `mode: terminate` is permitted **only** with an explicit acknowledgement flag, because it is the metadata leak THREAT-MODEL warns about (ADR-0026 trade-off) — never a silent default.
5. **Honest efficacy framing is part of the contract.** The descriptor and its docs state that fronting is **complementary / last-resort**, not a fix for the destination-class throttle (where the two-hop is primary). This keeps the option from being mistaken for the answer it is documented not to be.
6. **Schema before behaviour, gates-first.** Phase 1 (this ADR) ships an **inert** typed `FrontConfig` schema (`internal/spec`) + a conformance gate pinning its invariants (closed `mode` vocab, frontable-transport-only, relay-default, domain-required-when-enabled, terminate-needs-ack). Nothing consumes it yet. Phase 2 (a follow-on RP) renders the client endpoint at the front domain, wires the deploy-time domain/CDN setup, and field-tests reachability with a real operator domain.

## Consequences

**Positive**
- Operationalises ADR-0029's "CDN layer" as a concrete, opt-in deploy option without core owning a domain — diversity (each operator's domain/edge is distinct) becomes a per-node choice.
- Composes cleanly with the ADR-0032 HTTP-framed engines; adds reachability on IP/SNI-blocking networks and hardens control-plane distribution.
- Relay-default keeps the doctrine-clean metadata posture by construction; the terminate trade-off is explicit and logged in config, never silent.

**Negative / costs**
- Yet another opt-in surface to document and gate; mitigated by default-off + the inert-schema-first discipline.
- Risk of the option being **over-sold** as a primary reachability fix — countered by §5 (the efficacy framing is in the descriptor + docs) and by THREAT-MODEL remaining the source of truth.
- A terminating front, if an operator opts into it, is a real metadata trade-off — bounded by the explicit ack + ADR-0026.

## Failure modes & blast radius

- **Operator fronts a non-frontable transport (e.g. REALITY):** refused fail-closed by `FrontConfig.Validate` and the gate — never rendered/deployed.
- **Silent TLS termination (the metadata leak):** structurally impossible — `terminate` requires the explicit ack flag; default is `relay`.
- **Over-reliance on fronting against the hard target:** mitigated by the efficacy framing; the two-hop (ADR-0027) remains the documented primary, and fronting is labelled last-resort.
- **Inert-until-enabled:** the Phase-1 schema + gate consume nothing and deploy nothing — zero blast radius until the follow-on RP wires a render/deploy.

## Relationship to other records

- **Extends [ADR-0029](0029-community-federated-ingress.md):** the federated "CDN layer" gains a concrete self-hosted-operator, bring-your-own-domain, opt-in form, under the same relay-preferred rule.
- **Bounded by [THREAT-MODEL.md](../THREAT-MODEL.md):** fronting is complementary/last-resort; the destination-class throttle is answered by topology (in-region ingress + two-hop, [ADR-0027](0027-selective-growth-and-in-region-ingress.md)), not by a front.
- **Trade-off governed by [ADR-0026](0026-anastomosis-bridges-and-safe-defaults.md):** a terminating edge's metadata exposure is the explicit, acknowledged fallback.
- **Composes with [ADR-0032](0032-xray-automated-toggleable-engine.md) / [ADR-0010](0010-phase0-transport-set.md):** fronts the HTTP-framed genuine-TLS transports only.
- **Implementation:** staged — (P1, this change) inert `internal/spec.FrontConfig` + `front_relay_preferred` gate, default-off, consumed by nothing; (P2, follow-on RP) fronted client-endpoint render + deploy-time bring-your-own-domain wiring + an operator reachability field test.

### P2 implementation record

- **P2-1 (fronted-endpoint render):** `spec.FrontLinkParams` re-points a frontable transport's client endpoint at the front domain on 443 (SNI = the front domain; relay → the tunnel passes through to the node, own-cert pin unchanged). Fail-safe no-op for a disabled / non-matching / non-frontable front; mode-agnostic at the client.
- **P2-2 (edge config compiler):** `spec.RenderFrontProxy` (+ `myceliumctl front-render`) compiles a `FrontConfig` into the operator's edge nginx config — **relay** = an `ssl_preread` SNI-routed **TLS-passthrough** `stream` server (the edge terminates nothing, holds no key); **terminate** = an ack-gated TLS-terminating reverse proxy. Operator-supplied domain/host are config-injection-guarded.
- **P2-3 (bundle integration + deploy wiring):** `spec.RenderBundleFront` appends one fronted endpoint (distinct `-front` tag, last-resort priority) — purely additive, so a node without a front renders byte-identically (the `bundle_render_go_equiv` gate stays green). `control/lib/nb_front.sh` `front_setup` (run at the tail of `render_serve_bundle`, **default-off**) compiles the edge config + re-renders the served bundle with the fronted endpoint when a node-local `front.config.json` is enabled — read-only on the config, so the node never synthesises operator consent. Gate `front_deploy_inert` pins the default-off / no-auto-enable posture.
- **P2-4 (operator reachability field test):** OPERATOR-OWNED — requires a real bring-your-own domain + edge host (core registers none). Pending the operator. The dual-engine field test ([ADR-0032](0032-xray-automated-toggleable-engine.md) P2-5) gave the front a concrete primary use case: a **port-keyed** download throttle on a real mobile network (genuine-TLS on a non-443 port is throttled while the same node on 443 is not — [THREAT-MODEL.md](../THREAT-MODEL.md) "non-443 port throughput degradation"). This is precisely the discriminator the front's `relay` (SNI-passthrough on 443) rewrites — so against a port-keyed filter the front is a **primary** fix, not the complementary/last-resort role it (correctly) plays against the destination-class throttle.
