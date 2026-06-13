<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Runbook — on-node bootstrap + semi-auto network updater

This runbook covers the **on-node** path: a single idempotent script
([`scripts/node-bootstrap.sh`](../../scripts/node-bootstrap.sh)) that brings a fresh node up and
then keeps the whole network identical via a push-to-update loop. It is complementary to the
control-host Ansible path in [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) — use whichever
fits, both yield the same standard endpoints.

The node provides a persistent private network; framing here is neutral and technical throughout.

> **Software, not an operated network.** This repository publishes server-side software; it does not
> operate a public network, publishes no public endpoints, and distributes no public client configs.
> Each operator independently deploys and controls **their own** node and **their own** network (see
> the [README separation statement](../../README.md#what-this-is)). "The operator" below means
> *whoever is self-hosting this network* — there is no single project-wide owner of a network.

> **Signing is operator-local, by design — and the project-wide state is deliberately unsigned.**
> The signature mechanism below is each operator verifying **their own** pushes to **their own**
> network with **their own** out-of-band key. At the **project** level there is, on purpose, **no
> single signer**: because the shared identity is community-owned and approval is moving to
> community/organization consensus ("fungi voting") from Phase 1–2, designating one legal signer is
> specifically being avoided, so project-level updates are currently accepted **UNSIGNED /
> insecure** as a documented interim state (see [GOVERNANCE.md §6](../../GOVERNANCE.md)). The per-network
> signing here is the operator-local control available in the meantime, not a project-wide signer.

## Mental model

- **One source of truth, many identical nodes.** The operator self-hosting the network pushes
  canonical artifacts to **their** repo once. Every node runs a timer that pulls, re-renders **from
  its own local identity**, validates, and applies — so the network is testable together with no
  per-node hand-work.
- **"Semi-auto" = the human approval IS the self-hosting operator's SIGNATURE on the pushed ref.**
  Nodes apply automatically, but **fail-closed**: each node first verifies that the canonical ref is
  signed by **that operator's** out-of-band key (`--allowed-signers`, never committed) and refuses to
  run any fetched code otherwise; only then is the candidate config validated with `sing-box check`
  and rolled back on any failure. So a single bad push to the repo can neither own nor brick the
  network — an unsigned/forged push is rejected before its code ever executes. (This is an
  operator-local guarantee for one's own network; it is not, and does not imply, a single project-wide
  signer — see the note above.)
- **Secrets never leave the node.** The REALITY private key, client UUIDs, per-protocol secrets,
  and the self-signed cert key live only under `/var/lib/mycelium` (`0600`). Only the REALITY
  **public** key and per-client subscriptions are ever exported.

## What a friend runs (one command)

On a fresh Ubuntu 22.04 or 26.04 node, as root (the pinned version + checksum are the operator's
fail-closed pins — get them from the sing-box release page):

```sh
# 1) Put the canonical checkout outside the repo working tree (prefer /opt).
git clone <CANONICAL_REPO_URL> /opt/mycelium

# 2) Add your SSH public key first (anti-lockout: sshd is only hardened AFTER a key is confirmed).
#    ssh-copy-id, or paste into ~/.ssh/authorized_keys.

# 3) Bootstrap + converge (idempotent — safe to re-run).
sudo /opt/mycelium/scripts/node-bootstrap.sh \
  --singbox-version vX.Y.Z \
  --singbox-sha256  <SHA256_OF_THE_LINUX_ARCHIVE> \
  --clients "alice bob" \
  --node-address    <THIS_NODE_REACHABLE_HOST_OR_IP> \
  --yes
```

> **`--node-address` matters for subscriptions.** Generated client subscriptions dial this value.
> If you omit it, the script auto-detects the primary global address; if detection fails it falls
> back to the documented placeholder (`node.example.invalid`) and warns loudly — subscriptions
> generated against the placeholder will **not** connect. Set a real value before generating them.

What that does, in order (all idempotent, all fail-closed):

1. **Harden the host** — journald to volatile; key-only sshd (only after an authorized key is
   confirmed for *any* real account, including non-standard home dirs and `AuthorizedKeysFile`
   overrides, validated with `sshd -t` before reload); ufw default-deny that first opens the
   **actual** sshd listen port(s) parsed from the effective config (never assumes 22), then only
   the **enabled** protocols' canonical ports (read from the live rendered config).
2. **Install sing-box** — the pinned GitHub release, **SHA256-verified** against your pin before
   install (mismatch aborts). Skips if the pinned version is already present.
3. **Install the control tooling** — copies `control/` to `/usr/local/lib/mycelium` so
   `myceliumctl` is self-locating on the node.
4. **Generate per-node identity locally if absent** — REALITY keypair
   (`sing-box generate reality-keypair`), client UUID(s) (`sing-box generate uuid`), a shortId
   (`openssl rand -hex 8`), HY2/TUIC/SS/ShadowTLS secrets (`sing-box generate rand` /
   `openssl rand`), and a per-node **self-signed** cert (`CN=donor`, via `openssl`). No
   hand-rolled crypto (ADR-0002).
5. **Pick + verify a random donor SNI** — chosen at random from the committed candidate list
   ([`nodes/dataplane/donor-sni-candidates.json`](../../nodes/dataplane/donor-sni-candidates.json))
   and verified at runtime (`openssl s_client -groups x25519 -tls1_3` must negotiate TLSv1.3),
   reselecting on failure.
6. **Write `params.json`** — the **flat** render schema, local-only (`0600`), built from the local
   identity and the **canonical** port map (not from `params.example.json`, whose port values
   drift).
7. **Render the config** through the existing `myceliumctl render-server` pipeline (no embedded
   config blob), then **`sing-box check`** the result as the fail-closed gate.
8. **Install + start** the hardened `sing-box.service`.
9. **Set up the userspace AmneziaWG path** (`amneziawg-go`, kernel-independent) — out-of-band of
   the sing-box render. If the userspace tools are not yet built from source, this step prints
   exactly what to build and converges on the next run.
10. **Verify listeners** — fails closed if the service is not active.

Re-running the same command **converges/updates** the node without regenerating identity.

## How a network-wide update flows ("git push → whole network updates")

```
operator: git push  (canonical artifacts to the public repo)   <-- the human approval
        │
        ▼
each node, every few minutes (mycelium-update.timer):
  re-exec from an immutable copy  # so the in-place fetch cannot rewrite the running script
        │
        ▼
  myc_fetch_artifacts        # fetch, then VERIFY the operator signature on the pinned ref
        │                    # (fail-closed) BEFORE the fast-forward merge runs any fetched code
        ▼
  re-render FROM LOCAL identity   # keys are NEVER regenerated on update
        │
        ▼
  sing-box check (candidate)      # fail-closed gate the renderer does not run itself
        │
   ┌────┴─────────────┐
   ▼                  ▼
 PASS               FAIL
   │                  │
 candidate == live?  discard candidate; live config + service untouched
   │   │             (node stays on last known-good)
   │  yes → no change; service NOT restarted (zero downtime for unchanged pushes)
   no
   │
 promote +          # sing-box is Type=simple with no real reload: applying = RESTART
 restart sing-box   (briefly drops live connections)
   │
   ▼
 active AND expected ports bound? ── no ──► ROLL BACK to last-known-good, restart, exit non-zero
   │
  yes → done (node now matches the network)
```

Install the timer on every node:

```sh
sudo cp /opt/mycelium/infra/systemd/mycelium-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mycelium-update.timer
```

The updater needs the operator's signing key to verify pushes. Ship it **out-of-band** (never in
the repo) and point the unit at it, e.g. append `--allowed-signers /etc/mycelium/allowed_signers`
to the unit's `ExecStart`, and pin `--repo-ref` to an **immutable signed tag** rather than a
branch. (For local testing only, `--insecure-no-verify` bypasses verification with a loud warning;
never run the network timer with it.)

- **Default mode** (`--update`): re-exec from an immutable copy → fetch → **verify signature** →
  re-render → validate → **apply with rollback** (a no-op when the candidate equals the live
  config).
- **Stricter mode** (`--update --staged`): stage a *validated* candidate and **wait** for the
  operator's explicit `node-bootstrap.sh --ack` before promoting. Switch a node to it by appending
  `--staged` to the unit's `ExecStart`.

### The fetch step is swappable

`myc_fetch_artifacts` is the single function that knows **how** canonical artifacts arrive. Today
it does a pinned, fast-forward-only `git fetch` and then a **signature-verified** merge: the pinned
ref must carry a valid signature from the operator's out-of-band key (`verify_signed_ref`) before
any fetched code is merged, installed, or executed — fast-forward-only alone does not stop a fresh
malicious commit. To move to packages/releases later, replace only that function with "download the
signed release tarball, verify its signature + checksum, unpack into the checkout" — the rest of
the updater is unchanged, and the signature gate **must** be preserved.

## Verifying and rolling back by hand

```sh
# Dry-run an update (changes nothing):
sudo /opt/mycelium/scripts/node-bootstrap.sh --update --dry-run

# Inspect the last-known-good backup the updater keeps:
ls -l /var/lib/mycelium/config.lastgood.json

# The updater rolls back automatically on failure. To roll back manually (applying a config is a
# RESTART — sing-box is Type=simple with no real reload — so this briefly drops live connections):
sudo install -m 0644 /var/lib/mycelium/config.lastgood.json /usr/local/etc/sing-box/config.json
sudo systemctl restart sing-box
```

## Fail-closed guarantees (why a bad push cannot own or brick the network)

- **Provenance first.** Fetched artifacts are merged/installed/executed only after the pinned ref's
  **operator signature** verifies against an out-of-band key. An unsigned/forged push is refused
  before any of its shell (`node-bootstrap.sh`, `myceliumctl`, `render_singbox.sh`) ever runs as
  root, so a single bad push to the public repo cannot achieve network-wide code execution.
- **The updater cannot mis-run itself.** `--update` re-execs from an immutable copy before fetching,
  so the in-place merge cannot rewrite the running script and make it skip validation/rollback.
- The renderer only emits **valid JSON**; the updater additionally runs **`sing-box check`** and
  the unit's `ExecStartPre` runs it again — two independent gates.
- A candidate is **never** promoted unless it passes check. Applying is an explicit **restart**
  (sing-box is `Type=simple` with no real reload), and a byte-identical candidate is **not** applied
  at all (zero downtime for unchanged pushes). After a restart the node asserts the service is
  active **and** the expected listen ports are bound; on any failure the previous **last-known-good**
  config is restored and the service is left serving it.
- sshd is only hardened **after** an authorized key is confirmed for a real account (any home dir /
  `AuthorizedKeysFile`) and the config passes `sshd -t`; ufw opens the **actual** sshd port(s)
  before enabling, never assuming 22.
- Every node-specific value (keys, donor, ports, the node address, the signing key) is a
  **local-only** / out-of-band artifact; nothing node-specific is ever committed.

## Known prerequisites the operator resolves on live nodes

- The operator's **signing key** must be distributed out-of-band to every node and referenced via
  `--allowed-signers`; canonical pushes are **signed**, and `--repo-ref` is pinned to an immutable
  signed tag. Without this the updater refuses to apply (fail-closed) unless `--insecure-no-verify`
  is explicitly set (testing only).
- The canonical sing-box `--singbox-version` + `--singbox-sha256` pins must be supplied per release.
- The AmneziaWG userspace tools (`amneziawg-go`, `awg`, `awg-quick`) are built from source
  (kernel-independent); the bootstrap converges once they are on `PATH`.
- The renderer-compatible template
  ([`nodes/dataplane/singbox/server.template.renderer.json`](../../nodes/dataplane/singbox/server.template.renderer.json))
  is used because the historical canonical template's inbound tags diverge from the renderer's
  tag set; reconcile the two into one source on the live nodes when convenient.
