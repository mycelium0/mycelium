<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# ADR-0015: `Network artifact-delivery and node-update model — signature-gated pull, fail-closed apply`

> **Document type.** ADR (Architectural Decision Record). Records **one** bound
> decision: how canonical artifacts reach every node and how a node updates itself, as
> implemented by `scripts/node-bootstrap.sh` (the on-node bootstrap + semi-auto updater).
> Saved as `docs/adr/0015-network-artifact-delivery-and-node-update.md`.
>
> **See also:** [0002-no-custom-cryptography.md](0002-no-custom-cryptography.md),
> [0010-phase0-transport-set.md](0010-phase0-transport-set.md),
> [0013-mycelial-vocabulary-and-phase-discipline.md](0013-mycelial-vocabulary-and-phase-discipline.md),
> [0014-per-operator-node-credentials.md](0014-per-operator-node-credentials.md),
> [../proposals/0002-phase0-live-verified-hardened-node.md](../proposals/0002-phase0-live-verified-hardened-node.md),
> the forthcoming [RP-0003](../proposals/) (network update / artifact-delivery migration),
> [../runbooks/node-bootstrap.md](../runbooks/node-bootstrap.md),
> [../../scripts/node-bootstrap.sh](../../scripts/node-bootstrap.sh),
> [../../AGENTS.md](../../AGENTS.md), [../THREAT-MODEL.md](../THREAT-MODEL.md).

---

## Metadata

- **ID:** ADR-0015
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** accepted
- **Layer(s):** infra (deploy/bootstrap), control plane (config rendering + distribution), cross-cutting
- **Phase:** cross-cutting; binds node bootstrap + network update from Phase 0 onward
- **Related:** ADR-0002 (no custom crypto), ADR-0010 (transport set + per-protocol toggling),
  ADR-0013 (Phase 0-2 inert-schema rule; membership stays static config / no live registry),
  ADR-0014 (per-operator node credentials, no shared key material), RP-0002 (Phase 0 live
  verified hardened node), RP-0003 (network update / artifact-delivery migration),
  `scripts/node-bootstrap.sh`, `infra/systemd/mycelium-update.{service,timer}`

## Context

Once more than one node exists, the network needs a way to keep every node identical and to roll a
change out without per-node hand-work. The forces in tension are:

- **Operator effort vs. network size.** Editing each node by hand does not scale and guarantees drift;
  every node must converge on **one** canonical definition.
- **Speed of rollout vs. supply-chain safety.** The canonical artifacts live in a **public** repo
  (AGPL). Anything that pulls and runs them as root turns the repo into a network-wide remote-code
  path: a single bad commit, a force-push, or a compromised mirror would otherwise execute on every
  node. `sing-box check` validates a config's **schema**, never its **provenance**, so schema
  validation alone is not a supply-chain control.
- **Automation vs. brick-resistance.** A fully automatic updater that applies whatever it fetches can
  take the whole network down with one mistake. A fully manual one does not scale. The design must be
  automatic in the common case yet incapable of bricking or owning the network from a single push.
- **Central control vs. doctrine.** AGENTS.md principle 4 forbids a **permanent central brain** — no
  dependency on one coordinator/registry/push-controller — and ADR-0013 keeps membership as static
  config in Phase 0-2 (no live distributed registry). A push-based controller that holds node
  credentials and dictates state to nodes would violate both.
- **Stable links vs. updates.** ADR-0014 keeps per-node identity (REALITY keypair, client UUIDs,
  per-protocol secrets, the chosen donor SNI, the self-signed cert) **local and never committed**.
  Client subscriptions are pinned to that identity and to the node's chosen donor SNI; an update must
  not rotate identity or the subscriptions break.

- **Adversary model** (see [../THREAT-MODEL.md](../THREAT-MODEL.md)): config-distribution tampering
  and **supply-chain compromise of the update channel** (a malicious or forged push reaching a
  root-run updater network-wide), plus operator coercion (a central push-controller would be a single
  coercion target).
- **Affected asset.** Ingress reachability and the integrity of every node (root-level code
  execution via the update path); operators (a central controller is a coercion target); user
  traffic (a bricked or hostile network).
- **Fundamental trade-off.** Adaptation speed (one push updates the whole network) ↔ false-migration /
  self-brick risk and supply-chain exposure. This ADR resolves it by making the rollout pull-based
  and **signature-gated**, and the apply step **fail-closed with rollback**.

## Considered Options

> "Leave as is" (hand-edit each node) is option 0 and is rejected implicitly: it does not scale and
> guarantees drift.

1. **Unauthenticated pull + auto-apply.** Every node runs a timer that does a plain `git pull` of the
   public repo and applies the result.
   - Pros: trivial to implement; one push updates the network.
   - Cons: turns the public repo into a network-wide **root RCE** path — one bad/forged push, force-push,
     or mirror compromise executes on every node; `sing-box check` cannot catch a hostile-but-valid
     config or hostile fetched **shell**.
   - Impact on indistinguishability / survivability: catastrophic — a single supply-chain event owns
     or bricks the entire network.
2. **Central push agent / coordinator.** A control service holds node credentials and pushes state to
   each node.
   - Pros: immediate, centrally orchestrated rollouts.
   - Cons: a **permanent central brain** (AGENTS.md §4 violation) and a credential concentrator
     (ADR-0014 violation); one coercion/compromise target for the whole network.
   - Impact on indistinguishability / survivability: negative — crowns a permanent center to coerce
     or seize.
3. **Bake rendered config into the repo per node.** Commit each node's finished config/secrets.
   - Pros: nothing to render on-node.
   - Cons: leaks/duplicates per-node secrets into a public repo (ADR-0014 violation) and couples link
     stability to commits — re-baking rotates identity and breaks subscriptions.
   - Impact on indistinguishability / survivability: negative — secret exposure plus link churn.
4. **Pull-based, signature-gated, fail-closed apply with local rendering (chosen).** One canonical
   source delivered by an idempotent on-node updater on a systemd timer; the operator's **signature**
   on the pushed ref is the approval; the node verifies it before any fetched code runs, then renders
   from **local** identity, validates, and applies with rollback.
   - Pros: one push updates the network with no per-node hand-work; no central controller and no shared
     key material; a bad push can neither own nor brick the network; identity and links stay stable.
   - Cons: requires distributing the operator's signing key out-of-band and pinning a signed ref;
     two-gate (signature + `sing-box check`) machinery to maintain.
   - Impact on indistinguishability / survivability: positive — pull-based and provenance-gated, no
     permanent center, fail-closed rollout.

## Decision

**Option 4.** Network artifact-delivery and node update become canon as implemented by
`scripts/node-bootstrap.sh`:

1. **One canonical source of truth, delivered by an idempotent on-node updater.** The public repo is
   the single canonical definition. Each node runs `node-bootstrap.sh --update` from a systemd timer
   (`infra/systemd/mycelium-update.{service,timer}`); the updater fetches the canonical artifacts,
   re-renders, validates, and applies. A push updates the whole network with **no per-node hand-work**;
   nodes converge on re-run (idempotent). Delivery is **pull-based**, never a central push.

2. **Semi-auto = the operator's signature IS the approval.** Nodes apply automatically but
   **fail-closed**. The updater fetches (which touches only remote-tracking refs/tags, not the working
   tree), then **verifies the operator's signature** on the pinned ref against an **out-of-band**
   `allowedSigners` file (SSH signatures, preferred) or a GPG keyring — and only **after** that
   verification passes does any fetched code merge, install, or execute. Fast-forward-only is **not**
   sufficient alone: it blocks history rewrites but not a fresh malicious commit, so the **signature
   is the provenance gate**. `--insecure-no-verify` exists for local testing only (loud warning); the
   network timer must never run with it. Pin `--repo-ref` to an **immutable signed tag** so the approval
   itself is immutable; a bare branch HEAD is advanceable by any push and is only verified per-commit
   as a less-preferred fallback. An optional `--staged` cadence stages a *validated* candidate and
   waits for an explicit operator `--ack` before promoting.

3. **Per-node identity is local and pinned; `--update` never regenerates it.** Identity (REALITY
   keypair, client UUIDs, per-protocol secrets, the self-signed cert) is generated **locally** on
   first bootstrap and kept under `STATE_DIR` (`0600`), never committed (ADR-0014). The random donor
   SNI is chosen **once and pinned** so client subscriptions stay stable across updates. `--update`
   re-renders from this local identity and **never** rotates it.

4. **Re-exec from an immutable copy; byte-identical is a no-op; rollback on failure.** Because the
   in-place fetch rewrites the working tree (including the updater script itself), `--update`
   **re-execs from an immutable copy** before fetching, so a mutated tree can never make the running
   process skip validation/rollback. After rendering and `sing-box check`, a candidate that is
   **byte-identical** to the live config is **not** applied (zero downtime for unchanged pushes —
   applying is an explicit restart, since sing-box is `Type=simple` with no real reload). On any
   validation or post-apply failure the node **rolls back to the last-known-good** config and leaves
   the service serving it (fail-closed). Two independent schema gates run: the updater's `sing-box
   check` and the unit's `ExecStartPre`.

5. **The fetch step is one swappable function.** `myc_fetch_artifacts` is the **only** place that
   knows **how** artifacts arrive. Today it is a pinned, fast-forward-only `git fetch` + a
   signature-verified merge; it is designed to be swapped to a **signed release tarball** or OS
   packages (`apt`/`brew`) later — the long-term direction — by replacing only that function (download
   → verify signature **and** checksum → unpack). The rest of the updater is unchanged, and the
   **signature gate must be preserved** in any replacement: it is the provenance guarantee, not an
   optional extra.

This is consistent with AGENTS.md §4 (**no permanent central brain**): delivery is pull-based and
signature-gated, not a central push-controller, and no node or coordinator holds another node's
credentials. It is consistent with ADR-0014 (no shared key material; identity stays local) and with
ADR-0013 (membership remains static config; no live distributed registry is introduced here).
**Fail-closed** here means: unverifiable provenance is refused before any fetched code runs, an
unvalidated candidate is never promoted, and any post-apply failure restores the last-known-good.

## Consequences

- **Positive:** a single signed push rolls the whole network with no per-node hand-work; a bad/forged
  push can neither achieve network-wide code execution nor brick a node (provenance gate + validate +
  rollback + no-op short-circuit); no central controller and no shared/concentrated credentials;
  client links stay stable because identity and the donor SNI are pinned and never rotated on update;
  the delivery channel can later move to signed releases/packages without touching the rest.
- **Negative / cost:** the operator must distribute the signing key **out-of-band** to every node and
  pin a signed tag; the two-gate (signature + `sing-box check`) and re-exec machinery must be
  maintained; an unsigned/misconfigured push is refused rather than applied (intended, but it does
  require the operator to sign and pin correctly).
- **Impact on user security (requirement №1):** strongly protective. No secret or node-specific value
  is ever committed; only the REALITY public key and per-client subscriptions are exported. No logging
  or correlation is introduced by the update path; deniability and per-node identity are preserved
  because `--update` never regenerates keys.
- **Impact on observability/measurements:** the updater asserts the service is active **and** the
  expected listen ports are bound after apply (post-apply health), giving a per-node apply/rollback
  signal; it adds no cross-node telemetry and no central reporting.
- **Follow-on actions required:** RP-0003 sequences the migration (timer rollout, key distribution,
  pinning a signed tag, and the eventual swap of `myc_fetch_artifacts` to signed releases/packages);
  keep the runbook ([../runbooks/node-bootstrap.md](../runbooks/node-bootstrap.md)) and ADR-0014 in
  step; a conformance check should assert the updater verifies provenance before executing fetched
  code and that no node-specific value is committed.
- **What is now forbidden:** an unauthenticated `git pull` + auto-apply on nodes; a central push
  agent/coordinator holding node credentials; committing rendered per-node config or secrets into the
  repo; any fetch path that drops the signature gate; rotating identity or the donor SNI on `--update`.

## Compliance

How the decision is verified in practice:

- **Provenance-before-execution gate.** `myc_fetch_artifacts` / `verify_signed_ref` must verify the
  pinned ref's operator signature (SSH `allowedSigners` or GPG) **before** any merge/install/execute;
  an unverifiable ref is refused unless `--insecure-no-verify` is explicitly set (testing only). A
  conformance gate should assert the updater never executes fetched shell before this check.
- **No-leak gate (existing).** The wording / contact / per-protocol-toggle conformance gates plus the
  ADR-0014 per-node-credentials rule assert that no IP, hostname, jurisdiction, secret, key, or
  node-specific value is committed; every node-specific artifact is local-only/out-of-band.
- **Fail-closed apply.** A candidate is promoted only after `sing-box check` passes; applying is an
  explicit restart with a post-apply health assertion (service active **and** expected ports bound),
  and any failure rolls back to the last-known-good. A byte-identical candidate is a no-op.
- **Swappable-fetch invariant.** Any replacement of `myc_fetch_artifacts` (signed tarball / OS
  packages) must preserve the signature + checksum gate; a fetch path without it fails review.
- **Audit checkpoint.** A change to the update/delivery model updates this ADR, the runbook, and
  RP-0003; reviewers reject any update path that pulls-and-runs without provenance verification, any
  central push-controller, and any committed per-node config/secret.

## Alternatives considered

- **Unauthenticated `git pull` + auto-apply** — rejected: makes the public repo a network-wide root RCE
  channel; `sing-box check` validates schema, not provenance.
- **Central push agent / coordinator holding node credentials** — rejected: a permanent central brain
  (AGENTS.md §4) and a credential concentrator (ADR-0014 violation); one coercion target for the
  whole network.
- **Baking rendered config/secrets into the repo per node** — rejected: leaks/duplicates per-node
  secrets into a public repo (ADR-0014 violation) and couples link stability to commits, breaking
  subscriptions whenever a re-bake would rotate identity.
- **Fast-forward-only with no signature** — rejected as insufficient alone: it stops history rewrites
  but not a fresh malicious commit reaching every node; the operator signature is the required
  provenance approval.
