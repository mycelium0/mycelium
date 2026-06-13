<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Network rollout: from canonical bootstrap to a signed, self-updating network

> **Document type.** Refactoring / Change Proposal. Structure matches
> [../refactoring.md](../refactoring.md) and
> [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md).
> This RP takes the canonical on-node bootstrap + semi-auto updater
> ([`scripts/node-bootstrap.sh`](../../scripts/node-bootstrap.sh), the live-node DoD from
> [RP-0002](0002-phase0-live-verified-hardened-node.md)) from *code that works on one node*
> to a *running, self-updating network*: signed pushes, migrated hand-built nodes, the update
> timer installed everywhere, fresh-node onboarding for additional operators, one canonical
> server template, the preventive supply-chain conformance gates, and a verified
> convergence proof. It pulls **no** Phase 2 detector/rotation logic forward.

---

## Metadata
- **ID:** RP-0003
- **Date:** 2026-06-13
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** cross-cutting deploy/bootstrap track (binds Phase 0 nodes into a managed network; see [../ROADMAP.md](../ROADMAP.md))
- **Related documents:**
  [RP-0002](0002-phase0-live-verified-hardened-node.md) (the live, verified, hardened single node this network is built from);
  [RP-0001](0001-bootstrap-phase-0-node.md) (the original scaffold);
  [ADR-0014](../adr/0014-per-operator-node-credentials.md) (per-operator node credentials — no shared network key material);
  ADR-0015 (signed-release provenance for network artifacts — the decision record for §W1, authored alongside this RP per §8);
  [ADR-0002](../adr/0002-no-custom-cryptography.md) (no custom cryptography — all key/signature material from audited tools);
  [ADR-0010](../adr/0010-phase0-transport-set.md) (Phase 0 transport set);
  [ADR-0012](../adr/0012-go-primary-control-plane-language.md) (Go as the primary control-plane language);
  [scripts/node-bootstrap.sh](../../scripts/node-bootstrap.sh) (the implementation this RP operationalises);
  [docs/runbooks/node-bootstrap.md](../runbooks/node-bootstrap.md) (the operator runbook for the same system);
  [nodes/dataplane/singbox/server.template.json](../../nodes/dataplane/singbox/server.template.json) and
  [nodes/dataplane/singbox/server.template.renderer.json](../../nodes/dataplane/singbox/server.template.renderer.json) (the two templates §W5 reconciles);
  [nodes/dataplane/donor-sni-candidates.json](../../nodes/dataplane/donor-sni-candidates.json);
  [docs/refactoring.md](../refactoring.md) §13.

## 1. Title
Operationalise the canonical bootstrap + semi-auto updater into a signed, self-updating
network: migrate the existing hand-built nodes without changing client links, install the
update timer everywhere, onboard additional operators, collapse the two server templates
into one, add the preventive supply-chain gates, and prove network-wide convergence from a
single signed push.

## 2. Reason
[RP-0002](0002-phase0-live-verified-hardened-node.md) produced — and
[`scripts/node-bootstrap.sh`](../../scripts/node-bootstrap.sh) implements — everything a
*single* node needs: idempotent bootstrap, local per-node identity, donor selection,
render-through-`myceliumctl`, `sing-box check` as a fail-closed gate, an
apply-with-rollback `--update` path, the `--staged`/`--ack` cadence, and the
re-exec-from-an-immutable-copy self-modification guard. The updater is also already written
to be the delivery mechanism ("the human approval **is** the operator's signature on the
pushed ref"). **But the network does not yet run that way.** The gap is operational, not
algorithmic:

- **No signing pipeline exists yet.** `verify_signed_ref` and `--allowed-signers` are
  implemented and fail-closed, but no operator signing key has been generated, no release
  tag has been signed, no `allowed_signers` file has been distributed out-of-band, and no
  node pins `--repo-ref` to a signed tag. Until that pipeline exists, every node would have
  to run with `--insecure-no-verify` (forbidden on the network timer) — i.e. the provenance
  guarantee is designed but unarmed.
- **The existing nodes were hand-built** before the bootstrap's identity schema existed.
  Their keys/UUIDs/donor live in ad-hoc state, not in the bootstrap's
  `identities.json` / `identity.json` layout. If they re-run bootstrap cold it would
  generate **new** identity, which would **change every client subscription link** — an
  unacceptable break for live users on an always-on network. They must be *migrated in
  place* so they can join the updater without rotating anything client-facing.
- **The update timer is not installed.** The flow diagram in the runbook
  ([docs/runbooks/node-bootstrap.md](../runbooks/node-bootstrap.md)) describes
  `mycelium-update.timer`, but no node is actually running it, so "git push → whole network
  updates" is not yet true of any node.
- **Onboarding additional operators is undocumented as a network step.** The one-command
  install exists, but the handoff of subscriptions out-of-band (delivery method B,
  per [ADR-0014](../adr/0014-per-operator-node-credentials.md)) is not yet a repeatable
  operator procedure.
- **Two sing-box server templates have drifted.** The canonical
  [`server.template.json`](../../nodes/dataplane/singbox/server.template.json) and the
  renderer-compatible
  [`server.template.renderer.json`](../../nodes/dataplane/singbox/server.template.renderer.json)
  disagree on inbound **tags** (e.g. `tuic-v5-in` vs `tuic-in`, `shadowsocks-2022-in` vs
  `shadowsocks-in`, `shadowtls-v3-in` vs `shadowtls-in`, `trojan-tls-in` vs `trojan-in`),
  on SENTINEL names (`SENTINEL_REALITY_SHORT_ID` vs `SENTINEL_SHORTID`,
  `SENTINEL_TLS_SERVER_NAME`/`_CERTIFICATE_PATH` vs `SENTINEL_TLS_SNI`/`_CERT_PATH`,
  `SENTINEL_SS2022_SERVER_PASSWORD` vs `SENTINEL_SS_PASSWORD`), on listen address
  (`0.0.0.0` vs `::`), on the xhttp transport `type` (`http` vs `xhttp`), and on extras
  (clash_api, obfs/masquerade, bittorrent route rule). Critically, the bootstrap's
  **firewall keep-list** in `harden_ufw` / `verify_listen_ports` selects by **type** and by
  the tag `shadowsocks-in` — which matches the **renderer** template, not the canonical one.
  Two source-of-truth templates is a standing drift hazard: a future edit to the wrong file
  silently does nothing, or opens the wrong ports.
- **The preventive supply-chain gates do not exist.** The offline suite has nine gates
  (the "9/9" in [`tests/run.sh`](../../tests/run.sh)), but none of them is the strict,
  *preventive* check that this network's threat model now demands: a public repo whose every
  push is applied network-wide by a root timer must be mechanically guaranteed to never carry
  an IP literal, secret material, or an AI/tool vendor fingerprint. Those guarantees are
  currently policy + human review, not gates.
- **Network convergence has never been proven end-to-end.** No test asserts that one signed
  push reaches every node, that each node re-renders from its **own local** identity,
  validates, and applies-or-rolls-back, and that **client links are unchanged** afterwards.

Left as-is, the project has a correct single-node updater and a network that is still
hand-operated — the worst of both: the appearance of automation without the provenance,
migration, and convergence guarantees that make automation safe.

## 3. Scope
- **Layers:** deploy/bootstrap (the on-node script + the update timer), infra (systemd
  units, out-of-band key distribution), data plane (the single reconciled server template),
  and the thin control/identity surface (`myceliumctl` render from local identity). **No**
  routing, discovery, coordinator, or carrier/spore layer.
- **Components:** [`scripts/node-bootstrap.sh`](../../scripts/node-bootstrap.sh) (operated,
  not rewritten); `infra/systemd` (`mycelium-update.service` + `.timer`); the operator
  signing pipeline (key + signed tag + out-of-band `allowed_signers`); `control/myceliumctl`
  (render-from-local-identity, unchanged contract); the two sing-box templates (collapsed to
  one); `tests/conformance` (three new preventive gates + the convergence proof);
  the runbook ([docs/runbooks/node-bootstrap.md](../runbooks/node-bootstrap.md)).
- **Contracts:** the on-node identity schema (`identities.json`
  `{version,clients:[{name,id,created}]}` + `identity.json` `{reality,donor,secrets}`); the
  flat `params.json` render schema; the `myceliumctl render-server
  --engine/--template/--params/--state/--out` CLI; the artifact-provenance contract
  (a signed, immutable tag verified against an out-of-band `allowed_signers` before any
  fetched code runs); the firewall keep-list ↔ template-tag correspondence. **No new wire
  protocol or client-facing schema is invented** — existing contracts are armed, migrated
  onto, and reconciled.
- **Storage / state:** per-node `STATE_DIR` (`/var/lib/mycelium`, root-only): `identity.json`
  (0600 — REALITY keypair, per-protocol secrets, donor), `identities.json` (client name→uuid),
  `params.json` (0600), `config.lastgood.json`, `config.staged.json`, the TLS dir, the
  AmneziaWG key dir. The operator signing private key and the `allowed_signers` file are
  **out-of-band** artifacts — never committed. **No user PII is stored anywhere.**
- **Flows:** operator signs a release tag and pushes → every node's timer fetches, verifies
  the signature, re-renders from local identity, validates, applies-or-rolls-back; fresh-node
  onboarding (one command, local identity, out-of-band subscription handoff); hand-built-node
  migration (existing identity → schema, links preserved); convergence verification.
- **Schemas / formats:** **no new format.** Reconcile the two server templates into one
  (canonical tag set + renderer compatibility) and arm the existing provenance contract.

### 3.1. Component participation table (mandatory)

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| [`scripts/node-bootstrap.sh`](../../scripts/node-bootstrap.sh) | The bootstrap + `--update`/`--staged`/`--ack` engine that every workstream operates; armed (signing) and migrated onto, not rewritten | active | system shell / git / sing-box / openssl / jq | Deploy glue per [ADR-0012](../adr/0012-go-primary-control-plane-language.md); orchestrates audited tools, invents no bytes. |
| operator signing pipeline | W1: generate the signing key, sign an immutable release **tag**, ship `allowed_signers` out-of-band; nodes pin `--repo-ref` to the tag + pass `--allowed-signers` | active | `ssh-keygen -Y sign` / `git tag -s` / GPG (operator choice) | Provenance is standard SSH/GPG signing verified by `git verify-tag`; no in-house signature scheme ([ADR-0002](../adr/0002-no-custom-cryptography.md)). |
| `myceliumctl` (`control/`) | W2/W4/W7: renders the server config + subscriptions **from local identity**; its contract is reused unchanged | active | sing-box / openssl / jq (Go binary per [ADR-0012](../adr/0012-go-primary-control-plane-language.md) once parity lands) | Thin orchestration over sanctioned generators; rendering is not custom crypto/transport. |
| `infra/systemd` (`mycelium-update.{service,timer}`) | W3: the timer that runs `--update` on every node; the no-op short-circuit + rollback live in the script it invokes | active | systemd | Init/scheduling is OS configuration, not custom code. |
| `nodes/dataplane/singbox/*.template*.json` | W5: collapse the canonical + renderer templates into **one** source; tags reconciled to the firewall keep-list | active | sing-box | Transport engine config; [ADR-0002](../adr/0002-no-custom-cryptography.md) forbids an in-house transport. |
| `nodes/dataplane/donor-sni-candidates.json` | Read at bootstrap to pick a random per-node donor SNI; expanded/pruned as upstreams change | passive | sing-box (REALITY) / openssl (verify) | Public-hostname list only; selection + TLSv1.3/x25519 verification is the engine's, not ours. |
| `tests/conformance` (new W6 gates) | W6: `no_ip_literal`, `no_secret_material`, `no_ai_fingerprint` preventive gates + W7 convergence proof; added to [`tests/run.sh`](../../tests/run.sh) | active / test-only | system shell / git | Verification harness; no third-party tool fits the bespoke leak checks. |
| migration tooling (W2) | W2: convert a hand-built node's existing identity into `identities.json`/`identity.json` **in place**, preserving keys/uuids/donor | active / test-only | jq / system shell | One-shot, node-local schema transform over existing on-node state; no service needed. |
| `coordinator` (network registry / push fan-out) | Not built here — the "fan-out" is the operator's signed git push, pulled by per-node timers | deferred | none | A central registry/coordinator activates in a later RP (Phase 3); inert here by design. |
| interference detector / auto-rotation | Not built here | deferred | none | Phase 2 ([ADR-0012](../adr/0012-go-primary-control-plane-language.md) spine hosts it later); this RP changes no exposed transport surface. |

### 3.2. Blast-radius cap
> One RP = one manageable step.

This RP **exceeds** the single-step cap and is therefore declared **multi-phase** (seven
ordered workstreams W1–W7 in §5). The justification: "stand the network up" is one coherent
*responsibility* — turn the proven single-node updater into a running, self-updating network —
that cannot be cut smaller without leaving a network that is signed-but-unmigrated (existing
nodes excluded or link-broken), migrated-but-unconverged (no timer), or
converged-but-unguarded (no preventive gates). Crucially, **no client-facing contract
changes shape, no layer changes behaviour, and the one template reconciliation collapses two
existing surfaces into one rather than introducing a new distribution surface.**

- **Responsibility boundaries affected:** 0 (the provenance/identity/render boundaries are
  *armed and migrated onto*, not redrawn).
- **Layers affected (behaviour):** 0 new behaviours; the data plane is unchanged (template
  reconciliation is shape-preserving for what is rendered + checked).
- **Config-distribution surfaces affected:** 1 net **reduction** (two server templates → one).
- **Files in diff (estimate):** ~20–35 (one collapsed template + the deleted/aliased other,
  the two systemd units, three new conformance gates + `run.sh` wiring, the migration helper,
  the runbook, CHANGELOG/version bumps, the new ADR-0015).

- [ ] Within cap — single-step RP.
- [x] Exceeds cap → **declared multi-phase** (workstreams W1–W7 below). No client-facing
  contract, layer-behaviour, or net distribution-surface expansion; ordered so master stays
  green between workstreams (each ends on its own DoD with the offline gates passing).

  Phase breakdown: **W1** arm signing → **W2** migrate hand-built nodes (links preserved) →
  **W3** install the update timer everywhere → **W4** onboard additional operators →
  **W5** collapse the two templates into one → **W6** add the three preventive gates →
  **W7** prove network convergence. W1 is a prerequisite for W3/W7 (a node cannot safely run
  the timer until it can verify a signature); W2 must precede W3 on existing nodes (migrate
  before they auto-update); W5 should land before/with W7 so convergence is verified against
  the single template; W6 can land in parallel but **must** be green before the first signed
  push of W7.

## 4. Current state
The single-node machinery is complete and correct; the **network** machinery is unarmed,
unmigrated, and unproven. Specifically:

- **Signing (W1).** `scripts/node-bootstrap.sh` already implements `verify_signed_ref`
  (SSH `allowedSignersFile` preferred, GPG fallback), the `--allowed-signers` /
  `--repo-ref` / `--insecure-no-verify` flags, and a fast-forward-only,
  signature-verified `myc_fetch_artifacts`. **Nothing upstream is signed**: no operator key,
  no signed tag, no distributed `allowed_signers`, and no node pins a tag. The guarantee is
  designed and inert.
- **Existing hand-built nodes (W2).** The live nodes predate the bootstrap's identity schema.
  Their REALITY keypair, client UUIDs, per-protocol secrets, and donor exist as ad-hoc
  on-node state, not as `identity.json` (`{version,created,reality,donor,secrets}`) +
  `identities.json` (`{version,clients:[{name,id,created}]}`). `ensure_identity` only
  *generates* identity when absent and *keeps* it when present — so a cold bootstrap on a
  hand-built node either ignores the existing material (wrong shape) or, if its state dir is
  empty in the new layout, mints **new** identity and **changes every subscription link**.
- **Update timer (W3).** No node runs `mycelium-update.timer`; the units referenced by the
  runbook are not yet installed network-wide, so the no-op short-circuit, the rollback path,
  and the re-exec self-modification guard have never run on a schedule against the live network.
- **Additional operators (W4).** `ensure_identity` already generates a fully local identity on
  a fresh node, and [ADR-0014](../adr/0014-per-operator-node-credentials.md) fixes that there
  is **no shared network key material** — each operator's node is self-sufficient. What is
  missing is the *repeatable operator procedure*: the one-command install plus the
  out-of-band subscription handoff (delivery method B: per-node self-signed cert + client
  pin for HY2/TUIC, REALITY public key + params for the rest).
- **Two templates (W5).** Both [`server.template.json`](../../nodes/dataplane/singbox/server.template.json)
  (canonical: clash_api, obfs/masquerade, `transport.type:"http"`, listen `0.0.0.0`, tags
  `*-vision-in`/`tuic-v5-in`/`shadowsocks-2022-in`/`shadowtls-v3-in`/`trojan-tls-in`) and
  [`server.template.renderer.json`](../../nodes/dataplane/singbox/server.template.renderer.json)
  (renderer-compatible: no clash_api, no obfs/masquerade, `transport.type:"xhttp"`, listen
  `::`, tags `tuic-in`/`shadowsocks-in`/`shadowtls-in`/`trojan-in`, a bittorrent route rule)
  exist and disagree. The bootstrap renders the **renderer** one
  (`RENDER_TEMPLATE=…/server.template.renderer.json`), and the firewall keep-list in
  `harden_ufw` selects the `shadowsocks-in` tag — so the renderer template is the de-facto
  truth, while the canonical template is the documented one. SENTINEL names also diverge,
  so the two cannot be swapped blindly.
- **Preventive gates (W6).** [`tests/run.sh`](../../tests/run.sh) runs nine offline gates
  (`check_headers`, `check_ppn_wording`, `no_contact_leak`, `no_custom_crypto`,
  `validate_configs`, `no_legacy_transport`, `per_protocol_toggle`, `phase0_port_canon`,
  `control/selftest.sh`). There is **no** strict gate that refuses an IP literal, secret
  material, or an AI/tool vendor fingerprint — the exact leaks that are catastrophic when the
  public repo is also the network's root-applied delivery channel.
- **Convergence (W7).** No test exercises "one signed push → all nodes re-render from local
  identity → validate → apply-or-rollback → links unchanged." Convergence is asserted by the
  per-node `--update` logic only, never across the network end-to-end.

## 5. Target state
A live network where **one signed push by the operator converges every node** — each node
fetching, verifying the operator signature, re-rendering **from its own local identity**,
validating with `sing-box check`, and applying-or-rolling-back fail-closed — with the
existing hand-built nodes migrated so **no client subscription link ever changes**, the
update timer running everywhere, additional operators able to onboard a self-sufficient node
in one command, a **single** server template as the source of truth, three preventive
supply-chain gates wired into the offline suite, and a convergence proof. Effect on the
four template axes:

- **Indistinguishability.** Unchanged at the transport layer — the reconciled template
  renders the same checked inbounds; donor selection stays random-per-node
  ([nodes/dataplane/donor-sni-candidates.json](../../nodes/dataplane/donor-sni-candidates.json)).
  The `no_ai_fingerprint` / `no_ip_literal` gates additionally keep the *public artifacts*
  free of network-correlating breadcrumbs.
- **Survivability / path redundancy.** Improved operationally: a single signed push can
  update all nodes' transports at once (e.g. swap a donor candidate, toggle a protocol)
  without per-node hand-work, and the no-op short-circuit means an unchanged push costs zero
  restarts. (A single IP/AS per node remains a single blocking point — a Phase 1/2 concern,
  unchanged; see Non-goals.)
- **Adaptation speed.** The *manual* network primitive: time from "operator decides" to
  "network converged" becomes one signed push plus one timer interval, with automatic rollback
  on any node that fails to apply. Automated *detection-driven* rotation remains `deferred`
  to Phase 2.
- **Control-plane network persistence.** No central coordinator is introduced — the
  "fan-out" is a signed git push pulled by independent per-node timers, so the control path
  is the public repo (any mirror) plus an out-of-band key, not a single online service.

The plan is organised as seven ordered workstreams.

---

### W1 — Signing pipeline (arm artifact provenance)
**Goal.** Every canonical artifact a node applies is provably from the operator: an
immutable signed **tag**, verified against an out-of-band `allowed_signers` file before any
fetched code runs.

**Steps.**
1. **Generate the operator signing key** with an audited tool only
   ([ADR-0002](../adr/0002-no-custom-cryptography.md)): an SSH signing key
   (`ssh-keygen -t ed25519`) for the SSH-signature path `verify_signed_ref` prefers, or a
   GPG key for the fallback path. The **private** key never enters the repo or any node.
2. **Build the `allowed_signers` file** (the SSH allowedSigners format mapping the operator
   principal to the **public** key) and treat it as an out-of-band artifact. It is **never
   committed** (fail-closed: `verify_signed_ref` refuses if `--allowed-signers` is missing).
3. **Sign an immutable release tag** (`git tag -s`) at the reviewed commit, so the thing
   nodes pin is a fixed object, not a moving branch HEAD (which any push can advance and
   which `myc_fetch_artifacts` only verifies per-commit as a less-preferred fallback).
4. **Distribute `allowed_signers` out-of-band** to every node (existing + new) — the runbook
   already shows pointing the unit at `/etc/mycelium/allowed_signers`.
5. **Pin nodes** to `--repo-ref <signed-tag>` + `--allowed-signers <path>`; confirm a tag
   without a valid signature, and a forged tag, are both **refused** before any code runs.
6. **Record the decision in ADR-0015** (signed-release provenance for network artifacts): why
   a signed immutable tag verified out-of-band is the canonical approval, why
   `--insecure-no-verify` is testing-only, and how the gate is preserved when the fetch later
   moves to signed release tarballs (`myc_fetch_artifacts` swap, §"the fetch step is
   swappable" in the runbook).

**Definition of Done.** An operator signing key exists (private out-of-band); a signed
immutable tag is published; `allowed_signers` is distributed out-of-band to every node; a
node with `--repo-ref <tag> --allowed-signers <file>` **applies** the signed tag and
**refuses** (fail-closed, non-zero, nothing fetched executed) an unsigned or forged ref;
ADR-0015 is landed.

**Verification.**
- On a node: `node-bootstrap.sh --update --repo-ref <signed-tag> --allowed-signers <file>`
  logs `signature verified for '<tag>' against the operator key` and proceeds.
- A tampered/unsigned ref makes the same command die with the "signature verification FAILED
  … refusing to apply unauthenticated artifacts (fail-closed)" path; `git log`/working tree
  show nothing was merged or executed.
- `--allowed-signers` omitted → the run dies with the "no `--allowed-signers` given" message
  (never silently proceeds).

**Dependencies / ordering.** First; a hard prerequisite for W3 (the timer must verify) and
W7 (the convergence proof is of a *signed* push). Independent of W5/W6.

**Risks + mitigations.** **Supply-chain:** a single bad push to the public repo applied
network-wide as root — mitigated exactly here: the signature is verified *before* the
fast-forward merge, so unauthenticated code never runs. Key compromise → the private key is
out-of-band and rotatable (re-issue `allowed_signers`, re-sign the tag). **Threat-model:**
*Node compromise* / *supply-chain interference* (provenance gate); *Operator coercion*
(nothing in the repo reveals the operator — the key is out-of-band).

---

### W2 — Migrate existing hand-built nodes (preserve client links)
**Goal.** Convert each hand-built node's existing identity into the bootstrap's
`identity.json` / `identities.json` schema **in place, preserving keys, UUIDs, and donor**,
so existing client subscription links **do not change**, then let the node join the updater.

**Steps.**
1. **Inventory** the existing node's identity material: REALITY private/public key + shortId,
   client UUID(s) and their names, the per-protocol secrets (SS-2022 / Trojan / Hysteria2 /
   ShadowTLS), the chosen donor host/SNI, the self-signed cert + its client pin, and the
   node's reachable address used by current subscriptions.
2. **Transform into schema, not regenerate.** Write the inventoried values into
   `identity.json` (`{version,created,reality:{private_key,public_key,short_id},
   donor:{host,sni},secrets:{…}}`, 0600) and `identities.json`
   (`{version,clients:[{name,id,created}]}`, 0600) **using the existing bytes**. A one-shot,
   idempotent migration helper (jq + shell, node-local) does this; it **must not** call any
   generator. Reuse the existing self-signed cert under the TLS dir (keep its client pin),
   and record the existing reachable address so `resolve_node_address` reuses it (the
   placeholder `node.example.invalid` must never appear for a live node).
3. **Re-render from the migrated local identity** and diff against the live config: the
   render must reproduce the same per-client values (UUIDs, REALITY public key, shortId,
   donor SNI, pins, ports) so that a re-issued subscription is **byte-equivalent** to what
   clients already hold. Any divergence is a migration bug, not a "new" link.
4. **Dry-run an update** (`--update --dry-run`) and confirm the no-op short-circuit fires
   (the candidate equals the live config) before arming the timer in W3.
5. **Keep a rollback copy** of the pre-migration on-node state until the node has run one
   successful real update.

**Definition of Done.** Each migrated node carries valid `identity.json`/`identities.json`
built from its **existing** material; a fresh render from local identity is byte-equivalent
to the live config (no-op short-circuit fires); every existing client subscription link
still authenticates **unchanged** (no key/UUID/donor rotation); the node is ready to join
the timer.

**Verification.**
- `cmp -s <freshly-rendered candidate> <live config>` is true post-migration (the script's
  own no-op path).
- Re-issuing a subscription for an existing client yields the same connect parameters the
  client already uses; an unmodified existing client still connects.
- `jq` confirms `identity.json` holds the **pre-existing** REALITY public key + shortId and
  `identities.json` holds the **pre-existing** UUIDs (compared against the W2.1 inventory).
- `resolve_node_address` returns the real recorded address, never the placeholder.

**Dependencies / ordering.** After W1 (so the migrated node can verify the first signed
push). Must precede W3 **on existing nodes** — migrate the identity before the auto-updater
ever runs, so it never re-renders from absent/new identity.

**Risks + mitigations.** **Link instability if identity/donor regenerate** — the dominant
risk: mitigated by *transform-not-regenerate* (the helper calls no generator), the
byte-equivalence diff gate, and keeping the pre-migration state until one real update
succeeds. A wrong donor/address transcription would break links → the diff gate catches it
before the timer is armed. **Threat-model:** *Knowledge minimisation* (no new user
attribution introduced; UUIDs preserved, not re-minted); *Operator coercion* (migrated
secrets stay 0600 on-node, never exported).

---

### W3 — Install the update timer everywhere (no-op short-circuit + rollback proven)
**Goal.** Every node (migrated existing + fresh) runs `mycelium-update.timer`, and the
no-op short-circuit and the rollback path are confirmed to behave on a schedule.

**Steps.**
1. **Author/confirm the units** `infra/systemd/mycelium-update.service` (oneshot calling
   `node-bootstrap.sh --update --repo-ref <signed-tag> --allowed-signers <file>` with the
   node's pins; `--staged` appended on nodes that use the stricter ack cadence) and
   `mycelium-update.timer` (every few minutes, with a small randomized delay so the network
   does not fetch in lockstep).
2. **Install + enable** on every node:
   `cp infra/systemd/mycelium-update.{service,timer} /etc/systemd/system/` →
   `systemctl daemon-reload` → `systemctl enable --now mycelium-update.timer`.
3. **Confirm the no-op short-circuit:** with the live config already matching the signed
   tag, a timer run logs "candidate is identical to the live config; no change to apply
   (service untouched)" and performs **zero** restarts (an always-on network must not drop
   live connections on an unchanged push).
4. **Confirm rollback behaves:** push a deliberately invalid candidate (in a test ref, never
   the network tag) and confirm the node fails `sing-box check`, does **not** promote, and
   leaves the running service on the last-known-good config; then confirm a post-apply
   health failure path restores `config.lastgood.json` and restarts onto it.
5. **Confirm the self-modification guard:** the `--update` re-exec from an immutable copy
   runs (the timer invokes the in-tree script, which the fetch rewrites) so validation +
   rollback always execute from a stable image.

**Definition of Done.** `mycelium-update.timer` is active on every node; an unchanged signed
push causes zero restarts (no-op short-circuit); an invalid candidate is never promoted and
the service stays on last-known-good; a post-apply failure rolls back automatically; the
re-exec guard is observed in the logs.

**Verification.**
- `systemctl is-active mycelium-update.timer` is active on each node; `systemctl list-timers`
  shows the next run.
- A timer run against the current signed tag logs the no-op line; `systemctl show sing-box
  -p ExecMainStartTimestamp` is unchanged across that run (no restart).
- The invalid-candidate test (on a throwaway ref) leaves `sing-box` serving the prior config;
  the journal shows the "NOT applied … live config + service untouched (fail-closed)" path.
- The post-apply-failure test shows "rolling back" + restoration of `config.lastgood.json`.

**Dependencies / ordering.** After W1 (the timer must verify signatures) and after W2 on
existing nodes (migrate before auto-updating). Independent of W4/W5/W6, but W6 should be
green before any *real* signed push (W7).

**Risks + mitigations.** **SSH lockout** is not introduced by the timer itself, but the
update path may re-run `harden_sshd`/`harden_ufw`; both keep their anti-lockout guards
(key-confirmed before disabling passwords; the live sshd port opened before `ufw enable`).
Timer stampede on a shared upstream → randomized delay. A bad network tag bricking everything →
prevented structurally: validate-then-rollback per node, and the no-op short-circuit means a
re-pushed good tag re-converges. **Threat-model:** *Active probing* (rollback never exposes
an unverified config); *Operator coercion* (volatile journald keeps the timer's logs in RAM).

---

### W4 — Fresh-node onboarding for additional operators (delivery method B)
**Goal.** An additional operator stands up a self-sufficient node in **one command**, with
its identity generated **locally**, and receives client subscriptions handed off
**out-of-band** — no shared network key material
([ADR-0014](../adr/0014-per-operator-node-credentials.md)).

**Steps.**
1. **One-command install** (per the runbook): clone the canonical checkout, add the
   operator's SSH key first (anti-lockout), then run `node-bootstrap.sh` with the pinned
   `--singbox-version`/`--singbox-sha256`, `--clients`, `--node-address`, and the W1 pins
   (`--repo-ref <signed-tag> --allowed-signers <file>`). Identity is generated **on that
   node** (`ensure_identity`): per-node REALITY keypair, client UUIDs, per-protocol secrets,
   a random verified donor, and a self-signed cert — nothing fetched, nothing shared.
2. **Out-of-band subscription handoff (delivery method B):** export, per client, the
   connection parameters — REALITY public key + shortId + donor SNI + UUID + ports for the
   REALITY family, and the per-node self-signed cert **pin** (SHA-256) for HY2/TUIC — and
   deliver them to users out-of-band. The **private** key, secrets, and cert key never leave
   the node (only the public key, pins, and subscriptions are exported).
3. **Join the network:** install the W3 timer with the same pins; the node now converges on
   every signed push while keeping its own local identity.
4. **Document the operator handoff** in the runbook as a numbered procedure (so a second
   operator can repeat it without this RP).

**Definition of Done.** A fresh node is bootstrapped in one command with locally-generated
identity and no shared key material; its subscriptions are exported and handed off
out-of-band (REALITY params + per-node HY2/TUIC pin); it runs the timer and converges on the
signed tag; the procedure is in the runbook.

**Verification.**
- On the fresh node: `identity.json`/`identities.json` exist with locally-generated values;
  no shared wildcard/private key is present (consistent with
  [ADR-0014](../adr/0014-per-operator-node-credentials.md)).
- An off-the-shelf client using only the out-of-band subscription connects over the primary
  REALITY path and one more transport.
- `node-bootstrap.sh --update --dry-run` with the node's pins verifies the signed tag and
  reports a no-op (already converged).
- The placeholder `node.example.invalid` never appears in the issued subscription (a real
  `--node-address` was set).

**Dependencies / ordering.** After W1 (pins to give the operator). Independent of W2/W5/W6;
benefits from W3 (the timer install is shared).

**Risks + mitigations.** **Link instability if identity/donor regenerate** — a re-run must
**not** mint new identity: `ensure_identity` keeps existing secrets; the operator is warned
never to wipe the state dir. Out-of-band handoff leaking the wrong material → export only
public key + pins + subscription, never the 0600 secrets. **Threat-model:** *Knowledge
minimisation* (per-node identity, no network-wide correlation); *Node compromise* (a
compromised new node exposes only its own keys, never the network's — [ADR-0014](../adr/0014-per-operator-node-credentials.md)).

---

### W5 — Reconcile the two sing-box server templates into one
**Goal.** **One** server template is the single source of truth; its inbound tags match the
bootstrap's firewall keep-list and `verify_listen_ports` selection, so an edit to the
template provably changes what is rendered, checked, and firewalled.

**Steps.**
1. **Pick the canonical source.** Reconcile
   [`server.template.json`](../../nodes/dataplane/singbox/server.template.json) and
   [`server.template.renderer.json`](../../nodes/dataplane/singbox/server.template.renderer.json)
   into one file that the renderer (`myceliumctl render-server --template …`, which the
   bootstrap points at via `RENDER_TEMPLATE`) consumes. The bootstrap currently renders the
   **renderer** template, so the merged file must stay renderer-compatible while adopting the
   canonical decisions where they are the documented intent.
2. **Reconcile the inbound tags to the firewall keep-list.** `harden_ufw` and
   `verify_listen_ports` select by **type** (`vless`/`trojan`/`shadowtls`/`shadowsocks`
   non-loopback for TCP; `hysteria2`/`tuic` for UDP) **and** by the tag `shadowsocks-in`
   (the SS-2022 port). The merged template must use tags consistent with that selection (the
   renderer tag set: `tuic-in`, `shadowsocks-in`, `shadowtls-in`, `shadowtls-ss-in`,
   `trojan-in`, the `*-vision/grpc/xhttp-in` REALITY tags) so the keep-list opens exactly the
   enabled ports — eliminating the canonical-vs-renderer tag drift (`tuic-v5-in`,
   `shadowsocks-2022-in`, etc.).
3. **Reconcile SENTINEL names + shape:** one set of placeholder names
   (`SENTINEL_SHORTID` vs `SENTINEL_REALITY_SHORT_ID`, `SENTINEL_TLS_SNI`/`_CERT_PATH` vs
   `SENTINEL_TLS_SERVER_NAME`/`_CERTIFICATE_PATH`, `SENTINEL_SS_PASSWORD` vs
   `SENTINEL_SS2022_SERVER_PASSWORD`), one listen-address convention, one xhttp transport
   `type`, and a single, deliberate decision on the extras (clash_api, obfs/masquerade,
   the bittorrent route rule) — keep or drop each consciously, matching what `myceliumctl`
   actually fills and what `params.json` provides.
4. **Delete or alias the redundant file** so there is exactly one source; if a name must be
   kept for compatibility, make it a thin pointer, not a second editable copy.
5. **Re-render + `sing-box check`** the merged template against a real `params.json` +
   `identities.json` and confirm the rendered inbounds + ports are unchanged from what the
   live network runs (shape-preserving reconciliation, not a data-plane change).

**Definition of Done.** Exactly one server template is the rendered source of truth; its
inbound tags align with the bootstrap's keep-list and `verify_listen_ports`; a render +
`sing-box check` produces the same checked inbounds/ports the network already runs; the
redundant template is removed or reduced to a non-editable alias; `validate_configs` stays
green.

**Verification.**
- `myceliumctl render-server --template <merged> …` → `sing-box check -c <out>` passes; the
  rendered inbound tag set matches the `harden_ufw`/`verify_listen_ports` selection (no port
  opened-but-unbound, none bound-but-unopened).
- A diff of the rendered config before/after reconciliation shows no change to listen ports
  or enabled inbounds (data-plane-preserving).
- Only one editable template remains under `nodes/dataplane/singbox/`;
  `tests/run.sh` (`validate_configs`, `phase0_port_canon`, `per_protocol_toggle`) stays green.

**Dependencies / ordering.** Independent of W1–W4; land before/with W7 so convergence is
verified against the single template. Touches the data-plane config surface, so it carries
its own CHANGELOG/version bump.

**Risks + mitigations.** **Template drift** is the very thing this workstream removes —
mitigated by collapsing to one source and tying tags to the keep-list. A reconciliation that
silently changes a port/inbound → the before/after render diff + `sing-box check` +
`phase0_port_canon` gate catch it. Wrong file kept editable → enforce "exactly one" in
review (optionally a tiny check that the alias is a pointer). **Threat-model:**
*Signature-based DPI* (the rendered transport shape is unchanged); *Active probing* (the
firewall opens exactly the enabled ports — no extraneous open port from tag mismatch).

---

### W6 — Enforce the leak-free-public-tree invariant
**Goal.** Make the catastrophic leaks mechanically impossible for this public,
root-applied-network repo: **no node IP or location, no secret/key material, and no AI/tool
vendor fingerprint may enter the tree.** Each invariant is enforced by a fail-closed offline
conformance check wired into the suite.

**Steps.** Add/extend the conformance suite so each invariant above is enforced fail-closed,
with precise allowlists for legitimate config (the RFC 5737 documentation ranges, the RFC 1918
private + loopback/ULA ranges a config legitimately needs, the documented `SENTINEL_*`
placeholders and `*.example.json` fixtures, and the policy docs that must name forbidden tokens
to define them). The concrete checks, their allowlists, and exemptions are an engineering detail
maintained in [`../development.md`](../development.md) and the conformance directory — **not
enumerated in this proposal**.

**Definition of Done.** Each invariant above is enforced fail-closed by the conformance suite,
green on the clean tree; a deliberately seeded leak of each kind (a node IP/location, a
secret/PEM, an AI/vendor fingerprint) is caught while the legitimate allowlisted/exempt cases
are not flagged.

**Verification.**
- `bash tests/run.sh` passes with all conformance checks green on the clean tree.
- Seed-and-revert tests: an injected node IP/location, a PEM/token, and an AI/vendor fingerprint
  are each caught fail-closed; the legitimate allowlisted/exempt cases (the documentation IP
  ranges, the `SENTINEL_*` placeholders, the policy docs) are **not** flagged.
- The checks honor gitignore (local state/secrets are not scanned), matching the existing suite.

**Dependencies / ordering.** Independent of W1–W5; **must be green before the first real
signed push in W7** (the gates are the guarantee that the pushed artifacts are leak-free).

**Risks + mitigations.** False positives blocking legitimate config (a private-range IP in a
template, a SENTINEL placeholder) → precise allowlists/exemptions and seed-and-revert tests prove
both directions. An over-broad fingerprint check tripping ordinary prose → scope it to whole-word
vendor tokens and exempt the policy docs that define the rule, as the existing suite does.
**Threat-model:** *Supply-chain interference* (leak-free public artifacts); *Operator
coercion* / *Knowledge minimisation* (no IP/location/identity breadcrumb in the public tree).

---

### W7 — Verify network convergence (one signed push → all nodes, links unchanged)
**Goal.** Prove end-to-end that a single signed push converges the whole network: every node
fetches, verifies the operator signature, re-renders **from its own local identity**,
validates, and applies-or-rolls-back — and **client links are unchanged** afterward.

**Steps.**
1. **Prepare a no-op signed push:** sign a tag whose artifacts re-render byte-identically on
   already-converged nodes (e.g. a docs-only change) and confirm every node's timer logs the
   no-op short-circuit (zero restarts) — proving the signature path + local-identity render
   without disturbing live traffic.
2. **Prepare an effective signed push:** sign a tag with a real, safe data-plane change
   (e.g. add a donor candidate to
   [nodes/dataplane/donor-sni-candidates.json](../../nodes/dataplane/donor-sni-candidates.json),
   or toggle a protocol), and confirm each node re-renders from **its own** identity (keys
   never regenerated on update), validates, applies, and passes the post-apply health check
   (active + expected ports bound).
3. **Assert links unchanged:** after both pushes, re-issue a subscription on each node and
   confirm it is byte-equivalent to what clients already hold (no key/UUID/donor rotation) —
   the convergence must change the *config*, never the *identity*.
4. **Assert rollback under the convergence path:** push (to a throwaway ref) a change that
   passes schema but fails post-apply on at least one node, and confirm that node rolls back
   to last-known-good and exits non-zero while the rest converge — i.e. one bad node does not
   block, and a bad change cannot brick, the network.
5. **Author a convergence-check helper** (test-only) that, given the node list, asserts each
   node is on the signed tag, re-rendered from local identity, and reports unchanged links —
   the repeatable "is the network converged?" check.

**Definition of Done.** A single signed push converges every node (no-op push → zero
restarts; effective push → all nodes re-render-from-local-identity, validate, apply, pass
health); client subscription links are **unchanged** across both pushes; a deliberately
failing change rolls back on the affected node without blocking the rest; the convergence
helper reports green.

**Verification.**
- After a no-op signed push: every node logs the no-op short-circuit;
  `ExecMainStartTimestamp` for `sing-box` is unchanged network-wide (zero restarts).
- After an effective signed push: every node's live config reflects the change; each node's
  `identity.json` is byte-identical before/after (no key regeneration);
  `verify_post_apply`/`verify_listen_ports` pass on each.
- Re-issued subscriptions match the pre-push ones (existing clients keep working unchanged).
- The failing-change test rolls back the affected node (journal shows "rolling back" +
  `config.lastgood.json` restored) and the other nodes converge; the convergence helper
  reports each node on the signed tag with unchanged links.

**Dependencies / ordering.** Last; consumes W1 (signing), W2 (migrated identities), W3 (the
timer), W5 (the single template), and W6 (the gates green before the first real push).

**Risks + mitigations.** **Link instability if identity/donor regenerate** — the convergence
proof's central assertion is that updates re-render from local identity and never regenerate
keys; the before/after `identity.json` diff + subscription byte-equivalence are the gates.
**SSH lockout / a node stuck off the tag** → per-node rollback is independent, and a re-push
of the good tag re-converges via the no-op-aware update; keep an out-of-band recovery path to
any node that fails to converge. **Threat-model:** *Active probing* (a failed apply never
exposes an unverified config — it rolls back); *Knowledge minimisation* (convergence changes
config, not identity, so no new user-correlating material is introduced).

---

## 6. Risks
- **Compatibility.** The dominant compatibility concern is **client links must not change**
  for existing users. W2 (transform-not-regenerate, byte-equivalence diff) and W7
  (subscription byte-equivalence assertion) are the gates; no parallel client contract is
  needed because the schema is *migrated onto*, not changed. The W5 template reconciliation
  is shape-preserving (same rendered inbounds/ports), verified by a before/after render diff.
- **User security (requirement №1).** No de-anonymisation, logging, PII, or correlation is
  introduced. Per-node identity stays local (0600); only public keys, pins, and subscriptions
  are exported ([ADR-0014](../adr/0014-per-operator-node-credentials.md)). The new W6 gates
  *strengthen* this by mechanically refusing IP/secret/identity leaks into the public,
  network-applied repo. `--insecure-no-verify` stays testing-only and is never on the timer.
- **Indistinguishability / probe surface.** Unchanged at the transport layer — the same
  checked inbounds are rendered; donor selection stays random-per-node. W5 additionally
  guarantees the firewall opens *exactly* the enabled ports (no extraneous open port from a
  tag mismatch).
- **Supply-chain (primary risk).** A single bad push to the **public** repo applied
  network-wide as root: mitigated by W1 (signature verified before the fast-forward merge — no
  unauthenticated code runs), the re-exec self-modification guard, `sing-box check` + the
  unit `ExecStartPre` (two independent schema gates), and W6 (leak-free artifacts). The
  signature **is** the approval; an unsigned/forged push is refused before its code executes.
- **SSH lockout.** The update path may re-run host hardening; the anti-lockout guards stay
  (key confirmed for a real account before passwords are disabled, validated with `sshd -t`;
  the live sshd port opened before `ufw enable`, never assuming 22). An out-of-band
  recovery/console path is kept for any node that fails to converge.
- **Link instability if identity/donor regenerate.** Updates **never** regenerate keys
  (`ensure_identity` keeps existing secrets; `--update` re-renders from local identity); W2
  migrates existing material rather than minting new; operators are warned never to wipe the
  state dir. Gated by the before/after `identity.json` diff and subscription byte-equivalence.
- **Template drift.** Removed by W5 (one source of truth, tags tied to the keep-list);
  residual risk of the wrong file being edited is contained by deleting/aliasing the
  redundant template and the `phase0_port_canon`/`validate_configs` gates.
- **Loss of observability/measurements.** None removed; the no-op short-circuit explicitly
  avoids needless restarts (no signal loss). A node that fails to converge surfaces a
  non-zero exit + journal entry (volatile, in RAM per the journald posture).
- **Temporary degradation.** An *effective* signed push restarts sing-box on changed nodes
  (Type=simple, no real reload — applying = restart, briefly dropping live connections); an
  *unchanged* push restarts nothing (no-op short-circuit). The randomized timer delay avoids
  a synchronized network restart.
- **Flapping / false migrations.** No auto-rotation exists (Phase 2, `deferred`), so there is
  no false-migration risk; convergence is operator-initiated (a signed push) only.
- **Rollback risk.** Low and per-node: each node validates-then-applies and restores
  `config.lastgood.json` on any failure; a bad tag cannot brick the network, and re-pushing the
  good tag re-converges via the no-op-aware update.
- **Impact on decentralisation.** None — the "fan-out" is a signed git push pulled by
  independent per-node timers (any mirror works); no central coordinator/registry is
  introduced. Each node stays self-sufficient ([ADR-0014](../adr/0014-per-operator-node-credentials.md)).

## 7. Acceptance Criteria
- [ ] A node with `--repo-ref <signed-tag> --allowed-signers <file>` applies the signed tag
  and **refuses** an unsigned/forged ref (fail-closed; nothing fetched executed) — W1.
- [ ] Each migrated hand-built node re-renders byte-equivalently from its **existing**
  identity (no-op short-circuit fires); every existing client subscription link still
  authenticates **unchanged** — W2.
- [ ] `mycelium-update.timer` is active on every node; an unchanged signed push causes **zero
  restarts**; an invalid candidate is never promoted; a post-apply failure rolls back to
  last-known-good — W3.
- [ ] An additional operator bootstraps a self-sufficient node in one command (local
  identity, no shared key material) and hands off subscriptions out-of-band (REALITY params +
  per-node HY2/TUIC pin); the node converges on the signed tag — W4.
- [ ] Exactly **one** sing-box server template is the rendered source of truth; its inbound
  tags match the bootstrap's firewall keep-list; render + `sing-box check` reproduce the
  network's current inbounds/ports — W5.
- [ ] Conformance green: the existing offline suite **plus** the three new gates
  (`no_ip_literal`, `no_secret_material`, `no_ai_fingerprint`) — `bash tests/run.sh` passes
  (now 12 offline gates); a seeded leak of each kind is caught and the allowlisted/exempt
  cases are not — W6.
- [ ] A single signed push converges the whole network (no-op push → zero restarts; effective
  push → all nodes re-render-from-local-identity, validate, apply, pass health); a
  deliberately failing change rolls back on the affected node without blocking the rest;
  **client links unchanged** — W7.
- [ ] No excluded legacy transport is present ([ADR-0010](../adr/0010-phase0-transport-set.md));
  no shared network key material exists ([ADR-0014](../adr/0014-per-operator-node-credentials.md)).
- [ ] Survivability/recovery not degraded: handshake success rate healthy across the network
  before and after convergence; the manual network primitive (one signed push → converged) and
  per-node rollback both work.

> netsim/netem adversary scenarios (`rst_injection`, `as_blackhole`, `udp_drop`) exercise the
> *detector/rotation* response, which is `deferred` to Phase 2. This RP's adversary surface is
> *supply-chain* (the signature gate) and *active probing of an unverified config* (the
> validate-then-rollback gate); the netem block→recover scenarios are out of scope here.

### Non-goals (deferred to later phases — not in this RP)
- **Interference detector & auto-rotation logic** — convergence here is operator-initiated (a
  signed push), not detection-driven (Phase 2).
- **Central coordinator / network registry / online push fan-out** — the fan-out is a signed
  git push pulled by per-node timers; a registry/coordinator is Phase 3.
- **AS-diversity / multi-provider provisioning** — Phase 1; a single IP/AS per node remains a
  single blocking point by design.
- **Moving the fetch to signed release tarballs** — the `myc_fetch_artifacts` swap is
  designed and documented (the signature gate must be preserved) but is a later step; this RP
  arms the pinned-git-pull path.
- **Carrier-agnostic spores, DHT, trust gradients, learning federation** — must not run in
  Phases 0–2 (ROADMAP scope discipline); only inert data models/interfaces are permitted.
- **Client application / client-facing UX** — QR/subscription UI, per-client failover as a
  client feature (unchanged from RP-0001/RP-0002 out-of-scope).

## 8. Documentation changes
- [ ] `docs/adr/0015-<slug>.md` (**new**) — signed-release provenance for network artifacts:
  the signing-key + signed-immutable-tag + out-of-band `allowed_signers` decision W1 arms,
  why `--insecure-no-verify` is testing-only, and how the gate is preserved across the future
  fetch-to-tarball swap. Add the row to [../adr/README.md](../adr/README.md).
- [ ] [../runbooks/node-bootstrap.md](../runbooks/node-bootstrap.md) — add the signing-pipeline
  setup (W1), the hand-built-node migration procedure (W2), the additional-operator onboarding
  + out-of-band subscription handoff (W4), and the convergence-verification drill (W7); note
  the single reconciled template (W5).
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — record the *supply-chain* provenance gate and
  the W6 preventive leak gates under the relevant rows; confirm the no-logs/RAM posture.
- [ ] [../ROADMAP.md](../ROADMAP.md) — record that the network is signed + self-updating (the
  manual network primitive lands; automated detection-driven rotation remains Phase 2).
- [ ] Contract/registry reconciliation — collapse the two
  [`nodes/dataplane/singbox/`](../../nodes/dataplane/singbox/) templates into one (W5);
  align SENTINEL names + tags with the bootstrap keep-list; update
  [nodes/dataplane/singbox/README.md](../../nodes/dataplane/singbox/README.md).
- [ ] `tests/conformance/{no_ip_literal,no_secret_material,no_ai_fingerprint}.sh` (**new**) +
  [`tests/run.sh`](../../tests/run.sh) wired to run all twelve offline gates (W6).
- [ ] `infra/systemd/mycelium-update.{service,timer}` — confirmed/authored, documented in the
  runbook (W3).
- [ ] Component README/CHANGELOG + version bump (same commit) for each touched component:
  the sing-box template dir (W5), `tests/conformance` (W6), `infra/systemd` (W3),
  `scripts/`+runbook (W1/W2/W4), and this proposals index.
- [ ] [docs/proposals/README.md](README.md) — add the RP-0003 row (this RP).

## 9. Migration Strategy
The system is partly live (existing hand-built nodes serving real clients), so "migration"
means **arm, migrate, then converge — without ever changing a client link**:

- **Stages.** W1 (arm signing) → W2 (migrate existing nodes' identity into schema,
  links preserved) → W3 (install the timer everywhere) → W4 (onboard additional operators) →
  W5 (collapse to one template) → W6 (preventive gates green) → W7 (prove convergence). W1 is
  a hard prerequisite for W3/W7; **W2 must precede W3 on existing nodes** so the auto-updater
  never re-renders from absent/new identity; W6 must be green before the first real signed
  push in W7.
- **Parallel coexistence.** Existing hand-built nodes and freshly-onboarded nodes coexist
  from the moment W2 completes — both run the same `--update` engine against the same signed
  tag, each from its **own** local identity. No old/new client contract split is needed (the
  schema is migrated onto, not changed). During W5, the two templates coexist only until the
  redundant one is deleted/aliased; the rendered output is unchanged throughout.
- **Final cutover.** The moment W7's first effective signed push converges every node with
  unchanged links, the network is "signed + self-updating." The ROADMAP note is flipped only
  then.
- **Old-version nodes during transition.** A node not yet migrated (W2) or not yet running
  the timer (W3) keeps serving its current config by hand; it does not auto-update until both
  are done for it, so there is no window where an unmigrated node re-renders from new identity.
- **Dependencies (rollout order).** signing armed (W1) → existing-node identity migrated (W2)
  → timer installed (W3) → additional operators onboarded (W4) → single template (W5) →
  gates green (W6) → convergence proven, links re-verified unchanged (W7).

## 10. Rollback / Fallback
- **How to roll back, and how fast.** Rollback is **per node and automatic**: each node
  validates a candidate (`sing-box check`) and, on any apply/post-apply failure, restores
  `config.lastgood.json` and restarts onto it (a persistent private network — downtime means
  people without access, so rollback is fast and built into every update). To stop the network
  converging at all, revert the signed tag (re-sign the previous good commit, or
  `systemctl disable --now mycelium-update.timer` per node); the no-op-aware update means a
  re-pushed good tag re-converges without extra restarts.
- **Data/keys/IPs to preserve.** Preserve every node's state dir (`/var/lib/mycelium`:
  `identity.json`, `identities.json`, `params.json`, the TLS dir, the AmneziaWG keys,
  `config.lastgood.json`) — these are the local identity that keeps client links stable; the
  W2 migration keeps a pre-migration copy until one real update succeeds. The operator signing
  **private** key and `allowed_signers` are out-of-band; never commit any of this.
- **Contract/config versions kept in parallel.** None client-facing — the schema is migrated
  onto, not branched. During W5 the redundant template is kept only until the single source is
  proven, then removed/aliased.
- **Fail-closed behaviour during rollback.** No silent security bypass: an unsigned/forged
  push is refused (W1) before any code runs; a node that fails `sing-box check` or post-apply
  health is **never** promoted and stays on last-known-good; `--insecure-no-verify` is never
  used on the network timer; rollback never regenerates identity (links stay stable) and never
  disables the no-logs/anti-lockout posture. The safe state is *converged-or-last-known-good*,
  never *applied-but-unverified*.

---

## No-secrets / no-IP / no-location note (explicit)
This RP and every artifact it produces obey the project's public-repo discipline. **No** node
IP/IPv6 literal, hostname, jurisdiction/country name, location code, personal email, real
secret/key/UUID, or AI/tool vendor fingerprint (nor `Co-Authored-By:`) is written into any
committed file. Per-node identity — the REALITY private key, client UUIDs, per-protocol
secrets, the self-signed cert key, the chosen donor, and the node's reachable address — is
**local-only** (`/var/lib/mycelium`, 0600) and is migrated/preserved on-node, never committed
or exported beyond the public key + client pins + subscriptions handed off out-of-band
([ADR-0014](../adr/0014-per-operator-node-credentials.md)). The operator **signing private
key** and the `allowed_signers` file are out-of-band artifacts, never in the tree. W6 turns
this discipline from policy into three fail-closed gates (`no_ip_literal`,
`no_secret_material`, `no_ai_fingerprint`) so the public, root-applied-network repo is
mechanically guaranteed leak-free.
