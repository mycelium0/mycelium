<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Observability

Author: mindicator & silicon bags quartet

Health, reachability, and handshake telemetry for a Mycelium Phase 0 node, built on
**Prometheus + Alertmanager + blackbox_exporter** (the stack named in
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §Recommended stack). The job of this
component is to answer one operational question quickly: **is the node reachable and is the
handshake healthy — and if not, is this a host fault or possible network interference?** The same
signals are the raw inputs the **Phase-2 adaptation layer** (Layer 2) will consume to automate
rotation; in Phase 0 the operator reads them and acts by hand.

Data-plane liveness here is **engine-agnostic**. **sing-box is the primary engine** and is what a
default node runs; **Xray** is an **optional alternative**. The `dataplane_stats` scrape job and the
`DataPlaneDown` alert describe "is the data-plane process answering" without caring which engine is
deployed; an `engine` label (`singbox` | `xray`) records the choice. A direct `SingBoxDown` alert
covers the primary engine's service health, and an optional `XrayDown` is provided (commented)
behind the optional engine.

> Privacy note (threat model): nothing here records user PII, client IPs, destinations, or
> per-identity traffic. Host metrics are aggregate; data-plane stats are exported at the
> **inbound / aggregate** level only (per-user counters stay off, see
> [`../nodes/dataplane/singbox/README.md`](../nodes/dataplane/singbox/README.md));
> blackbox probes are unauthenticated reachability checks that never open a tunnel.

## License note (why the `targets/*.json` files have no header)

The `prometheus/targets/*.json` files are **pure JSON** consumed by Prometheus' `file_sd`. JSON
has no comment syntax, so an embedded AGPL header would make them invalid. The license therefore
lives here instead and covers every `.json` under this directory:

> Copyright © 2026 mindicator & silicon bags quartet.
> SPDX-License-Identifier: AGPL-3.0-or-later
> These files are part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
> later. See the `LICENSE` file in the repository root.

## Files

| File | Purpose |
|---|---|
| `prometheus/prometheus.yml` | Scrape config: `node_exporter`, `dataplane_stats` (engine-agnostic; optional `xray_stats` commented), blackbox handshake + TCP probes, self-monitoring. |
| `prometheus/rules.yml` | Alerting rules: `NodeDown`, `DataPlaneDown`, `SingBoxDown` (optional `XrayDown` commented), `HighHandshakeFailureRate`, `NodeTCPUnreachable`, `TLSCertExpirySoon`, `TLSCertExpired`, `BlackboxExporterDown`. |
| `prometheus/targets/*.json.example` | `file_sd` target templates. Copy to the un-suffixed name and fill in real addresses (gitignored). |
| `alertmanager/alertmanager.yml` | Routing skeleton with a null default receiver and a placeholder webhook (no secrets). |
| `blackbox/blackbox.yml` | blackbox_exporter modules: `mycelium_tcp_connect`, `mycelium_tls_handshake`, `mycelium_https_get`. |

## How it wires to a node

Prometheus, Alertmanager, and blackbox_exporter run on the **operator's control host**, not on
the node. The node-side exporters bind to **loopback only** and the host firewall never opens an
exporter port (see [`../infra/ansible/roles/observability`](../infra/ansible/roles/observability)
and the node_exporter systemd unit, which binds `127.0.0.1:9100`). Metrics are reached over an
**SSH tunnel** (or the mesh, in later phases), never over the public interface.

```
                          OPERATOR CONTROL HOST
   ┌──────────────────────────────────────────────────────────────────┐
   │  Prometheus (127.0.0.1:9090)                                       │
   │     ├── scrape node_exporter    ──▶ 127.0.0.1:19100  ─┐           │
   │     ├── scrape dataplane_stats  ──▶ 127.0.0.1:19550  ─┤ SSH tunnel│
   │     ├── scrape blackbox /probe  ──▶ 127.0.0.1:9115 ───┼───────┐   │
   │     └── alerts ──▶ Alertmanager (127.0.0.1:9093) ──▶ webhook │   │
   └───────────────────────────────────────────────────────│──────│───┘
              │ (1) loopback-forwarded scrapes              │      │ (2) outward probe
              ▼                                              │      ▼
   ┌────────────────────────────────────┐         ┌─────────┴───────────────────┐
   │  NODE (loopback exporters)          │         │  blackbox_exporter           │
   │   node_exporter   127.0.0.1:9100    │         │  probes NODE_PUBLIC:443      │
   │   sing-box clash_api 127.0.0.1:9090 │         │  (TCP + TLS1.3 handshake)    │
   │   dataplane-stats 127.0.0.1:9550    │◀────────┘  from outside, like a prober │
   └────────────────────────────────────┘         └──────────────────────────────┘
```

Two complementary vantage points:

1. **Inside-out (tunnelled scrapes).** `node_exporter` (host health) and the engine-agnostic
   `dataplane_stats` exporter (data-plane counters) are pulled through an SSH tunnel that maps each
   node's loopback port to a loopback port on the control host. The stats exporter reads the
   primary engine's loopback stats surface (sing-box `clash_api` on `127.0.0.1:9090`) — or, for an
   optional-engine node, the Xray stats API — and re-exposes counters on `127.0.0.1:9550`. List
   those forwarded addresses in `prometheus/targets/node_exporter.json` and
   `prometheus/targets/dataplane_stats.json`.
2. **Outside-in (blackbox probes).** blackbox_exporter probes each node's **public** `:443` from
   the control host, measuring whether a client could actually connect and complete the handshake.
   List the public `host:443` targets in `prometheus/targets/blackbox_handshake.json`.

### Wiring steps

1. Copy each `targets/*.json.example` to its real (gitignored) name and fill in addresses:

   ```sh
   cd observability/prometheus/targets
   cp node_exporter.json.example       node_exporter.json
   cp dataplane_stats.json.example     dataplane_stats.json
   cp blackbox_handshake.json.example  blackbox_handshake.json
   $EDITOR *.json   # set the forwarded loopback ports, the engine label, and the public host:443
   ```

2. Open the SSH tunnel from the control host to the node, mapping loopback exporters to local
   loopback ports (match the ports you put in the target files):

   ```sh
   ssh -N \
     -L 127.0.0.1:19100:127.0.0.1:9100 \
     -L 127.0.0.1:19550:127.0.0.1:9550 \
     deploy@NODE_PUBLIC_HOST
   ```

3. Start blackbox_exporter with this module file, then Prometheus + Alertmanager with these
   configs (any install method — package, container, or binary; pin the versions you deploy):

   ```sh
   blackbox_exporter   --config.file=observability/blackbox/blackbox.yml          # :9115
   prometheus          --config.file=observability/prometheus/prometheus.yml      # :9090
   alertmanager        --config.file=observability/alertmanager/alertmanager.yml  # :9093
   ```

4. Point the Alertmanager webhook at your own notification relay (keep the real URL OUT of the
   repo — use an `alertmanager.yml.local` override or a `secrets/` mount).

### Data-plane stats: chosen approach (engine-agnostic)

Data-plane counters are read from whichever engine the node runs, and re-exposed on a single
loopback port so the `dataplane_stats` scrape job never has to change.

**Primary engine — sing-box.** A default node enables `experimental.clash_api` bound to
`127.0.0.1:9090` (see
[`../nodes/dataplane/singbox/server.template.renderer.json`](../nodes/dataplane/singbox/server.template.renderer.json)),
which serves aggregate connection/traffic counters over **HTTP/JSON** — not the Prometheus text
format — so Prometheus cannot scrape it directly. The chosen approach is a **small read-only
exporter on the node**: it reads that loopback `clash_api`, translates the inbound/aggregate byte
and uptime counters into Prometheus metrics, and serves them on `127.0.0.1:9550`. Prometheus
scrapes that exporter over the same SSH tunnel as `node_exporter`. The exporter is read-only,
loopback-bound, and exports **inbound/aggregate-level counters only** — never per-user stats — to
avoid attributing traffic to individual identities. This is the sing-box-native, documented surface
and adds no new public wire.

**Optional engine — Xray.** When a node runs the optional Xray alternative instead, the same
exporter slot reads Xray's local stats API and re-exposes on the same `127.0.0.1:9550`. The scrape
job and the engine-agnostic `DataPlaneDown` alert are unchanged; only the `engine` file_sd label
flips to `xray` (and the optional, commented `xray_stats` job / `XrayDown` alert can be enabled if a
dedicated native exporter is preferred). Either way, only inbound/aggregate counters are exported.

The `engine` label (`singbox` | `xray`) carried in `targets/dataplane_stats.json` flows through to
the metrics, so `DataPlaneDown` covers both engines while `SingBoxDown` keys specifically off the
primary engine's node-side systemd-textfile health metric.

## What each alert means operationally

| Alert | Fires when | Operational meaning | Action |
|---|---|---|---|
| **NodeDown** | `up{job="node_exporter"} == 0` for 2m | The host (or its metrics tunnel) is gone. Confirm liveness first — this is *not yet* a network-interference verdict. | Check the host / tunnel. See `deploy-node.md`. |
| **DataPlaneDown** | `up{job="dataplane_stats"} == 0` for 2m | Engine-agnostic data-plane liveness. The data-plane process or its local stats surface is down. If NodeDown is **not** also firing, the host is up but the engine (`{{ engine }}` = singbox \| xray) is not — a process fault. | Restart / inspect the data-plane service, not the network. |
| **SingBoxDown** | `mycelium_dataplane_unit_active{engine="singbox"} == 0` for 2m | The **primary engine**'s service is not active (node-side systemd-textfile health metric). Catches a crashed/stopped `sing-box.service` even if the stats exporter is unhealthy. | Restart / inspect `sing-box.service`, not the network. |
| **XrayDown** *(optional, commented)* | `mycelium_dataplane_unit_active{engine="xray"} == 0` for 2m | Only for nodes running the **optional** Xray engine: the `xray.service` unit is not active. Enable this alert only behind the optional engine. | Restart / inspect the optional `xray.service`, not the network. |
| **HighHandshakeFailureRate** | 10m mean of `probe_success{job="blackbox_handshake"} < 0.5` | **Possible network interference**: clients increasingly cannot complete the REALITY/TLS handshake from the probe vantage point. | **Trigger IP/AS rotation per `rotate-ip-as.md`** (and consider port / SNI / donor). Compare with the TCP probe to localise the layer. |
| **NodeTCPUnreachable** | 10m mean of `probe_success{job="blackbox_tcp"} < 0.5` | TCP to `:443` is failing too — most consistent with **AS-level blocking** (the route to the node's AS is black-holed). | Rotate IP/AS per `rotate-ip-as.md`; a restart will not help a black-holed route. |
| **TLSCertExpirySoon** | leaf cert NotAfter `< 14d` for 1h | The donor/cover certificate is about to expire; an expired cert breaks the relayed handshake and makes the endpoint distinguishable. | Renew or rotate the donor/cover before expiry. |
| **TLSCertExpired** | leaf cert NotAfter `<= now` for 5m | The cert has expired; the relayed handshake is broken and the endpoint is distinguishable. | Renew / rotate immediately. |
| **BlackboxExporterDown** | Prometheus up but no handshake probes present for 5m | The reachability detector itself is blind — the main Phase-0 interference signal is missing. | Check blackbox_exporter and `targets/blackbox_handshake.json`. |

### Reading the signals together

The two blackbox modules are designed to be compared:

- **TCP connects, TLS fails** → handshake-layer interference (network degradation / active probing / RST
  injection). Rotating SNI / donor / port often helps; rotate IP/AS if it persists.
- **TCP also fails** → AS-level blocking. The IP/AS itself is the problem — rotate it.
- **node_exporter also down** → it is a host outage, not a network event. Fix the host first.

This triage is exactly what the **Phase-2 adaptation layer** automates: the network-state
detector classifies the channel as `clean / throttled / blocked / shutdown` from these same
probe-success, byte-counter, and reachability signals, and the auto-rotation loop acts on the
verdict. Phase 0 ships the measurements and the manual runbook; Phase 2 closes the loop.

## YAML / JSON validity

- `prometheus.yml`, `rules.yml`, `alertmanager.yml`, `blackbox.yml` — well-formed YAML; verify
  with `promtool`/`amtool` where available (e.g. `promtool check config prometheus.yml`,
  `promtool check rules rules.yml`, `amtool check-config alertmanager.yml`).
- `targets/*.json.example` — well-formed JSON; verify with `jq . <file>`.

## Related

- [`../docs/runbooks/rotate-ip-as.md`](../docs/runbooks/rotate-ip-as.md) — IP/AS migration after a
  blocking event (the action for HighHandshakeFailureRate / NodeTCPUnreachable).
- [`../docs/runbooks/deploy-node.md`](../docs/runbooks/deploy-node.md) — deploy/restore a node.
- [`../infra/ansible/roles/observability`](../infra/ansible/roles/observability) — installs the
  loopback-bound node_exporter on the node.
- [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) — Layer 2 (control plane + adaptation).
