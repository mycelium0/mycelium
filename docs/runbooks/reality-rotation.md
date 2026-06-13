<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbook — Manual REALITY-parameter rotation (Phase 0)

The Phase-0 way to rotate a node's REALITY parameters **on operator intent** — for example after the
current donor SNI or short id is suspected burned, or on a routine hygiene schedule. This is the
manual procedure mandated by [ADR-0020](../adr/0020-phase0-scope-reconciliations.md) §3; automated or
block-triggered rotation is **Phase 2** (the adaptation layer), not this.

> **This DELIBERATELY changes client links.** Rotating the REALITY keypair, short id, or donor SNI
> changes the `pbk` / `sid` / `sni` embedded in every client link for this node. It is the opposite of
> the link-stable self-update (`node-bootstrap.sh --update`, which re-renders from the *existing*
> identity and never regenerates it). Rotate only when you mean to, and plan to re-hand the new
> subscriptions to users out-of-band ([ADR-0020](../adr/0020-phase0-scope-reconciliations.md) §1).
> It is **per node** — rotating one node does not touch any other node (per-operator credentials,
> [ADR-0014](../adr/0014-per-operator-node-credentials.md)).

## What rotates
- **REALITY keypair** (`private_key` / `public_key`) — the steal-the-handshake identity.
- **short id(s)** (`short_id`) — the per-node selector.
- **donor SNI** (`donor.sni` / `donor.host`) — optional; only if the current donor is suspected burned.

Client **UUIDs are NOT touched** by this procedure (revoking/issuing a *client* is a separate action,
`myceliumctl identity revoke|add`). Rotating REALITY keeps the same users but gives them new links.

## Preconditions
- Root on the node; `myceliumctl` on PATH (installed by the bootstrap under the tooling dir).
- A maintenance window: applying the new config restarts sing-box and briefly drops live connections.
- A way to hand the regenerated subscriptions to users out-of-band afterwards.

## Procedure (on the node)
All key material comes from the sanctioned generators only — never hand-rolled
([ADR-0002](../adr/0002-no-custom-cryptography.md)).

1. **Back up the current identity** (so you can roll back):
   ```sh
   cp -a /var/lib/mycelium/identity.json /var/lib/mycelium/identity.json.bak
   ```
2. **Generate a fresh REALITY keypair + short id** with the sanctioned generator and write the new
   values into the node's local identity (REALITY fields only — leave `clients` untouched):
   ```sh
   myceliumctl reality-keys            # emits a fresh private/public keypair + short id
   # update /var/lib/mycelium/identity.json: reality.private_key, reality.public_key, reality.short_id
   ```
   To also rotate the donor, pick a new one from the curated list and re-verify it supports TLS1.3 +
   X25519 + H2 before committing it:
   ```sh
   # choose a new donor host/SNI from nodes/dataplane/donor-sni-candidates.json, verify, then set
   # donor.host / donor.sni in identity.json
   ```
3. **Re-render the server config from the updated identity** and validate it fail-closed.
   Do **not** hand-render: `params.json` is derived from `identity.json`, so editing the
   identity alone leaves the cached params (and thus the rendered key) stale. Re-run the
   bootstrap, which regenerates params from the updated identity before rendering:
   ```sh
   node-bootstrap.sh --update            # regenerates params from identity, then renders + checks
   ```
   (`node-bootstrap.sh --update` already wires regenerate-params → render → `sing-box check` →
   promote → settle-check → rollback; re-running it after editing the identity performs steps 3-4
   with that fail-closed gating.)
4. **Promote and restart**, then confirm the data plane is up:
   ```sh
   systemctl restart sing-box
   systemctl is-active sing-box && ss -tlnp | grep -E ':(443|8443)\b'
   ```
   If sing-box does not come back active, restore the backup and restart:
   ```sh
   cp -a /var/lib/mycelium/identity.json.bak /var/lib/mycelium/identity.json
   # re-render from the restored identity, sing-box check, restart
   ```
5. **Re-issue and re-distribute subscriptions** (the links changed):
   ```sh
   myceliumctl subscription ...        # regenerate per-user bundles from the new identity
   ```
   Hand the new bundles to users out-of-band. Old links for this node stop working once the restart in
   step 4 lands — coordinate the cutover.

## After rotation
- Old REALITY params are dead on this node immediately after step 4; there is no overlap window, so
  schedule the cutover when users can re-import.
- Record the rotation in the node inventory (date, reason) for the AS/operational log.
- Do **not** commit any of `identity.json`, `params.json`, rendered configs, or the regenerated
  subscriptions — they are per-node secrets and are gitignored.
