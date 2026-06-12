# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# Mycelium Phase 0 — OPTIONAL Terraform (Hetzner Cloud) example.
# Author: mindicator & silicon bags quartet
#
# OPTIONAL provisioning path. The PRIMARY path is bring-your-own-VPS via Ansible (infra/ansible/).
# This config stands up exactly ONE server plus ONE firewall (allow 22/tcp and 443/tcp by default;
# add ports per enabled protocol via firewall_extra_tcp_ports / firewall_extra_udp_ports), and
# outputs the server's public IPv4. It deliberately does NOT configure the node — provisioning of
# the data plane / cover / observability is the Ansible playbook's job. Feed the output IPv4 into
# infra/ansible/inventory.ini and run scripts/bootstrap.sh (see docs/runbooks/deploy-node.md).
#
# AS-DIVERSITY CAVEAT: do not concentrate nodes in one provider/region/AS. A single AS is a single
# AS-level blocking point. Use this for ONE node and diversify the fleet across providers/ASes.

terraform {
  # Pin Terraform and the provider so applies are reproducible (dependency-policy.md).
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

provider "hcloud" {
  # Token comes from var.hcloud_token (env HCLOUD_TOKEN or a gitignored *.tfvars). Never committed.
  token = var.hcloud_token
}

# Upload the operator's SSH PUBLIC key so the fresh server permits key-only SSH for the first
# Ansible run. The private key never leaves the operator's machine.
resource "hcloud_ssh_key" "operator" {
  name       = var.ssh_key_name
  public_key = file(pathexpand(var.ssh_public_key_path))
  labels     = var.labels
}

# Firewall: by default allow ONLY 22/tcp (SSH, ideally narrowed to the control host) and 443/tcp
# (the primary data-plane / cover — must look like an ordinary public HTTPS endpoint). Everything
# else is denied by Hetzner's default-deny on inbound. Outbound is left unrestricted so the node can
# egress. To run additional protocols, open ONLY their canonical ports via firewall_extra_tcp_ports
# / firewall_extra_udp_ports so the exposed surface matches what the Ansible role actually enables
# (see variables.tf and README for the canonical port map). Keeping the lists empty = 443-only.
resource "hcloud_firewall" "node" {
  name   = "${var.server_name}-fw"
  labels = var.labels

  rule {
    description = "SSH for initial provisioning (tighten ssh_cidrs_allowed for production)"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_cidrs_allowed
  }

  rule {
    description = "VLESS+REALITY+Vision primary data plane / cover — public HTTPS-shaped endpoint"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  # Extra TCP ports, one rule per enabled TCP protocol (empty by default = none beyond 443).
  dynamic "rule" {
    for_each = toset(var.firewall_extra_tcp_ports)
    content {
      description = "Enabled protocol (TCP ${rule.value}) — open only if the Ansible role enables it"
      direction   = "in"
      protocol    = "tcp"
      port        = tostring(rule.value)
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }

  # Extra UDP ports, one rule per enabled UDP protocol (Hysteria2 / TUIC / shadowsocks2022 /
  # AmneziaWG). Empty by default. UDP is excised on some networks, so these are complementary paths.
  dynamic "rule" {
    for_each = toset(var.firewall_extra_udp_ports)
    content {
      description = "Enabled protocol (UDP ${rule.value}) — open only if the Ansible role enables it"
      direction   = "in"
      protocol    = "udp"
      port        = tostring(rule.value)
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }
}

# The node itself: a single fresh Debian/Ubuntu server with the firewall attached.
resource "hcloud_server" "node" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image
  location    = var.location
  labels      = var.labels

  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}
