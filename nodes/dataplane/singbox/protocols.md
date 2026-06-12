<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Protocol map — sing-box multi-protocol data plane (PRIMARY engine)

Author: mindicator & silicon bags quartet

This is the **primary** data-plane engine for a Mycelium node: a single `sing-box` process that
terminates many transport "dialects" at once. The optional alternative engine —
[`../vless-reality/`](../vless-reality/) (Xray-core) — covers only the single VLESS+REALITY inbound
and exists for operators who prefer Xray or who need an Xray-only feature (e.g. true XHTTP, see the
note below). The two engines are not run side by side on the same ports; an operator picks one
engine per node.

Every inbound is **individually toggleable** via `group_vars` so an operator exposes only the
subset they want. A protocol with its toggle set `false` is omitted from the rendered
`server.json` by `myceliumctl` and its port is never opened by the hardening role. The toggle
names below are the canonical names the infra/control layers consume.

## Inbound table

| # | Protocol / inbound tag | sing-box `type` + transport | Default port | SENTINELs it needs | `group_vars` toggle |
|---|---|---|---|---|---|
| 1 | VLESS + REALITY + XTLS-Vision (`vless-reality-vision-in`) | `vless`, TCP (no v2ray transport), `tls.reality` | `tcp/443` | `SENTINEL_DONOR_SNI`, `SENTINEL_DONOR_HOST`, `SENTINEL_REALITY_PRIVATE_KEY`, `SENTINEL_REALITY_SHORT_ID` | `enable_vless_reality_vision` |
| 2 | VLESS + REALITY + gRPC (`vless-reality-grpc-in`) | `vless`, `transport.type: grpc`, `tls.reality` | `tcp/8443` | `SENTINEL_DONOR_SNI`, `SENTINEL_DONOR_HOST`, `SENTINEL_REALITY_PRIVATE_KEY`, `SENTINEL_REALITY_SHORT_ID`, `SENTINEL_GRPC_SERVICE_NAME` | `enable_vless_reality_grpc` |
| 3 | VLESS + REALITY + XHTTP (`vless-reality-xhttp-in`) | `vless`, `transport.type: http`, `tls.reality` | `tcp/2096` | `SENTINEL_DONOR_SNI`, `SENTINEL_DONOR_HOST`, `SENTINEL_REALITY_PRIVATE_KEY`, `SENTINEL_REALITY_SHORT_ID`, `SENTINEL_XHTTP_PATH` | `enable_vless_reality_xhttp` |
| 4 | Hysteria2 (`hysteria2-in`) | `hysteria2`, QUIC/UDP, `obfs.salamander` + `tls` | `udp/8444` | `SENTINEL_HYSTERIA2_OBFS_PASSWORD`, `SENTINEL_HYSTERIA2_MASQUERADE_URL`, `SENTINEL_TLS_SERVER_NAME`, `SENTINEL_TLS_CERTIFICATE_PATH`, `SENTINEL_TLS_KEY_PATH` | `enable_hysteria2` |
| 5 | TUIC v5 (`tuic-v5-in`) | `tuic`, QUIC/UDP, `tls` | `udp/8445` | `SENTINEL_TLS_SERVER_NAME`, `SENTINEL_TLS_CERTIFICATE_PATH`, `SENTINEL_TLS_KEY_PATH` | `enable_tuic` |
| 6 | Shadowsocks-2022 AEAD (`shadowsocks-2022-in`) | `shadowsocks`, `2022-blake3-aes-256-gcm`, TCP+UDP | `tcp+udp/8388` | `SENTINEL_SS2022_SERVER_PASSWORD` | `enable_shadowsocks_2022` |
| 7 | ShadowTLS v3 → Shadowsocks (`shadowtls-v3-in` + `shadowtls-shadowsocks-in`) | `shadowtls` v3 outer + `detour` to a loopback `shadowsocks` inbound | `tcp/8843` (outer); inner is loopback-only | `SENTINEL_DONOR_HOST` (handshake target), `SENTINEL_SHADOWTLS_SS_PASSWORD` | `enable_shadowtls` |
| 8 | Trojan over TLS (`trojan-tls-in`) — optional | `trojan`, TCP, `tls` | `tcp/8447` | `SENTINEL_TLS_SERVER_NAME`, `SENTINEL_TLS_CERTIFICATE_PATH`, `SENTINEL_TLS_KEY_PATH` | `enable_trojan` |

Notes on the table:

- **Ports are defaults, not constants.** Port/SNI/donor diversification is a Layer-1 design goal
  (see [`../../../docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md)); the rendered ports are
  fed from `group_vars` and should differ across a fleet. `tcp/443` is reserved for the Vision
  inbound because port 443 maximises indistinguishability from ordinary HTTPS.
- **`users` are filled at deploy.** Every VLESS/TUIC/Trojan/Hysteria2/ShadowTLS inbound ships with
  `users: []`; identities (UUIDs/passwords) are issued and revoked by the control plane
  (`myceliumctl`) without redeploying the node. Shadowsocks-2022 uses a single server `password`.
- **ShadowTLS is a pair.** The public `shadowtls-v3-in` inbound performs the TLS-like outer
  handshake against the donor (`handshake.server`) and forwards the decrypted stream over `detour`
  to the loopback-only `shadowtls-shadowsocks-in`. The inner Shadowsocks inbound has **no
  `listen_port`** and binds to `127.0.0.1`, so it is never reachable directly from the network.
- **Two REALITY listeners (`tcp/443` vs others) and the QUIC listeners can coexist.** UDP transports
  (Hysteria2, TUIC) are provisioned but, per the roadmap, are not relied on as the primary route
  because UDP is excised entirely in some network environments.

## SENTINEL reference

| SENTINEL | Meaning | Source at deploy time |
|---|---|---|
| `SENTINEL_DONOR_SNI` | Donor SNI presented/accepted by the REALITY inbounds (the donor's hostname). | operator choice (see README "Donor / SNI guidance") |
| `SENTINEL_DONOR_HOST` | Donor handshake target host for `tls.reality.handshake.server` and the ShadowTLS `handshake.server`. | operator choice |
| `SENTINEL_REALITY_PRIVATE_KEY` | REALITY X25519 **private** key (server side). | `sing-box generate reality-keypair` (audited built-in) |
| `SENTINEL_REALITY_SHORT_ID` | REALITY short ID (hex, 0–8 bytes). | `openssl rand -hex 8` |
| `SENTINEL_GRPC_SERVICE_NAME` | gRPC service name path for the gRPC transport. | operator choice (a plausible, boring path) |
| `SENTINEL_XHTTP_PATH` | HTTP transport request path for the XHTTP-style inbound. | operator choice |
| `SENTINEL_HYSTERIA2_OBFS_PASSWORD` | Salamander obfuscation password for Hysteria2. | `openssl rand -base64 24` |
| `SENTINEL_HYSTERIA2_MASQUERADE_URL` | URL Hysteria2 masquerades unauthenticated requests to (e.g. a real site). | operator choice |
| `SENTINEL_TLS_SERVER_NAME` | TLS SNI for the genuine-cert TLS inbounds (Hysteria2/TUIC/Trojan). | the node's own TLS hostname |
| `SENTINEL_TLS_CERTIFICATE_PATH` | Path to the TLS certificate (PEM) on the node for the genuine-cert inbounds. | issued by the cover/ACME tooling (gitignored on node) |
| `SENTINEL_TLS_KEY_PATH` | Path to the TLS private key (PEM) on the node. | issued by the cover/ACME tooling (gitignored on node) |
| `SENTINEL_SS2022_SERVER_PASSWORD` | Shadowsocks-2022 server PSK (base64, 32 bytes for `aes-256-gcm`). | `openssl rand -base64 32` |
| `SENTINEL_SHADOWTLS_SS_PASSWORD` | PSK for the inner loopback Shadowsocks behind ShadowTLS. | `openssl rand -base64 32` |
| `SENTINEL_CLASH_API_SECRET` | Bearer secret for the loopback Clash API observability endpoint. | `openssl rand -hex 16` |

## Why XHTTP uses the `http` transport here (engine boundary)

`XHTTP` (a.k.a. SplitHTTP) is an **Xray-core** transport and is **not** available in the pinned
sing-box 1.11.x series. In sing-box the closest-equivalent HTTP-framed VLESS+REALITY inbound is the
v2ray `http` transport (`transport.type: "http"`), which is what inbound #3 uses — it gives an
HTTP/2-style framing that survives many networks where bare TCP-TLS does not. Operators who require
the genuine XHTTP wire format should run the **optional Xray engine** for that one inbound
([`../vless-reality/`](../vless-reality/)); the rest of the protocol set still runs on sing-box.

## Out of this engine: AmneziaWG (separate non-TLS / UDP path)

AmneziaWG (obfuscated WireGuard) is item (9) of the Phase-0 protocol set but is **deliberately not
a sing-box inbound** — sing-box does not speak the AmneziaWG obfuscation dialect. It is a separate
non-TLS, UDP data path with its own component, its own toggle (`enable_amneziawg`), and its own key
material (`awg genkey` / `wg genkey`). It is listed here only so the full Phase-0 set is accounted
for; nothing in this directory configures it.
