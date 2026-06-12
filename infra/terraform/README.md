<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Phase 0 — OPTIONAL VPS provisioning (Terraform / Hetzner Cloud)

Author: mindicator & silicon bags quartet

> **This path is OPTIONAL.** The **primary** deploy path is **bring-your-own-VPS** driven by
> Ansible (see [`infra/ansible/`](../ansible/) and
> [`docs/runbooks/deploy-node.md`](../../docs/runbooks/deploy-node.md)). This Terraform example
> only **provisions one server** so you have an IP to point Ansible at — it does **not** install
> or configure Xray / REALITY / the cover site / observability. That is the playbook's job.

It creates exactly:

- **one** `hcloud_server` (a fresh Debian/Ubuntu VPS on a public IPv4 + IPv6),
- **one** `hcloud_firewall` allowing **`22/tcp`** (SSH, ideally narrowed to your control host) and
  **`443/tcp`** (the primary data-plane / cover — a public, HTTPS-shaped endpoint), plus any
  **extra ports you explicitly list** for the protocols you enable in Ansible (see
  [Firewall ports](#firewall-ports-443-only-minimal-by-default) below); everything else is
  default-denied,
- **one** `hcloud_ssh_key` (your **public** key, so the box permits key-only SSH for the first
  Ansible run),

and outputs **`server_ipv4`**.

---

## AS-diversity caveat (read this first)

Do **not** concentrate nodes in one provider, region, or autonomous system. **AS-level blocking**
cuts traffic to an entire autonomous system wholesale (the handshake completes; the data silently
dies), so a fleet packed into one AS shares a **single blocking point**. Use this module for **one
node** and deliberately spread the fleet across **different providers and ASes**, keeping **1–2
fresh IPs in reserve in other ASes** for the [`rotate-ip-as`](../../docs/runbooks/rotate-ip-as.md)
procedure. The `location` variable and the `server_location` output exist to keep this top of mind
— picking a Hetzner location is **not** the same as guaranteeing AS diversity across providers.

---

## Firewall ports (443-only minimal by default)

The firewall always opens **`443/tcp`** — the primary VLESS+REALITY+Vision path, which must look
like an ordinary public HTTPS endpoint. By default **nothing else** data-plane is opened: the
default is **443-only minimal**. If you enable additional protocols in the Ansible group_vars, open
**only their ports** here so the host's exposed surface matches what is actually running. Add them
per protocol with `firewall_extra_tcp_ports` / `firewall_extra_udp_ports`, aligned to the
**canonical port map**:

| Protocol | Port | List |
|---|---|---|
| `vless_reality_vision` (primary, default-on) | `443/tcp` | always open (built in) |
| `vless_reality_grpc` | `8443/tcp` | `firewall_extra_tcp_ports` |
| `vless_reality_xhttp` | `2096/tcp` | `firewall_extra_tcp_ports` |
| `shadowsocks2022` | `8388/tcp` + `8388/udp` | both lists |
| `shadowtls` | `8446/tcp` | `firewall_extra_tcp_ports` |
| `trojan` | `8447/tcp` | `firewall_extra_tcp_ports` |
| `hysteria2` | `8444/udp` | `firewall_extra_udp_ports` |
| `tuic` | `8445/udp` | `firewall_extra_udp_ports` |
| `amneziawg` | `51820/udp` | `firewall_extra_udp_ports` |

Both lists default to **empty** (443-only). Extra ports are opened to the world (`0.0.0.0/0`,
`::/0`), like 443, because they front public-shaped endpoints. UDP is excised on some networks, so
UDP paths are **complementary** — never assume reachability on UDP alone.

```sh
# Example: 443 (always) + vless gRPC (8443/tcp) + Hysteria2 (8444/udp) + AmneziaWG (51820/udp):
terraform apply \
  -var 'firewall_extra_tcp_ports=[8443]' \
  -var 'firewall_extra_udp_ports=[8444,51820]'
```

---

## Credentials are the operator's — never committed

- The Hetzner API token is supplied **at apply time**, never stored in the repo. Prefer the
  environment variable:
  ```sh
  export HCLOUD_TOKEN="<your-hetzner-api-token>"
  ```
  Terraform reads it via `var.hcloud_token`. If you must use a `*.tfvars` file instead, keep it
  **gitignored** (e.g. `terraform.tfvars` or a `*.local` name — both are covered by the repo
  `.gitignore` patterns for `*.local`; add `*.tfvars` / `*.tfstate*` to your local ignore as
  well). The token belongs to **your** Hetzner account.
- **Terraform state contains sensitive values** (resource IDs, IPs, and references to the token).
  Never commit `terraform.tfstate*`. Use a private/encrypted backend or keep state local and out of
  version control.
- Only your SSH **public** key is uploaded. The private key never leaves your machine and is never
  referenced here.

---

## Usage

```sh
cd infra/terraform

# 1. Supply your token (env var preferred — keeps it out of any file):
export HCLOUD_TOKEN="<your-hetzner-api-token>"

# 2. Initialise (downloads the pinned hcloud provider):
terraform init

# 3. Review the plan. Override defaults as needed, e.g. an Arm box in a different location and
#    SSH locked to your control host's address:
terraform plan \
  -var 'server_type=cax11' \
  -var 'location=hel1' \
  -var 'ssh_public_key_path=~/.ssh/id_ed25519.pub' \
  -var 'ssh_cidrs_allowed=["203.0.113.10/32"]'

# 4. Apply:
terraform apply   # add the same -var flags

# 5. Grab the IP for Ansible:
terraform output -raw server_ipv4
```

Then hand that IP to the primary path:

```sh
cd ../ansible
cp inventory.ini.example inventory.ini
$EDITOR inventory.ini                 # replace NODE_PUBLIC_IP with the server_ipv4 above
cp group_vars/all.yml.example group_vars/all.yml
$EDITOR group_vars/all.yml            # set node_address = that IP, donor/SNI, client_names, pins
cd ..
scripts/bootstrap.sh                  # one-command provision (see docs/runbooks/deploy-node.md)
```

### Key variables

| Variable | Default | Notes |
|---|---|---|
| `hcloud_token` | _(required)_ | Operator token; via `HCLOUD_TOKEN` or gitignored `*.tfvars`. Never committed. |
| `server_type` | `cx22` | `cax11` for Arm/aarch64 (maps to the Xray arm64 asset). |
| `location` | `hel1` | Pick with AS diversity in mind. |
| `image` | `debian-12` | Must be Debian/Ubuntu (the playbook asserts a Debian-family host). |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Your **public** key. |
| `ssh_cidrs_allowed` | world | **Tighten** to your control host for production; `443/tcp` stays world-open by design. |
| `firewall_extra_tcp_ports` | `[]` (443-only) | Extra inbound TCP ports per enabled protocol (e.g. `[8443]`). See [Firewall ports](#firewall-ports-443-only-minimal-by-default). |
| `firewall_extra_udp_ports` | `[]` | Extra inbound UDP ports per enabled protocol (e.g. `[8444,51820]`). |

See [`variables.tf`](variables.tf) for the full set and [`outputs.tf`](outputs.tf) for outputs.

---

## Teardown

When retiring a node (e.g. after [`rotate-ip-as`](../../docs/runbooks/rotate-ip-as.md)):

```sh
cd infra/terraform
terraform destroy   # with the same -var flags you applied with
```

This removes the server, firewall, and uploaded SSH key. Replenish your reserve pool of fresh IPs
in other ASes afterwards.

---

## Version pins

- Terraform `>= 1.6.0`.
- `hetznercloud/hcloud` provider `~> 1.48`.

Updating either pin is a separate, verified change (see
[`docs/dependency-policy.md`](../../docs/dependency-policy.md)).
