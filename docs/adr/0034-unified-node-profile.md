<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0034: Unified node profile — one node-local descriptor; capabilities and roles, not node variants

## Metadata
- **ID:** ADR-0034
- **Date:** 2026-06-20
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (implementation staged — inert descriptor schema + gate first; the CLI/installer that writes it is [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md))
- **Layer(s):** control plane (node provisioning / role assignment) · infra · cross-cutting track
- **Phase:** Phase 3 — **Operability & Release track** (living node: recovery, release, and the fungi/advisory INERT seam; the packaging/CLI deliverable, [ROADMAP](../ROADMAP.md) Phase-3 deliverable); **not a phase gate**. Under the operator-confirmed 2026-07-02 re-phasing, Phase 2 is narrowed to single-node adaptivity and the operability/release/packaging track (this unified node descriptor) lands in the new Phase 3 — a doctrinal re-phasing of the whole roadmap, not an ad-hoc mid-ladder half-step around one increment (the [ADR-0030](0030-advisory-network-awareness.md) no-bespoke-ladder-number precedent still holds)
- **Related:** [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) (the packaging + management CLI that consumes this descriptor — the work); [ADR-0018](0018-fungi-role-and-opt-in-publish.md) (**fungi is a reversible niche, not a permanent class** — the canon this descriptor must not violate); [ADR-0030](0030-advisory-network-awareness.md) (the sibling cross-cutting awareness increment — the inert weather-opt-in slot this descriptor reserves); [ADR-0032](0032-xray-automated-toggleable-engine.md) (Xray is an **additive** per-protocol engine, never a mutually-exclusive role); [ADR-0033](0033-operator-cdn-front-relay-byod.md) (the opt-in BYOD relay-preferred front this descriptor folds in); [ADR-0029](0029-community-federated-ingress.md) (the two-hop ingress this descriptor folds in); [ADR-0016](0016-software-releases-not-an-operated-network.md) (software, not an operated network — each operator controls their own node); [ADR-0014](0014-per-operator-node-credentials.md) (per-operator key material stays node-local); [ADR-0010](0010-phase0-transport-set.md) (the closed transport set + per-protocol toggle); [RP-0008](../proposals/0008-go-spine-distribution-rendering.md) (the Go spine + the Go-owned `control/vocab.json` single source). Prompted by an operator directive (2026-06-20) — *"unify what we have into one node form, including the CDN layer."*

## Context

A node's "kind" is decided **implicitly today, scattered across five independent selectors**, none of which is a single declared profile:

1. the transport `*_enabled` toggles in `params.json` / `operator-overrides.json` — which transports it serves;
2. `node_needs_xray` (computed over `control/vocab.json` × `params.json`) — whether the additive Xray engine installs alongside sing-box;
3. the **presence** of `STATE_DIR/two_hop.json` — whether it is a two-hop ingress ([ADR-0029](0029-community-federated-ingress.md));
4. the **presence** of `STATE_DIR/front.config.json` (enabled=true) — whether it carries a CDN/ingress front ([ADR-0033](0033-operator-cdn-front-relay-byod.md));
5. which background loops were separately enabled — the auto-pull update timer (installed out-of-band), `--rotate-enable-loop`, `--measure-enable`.

To stand up a node and shape it, an operator must today know the exact `params` key names, hand-place up to three different JSON overlays, and separately arm three timers. There is **no single node-local descriptor**, **no clean operator input for transport selection**, **no reachability posture** (a node is either fully public-served or, via the all-or-nothing `--no-harden`, possibly left with ports open — the opposite of private), and the CDN front is a hand-copied template file. Worse, the parallel Ansible provisioning path models the engine as a **mutually-exclusive role switch** (`engine: singbox | xray`) — the literal opposite of one node form, and inconsistent with the additive dual-engine decision ([ADR-0032](0032-xray-automated-toggleable-engine.md)).

[RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) needs a node that a release CLI can *deploy and manage* by a second operator in minutes; the operator's directive is to make every node **one form** that opts into transports, reachability, a CDN subdomain, ingress, and (later) the weather niche — capabilities, not separate node products.

**Adversary model.** This is a provisioning/control-plane decision, not a dataplane one; the adversary surface it touches is **operator coercion / config seizure** (the descriptor must not become a committed record of real node identity) and **network-map reconstruction** (the descriptor must not become a transmitted per-node profile). **Affected asset:** the network map and operator identity. **Fundamental trade-off touched:** operability/convenience ↔ keeping per-node differentiation node-local and never a shared artifact.

**Constraints that bound any answer.**
- **Fungi is a ROLE / reversible niche, not a node type** ([ADR-0018](0018-fungi-role-and-opt-in-publish.md), [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md)). A unification must not invent a node-type taxonomy.
- **Engines are additive** ([ADR-0032](0032-xray-automated-toggleable-engine.md)): enabling the Xray-only `vless-xhttp-tls` installs Xray *alongside* sing-box; it is never a mutually-exclusive engine role.
- **The front is opt-in, default-off, relay-preferred, BYOD** ([ADR-0033](0033-operator-cdn-front-relay-byod.md)); terminate is an ack-gated metadata trade-off.
- **`control/vocab.json` is the Go-owned single source** for proto→engine/enable-key/port-key ([RP-0008](../proposals/0008-go-spine-distribution-rendering.md) P2); a transport-selection input must **read** it, never restate the naming rule.
- **All per-node differentiation state is node-local and gitignored** and must stay so — the committed surface is example templates only ([ADR-0016](0016-software-releases-not-an-operated-network.md), [ADR-0014](0014-per-operator-node-credentials.md)).
- **The deploy path is fail-closed** (render → validate → promote → rollback) with a no-op short-circuit on a byte-identical candidate that protects live connections; any change must preserve both.

## Considered Options

0. **Leave the five scattered selectors as they are.**
   - Pros: no new schema; nothing to migrate.
   - Cons: the operator UX the directive asks for is unbuildable; the implicit-kind drift (three overlays + three timers + the Ansible role-switch) persists; transport selection stays a hand-edited 0600 JSON file.
   - Survivability: neutral on the wire, but operability stays poor → fewer correctly-configured independent nodes.

1. **A node-TYPE enum** (`type: entry | ingress | front | fungi | …`) selected at install.
   - Pros: reads simply ("pick a type").
   - Cons: reintroduces exactly the taxonomy [ADR-0018](0018-fungi-role-and-opt-in-publish.md) and [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) forbid (fungi is a niche, not a class); collides with additive engines ([ADR-0032](0032-xray-automated-toggleable-engine.md)) — a node can be "front" **and** serve direct transports **and** be an ingress at once, so a single enum cannot express it; a type enum tends to fork into divergent provisioning branches (the Ansible role-switch failure mode, generalised).
   - Survivability: worse — a rigid type set fragments the one-node-form goal.

2. **One node-local profile descriptor where every differentiator is a default-off CAPABILITY field, read by the existing seams.** *(Chosen.)*
   - Pros: one operator input; the four existing seams (`write_params`, `node_needs_xray`, `front_setup`, `assert_two_hop_shape`) each read one declared place instead of four conventions; CDN and ingress fold in as fields; reachability becomes a first-class posture; engines stay additive; transport names map through `vocab.json`; leaves a clean **inert** slot for the [ADR-0030](0030-advisory-network-awareness.md) weather opt-in; purely additive so a node that adopts no new field renders byte-identically.
   - Cons: a new descriptor schema + a one-time migration from the scattered selectors; the Ansible path must reconcile to the additive model or be retired.
   - Survivability: best — one converged, fail-closed provisioning path; no new wire surface (the descriptor never leaves the node).

3. **Keep the separate overlay files but add a CLI that stitches them.**
   - Pros: no schema change.
   - Cons: does not unify — it papers over four sources of truth with a fifth writer; the Ansible role-switch and the drift survive; the CLI must encode the cross-file invariants in bash, against the no-control-decisions-in-bash discipline.
   - Survivability: neutral; perpetuates the drift this ADR exists to remove.

## Decision

**Option 2.** Adopt **one node-local node profile** as the single declared description of what a node is, with every differentiator expressed as a **default-off capability field**, never a node-type enum.

Specifically, what becomes **canon**:

1. **One descriptor, node-local, never committed.** A single `STATE_DIR/node.config.json` (gitignored, `0600`) is the authoritative declaration the provisioning path reads. The **committed** surface is `control/node.config.example.json` only, using fail-closed placeholders (`node.example.invalid`, `front.your-own-domain.example`) and a loud "node-local, never commit" warning — exactly as `two_hop.json` / `front.config.json` are today. Real per-node values (node address, donor SNI, two-hop upstream, the operator's own front domain) live **only** here, never in the tree ([ADR-0016](0016-software-releases-not-an-operated-network.md), [ADR-0014](0014-per-operator-node-credentials.md)).

2. **Capabilities, not types.** The descriptor's fields are capability layers on **one** node form, each default-off / safe-default, illustrative shape:
   - `transports` — a friendly proto-name list (e.g. `vless-reality-vision`) that the renderer maps to the `params` `*_enabled` toggles **through `control/vocab.json`** (the Go-owned single source — never a restated naming rule); the default-on set is unchanged (`vless-reality-vision` + `vless-reality-grpc`).
   - `reachable` — the **posture** (see §3). Wire semantics: an **absent** `reachable` key renders **public** (`"::"`) so a node that has not adopted the field is **byte-identical to today** (the additive guard); set `reachable: false` **explicitly** to make the node a non-public participant, `true` to declare it a public entry. (The Go struct zero value is `false`, but that is a *construction* default for a profile built in Go — not the absent-key wire default; the CLI always serialises the field, so a CLI-produced descriptor is never ambiguous.)
   - `front` — folds today's `front.config.json` (enabled / domain / frontable transport / mode); **relay default, terminate ack-gated** ([ADR-0033](0033-operator-cdn-front-relay-byod.md)).
   - `ingress` — folds today's `two_hop.json` (the in-region ingress → elsewhere egress, [ADR-0029](0029-community-federated-ingress.md)).
   - `loops` — the three opt-in background planes (update / rotate / measure) declared in **one** place; arming still happens only through the existing node-local sentinels and never auto-arms (the [RP-0012](../proposals/0012-phase2-auto-rotation-actuation.md) triple-gate doctrine holds — a descriptor field may **request** a loop but never makes any autonomous actuation committable or default-on).
   - a **reserved, inert** `weather` slot for the [ADR-0030](0030-advisory-network-awareness.md)/[ADR-0018](0018-fungi-role-and-opt-in-publish.md) opt-in publish niche — **declared, not built here**; this ADR only guarantees the unified node leaves the slot so the awareness build-RP has a home without a node-model rewrite.

3. **Reachability is a posture on one node form, not a variant.** `reachable: false` means *provisioned and converged, but not a public entry*: public inbounds bind loopback (the existing ShadowTLS-detour pattern) **and** the firewall does not open their ports — privacy held at **both** the bind and firewall layers, fail-closed (never merely "skip opening" a port on a host with no prior firewall). It composes with `ingress`/`front` (a non-public node can still be an egress/relay participant) and preserves the sshd-anti-lockout ordering when the firewall is re-applied. The name for this posture is a **non-public participant** — never a "node variant"; the framing is a population of nodes joining one network (see [GLOSSARY](../GLOSSARY.md)).

   *Implementation staging (RP-0011 chunk D).* The mechanism is a single render-time `node_bind` param (default `"::"`, byte-identical to today; `apply_node_profile` stamps `"127.0.0.1"` only when the descriptor declares `reachable: false`), applied identically by the shell renderer and `internal/spec.RenderServer` (the `render_server_go_equiv` gate pins them byte-identical, including a `reachable=false` fixture). The **bind layer holds on every flow** (bootstrap / update / `--node-apply`) the instant the descriptor sets `reachable: false` — a loopback-bound inbound is unreachable off-host *regardless* of the firewall, so the posture is never fail-open. The **firewall layer** follows automatically: `harden_ufw`'s loopback exclusion is generalised to all inbound types, so a loopback-bound port is never opened — and since `harden_ufw` runs at bootstrap, the firewall layer converges then. A live `--node-apply` that flips reachability off rebinds to loopback immediately but does **not** re-run the firewall (`flow_node_apply` has no lockout surface by design); the firewall re-converges on the next bootstrap. So §3's "both layers" is held — **bind always, firewall on convergence** — and the **bind layer is the authoritative privacy control between bootstraps**, never fail-open. The opposite direction is an *availability* (not privacy) gap: a live `--node-apply` that flips reachability **on** rebinds public immediately but leaves ufw's ports **closed** until the next bootstrap, so the node is not actually reachable until then — `myceliumctl reachable on` warns that going public needs a full bootstrap. *Tracked follow-up:* a firewall-only reconverge for `--node-apply` (both directions) that preserves the sshd-allow-first ordering.

4. **Engines stay additive.** The descriptor never selects "the engine." `node_needs_xray` remains authoritative: a `transports` list that includes an Xray-only proto installs Xray **alongside** sing-box ([ADR-0032](0032-xray-automated-toggleable-engine.md)); the Xray-only `vless-xhttp-tls` is never routed onto sing-box. The CLI surfaces the second-engine install cost of selecting that transport.

   *Reachability scope (RP-0011 chunk D).* `node_bind` (§3) governs only the **sing-box ingress** — the canonical engine. The Xray engine renders to a **separate** config that the loopback rebind does not reach, so `apply_node_profile` **fails closed**: it **refuses** `reachable: false` while an Xray-only transport (any non-sing-box-engine `enable_key` from `control/vocab.json`) is enabled, rather than give a false sense of privacy. Lifting the refusal is a *tracked follow-up* in the dual-engine track — plumb `node_bind` into the Xray renderer (`myc_render_xray_xhttp_tls` + its template `listen`) and extend `harden_ufw`'s loopback exclusion to the `XRAY_CONFIG` ports. **AmneziaWG** carries no `params` enable-key and is a separate egress/relay UDP surface; its reachability is governed independently of `reachable` (documented here, not auto-suppressed).

5. **Additive and byte-identical.** Reading from the descriptor is purely additive: a node with **no** `node.config.json` (or one that adopts no new field) renders **byte-identically** to today — the conformance suite pins `write_params` byte-identity, and the deploy path keeps its fail-closed render → validate → promote → rollback spine and its no-op-on-identical short-circuit, so a descriptor rollout never drops a live session.

6. **The Ansible path reconciles to the additive model or retires.** The mutually-exclusive `engine` role-switch contradicts this decision and must not be carried into the one node form; reconciling it (a single composed profile that mirrors the additive install) or retiring it in favour of the [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) package installer is a tracked follow-on, and must keep the load-bearing parity gates (`unit_netlink_parity`, `phase0_port_canon`) green rather than silently dropping their declared sources.

## Consequences

- **Positive:** one operator input replaces four overlays + three out-of-band timer arms; transport selection, reachability, CDN-subdomain, and ingress become declared capability fields the [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) CLI writes and validates; CDN stops being a separate hand-placed deploy; the implicit-kind drift is removed; the [ADR-0030](0030-advisory-network-awareness.md) weather niche has a reserved home.
- **Negative / cost:** a new descriptor schema + a one-time, idempotent migration from the scattered selectors (the existing overlays remain readable during the transition); the Ansible path owes a reconciliation; one more node-local file to keep gitignored.
- **Impact on user security (requirement №1):** none added — the descriptor is node-local-only, never transmitted, introduces no logging or correlation, and carries no per-node row that could leave the node; relay-default and the ack-gated terminate trade-off are preserved by construction; the weather slot stays inert (no emission until the [ADR-0030](0030-advisory-network-awareness.md) build-RP, which keeps the class-aggregate / no-per-node-row invariants).
- **Impact on observability/measurements:** none — no detector/rotation signal is added or lost; the descriptor only declares which capabilities a node provisions.
- **Follow-on actions required:** [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) builds the inert descriptor schema + gate first, then the CLI verbs that write it, then the reachability posture path, then the diagnostics bundle and CI/release; the Ansible reconciliation; the [ADR-0030](0030-advisory-network-awareness.md) weather opt-in remains a separate build-RP that fills the reserved slot.
- **What is now forbidden:** a node-TYPE enum or any provisioning branch keyed on a "kind"; a committed `node.config.json` or any real node identity (address/host/domain/donor/key) in the tree; a `reachable` schema/descriptor default that is anything but off/safe-default (a fresh node must never auto-advertise), a default-on `front`, or a default-on weather emission; a descriptor field that makes any autonomous loop (rotate/measure/update) auto-arm or committable; routing the Xray-only `vless-xhttp-tls` onto sing-box; restating the proto→enable-key naming rule anywhere but `control/vocab.json`.

## Failure modes & blast radius

- **Descriptor absent:** the provisioning path runs the legacy default — a byte-identical stock node (fail-safe by construction; the suite pins it).
- **Descriptor malformed / a field out of the closed vocab:** fail-closed — the render → validate (`sing-box check` / `xray run -test`) → promote → rollback spine rejects the candidate and keeps the live config; `write_params` already dies on a non-object override or an empty allowlist.
- **A field that would open a port** is still gated by the `reachable` posture **and** the firewall lockout-safety (sshd-allow-first) — an unreachable node never ends with default-deny-and-no-sshd-allow, and a field can never open a port the posture says is closed.
- **Auto-pull cannot weaponise the descriptor:** it is gitignored and node-local, so a `main` push can never flip a node's reachability, arm a loop, or enable a front remotely (the sentinel/no-auto-arm doctrine, generalised).
- **Inert-until-built:** the Phase-of-this-change ships the descriptor schema + gate consuming nothing; zero blast radius until [RP-0011](../proposals/0011-phase2-fungi-packaging-and-cli.md) wires the seams behind the byte-identity gate.

## Compliance

How the decision is verified in practice (proof, not prose):

- **NEW gate `node_profile_single_source`** — asserts there is exactly **one** node profile descriptor and **no** resurrected node-type enum / no second divergent default-on transport set; that every posture (`reachable`, `front`, `loops`, `weather`) is **default-off / safe-default**; that the transport-name → enable-key mapping is read from `control/vocab.json`, never restated; and that no bootstrap path **writes** a `node.config.json` (operator-supplied, like the front config).
- **Existing gates stay green (regression-pinned):** `vocab_single_source` (the Go-owned registry is the only naming source); `per_protocol_toggle` / `phase0_port_canon` (default-on set + port canon unchanged); `front_relay_preferred` + `front_deploy_inert` (front relay-default, default-off, never self-enabled); `no_new_control_decisions_in_bash` (the descriptor's invariants live in the Go spine, not bash); the `write_params` byte-identity pins (a no-new-field node renders identically); `unit_netlink_parity` + `phase0_port_canon` for the Ansible reconciliation.
- **Wording / leak gates** (`check_ppn_wording`, `no_contact_leak`, `check_headers`, and the node-identity leak scan) police the descriptor example, the CLI help text, and this ADR for banned framing and any leaked address/host/domain/country signal.
