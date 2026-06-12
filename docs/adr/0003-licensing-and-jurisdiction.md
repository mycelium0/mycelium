<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0003: Software License and Development / Operator Jurisdiction

## Metadata
- **ID:** ADR-0003
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** **accepted** (2026-06-11)
- **Layer(s):** infra / cross-cutting (governance)
- **Phase:** cross-cutting; resolve before publication
- **Related:** [ADR-0001](0001-record-architecture-decisions.md),
  [../THREAT-MODEL.md](../THREAT-MODEL.md) "Law and opsec"
- **Spawns (downstream ADRs):** ADR-0004 no-logs/retention · ADR-0005 classification/disclosure
  as encryption item · ADR-0006 legal wrapper for exit infrastructure · ADR-0007 role/jurisdiction
  separation · ADR-0008 sanctions screening · ADR-0009 distribution channels
  (renumbered to the adr/ canon)

## Context

Two linked decisions with long-lasting consequences: (1) the **software license**, and
(2) the **jurisdiction** of development and operation. Key forces:

- Some jurisdictions restrict the distribution and promotion of this class of
  infrastructure, and separately impose cryptographic-means licensing regimes. Development and
  operator infrastructure **must** be situated outside any such jurisdiction.
- Mere-conduit / safe-harbour frameworks for relay-transit traffic are available in several
  favorable jurisdictions.
- Dual-use export-control regimes provide an exception for **published/public-domain** software
  — open-source publication satisfies this, which **favors OSS**.
- **To resolve:** copyright headers currently reference "the Mycelium license — see LICENSE
  (pending this ADR)" as a neutral placeholder. This ADR fixes the choice and the header wording.
- **Trust:** a persistent private network that cannot be audited is indistinguishable from a
  honeypot — auditability (OSS) is a security feature, not merely "openness".

## Options Considered

**License:**
1. **OSI-permissive (MIT/Apache-2.0)** — broad adoption, auditability/trust, satisfies the
   published-source export-control exception.
2. **Copyleft (AGPL-3.0)** — protects the openness of mesh-node forks; same export-control
   benefit.
3. **Source-available proprietary (as-is)** — operator control, but undermines trust/auditability
   for a persistent private network and loses the published-source position.

**Jurisdiction:** development + infrastructure must be outside any jurisdiction that restricts
this class of infrastructure or imposes cryptographic-means licensing on the software. Node hosting
should favor mere-conduit-friendly jurisdictions balancing cost, availability,
and AS cleanliness. Egress/exit nodes must not be operated under jurisdictions that are restrictive
toward this class of infrastructure.

## Decision

**ACCEPTED (2026-06-11).** Mycelium is licensed under the **GNU Affero General Public License
v3.0 or later (AGPL-3.0-or-later)** — copyleft. Rationale: Mycelium is an open, extensible platform
meant to be self-hosted and modified; AGPL closes the network-service ("SaaS") loophole, so anyone
who runs a modified node as a service must offer their changes under the same terms, keeping the
platform and its improvements a commons. Development and operator infrastructure are situated in
jurisdictions favorable to this class of infrastructure (see Options Considered); egress is not
operated under restrictive regimes. Downstream ADRs 0004–0009 follow. The repository `LICENSE` file
carries the full AGPL-3.0 text; all file headers carry the `AGPL-3.0-or-later` SPDX identifier.

## Consequences

- **Positive (with OSS):** trust/auditability, community contribution, clean dual-use position.
- **Negative / cost:** a license decision triggers a sweep of all copyright headers and the
  creation of a correct LICENSE; jurisdiction affects hosting cost and operational complexity.
- **User safety (#1):** OSS lets users verify the absence of a backdoor or telemetry — a direct
  contribution to trust.
- **Follow-on work:** LICENSE aligned with headers; ADR-0004…0009; a separate legal
  assessment before launching nodes in any new jurisdiction.

## Compliance

- LICENSE is present and **consistent** with copyright headers (after decision — sweep);
- downstream ADRs 0004–0009 are created;
- no nodes are operated under a jurisdiction that restricts this class of infrastructure or
  imposes cryptographic-means licensing on the software (operational checklist);
- a legal assessment is completed before launching in a new jurisdiction.
