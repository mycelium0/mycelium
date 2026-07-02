<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Dependency and Supply-Chain Policy

## 1. Why this is critical here
Mycelium deliberately **does not reinvent cryptography or transport**
([adr/0002-no-custom-cryptography.md](adr/0002-no-custom-cryptography.md)) — which means we
depend on upstream for the most sensitive components. For a persistent private network the
supply chain is an **attack surface of the first order**: a poisoned dependency equals mass
de-anonymisation or a ready-made blocking signature. Provenance and update control are therefore
held to a stricter standard than in a typical project.

## 2. Trusted upstream (core stack)
| Dependency | Role | Notes |
|---|---|---|
| Xray-core | VLESS/REALITY/Vision | primary transport; track releases (network-interference waves → fast patches) |
| sing-box | transport multiplexer | server-side; Hysteria2/TUIC |
| AmneziaWG | obfuscated WG | non-TLS fallback |
| libp2p | DHT/gossip/NAT (Phase 5+) | mesh |
| Caddy / nginx | cover site | standard web server |
| Cloudflare | CDN-front / WARP | external service; do not treat as a secrets store |
| Terraform / Ansible | provisioning/deploy | IaC |

## 3. Pinning and provenance
- **Pin by version AND by hash** (lockfiles, images by digest rather than tag).
- **Verify signatures/checksums** of upstream releases on introduction and update.
- **Reproducible builds** where upstream supports them; own artefacts are reproducible.
- **Mirror** critical upstream artefacts (to guard against source takedown or blocking).

## 4. Update cadence
- **Security updates** — priority, out of band (especially crypto/transport; see
  [refactoring.md](refactoring.md) severity S0/S1).
- **Feature updates** — planned, via RP when contracts or behaviour change.
- Updating a pin is a separate commit with a `Verification:` block (what was run) and the new
  hash recorded.

## 5. Vulnerability monitoring
- Track CVEs and advisories for every upstream in §2.
- Subscribe to security channels for Xray/sing-box/AmneziaWG/libp2p.
- A "protocol-wave" event (e.g. VLESS-TCP-TLS blocks following a classifier update) is treated
  as a security event.

## 6. Introducing a new dependency
A new external dependency is an **architecturally significant change** → RP + (when canon
changes) ADR. The RP must establish:
- **boundary argument** (principle #1): why this code should not live here, why upstream is the
  right home for it;
- **licence compatibility** with the choice in [adr/0003-licensing-and-jurisdiction.md](adr/0003-licensing-and-jurisdiction.md);
- **no phone-home:** the dependency must not transmit telemetry or identifiers (de-anonymisation
  risk);
- **project health:** activity, audits, number of maintainers (bus factor).

## 7. Prohibited
- Unpinned / floating dependencies in production (`latest`, floating image tags).
- Dependencies with built-in telemetry or phone-home on the data path or at the node.
- Abandoned upstream as a security boundary.
- Silent update of a crypto/transport dependency without a `Verification:` entry and without
  running conformance (`no_custom_crypto`, netsim adversary scenarios).

## 8. Version currency / floors (ADR-0028, ADR-0031)
Currency is not housekeeping here — it is **load-bearing for indistinguishability**. An aged TLS
fingerprint, a non-PQ handshake, or a missing post-handshake mimicry is itself a detection signal,
so a transport-stack element pinned **below its declared floor is a detectability defect** that
MUST be recorded and scheduled, never treated as optional.
- **Honor the declared floors.** [adr/0028-dependency-and-transport-currency-policy.md](adr/0028-dependency-and-transport-currency-policy.md)
  carries machine-readable `floor:` lines (sing-box, Xray-core for post-handshake mimicry / PQ
  REALITY, AmneziaWG 2.0-class, uTLS); the offline gate `dependency_policy.sh` FAILS a recorded pin
  that is below any floor, and checks that the [reference/transport-technique-landscape.md](reference/transport-technique-landscape.md)
  annex carries a `last-verified:` line. Keep that annex fresh — stale past one quarter is a defect.
- **No fork to meet a floor.** Currency means **adopting vetted upstream primitives faster** —
  never forking, hand-rolling, or patching a crypto/transport primitive to satisfy a floor (binds
  [adr/0002-no-custom-cryptography.md](adr/0002-no-custom-cryptography.md) / `no_custom_crypto`).
- **Stage a live bump one-node-first.** Bump a live engine pin **staged, one node first**, with a
  `Verification:` block and a conformance run — never the whole network in one move (the
  prior-outage lesson). Every engine-pin bump re-checks the floors **and** the landscape annex in
  the **same** change.
- **Respect engine asymmetry.** Serve a hardening shape on the engine that actually carries it: PQ
  REALITY and post-handshake mimicry are **Xray-only**, AmneziaWG 2.0 is **awg-only**. Never enable
  PQ REALITY or assume post-handshake parity on sing-box before upstream parity is confirmed
  ([adr/0010-phase0-transport-set.md](adr/0010-phase0-transport-set.md) engine-asymmetry note).
- **Reuse is one-way into AGPL.** Any adopted/wrapped upstream is licence-checked one-way-compatible
  into AGPL-3.0-or-later (MIT/BSD/Apache-2.0, LGPL/GPL-with-linking); Mycelium stays AGPL and retains
  upstream notices ([adr/0031-build-vs-reuse-compose-proven-patterns.md](adr/0031-build-vs-reuse-compose-proven-patterns.md)).
