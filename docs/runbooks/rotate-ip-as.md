<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbook — rotate IP / AS when a node degrades

Author: mindicator & silicon bags quartet

What to do when a node's reachability degrades — typically signalled by a **handshake-failure
alert** — and the most effective response is to move the ingress to a **fresh IP in a different
autonomous system**. The procedure: bring up a new node in another AS, deploy it, re-issue (or
refresh) client subscriptions to point at it, then retire the old node.

> **Phase 0 is manual.** This is an operator procedure executed by hand. The same signals are the
> inputs the **Phase-2 adaptation layer** will consume to automate transport / port / SNI / IP /
> AS rotation with anti-flapping and rollback (see [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md)
> §Layer 2 and [`docs/ROADMAP.md`](../ROADMAP.md) Phase 2). Until then, follow the steps below.

Neutral wording throughout: "network interference", "AS-level blocking", "reachability", "active
probing". No deployment scenario is named.

---

## 1. Confirm it is a network event, not a host fault

Do not rotate IP/AS for a problem a restart would fix. Triage against
[`observability/prometheus/rules.yml`](../../observability/prometheus/rules.yml):

| Alert(s) firing | Most likely cause | Action |
|---|---|---|
| `NodeDown` (`up{job="node_exporter"}==0`) | Host down or metrics tunnel dropped | Confirm the host is alive; **do not** rotate yet. |
| `DataPlaneDown` (engine `singbox`\|`xray`) but **not** `NodeDown` | Host up, data-plane process/stats surface down | Restart/inspect the engine's service (`sing-box.service` for the primary engine, `xray.service` for the optional one); **not** a network event. |
| `HighHandshakeFailureRate` (`signal: possible_network_interference`) | TLS/REALITY handshake no longer completing reliably | Handshake-layer interference → **rotate** (this runbook). |
| `NodeTCPUnreachable` (`signal: possible_as_level_blocking`) | Bare TCP to `:443` failing too | Likely AS-level black-holing → **rotate IP/AS** (this runbook). |
| `TLSCertExpired` / `TLSCertExpirySoon` | Donor/cover certificate problem | Renew or repoint the donor; usually **not** an IP/AS move. |

Quick manual cross-check from a clean vantage point (and, where possible, from inside the affected
region):

```sh
# Bare TCP connect to the node's :443 — does the route even reach the AS?
nc -vz -w 5 OLD_NODE_IP 443

# TLS 1.3 + h2 handshake — does REALITY's relayed handshake still complete?
openssl s_client -connect OLD_NODE_IP:443 -alpn h2 -tls1_3 -servername DONOR_SNI \
  </dev/null 2>/dev/null | grep -E 'ALPN protocol|Protocol *:|Verify return'

# The same conformance probe used at deploy time:
tests/conformance/cover_site_probe.sh OLD_NODE_IP DONOR_SNI
```

Interpretation:
- **TCP fails too** → suspect AS-level blocking: the route to the node's autonomous system is cut
  wholesale. Rotating port/SNI on the **same IP/AS** will not help — move to a **different AS**.
- **TCP connects but the TLS handshake fails** → handshake-layer interference. A fresh IP (ideally
  a different AS) plus, if needed, a fresh donor/SNI is the durable fix; port/SNI changes alone are
  a weaker, temporary measure.

If only a host fault is indicated, stop here and use [`deploy-node.md`](deploy-node.md) §6 to
recover the service instead.

---

## 2. Provision a new node in a *different* AS

Stand up a fresh VPS following [`deploy-node.md`](deploy-node.md) §1, with one hard requirement:

- **Different autonomous system from the degraded node** (and, ideally, a different provider).
  Moving to a fresh IP **in the same AS** does not escape AS-level blocking. This is exactly why
  the deploy runbook tells you to keep **1–2 fresh IPs in reserve in other ASes** — draw one now.
- Re-check the donor still meets the criteria in [`deploy-node.md`](deploy-node.md) §2 from the new
  node's vantage point. If the donor itself is implicated, pick a different donor / SNI for the new
  node to diversify the cover.

Record the new node's public IP as `NEW_NODE_IP`.

---

## 3. Deploy the new node

You may reuse the same `infra/ansible/` working tree. Keep the two inventories distinct so you can
operate both nodes during the cutover (the example files are gitignored, so make local copies):

```sh
cd infra/ansible
cp inventory.ini inventory.new.ini      # or copy from inventory.ini.example
$EDITOR inventory.new.ini               # point [mycelium_nodes] at NEW_NODE_IP
$EDITOR group_vars/all.yml              # set node_address = NEW_NODE_IP; donor/SNI as chosen

# Deploy the new node specifically:
ansible-playbook -i inventory.new.ini playbook.yml
```

(Equivalently, run `scripts/bootstrap.sh` after pointing `inventory.ini` at the new node.) Verify
the new node before cutting over, using [`deploy-node.md`](deploy-node.md) §6:

```sh
tests/conformance/cover_site_probe.sh NEW_NODE_IP DONOR_SNI
```

### Reusing client UUIDs/keys — where it is safe

Client identities and REALITY material can be reused to avoid re-onboarding every client, **with
care**:

- **Client UUIDs are reusable across nodes** when the move is purely a reachability rotation (the
  old node was not compromised — only blocked). Reusing the `client_names` roster means each
  client's UUID is regenerated *deterministically per node* only if you carry the on-node
  `identity.json`; otherwise the new node mints fresh UUIDs for the same names. Either is
  acceptable for an unblock; reissuing subscriptions (step 4) papers over the difference because
  the subscription is what the client actually imports.
- **REALITY keypair: prefer fresh.** Generating a new REALITY keypair on the new node (the
  default) is the safe choice and costs nothing operationally because clients get new
  subscriptions anyway. **Reuse the old keypair only if** you have a specific reason and the old
  node was **not** compromised — never carry private key material onto a node you suspect is
  compromised, and never if the rotation is a response to suspected key exposure.
- **Hard rule:** if the node is being retired due to suspected **compromise** (not mere blocking),
  treat **all** of its key material as burned — mint fresh REALITY keys *and* fresh client UUIDs,
  and reissue every subscription.

---

## 4. Re-issue / refresh client subscriptions to point at the new node

Clients must be pointed at `NEW_NODE_IP`. Each affected client needs a refreshed subscription that
carries the new node's address (and, if you regenerated them, the new REALITY public key /
shortIds).

```sh
# Subscriptions are re-rendered by the xray role and fetched to ./out/ on every run:
cd infra/ansible
ansible-playbook -i inventory.new.ini playbook.yml --tags xray
# -> out/subscriptions/<NEW_host>/<client>.txt  and  out/<NEW_host>-reality_public_key.txt
```

Then redistribute as in [`deploy-node.md`](deploy-node.md) §7 — over a channel reachable **from a
heavily restricted network**, outside the infrastructure an adversary can cut. Distribute only the
subscription; never the REALITY **private** key or a raw UUID.

> Phase 0 has no automatic config-distribution failover — that arrives in Phase 1 (the config
> distribution endpoint that lets standard clients pick up a new endpoint without manual
> redistribution). Until then, refreshing subscriptions out-of-band is the operator's job.

---

## 5. Retire the old node

Only after the new node is verified **and** clients are confirmed on it:

1. **Drain, then stop.** Stop the data plane on the old node so it no longer accepts connections:
   ```sh
   ssh root@OLD_NODE_IP 'systemctl stop xray caddy node_exporter'
   ```
2. **Destroy the instance** (provider console, or `terraform destroy` if you provisioned it via
   [`infra/terraform/`](../../infra/terraform/)). Tearing it down promptly limits the surface and
   stops paying for a blocked IP.
3. **Preserve the reserve pool.** Keep your inventory of fresh IPs in other ASes topped up —
   replenish the one you just consumed so the next rotation is fast.
4. **Update observability.** Remove the retired node from the probe targets and add the new one so
   the dashboard reflects reality:
   - [`observability/prometheus/targets/blackbox_handshake.json.example`](../../observability/prometheus/targets/blackbox_handshake.json.example)
   - [`observability/prometheus/targets/node_exporter.json.example`](../../observability/prometheus/targets/node_exporter.json.example)
   - [`observability/prometheus/targets/dataplane_stats.json.example`](../../observability/prometheus/targets/dataplane_stats.json.example)

If the new node also fails to reach clients, the issue may be wider than one AS — re-triage
(step 1) from multiple vantage points and consider a different provider entirely.

---

## Rollback / fail-closed

If the cutover misbehaves, fall back **fail-closed**: a client without a working config reports
"no connectivity" rather than leaking traffic unprotected (per the project glossary and proposal
§10). Keep the old node's subscriptions in hand until the new node is confirmed; if the new node is
not yet healthy, do **not** push clients onto it.

---

## Post-rotation checklist

- [ ] New node is in a **different AS** from the retired one.
- [ ] `cover_site_probe.sh NEW_NODE_IP DONOR_SNI` is green.
- [ ] Affected clients have refreshed subscriptions pointing at `NEW_NODE_IP` and have connected.
- [ ] Old node stopped and destroyed; its IP no longer in the probe targets.
- [ ] Reserve pool of fresh IPs (in other ASes) replenished.
- [ ] If retirement was due to suspected compromise: all REALITY keys **and** client UUIDs were
      regenerated, not reused.

---

## See also

- [`deploy-node.md`](deploy-node.md) — the zero-to-node procedure this one reuses.
- [`observability/prometheus/rules.yml`](../../observability/prometheus/rules.yml) — the alerts
  that trigger this runbook.
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) §Layer 2 — the adaptation layer that automates this
  in Phase 2.
