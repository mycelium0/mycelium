<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0020: `Phase-0 scope reconciliations (delivery, cover, REALITY rotation, Terraform, D2 bar)`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: how five
> places where the Phase-0 implementation deviates from, or under-specifies, the literal
> [ROADMAP](../ROADMAP.md) Phase-0 text are reconciled — so the Phase-0→Phase-1 gate is decided
> against an unambiguous bar, not contradictory wording. It changes no transport behaviour; it pins
> meanings and scope.

---

## Metadata
- **ID:** ADR-0020
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** cross-cutting (doctrine / Phase-0 acceptance)
- **Phase:** Phase 0 (the acceptance bar; see [../ROADMAP.md](../ROADMAP.md))
- **Related:** [../ROADMAP.md](../ROADMAP.md) (Phase-0 scope/DoD, lines 65-74, 82-91);
  [ADR-0010](0010-phase0-transport-set.md) (transport set + families);
  [ADR-0014](0014-per-operator-node-credentials.md) (per-operator creds; self-signed-cert pinning);
  [ADR-0016](0016-software-releases-not-an-operated-network.md) (software, not an operated network — why no public config endpoint);
  [RP-0002](../proposals/0002-phase0-live-verified-hardened-node.md) (the Phase-0 single-node RP);
  [../runbooks/reality-rotation.md](../runbooks/reality-rotation.md) (the manual rotation procedure this ADR mandates);
  [../THREAT-MODEL.md](../THREAT-MODEL.md) (a public config endpoint is itself a scan/fingerprint surface).

## Context
A Phase-0 completion audit (repo + the three live nodes + RP-0002) found that **only D5 is fully
met**; D1-D4 and several scope items are "partial." Crucially, a subset of the "partial" verdicts are
not engineering gaps at all — they are **wording conflicts** between the literal ROADMAP Phase-0 text
and the deliberately-chosen implementation. Left unreconciled, each would block the phase-transition
decision ("do not begin Phase 1 until Phase 0 DoD is met in production") on an ambiguity rather than a
real deficiency, or — worse — invite someone to "fix" a deviation that is actually the correct choice.

- **Affected asset.** Ingress reachability and the **network map / fingerprint surface** — two of the
  reconciliations (config delivery, cover site) trade a literal convenience for a smaller attack surface.
- **Forces.** The ROADMAP is doctrine and must not be silently overridden; but where the implementation
  knowingly diverges for a security reason, or where the ROADMAP contradicts a later project decision,
  the divergence must be *recorded and decided*, not left implicit.

The five items: (1) D1/"config distribution endpoint: a single URL/file" vs. the chosen out-of-band
delivery; (2) "a genuine cover site on Caddy/nginx" vs. REALITY's external-donor forwarding; (3)
"rotation of REALITY parameters" listed in Phase-0 vs. the project's deferral of *automated* rotation
to Phase 2; (4) the Terraform deploy path named alongside script/Ansible; (5) the meaning of "two
independent transport shapes" (D2) — sub-shapes of one family, or distinct families.

## Considered Options
1. **Silently keep diverging** (option 0). — Pro: no work. Con: the phase gate is decided on
   contradictory text; a future contributor may "restore" a public endpoint or a Caddy cover site,
   re-expanding the attack surface; the D2 bar stays ambiguous. Rejected.
2. **Rewrite the ROADMAP Phase-0 section to match the implementation.** — Pro: single source. Con: the
   ROADMAP is intentionally aspirational doctrine; rewriting requirements out of it loses the "why we
   deviated" record and blurs ADR (decision) vs ROADMAP (direction). Rejected as the primary vehicle.
3. **Record one ADR pinning each reconciliation, and annotate the ROADMAP to point at it (chosen).** —
   Pro: the decision and its rationale live in an ADR (the right place); the ROADMAP keeps its
   direction and gains a pointer; the phase gate has an unambiguous bar. Con: one more document.

## Decision
**Option 3.** The following five reconciliations are **canon** for Phase-0 acceptance. The ROADMAP
Phase-0 lines are annotated to reference this ADR; their intent is preserved, their Phase-0 bar is made
precise here.

1. **Config delivery is local-generation + out-of-band hand-off (not a public endpoint).** Phase-0
   "the user retrieves the config endpoint" (D1) is satisfied by the operator generating a per-user
   bundle locally (`myceliumctl subscription`, delivery model B) and handing it over a side channel.
   **No public, always-on config URL is stood up in Phase 0** — a public config endpoint is itself a
   scan/fingerprint surface and an availability target ([../THREAT-MODEL.md](../THREAT-MODEL.md)), and a
   *matured* distribution endpoint is explicitly Phase-1 ROADMAP scope. The bundle MUST be valid for
   stock sing-box / Clash-Meta and carry the enabled transports with a urltest/selector for client-side
   failover.
2. **The genuine cover under active probing is the external REALITY donor; a self-hosted Caddy/nginx
   cover site is OPTIONAL.** For a node exposing only REALITY (and/or ShadowTLS) shapes, an
   unauthenticated probe is relayed to the real donor and receives a genuine response — this satisfies
   D3. A local Caddy/nginx cover site is defense-in-depth, **not required** when only REALITY shapes are
   exposed. **Conditional:** if a TLS-terminating non-REALITY shape with a *self-signed* certificate
   (HY2/TUIC/Trojan per [ADR-0014](0014-per-operator-node-credentials.md)) is ever exposed on a node, D3
   MUST be re-vetted for that node (a probe would then hit a self-signed handshake, not a donor).
3. **REALITY-parameter rotation is a MANUAL Phase-0 operator procedure, distinct from the self-update.**
   The ROADMAP line listing rotation under Phase-0 key/identity management is satisfied by a documented
   manual runbook ([../runbooks/reality-rotation.md](../runbooks/reality-rotation.md)) that an operator
   runs on intent. Rotation **deliberately changes client links** and is therefore explicitly NOT part
   of the link-stable no-op self-update. **Automated / block-triggered rotation remains Phase 2**
   (the adaptation layer).
4. **Phase-0 reproducible-deploy is satisfied by `node-bootstrap.sh` + the Ansible path; Terraform is
   deferred/optional.** The "one script / Ansible / Terraform" line is met for Phase-0 by the
   single-command `node-bootstrap.sh` and the Ansible playbook. The Terraform path under
   `infra/terraform/` is **not a gating Phase-0 deploy path**; it is deferred/optional until separately
   validated from zero. A named path is thus accounted for rather than silently unassessed.
5. **"Two independent transport shapes" (D2) means two independent transport FAMILIES.** Per
   [ADR-0010](0010-phase0-transport-set.md), the REALITY/TLS-over-TCP shapes (Vision, gRPC, XHTTP) are
   ONE family regardless of protocol framing; AmneziaWG-over-UDP, Shadowsocks-2022-over-TCP, and the
   QUIC shapes (HY2/TUIC) are each a **distinct** family. D2 requires **≥2 independent families
   reachable at once on every node**. The **canonical Phase-0 second family is AmneziaWG (UDP) on every
   node** (the proven obfuscated-UDP fallback). A static conformance check MAY enforce the family count;
   it must only inspect configuration, never auto-select or rotate a family (that is Phase-2 actuation).

## Consequences
- **Positive:** the Phase-0→Phase-1 gate is decided against an unambiguous, recorded bar; the smaller
  attack surface (no public endpoint, donor-as-cover) is protected from well-meaning "restoration"; the
  D2 family bar is enforceable; the rotation contradiction is resolved with a concrete runbook.
- **Negative / cost:** one ADR plus a ROADMAP annotation to maintain; the manual rotation runbook is an
  operator burden until Phase-2 automates it.
- **Impact on user security (requirement №1):** strictly positive — declining a public config endpoint
  and not standing up an unnecessary cover service both *reduce* exposed surface; nothing here logs or
  correlates users.
- **Impact on observability/measurements:** none directly. (The separate, larger observability gap —
  deploying node-local liveness/utilisation/alerts — is tracked outside this ADR.)
- **Follow-on actions required:** annotate ROADMAP Phase-0 lines with `(see ADR-0020)`; add
  [../runbooks/reality-rotation.md](../runbooks/reality-rotation.md); bring AmneziaWG live on the one
  node still missing it so D2 holds fleet-wide; add the static D2 family check; record the Terraform
  decision wherever the deploy paths are listed.
- **What is now forbidden in Phase 0:** standing up a public always-on config-distribution endpoint;
  treating Vision+gRPC alone as "two independent shapes"; shipping automated/triggered REALITY rotation;
  exposing a self-signed-cert TLS shape without re-vetting D3 for that node.

## Compliance
- A static D2 family-count check (config inspection only, no actuation) asserts ≥2 independent families
  per node; the existing `per_protocol_toggle` / `no_legacy_transport` / `phase0_port_canon` gates remain
  green.
- The Phase-0 acceptance ledger records: the out-of-band D1 hand-off proof; the `cover_site_probe`
  PASS per node (with the REALITY-only conditional noted); the manual-rotation runbook existing and
  exercised at least once; and the explicit Terraform deferral.
- Code review rejects any reintroduction of a public config endpoint or a required cover service in
  Phase-0, and any automated REALITY rotation before Phase 2.
