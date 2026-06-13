<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Phase-0 GO/NO-GO acceptance ledger

The single artifact that authorizes the **Phase-0 → Phase-1 transition**. Per
[ROADMAP.md](ROADMAP.md) ("Phase-transition principle"), **Phase 1 does not begin until Phase-0's
Definition of Done is met in production with real users** — not when the code merely exists. This
ledger maps every Phase-0 DoD and scope item to its status, evidence, and owner; the scope
reconciliations it relies on are pinned in [adr/0020-phase0-scope-reconciliations.md](adr/0020-phase0-scope-reconciliations.md).

> **Current verdict: NO-GO** — for the right reason. The engineering / conformance plane is **complete
> and live** on the three-node fleet (D5 done; D2 wired to ≥2 independent families and live on every node;
> 14 offline gates green; the Go spine builds/tests/`-race` green; decentralized node-side observability
> deployed loopback-only; out-of-band D1 delivery correct — only the REALITY *public* key + client UUIDs
> reach clients). What gates the flip is a small, bounded set of **operator-owned production proofs** plus
> the autonomous closures listed below — not a code deficiency. (Node identifiers are abstracted as
> node-A/B/C; no IPs/hostnames/donor-mappings appear here, per the project OPSEC rule.)

## DoD scorecard

| # | Criterion (DoD / scope) | Status | Evidence / proof | Owner of remainder |
|---|---|---|---|---|
| **D1** | Restrictive-network user retrieves config → reaches the internet (out-of-band hand-off, ADR-0020 §1) | **partial** | Bundle generation + urltest/selector failover built (`control/lib/render_singbox.sh`); only the REALITY public key + UUIDs reach clients (`control/selftest.sh` asserts no private-key leak). **Missing:** a recorded real-user proof. | operator |
| **D2** | ≥2 independent transport **families** reachable at once on every node (ADR-0020 §5) | **partial** | REALITY/TLS-TCP + AmneziaWG/UDP wired end-to-end + **live on all 3 nodes**; `transport_family_independence.sh` gate PASS. **Missing:** a client-device tunnel-and-reach proof (the data-plane half). | operator |
| **D3** | Active probing → genuine donor response (REALITY donor is the cover; ADR-0020 §2) | **DONE** | **`cover_site_probe.sh` PASS recorded 2026-06-13 for node-A/B/C:** each answers an active probe as its pinned donor — certificate identity matches the donor, HTTP 200, no tunnel tell ("indistinguishable from ordinary HTTPS"). Conditional closed: the fleet is REALITY-only; HY2/TUIC/Trojan/ShadowTLS default-off (`group_vars/all.yml.example`, `per_protocol_toggle` gate), so no self-signed handshake is exposed. | — |
| **D4** | One-command deploy + revoke-without-reinstall + reproducible deploy | **partial** | One-command bootstrap (`scripts/node-bootstrap.sh`) proven on 3 nodes (AF_NETLINK fix at HEAD); Terraform deferred (ADR-0020 §4). **Revoke (corrected):** `myceliumctl identity revoke` removes the client from `identities.json`, but a **re-render + engine reload** is required to take effect (UUIDs are baked into the inbound users) — only a node *reinstall* is avoided. **Missing:** an atomic on-node revoke wrapper (autonomous); Ansible-from-zero re-validation on a fresh VPS (operator). | autonomous + operator |
| **D5** | No excluded legacy transport configured anywhere | **DONE** | `no_legacy_transport.sh` gate PASS at HEAD. | — |
| S | Basic observability (node liveness / utilisation **done**; per-transport handshake-success + alerts **deferred** per ADR-0021) | **partial** | Node-side producers live on all 3, loopback-only: `node_exporter`, the `dataplane-stats` utilisation exporter (PII-safe, `no_dataplane_pii` gate), the reachability monitor, + the `mycelium_dataplane_unit_active` metric. **Deferred (named, ADR-0021):** alerting + per-transport handshake-success-rate → the per-operator monitor / Phase-2 edge reporting; **no central collector in any phase.** | deferred (not a Phase-0 blocker) |
| S | Reproducible deploy (`node-bootstrap.sh` + Ansible; Terraform deferred, ADR-0020 §4) | **DONE** | Canonical idempotent fail-closed bootstrap; ROADMAP annotated `(see ADR-0020)`. (Ansible-from-zero re-validation tracked under D4.) | — |
| S | Hosting / AS-diversity (no single tainted AS) | **partial** | Operationally met (3 nodes, 3 countries). **Missing:** an auditable AS-diversity inventory (autonomous; no raw IPs). | autonomous |
| S | ADR-0020 reconciliations recorded + ROADMAP annotated | **DONE** | ADR-0020 accepted; ROADMAP cross-refs present. | — |
| S | Manual REALITY-rotation runbook **exercised at least once** (ADR-0020 §Compliance) | **remaining** | Runbook exists (`runbooks/reality-rotation.md`); the *exercised-once* transcript is unrecorded. | operator |
| — | This GO/NO-GO ledger exists (r18) | **DONE** | this document. | — |

## Remaining autonomous closures (no node / no operator needed)
These I can land immediately; they harden Phase-0 and complete the self-contained surface:
- **Atomic on-node revoke wrapper** — `myceliumctl identity revoke → re-render → `sing-box check` → promote → engine reload → verify, with rollback (fail-closed, mirroring the updater).
- **`harden_journald` fail-closed** — verify the volatile drop-in and fail (not warn) on a bad config.
- **AS-diversity inventory doc** — region / AS class / IP-reputation posture / deploy-date / rationale, keyed by node-A/B/C (no raw IPs).
- **Bootstrap subscription emission** — `node-bootstrap.sh` emits per-client subscriptions to a gitignored hand-off dir at the end of bootstrap (the Ansible path already does), so the one-command path is self-complete for the D1 hand-off.
- **ROADMAP line annotation** — point the observability DoD line at ADR-0021 (the deferral of alerting / per-transport handshake to the per-operator monitor / Phase-2), mirroring the ADR-0020 cross-refs.

## Remaining node-side proof (controlled, read-only)
- **D3 cover-probe — DONE this session** (recorded above). No further node action outstanding for D3.

## Remaining operator gates (only the operator can clear these)
1. **D1 user proof** — hand a test subscription out-of-band to a real user on a restrictive network; confirm they import it (stock sing-box / Clash-Meta) and reach the open internet; record transport + outcome.
2. **D2 client-device proof** — a real endpoint imports the AmneziaWG config, establishes the UDP/443 tunnel on a node, and reaches an external URL.
3. **REALITY-rotation runbook exercised once** — run `runbooks/reality-rotation.md` on intent; confirm clients re-link with new parameters; attach the transcript.
4. **Ansible-from-zero** — run the full `infra/ansible` playbook on a freshly provisioned VPS; confirm every role converges; record the transcript.
5. **GO/NO-GO signature** — review this completed ledger and authorize (or hold) the transition.

## Ready for Phase 1 when
Every DoD cell is GREEN with **recorded production evidence**: D1 has a real-user proof; D2 has an
AmneziaWG client-device connect-and-reach proof; D3 PASS recorded (**done**); D4 retains the one-command
deploy + the (now-built) atomic revoke wrapper, with Ansible-from-zero validated once; the REALITY-rotation
runbook is exercised once with a transcript; D5 stays green; node-side observability confirmed running with
alerting/per-transport-handshake explicitly deferred per ADR-0021 (named, not silent); **and the operator
signs the GO decision.** The autonomous closures above are prerequisites the maintainer lands directly;
after them, only the operator-owned live proofs remain to flip NO-GO → GO.

## Sign-off
- [ ] All DoD cells GREEN with recorded evidence (operator)
- [ ] Phase-0 → Phase-1 transition **authorized** — signer / date: ____________________
