<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0016: `Software releases, not an operated network; community-consensus governance`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound decision: the
> repository publishes server-side software and does **not** operate a public network or have a
> single owner; governance moves to community/organization consensus. Saved as
> `docs/adr/0016-software-releases-not-an-operated-network.md`.
>
> **See also:** [0003-licensing-and-jurisdiction.md](0003-licensing-and-jurisdiction.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [0015-fleet-artifact-delivery-and-node-update.md](0015-fleet-artifact-delivery-and-node-update.md),
> [../../GOVERNANCE.md](../../GOVERNANCE.md), [../../ACCEPTABLE-USE.md](../../ACCEPTABLE-USE.md),
> [../../TRADEMARKS.md](../../TRADEMARKS.md), [../../README.md](../../README.md), [../../SECURITY.md](../../SECURITY.md).

---

## Metadata

- **ID:** ADR-0016
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** project governance, legal/positioning, discovery/membership (cross-cutting)
- **Phase:** cross-cutting; binds positioning from now; governance shifts to consensus in Phase 1-2
- **Related:** ADR-0003 (licensing/jurisdiction), ADR-0014 (per-operator credentials), ADR-0015
  (fleet delivery), GOVERNANCE.md, README separation statement

## Context

Mycelium is a **community** project, not one person's. The repository ships server-side software that
independent operators deploy on their own nodes. Casting the project — or its maintainer — as the
operator or owner of "the Mycelium network" would be both inaccurate and harmful: it manufactures a
single point of legal liability and coercion, implies a central operator the architecture explicitly
rejects (ADR-0014: no shared fleet key material; AGENTS.md §1.4: no permanent central brain), and
frames a community effort as personal property.

Earlier docs carried "official network" framing that implied an operated network with an owner. This
ADR records the corrected posture and the move to consensus governance.

## Decision

1. **Software, not an operated network (the separation statement).** Verbatim, carried in the README
   and referenced from SECURITY.md:
   - The repository publishes server-side software.
   - It does not operate a public network.
   - It does not publish public endpoints.
   - It does not distribute public client configs.
   - Each operator independently deploys and controls their own node.

2. **No single owner.** The name, marks, trust roots, and bootstrap seeds are a **community-owned
   shared identity**, not any individual's property. No person is the network's owner or operator;
   "holding the name" is not operating a network, and the project operates none.

3. **Governance by consensus.** From **Phase 1-2**, changes and shared-identity decisions (including
   network updates/merges) are approved by **community/organization consensus ("fungi voting")**,
   replacing single-maintainer approval. The pre-consensus **interim deliberately accepts updates
   UNSIGNED** (the fleet updater runs in its no-signature mode): there is intentionally no single legal
   signer yet, and write access to the canonical ref is the only gate (branch protection + a sole/known
   set of writers). This interim is a documented temporary state, not the end state.

4. **Enforcement.** The separation is guarded by a fail-closed conformance check that rejects
   affirmative "operates/owns a network" claims in the tree (allowing the negated separation
   statement), alongside the existing leak checks. The specific checks live in the conformance suite
   and `development.md`, not in this ADR.

## Consequences

- The project/maintainer is **not** a network operator: liability, mere-conduit, and sanctions posture
  are assessed **per operator** for their own node (ADR-0003), never centrally for "the network".
- GOVERNANCE.md, ACCEPTABLE-USE.md, TRADEMARKS.md, README.md, SECURITY.md are reframed from "official
  network" to a **shared-identity + consensus** model; the docs govern the shared name/marks/trust
  roots and contributions, not an operated network.
- The fleet updater (ADR-0015) stays in its **unsigned/insecure interim** until consensus signing
  lands; the safety of "a push reaches the fleet" rests on repo write-access control until then.
- A conformance check prevents owner/operate-a-network language from re-entering the public tree.

## Alternatives considered

- **A single-owner, centrally-operated network** — rejected: a single legal/coercion target, a central
  dependency the architecture rejects (ADR-0014), and a misframing of a community project.
- **Maintainer-signed updates now** — deferred: the maintainer declines to legally own update
  signatures before consensus exists. The unsigned interim plus repo write-access control bridges it
  until community-consensus signing (the spawned governance work) replaces single-owner approval.
