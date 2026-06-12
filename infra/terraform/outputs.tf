# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# Mycelium Phase 0 — OPTIONAL Terraform (Hetzner Cloud) outputs.
# Author: mindicator & silicon bags quartet
#
# The one output you actually need: the server's public IPv4, to paste into
# infra/ansible/inventory.ini (replacing NODE_PUBLIC_IP) before running scripts/bootstrap.sh.

output "server_ipv4" {
  description = "Public IPv4 of the provisioned node. Put this in infra/ansible/inventory.ini."
  value       = hcloud_server.node.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 of the provisioned node (informational; IPv4 is used for inventory)."
  value       = hcloud_server.node.ipv6_address
}

output "server_id" {
  description = "Hetzner server resource ID (for reference / teardown)."
  value       = hcloud_server.node.id
}

output "server_location" {
  description = <<-EOT
    Hetzner location the node was created in. A reminder to verify AS diversity across the fleet:
    do not concentrate nodes in one provider/region/AS (see README and rotate-ip-as runbook).
  EOT
  value       = hcloud_server.node.location
}
