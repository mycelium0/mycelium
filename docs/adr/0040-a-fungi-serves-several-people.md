<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0040: A fungi serves several independent people, and everything follows from that

> Records **one** decision the corpus never made: a fungi is **multi-tenant**. It serves several people
> who need not know one another, whose networks differ, and whose access must be grantable and
> revocable independently. The doctrine had been silent on this — searched across the vision set, the
> ADR set, THREAT-MODEL, ARCHITECTURE, GLOSSARY, ROADMAP, README, SECURITY, QUICKSTART and
> development.md, there was no statement either way — and four defects measured in Audit-0012 are all
> consequences of that silence rather than four separate mistakes.
>
> Saved as `docs/adr/0040-a-fungi-serves-several-people.md`.

---

## Metadata
- **ID:** ADR-0040
- **Date:** 2026-08-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted (decision binding; the credential half implemented per its RP)
- **Layer(s):** Layer 2 (identity/keys, config, detector/rotation); cross-cutting (threat model)
- **Phase:** Phase 2 — the decision binds now; the credential implementation is a patch-release RP
- **Related:** [ADR-0039](0039-client-vantage-reachability-signal.md) (what a node can observe — this
  ADR promotes its corollary to a decision), [ADR-0034](0034-unified-node-profile.md) (one node form),
  [ADR-0010](0010-phase0-transport-set.md) (introduced the four shared-secret families; its stated
  consequence is re-scoped here), [ADR-0015](0015-network-artifact-delivery-and-node-update.md)
  (per-node identity, "per-protocol secrets" — the phrase this ADR disambiguates),
  [ADR-0027](0027-selective-growth-and-in-region-ingress.md) (never silently full-tunnel),
  [RP-0013](../proposals/0013-phase3-e2e-client-recovery.md) (≥2 independent families per node)

---

## 1. Context — the silence, and what filled it

Audit-0012 measured four things. Read separately they look unrelated:

1. `--revoke` removes a client's UUID and prints *"the client's UUID is gone from every inbound on BOTH
   engines"*. On hysteria2, shadowsocks, shadowtls and trojan the removed person keeps access, because
   those families authenticate against a **node-wide** secret every client holds identically. Measured:
   two clients' emitted subscriptions are byte-identical on those families.
2. The rotation planner is shaped around a single `Active` member and a single `ActiveVerdict`, so the
   node's health is the health of one transport.
3. Nothing in the planner distinguishes a transport the node **terminates** (a client dials in) from one
   the node **dials** — although the two differ in what the node can observe about them, which
   ADR-0039 established.
4. Nothing prevents the loop from taking away a transport that is, at that moment, carrying somebody's
   traffic.

They are one thing. **Every one of them is correct if a fungi serves one person, and wrong if it serves
several.** A single-tenant node loses nothing by sharing a secret across its own devices, has one
transport that matters, need not care which direction a member serves in, and can drop any transport
because the only person affected is the operator.

Nobody chose single-tenancy. It was never written down — and code written without the question in view
answered it by default, four times, in four files.

The one adjacent statement in the corpus is ADR-0010's consequence: *"the node learns nothing new about
users — no per-user attribution or access logging is introduced by adding transports."* That sentence is
true **only because** the credentials are node-wide: a node cannot attribute what it cannot distinguish.
It is an accurate observation that quietly documented an unchosen architecture.

## 2. Decision

**A fungi serves several people who need not know one another.** Their networks differ, so the transport
that works for one may be unusable for another; their access is granted and revoked independently.

Four consequences, each binding.

### 2.1 Credentials are per person, and revocation is per person

Every family a node serves must authenticate each person on material **only that person holds**.
Revoking one person must not require re-minting anyone else's access, and must not leave the revoked
person authenticated on any served family.

**Constraints on how**, so this is not read as licence:

- Per-person material comes from **each engine's own multi-user facility** and its standard key or
  password generation. Deriving a person's credential from a node secret plus a name is a hand-rolled
  KDF, and `development.md` §2.2 item 1 makes that **S0, merge blocked**.
- The identity layer owns it (`development.md` §2.4: *"Client identities/keys, issuance/revocation →
  Layer 2"*). One store, one owner. Not a copy in params, another in the rendered engine config, and a
  third in the subscription renderer.
- It lands through **one** credential-rendering seam. `development.md` §2.2 item 7: if connecting a
  transport requires edits across the tree, the contract model is the defect, not the transport.

**Re-scoping ADR-0010 honestly.** Its consequence must now read: *the node distinguishes people, because
it must be able to revoke one without revoking the rest; it still records no per-user attribution and no
access log.* **Distinguishable is not attributable.** Holding a credential per person is what makes
revocation possible; writing down who used which transport when is what ADR-0039 §2.2 and
`development.md` §2.2 item 2 forbid, and neither this ADR nor its RP introduces it. The node knows that
a credential exists; it does not learn who used it, when, or for what.

**Until the RP lands**, the honest position is the one Audit-0012 forces: on a node serving any
shared-secret family, `--revoke` **must refuse to claim** the person was removed, name the families,
name them as still admitted, and exit non-zero. A guarantee is earned, not printed — the AmneziaWG half
of the same verb already works this way and is the pattern to port.

### 2.2 The planner judges a set, not a member

A node's health is not the health of one transport. The planner's input is the **served set**, each
member with its own verdict; suppression is per member; and no single member's state stands for the
node.

This promotes ADR-0039's corollary — *"any planner input shaped around one active transport is a defect
against this ADR and against ADR-0034"* — from an observation to a decision with an owner. The singleton
`Active` / `ActiveVerdict` in the planner input is that defect, and is to be replaced rather than
worked around.

### 2.3 Ingress and egress are different roles, because they differ in what is observable

- **Ingress** — the client dials the node. The node terminates it. Its loopback probe (ADR-0036) can
  establish that the **listener serves**; it can never establish that a given person's network reaches
  it, because the node is not on that network. Whether an ingress member works is a property of the
  node **and** of the client.
- **Egress** — the node dials outward, to an upstream, a peer or a cover host. Here the node **is** the
  client, so its own probe is end-to-end evidence for exactly the path in question. Whether an egress
  member works is a property of the node alone.

ADR-0039 established this asymmetry for *evidence*. This ADR makes it a **typed role on the member**, so
the distinction is machine-checkable rather than remembered: evidence admissible for one role is
refused for the other by construction, not by review.

The multi-tenant reading is what makes the asymmetry matter. With one person, "can the client reach it"
and "does the listener work" collapse into one question the operator answers by trying. With several,
they cannot: the transport that fails for one person is serving another right now.

### 2.4 The loop may not take away a channel that is working for somebody

A suppression removes a transport from **everyone**. The node cannot see whose sessions it is ending —
by design, it holds no per-user attribution (§2.1). Therefore:

**A member that is carrying traffic is not suppressed, whatever the probe says.** A probe failure is not
permission to disconnect the people visibly succeeding on that member. The failure the loop is reacting
to is, by construction, one those people are not experiencing.

This is not a softening of the loop's fail-closed posture; it is that posture applied to the right
subject. Fail-closed against **serving something broken** argues for suppression. Fail-closed against
**taking working access away from people whose situation you cannot observe** argues against it. When a
member is demonstrably carrying traffic, the second is the stronger claim, because the harm is certain
and immediate while the fault is inferred from a signal that cannot see those users.

The RP-0013 floor of ≥2 independent families is the same principle in the other direction: the loop may
never reduce the node below the diversity a blocked person needs to still have somewhere to go.

## 3. Consequences

**Positive.** Four measured defects become one decided question with four checkable rules. The
credential model stops being implicit. The planner stops speaking about "the active transport" as though
a node had one. The evidence asymmetry becomes a type rather than a convention. And the loop acquires
the one guard that distinguishes "this is broken" from "this is broken for me".

**Negative, and accepted.** Per-person credentials mean more secret material per node and a real
migration for existing nodes, which must not silently invalidate anyone's working access. Distinguishing
people is a step toward being able to attribute them; §2.1 states the boundary, and the RP must show
that no attribution surface is added — a claim its gates must hold, not its prose.

**Operational, immediately.** Until the credential RP lands, every document that says a client can be
revoked must say what `--revoke` actually does, per family. Four documents currently assert otherwise
and `phase0-acceptance-ledger.md` scores it DONE; both are corrected as part of accepting this ADR.

## 4. What would change this decision

- A decision that a fungi is **single-tenant** — one operator, their own devices — which would make the
  shared-secret model correct and this ADR unnecessary. That is a coherent product, and it is not the
  one being built: the operator's own statement, which this ADR records, is that several people with
  different constraints connect to one fungi.
- An engine whose multi-user facility cannot express per-person credentials for a family this project
  serves. That would not reopen the decision; it would remove that family from the served set, or move
  it behind an explicit "shared secret, no independent revocation" label the operator opts into.
