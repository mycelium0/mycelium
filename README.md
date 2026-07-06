<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

<p align="center">
  <img src="logo.svg" alt="Mycelium" width="320">
</p>

# Mycelium

<p align="center">
  <a href="https://github.com/mycelium0/mycelium/actions/workflows/ci.yml"><img src="https://github.com/mycelium0/mycelium/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/mycelium0/mycelium/badges/coverage.json" alt="Go test coverage">
  <img src="https://img.shields.io/badge/version-0.2.29-blue" alt="version 0.2.29">
  <img src="https://img.shields.io/badge/go-1.23%2B-00ADD8?logo=go&logoColor=white" alt="Go 1.23+">
  <a href="CONTRIBUTING.md"><img src="https://img.shields.io/badge/contribute-welcome-brightgreen" alt="contribute"></a>
</p>

> **Resilient private connectivity over unreliable networks.**

> [!IMPORTANT]
> **Use restriction.** Licensed for educational, research, humanitarian, and civil use only — not for
> military operations, covert surveillance, or illegal activities. See [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md).

---

## What this is

Mycelium is **server software** for a self-adapting private network (PPN): a mesh of relay nodes that
reroute to keep private connectivity available across unreliable, high-interference, and disaster-prone
networks. The path runs from a single multi-protocol node that adapts to interference automatically,
toward a decentralized mesh that reroutes on its own — so connectivity stays available wherever there
is some channel to the network and at least one working node in reach. It is community infrastructure
for the people and groups who need dependable private connectivity when networks are unreliable:
communities, researchers, journalists, NGOs, families, and infrastructure operators.

Nodes expose **standard protocol endpoints** consumed by existing off-the-shelf clients; a bespoke
end-user client is out of scope for now. Traffic re-forms across other nodes when a path dies, and any
carrier that can move authenticated bytes — IP, cellular, satellite, Wi-Fi Direct, radio, even a
file/QR hand-off — can bridge it (the mycelial model: [docs/vision/0002-carrier-agnostic-mycelial-doctrine.md](docs/vision/0002-carrier-agnostic-mycelial-doctrine.md)).

> **Software, not an operated network.** This repository publishes server software only. It operates
> no public network, publishes no public endpoints, and distributes no public client configs — each
> operator independently deploys and controls their own node.

## Get started

Stand up a node in a few commands — fetch + verify a signed release, then `scripts/fungi deploy`. See
**[QUICKSTART.md](QUICKSTART.md)**. Engine versions/checksums are pinned and resolved automatically;
the release is signed and verifiable ([docs/RELEASING.md](docs/RELEASING.md)).

## Status

- **Phase 0 — Foundation (landed):** the deploy-ready node scaffold — multi-protocol data plane
  (sing-box + AmneziaWG), control tooling, provisioning, observability, conformance tests, runbooks.
- **Phase 1 — Distribution (closed):** genuine-TLS transports, a self-replenishing endpoint bundle,
  and a self-updating subscription — validated hands-on over real cellular and Wi-Fi links.
- **Phase 2 — Single-node adaptivity (closed):** the node-local *measure → detect → tune → rotate →
  roll back* loop — a network-state detector, a reinforce-and-decay self-tuner, and a gated
  auto-rotation with anti-flapping and rollback — proven driving itself on a live node. Control logic
  consolidated into a typed Go spine: *the shell deploys; the Go binary decides and adapts.*
- **Phase 3 — Living node (in progress):** end-to-end client recovery under a real block, a signed
  release + deploy CLI, and the **inert seams** for advisory network-weather and the face-to-face
  **hypha** boundary (no live federation yet). The first public release cuts after this phase.

Each phase is useful on its own and ships to production; the mesh is extended on top of something
already working. Full roadmap (phases 0→8, scope, Definition of Done): [docs/ROADMAP.md](docs/ROADMAP.md).

## Principles

1. **No custom cryptography or transports** — build on Xray/sing-box, AmneziaWG, libp2p and proven
   patterns; innovation lives in the adaptation layer ([ADR-0002](docs/adr/0002-no-custom-cryptography.md)).
2. **Indistinguishability over obfuscation** — statistically like legitimate HTTPS/QUIC, not "a hidden tunnel".
3. **Redundancy by default** — multiple protocols, ports, SNIs, IPs, ASes, and carriers at once.
4. **Degrade, don't fail** — losing a node or coordinator slows the network; it does not switch it off.
5. **Operator and user safety is requirement #1** — legal posture and opsec designed in from phase 0.

## Docs

- **[QUICKSTART.md](QUICKSTART.md)** — stand up a node · **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — layers, transport matrix, mesh design · **[docs/GLOSSARY.md](docs/GLOSSARY.md)** — terminology
- **[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md)** — adversary, surface, honest limits · **[SECURITY.md](SECURITY.md)** — policy & disclosure
- **[docs/development.md](docs/development.md)** — engineering charter (standards, layers, tests, CI) · **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to contribute
- **Records:** [docs/adr/](docs/adr/) (decisions) · [docs/proposals/](docs/proposals/) (work) · [docs/vision/](docs/vision/) · [docs/runbooks/](docs/runbooks/)
- **Governance & marks:** [GOVERNANCE.md](GOVERNANCE.md) · [TRADEMARKS.md](TRADEMARKS.md) · [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md)

## License & governance

The **code** is free software under the **GNU AGPL-3.0-or-later** ([LICENSE](LICENSE)): run, study,
modify, and redistribute it; if you run a modified version as a network service, make your changes
available to its users under the same license.

The project's **shared identity** — the Mycelium name, logo, bootstrap seeds, trust roots, and
spore-signing keys — is governed **separately** (not under the AGPL) and is **community-owned**: there
is no single owner, and as the network grows, decisions move to community consensus. A fork is welcome
but must use its own name. See [GOVERNANCE.md](GOVERNANCE.md), [TRADEMARKS.md](TRADEMARKS.md), and
[ACCEPTABLE-USE.md](ACCEPTABLE-USE.md).
