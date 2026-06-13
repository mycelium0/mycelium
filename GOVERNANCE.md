<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Governance (Shared Identity & Trust Roots)

> **Status:** canonical governance policy for Mycelium's **shared identity and trust roots**.
>
> **Author:** mindicator & silicon bags quartet
>
> **See also:** [TRADEMARKS.md](TRADEMARKS.md) (the name and shared-identity marks),
> [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md) (what the shared name, marks, and trust roots may not be
> used for), [LICENSE](LICENSE) (AGPL terms for the *code*),
> [docs/adr/0003-licensing-and-jurisdiction.md](docs/adr/0003-licensing-and-jurisdiction.md)
> (why the code is AGPL).

> **Software, not an operated network.** This repository publishes server-side software; it does not
> operate a public network, publishes no public endpoints, and distributes no public client configs.
> Each operator independently deploys and controls their own node (see the
> [README separation statement](README.md#what-this-is)). What this document governs is therefore
> **not** an operated network but Mycelium's **shared identity** — the name, marks, bootstrap seeds,
> trust roots, and spore-signing keys — and how independent nodes choose to associate with it.

This document explains, in plain language, how Mycelium's **shared identity and trust roots** are
governed. The **code** is free software under the AGPL and is not governed by this document — anyone
may run, study, modify, fork, and redistribute it. What is governed here is the **shared-identity
layer**: the bootstrap seeds, trust roots, voluntary federation between independently operated nodes,
and the **spore-signing keys** that anchor shared trust. There is **no single owner**: this identity
layer is **community-owned**, and approval moves to community/organization consensus as set out in
§6.

This is **project policy, not legal advice.**

---

## 1. The two layers, kept separate on purpose

It helps to hold two layers apart:

- **The code layer.** Open, forkable, AGPL ([LICENSE](LICENSE)). No permission needed, no governance
  attached. Fork it, change it, run it.
- **The shared-identity layer.** The bootstrap seeds, trust roots, spore-signing keys, certified
  nodes, and the "Mycelium" name when used to claim the shared identity. This layer carries trust, so
  it is governed — by the community, not by a single owner. It is **not** an operated network: each
  node remains independently deployed and controlled by its own operator.

Keeping them separate is the whole design: the **code stays free even if governance fails**, and the
**shared identity stays ethically governed even if the code is forked a thousand times**. Neither
goal weakens the other.

---

## 2. Three principles

These three principles are the heart of Mycelium's governance. They are stated plainly so anyone can
hold the project to them.

### Principle (i) — You cannot close the commons and sell a black box

No one may take Mycelium, close their modifications, and sell a black-box **"Enterprise"** product or
hosted service **without giving the service's users their changes**. This is exactly what the
**AGPL** ([LICENSE](LICENSE)) requires: if you run a modified version of Mycelium as a network
service, the people using that service are entitled to your modified source under the same license.
The improvements stay part of the commons. This applies to everyone equally, including the original
maintainers.

### Principle (ii) — Commercial allies are welcome and useful

This is **not** an anti-commercial project. Many commercial and institutional actors make the
ecosystem stronger, and they are explicitly welcome:

- **small hosting providers** running nodes and mesh segments;
- **NGOs with legal entities** that can hold contracts, grants, and accountability;
- **university spin-offs** and research groups;
- **cooperatives** and community-owned operators;
- **security auditors** who review the code and the deployments;
- **emergency-connectivity providers** standing up service where networks are unreliable or
  disaster-prone.

What we want from allies is concrete and mutual: **infrastructure, audits, hosting, grants,
releases, and upstream code.** A well-run commercial host that contributes back, gets audited, and
behaves honestly is an asset to the ecosystem, not a threat to it. (See §4 for the conditions on
hosted services.)

### Principle (iii) — The shared identity stays ethically governed even if the code is forked

Because anyone can fork the code, ethical governance cannot live in the license. It lives in the
**shared identity** the community holds in common: the **name**, the **bootstrap seeds**, the
**trust roots**, and the **spore-signing keys** (see [TRADEMARKS.md](TRADEMARKS.md)). These are not
held by a single owner; they are stewarded for the community under the consensus process in §6. A
fork is free to exist — but the **shared identity**, the thing people trust by name and by signature,
stays accountable to the project's values and to [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md). Fork the
code all you like; you do not fork the shared trust.

---

## 3. How the shared identity is governed

> Nothing in this section describes a network the project operates. It describes how an
> independently operated node, segment, seed, or operator may **associate with** the shared identity
> and carry shared trust — and how that association is granted, scoped, and withdrawn.

### 3.1 Admission

A mesh segment, bootstrap seed, trust root, or operator carries the **shared** identity by admission,
not automatically. Admission considers:

- **alignment** with [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md) and the project's values;
- **AGPL compliance** for any modified node software being run as a service;
- **operational soundness** — does this segment improve reachability, resilience, or coverage
  without concentrating knowledge or creating a permanent center;
- **transparency** about who operates it and under what jurisdiction;
- a **non-surveillance** posture consistent with the project's no-raw-telemetry stance.

Admission is the moment a segment, seed, or operator gets to carry shared trust — shared bootstrap
status, trust-root inclusion, certified-node marks, or federation. It is granted by the community
consensus process (§6), deliberately, and can be declined.

### 3.2 Revocation

Shared trust can be **revoked**. A segment, seed, trust root, certified node, or operator can have
its shared-identity status removed if it:

- uses the shared name, marks, or trust roots for a purpose prohibited by
  [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md);
- runs modified node software as a service without offering its source (an AGPL violation);
- misrepresents itself as carrying the shared identity, certified, or endorsed contrary to
  [TRADEMARKS.md](TRADEMARKS.md);
- behaves in a way that endangers users or the integrity of shared trust.

Revocation is expressed through the same trust machinery the shared-identity layer already uses:
removing trust-root inclusion, withdrawing certified-node status, ceasing federation, and — where
appropriate — issuing signed revocation notices, on the community consensus process (§6). Revocation
removes a party from the **shared identity**; it does not, and cannot, take away their AGPL rights
over the code, nor does it reach a node the operator continues to run independently under its own
name.

### 3.3 Community federation

Independent community segments may **federate** with one another under the shared identity using
scoped trust rather than central control, consistent with the project's decentralization goals.
Federation is a voluntary trust relationship between independently operated nodes that can be formed,
scoped, narrowed, and withdrawn — it does not require any segment to hand over a full map of itself,
and it does not crown a permanent center or a single owner.

---

## 4. Commercial hosted services

Commercial hosted services built on Mycelium are **allowed**, and can be valuable (Principle ii), but
to associate with, or present themselves as carrying, the **shared** Mycelium identity they must be:

- **AGPL-compliant** — service users can get the modified source ([LICENSE](LICENSE));
- **transparent** — clear about who operates the service and where;
- **non-surveillance** — no raw user telemetry, content logging, identity profiling, or behavioral
  tracking;
- **non-military** — consistent with [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md);
- **not advertised as "official Mycelium"** (or certified/endorsed) **without permission**
  ([TRADEMARKS.md](TRADEMARKS.md)).

A hosted service that meets these conditions is exactly the kind of commercial ally the project wants.
A hosted service that does not still has full AGPL rights to the **code** — it simply may not wear the
shared identity. In every case the service is the operator's own independently controlled deployment,
not part of any network the project operates.

---

## 5. Humanitarian Network Policy

The **shared bootstrap seeds, trust roots, and spore-signing keys** are governed by a standing
**Humanitarian Network Policy**. Because these are the cryptographic and social root of shared
trust — the thing that lets a node, route, or spore carry the shared identity — they carry an extra
duty:

- they are stewarded to serve the project's humanitarian purpose: keeping private connectivity
  available for real people on restrictive, unreliable, high-interference, and disaster-prone
  networks;
- they are **never** lent to, signed for, or used to bless any deployment that violates
  [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md);
- their use is conservative and accountable: the shared seeds, trust roots, and signing keys exist
  to anchor trust for people in need, not to expand any one party's reach for its own sake;
- if shared trust is misused, the policy is to **revoke** it through the trust machinery in §3.2 and
  to issue signed revocation where appropriate, on community consensus (§6).

The Humanitarian Network Policy is what makes Principle (iii) real in practice: it is the standing
commitment that governs the exact keys and seeds the community stewards in common.

---

## 6. Who approves changes — consensus, not a single owner

The shared identity is **community-owned**, so the authority to approve a network update — accepting a
new trust root, blessing a bootstrap seed, admitting or revoking an operator from the shared identity,
or merging a change to the canonical artifacts the fleet converges on — does **not** belong to any one
person.

- **From Phase 1–2 onward, approval is by community / organization consensus** — the project's
  **"fungi voting"** process, in which independently operated nodes and the stewarding organization
  reach consensus rather than a single owner signing off. As the mesh decentralizes
  (see [docs/ROADMAP.md](docs/ROADMAP.md)), this consensus is what **replaces single-owner approval**;
  it is the governance counterpart of the network's own "agree among themselves" behaviour. No single
  person holds a veto or a kill switch.
- **The interim (pre-consensus) state is deliberate and documented.** Before that consensus process
  is stood up, there is **no single legal signer** who could sign on behalf of a community-owned
  identity — so, on purpose, network updates are currently accepted **UNSIGNED / insecure**. This is a
  conscious, temporary state, not an oversight: signing would require designating a single owner,
  which the project is specifically avoiding. The fail-closed signature gate in the updater
  ([docs/runbooks/node-bootstrap.md](docs/runbooks/node-bootstrap.md)) is what each operator can opt
  into for their **own** node in the meantime, using their own out-of-band key — an operator-local
  control, not a project-wide signer.
- **The transition is one-way and recorded here.** When the consensus process is adopted, this
  section is updated to point at it; until then the unsigned interim above is the governing state.

---

## 7. Changes and standing

- This governance applies to the **shared identity and trust roots**, not to any network the project
  operates (it operates none); it does not add conditions to AGPL rights over the **code**.
- This policy may be updated through the community consensus process (§6); from Phase 1–2 onward no
  single owner amends it unilaterally. Updates do not retroactively revoke AGPL rights over code
  already received.
- This is **policy, not legal advice**, and creates no partnership, agency, or guarantee.

Questions about admission, federation, hosted-service status, or the Humanitarian Network Policy can
be raised through the channels in [SECURITY.md](SECURITY.md) and
[docs/contributing.md](docs/contributing.md).
