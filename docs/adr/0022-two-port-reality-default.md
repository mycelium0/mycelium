<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0022: `Two-port REALITY default on the bootstrap deploy path (Vision + gRPC)`

> **Document type.** ADR. Records **one** bound decision: the default-on transport set a fresh node
> exposes when provisioned via the bash bootstrap path, and why it differs from the conservative
> Ansible/group_vars default. Saved as `docs/adr/0022-two-port-reality-default.md`.
>
> **See also:** [0010-phase0-transport-set.md](0010-phase0-transport-set.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [0020-phase0-scope-reconciliations.md](0020-phase0-scope-reconciliations.md),
> [../THREAT-MODEL.md](../THREAT-MODEL.md), [../refactoring.md](../refactoring.md) (Audit-0004 F-004).

---

## Metadata

- **ID:** ADR-0022
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** data plane (transport exposure), deploy/bootstrap
- **Phase:** Phase 0
- **Related:** ADR-0010 (transport set), ADR-0014 (per-operator credentials), ADR-0020 (Phase-0 scope
  reconciliations — D2 second family), Audit-0004 finding F-004.

## Context

A full-scale audit (Audit-0004, F-004) found that the bash bootstrap's `write_params`
(`scripts/node-bootstrap.sh`) enables **two** REALITY transports by default — VLESS+REALITY+XTLS-Vision
on `443/tcp` **and** VLESS+REALITY+gRPC on `8443/tcp` — so every bootstrapped node opens a second
always-on port. Every *other* authoritative source kept gRPC OFF: the Ansible `group_vars` default,
the role defaults, and the `per_protocol_toggle.sh` gate (which asserts only Vision may default-on).
The two-port live default was recorded only in an inline code comment ("friends alpha, Variant A"),
with no decision record, no THREAT-MODEL entry, and no gate covering the live source — a
`CONFLICTING_SOURCE_OF_TRUTH` between deploy paths and an undocumented departure from the documented
single-`443` minimal-exposure posture.

Two facts shape the decision:

1. **gRPC is the SAME transport family as Vision.** Both are `reality-tls-tcp` (ADR-0020 §5): the same
   REALITY handshake fingerprint surface, the same donor, the same per-node X25519 keypair. A second
   REALITY port is **not** a second *independent* family for the Phase-0 D2 bar — the sanctioned
   independent second family remains **AmneziaWG/UDP** (ADR-0020 §5). gRPC adds a second *shape on a
   second port*, useful for client-side failover, not transport-family diversity.
2. **The operator relies on the REALITY+gRPC shape in the field.** Disabling it to satisfy the
   single-port posture would remove a path that is in real use for failover.

## Decision

1. **Accept the two-port REALITY default ("Variant A") for the bash bootstrap deploy path.** A fresh
   node provisioned via `node-bootstrap.sh` exposes, by default, exactly **two** REALITY transports —
   Vision (`443/tcp`) and gRPC (`8443/tcp`) — and **nothing else** (HY2/TUIC/Shadowsocks/ShadowTLS/
   Trojan stay OFF behind their toggles; AmneziaWG is the separate sanctioned second family). Both
   REALITY ports are donor-fronted and present a genuine TLS handshake (no new fingerprint class).

2. **The conservative Ansible/`group_vars` default stays Vision-only.** The two deploy paths
   legitimately differ: the bootstrap path optimises for the alpha cohort's failover; the Ansible
   path optimises for minimal default exposure. This divergence is intentional and recorded here, not
   a defect.

3. **The live default-on set is pinned by a conformance gate.** `tests/conformance/live_artifact_posture.sh`
   asserts the bootstrap default-on set is **exactly** `{vless_reality_vision, vless_reality_grpc}`.
   The set cannot grow a new always-on ingress (e.g. enabling HY2 by default) without tripping the
   gate **and** amending this ADR + the THREAT-MODEL port posture first.

## Consequences

- **Gain:** client-side failover between two REALITY shapes on independent ports — if one port is
  interfered with, the other remains, with no manual reconfiguration. Matches real field use.
- **Cost (accepted):** one extra always-on port (`8443`) is a marginally larger scan/enumeration
  surface than a single-`443` node. This is acknowledged in [THREAT-MODEL.md](../THREAT-MODEL.md)'s
  port-posture statement. Active-probing indistinguishability (D3) is **unaffected**: `8443` is
  REALITY-fronted and relays to the genuine donor exactly as `443` does.
- **Not a D2 second family.** Because Vision and gRPC share the REALITY family, a block of the REALITY
  family blocks both; the Phase-0 two-independent-family bar is met by AmneziaWG/UDP, not by this
  second port (ADR-0020 §5; `transport_family_independence.sh`).
- **Change control:** altering the default-on set requires editing this ADR, the THREAT-MODEL port
  posture, and `live_artifact_posture.sh` together — they are kept in lockstep by the gate.
