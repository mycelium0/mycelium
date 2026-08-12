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

- **sing-box:** the concrete pin lives in **`control/engines.manifest.json`** — that file is the
  single source of truth, and the deploy path fills it in as the default `--singbox-version` /
  `--singbox-sha256` when the operator passes no flag (`control/lib/nb_install.sh`). At the time of
  writing it pins **`v1.13.13`**; the enforced currency floor is **`v1.13.0`**
  ([ADR-0028](../../../docs/adr/0028-dependency-and-transport-currency-policy.md)).
  Do not float to `latest` and do not restate a literal tag here: REALITY/transport wire behaviour
  and config field names evolve between minor versions, and reproducible deployment (a Phase-0
  acceptance criterion) requires a fixed, checksum-verified tag. Updating the pin is a separate,
  verified change.

> Note: passing `--singbox-version` for a DIFFERENT tag without also passing the matching
> `--singbox-sha256` will fail closed — the manifest's checksum is filled in as the default and will
> not match the archive you asked for. Change both together, or change the manifest.

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

`server.template.renderer.json` is **pure JSON** consumed by `jq` (to fill sentinels) and by
`sing-box` (to load the config). JSON has no comment syntax, so embedding the AGPL header inside the
file would make it invalid and break both tools. The license therefore lives here instead:

> Copyright © 2026 mindicator & silicon bags quartet.
> SPDX-License-Identifier: AGPL-3.0-or-later
> This file (`server.template.renderer.json`) is part of Mycelium, licensed under the GNU Affero
> General Public License v3.0 or later. See the `LICENSE` file in the repository root.

## How `myceliumctl` fills the sentinels

`server.template.renderer.json` ships with **sentinel** string values (`SENTINEL_*`) so it stays
valid JSON (and `jq`-fillable) while carrying no secrets. The control tool `myceliumctl`
([`../../../control/`](../../../control/)) renders a real, deploy-only `server.json` — which lands
under a **gitignored** path (`state/`, `secrets/`, `out/`, or `server.json` itself, never committed)
— by editing the config **by `jq` path** (it never string-splices secrets into the file):

- For each REALITY inbound: `tls.reality.private_key`, `tls.reality.short_id[]`,
  `tls.server_name` / `tls.reality.handshake.server` ← the donor values + generated keys.
- Per-protocol material — the sentinels the template actually carries: `SENTINEL_SS_PASSWORD`,
  `SENTINEL_REALITY_PRIVATE_KEY`, `SENTINEL_SHORTID`, `SENTINEL_TLS_SNI`, `SENTINEL_TLS_CERT_PATH`,
  `SENTINEL_TLS_KEY_PATH`, `SENTINEL_GRPC_SERVICE_NAME`, `SENTINEL_XHTTP_PATH`, `SENTINEL_WS_PATH`,
  `SENTINEL_DONOR_HOST`, `SENTINEL_DONOR_SNI` ← generated or operator-supplied values from the params
  file. (The remaining per-protocol passwords and the `clash_api` secret are injected at render time
  from the identity/secrets state, not carried as sentinels in this template.)
- `users[]` arrays (shipped empty) ← one object per identity from the identity state, so identities
  are issued and revoked **without redeploying the node** — on the UUID-keyed families. Hysteria2,
  ShadowTLS, Trojan and Shadowsocks build their users as `(.password // $pw)` with a node-wide `$pw`,
  so a revoked person keeps that credential and keeps access
  ([ADR-0040 §2.1](../../../docs/adr/0040-a-fungi-serves-several-people.md)).

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

Diversify donors, SNI values, ports, IPs, and ASes across the network (see
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

## Template in this directory (licensing)

The template is **pure JSON** (no comment syntax), so it carries **no inline license header**; its
license is the repository AGPL-3.0-or-later, documented here per the project convention.

- `server.template.renderer.json` — the single canonical sing-box server template. It uses the
  renderer's `-in` inbound tag set (`vless-reality-vision-in`, `vless-xhttp-tls-in`, `tuic-in`,
  `shadowsocks-in`, `shadowtls-in`, `shadowtls-ss-in`, `trojan-in`, …) that `myceliumctl` and
  `render_singbox.sh` fill/keep, and listens on `::` for dual-stack. The on-node
  [`scripts/node-bootstrap.sh`](../../../scripts/node-bootstrap.sh) renders the deployed config from
  it, and `myceliumctl render-server --engine singbox` defaults to it. Port values match
  [`../PORTS.md`](../PORTS.md).

  > Historical note: an earlier `server.template.json` carried long-form inbound tags
  > (`tuic-v5-in`, `shadowsocks-2022-in`, `shadowtls-v3-in`, `trojan-tls-in`) the renderer never
  > matched and lacked `vless-xhttp-tls-in`. It has been **removed** — there is now ONE sing-box
  > server template, closing RP-0003 §W5.

## Validate

```sh
jq . server.template.renderer.json   # must parse cleanly (no secrets, only SENTINEL_* values)
```
