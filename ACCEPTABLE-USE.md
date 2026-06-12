<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Mycelium Acceptable-Use Policy (Official Network)

> **Status:** canonical acceptable-use policy for the **official** Mycelium network and marks.
>
> **Author:** mindicator & silicon bags quartet
>
> **See also:** [GOVERNANCE.md](GOVERNANCE.md) (how the official network is governed and how
> revocation works), [TRADEMARKS.md](TRADEMARKS.md) (the name and official-network identity),
> [LICENSE](LICENSE) (the AGPL terms that cover the *code*).

This policy is written in plain language. It is **project policy, not legal advice.**

---

## 1. What this policy covers, and what it does not

This policy applies to the **official Mycelium infrastructure and identity**, specifically:

- the **official bootstrap seeds**;
- the official **trust roots** and **spore-signing keys**;
- the **certified nodes** and certified-operator status;
- the **official Mycelium network** and its official mesh segments;
- the **"Mycelium" name and marks** when used to present something as official
  (see [TRADEMARKS.md](TRADEMARKS.md)).

**It does not attach to the AGPL code itself.** The code is free software ([LICENSE](LICENSE)):
anyone may run, study, modify, fork, and redistribute it, and this policy does not — and cannot —
add conditions to those AGPL rights. These use restrictions attach to the **official network and
marks** by way of trademark and this policy, not to the software license. If you fork and rename
(see [TRADEMARKS.md §5](TRADEMARKS.md)), you are running *your* network, governed by *you*; you are
simply not running the official one and may not present it as such.

In short: this is the rule for **"may I use the official seeds, trust roots, signing keys, certified
status, and name"** — not the rule for **"may I use the code"**. The code answer is always yes,
under the AGPL.

---

## 2. Prohibited uses of the official infrastructure

The official Mycelium infrastructure and identity **may not** be used for, or knowingly in support
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

This list describes the kinds of harm the official network refuses to enable. It is meant to be read
in good faith and in spirit, not gamed on technicalities. If something is clearly within the same
family of harm, treat it as prohibited.

---

## 3. Why these restrictions exist

Mycelium exists to keep **private connectivity available for real people** on restrictive,
unreliable, high-interference, and disaster-prone networks. The official infrastructure — the
bootstrap seeds, trust roots, spore-signing keys, and certified nodes — is the part of the project
that the maintainers personally stand behind and put their trust signatures on. It would betray the
whole purpose of the project to let that specific, trusted infrastructure be turned against the very
people it is meant to protect.

So the official network draws a line: the **tool** is open to everyone, but the **official, signed,
maintainer-backed network** is not a neutral utility for the harms listed above.

---

## 4. How this is enforced

Because these restrictions attach to the **official network and marks** (not the AGPL code), they are
enforced through the mechanisms the maintainers actually control:

- **revocation** of official trust: a node, segment, seed, or operator that uses the official
  infrastructure for a prohibited purpose can have its certified status, trust-root inclusion, or
  federation removed (see [GOVERNANCE.md](GOVERNANCE.md));
- **withdrawal of the name and marks**: presenting a prohibited deployment as "official Mycelium" is
  also a naming/marks violation under [TRADEMARKS.md](TRADEMARKS.md);
- **the Humanitarian Network Policy** governing the official bootstrap, trust roots, and
  spore-signing keys (see [GOVERNANCE.md](GOVERNANCE.md)).

What this policy **cannot** do is reach into a renamed fork that uses none of the official
infrastructure. That is a deliberate consequence of keeping the code free: enforcement lives at the
level of trust, identity, and the official keys — not as a restriction on software freedom.

---

## 5. Reporting and good faith

If you believe the official infrastructure is being used for a prohibited purpose, report it through
the channels in [SECURITY.md](SECURITY.md). Reports are handled in good faith and with care for the
safety of the people involved.

This is **policy, not legal advice**, and the maintainers may update it. Updates do not retroactively
change the AGPL rights you hold over code you already received.
