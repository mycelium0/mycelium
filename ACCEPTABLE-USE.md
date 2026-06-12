<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Acceptable-Use Policy (Shared Name, Marks & Trust Roots)

> **Status:** canonical acceptable-use policy for the **shared** Mycelium name, marks, and trust
> roots.
>
> **Author:** mindicator & silicon bags quartet
>
> **See also:** [GOVERNANCE.md](GOVERNANCE.md) (how the shared identity is governed and how
> revocation works), [TRADEMARKS.md](TRADEMARKS.md) (the name and shared-identity marks),
> [LICENSE](LICENSE) (the AGPL terms that cover the *code*).

This policy is written in plain language. It is **project policy, not legal advice.**

> **Software, not an operated network.** This repository publishes server-side software; it does not
> operate a public network, publishes no public endpoints, and distributes no public client configs.
> Each operator independently deploys and controls their own node (see the
> [README separation statement](README.md#what-this-is)). This policy therefore restricts use of the
> **shared name, marks, and trust roots**, not use of a network the project runs (it runs none).

---

## 1. What this policy covers, and what it does not

This policy applies to Mycelium's **shared identity**, specifically:

- the **shared bootstrap seeds**;
- the shared **trust roots** and **spore-signing keys**;
- the **certified nodes** and certified-operator status;
- the **shared Mycelium identity** carried by independently operated mesh segments;
- the **"Mycelium" name and marks** when used to present something as carrying the shared identity
  (see [TRADEMARKS.md](TRADEMARKS.md)).

**It does not attach to the AGPL code itself.** The code is free software ([LICENSE](LICENSE)):
anyone may run, study, modify, fork, and redistribute it, and this policy does not — and cannot —
add conditions to those AGPL rights. These use restrictions attach to the **shared name, marks, and
trust roots** by way of trademark and this policy, not to the software license. If you fork and
rename (see [TRADEMARKS.md §5](TRADEMARKS.md)), you are running *your own* independently controlled
node or network, governed by *you*; you are simply not carrying the shared Mycelium identity and may
not present yourself as doing so.

In short: this is the rule for **"may I use the shared seeds, trust roots, signing keys, certified
status, and name"** — not the rule for **"may I use the code"**. The code answer is always yes,
under the AGPL.

---

## 2. Prohibited uses of the shared name, marks, and trust roots

The shared Mycelium name, marks, and trust roots **may not** be used for, or knowingly in support
of, any of the following:

1. **Military operations.** Use as part of military operations, command, logistics, or targeting.
2. **Targeting, surveillance, or repression of civilians.** Identifying, tracking, profiling,
   locating, or otherwise targeting civilians for surveillance or repression.
3. **Mercenary or private-military activity.** Use by, or in support of, mercenary or
   private-military operations.
4. **Weapons command and control.** Any role in the command, control, guidance, or operation of
   weapons systems.
5. **Enforcement of population-scale network restrictions or suppression of lawful expression, or
   persecution.** Use to help enforce population-scale network restrictions, to suppress lawful
   expression, or to persecute people.
6. **Malware, botnets, fraud.** Distributing malware, operating botnets or command-and-control,
   committing fraud, or comparable abuse of others' systems.
7. **Stalking and coercive monitoring.** Stalking, harassment, or coercive monitoring of any
   person, including intimate-partner or household monitoring without free consent.

This list describes the kinds of harm the shared identity refuses to bless. It is meant to be read
in good faith and in spirit, not gamed on technicalities. If something is clearly within the same
family of harm, treat it as prohibited.

---

## 3. Why these restrictions exist

Mycelium exists to keep **private connectivity available** on unreliable, high-interference, and
disaster-prone networks. The shared identity — the bootstrap seeds, trust roots, spore-signing keys,
and certified nodes — is the part of the project that the community stewards in common and puts its
shared trust signatures on. It would betray the purpose of the project to let that specific, trusted
identity be turned toward the harms listed above.

So the shared identity draws a line: the **tool** is open to everyone, but the **shared, signed,
community-backed trust** is not a neutral utility for the harms listed above.

---

## 4. How this is enforced

Because these restrictions attach to the **shared name, marks, and trust roots** (not the AGPL code),
they are enforced through the mechanisms the community actually controls (by consensus, not by a
single owner — see [GOVERNANCE.md §6](GOVERNANCE.md)):

- **revocation** of shared trust: a node, segment, seed, or operator that uses the shared name,
  marks, or trust roots for a prohibited purpose can have its certified status, trust-root inclusion,
  or federation removed (see [GOVERNANCE.md](GOVERNANCE.md));
- **withdrawal of the name and marks**: presenting a prohibited deployment as "official Mycelium" is
  also a naming/marks violation under [TRADEMARKS.md](TRADEMARKS.md);
- **the Humanitarian Network Policy** governing the shared bootstrap, trust roots, and
  spore-signing keys (see [GOVERNANCE.md](GOVERNANCE.md)).

What this policy **cannot** do is reach into a renamed fork, or any independently operated node, that
uses none of the shared name, marks, or trust roots. That is a deliberate consequence of keeping the
code free: enforcement lives at the level of trust, identity, and the shared keys — not as a
restriction on software freedom, and not over a network the project does not operate.

---

## 5. Reporting and good faith

If you believe the shared Mycelium name, marks, or trust roots are being used for a prohibited
purpose, report it through the channels in [SECURITY.md](SECURITY.md). Reports are handled in good faith and with care for the
safety of the people involved.

This is **policy, not legal advice**, and the maintainers may update it. Updates do not retroactively
change the AGPL rights you hold over code you already received.
