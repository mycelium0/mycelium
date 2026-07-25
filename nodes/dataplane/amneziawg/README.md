<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Data plane — AmneziaWG (obfuscated WireGuard)

Author: mindicator & silicon bags quartet

This directory holds the **non-TLS / UDP fallback transport** of a Mycelium node: an
[AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) interface (`awg0`). AmneziaWG speaks the
WireGuard data protocol but adds **junk packets** and **header randomization** so the handshake no
longer matches a fixed WireGuard fingerprint. The goal is **indistinguishability** on unreliable
/ high-interference UDP paths — see [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md)
§Layer 1.

This path is **complementary**, not primary. The primary transports are the sing-box / Xray
**TLS** (VLESS + XTLS-Vision + REALITY) and **QUIC** (Hysteria2 / TUIC) protocols. AmneziaWG fills
the niche where those are degraded but UDP still flows: it is fast (~3 % overhead over plain
WireGuard). Its obfuscation dialect (H1..H4 + jitter) is **derived per node** from the node's own
AmneziaWG key (`derive_awg_dialect`, `control/lib/nb_render_awg.sh`) — server and every client of one
node share it while different nodes differ and the repo discloses none, so a repo-derived UDP
payload-match rule cannot block the family network-wide. The trade-off is that **UDP is
excised entirely on some networks**, so this path is provisioned as a fallback and never relied on
as the only route.

## What AmneziaWG adds over plain WireGuard

Plain WireGuard is excellent cryptographically but has a **static on-the-wire fingerprint**: the
first packet of a session is always a fixed-size (148-byte) handshake initiation, and the four
message types carry fixed 1-byte headers (`1`=init, `2`=response, `3`=cookie, `4`=transport
data). That regularity makes it cheap to recognize and block. AmneziaWG removes the regularity
without touching the cryptography:

- **Junk packets** (`Jc`, `Jmin`, `Jmax`) — before the real handshake, a peer sends `Jc`
  random-length, random-content packets (each between `Jmin` and `Jmax` bytes). This breaks the
  "the first packet is always a WireGuard handshake of size X" pattern.
- **Handshake-size randomization** (`S1`, `S2`) — random bytes are prepended to the handshake
  **init** (`S1`) and **response** (`S2`) messages, so those packets no longer match WireGuard's
  fixed sizes.
- **Header randomization** (`H1`..`H4`) — the four well-known message-type constants are replaced
  with four custom 32-bit values, removing the static header fingerprint.

These are **tunable knobs**, not constants: the adaptation layer (Layer 2) may A/B-tune them per
survivability feedback (see ARCHITECTURE §Layer 1 / ROADMAP Phase 2). They are **not secrets**,
but a node and all of its clients form one "dialect" — **every peer must share the identical
`Jc`/`Jmin`/`Jmax`/`S1`/`S2`/`H1`..`H4` values** or the handshake fails. Constraints to respect:
`Jmin < Jmax`, `H1`..`H4` are four distinct values, and `S1 + 56 ≠ S2`.

## Pinned version

- **AmneziaWG**: pin to a concrete release, not a moving branch. The Ansible role
  ([`infra/ansible/roles/amneziawg`](../../../infra/ansible/roles/amneziawg)) defaults to:
  - kernel module + tools (`amneziawg-dkms` / `amneziawg-tools`) from the official Amnezia PPA, or
  - the userspace Go implementation **`amneziawg-go` `v0.2.12`** (checksum-verified) when the
    kernel module is unavailable.

  Record the exact deployed version/commit in the node's gitignored `state/` directory at deploy
  time. Do not float to `latest`: the obfuscation wire behaviour and config field names evolve, and
  reproducible deployment requires a fixed pin.

## No custom cryptography (ADR-0002)

All key material is produced by the audited AmneziaWG built-ins — **never hand-rolled** (the
underlying primitive is the same X25519 WireGuard uses):

| Material | Command | Lives where (model A) |
|---|---|---|
| Server keypair | `awg genkey \| awg pubkey` | private key: on the node only; public key: handed to clients |
| Client keypair | `awg genkey \| awg pubkey` | generated **on the node** per client; the client's private key is delivered inside its rendered config (see model A below) |
| Pre-shared key (optional) | `awg genpsk` | shared with exactly one client, for an extra symmetric layer |

`awg genkey`/`awg pubkey`/`awg genpsk` are the AmneziaWG equivalents of `wg genkey`/`wg
pubkey`/`wg genpsk`; either toolset is acceptable since the key format is identical. The server's
**private** key never leaves the node. Under provisioning **model A** (below) the client keypairs
are generated on the node too, so a client's private key travels inside its rendered config; under
the future **model B** the client keeps its private key and only its public key reaches the node.

## How the template is filled

[`awg0.conf.template`](./awg0.conf.template) ships with **sentinel** values only, so it carries no
secrets and is safe to commit. A deploy-time renderer (the `amneziawg` Ansible role) produces a
real, deploy-only `awg0.conf` that lands under a gitignored path (`state/`, `secrets/`, `out/`, or
the system path `/etc/amnezia/amneziawg/awg0.conf`) — **never committed**. Sentinels:

| Sentinel | Filled with | Source |
|---|---|---|
| `SENTINEL_SERVER_PRIVATE_KEY` | server private key | `awg genkey` |
| `SENTINEL_SERVER_TUNNEL_ADDR_V4` / `_V6` | server's in-tunnel addresses (private ranges) | operator / role default |
| `SENTINEL_LISTEN_PORT` | UDP listen port (diversify per node) | operator choice |
| `SENTINEL_JC` … `SENTINEL_H4` | the obfuscation knobs (shared by all peers) | role default / Layer 2 tuning |
| `SENTINEL_WAN_IF` | the node's public-facing interface name | discovered on the node |
| `[Peer]` block placeholder | one block per client (public key + AllowedIPs, optional PSK) | per-client `awg genkey`/`genpsk` |

## How clients get their config — provisioning model A (Phase 0)

Phase 0 uses **model A: node-generated client keys** — the simpler model, chosen to match how the
sing-box path already produces and fetches per-client subscriptions. The `amneziawg` Ansible role:

1. Generates the **server** keypair once (`awg genkey | awg pubkey`) and, per client name in
   `client_names`, a **client** keypair (`awg genkey | awg pubkey`) plus an optional pre-shared key
   (`awg genpsk`). All of this is generated **on the node** and stored root-only (`0600`) in the
   node's gitignored state directory. The server `awg0.conf` lists each client as a `[Peer]`
   (public key + a unique tunnel `AllowedIPs`).
2. Renders a **complete, self-contained client config** per identity from
   [`templates/client.conf.j2`](../../../infra/ansible/roles/amneziawg/templates/client.conf.j2):
   - `[Interface]` — the client's private key, its assigned tunnel address, `DNS`, and the shared
     `Jc`/`Jmin`/`Jmax`/`S1`/`S2`/`H1`..`H4` obfuscation values (these must match the server
     exactly);
   - `[Peer]` — the **server public key**, `Endpoint = node_address:ListenPort`, `AllowedIPs`,
     `PersistentKeepalive`, and the optional pre-shared key.
3. **Fetches** each rendered `<name>.conf` (and the server public key) to the operator's
   **gitignored `./out/amneziawg/<host>/`**, exactly mirroring how the sing-box role fetches
   per-client subscriptions to `./out/subscriptions/`. The operator then delivers each `.conf` to
   the right client **out-of-band**. Off-the-shelf clients consume it directly — the AmneziaWG app
   or any AmneziaWG-aware client (e.g. recent sing-box / Amnezia clients).

Because the node generates the client keypair in model A, a client's **private key is inside its
rendered `.conf`**. That config is root-only on the node and lands in the gitignored `./out/`, so
treat `./out/` as sensitive and never commit it. The **server** private key still never leaves the
node. Revocation = drop the name from `client_names` and re-run: the role removes that `[Peer]` and
reloads `awg0`, and stops re-emitting that client's config.

### Future hardening: model B (client-generated keys)

A later hardening pass may switch to **model B: client-generated keypairs**, where each client runs
`awg genkey | awg pubkey` locally, keeps its private key, and registers only its **public** key
with the node — so no client private key ever leaves the client. That tightens the key-handling
invariant to match the VLESS+REALITY path (node holds public keys only), at the cost of a more
involved enrolment flow (the client must assemble its own `[Interface]`, or the node must render a
config from a supplied public key). Model B is **out of scope for Phase 0** and is tracked as a
future option; model A is the supported path today.

## Relationship to the other transports

| | VLESS+REALITY (primary) | Hysteria2 / TUIC | **AmneziaWG (this path)** |
|---|---|---|---|
| Basis | TCP / TLS 1.3 | QUIC / UDP | WireGuard / UDP + obfuscation |
| Looks like | HTTPS to a real donor | QUIC | non-fingerprintable UDP |
| Breaks when | targeted TLS-TCP blocking | UDP excised | UDP excised |
| Role | primary | UDP-friendly networks | **non-TLS fallback** |

Layer 3 selects the active transport; this path is one of several run in parallel so a client can
fail over within the same node (ROADMAP Phase 1).

## Validate

```sh
# The template must contain ONLY sentinels/placeholders — no real keys, IPs, or ports:
grep -nE 'SENTINEL_|\[(Interface|Peer)\]' awg0.conf.template

# After rendering a real awg0.conf on the node (root-only), check the config + interface:
awg-quick strip awg0          # parse + emit the wg(8)-compatible form
awg show awg0                 # live peers / handshakes (no secrets printed)
```
