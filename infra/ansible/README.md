<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Phase 0 — Provisioning (Ansible)

Author: mindicator & silicon bags quartet

This role set brings up a single persistent-private-network ingress node on a **fresh
Debian/Ubuntu VPS** ("bring your own VPS" — the primary deploy path). It is server-only; the
client application is out of scope (see
[`docs/proposals/0001-bootstrap-phase-0-node.md`](../../docs/proposals/0001-bootstrap-phase-0-node.md)).

The playbook applies these roles to the `mycelium_nodes` host group:

| Role | What it does |
|---|---|
| `hardening` | UFW (allow OpenSSH + the primary VLESS port `443/tcp`, deny the rest), `unattended-upgrades`, baseline sysctl, optional `fail2ban`. |
| `singbox` | **PRIMARY engine** (default; runs when `engine: singbox`). Installs a **pinned, checksum-verified** sing-box (≥ 1.11.x); one server speaks many **individually toggleable** transports — VLESS+REALITY in three flavours (Vision/gRPC/XHTTP), Hysteria2, TUIC, Shadowsocks-2022, ShadowTLS, Trojan. Generates REALITY keys, per-client UUIDs, shortIds and per-protocol passwords **on the node** (`sing-box generate …`, `openssl rand …` — no custom crypto); renders `config.json` for the enabled subset; installs a hardened `sing-box.service`; opens **only** the enabled protocols' ports; fetches client subscriptions back to `./out/`. |
| `xray` | **Optional alternative engine** (runs only when `engine: xray`). Installs a pinned, checksum-verified Xray-core (≥ v26.2.4); VLESS + XTLS-Vision + REALITY only; renders `config.json`; installs a hardened `xray.service`; fetches subscriptions back to `./out/`. Kept for operators who prefer the Xray stack. |
| `amneziawg` | **Off by default** (`enable_amneziawg`). The **non-TLS / UDP fallback** path, independent of whichever TLS engine is selected: installs pinned AmneziaWG (kernel module via the official PPA, or the checksum-verified `amneziawg-go` userspace build); generates server + per-client keys **on the node** (`awg genkey`/`awg pubkey`/`awg genpsk` — no custom crypto); renders `awg0.conf`; enables `awg-quick@awg0`; opens **only** its UDP port in UFW. See [`nodes/dataplane/amneziawg/README.md`](../../nodes/dataplane/amneziawg/README.md). |
| `caddy` | Installs pinned Caddy; deploys an optional loopback cover site (a self-hosted donor target). By default REALITY borrows a real **external** donor, so this site is harmless when unused. |
| `observability` | Installs pinned `node_exporter`, bound to loopback only. |

The primary transport is **VLESS + XTLS-Vision + REALITY**: ordinary HTTPS to a real donor site,
selected for high reachability on high-interference networks under advanced network degradation and active
probing (see [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) §Layer 1). With the **sing-box** engine you can
additionally expose any subset of gRPC/XHTTP REALITY, Hysteria2, TUIC, Shadowsocks-2022, ShadowTLS,
and Trojan — each behind its own `enable_*` toggle (see §1a below). Legacy, easily-fingerprinted
protocols (VMess, plain pre-2022 Shadowsocks, plain WireGuard, OpenVPN, L2TP/IPsec, …) are
intentionally **not** offered.

---

## 1a. Engines and per-protocol toggles

Two TLS data-plane **engines** are available; **exactly one runs**, chosen by `engine` in
`group_vars/all.yml`:

| `engine` | Role | Protocols |
|---|---|---|
| `singbox` (**default**) | `singbox` | VLESS+REALITY (Vision/gRPC/XHTTP), Hysteria2, TUIC, Shadowsocks-2022, ShadowTLS, Trojan — each toggleable |
| `xray` | `xray` | VLESS + XTLS-Vision + REALITY only |

**AmneziaWG** is orthogonal to the engine choice — a separate non-TLS/UDP path gated by its own
`enable_amneziawg` toggle, and it can run alongside either engine.

With the sing-box engine, the operator exposes **only a chosen subset** of protocols. An inbound is
created — and its firewall port opened — only for a protocol whose toggle is `true`:

| Toggle | Protocol | Default | Transport | Default port |
|---|---|---|---|---|
| `enable_vless_reality_vision` | VLESS + REALITY + XTLS-Vision | **true** | TCP | `443` |
| `enable_vless_reality_grpc` | VLESS + REALITY + gRPC | false | TCP | `8443` |
| `enable_vless_reality_xhttp` | VLESS + REALITY + XHTTP | false | TCP | `2096` |
| `enable_hysteria2` | Hysteria2 | false | QUIC/UDP | `8444` |
| `enable_tuic` | TUIC v5 | false | QUIC/UDP | `8445` |
| `enable_ss2022` | Shadowsocks-2022 AEAD | false | TCP | `8388` |
| `enable_shadowtls` | ShadowTLS v3 (wraps Shadowsocks-2022) | false | TCP | `8446` |
| `enable_trojan` | Trojan over TLS | false | TCP | `8447` |

**Enable a protocol and re-run** — flip its toggle in `group_vars/all.yml` and re-apply the engine:
```yaml
# group_vars/all.yml
engine: "singbox"
enable_hysteria2: true     # was false
```
```sh
ansible-playbook playbook.yml --tags singbox
```
The role generates any newly needed per-client passwords (existing material is reused), re-renders
`config.json` for the now-enabled subset, validates it with `sing-box check`, opens the protocol's
UDP/TCP port in UFW, restarts the service, and re-fetches the per-client subscriptions (which now
include an outbound for the new protocol) to `./out/subscriptions/<host>/`.

> UDP note: Hysteria2 and TUIC ride QUIC/UDP, which is excised entirely on some networks. Provision
> them as complementary paths — never rely on a UDP transport as the only route (ROADMAP Phase 1).

> Switch engines deliberately: changing `engine` from `singbox` to `xray` (or back) leaves the other
> engine's binary/service in place but stops managing it. Stop/disable the unused service by hand if
> you want a single active engine on the node.

---

## 1. Prerequisites

**On the control host (your laptop):**
- Ansible ≥ 2.15 (`ansible-core`) and Python 3.
- The pinned Galaxy collections:
  ```sh
  ansible-galaxy collection install -r requirements.yml
  ```
- SSH access to the node as `root` (or a sudo-capable user — see `inventory.ini.example`).

**On the node:**
- A **fresh** Debian 12+ / Ubuntu 22.04+ VPS on a **public IP** (`amd64` or `arm64`).
- Inbound `22/tcp` reachable (SSH) for the initial run. The playbook then opens only the ports of
  the **enabled** transports: SSH, `443/tcp` for the primary VLESS path, plus any other enabled
  protocol's TCP/UDP port (and the AmneziaWG UDP port when `enable_amneziawg`).

**No secrets live in this repo.** REALITY private keys and client UUIDs are generated on the node
at deploy time and never committed. Only the REALITY *public* key and rendered subscriptions are
fetched back to your gitignored `./out/`.

---

## 2. Configure

Copy the two example files (the real ones are gitignored) and edit them:

```sh
cp inventory.ini.example   inventory.ini
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR inventory.ini group_vars/all.yml
```

- **`inventory.ini`** — replace `NODE_PUBLIC_IP` with the node's real address.
- **`group_vars/all.yml`** — choose `engine` (`singbox` default, or `xray`); flip the
  `enable_*` protocol toggles for the subset you want (§1a); set `donor_host` / `donor_sni` (a
  real, high-traffic third-party TLS 1.3 + HTTP/2 site you do not control), `node_address`,
  `client_names`, and the pinned versions/checksums.

### Record the upstream checksums (fail-closed)

The roles **refuse to deploy** until you record real SHA256 checksums (the `REPLACE_…`
placeholders are 64-char-invalid on purpose). Fetch them from the pinned upstream releases — only
the engine you select needs its checksum recorded:

```sh
# sing-box (PRIMARY; replace the tag with your pinned singbox_version). The release ships a
# checksum manifest alongside the per-arch tarballs:
curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v1.11.15/sing-box-1.11.15-linux-amd64.tar.gz.sha256
# Xray (only if engine: xray; replace the tag with your pinned xray_version):
curl -fsSL https://github.com/XTLS/Xray-core/releases/download/v26.2.4/Xray-linux-64.zip.dgst
# node_exporter:
curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v1.8.2/sha256sums.txt
```

Paste the values into `singbox_sha256` / `xray_sha256` / `node_exporter_sha256` in
`group_vars/all.yml` (and `awg_go_sha256` if you set `awg_install_method: userspace`). This
satisfies the project supply-chain policy (pin by version **and** by hash; see
[`docs/dependency-policy.md`](../../docs/dependency-policy.md)).

---

## 3. Run

From this directory (`infra/ansible/`):

```sh
ansible-playbook playbook.yml
```

`ansible.cfg` already points at `./inventory.ini` and loads `group_vars/all.yml`. To target one
role use its tag, e.g. `--tags singbox` (the primary engine), `--tags xray`, `--tags amneziawg`,
or `--tags dataplane` (whichever data-plane roles are active). To dry-run: add `--check --diff`.

---

## 4. What gets generated, and where

With the **sing-box** engine (default), on the node (root-only, never fetched):
| Path | Contents |
|---|---|
| `/usr/local/bin/sing-box` | the pinned, verified sing-box binary |
| `/usr/local/etc/sing-box/config.json` | rendered multi-protocol server config for the enabled subset (mode `0640`, group `sing-box`) |
| `/var/lib/mycelium/identity.json` | REALITY **private**+public key, client UUIDs, shortIds, and all per-protocol **passwords** (mode `0600`, root) |
| `/var/lib/mycelium/tls/` | self-signed TLS pairs for the TLS-terminating protocols (Hysteria2/TUIC/Trojan), via `openssl req` |
| `/usr/local/lib/mycelium/` | copied Mycelium control tooling + the sing-box config template |

(The **xray** engine is the analogous set under `/usr/local/bin/xray` and `/usr/local/etc/xray/`.)

**Fetched back to the control host** (gitignored `./out/`):
| Path | Contents |
|---|---|
| `./out/subscriptions/<host>/<client>.singbox.json` | one sing-box client config per client, with an outbound per enabled protocol |
| `./out/<host>-reality_public_key.txt` | the REALITY **public** key (clients need this) |

> Key-handling invariant: the REALITY **private** key, client UUIDs, and **all server-side
> passwords never leave the node**. Only the REALITY public key and the per-client subscriptions
> (which carry only that client's own credentials) are exported. Hand each client their subscription
> over a channel reachable from a heavily restricted network (see proposal §5).

Rendering prefers the copied `myceliumctl` (engine `singbox`) when a prebuilt tool with that engine
is present; otherwise it falls back to rendering the bundled Jinja template directly. Either way the
result is validated with `sing-box check` before it is promoted into place.

---

## 5. Idempotency

The playbook is safe to re-run:
- **Binaries** (sing-box / Xray, node_exporter) reinstall only when the installed version differs
  from the pin — verified against the recorded checksum every time.
- **Identity material** is generated **once** and persisted in `/var/lib/mycelium/identity.json`.
  Re-runs reuse it, so REALITY keys, existing client UUIDs, and per-protocol passwords **do not
  rotate** on every deploy. Enabling a new protocol mints only the additional passwords it needs.
- **`config.json`** and **subscriptions** are re-rendered each run (cheap, deterministic) and the
  service restarts only when the binary or config actually changes.

To **rotate REALITY keys** deliberately: delete `/var/lib/mycelium/identity.json` on the node and
re-run (all clients then need the new public key + new subscriptions).

---

## 6. Add or revoke a client

Client identities are the friendly names in `client_names`. The node owns issuance/revocation
(Layer 2, control plane).

**Add a client** — append a name and re-run (use your active engine's tag, e.g. `singbox`):
```yaml
# group_vars/all.yml
client_names:
  - alice
  - bob
  - carol   # new
```
```sh
ansible-playbook playbook.yml --tags singbox   # or --tags xray
```
A fresh UUID (and per-protocol passwords) is generated for `carol`, `config.json` is re-rendered,
the service reloads, and `./out/subscriptions/<host>/carol.singbox.json` appears. Existing clients
are untouched.

**Revoke a client** — remove the name and re-run:
```yaml
client_names:
  - alice
  # bob removed
```
```sh
ansible-playbook playbook.yml --tags singbox   # or --tags xray
```
`bob`'s UUID and passwords are dropped from `identity.json` and `config.json`; the node no longer
accepts that identity (revocation without redeploying the node — acceptance criterion in proposal §7).

**On-node alternative:** the copied control tooling can manage the roster directly. The
authoritative roster, however, is `client_names` — the next playbook run reconciles the node to
it, so prefer editing `client_names` and re-running for reproducibility.

---

## 7. Verify

```sh
# On the node (sing-box engine):
systemctl status sing-box caddy node_exporter
/usr/local/bin/sing-box check -c /usr/local/etc/sing-box/config.json
# (xray engine: systemctl status xray; /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json)

# From the control host — an active probe of :443 should look like ordinary HTTPS to the donor:
#   the handshake completes and the real external donor responds (proposal §7 / cover_site_probe).
```

Hand a fetched `./out/subscriptions/<host>/<client>.singbox.json` to an off-the-shelf client
(sing-box, Clash-Meta) to connect.

---

## 8. Network framing note

Throughout these roles "adversary", "network interference", "network degradation", "active probing", and
"reachability/resilience" are used per the project glossary. The objective is **statistical
indistinguishability** from legitimate HTTPS, not any specific deployment scenario.
