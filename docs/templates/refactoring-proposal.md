<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — `<short title>`

> **Document type.** Refactoring / Change Proposal template. Structure matches
> [../refactoring.md](../refactoring.md) (mandatory RP template). The finished
> proposal is saved as `docs/proposals/NNNN-<slug>.md`, slug in kebab-case;
> ID — `RP-NNNN` (zero-padded, monotonically increasing, separate sequence
> from ADR/Audit).
>
> **When an RP is required.** Any architecturally significant change: shifting
> layer boundaries, contracts between them, state/process ownership, the protocol
> matrix, the trust/discovery model, the auto-rotation loop, or the config
> distribution format. A change with no stated problem, no affected components,
> no success criteria, no understanding of contract impact, and no documentation
> update plan is **forbidden** ("cosmetic refactoring" does not pass the gate).
> Trivial edits go as ordinary type-prefixed commits without an RP.
>
> **Relationship to ADR.** An RP describes the *work* and migration; the
> decision "why this way" is recorded in an ADR. If the RP changes the canon it
> references an ADR (or creates one in §8). The commit implementing the RP carries
> `RP-NNNN ...` in its subject (see
> [../commit-template.txt](../commit-template.txt)).
>
> **See also:** [adr.md](adr.md), [audit.md](audit.md),
> [../development.md](../development.md), [../refactoring.md](../refactoring.md),
> [../ARCHITECTURE.md](../ARCHITECTURE.md), [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Metadata
- **ID:** RP-NNNN
- **Date:** YYYY-MM-DD
- **Author:** mindicator & silicon bags quartet
- **Status:** draft | review | approved | landed | implemented | rejected | superseded
- **Phase:** Phase 0–5 / cross-cutting track (see [../ROADMAP.md](../ROADMAP.md))
- **Related documents:** <ADR-NNNN / Audit-NNNN (F-NNN) / Vision / issue>

## 1. Title
<short one-line statement>

## 2. Reason
What problem the change solves and why it cannot be left as-is. Include
references to audit findings (`Audit-NNNN F-NNN`) if that is the source;
to a blocking incident; to detector signals. An RP not anchored to a problem
does not pass the gate.

## 3. Scope
- **Layers:** data plane | control plane | routing | discovery | infra
- **Components:** … (node agent, config distribution server, network interference detector,
  rotation loop, coordinator, telemetry, …)
- **Contracts:** … (config distribution format, transport config, block-signal /
  telemetry schema, control commands, capability)
- **Storage / state:** … (where current node state lives, "what lives where"
  policy, keys/identities, incident history)
- **Flows:** … (config delivery, auto-rotation on block, egress-route migration,
  node onboarding, bootstrap)
- **Schemas / formats:** …

### 3.1. Component participation table (mandatory)

Every RP **must** include a participation table. A component without a justified
role is a sign of over-claiming; remove, merge, or mark `deferred`.

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| `<name>` | <one sentence: what it does in this flow> | active / passive / deferred / test-only | <Xray / sing-box / AmneziaWG / libp2p / Caddy / CDN / Terraform / none> | <boundary argument: what owns the boundary and why no custom code should live here, or "—" if External tech = none> |

**Status:**
- `active` — performs runtime work in the proposed flow.
- `passive` — read-only participant (read, not mutated).
- `deferred` — mentioned because it activates in a future phase; intentionally
  inert in this RP (state future RP / phase in Role).
- `test-only` — participates only in conformance/netsim/smoke fixtures.

**External tech** is named whenever a non-custom stack component is used
(Xray-core / sing-box / AmneziaWG / libp2p / Caddy/nginx / Cloudflare /
Headscale / Terraform / Ansible / system shell / cloud API). The **Why not
existing tool** column must contain a boundary argument in the spirit of project
principle №1 ("do not reinvent cryptography and transport"): why this code must
not live in-house but stands on a proven standard.

## 3.2. Blast-radius cap
> One RP = one manageable step. Limit per RP phase:
> **no more than one** responsibility-boundary shift **OR** one layer-behaviour
> shift **OR** one config-distribution surface shift.

- **Responsibility boundaries affected:** N
- **Layers affected (behaviour):** N
- **Config-distribution surfaces affected:** N
- **Files in diff (estimate):** ~N

- [ ] Within cap — single-step RP.
- [ ] Exceeds cap → **split** into multiple RPs, **declare multi-phase**
  (list phases below), or **justify** as an emergency fix-forward (only when
  master is red — see [../refactoring.md](../refactoring.md) — Red master freeze:
  no new features or incidental cleanups, restoration of green only).

  Justification for exceeding / phase breakdown: …

## 4. Current state
What exists today and why it is problematic. Specifically: component names, contract
fields, routing/rotation rules, what the node currently knows about the user.
No vague generalisations.

## 5. Target state
How it should look after the change. Concrete interfaces, contracts, ownership.
How the change affects:
- **indistinguishability** (statistical similarity to legitimate HTTPS/QUIC);
- **survivability / path redundancy** (number of transports/ports/SNI/IPs/ASes);
- **adaptation speed** (time to recovery after a blocking event);
- **network persistence of the control plane** (management survives wherever data does).

## 6. Risks
- **Compatibility:** old clients/configs/nodes; whether a parallel contract
  release is needed (breaking schema change = major bump, N=2 parallel releases).
- **User security (requirement №1):** whether de-anonymisation, logging, PII in
  telemetry, or correlation is introduced; whether deniability/forward secrecy
  narrows. **A feature that improves convenience at the cost of de-anonymisation
  does not pass.**
- **Indistinguishability / probe surface:** whether traffic/banner/response to
  probing becomes more distinctive; whether the cover site withstands active probing.
- **Loss of observability/measurements:** which detector/rotation signals disappear.
- **Temporary degradation:** what slows or breaks during migration.
- **Flapping / false migrations:** whether the auto-rotation false-positive risk increases.
- **Rollback risk:** how reversible the change is.
- **Impact on decentralisation:** whether the change introduces hidden centralisation /
  an unpluggable coordinator dependency.

## 7. Acceptance Criteria
Verifiable success indicators (specific tests / netsim scenarios / metrics):
- [ ] …
- [ ] Conformance green (`no_custom_crypto`, `no_pii_in_telemetry`,
  `cover_site_probe`, … — name the specific tests).
- [ ] netsim/netem adversary scenario reproduces block → system behaves as
  specified (`rst_injection` / `as_blackhole` / `udp_drop` / `active_probe`).
- [ ] Survivability/recovery metric has not degraded (handshake success rate,
  time to recovery, TTFB).

## 8. Documentation changes
What must be updated (with file references):
- [ ] [../ARCHITECTURE.md](../ARCHITECTURE.md) — section …
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — if the attack surface or response changes
- [ ] [../ROADMAP.md](../ROADMAP.md) — if a phase DoD moves
- [ ] `docs/adr/NNNN-<slug>.md` — new/updated ADR
- [ ] contract/schema (config distribution format / telemetry signal schema)
- [ ] component README/CHANGELOG + version bump (version-hygiene: bump version →
  README header + CHANGELOG in the same commit)
- [ ] runbook (`docs/runbooks/...`), if an operational procedure changes

## 9. Migration Strategy
How to transition the system without disrupting operation:
- stages;
- parallel coexistence of old and new (especially contracts and nodes);
- the moment of final cutover;
- what happens to nodes running the old version during the transition;
- dependencies (rollout order: node → config distribution → clients).

## 10. Rollback / Fallback
What to do if the change fails:
- how to roll back (and in what time — this is a persistent private network;
  downtime means people without network access);
- which data/keys/IPs to preserve;
- which contract/config versions to keep running in parallel;
- fail-closed behaviour during rollback (no silent security bypasses).
