<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Data plane — sing-box multi-protocol engine (PRIMARY)

Author: mindicator & silicon bags quartet

> Mycelium is resilient private connectivity for communities, researchers, journalists, NGOs,
> families, distributed teams, and infrastructure operating over unreliable networks.

This directory holds the **primary** data-plane engine of a Mycelium node: a single `sing-box`
process that terminates many transport "dialects" at once. The design goal is **statistical
indistinguishability** from ordinary HTTPS/QUIC: a connection to the node should look like a
genuine browser session to a real external site, and active probing should receive a legitimate
response. Running several transports in parallel means that when one path degrades on a given
network, another can carry traffic from the same node.

The full inbound list, ports, SENTINELs, and `group_vars` toggles live in
[`protocols.md`](protocols.md). Each protocol is **individually toggleable** so an operator exposes
only the subset they choose.

## Engine overview

| Engine | Directory | Role | Scope |
|---|---|---|---|
| **sing-box** | this directory | **PRIMARY** — one server, many protocols | All Phase-0 TLS/QUIC transports (see `protocols.md`) |
| Xray-core | [`../vless-reality/`](../vless-reality/) | **Optional alternative** | The single VLESS+REALITY inbound (and the only path for genuine XHTTP) |
| AmneziaWG | separate component | **Separate non-TLS / UDP path** | Obfuscated WireGuard; not a sing-box inbound |

sing-box and Xray are **alternatives**, not co-running engines: pick one per node. AmneziaWG is a
distinct UDP path that runs alongside whichever TLS engine you choose.

The protocol set deliberately uses only modern, hard-to-fingerprint transports and **excludes**
legacy/easily-fingerprinted ones (VMess, pre-2022 Shadowsocks, plain WireGuard, OpenVPN,
L2TP/IPsec, PPTP, SSTP, IKEv2).

## Pinned version

- **sing-box: `v1.11.8`** (minimum `1.11.x`; this is the latest patch in the 1.11 series). Pin the
  deployed binary to this concrete tag — do not float to `latest`. REALITY/transport wire behaviour
  and config field names evolve between minor versions, and reproducible deployment (a Phase-0
  acceptance criterion) requires a fixed tag. Pin by version **and** by the upstream release SHA256,
  and record the exact deployed tag in the node's `state/` directory at deploy time. Updating this
  pin is a separate, verified change.

> Note: at the time of writing, sing-box has newer minor series (1.13.x). The 1.11.x series is
> pinned here as the project's tested floor; bumping to a newer minor is a deliberate, reviewed
> migration, not an automatic upgrade, because transport schemas change across minors.

## No custom cryptography (ADR-0002)

All key material is produced by audited, built-in generators — **never hand-rolled**:

- **REALITY X25519 keypair** comes from `sing-box generate reality-keypair` (prints a private and a
  matching public key). The **private** key goes into the server config; the **public** key is
  handed to clients as part of the standard endpoint parameters.
- **REALITY `short_id`** values are random hex strings from `openssl rand -hex 8`.
- **Shadowsocks-2022 / ShadowTLS PSKs** come from `openssl rand -base64 32` (32 bytes for the
  `2022-blake3-aes-256-gcm` method).
- **Hysteria2 obfuscation / Clash-API secrets** come from `openssl rand`.
- **Client UUIDs** come from `sing-box generate uuid`.

See [`../../../docs/adr/0002-no-custom-cryptography.md`](../../../docs/adr/0002-no-custom-cryptography.md).

## License note (why there is no header in the `.json`)

`server.template.json` is **pure JSON** consumed by `jq` (to fill sentinels) and by `sing-box`
(to load the config). JSON has no comment syntax, so embedding the AGPL header inside the file
would make it invalid and break both tools. The license therefore lives here instead:

> Copyright © 2026 mindicator & silicon bags quartet.
> SPDX-License-Identifier: AGPL-3.0-or-later
> This file (`server.template.json`) is part of Mycelium, licensed under the GNU Affero General
> Public License v3.0 or later. See the `LICENSE` file in the repository root.

## How `myceliumctl` fills the sentinels

`server.template.json` ships with **sentinel** string values (`SENTINEL_*`) so it stays valid JSON
(and `jq`-fillable) while carrying no secrets. The control tool `myceliumctl`
([`../../../control/`](../../../control/)) renders a real, deploy-only `server.json` — which lands
under a **gitignored** path (`state/`, `secrets/`, `out/`, or `server.json` itself, never committed)
— by editing the config **by `jq` path** (it never string-splices secrets into the file):

- For each REALITY inbound: `tls.reality.private_key`, `tls.reality.short_id[]`,
  `tls.server_name` / `tls.reality.handshake.server` ← the donor values + generated keys.
- Per-protocol secrets (`SENTINEL_SS2022_SERVER_PASSWORD`, `SENTINEL_SHADOWTLS_SS_PASSWORD`,
  `SENTINEL_HYSTERIA2_OBFS_PASSWORD`, `SENTINEL_CLASH_API_SECRET`, the TLS cert/key paths, the gRPC
  service name and XHTTP path) ← generated or operator-supplied values from the params file.
- `users[]` arrays (shipped empty) ← one object per identity from the identity state, so identities
  are issued and revoked **without redeploying the node**.

Disabled protocols (their `group_vars` toggle set `false`) are dropped from the rendered config and
their ports are never opened by the hardening role. The full SENTINEL ⇄ source ⇄ toggle mapping is
in [`protocols.md`](protocols.md).

## Donor / SNI guidance for the REALITY inbounds — TODO at deploy time

REALITY does not present its own certificate. Instead it **borrows the TLS handshake of a real
external site** — the *donor*. When a client (or an active prober) connects, the node relays the
genuine TLS 1.3 handshake of the donor, so the certificate, SNI, and handshake all belong to a
legitimate third-party site. Authorised clients upgrade the session to the tunnel; anyone else
(including a prober) just gets a real, working session to the donor.

`SENTINEL_DONOR_HOST` and `SENTINEL_DONOR_SNI` are left as a deliberate **TODO** — there is no safe
default. Pick a donor that satisfies **all** of:

- [ ] **Real, popular, always-up external site**, so active probing receives a legitimate response.
- [ ] **Serves TLS 1.3 and HTTP/2** (negotiates `h2` via ALPN). Verify with
      `openssl s_client -connect host:443 -alpn h2 -tls1_3` and confirm `ALPN protocol: h2`.
- [ ] **NOT hosted on your own provider / AS.** The donor must be independent infrastructure;
      reusing your own hosting undermines the cover and links the node to its own egress.
- [ ] **Not a CDN edge you also use**, and ideally operationally close to the node so latency to the
      donor is low and the relayed handshake looks natural.
- [ ] **`server_name` / `handshake.server` match what the donor actually serves.** `server_name` is
      the SNI the node accepts and presents; `handshake.server:server_port` is what the node dials
      to fetch that handshake — usually the same hostname on `:443`.

Diversify donors, SNI values, ports, IPs, and ASes across the fleet (see
[`../../../docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md) Layer 1): blocking can occur at the
AS level, so a single shared donor is a single point of failure.

The genuine-cert TLS inbounds (Hysteria2 / TUIC / Trojan) do **not** use REALITY; they present a
real certificate for the node's own TLS hostname (`SENTINEL_TLS_SERVER_NAME`), issued by the cover /
ACME tooling. ShadowTLS reuses the donor as its outer `handshake.server`.

## Observability (loopback only)

The template enables `experimental.clash_api` bound to `127.0.0.1:9090` with a `SENTINEL`-filled
`secret`. This is the chosen observability surface because it is the sing-box-native, documented way
to read connection counts and aggregate traffic for node liveness/health (Phase-0 basic
observability) **without** attributing traffic to individual identities or destinations. It is bound
to loopback only and **must never be exposed publicly**; scrape it locally (e.g. via an exporter on
the node). No per-connection identity logging is performed anywhere in this config.

## Privacy / logging

- `log` is `{ level: "warn", timestamp: true }` with **no access log** — user connections, client
  IPs, and destinations are never recorded (privacy / threat-model requirement).
- `route` blocks traffic to **private / loopback IP ranges** (`ip_is_private`), preventing the node
  from being used to reach internal hosts; `final` is `direct` for normal egress, with a `block`
  outbound available.

## Templates in this directory (licensing)

Both templates are **pure JSON** (no comment syntax), so they carry **no inline license header**;
their license is the repository AGPL-3.0-or-later, documented here per the project convention.

- `server.template.json` — the historical canonical template. **Note:** its inbound `tag`s use the
  long forms (`tuic-v5-in`, `shadowsocks-2022-in`, `shadowtls-v3-in`, `shadowtls-shadowsocks-in`,
  `trojan-tls-in`), which **do not match** the tag set the `myceliumctl` renderer fills/keeps
  (`tuic-in`, `shadowsocks-in`, `shadowtls-in`, `shadowtls-ss-in`, `trojan-in`). Rendering this
  template with the current renderer would silently drop TUIC/Shadowsocks/ShadowTLS/Trojan. This is
  a known divergence to reconcile into one source.
- `server.template.renderer.json` — a **renderer-compatible** template (uses the renderer's `-in`
  tag set, listens on `::` for dual-stack) shipped so the on-node
  [`scripts/node-bootstrap.sh`](../../../scripts/node-bootstrap.sh) can render the canonical config
  through the existing pipeline today. Port values match [`../PORTS.md`](../PORTS.md). Until the two
  templates above are unified, the bootstrap points `--template` at this one.

## Validate

```sh
jq . server.template.json            # must parse cleanly (no secrets, only SENTINEL_* values)
jq . server.template.renderer.json   # renderer-compatible variant; same rule
```
