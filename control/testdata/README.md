<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# `control/testdata` — fixtures for `selftest.sh`

Author: mindicator & silicon bags quartet.

## `server.template.json`

A minimal, standalone VLESS + XTLS-Vision + REALITY server template used so that
`control/selftest.sh` can exercise `render-server` without depending on the dataplane component.
It mirrors the shape of the production template at
`../../nodes/dataplane/vless-reality/server.template.json` (the dataplane component owns the
authoritative one).

This is **pure JSON** and therefore carries **no comment header** — it must stay valid for `jq` and
`xray`. Its license is documented here, per the repository convention for functional JSON.

It contains **no secrets**. Every sensitive value is a non-functional sentinel that `render-server`
overwrites by `jq` path at render time:

| Path | Sentinel | Replaced by |
|---|---|---|
| `inbounds[0].streamSettings.realitySettings.privateKey` | `REALITY_PRIVATE_KEY_PLACEHOLDER` | `params.reality_private_key` |
| `inbounds[0].streamSettings.realitySettings.shortIds[0]` | `SHORT_ID_PLACEHOLDER` | `params.short_ids` |
| `inbounds[0].streamSettings.realitySettings.serverNames[0]` | `DONOR_SNI_PLACEHOLDER` | `[ params.donor_sni ]` |
| `inbounds[0].streamSettings.realitySettings.dest` | `DONOR_HOST_PLACEHOLDER:443` | `params.dest` (default `donor_host:443`) |

The sentinels must never appear in a rendered `server.json`; `selftest.sh` asserts the private-key
placeholder is gone after rendering.

## `singbox.server.template.json`

A standalone **multi-protocol sing-box** server template used so that `control/selftest.sh` can
exercise the sing-box engine (`render-server --engine singbox` and the multi-protocol
`subscription --engine singbox`) without depending on the dataplane component. It mirrors the
shape of the production template the dataplane component owns at
`../../nodes/dataplane/singbox/server.template.renderer.json` (the dataplane component owns the
authoritative one; the tool's `--engine singbox` default points there).

It is **pure JSON** and therefore carries **no comment header** — it must stay valid for `jq` and
`sing-box`. Its license is documented here, per the repository convention for functional JSON.

It contains **no secrets**. It declares one inbound per protocol; every sensitive value is a
non-functional sentinel that `render-server` overwrites by `jq` path at render time, and inbounds
whose `<proto>_enabled` flag is not `true` in params are pruned from the rendered output.

| Inbound `tag` | Protocol | Sentinels filled |
|---|---|---|
| `vless-reality-vision-in` | VLESS + REALITY + XTLS-Vision (TCP) | `tls.reality.private_key`, `tls.reality.short_id[]`, `tls.server_name`, `tls.reality.handshake.server`, `users[]` |
| `vless-reality-grpc-in` | VLESS + REALITY + gRPC | as above + `transport.service_name` |
| `vless-reality-xhttp-in` | VLESS + REALITY + XHTTP | as above + `transport.path` |
| `hysteria2-in` | Hysteria2 (QUIC/UDP) | `tls.server_name`, `tls.certificate_path`, `tls.key_path`, `users[].password` |
| `tuic-in` | TUIC v5 (QUIC/UDP) | as Hysteria2 + per-user `uuid`/`password` |
| `shadowsocks-in` | Shadowsocks-2022 AEAD | `password`, `users[]` |
| `shadowtls-in` + `shadowtls-ss-in` | ShadowTLS v3 wrapping Shadowsocks | `handshake.server`, `users[].password`, inner SS `password` |
| `trojan-in` | Trojan over TLS | `tls.*`, `users[].password` |

The sentinels (`SENTINEL_REALITY_PRIVATE_KEY`, `SENTINEL_SHORTID`, `SENTINEL_DONOR_SNI`,
`SENTINEL_DONOR_HOST`, `SENTINEL_TLS_SNI`, `SENTINEL_TLS_CERT_PATH`, `SENTINEL_TLS_KEY_PATH`,
`SENTINEL_SS_PASSWORD`, `SENTINEL_GRPC_SERVICE_NAME`, `SENTINEL_XHTTP_PATH`) must never appear in a
rendered config; `selftest.sh` asserts the REALITY private-key sentinel is gone after rendering.
