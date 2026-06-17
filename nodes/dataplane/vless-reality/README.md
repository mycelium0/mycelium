<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Data plane — VLESS + XTLS-Vision + REALITY

Author: mindicator & silicon bags quartet

This directory holds the **primary transport** of a Mycelium Phase 0 node: an Xray-core inbound
speaking VLESS with the XTLS-Vision flow, wrapped in REALITY. The design goal is **statistical
indistinguishability** from ordinary TLS 1.3 traffic to a real, popular external site. To a network
adversary running behavioral-layer detection or active probing, a connection to this node is meant to be
indistinguishable from a genuine browser session to that external donor site.

## License note (why there is no header in the `.json`)

`server.template.json` is **pure JSON** consumed by `jq` (to fill sentinels) and by `xray run`
(to load the config). JSON has no comment syntax, so embedding the AGPL header inside the file
would make it invalid and break both tools. The license therefore lives here instead:

> Copyright © 2026 mindicator & silicon bags quartet.
> SPDX-License-Identifier: AGPL-3.0-or-later
> This file (`server.template.json`) is part of Mycelium, licensed under the GNU Affero General
> Public License v3.0 or later. See the `LICENSE` file in the repository root.

## Pinned versions

- **xray-core: `v26.2.4`** (minimum). Pin the deployed binary to a concrete recent tag at or
  above this version. Do not float to `latest`: REALITY/Vision wire behaviour and config field
  names evolve, and reproducible deployment (Phase 0 acceptance criterion) requires a fixed tag.
  Record the exact deployed tag in the node's `state/` directory at deploy time.

## No custom cryptography (ADR-0002)

All key material is produced by audited, built-in generators — **never hand-rolled**:

- **REALITY X25519 keypair** comes from `xray x25519`. The command prints a private key and the
  matching public key. The **private** key goes into the server config; the **public** key is
  handed to clients (it is part of the standard endpoint parameters).
- **Client UUIDs** come from `xray uuid`.
- **`shortIds`** are random hex strings produced by `openssl rand -hex <n>` (1–8 bytes → 2–16 hex
  chars; an empty string is also valid and means "accept any"). We deploy explicit short IDs.

## How the template is filled

`server.template.json` ships with **sentinel** string values so it stays valid JSON (and
`jq`-fillable) while carrying no secrets. The `myceliumctl` tool renders a real, deploy-only
`server.json` (which lands under a gitignored path — `state/`, `secrets/`, `out/`, or
`server.json` itself — never committed) by replacing:

| Sentinel | Filled with | Source |
|---|---|---|
| `SENTINEL_REALITY_PRIVATE_KEY` | the node's REALITY X25519 private key | `xray x25519` |
| `SENTINEL_SHORTID` | one or more random short IDs | `openssl rand -hex` |
| `SENTINEL_DONOR_SNI` | the donor site's hostname(s) (`serverNames`) | operator choice (see below) |
| `SENTINEL_DONOR_HOST:443` | the donor handshake target (`dest`) | operator choice (see below) |
| `clients[]` | one object per identity, each with `id` (a `xray uuid`) and `flow: "xtls-rprx-vision"` | `xray uuid` + identity layer |

The shipped `clients` array is **empty** on purpose: identities are issued and revoked by the
control plane without redeploying the node. Each client object myceliumctl appends MUST carry the
XTLS-Vision flow, i.e.:

```json
{ "id": "<xray uuid>", "flow": "xtls-rprx-vision" }
```

## Choosing a DONOR (handshake target) — TODO at deploy time

REALITY does not present its own certificate. Instead it **borrows the TLS handshake of a real
external site** — the *donor*. When a client (or an active prober) connects, the node relays the
genuine TLS 1.3 handshake of the donor, so the certificate, SNI, and handshake all belong to a
legitimate third-party site. Authorised clients then upgrade the session to the tunnel; anyone
else (including a prober) just gets a real, working session to the donor.

Pick a donor that satisfies **all** of the following. The sentinels `SENTINEL_DONOR_HOST` and
`SENTINEL_DONOR_SNI` are deliberately left as a clear **TODO** — there is no safe default:

- [ ] **Real, popular, always-up external site.** Active probing must receive a legitimate
      response, so the target has to be a site that genuinely exists and stays reachable.
- [ ] **Serves TLS 1.3.** REALITY requires a TLS 1.3 handshake to mirror.
- [ ] **Serves HTTP/2** (negotiates `h2` via ALPN). Verify with
      `openssl s_client -connect host:443 -alpn h2 -tls1_3` and confirm `ALPN protocol: h2`.
- [ ] **NOT hosted on your own provider / AS.** The donor must be independent infrastructure;
      reusing your own hosting undermines the cover and links the node to its own egress.
- [ ] **Not a CDN edge you also use**, and ideally geographically/operationally close to the node
      so latency to the donor is low and the relayed handshake looks natural.
- [ ] **`serverNames` matches what the donor actually serves.** `serverNames` is the set of SNI
      values the node will accept and present; every entry must be a hostname the donor terminates
      TLS for. `dest` is the `host:port` the node dials to fetch that handshake — usually the same
      hostname on `:443`.

Diversify donors, SNI values, ports, IPs, and ASes across the network (see ARCHITECTURE.md Layer 1):
blocking can occur at the AS level, so a single shared donor is a single point of failure.

## REALITY fields explained (`streamSettings.realitySettings`)

- **`show`** — verbose REALITY debug logging. `false` in production (keeps logs quiet and avoids
  leaking handshake detail into logs).
- **`dest`** — the donor handshake target as `host:port`. The node dials this to obtain the real
  TLS 1.3 handshake it relays. Template: `SENTINEL_DONOR_HOST:443`.
- **`xver`** — PROXY-protocol version prepended toward `dest`. `0` = disabled; use a non-zero
  value only when the donor backend expects the PROXY protocol (it normally does not).
- **`serverNames`** — the allowed/presented SNI values. Must be hostname(s) the donor actually
  serves TLS for. Template: `["SENTINEL_DONOR_SNI"]`.
- **`privateKey`** — the node's REALITY X25519 **private** key from `xray x25519`. The matching
  public key is distributed to clients. Template: `SENTINEL_REALITY_PRIVATE_KEY`.
- **`shortIds`** — list of accepted short IDs (hex, even length, ≤ 16 chars). Each client presents
  one of these; it lets the node distinguish authorised clients from random TLS to the donor.
  Generate with `openssl rand -hex`. Template: `["SENTINEL_SHORTID"]`.

## Other config sections

- **`log`** — `loglevel: "warning"` and **no access log**. User traffic is never logged
  (privacy / threat-model requirement: do not record client connections, IPs, or destinations).
- **`inbounds[0].settings`** — `decryption: "none"` (mandatory for VLESS; VLESS has no transport
  encryption of its own — confidentiality comes from the TLS/REALITY layer).
- **`sniffing`** — `routeOnly: true` so domain sniffing is used only for routing decisions, not to
  rewrite or record destinations.
- **`api` inbound + `api` block + `stats` + `policy`** — a local-only observability surface.
  A `dokodemo-door` inbound bound to `127.0.0.1:10085` (tag `api`) exposes Xray's `StatsService`;
  `policy.system.statsInboundUplink/Downlink` enable per-inbound byte counters. Bind only to
  loopback — never expose the API port publicly. Per-user stats (`statsUserUplink/Downlink`) are
  left **off** at level 0 to avoid attributing traffic to individual identities.
- **`outbounds`** — `freedom` (tag `direct`) for normal egress and `blackhole` (tag `block`) to
  drop traffic.
- **`routing`** — sends the `api` inbound to the API handler, blocks traffic to **private IP
  ranges** (`geoip:private`, prevents the node from being used to reach internal hosts), and blocks
  `bittorrent` (optional, keeps the egress reputation clean). `domainStrategy: "AsIs"` avoids
  resolver-based leakage.

## Validate

```sh
jq . server.template.json   # must parse cleanly (no secrets, only sentinels)
```
