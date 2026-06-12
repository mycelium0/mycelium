# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# Mycelium Phase 0 — OPTIONAL Terraform (Hetzner Cloud) input variables.
# Author: mindicator & silicon bags quartet
#
# This is the OPTIONAL provisioning path. The PRIMARY path is bring-your-own-VPS driven by Ansible
# (see infra/ansible/). Nothing here is a secret in the repo: the API token is supplied at apply
# time (env var or *.tfvars that you keep gitignored), never committed.

variable "hcloud_token" {
  description = <<-EOT
    Hetzner Cloud API token (operator-supplied; NEVER commit it). Prefer the environment variable
    HCLOUD_TOKEN over a *.tfvars file. If you must use a file, keep it gitignored
    (e.g. terraform.tfvars or *.local). The token belongs to the operator's own account.
  EOT
  type        = string
  sensitive   = true
  # No default on purpose: Terraform will prompt / require it so a token is never assumed.
}

variable "server_name" {
  description = "Name/label for the server resource. Friendly label only; not a secret."
  type        = string
  default     = "mycelium-node"
}

variable "server_type" {
  description = <<-EOT
    Hetzner server type (e.g. "cx22" shared-vCPU, "cax11" Arm/aarch64). Choose per your bandwidth
    and CPU needs. Arm types map to the Xray arm64 asset in the Ansible role.
  EOT
  type        = string
  default     = "cx22"
}

variable "location" {
  description = <<-EOT
    Hetzner location code (e.g. "nbg1", "fsn1", "hel1", "ash", "hil", "sin"). Pick with attention
    to AS diversity: do NOT concentrate every node in one provider/region/AS (see README and
    docs/runbooks/rotate-ip-as.md). A single AS is a single AS-level blocking point.
  EOT
  type        = string
  default     = "hel1"
}

variable "image" {
  description = <<-EOT
    Base OS image. Must be Debian/Ubuntu — the Ansible playbook asserts a Debian-family host.
    Pinned to a concrete image so re-applies are reproducible.
  EOT
  type        = string
  default     = "debian-12"
}

variable "ssh_public_key_path" {
  description = <<-EOT
    Path to the operator's SSH PUBLIC key (e.g. ~/.ssh/id_ed25519.pub). The public key is uploaded
    so the server allows key-only SSH for the initial Ansible run. The private key never leaves the
    operator's machine and is never referenced here.
  EOT
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_key_name" {
  description = "Label for the uploaded SSH key resource in Hetzner. Friendly label only."
  type        = string
  default     = "mycelium-operator"
}

variable "ssh_cidrs_allowed" {
  description = <<-EOT
    Source CIDRs permitted to reach 22/tcp (SSH). Defaults to "anywhere" for a first run; TIGHTEN
    this to your control host's address(es) for a real deployment so SSH is not world-open.
    443/tcp (the data-plane / cover) is always open to the world by design — it must look like an
    ordinary public HTTPS endpoint.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "labels" {
  description = "Optional labels applied to the server and firewall. Non-secret metadata only."
  type        = map(string)
  default = {
    project = "mycelium"
    phase   = "0"
    role    = "ingress-node"
  }
}

# --- Data-plane firewall port set ---------------------------------------------------------------
# 443/tcp (the primary VLESS+REALITY+Vision path) is ALWAYS opened — it must look like an ordinary
# public HTTPS endpoint. The minimal default below is "443-only": no extra ports. Open ports ONLY
# for the protocols you actually enable in the Ansible group_vars, so the host's exposed surface
# matches what is running. Align these to the canonical port map (see README):
#
#   TCP  8443 vless_reality_grpc | 2096 vless_reality_xhttp | 8388 shadowsocks2022 |
#        8446 shadowtls          | 8447 trojan
#   UDP  8444 hysteria2          | 8445 tuic                | 8388 shadowsocks2022 |
#        51820 amneziawg
#
# Example (enabling hysteria2 + amneziawg + grpc):
#   -var 'firewall_extra_tcp_ports=[8443]' -var 'firewall_extra_udp_ports=[8444,51820]'
variable "firewall_extra_tcp_ports" {
  description = <<-EOT
    Additional inbound TCP ports to open beyond the always-on 443/tcp, one per enabled
    TCP protocol. Canonical TCP ports: 8443 (vless grpc), 2096 (vless xhttp), 8388
    (shadowsocks2022), 8446 (shadowtls), 8447 (trojan). Default is empty = 443-only minimal.
    Opened to the world (0.0.0.0/0, ::/0), like 443, since they front public-shaped endpoints.
  EOT
  type        = list(number)
  default     = []

  validation {
    condition     = alltrue([for p in var.firewall_extra_tcp_ports : p >= 1 && p <= 65535])
    error_message = "firewall_extra_tcp_ports must contain valid port numbers (1-65535)."
  }
}

variable "firewall_extra_udp_ports" {
  description = <<-EOT
    Additional inbound UDP ports to open, one per enabled UDP protocol. Canonical UDP ports:
    8444 (hysteria2), 8445 (tuic), 8388 (shadowsocks2022), 51820 (amneziawg). Default is empty.
    Opened to the world (0.0.0.0/0, ::/0). UDP is excised on some networks, so these are
    complementary paths — never assume reachability on UDP alone.
  EOT
  type        = list(number)
  default     = []

  validation {
    condition     = alltrue([for p in var.firewall_extra_udp_ports : p >= 1 && p <= 65535])
    error_message = "firewall_extra_udp_ports must contain valid port numbers (1-65535)."
  }
}
