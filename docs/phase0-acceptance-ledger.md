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

> **Current verdict: GO — Phase-0 → Phase-1 transition AUTHORIZED 2026-06-15** (operator sign-off recorded
> below). Every DoD and acceptance cell is **GREEN with recorded evidence**: D1 ✅ (real-user proof), D2 ✅
> (AmneziaWG client-device proof), D3 ✅ (cover-probe), D4 ✅ (one-command deploy + atomic revoke wrapper +
> from-zero install path validated end-to-end on a node, **no new VDS**), D5 ✅, REALITY-rotation ✅ (exercised
> once), engine-currency ✅; 18 offline gates green; the Go spine builds/tests/`-race` green; node-side
> observability live loopback-only; out-of-band D1 delivery correct (only the REALITY *public* key + client
> UUIDs reach clients). The operator additionally validated both families hands-on on a real device and signed
> GO. **Phase 1 (RP-0007) is now unlocked.** (Node identifiers are abstracted as node-A/B/C; no
> IPs/hostnames/donor-mappings appear here, per the project OPSEC rule.)

## DoD scorecard

| # | Criterion (DoD / scope) | Status | Evidence / proof | Owner of remainder |
|---|---|---|---|---|
| **D1** | Restrictive-network user retrieves config → reaches the internet (out-of-band hand-off, ADR-0020 §1) | **PASS** | 2026-06-14: a real client on a restrictive mobile carrier imported the out-of-band subscription into a stock client and reached the open internet (incl. messaging + in-region sites) through a REALITY node. Multi-endpoint client-side failover observed working — some node/transport paths were network-blocked from that carrier and the client selected a reachable one (degradation-not-failure, as designed). Server-side all nodes verified identical + healthy; the unreachable endpoints were confirmed (clean-vantage handshake OK) to be in-region path/IP blocking, not node faults. Bundle generation + urltest/selector failover built (`control/lib/render_singbox.sh`); only the REALITY public key + UUIDs reach clients (`control/selftest.sh`). | operator (final GO sign-off) |
| **D2** | ≥2 independent transport **families** reachable at once on every node (ADR-0020 §5) | **PASS** | 2026-06-14: a real client device imported a node's AmneziaWG (UDP) config and reached the open internet (sites + messaging) over a restrictive mobile link — notably while the REALITY/TLS-TCP family was DPI-blocked on that same link, demonstrating the second family is genuinely INDEPENDENT (degradation-not-failure, the exact purpose of D2). Server-side `awg show` confirmed a recent handshake + bidirectional transfer for the device's peer. REALITY/TLS-TCP + AmneziaWG/UDP wired end-to-end + live on all 3 nodes; `transport_family_independence.sh` PASS. | operator (final GO sign-off) |
| **D3** | Active probing → genuine donor response (REALITY donor is the cover; ADR-0020 §2) | **DONE** | **`cover_site_probe.sh` PASS recorded 2026-06-13 for node-A/B/C:** each answers an active probe as its pinned donor — certificate identity matches the donor, HTTP 200, no tunnel tell ("indistinguishable from ordinary HTTPS"). Conditional closed: the network is REALITY-only; HY2/TUIC/Trojan/ShadowTLS default-off (`group_vars/all.yml.example`, `per_protocol_toggle` gate), so no self-signed handshake is exposed. | — |
| **D4** | One-command deploy + revoke-without-reinstall + reproducible deploy | **DONE** | One-command bootstrap (`scripts/node-bootstrap.sh`) proven on 3 nodes (AF_NETLINK fix at HEAD); Terraform deferred (ADR-0020 §4). **Atomic revoke wrapper (DONE, 2026-06-15, `4ce8ce0`):** the on-node `--revoke NAME\|ID` mode (`flow_revoke`) now does `myceliumctl identity revoke` → re-render → `sing-box check` (fail-closed) → promote → engine reload → verify-post-apply, with auto-rollback on failure — one command, reusing the updater's tested render/validate/promote/verify path. No node *reinstall* and no manual re-render needed; other clients' links are unchanged. **From-zero deps (done, 2026-06-15):** node-bootstrap auto-installs the base packages (git/jq/iptables/ufw + curl/tar/unzip, `install_base_deps`) and builds the AmneziaWG userspace tools (amneziawg-go + awg/awg-quick, pinned source) on bootstrap (`install_awg_tools`). **From-zero install path VALIDATED end-to-end on a node — no new VDS (2026-06-15):** the *verbatim* `install_base_deps` + `install_awg_tools` from `node-bootstrap.sh` were run against a throwaway **empty Ubuntu 26.04 (`resolute`) rootfs** built with `debootstrap` inside an existing node (git/jq/go/awg/awg-quick/amneziawg-go/iptables/ufw/curl/unzip all confirmed ABSENT first). Result: all 8 base packages installed from zero; `golang-go` + `build-essential` installed; **amneziawg-go (tag v0.2.18) + amneziawg-tools (tag v1.0.20260223) built from pinned source** and installed (`amneziawg-go`→`/usr/local/bin`, `awg`/`awg-quick`→`/usr/bin`); the userspace `awg-quick@.service` rendered — **`rc=0`, NO manual fixups**. Rootfs then torn down (cleanup trap); the host's live transports stayed active throughout. This is the "no-manual-fixups from-zero" proof for the canonical bash bootstrap; the systemd-as-PID1 half (units actually starting on a real boot) is proven continuously by the live network (D2: engine + `awg-quick@awg0` active on every node). **Optional (NOT a GO gate):** a from-zero run of the *Ansible* path (`infra/ansible`) — it shares the same apt/build logic, so its from-zero risk is already de-risked; it has simply not been separately exercised. | — |
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
4. **From-zero bootstrap** — **DONE 2026-06-15, no new VDS** (see the D4 scorecard row): the verbatim `install_base_deps` + `install_awg_tools` ran to `rc=0` with NO manual fixups against a throwaway empty Ubuntu 26.04 rootfs (`debootstrap`) inside an existing node — base packages installed, `amneziawg-go`/`amneziawg-tools` built from the pinned tags + installed, `awg-quick@.service` rendered, then torn down. The systemd-as-PID1 orchestration is proven continuously by the live network. **Optional, not a gate:** a from-zero run of the *Ansible* path (same apt/build logic — already de-risked) and/or a full pristine-VPS bootstrap if the operator ever wants the belt-and-suspenders transcript. Renting a fresh VPS is **not required**.
5. **GO/NO-GO signature** — review this completed ledger and authorize (or hold) the transition. **This is now the only gate left.**

## Ready for Phase 1 when
Every DoD cell is GREEN with **recorded production evidence**: D1 has a real-user proof; D2 has an
AmneziaWG client-device connect-and-reach proof; D3 PASS recorded (**done**); D4 is **DONE** — one-command
deploy + the atomic revoke wrapper + the from-zero install path validated end-to-end on a node (no VDS);
the REALITY-rotation runbook is exercised once with a transcript; D5 stays green; node-side observability
confirmed running with alerting/per-transport-handshake explicitly deferred per ADR-0021 (named, not silent).
**Every engineering and acceptance cell is now GREEN; the sole remaining gate is the operator's GO signature.**
The autonomous closures above are all landed; nothing further requires the maintainer or a new VPS.

## Sign-off
- [x] All DoD cells GREEN with recorded evidence (operator)
- [x] Phase-0 → Phase-1 transition **authorized** — signer / date: **mindicator (operator) / 2026-06-15**

Operator validated both transport families hands-on on a real restrictive-network device (D1 + D2
AmneziaWG/UDP, Wi-Fi + LTE) and **authorized the Phase-0 → Phase-1 transition (GO) on 2026-06-15.** A
client-pull subscription URL was also demonstrated propagating a server-side change without re-import —
note this is the **Phase-1 RP-0007-b *seam* working early** (a self-hosted nginx-served URL the client
re-polls), **not** the matured RP-0007-b deliverable (a `myceliumd`-served bundle endpoint with
`profile-update-interval`, the bundle schema, and the sub-channel-not-single-point gate). That build is
Phase-1 work; this GO authorizes *starting* it, not its acceptance. (Phase status: the ledger is the SoT.)
