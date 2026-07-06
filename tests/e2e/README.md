<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# End-to-end client-recovery harness (RP-0013 C2)

The repeatable auto-test behind the first-release-milestone e2e DoD (closing Phase 2): **under a block of its active endpoint, a stock
client holding the served subscription is carrying traffic again on an independent sibling within
single-digit minutes, with no human action — measured at the client.** This is the automated companion to
the authoritative on-device run on the operator's real client (the Phase-1 method); see
[RP-0013](../../docs/proposals/0013-phase3-e2e-client-recovery.md).

This is a **live-node** harness, not an offline conformance gate — it starts an engine and moves real
packets, so it is **not** registered in `tests/run.sh` (which stays hermetic). The serve-time invariant it
depends on (`≥2 independent families`) *is* offline-gated by `tests/conformance/e2e_recovery_fallback.sh`
(RP-0013 C1).

## The three pieces

| Script | Runs as | Does |
|---|---|---|
| `gen_client_config.sh` | any host, jq | Wraps a node's rendered subscription (`myceliumctl subscription`) into a runnable headless client: injects a loopback `mixed` inbound + routes through the `urltest` "auto" group. **Fails closed unless the sub spans ≥2 distinct families** (mirrors C1 — no sibling ⇒ no recovery to measure). |
| `block_endpoint.sh` | node, root | A **scoped, reversible** `iptables` DROP of one served port. `--source SRC` makes it **surgical**: only that source is dropped, so a real population on the same port is unaffected. Never edits the served config. |
| `client_recovery_probe.sh` | client host, root | Starts the client, proves a baseline, invokes the block, **times recovery on the sibling**, unblocks, emits a JSON verdict + `recovery_seconds`. A trap always unblocks + stops the client. |

## Topology

Two equivalent shapes; both measure recovery **at the client**:

- **Co-located (default).** Run the client on the node itself, dialing the node's **public IP**. Own
  out→in traffic routes via `lo` with `src = the public IP`, so `block_endpoint.sh --source <public-ip>`
  drops **only** the on-node test client's path to the active port — every external client on that port is
  untouched. Self-contained, surgical, production-safe.
- **Two-host.** Run the client on a second host dialing the node; block on the node with
  `--source <client-host-ip>`. A faithful external path; same surgical scoping.

## Drill runbook (RP-0013 C3)

On the node (co-located shape), with `IP` = the node's reachability address:

```sh
# 1. fresh subscription from live params + identities (>=2 independent families)
myceliumctl subscription --params /var/lib/mycelium/params.json \
    --state /var/lib/mycelium/identities.json --out /tmp/e2e-sub
# 2. wrap into a runnable client (fast urltest interval for the drill; served interval bounds real-world)
tests/e2e/gen_client_config.sh --fragment /tmp/e2e-sub/<client>.singbox.json \
    --proxy-port 10808 --urltest-interval 30s --out /tmp/e2e-sub/client.runnable.json
# 3. block the ACTIVE family's port, time recovery on the sibling, restore
tests/e2e/client_recovery_probe.sh --config /tmp/e2e-sub/client.runnable.json \
    --proxy-port 10808 --node-ip "$IP" --active-port <active-port> --bound-sec 360
```

`verdict:"pass"` with `recovery_seconds ≤ bound` ⇒ AC-1 + AC-4 met for that node. Record the result in the
Phase-2 acceptance ledger (C3), plus one on-device confirmation on the real client.

## Safety / invariants

- **Never changes what the node serves** — only a scoped path DROP; the served config is byte-identical
  before and after, and the trap guarantees the rule is removed even on interrupt.
- **Surgical** — `--source` scoping keeps a live population unaffected during a drill.
- **No new actuation, no coordination** — recovery is client-native `urltest` failover across the
  ≥2 independent families the subscription already carries (RP-0010/0012 AC-4-advisory + AC-5-closed-set
  stay green; the harness introduces no global signal and no mutate-a-node path).
- **Realism caveat** — a node-local firewall DROP approximates a path block; the on-device run on the real
  restrictive link is the realism backstop (as in Phase 1).
