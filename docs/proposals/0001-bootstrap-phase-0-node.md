<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Phase 0 Node Bootstrap (VLESS+REALITY + cover)

## Metadata
- **ID:** RP-0001
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** landed (deploy-ready scaffold on `main`; live deployment and DoD verification pending an operator-provided server)
- **Phase:** Phase 0 (see [../ROADMAP.md](../ROADMAP.md))
- **Related documents:** [ADR-0002](../adr/0002-no-custom-cryptography.md),
  [ADR-0010](../adr/0010-phase0-transport-set.md),
  [VIS-0001](../vision/0001-mycelium-vision-and-scope.md),
  [../ROADMAP.md](../ROADMAP.md) Phase 0

## 1. Title

Bring up the first working egress node on VLESS + XTLS-Vision + REALITY with a genuine cover
site and reproducible deployment.

## 2. Rationale

The project is greenfield — no nodes exist, no access exists. What is needed is a first working
node running the transports that **currently survive** the most restrictive network environments
(VLESS+REALITY demonstrates the highest reachability rates under documented large-scale DPI
deployments; preprint and research analysis is maintained internally).
Without Phase 0 there is no foundation for phases 1–5: the mesh is built on top of a working
ingress, not in its absence.

## 3. Scope

This proposal is **server-only**. The node serves standard protocol endpoints; the client
application and all client-side UX are explicitly out of scope (see
[VIS-0001](../vision/0001-mycelium-vision-and-scope.md) §4 and
[../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md)). Off-the-shelf
clients (sing-box, Clash-Meta, etc.) connect to the standard endpoints the node exposes.

- **Layers:** data plane · control plane (minimal) · infra
- **Components:** `vless_reality` adapter, cover site, identity issuance/revocation,
  observability, provisioning
- **Contracts:** standard server-side endpoint parameters (VLESS+REALITY connection string)
- **State/storage:** per-node UUIDs/keys, REALITY parameters, reserve IP pool
- **Flows:** node deployment from scratch · handshake lifecycle · key revocation · join-token
  issuance for operator use
- **Out of scope:** client profile QR codes, client-facing subscription UI, per-client failover
  as a client feature

### 3.1. Component Participation

| Component | Role in this RP | Status | External tech | Why not an existing tool |
|---|---|---|---|---|
| `vless_reality` | Terminates VLESS+XTLS-Vision+REALITY; target is a real donor site | active | Xray-core (≥v26.2.4) | not inventing transport/crypto ([../adr/0002-no-custom-cryptography.md](../adr/0002-no-custom-cryptography.md)) |
| `cover` | Legitimate response to active probing | active | Caddy/nginx + donor | standard web server; we do not write our own HTTP |
| `identity` | UUID issuance/revocation, REALITY key rotation | active | none (thin custom layer) | project business logic; does not violate layer boundaries |
| `observability` | Node health, handshake success rate, alerts | active | Prometheus/Alertmanager | standard; we do not write custom metric collection |
| `infra` | VPS provisioning + deployment from scratch | active | Terraform + Ansible | standard IaC; fast IP/AS migration |
| `control-agent` | Network interference detector / auto-rotation | deferred | — | activates in RP Phase 2 |
| `coordinator` | Fleet registry, rerouting | deferred | — | activates in Phase 3 |

## 3.2. Blast-Radius Cap

> Greenfield foundation: introduces **one** behavior layer (a single ingress) on a single server
> surface. Conceptually one step, though many files are new (from scratch).

- **Responsibility boundaries touched:** 1 (data plane appears)
- **Behavior layers touched:** 1 (ingress)
- **Client/subscription surfaces touched:** 0 (client is out of scope)
- **Files in diff (estimate):** ~30 (infra + configs, greenfield)

- [x] Within cap — a single-step foundational RP.

## 4. Current State

No nodes. No access. Documents (ROADMAP/ARCHITECTURE/THREAT-MODEL and process) exist;
no code exists.

## 5. Target State

One node answers VLESS+REALITY; the cover site holds active probing (returns a genuine donor);
the node deploys from scratch with a single command; a key is revoked without redeploying the
node. Effects:

- **Indistinguishability:** traffic = standard TLS to a donor site;
- **Survivability:** baseline (single IP/AS) — consciously extended in Phase 1;
- **Adaptation speed:** manual (automated in Phase 2);
- **Control plane network persistence:** join tokens and operator configs are distributed
  outside infrastructure reachable from heavily restricted networks.

## 6. Risks

- **Single IP/AS = single blocking point** — accepted for Phase 0, addressed in Phase 1–2;
  maintain a pool of fresh IPs across different ASes.
- **User safety (#1):** do not log user PII/IPs; telemetry is deferred and will be opt-in.
- **Indistinguishability:** correct donor SNI selection; cover site must withstand probing.
- **Rollback risk:** low — teardown/redeploy the node; no existing clients to break.

## 7. Acceptance Criteria

- [ ] Active probing of the server returns the genuine donor site (not a tell-tale response).
- [ ] The node deploys from scratch with a single command; an operator key is revoked without
  redeployment.
- [ ] Conformance green: `no_custom_crypto`, `cover_site_probe`.
- [ ] netsim probe `active_probe` confirms correct cover response.
- [ ] Off-the-shelf clients (sing-box / Clash-Meta) successfully connect using the standard
  endpoint parameters the node exposes.

## 8. Documentation Changes

- [ ] [../ROADMAP.md](../ROADMAP.md) — mark Phase 0 DoD fulfilled
- [ ] [../ARCHITECTURE.md](../ARCHITECTURE.md) — §data plane: record actual parameters
- [ ] [../runbooks/](../runbooks/) — runbook "deploy a node" and "IP/AS migration"
- [ ] [../adr/](../adr/) — ADR if donor/hosting/AS choice becomes canon

## 9. Migration Strategy

Greenfield → deployment: provision VPS → configure Xray + cover → issue join token for operator
use. No parallel coexistence (no existing nodes or clients). Rollout order: node → cover →
endpoint parameters.

## 10. Rollback / Fallback

Tear down the node; preserve the IP pool and keys; no existing clients, nothing to break. During
rollback — fail-closed (a client without a working config reports "no connectivity" rather than
leaking traffic unprotected).
