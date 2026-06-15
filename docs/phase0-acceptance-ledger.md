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
| **D1** | Restrictive-network user retrieves config → reaches the internet (out-of-band hand-off, ADR-0020 §1) | **PASS** | 2026-06-14: a real client on a restrictive mobile carrier imported the out-of-band subscription into a stock client and reached the open internet (incl. messaging + in-region sites) through a REALITY node. Multi-endpoint client-side failover observed working — some node/transport paths were network-blocked from that carrier and the client selected a reachable one (degradation-not-failure, as designed). Server-side all nodes verified identical + healthy; the unreachable endpoints were confirmed (clean-vantage handshake OK) to be in-region path/IP blocking, not node faults. Bundle generation + urltest/selector failover built (`control/lib/render_singbox.sh`); only the REALITY public key + UUIDs reach clients (`control/selftest.sh`). | operator (final GO sign-off) |
| **D2** | ≥2 independent transport **families** reachable at once on every node (ADR-0020 §5) | **PASS** | 2026-06-14: a real client device imported a node's AmneziaWG (UDP) config and reached the open internet (sites + messaging) over a restrictive mobile link — notably while the REALITY/TLS-TCP family was DPI-blocked on that same link, demonstrating the second family is genuinely INDEPENDENT (degradation-not-failure, the exact purpose of D2). Server-side `awg show` confirmed a recent handshake + bidirectional transfer for the device's peer. REALITY/TLS-TCP + AmneziaWG/UDP wired end-to-end + live on all 3 nodes; `transport_family_independence.sh` PASS. | operator (final GO sign-off) |
| **D3** | Active probing → genuine donor response (REALITY donor is the cover; ADR-0020 §2) | **DONE** | **`cover_site_probe.sh` PASS recorded 2026-06-13 for node-A/B/C:** each answers an active probe as its pinned donor — certificate identity matches the donor, HTTP 200, no tunnel tell ("indistinguishable from ordinary HTTPS"). Conditional closed: the fleet is REALITY-only; HY2/TUIC/Trojan/ShadowTLS default-off (`group_vars/all.yml.example`, `per_protocol_toggle` gate), so no self-signed handshake is exposed. | — |
| **D4** | One-command deploy + revoke-without-reinstall + reproducible deploy | **partial** | One-command bootstrap (`scripts/node-bootstrap.sh`) proven on 3 nodes (AF_NETLINK fix at HEAD); Terraform deferred (ADR-0020 §4). **Atomic revoke wrapper (DONE, 2026-06-15, `4ce8ce0`):** the on-node `--revoke NAME\|ID` mode (`flow_revoke`) now does `myceliumctl identity revoke` → re-render → `sing-box check` (fail-closed) → promote → engine reload → verify-post-apply, with auto-rollback on failure — one command, reusing the updater's tested render/validate/promote/verify path. No node *reinstall* and no manual re-render needed; other clients' links are unchanged. **From-zero deps (done, 2026-06-15):** node-bootstrap auto-installs the base packages (git/jq/iptables/ufw + curl/tar/unzip, `install_base_deps`) and builds the AmneziaWG userspace tools (amneziawg-go + awg/awg-quick, pinned source) on bootstrap (`install_awg_tools`). **From-zero build VALIDATED on a node (2026-06-15):** on an existing node every `install_base_deps`/`install_awg_tools` apt package resolves on 26.04 (incl. `golang-go 1.26` + `build-essential 12.12`), and the pinned sources `amneziawg-go v0.2.18` + `amneziawg-tools v1.0.20260223` compile clean with that apt Go — the build half of the from-zero path is proven; the runtime/systemd half (units + awg-quick@) is proven by the live fleet (D2). **Remaining:** the operator's full bootstrap-orchestration run on a freshly provisioned pristine VPS (the only piece an existing node can't stand in for). | operator (pristine-VPS run) |
| **D5** | No excluded legacy transport configured anywhere | **DONE** | `no_legacy_transport.sh` gate PASS at HEAD. | — |
| S | Basic observability (node liveness / utilisation **done**; per-transport handshake-success + alerts **deferred** per ADR-0021) | **partial** | Node-side producers live on all 3, loopback-only: `node_exporter`, the `dataplane-stats` utilisation exporter (PII-safe, `no_dataplane_pii` gate), the reachability monitor, + the `mycelium_dataplane_unit_active` metric. **Deferred (named, ADR-0021):** alerting + per-transport handshake-success-rate → the per-operator monitor / Phase-2 edge reporting; **no central collector in any phase.** | deferred (not a Phase-0 blocker) |
| S | Reproducible deploy (`node-bootstrap.sh` + Ansible; Terraform deferred, ADR-0020 §4) | **DONE** | Canonical idempotent fail-closed bootstrap; ROADMAP annotated `(see ADR-0020)`. (Ansible-from-zero re-validation tracked under D4.) | — |
| S | Hosting / AS-diversity (no single tainted AS) | **DONE** | Operationally met (3 nodes, 3 countries); the auditable AS-diversity inventory now exists at `runbooks/node-as-inventory.md` (region / AS class / IP-reputation / deploy-date / rationale, keyed by node-A/B/C; no raw IPs). | — |
| S | ADR-0020 reconciliations recorded + ROADMAP annotated | **DONE** | ADR-0020 accepted; ROADMAP cross-refs present. | — |
| S | Manual REALITY-rotation runbook **exercised at least once** (ADR-0020 §Compliance) | **DONE** | 2026-06-15: exercised once on a node end-to-end per `runbooks/reality-rotation.md` — a fresh REALITY keypair (`sing-box generate reality-keypair`) + new short-id (`openssl rand -hex 8`) generated and written into the node identity, the server config re-rendered with the new params, `sing-box check` VALID, sing-box reloaded + active on the rotated key (REALITY TCP ports listening), under backup + validate-before-apply + auto-rollback; the node's subscriptions re-issued with the new `pbk`/`sid`. Confirms the manual rotation cleanly changes links with only a reload blip. | operator (confirm a re-imported client links) |
| — | This GO/NO-GO ledger exists (r18) | **DONE** | this document. | — |

## Remaining autonomous closures (no node / no operator needed)
These I can land immediately; they harden Phase-0 and complete the self-contained surface:
- **DONE — atomic on-node revoke wrapper** (2026-06-15, `4ce8ce0`) — `scripts/node-bootstrap.sh --revoke NAME|ID` (`flow_revoke`): `myceliumctl identity revoke` → re-render → `sing-box check` → promote → engine reload → verify, with auto-rollback (fail-closed, mirroring the updater). Suite 18/18, `bash -n` clean.
- **Bootstrap subscription emission** — `node-bootstrap.sh` emits per-client subscriptions to a gitignored hand-off dir at the end of bootstrap (the Ansible path already does), so the one-command path is self-complete for the D1 hand-off.
- **DONE — `harden_journald` fail-closed** — implemented in `scripts/node-bootstrap.sh` (`harden_journald`): a failed restart or a surviving persistent `/var/log/journal` aborts the bootstrap via `die` (fail-closed), not a warning.
- **DONE — AS-diversity inventory doc** — exists at [runbooks/node-as-inventory.md](runbooks/node-as-inventory.md): region / AS class / IP-reputation posture / deploy-date / rationale template, keyed by node-A/B/C (no raw IPs).
- **DONE — ROADMAP line annotation** — the observability DoD line in [ROADMAP.md](ROADMAP.md) now points at ADR-0021 (deferral of alerting / per-transport handshake to the per-operator monitor / Phase-2), mirroring the ADR-0020 cross-refs.

## Audit-0004 (full-scale) — transition-gating S1 closed
Audit-0004 ([audits/0004-phase0-to-phase1-full-scale-audit.md](audits/0004-phase0-to-phase1-full-scale-audit.md))
closed **F-001** (AF_NETLINK unit parity — `AF_NETLINK` now on both Ansible units, `singbox.service.j2` /
`xray.service.j2`, with the `unit_netlink_parity.sh` conformance gate guarding all unit-producing sources)
and **F-002 / F-004** (the structural gates now describe the *deployed* artifact via `live_artifact_posture.sh`,
and the two-port REALITY default is recorded in [adr/0022-two-port-reality-default.md](adr/0022-two-port-reality-default.md)).
So **the one S1 that gated the Phase-0 → Phase-1 transition is closed**; only the operator-owned production
proofs below remain.

## Remaining node-side proof (controlled, read-only)
- **D3 cover-probe — DONE this session** (recorded above). No further node action outstanding for D3.

## Remaining operator gates (only the operator can clear these)
1. **D1 user proof** — **DONE** (scorecard PASS, 2026-06-14): a real user on a restrictive mobile carrier imported the out-of-band subscription and reached the open internet via a REALITY node, with client-side failover observed.
2. **D2 client-device proof** — **DONE** (scorecard PASS, 2026-06-14): a real device imported a node's AmneziaWG config and reached the internet over UDP while the TLS family was blocked on the same link.
3. **REALITY-rotation runbook exercised once** — **DONE 2026-06-15** (see the scorecard row): exercised end-to-end on a node (fresh keypair via `sing-box generate reality-keypair` + new short-id → identity updated → config re-rendered → `sing-box check` VALID → sing-box reloaded + active → links re-issued), under backup + auto-rollback. Operator residue: confirm a client that re-imports the node's new links connects.
4. **Ansible-from-zero (pristine-VPS orchestration run)** — run the full `infra/ansible` playbook (or `node-bootstrap.sh`) on a freshly provisioned VPS; confirm every role converges; record the transcript. **De-risked 2026-06-15:** the from-zero manual-fixup gaps are closed in node-bootstrap (`install_base_deps` + `install_awg_tools`), and the build half was validated on an existing node — every apt package resolves on 26.04 (incl. `golang-go 1.26`) and the pinned `amneziawg-go v0.2.18` + `amneziawg-tools v1.0.20260223` compile clean with that apt Go. So this operator run now validates only the **systemd orchestration on a pristine image** (units + awg-quick@ + fail-closed render end-to-end), not the package/build path.
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
