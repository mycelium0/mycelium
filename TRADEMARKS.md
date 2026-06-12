<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Trademark & Naming Policy

> **Status:** canonical naming and marks policy.
>
> **Author:** mindicator & silicon bags quartet
>
> **See also:** [GOVERNANCE.md](GOVERNANCE.md) (how the official network is governed),
> [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md) (what the official network may not be used for),
> [LICENSE](LICENSE) (the AGPL terms that cover the *code*),
> [docs/adr/0003-licensing-and-jurisdiction.md](docs/adr/0003-licensing-and-jurisdiction.md)
> (why the code is AGPL).

This document is written in plain language so contributors, operators, and people who want to fork
the project can understand it without a lawyer. It is **project policy, not legal advice.** If you
need to know how this interacts with the law in your situation, talk to a qualified lawyer.

---

## 1. The short version

Two different things live in this project, and they are governed differently:

1. **The code.** Everything in this repository is free software under the
   **GNU Affero General Public License v3.0 or later** ([LICENSE](LICENSE)). You may **run, study,
   modify, and redistribute** it. You may **fork** it. You may build your own network with it. The
   AGPL gives you those rights and we will not take them away.

2. **The name and the official network's identity.** The word **"Mycelium"** as the name of this
   project, the project's logos and visual marks, the identity of the **official Mycelium network**,
   the **certified-node** marks, and the marks used for the **official bootstrap seeds, trust roots,
   and spore-signing keys** are **not** licensed under the AGPL and are **not** granted to you by it.

In one sentence: **the code is open and forkable; the name and the official network's identity are
not.** A fork is welcome — it just has to use its own name.

---

## 2. What is *not* covered by the AGPL

The AGPL is a copyright license for software. It does **not** grant any right to use the project's
name, brand, or the identity of the official network. The following are **reserved** and are **not**
licensed to you simply because you received or forked the code:

- the name **"Mycelium"** used to identify this project or a connectivity network;
- the project **logo(s)** and visual marks;
- the identity and naming of the **official Mycelium network** and its official mesh segments;
- the **"certified node"** / certified-operator marks;
- the marks, names, and identifiers associated with the **official bootstrap seeds**, the official
  **trust roots**, and the official **spore-signing keys**;
- the **official reputation** built up by the network and its maintainers;
- any positioning, wording, or presentation that calls something **"official Mycelium"**, "the
  Mycelium network", "endorsed by Mycelium", "certified by Mycelium", or anything a reasonable
  person would read the same way.

These are reserved so that, even though anyone may fork the code, there remains **one identity** that
people can trust to be governed under the project's stated values
([GOVERNANCE.md](GOVERNANCE.md), [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md)). The name is how people tell
"the network the maintainers stand behind" apart from "some other operator's network".

---

## 3. What you *may* do without asking

You have broad freedom. Without any permission from us you may:

- **run** Mycelium, for yourself, your community, your organization, or your customers;
- **study** the source and learn from it;
- **modify** it however you like;
- **redistribute** it under the AGPL (including your modifications, per the AGPL);
- **fork** it and start your own project and your own network;
- **describe** what your software is, factually and honestly — for example: "this service is built
  on Mycelium", "based on the Mycelium project", "a fork of Mycelium", "compatible with Mycelium" —
  as long as you do **not** imply that your thing **is** the official Mycelium network, or that it
  is endorsed, certified, or operated by the Mycelium maintainers when it is not. Honest,
  descriptive **"built on / based on / fork of"** references are fine and encouraged. Claims of
  being **official, endorsed, or certified** are not.

Plain rule of thumb: **describe your relationship to Mycelium truthfully; do not borrow its
identity.**

---

## 4. What needs permission

You need written permission from the maintainers to:

- use **"Mycelium"** (or a confusingly similar name) **as the name of your product, service, or
  network**;
- present your deployment as **"official Mycelium"**, "the Mycelium network", or part of it;
- use the project **logo(s)** or visual marks as your own branding;
- describe your nodes as **"certified"** or **"official"** Mycelium nodes;
- use, distribute, or present yourself as a source of the **official bootstrap seeds, trust roots,
  or spore-signing keys**, or to imply your keys/seeds carry the official chain of trust;
- claim **endorsement, certification, partnership, or official status** of any kind.

We expect to say **yes** to a lot of these for aligned operators and allies — see
[GOVERNANCE.md](GOVERNANCE.md) for who is welcome and how admission works. The point of asking is so
the **official** identity stays accountable, not to make life hard for good-faith operators.

---

## 5. If you fork, please rename

This is the most important practical rule, and it is friendly, not adversarial:

> **A fork must use its own name.**

If you take the code and run a separate project or a separate network — especially one with **its
own** bootstrap seeds, **its own** trust roots, and **its own** spore-signing keys — that is a
genuinely different network with a different chain of trust and different governance. Calling it
"Mycelium" would tell people it carries the official identity and values when it does not. That is
confusing at best and unsafe at worst, because people make **trust** decisions based on the name.

So: keep the AGPL rights, keep the credit ("a fork of Mycelium"), and **choose a new name** for the
fork. You can still say, accurately, that it is built on or forked from Mycelium.

---

## 6. Why the name is held separately

People rely on the name to decide whom to trust with their connectivity. The official bootstrap
seeds, trust roots, and spore-signing keys are the cryptographic root of that trust. If anyone could
attach the **name and the official identity** to an arbitrary network, the name would stop meaning
anything, and a network adversary or a bad-faith operator could stand up something that *looks*
official in order to mislead users.

Holding the name and the official-network marks separately from the code is what lets us keep the
promise in [GOVERNANCE.md](GOVERNANCE.md): the code is fully open and forkable, **and** there is one
identity that stays ethically governed even if the code is copied a thousand times. The two goals do
not conflict — open code plus a held name is exactly how both can be true at once.

---

## 7. Enforcement posture

Our intent is **proportionate and good-faith**. We are not interested in policing honest
"built on / fork of" language, hobby experiments, research, or aligned community operators. We are
interested in stopping uses that **mislead people about trust** — for example, a network falsely
presented as "official Mycelium", or seeds/keys falsely presented as the official trust roots.

If you are unsure whether your planned use is fine, **ask first**. We would much rather have a short
friendly conversation than a misunderstanding.

---

## 8. Reservations and changes

- Nothing in this policy reduces the rights the AGPL grants you over the **code**. Where this policy
  and the AGPL could ever appear to conflict over the *code*, the AGPL governs the code.
- This policy concerns the **name, marks, and official-network identity** only.
- The maintainers may update this policy; updates do not retroactively revoke AGPL rights over code
  you already received.
- This is **policy, not legal advice**, and does not create any partnership, agency, or guarantee.

If you have questions about naming, marks, or permission, contact the maintainers through the
channels listed in [SECURITY.md](SECURITY.md) and [docs/contributing.md](docs/contributing.md).
