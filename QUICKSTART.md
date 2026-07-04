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
# download the tagged artifact + checksums + signature (or `gh release download vX.Y.Z`)
ver=vX.Y.Z
base="https://github.com/mycelium0/mycelium/releases/download/$ver"
curl -fsSLO "$base/mycelium-${ver#v}.tar.gz"
curl -fsSLO "$base/SHA256SUMS"
curl -fsSLO "$base/SHA256SUMS.sig"

# verify integrity + authenticity, fail-closed (REL-3)
tar -xzf "mycelium-${ver#v}.tar.gz" && cd "mycelium-${ver#v}"
scripts/verify-release.sh .. --allowed-signers /path/to/allowed_signers --signer <signer-id> --tag "$ver"
```

Without `--allowed-signers` the helper checks integrity only and warns that authenticity is
unverified — always supply the key for a real deployment.

## 2. Deploy

```sh
scripts/fungi deploy \
  --clients alice \
  --node-address your.host.example \
  --allowed-signers /path/to/allowed_signers
```

The engine versions + checksums — and the Go toolchain that builds the control-plane spine — are pinned in
`control/engines.manifest.json` and fetched + checksum-verified automatically; you do **not** hand-enter
`--singbox-sha256`, and the node needs **no distro Go**. `fungi deploy` hardens the host, installs the
pinned engine, generates this node's identity locally, renders + validates the config, starts the service,
and then **self-arms single-node adaptivity** (the measure + L7 liveness detection plane and the
auto-rotation loop) so the node comes up self-driving. It is idempotent — re-running converges. Pass
`--no-arm` to converge serve-only (arm later with `--measure-enable` + `--rotate-arm` + `--rotate-enable-loop`,
or a re-deploy).

## 3. Check it is serving

```sh
scripts/fungi status        # service state, public listeners, engine versions (read-only)
scripts/fungi plan          # preview what this node will deploy (read-only)
```

## Later

```sh
scripts/fungi update        # fetch + re-render + validate + apply, with rollback on failure
scripts/fungi apply         # apply node-descriptor changes (transports / reachability) to the node
```

Edit what the node serves with the descriptor verbs before `apply`/`deploy`:

```sh
myceliumctl transport enable vless-ws-tls    # add a transport (writes node.config.json)
myceliumctl reachable off                    # make the node a non-public participant
```

## Notes

- **Covered architectures:** amd64 and arm64 resolve pins from the manifest automatically. On other
  architectures (e.g. armv7) pass `--singbox-version` / `--singbox-sha256` (and `--xray-*` if an
  Xray-engine transport is enabled) explicitly.
- **The descriptor is optional:** a fresh node uses the default-on transport set; `node.config.json`
  only records changes you make with `myceliumctl transport` / `reachable`.
- **One node form:** engine, reachability, and front are capabilities of a single node, default-off
  ([ADR-0034](docs/adr/0034-unified-node-profile.md)); there is no node "type".

See [docs/runbooks/](docs/runbooks/) for the full operator runbooks and [docs/RELEASING.md](docs/RELEASING.md)
for cutting + verifying a release.
