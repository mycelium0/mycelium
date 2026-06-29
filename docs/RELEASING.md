<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Releasing Mycelium

Mycelium ships **software releases, not an operated network** ([ADR-0016](adr/0016-software-releases-not-an-operated-network.md)): a release is a tagged, signed, reproducible source artifact an operator fetches and deploys on their own infrastructure. There is no central service, no telemetry, no "uptime."

A release is three things, in this order:

1. a **signed git tag** `vX.Y.Z` — the authenticity root (SSH-signature, the same scheme the node updater verifies, [ADR-0015](adr/0015-network-artifact-delivery-and-node-update.md));
2. a **deterministic source tarball** `mycelium-X.Y.Z.tar.gz` (= the AGPL Corresponding Source) + `SHA256SUMS`, built by `make dist`;
3. a **GitHub Release** at that tag carrying the tarball, `SHA256SUMS`, and a detached **`SHA256SUMS.sig`** signed with the maintainer's key.

The signing key is the maintainer's **SSH key** — the same key whose public half operators carry out-of-band in their `--allowed-signers` file (ADR-0015). **CI holds no signing secret**: the tag and the checksum signature are produced locally by the maintainer; CI only builds and publishes.

## One-time signing setup (maintainer)

```sh
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519.pub   # the key in operators' allowed_signers
git config tag.gpgsign true
```

## Cut a release

```sh
# 1. bump the single source of truth + record the change
$EDITOR internal/spec/version.go          # const Version = "X.Y.Z"
$EDITOR CHANGELOG.md                       # add "## [X.Y.Z] — <date>"
git add -A && git commit && git push origin main
#    → wait for green CI (build/vet/test/race + all gates, incl. release_dist_sane)

# 2. sanity-build the artifact locally and run its gate
make dist                                  # → dist/mycelium-X.Y.Z.tar.gz + dist/SHA256SUMS
MYC_REPO_ROOT="$PWD" bash tests/conformance/release_dist_sane.sh

# 3. sign + push the tag → triggers .github/workflows/release.yml (REL-2)
git tag -s vX.Y.Z -m "Mycelium vX.Y.Z"
git push origin vX.Y.Z

# 4. sign the checksums with the same key and attach the .sig to the published Release
ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n file dist/SHA256SUMS    # → dist/SHA256SUMS.sig
gh release upload vX.Y.Z dist/SHA256SUMS.sig
```

`make dist` is reproducible: re-running it at the same tag yields a byte-identical tarball (pinned by `release_dist_sane`). So any third party can rebuild and confirm the published artifact independently.

## Verify a release (operator / downloader)

```sh
# authenticity of the source (the tag is the root of trust)
git verify-tag vX.Y.Z                              # against your allowed_signers

# integrity of the downloaded tarball
sha256sum -c SHA256SUMS                             # (macOS: shasum -a 256 -c SHA256SUMS)

# authenticity of the checksums (detached SSH signature)
ssh-keygen -Y verify -f allowed_signers -I <signer-id> -n file \
  -s SHA256SUMS.sig < SHA256SUMS
```

On a node, `node-bootstrap.sh --allowed-signers <file>` performs the tag/commit signature check automatically (`verify_signed_ref`, fail-closed) before applying a fetched ref — so the same key that signs the release also gates every node update.

## Notes

- **Version scheme:** `0.<phase>.<patch>` during the alpha; `1.0.0` is reserved for the first stable public release. The MINOR digit tracks the lifecycle phase.
- **What ships:** `make dist` archives every *tracked* file. Per-node identity, secrets, params, and rendered configs are gitignored and never tracked, so they can never enter the artifact (`release_dist_sane` pins this).
- **No CI signing key:** keeping the signing key off CI means a CI compromise cannot forge a release; the trade-off is the two manual signing steps above.
