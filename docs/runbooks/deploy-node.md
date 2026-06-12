<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbook — deploy a node from zero

Author: mindicator & silicon bags quartet

Zero-to-node operator procedure for a Mycelium Phase 0 ingress on a single VPS, against a real
external donor, with a genuine cover response to active probing. The data plane is engine-selected
per node via the `engine` toggle in `group_vars/all.yml`:

- **DEFAULT — sing-box (PRIMARY).** One `sing-box` process speaks several transport "dialects" in
  parallel, with **VLESS + REALITY + XTLS-Vision enabled on `443/tcp`** as the primary, default-on
  transport. Additional sing-box inbounds (VLESS+REALITY+gRPC `8443/tcp`, VLESS+REALITY+XHTTP
  `2096/tcp`, Hysteria2 `8444/udp`, TUIC `8445/udp`, Shadowsocks-2022 `8388/tcp+udp`, ShadowTLS
  `8446/tcp`, Trojan `8447/tcp`) are individually toggleable; an operator exposes only the subset
  they choose. This is the recommended path.
- **OPTIONAL — Xray-core (alternative engine).** Set `engine: xray` to deploy the single
  **VLESS + XTLS-Vision + REALITY** inbound on `443/tcp` using the Xray-core stack instead. sing-box
  and Xray are **alternatives, not co-running engines** — exactly one TLS engine runs per node.
- **OPTIONAL — AmneziaWG (separate UDP path).** An obfuscated WireGuard inbound on `51820/udp`,
  gated by `enable_amneziawg: true`. It is **not** a sing-box/Xray inbound; it runs alongside
  whichever TLS engine you select.

This runbook is server-only; off-the-shelf clients (sing-box, Clash-Meta) consume the standard
endpoint parameters the node exposes (see [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) §Layer 5 and
[`docs/proposals/0001-bootstrap-phase-0-node.md`](../proposals/0001-bootstrap-phase-0-node.md)).

The objective throughout is **statistical indistinguishability** from ordinary HTTPS/QUIC to a real
site. "Adversary", "network interference", "DPI", "active probing", "AS-level blocking", and
"reachability/resilience" are used per the project glossary — no deployment scenario is named.

> **Key-handling invariant.** REALITY **private** keys and client UUIDs are generated *on the
> node* at deploy time and **never** leave it. Only the REALITY **public** key and the rendered
> per-client subscriptions are fetched back to the operator's gitignored `./out/`. Nothing in
> this procedure commits a secret to the repository.

---

## 0. Prerequisites (control host = your laptop)

- `ansible-core` ≥ 2.15 and Python 3.
- `git`, `ssh`, `curl`, and `openssl` on `PATH`.
- The pinned Galaxy collections (run from `infra/ansible/`):
  ```sh
  cd infra/ansible
  ansible-galaxy collection install -r requirements.yml
  ```
- A clone of this repository. All commands below assume the repository root unless a `cd` is
  shown.

Estimated time end-to-end: **15–30 minutes**, most of it waiting on the VPS to provision and the
playbook to run.

---

## 1. Choose and provision a fresh VPS in a clean AS

Pick a VPS that is **fresh** (no prior reputation) and on a **public IP**.

- **Distribution:** Debian 12+ or Ubuntu 22.04+ (`amd64` or `arm64`). The playbook asserts a
  Debian-family host and refuses anything else.
- **AS diversity — mandatory.** Do **not** concentrate nodes in one provider or one autonomous
  system. AS-level blocking cuts traffic to an entire autonomous system wholesale (the handshake
  completes; the data silently dies), so a fleet packed into one AS shares a single blocking
  point. Spread nodes across **different providers and different ASes**, and keep **1–2 fresh IPs
  in reserve in other ASes** for the `rotate-ip-as` procedure.
- **Avoid tainted ranges.** Prefer IP ranges with no known-bad reputation. New allocations from a
  well-mixed provider are safer than recycled addresses.
- **Inbound:** ensure `22/tcp` (SSH) is reachable for the initial run. The hardening role then
  opens only `443/tcp` and locks the rest down.

You can bring your own VPS by hand (the primary path) **or** use the optional Terraform example in
[`infra/terraform/`](../../infra/terraform/) to provision one Hetzner server plus a firewall. The
Terraform path is optional and does not change anything below — it only hands you an IP. See its
[README](../../infra/terraform/README.md) for the same AS-diversity caveat.

Record the node's public IP; you will need it in step 3.

---

## 2. Pick a DONOR (REALITY handshake target)

REALITY does not present its own certificate — it **borrows the live TLS 1.3 handshake of a real
external site**, the *donor*. An active prober that connects to the node therefore receives a
genuine, working session to that donor; only authorised clients upgrade the session to the tunnel.

Pick a donor that satisfies **all** of the following (there is no safe default — this is a
deliberate operator decision; see
[`nodes/dataplane/vless-reality/README.md`](../../nodes/dataplane/vless-reality/README.md)):

- [ ] **Real, popular, always-up external site** — probing must get a legitimate response.
- [ ] **Serves TLS 1.3** — REALITY mirrors a TLS 1.3 handshake.
- [ ] **Serves HTTP/2** (negotiates `h2` via ALPN). Verify from the control host:
      ```sh
      openssl s_client -connect DONOR_HOST:443 -alpn h2 -tls1_3 </dev/null 2>/dev/null \
        | grep -E 'ALPN protocol|Protocol *:'
      # expect: ALPN protocol: h2   and   Protocol  : TLSv1.3
      ```
- [ ] **NOT on your own provider / AS** — reusing your own hosting undermines the cover and links the
      node to its own egress.
- [ ] **Not a CDN edge you also use**, ideally operationally close to the node so the relayed
      handshake looks natural and latency to the donor is low.
- [ ] **`serverNames` matches what the donor actually serves** — every SNI the node presents must
      be a hostname the donor terminates TLS for.

Diversify donors and SNI values across the fleet: a single shared donor is a single point of
failure at the AS level.

---

## 3. Set `group_vars/all.yml` and `inventory.ini`

The real config files are **gitignored** (`inventory.ini`, `group_vars/all.yml`). Copy the
shipped `*.example` files and edit them:

```sh
cd infra/ansible
cp inventory.ini.example       inventory.ini
cp group_vars/all.yml.example  group_vars/all.yml
$EDITOR inventory.ini group_vars/all.yml
```

- **`inventory.ini`** — replace `NODE_PUBLIC_IP` with the node's real address. `ansible_user=root`
  assumes a vanilla fresh VPS; switch to a sudo-capable user if your provider ships a non-root
  default account.
- **`group_vars/all.yml`** — set at minimum:
  - `donor_host` / `donor_sni` — the donor you chose in step 2.
  - `node_address` — the address clients use to reach this node (usually its public IP). Used only
    to render subscriptions; not a secret.
  - `client_names` — friendly labels for the clients you want issued (e.g. `alice`, `bob`). These
    are **not** secrets and **not** the UUIDs; one UUID + subscription is generated per name on the
    node.
  - `shortid_count` — number of REALITY shortIds to generate.
  - the pinned versions (`xray_version` ≥ `v26.2.4`, `node_exporter_version`, `caddy_version`).

### Record the upstream checksums (fail-closed)

The roles **refuse to deploy** until you record real SHA256 checksums — the `REPLACE_…`
placeholders are invalid on purpose, so an unverified artefact is never installed. Fetch them from
the pinned upstream releases and paste them into `xray_sha256` / `node_exporter_sha256`:

```sh
# Xray (use your pinned xray_version tag):
curl -fsSL https://github.com/XTLS/Xray-core/releases/download/v26.2.4/Xray-linux-64.zip.dgst
# node_exporter:
curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v1.8.2/sha256sums.txt
```

This satisfies the supply-chain policy: pin by version **and** by hash (see
[`docs/dependency-policy.md`](../dependency-policy.md)).

---

## 4. Run the bootstrap (one command)

From the repository root, the wrapper provisions the node end-to-end:

```sh
scripts/bootstrap.sh
```

`scripts/bootstrap.sh` is the single-command entry point required by the Phase 0 Definition of
Done. It installs the Galaxy collections if missing, sanity-checks that `inventory.ini` and
`group_vars/all.yml` exist (and that no checksum placeholders remain), then runs the Ansible
playbook against the `mycelium_nodes` group.

If you prefer to drive Ansible directly (identical result), run it from `infra/ansible/`:

```sh
cd infra/ansible
ansible-playbook playbook.yml          # ansible.cfg already points at ./inventory.ini
# dry-run first if you like:  ansible-playbook playbook.yml --check --diff
```

The playbook applies four roles in order:

| Role | What it does |
|---|---|
| `hardening` | UFW (allow OpenSSH + `443/tcp`, deny the rest), `unattended-upgrades`, baseline sysctl, optional `fail2ban`. |
| `xray` | Installs the pinned, checksum-verified Xray-core; generates REALITY keys + per-client UUIDs + shortIds **on the node**; renders `config.json`; installs a hardened `xray.service`; validates with `xray run -test`; fetches subscriptions back to `./out/`. |
| `caddy` | Installs pinned Caddy; deploys an optional loopback cover origin (used only if you self-host your own donor). |
| `observability` | Installs pinned `node_exporter`, bound to loopback only. |

What you get back on the control host (gitignored `./out/`):

| Path | Contents |
|---|---|
| `infra/ansible/out/subscriptions/<host>/<client>.txt` | one standard VLESS+REALITY subscription per client |
| `infra/ansible/out/<host>-reality_public_key.txt` | the REALITY **public** key (clients need this) |

---

## 5. Add a client

Client identities are the friendly names in `client_names`; the node owns issuance and revocation
(Layer 2, control plane). The **authoritative** roster is `client_names` — prefer editing it and
re-running so the deploy stays reproducible.

**Add a client** — append a name and re-run the `xray` role:

```yaml
# infra/ansible/group_vars/all.yml
client_names:
  - alice
  - bob
  - carol   # new
```

```sh
cd infra/ansible
ansible-playbook playbook.yml --tags xray
```

A fresh UUID (`xray uuid`) is generated for `carol`, `config.json` is re-rendered, the service
reloads, and `out/subscriptions/<host>/carol.txt` appears. Existing clients are untouched.

**On-node alternative.** The copied control tooling can manage the roster directly on the node:

```sh
# on the node, against the on-node state file:
myceliumctl identity add  --name carol
myceliumctl identity list
```

This is equivalent for a one-off, but the next playbook run reconciles the node back to
`client_names`, so treat `client_names` as the source of truth.

---

## 6. Verify the node

```sh
# On the node: services up and config valid. Use the line for the engine you deployed.

# DEFAULT — sing-box (PRIMARY):
systemctl status sing-box caddy node_exporter
/usr/local/bin/sing-box check -c /usr/local/etc/sing-box/config.json

# OPTIONAL — Xray-core (alternative engine, when engine: xray):
systemctl status xray caddy node_exporter
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

If you enabled the optional AmneziaWG UDP path (`enable_amneziawg: true`), also confirm its
interface is up:

```sh
systemctl status awg-quick@awg0   # AmneziaWG (separate UDP path on 51820/udp)
```

From the control host, run the conformance probe. It confirms that an active probe of `:443`
behaves like ordinary HTTPS to the donor — the handshake completes and a **genuine donor
response** comes back, with no tell-tale fingerprint:

```sh
tests/conformance/cover_site_probe.sh NODE_PUBLIC_IP DONOR_SNI
```

A green run satisfies the proposal's `cover_site_probe` acceptance criterion. Cross-check the
reachability signal in the dashboard: a sustained drop in handshake success is treated as
**possible network interference** and points at the
[`rotate-ip-as`](rotate-ip-as.md) runbook (see
[`observability/prometheus/rules.yml`](../../observability/prometheus/rules.yml)).

---

## 7. Hand the client their subscription

Hand each client the matching subscription from
`infra/ansible/out/subscriptions/<host>/<client>.txt`. It carries the standard VLESS+REALITY
endpoint parameters (address, port, UUID, flow `xtls-rprx-vision`, the REALITY **public** key,
SNI, shortId) and imports directly into **sing-box** or **Clash-Meta** — no bespoke client
software is involved.

Deliver it over a channel reachable **from a heavily restricted network**, i.e. outside the
infrastructure that the adversary can cut. Never transmit the REALITY **private** key or a client
UUID over an untrusted channel; the subscription contains only what a client legitimately needs.

---

## Phase 0 — Definition-of-Done checklist

From [`docs/ROADMAP.md`](../ROADMAP.md) Phase 0. The node is "done" when **all four** hold:

- [ ] **Reaches the open internet from a restrictive network.** An unprepared user on a
      restrictive network imports the issued subscription into an off-the-shelf client and reaches
      the open internet through the node — no special setup beyond importing the config.
- [ ] **Active probing returns a genuine donor response.** A direct probe of the node's `:443`
      receives a legitimate response from the real donor, not a suspicious/tell-tale one
      (`tests/conformance/cover_site_probe.sh` is green; the netsim `active_probe` confirms the
      cover response).
- [ ] **Deploys from zero with one command.** A fresh VPS becomes a working node via a single
      command (`scripts/bootstrap.sh`), with no manual post-steps beyond handing out
      subscriptions.
- [ ] **A client credential is revoked without reinstalling the node.** Remove the name from
      `client_names` and re-run `ansible-playbook playbook.yml --tags xray` (or
      `myceliumctl identity revoke <name|uuid>` on the node): the UUID is dropped from
      `config.json`, the node stops accepting that identity, and **no redeploy** of the node is
      required. Other clients keep working.

When all four pass in production, mark Phase 0 DoD fulfilled in
[`docs/ROADMAP.md`](../ROADMAP.md) and record the actual data-plane parameters in
[`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) §Layer 1 (per proposal §8).

---

## See also

- [`rotate-ip-as.md`](rotate-ip-as.md) — migrate to a fresh IP/AS when a node degrades.
- [`infra/ansible/README.md`](../../infra/ansible/README.md) — role-by-role detail and idempotency.
- [`nodes/dataplane/vless-reality/README.md`](../../nodes/dataplane/vless-reality/README.md) —
  donor selection and the REALITY config fields.
- [`infra/terraform/README.md`](../../infra/terraform/README.md) — optional VPS provisioning.
