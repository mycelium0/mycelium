<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Data plane

Per-node transport components and the values shared across them.

- [`PORTS.md`](PORTS.md) — the single source of truth for every listen port.
- [`singbox/`](singbox/) — the PRIMARY engine (one server, many toggleable protocols).
- [`vless-reality/`](vless-reality/) — the optional Xray-core alternative.
- [`amneziawg/`](amneziawg/) — the separate, non-TLS / UDP obfuscated path.
- `donor-sni-candidates.json` — see below.

## `donor-sni-candidates.json` (licensing + purpose)

This file is **pure JSON** (no comment syntax), so it carries **no inline license header**; its
license is the repository AGPL-3.0-or-later, documented here per the project convention.

It is a curated list of **public** REALITY donor-SNI candidate hostnames. The on-node
[`scripts/node-bootstrap.sh`](../../scripts/node-bootstrap.sh) picks **one at random per node** and
verifies it at runtime — `openssl s_client -groups x25519 -tls1_3` must negotiate TLSv1.3 — before
committing it to that node's local config. Picking randomly per node diversifies the donor across
the network so nodes do not share one fingerprintable handshake target.

Rules for entries: **public hostnames only**. No secrets, no IPs, no locations, no jurisdiction
names. Add or prune candidates as upstreams change; each must be a real, reachable host that
terminates TLSv1.3 over an X25519 group.
