<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium — Canonical Port Registry

Author: mindicator & silicon bags quartet

**This file is the single source of truth for every data-plane listen port.** All
configuration (Ansible group vars and role defaults, the firewall rules, the sing-box server
template, and the `myceliumctl` standalone fallback defaults) MUST agree with the table below.
When a port needs to change, change it HERE first, then align every reference to match.

sing-box is the PRIMARY engine: one server process speaks every TLS transport listed below in
parallel, each individually toggleable so an operator exposes only a chosen subset. Xray is an
OPTIONAL alternative engine (VLESS + XTLS-Vision + REALITY only). AmneziaWG is a SEPARATE,
orthogonal UDP path handled by its own role.

## Canonical port map

| # | Protocol | Engine | Port | Proto | Default | Toggle | Notes |
|---|----------|--------|------|-------|---------|--------|-------|
| 1 | VLESS + REALITY + XTLS-Vision | sing-box | `443`   | tcp     | on  | `enable_vless_reality_vision` | Primary transport; equals `listen_port`. `443` maximises indistinguishability from ordinary HTTPS. |
| 2 | VLESS + REALITY + gRPC        | sing-box | `8443`  | tcp     | off | `enable_vless_reality_grpc`   | |
| 3 | VLESS + REALITY + XHTTP       | sing-box | `2096`  | tcp     | off | `enable_vless_reality_xhttp`  | XHTTP framing *inside* REALITY = TLS-in-TLS. |
| 3b | VLESS + XHTTP over genuine TLS | sing-box | `2087` | tcp     | off | `enable_vless_xhttp_tls`      | Genuine single-layer TLS with the node's OWN cert (NO reality). Distinct family from row 3 — survives links where TLS-in-TLS is blocked. **Deliberately not 8443** (a confirmed mobile tell); a node wanting `443` overrides per-node. NOTE: the `xhttp` transport is Xray-core only, so this family is NOT served by the sing-box engine (kept for a future Xray serving path); use row 3c for a genuine-TLS family that sing-box actually serves. |
| 3c | VLESS + WebSocket over genuine TLS | sing-box | `2089` | tcp     | off | `enable_vless_ws_tls`         | Genuine single-layer TLS with the node's OWN cert (NO reality), over sing-box's NATIVE WebSocket (`ws`) transport — so it IS servable on the primary engine (unlike row 3b). Same goal as row 3b (real single-layer TLS that survives TLS-in-TLS-blocked links), distinct family. **Deliberately not 8443**; a node wanting `443` overrides per-node. |
| 4 | Hysteria2                     | sing-box | `8444`  | udp     | off | `enable_hysteria2`            | QUIC. |
| 5 | TUIC v5                       | sing-box | `8445`  | udp     | off | `enable_tuic`                 | QUIC. |
| 6 | Shadowsocks-2022 AEAD         | sing-box | `8388`  | tcp+udp | off | `enable_ss2022`               | Opens BOTH tcp and udp when enabled. |
| 7 | ShadowTLS v3 → Shadowsocks    | sing-box | `8446`  | tcp     | off | `enable_shadowtls`            | Outer listener. The inner Shadowsocks detour is loopback-only (no public port). |
| 8 | Trojan over TLS               | sing-box | `8447`  | tcp     | off | `enable_trojan`               | |
| 9 | AmneziaWG (obfuscated WireGuard) | amneziawg | `51820` | udp  | off | `enable_amneziawg`            | Separate, non-TLS UDP path; own role. Diversify per node. |

The firewall opens ONLY the ports of the protocols that are enabled.

### Loopback-only ports (intentionally outside the public canon)

These ports are bound to `127.0.0.1` only and are **never opened by the host firewall**. They are
NOT part of the public data-plane canon above (they carry no public passive fingerprint), and they
deliberately do not reuse any canonical PUBLIC port number:

| Port | Bind | Role | Default |
|------|------|------|---------|
| `8443` | `127.0.0.1` | Caddy cover-site listener (REALITY `dest` forwards active probes here). `caddy_cover_listen`. | on |
| `8472` | `127.0.0.1` | Caddy served-distribution-bundle listener (`caddy_bundle_listen`); the operator fronts it via their own reach path. Outside the public canon on purpose so it never collides with a public listen port (e.g. `8444`/Hysteria2). | off |

## Where these values appear (all must match this table)

| File | Role |
|------|------|
| `nodes/dataplane/PORTS.md` | **This registry — the source of truth.** |
| `infra/ansible/group_vars/all.yml.example` | Operator-facing `singbox_port_*` and `awg_listen_port` defaults. |
| `infra/ansible/roles/singbox/defaults/main.yml` | Safe role defaults for `singbox_port_*` (used if a var is omitted). |
| `infra/ansible/roles/singbox/tasks/main.yml` | UFW rules — opens the enabled protocols' tcp / udp ports. |
| `infra/ansible/roles/amneziawg/defaults/main.yml` | `awg_listen_port` default for the separate UDP path. |
| `nodes/dataplane/singbox/server.template.renderer.json` | `listen_port` per inbound (the DEPLOYED template `node-bootstrap.sh` renders). |
| `control/lib/render_singbox.sh` | `myceliumctl` standalone fallback defaults (must equal the Ansible defaults). |
