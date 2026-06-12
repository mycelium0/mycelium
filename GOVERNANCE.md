<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Governance (Official Network)

> **Status:** canonical governance policy for the **official** Mycelium network.
>
> **Author:** mindicator & silicon bags quartet
>
> **See also:** [TRADEMARKS.md](TRADEMARKS.md) (the name and official-network identity),
> [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md) (what the official network may not be used for),
> [LICENSE](LICENSE) (AGPL terms for the *code*),
> [docs/adr/0003-licensing-and-jurisdiction.md](docs/adr/0003-licensing-and-jurisdiction.md)
> (why the code is AGPL).

This document explains, in plain language, how the **official Mycelium network** is governed. The
**code** is free software under the AGPL and is not governed by this document — anyone may run,
study, modify, fork, and redistribute it. What is governed here is the **official network**: the
official mesh segments, bootstrap seeds, trust roots, community federation, and the
**spore-signing keys** that anchor official trust.

This is **project policy, not legal advice.**

---

## 1. The two layers, kept separate on purpose

It helps to hold two layers apart:

- **The code layer.** Open, forkable, AGPL ([LICENSE](LICENSE)). No permission needed, no governance
  attached. Fork it, change it, run it.
- **The official-network layer.** The bootstrap seeds, trust roots, spore-signing keys, certified
  nodes, and the "Mycelium" name when used officially. This layer carries trust, so it is governed.

Keeping them separate is the whole design: the **code stays free even if governance fails**, and the
**official network stays ethically governed even if the code is forked a thousand times**. Neither
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
network stronger, and they are explicitly welcome:

- **small hosting providers** running nodes and mesh segments;
- **NGOs with legal entities** that can hold contracts, grants, and accountability;
- **university spin-offs** and research groups;
- **cooperatives** and community-owned operators;
- **security auditors** who review the code and the deployments;
- **emergency-connectivity providers** standing up service where networks are unreliable or
  disaster-prone.

What we want from allies is concrete and mutual: **infrastructure, audits, hosting, grants,
releases, and upstream code.** A well-run commercial host that contributes back, gets audited, and
behaves honestly is an asset to the network, not a threat to it. (See §4 for the conditions on hosted
services.)

### Principle (iii) — The official network stays ethically governed even if the code is forked

Because anyone can fork the code, ethical governance cannot live in the license. It lives in the
things the maintainers actually hold: the **name**, the **official bootstrap seeds**, the **trust
roots**, and the **spore-signing keys** (see [TRADEMARKS.md](TRADEMARKS.md)). A fork is free to exist
— but the **official** network, the one people trust by name and by signature, stays accountable to
the project's values and to [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md). Fork the code all you like; you
do not fork the official trust.

---

## 3. How the official network is governed

### 3.1 Admission

A mesh segment, bootstrap seed, trust root, or operator joins the **official** network by admission,
not automatically. Admission considers:

- **alignment** with [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md) and the project's values;
- **AGPL compliance** for any modified node software being run as a service;
- **operational soundness** — does this segment improve reachability, resilience, or coverage
  without concentrating knowledge or creating a permanent center;
- **transparency** about who operates it and under what jurisdiction;
- a **non-surveillance** posture consistent with the project's no-raw-telemetry stance.

Admission is the moment a segment, seed, or operator gets to carry official trust — official
bootstrap status, trust-root inclusion, certified-node marks, or federation. It is granted
deliberately and can be declined.

### 3.2 Revocation

Official trust can be **revoked**. A segment, seed, trust root, certified node, or operator can have
its official status removed if it:

- uses the official infrastructure for a purpose prohibited by
  [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md);
- runs modified node software as a service without offering its source (an AGPL violation);
- misrepresents itself as official, certified, or endorsed contrary to
  [TRADEMARKS.md](TRADEMARKS.md);
- behaves in a way that endangers users or the integrity of official trust.

Revocation is expressed through the same trust machinery the network already uses: removing trust-root
inclusion, withdrawing certified-node status, ceasing federation, and — where appropriate — issuing
signed revocation notices. Revocation removes a party from the **official** network; it does not, and
cannot, take away their AGPL rights over the code.

### 3.3 Community federation

Independent community segments may **federate** with the official network under scoped trust rather
than central control, consistent with the project's decentralization goals. Federation is a trust
relationship that can be formed, scoped, narrowed, and withdrawn — it does not require any segment to
hand over a full map of itself, and it does not crown a permanent center.

---

## 4. Commercial hosted services

Commercial hosted services built on Mycelium are **allowed**, and can be valuable (Principle ii), but
to operate as part of, or in association with, the **official** network they must be:

- **AGPL-compliant** — service users can get the modified source ([LICENSE](LICENSE));
- **transparent** — clear about who operates the service and where;
- **non-surveillance** — no raw user telemetry, content logging, identity profiling, or behavioral
  tracking;
- **non-military** — consistent with [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md);
- **not advertised as "official Mycelium"** (or certified/endorsed) **without permission**
  ([TRADEMARKS.md](TRADEMARKS.md)).

A hosted service that meets these conditions is exactly the kind of commercial ally the project wants.
A hosted service that does not still has full AGPL rights to the **code** — it simply may not wear the
official identity.

---

## 5. Humanitarian Network Policy

The **official bootstrap seeds, trust roots, and spore-signing keys** are governed by a standing
**Humanitarian Network Policy**. Because these are the cryptographic and social root of official
trust — the thing that makes a node, route, or spore "official" — they carry an extra duty:

- they are stewarded to serve the project's humanitarian purpose: keeping private connectivity
  available for real people on restrictive, unreliable, high-interference, and disaster-prone
  networks;
- they are **never** lent to, signed for, or used to bless any deployment that violates
  [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md);
- their use is conservative and accountable: the official seeds, trust roots, and signing keys exist
  to anchor trust for people in need, not to expand the network's reach for its own sake;
- if official trust is misused, the policy is to **revoke** it through the trust machinery in §3.2 and
  to issue signed revocation where appropriate.

The Humanitarian Network Policy is what makes Principle (iii) real in practice: it is the standing
commitment that governs the exact keys and seeds the maintainers hold.

---

## 6. Changes and standing

- This governance applies to the **official network**; it does not add conditions to AGPL rights over
  the **code**.
- The maintainers may update this policy; updates do not retroactively revoke AGPL rights over code
  already received.
- This is **policy, not legal advice**, and creates no partnership, agency, or guarantee.

Questions about admission, federation, hosted-service status, or the Humanitarian Network Policy can
be raised through the channels in [SECURITY.md](SECURITY.md) and
[docs/contributing.md](docs/contributing.md).
