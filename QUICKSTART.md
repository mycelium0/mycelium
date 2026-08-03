<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Quickstart — stand up a node

Mycelium is server software for resilient, private connectivity over degrading or unreliable
networks. This guide takes a fresh Linux server to a running node in a few commands.

## You need

- A Linux server (x86-64 / amd64 or arm64) with `root` (or `sudo`), `curl`, `tar`, and `git`.
- The maintainer's **signing key**, obtained out-of-band, as an `allowed_signers` line (used to
  verify the release; see [docs/RELEASING.md](docs/RELEASING.md)).

## 1. Fetch and verify a release

```sh
# download the tagged artifact + checksums (or `gh release download vX.Y.Z`). The detached signature
# SHA256SUMS.sig is signed + attached by the maintainer SEPARATELY (ADR-0015 — CI holds no signing key),
# so it can lag the tarball by minutes; the `|| ...` below tolerates its absence.
ver=vX.Y.Z
base="https://github.com/mycelium0/mycelium/releases/download/$ver"
curl -fsSLO "$base/mycelium-${ver#v}.tar.gz"
curl -fsSLO "$base/SHA256SUMS"
curl -fsSLO "$base/SHA256SUMS.sig" || echo "note: SHA256SUMS.sig not attached yet — do an integrity-only check now, or wait for the maintainer to upload it for authenticity."

# verify, fail-closed (REL-3)
tar -xzf "mycelium-${ver#v}.tar.gz" && cd "mycelium-${ver#v}"

# TODAY: integrity only. This is executable right now and it fails closed — an empty, truncated or
# HTML-body SHA256SUMS is refused rather than reported as verified.
scripts/verify-release.sh ..

# ONCE THE MAINTAINER'S KEY IS PUBLISHED (see below), add authenticity. You are never told the signer
# identity separately — it is the first field of the published allowed_signers line:
signer="$(awk 'NF{print $1; exit}' allowed_signers)"
scripts/verify-release.sh .. --allowed-signers ./allowed_signers --signer "$signer" --tag "$ver"

# put the VERIFIED tree where the node will keep it, so every later command means the same directory
sudo mkdir -p /opt && sudo cp -a "../mycelium-${ver#v}" /opt/mycelium && cd /opt/mycelium
```

> **The maintainer's public key is not published anywhere yet, so authenticity cannot currently be
> verified by anyone else.** It is not in this repository, and GitHub reports the commit signatures as
> `unknown_key` because the key is not registered on the account either. Until that changes there is
> exactly one executable check — integrity — and it tells you the bytes match the checksums *shipped
> beside them*, which is protection against a corrupted or truncated download and **not** against
> someone who replaced both. This is a real gap, stated here rather than hidden behind a placeholder
> path; it is tracked in [SECURITY.md §8](SECURITY.md#8-open-questions-tbd).

Once the key is published you will have an `allowed_signers` line to save as a file, and the signed form
above becomes the one to use. Two properties of the helper are worth knowing either way: without
`--allowed-signers` it checks integrity and **warns** that authenticity is unverified rather than implying
success, and passing `--allowed-signers` *before* `SHA256SUMS.sig` is attached **fails closed** (exit 1)
instead of silently downgrading. For a real deployment always end up on the signed form.

## 2. Deploy

```sh
sudo /opt/mycelium/scripts/fungi deploy \
  --clients alice \
  --node-address your.host.example
```

`deploy` takes no `--allowed-signers`, and it used to be shown with one. The flag is parsed and then
never read on this path: signature verification belongs to `update`, which fetches code it has not seen.
The first deploy runs the tree you verified in step 1, so passing a key here checked nothing and only
suggested otherwise.

The engine versions + checksums — and the Go toolchain that builds the control-plane spine — are pinned in
`control/engines.manifest.json` and fetched + checksum-verified automatically; you do **not** hand-enter
`--singbox-sha256`, and the node needs **no distro Go**. `fungi deploy` hardens the host, installs the
pinned engine, generates this node's identity locally, renders + validates the config, starts the service,
and then brings up **detection**: the measure + L7 liveness plane and the rotation loop that consumes it.
It is idempotent — re-running converges.

The loop **plans and reports; it does not promote.** Letting a node change its own served config
unattended is a separate, deliberate act:

| you run | what the node does |
|---|---|
| `fungi deploy` | serves, measures, and reports when a transport looks impaired |
| `fungi deploy --auto-rotate` | the above, **and may promote a new config on its own** when the planner decides a served transport is impaired |
| `fungi deploy --no-arm` | serves only — no detection plane, no loop |

To arm a node you already deployed, run the node-bootstrap flag directly — **not** `fungi deploy
--rotate-arm`, which would hand `--rotate-arm` to node-bootstrap as a *mode* and skip the converge:

```sh
sudo /opt/mycelium/scripts/node-bootstrap.sh --rotate-arm
```

Or simply re-deploy with `--auto-rotate`. Disarming is removing
`/var/lib/mycelium/rotate-live.enabled`; nothing else is needed, and no push can recreate it.

## 3. Check it is serving

```sh
scripts/fungi status        # service state, public listeners, engine versions (read-only)
scripts/fungi plan          # preview what this node will deploy (read-only)
```

## Later

```sh
sudo /opt/mycelium/scripts/fungi apply    # apply node-descriptor changes (transports / reachability)
```

### Updating a node

**A tarball install is not a git checkout, and `fungi update` is a git fetch.** Run it against the tree
you extracted above and it will refuse — correctly — because there is nothing to fetch into. Two supported
ways forward; pick one deliberately, because only the second can ever run unattended.

**Re-deploy from a newer release.** No git, and the verification chain stays end to end: every byte the
node runs came out of a tarball you checked.

```sh
# repeat step 1 with the new tag, then, from the new /opt/mycelium:
sudo /opt/mycelium/scripts/fungi deploy --clients alice --node-address your.host.example
```

**Or adopt a git checkout, which is what `fungi update` and the unattended timer need.** Clone the
repository at the signed tag; `--repo-ref` then verifies that tag's signature on every subsequent update
before a single fetched byte is executed.

```sh
sudo rm -rf /opt/mycelium                        # replaced by a checkout of the same verified tag
sudo git clone --branch vX.Y.Z https://github.com/mycelium0/mycelium /opt/mycelium
sudo /opt/mycelium/scripts/fungi update --repo-ref vX.Y.Z \
  --allowed-signers /etc/mycelium/allowed_signers   # the maintainer key — not published yet, see step 1
```

`update` VERIFIES the signed ref before running anything it fetched, so it needs the key — the first
deploy does not, because it runs from the tarball you already verified. If `/opt/mycelium` does not exist
at all, `--repo-url <url>` makes `update` clone it for you; it will not clone over a directory that
already has files in it.

A tag pin is also checked for real now: if the fast-forward cannot reach the tag — which is what happens
when a checkout is already ahead of it — the update **fails loudly** instead of doing nothing and
reporting success.

Choose what the node serves with the profile verbs — a single `fungi` surface. Each edits the node-local
descriptor / front config (write-only intent); nothing mutates a live node until `fungi apply` converges it:

(Run these from the checkout as `scripts/fungi …`, or symlink it once:
`sudo ln -s /opt/mycelium/scripts/fungi /usr/local/bin/fungi` — nothing installs it on `$PATH` for you.)

```sh
fungi transport list                          # the closed registry (proto / class / port / frontable)
fungi transport enable vless-ws-tls           # serve one more transport
fungi transport disable hysteria2             # stop serving one
fungi reachable off                           # make the node a non-public participant (binds loopback)
fungi front enable --domain cdn.example.com --transport vless-ws-tls   # bring-your-own-domain CDN front
fungi apply                                   # converge the descriptor onto the node (rollback on failure)
```

## Profiles — common recipes

A fresh node already serves a sensible **default profile**: REALITY Vision + gRPC (over TCP) plus AmneziaWG
(over UDP) — two independent transport families, the minimum a client needs to recover from a single-family
block (RP-0013). Toggle from there (post-deploy, once the spine is built):

```sh
# add genuine-TLS WebSocket (survives some IP/SNI blocks REALITY does not):
fungi transport enable vless-ws-tls && fungi apply

# add the Xray XHTTP transport:
fungi transport enable vless-xhttp-tls && fungi apply

# put a bring-your-own-domain CDN in front of a frontable transport (ws-tls or xhttp-tls):
fungi transport enable vless-ws-tls
fungi front enable --domain cdn.example.com --transport vless-ws-tls
fungi apply
# then deploy the compiled $STATE_DIR/front/edge.nginx.conf on YOUR edge host + point the domain's DNS at it

# a non-public participant (in-region relay, not a public entry):
fungi reachable off && fungi apply

# let the node promote a new config on its own when a transport looks impaired:
fungi deploy --auto-rotate ...

# serve only — no detection plane and no loop at all (a plain, hand-driven node):
fungi deploy --no-arm ...
```

**Keep ≥2 independent transport families.** The node refuses to serve a subscription that spans only one
family (a single block would strand the client — RP-0013), so if you drop AmneziaWG (`--no-amneziawg`)
enable a second non-REALITY family (e.g. `vless-ws-tls`) too. A CDN front is **complementary** — it adds
reachability where IP/SNI is blocked; the in-region two-hop stays primary (ADR-0033).

## Notes

- **Two descriptors, not one:** `fungi transport` / `fungi reachable` record intent in
  `node.config.json`; `fungi front` writes the separate `front.config.json`. Both live in the node
  state dir and both are read by the deploy path.

- **Covered architectures:** amd64 and arm64 resolve pins from the manifest automatically. On other
  architectures (e.g. armv7) pass `--singbox-version` / `--singbox-sha256` (and `--xray-*` if an
  Xray-engine transport is enabled) explicitly.
- **The descriptor is optional:** a fresh node uses the default-on transport set; `node.config.json`
  only records changes you make with `fungi transport` / `reachable` / `front` (or `myceliumctl` directly).
- **One node form:** engine, reachability, and front are capabilities of a single node, default-off
  ([ADR-0034](docs/adr/0034-unified-node-profile.md)); there is no node "type".

See [docs/runbooks/](docs/runbooks/) for the full operator runbooks and [docs/RELEASING.md](docs/RELEASING.md)
for cutting + verifying a release.
