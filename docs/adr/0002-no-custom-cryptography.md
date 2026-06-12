<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0002: No Custom Cryptography — Standard Audited Primitives Only

## Metadata
- **ID:** ADR-0002
- **Date:** 2026-06-11
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** cross-cutting (primarily data plane), touching control plane and discovery
- **Phase:** cross-cutting, in force from Phase 0
- **Related:** [ADR-0001](0001-record-architecture-decisions.md),
  [../THREAT-MODEL.md](../THREAT-MODEL.md), [../development.md](../development.md) §2.2

## Context

Mycelium is built on tunnels that already encrypt: WireGuard/AmneziaWG (Curve25519,
ChaCha20-Poly1305, Noise IK), Xray/TLS 1.3, libp2p-noise. The temptation arises to
"strengthen" obfuscation with a custom cipher, a bespoke handshake, or a "secret" XOR layer
treated as a security boundary. Competing forces:

- **Threat model** ([../THREAT-MODEL.md](../THREAT-MODEL.md)): ML flow classification and active
  probing. A hand-rolled crypto/handshake is an anomaly that classifiers catch; custom schemes
  rarely survive active probing.
- **User safety (asset #1):** custom cryptography is historically catastrophic — home-grown
  primitives/modes/KDFs are nearly always breakable. The cost of a defect is user de-anonymization.
- **Law:** cryptographic-means licensing regimes (in some jurisdictions) apply regardless of who
  invented the primitive — inventing one's own therefore gives zero legal benefit at maximum risk.
  The dual-use export-control published-source exception, by contrast, relies on **standard,
  published** algorithms. (Detailed legal analysis is maintained in the maintainers' internal
  knowledge base.)
- **Indistinguishability:** to look like standard TLS, one must **use** standard TLS.

## Options Considered

1. **Standard audited primitives from upstream only** (chosen) — ChaCha20-Poly1305, Curve25519,
   Ed25519, AES-GCM, TLS 1.3, Noise — via established tools (Xray/sing-box, AmneziaWG,
   libp2p-noise).
   - Pros: security, indistinguishability (= standard TLS), clean legal/export position.
   - Cons: cannot "fix" a primitive ourselves — we depend on upstream
     (see [../dependency-policy.md](../dependency-policy.md)).

2. **Custom obfuscation crypto layer / bespoke handshake** (rejected).
   - Cons: vulnerabilities, ML-DPI fingerprint, legal risk without benefit.

3. **No explicit policy** (rejected) — leads to ad-hoc custom cryptography at the point of
   implementation.

## Decision

**Option 1.** Mycelium **never** implements its own cryptographic primitives or protocols. Only
standard audited primitives are used, exactly as provided by the upstream tool.
**Obfuscation ≠ cryptography:** shaping, padding, junk packets, header randomization, and
transport selection are all permitted — but they are **not a confidentiality boundary**;
confidentiality is held only by standard primitives. Any change touching cryptography must name
a specific upstream primitive; it must not introduce a new one.

## Consequences

- **Positive:** no home-grown crypto bugs; traffic is indistinguishable from standard TLS/Noise;
  clean export/legal position; cryptographic audit reduces to trusting upstream + provenance.
- **Negative / cost:** dependency on upstream (a compromised primitive is fixed only by updating
  the dependency — managed by [../dependency-policy.md](../dependency-policy.md)).
- **Impact on user safety (#1):** maximally reduces the risk of de-anonymization via cryptographic
  failure.
- **What becomes forbidden:** custom ciphers/modes/KDFs/handshake-crypto; "secret" XOR/obfuscation
  as a security boundary; "improving" primitives by forking a crypto core.

## Compliance

- Conformance test **`no_custom_crypto`** in CI gate (prohibits crypto code outside permitted
  upstream; lints for home-grown primitives/modes);
- [../dependency-policy.md](../dependency-policy.md) verifies provenance and versions of upstream
  cryptography;
- Review lens **Security/Threat** ([../refactoring.md](../refactoring.md)) must reject custom
  cryptography as S0/S1.
