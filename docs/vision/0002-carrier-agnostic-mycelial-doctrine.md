<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# VIS-0002: Carrier-Agnostic Mycelial Doctrine

## Metadata

- **ID:** VIS-0002
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** proposed
- **Horizon:** Phase 0-7
- **Layer(s):** cross-cutting
- **Related:** `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `docs/THREAT-MODEL.md`,
  `docs/adr/0011-carrier-agnostic-bridging.md`,
  the internal research baseline (maintainers' knowledge base)

## 1. Core idea

Mycelium is not a star network, not a VPN fleet, and not a corporation-like service with users around
a center. Mycelium is a living private connectivity fabric.

It grows through many small local connections, reinforces useful paths, forgets dead paths, forms
temporary transport backbones when needed, shares safe stress signals, and survives by adaptation
rather than by one perfect protocol or one central authority.

The network should behave like a biological mycelium:

- hyphae explore;
- anastomoses connect;
- cords carry;
- gradients guide;
- stress leaves memory;
- dead paths decay;
- spores germinate;
- local signals create global structure.

## 2. Any carrier can be a bridge

A Mycelium bridge is any carrier that can move authenticated bytes.

Examples:

- ordinary IP links;
- LTE/5G;
- satellite;
- Wi-Fi Direct;
- local Ethernet or local Wi-Fi;
- WebRTC volunteer ingress;
- Bluetooth / Bluetooth Mesh;
- LoRa-style radio meshes;
- QR codes;
- files;
- USB/memory card;
- future radio or optical links.

The carrier constrains the flow class; it does not define Mycelium.

A low-rate carrier can still carry bootstrap spores, route capsules, revocations, signed manifests,
stress summaries, and delayed messages. A high-rate carrier can carry interactive and real-time flows
when measured quality permits. A physical bridge can reconnect islands even when no radio/IP path
exists.

## 3. Spores

A spore is a compact, signed, portable, replay-bounded artifact that can be carried across any bridge.

Spores may contain:

- bootstrap hints;
- route capsules;
- trust invitations;
- revocation notices;
- signed update manifests;
- stress summaries;
- cache manifests;
- delayed messages;
- emergency coordination messages.

Spores must not contain raw traffic, full topology maps, complete peer lists, user identities, private
content, or persistent behavioral profiles.

## 4. Island behavior

A separated Mycelium fragment is not dead. It is an island.

An island should keep local discovery, local messaging, local content cache, local service registry,
local emergency coordination, and delayed synchronization capability.

When two islands meet through any bridge, they exchange signed scoped summaries first, not full maps.
They request only missing artifacts needed for their scope. They preserve local autonomy if merge
confidence is low.

## 5. Adversary-cost goal

Mycelium does not promise absolute reachability. It raises the cost of selective breakage.

The desired property is that breaking the fabric requires increasingly high-collateral actions:
disrupting large protocol classes, many autonomous systems, common CDNs, satellite/cellular/local radio
paths, local bridges, and eventually physical spore exchange — while the network degrades into lower
modes instead of going dark all at once.

## 6. Canon

Mycelium should:

- explore cheaply;
- reinforce what works;
- prune what dies;
- fuse where useful;
- form cords where needed;
- carry spores over any carrier;
- forget safely;
- remember stress;
- learn without surveillance;
- grow toward need;
- defend against parasites;
- degrade gracefully;
- never crown a permanent center.
