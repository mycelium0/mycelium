<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbook — Phase-0 acceptance proofs (operator-owned)

> **Purpose.** The Phase-0 engineering/conformance plane is complete (offline suite green; the
> Phase-0→1 full-scale audit found no open S0/S1). What remains to flip the
> [acceptance ledger](../phase0-acceptance-ledger.md) from NO-GO to GO are **live production proofs
> only a person with the real infrastructure and a real client device can perform.** This runbook is
> the exact sequence for those proofs, with a pass criterion and a one-line record to paste into the
> ledger for each.
>
> **Scope discipline.** These are *acceptance* steps, not new features. They change no committed
> contract. Nodes are referred to as node-A / node-B / node-C; never write a real IP, hostname,
> donor, key, or client UUID into the ledger or any committed file (keep those in the gitignored
> `*.local.md`).

## Preconditions
- The network is healthy: on each node `systemctl is-active sing-box` and `systemctl is-active
  awg-quick@awg0` are `active`, and the `mycelium-update.timer` is active.
- `bash tests/run.sh` is green on the deployed `--repo-ref` (the offline gates describe the deployed
  artifact, per Audit-0004 F-002).
- You have a **real client device on a restrictive network** (mobile LTE in the target region is the
  realistic case) for D1/D2, and a **fresh VPS** for the Ansible-from-zero proof.

---

## Proof D1 — real-user end-to-end on a restrictive link

**Goal.** A real client, on a restrictive network, connects through a Mycelium subscription and
reaches the open internet — the data plane carries real traffic, not just a loopback smoke test.

**Materials.** Either a single node's subscription, or the **one-profile-all-nodes** bundle (below).

**One profile, all nodes (the "one link" convenience + Phase-1 client-side-merge model).** Each node
renders its own subscription locally; the client holds the union with automatic failover. To rebuild
it reproducibly:
1. On (or for) each node, render the per-client subscription from local identity:
   `myceliumctl subscription --engine singbox --params <node>.params.local.json --state <node>.state
   --out out/<node>/`. This emits `<client>.singbox.json` (+ `.clash.yaml`) per node — public key /
   shortId only, never the private key.
2. Merge the per-node proxy outbounds into **one** client profile, retagged per node
   (`proxy-<node>-vision`, `proxy-<node>-grpc`, …), and add a health-based selector across all of
   them so the client auto-picks a live endpoint:
   - **sing-box / Clash-Meta:** one `urltest` outbound (`tag: auto`) over every per-node tag + a
     `selector` defaulting to it.
   - **Xray (e.g. Happ):** an `observatory` (`subjectSelector: ["proxy-"]`, 10 s probe) + a
     `leastPing` `balancer` (`selector: ["proxy-"]`), routed `balancerTag: auto` for proxy traffic.
   This is **client-side aggregation** — no central endpoint enumerates the cluster
   (see [ROADMAP.md](../ROADMAP.md) Phase 1; a single cluster-wide endpoint is forbidden).

**Steps.**
1. Import the profile into the off-the-shelf client (match the engine: Happ = Xray; Hiddify /
   sing-box app = sing-box). Connect.
2. From the device on the restrictive link, verify egress: open an IP-echo page and a normal site;
   confirm the public IP is a node's, not the carrier's, and pages load.
3. Block/observe one transport (e.g. carrier interferes with TCP/443) and confirm the client fails
   over to another endpoint/transport within the same profile without manual reconfiguration.

**Pass criterion.** A real device on the restrictive link browses the open internet through Mycelium,
and survives one transport being unavailable.

**Ledger record (no PII):** `D1: PASS — real client on <restrictive network class>, egress via
node-X confirmed, failover to <transport> observed on <date>.`

---

## Proof D2 — independent second family (AmneziaWG) reachable from a device

**Goal.** Prove the **second transport family** (AmneziaWG/UDP, the canonical Phase-0 second family,
ADR-0020 §5) actually carries traffic from a client device — not just that the server listens.

**Steps.**
1. Import a node's AmneziaWG client config (the `*.awg.conf` issued for that node) into the AmneziaWG
   / Amnezia app on the device. Bring the tunnel up.
2. Confirm reachability: from the device, load an external URL; confirm egress is the node's IP.
3. Server-side confirmation on that node: `awg show awg0` shows a **recent handshake** and non-zero
   `transfer` for the device's peer.

**Pass criterion.** The device establishes an AmneziaWG tunnel (UDP/443) to the node and reaches an
external URL; `awg show` confirms handshake + transfer.

**Ledger record:** `D2: PASS — device AmneziaWG tunnel to node-X up, external reach confirmed,
awg show handshake+transfer present on <date>.`

---

## Proof — REALITY rotation exercised once (transcript)

**Goal.** Prove the manual Phase-0 cover-identity rotation procedure actually works end-to-end on a
real node (so it is usable under a real burn), and capture a transcript.

**Steps.** Follow [reality-rotation.md](reality-rotation.md) on **one** node (node-C is a good
choice — fewest live clients). In short: back up `identity.json`; `myceliumctl reality-keys` (it
uses `xray x25519`, or falls back to `sing-box generate reality-keypair` on a sing-box-only node);
write the new REALITY fields into `identity.json`; re-render via `node-bootstrap.sh --update`;
confirm `sing-box check` passes and the service is healthy; re-issue that node's client links (the
rotation **deliberately changes links**).

**Pass criterion.** The node comes back healthy on the new REALITY parameters and a client using the
**new** link connects; the **old** link no longer authenticates.

**Ledger record:** `REALITY rotation: PASS — exercised on node-C <date>; node healthy on new params;
old link rejected; new link connects. Transcript: <path to gitignored .local transcript>.`

---

## Proof D4 — Ansible from zero on a fresh VPS

**Goal.** Prove a brand-new node converges to a healthy, hardened, two-family node from nothing, by
the sanctioned Ansible path — the reproducibility guarantee. (The AF_NETLINK, journald-fail-closed,
and AmneziaWG-fail-closed fixes from Audit-0004 make this path safe to run from zero.)

**Steps.**
1. Provision a fresh VPS (a spare IP in an AS not already used by the network — see
   [node-as-inventory.md](node-as-inventory.md)).
2. Fill a gitignored inventory + `group_vars` `*.local` with the node's real values; run the Ansible
   play (`infra/ansible`).
3. Watch convergence: hardening (key-only SSH, RAM-only journald — now fail-closed; UFW with logging
   off), sing-box up with the enabled transports, AmneziaWG up (fail-closed — the play aborts if the
   second family does not come up), observability loopback stack.

**Pass criterion.** From a bare VPS, one play run yields a node that passes the same listener / cover
/ second-family checks as a hand-built node, with **no manual fix-ups**, and no crash-loop.

**Ledger record:** `D4: PASS — fresh VPS converged via Ansible in one run on <date>; sing-box +
AmneziaWG active; no manual intervention.`

---

## Proof — GO sign-off

Once D1, D2, the REALITY-rotation exercise, and D4 are recorded PASS in the
[acceptance ledger](../phase0-acceptance-ledger.md), flip the ledger verdict to **GO** and sign it
(operator name/date). That sign-off is the gate that authorises starting Phase 1.

**Ledger record:** `Verdict: GO — Phase 0 fulfilled in production. Signed: <operator> <date>.`

---

## After GO
- Open the Phase-1 RP (matured config-distribution endpoint: self-replenishing subscription +
  client-side single-profile aggregation; per-transport health/failover; CDN-fronted last resort).
  Carry the pinned Phase-1 contracts forward: the `region` metadatum closed-vocabulary guard and the
  §15.2 subscription block-resistance acceptance bar (see [ROADMAP.md](../ROADMAP.md) Phase 1).
- Per [refactoring.md](../refactoring.md) §19, review the audit/refactoring policy after the phase
  transition.
