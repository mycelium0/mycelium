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
git config user.signingkey ~/.ssh/id_rsa.pub       # the key in operators' allowed_signers
git config tag.gpgsign true
```

This said `id_ed25519` and the key in use is **RSA** — following it verbatim configured signing against
a file that does not exist. Check what you actually sign with before trusting either line:
`git log -1 --show-signature` names the algorithm and fingerprint.

> **PUBLISH THE PUBLIC HALF — nothing downstream works without it.** The signer identity is already
> public — `git log -1 --format=%GS` prints it on any signed commit — but the KEY is not: it is in no
> file in this repository,
> and GitHub reports the commit signatures as `unknown_key` because it is not registered on the account.
> So no downloader can run the authenticity check at all, and `verify-release.sh` degrades to
> integrity-only — the one mode that cannot tell a substituted release from a genuine one. Two places,
> both cheap:
>
> ```sh
> # 1. in the repository, so every downloader has it after the first fetch.
> #    The principal is a LITERAL — your own identifier, whatever you register on the account. It is
> #    NOT `git log -1 --format=%GS`, which this line used to use: %GS prints a principal only once an
> #    allowed_signers already exists containing that key, so the command written to CREATE the file
> #    required the file. Reproduced from an empty repository with a real SSH-signed commit
> #    (Audit-0012 B4): %GS was empty, the line came out as " ssh-ed25519 AAAA…" with a leading space
> #    and no principal, `awk 'NF{print $1; exit}'` then yielded `ssh-ed25519` — the key TYPE — and the
> #    commit verified as `U`, not `G`.
> printf '%s %s\n' "you@example.org" "$(cut -d' ' -f1,2 ~/.ssh/id_rsa.pub)" > allowed_signers
>
> # sanity: the file must parse, and the tip commit must verify against it
> git -c gpg.ssh.allowedSignersFile=allowed_signers log -1 --format=%G?   # expect: G
> ssh-keygen -Y find-principals -f allowed_signers -s <(git cat-file commit HEAD | sed -n '/^gpgsig/,/END SSH SIGNATURE/p') 2>/dev/null || true
>
> # 2. on the GitHub account as a SIGNING key (Settings -> SSH and GPG keys -> New SSH key ->
> #    key type "Signing Key"), which makes commits show Verified and gives a second, independent
> #    channel — a key committed only to the repository it authenticates is circular for a first-time
> #    downloader.
> ```

## Cut a release

**The signed bytes must be the published bytes.** The old order in this file did not guarantee that
(Audit-0011 #15): step 2 built `dist/SHA256SUMS` locally from `HEAD`, *before the tag existed*, step 4
signed that local copy, and the workflow published CI's own independently built copy. Nothing compared
them. Any commit landing between the local build and the tag made the signed file describe a different
tarball from the published one — and then `scripts/verify-release.sh` fails closed for **every**
downloader while the maintainer, who never re-checks, sees a normal release. The order below builds at
the tag and then signs the file that was *actually published*, so the two cannot diverge.

```sh
# 0. ADVISORY — check engine currency BEFORE tagging. Maintenance currency is load-bearing for
#    indistinguishability (docs/adr, dependency_policy.sh header), but "is the pin the latest upstream
#    tag" is deploy-time state, not a CI invariant, so no gate can answer it offline. Tag time is the
#    one moment it is both answerable and actionable. Compare each pin against upstream; if an engine is
#    behind, decide DELIBERATELY whether to bump it in this release or record why not.
gh release view --repo SagerNet/sing-box --json tagName -q .tagName
gh release view --repo XTLS/Xray-core   --json tagName -q .tagName
jq -r '.engines | to_entries[] | "\(.key)\t\(.value.version)"' control/engines.manifest.json

# 1. bump the single source of truth + record the change
$EDITOR internal/spec/version.go          # const Version = "X.Y.Z"
$EDITOR CHANGELOG.md                       # add "## [X.Y.Z] — <date>"
git add -A && git commit && git push origin main
#    → wait for green CI (build/vet/test/race + all gates, incl. release_dist_sane)

# 2. sign + push the tag → triggers .github/workflows/release.yml (REL-2)
#    The workflow now refuses to publish unless `git verify-tag` passes against the committed
#    allowed_signers, so an unsigned `git tag` can no longer produce a normal-looking release.
git tag -s vX.Y.Z -m "Mycelium vX.Y.Z"
git push origin vX.Y.Z

# 3. sanity-build AT THE TAG and run its gate. Not from HEAD — HEAD may already have moved.
git checkout --detach vX.Y.Z
make dist DIST_REF=vX.Y.Z                  # → dist/mycelium-X.Y.Z.tar.gz + dist/SHA256SUMS
MYC_REPO_ROOT="$PWD" bash tests/conformance/release_dist_sane.sh

# Steps 4-7 leave the repository, so they pin REPO and use absolute paths throughout, and every `gh`
# call carries --repo. Measured (Audit-0012 B3): without it, `gh release download` from /tmp/rel fails
# with "failed to run git: fatal: not a git repository" and never reaches GitHub — and these are exactly
# the three steps that exist to prove the signed bytes are the published bytes.
REPO=mycelium0/mycelium
REPO_DIR="$PWD"          # you are still in the checkout, detached at the tag, from step 3

# 4. wait for the workflow, then DOWNLOAD what it actually published
mkdir -p /tmp/rel
gh release download vX.Y.Z --repo "$REPO" --dir /tmp/rel \
  --pattern 'mycelium-*.tar.gz' --pattern 'SHA256SUMS' --clobber

# 5. assert byte equality against the local build. If this differs, DO NOT SIGN — something landed
#    between the tag and the build, or the workflow built a different ref. Investigate, do not paper over.
cmp /tmp/rel/SHA256SUMS "$REPO_DIR/dist/SHA256SUMS" \
  || { echo "published SHA256SUMS != locally built at the tag — STOP"; exit 1; }

# 6. sign the DOWNLOADED copy — the bytes the world will verify — and attach the signature
ssh-keygen -Y sign -f ~/.ssh/id_rsa -n file /tmp/rel/SHA256SUMS      # → SHA256SUMS.sig
gh release upload vX.Y.Z --repo "$REPO" /tmp/rel/SHA256SUMS.sig

# 7. re-verify in SIGNED mode, from the download directory, as a stranger would.
#    --allowed-signers is ABSOLUTE and points at the CLONE, not at /tmp/rel. Two reasons, and the second
#    is the one that matters: verify-release.sh cd's into the directory it checks, so a relative path
#    resolves against /tmp/rel (Audit-0012 B5) — and a key that lives inside the artifact is no key at
#    all, since whoever built the artifact chose it (Audit-0015). The tool now refuses that shape.
scripts/verify-release.sh /tmp/rel \
  --allowed-signers "$REPO_DIR/allowed_signers" \
  --signer "$(awk 'NF{print $1; exit}' "$REPO_DIR/allowed_signers")" --tag vX.Y.Z
```

`make dist` is reproducible using git's internal zlib: re-running it at the same tag yields a
byte-identical tarball, confirmed on macOS and Linux and pinned by `release_dist_sane`. That is
independence from the host's `gzip` and from a `tar.tar.gz.command` set in the operator's git config —
it is **not** a claim of bit-identical output across every platform and git version.

## A bad release

There is no downgrade verb and no code rollback (Audit-0011 #21). `rollback_config` restores the last
known-good *config*; the revision and the spine have already advanced by then
(`scripts/node-bootstrap.sh`), so "roll back" does not undo an update. Plan accordingly:

1. **Stop the spread first.** The nodes only take signed tips of `origin/main`. Revert the offending
   commit on `main` and push the revert, signed, the normal way (`git revert`, then
   `git merge --no-ff -S` if it went through a branch). Armed nodes converge onto the revert on their
   next tick; that is the fastest lever available and it needs no node access.
2. **Delete the release, keep the tag.** `gh release delete vX.Y.Z --repo mycelium0/mycelium` removes the assets that
   `QUICKSTART.md` resolves to. Leave the tag in place — deleting a pushed tag rewrites what other
   people already fetched, and a tag that resolves to nothing is worse than one that resolves to a
   known-bad commit you have documented. Add a `## [X.Y.Z] — YANKED` line to CHANGELOG.md saying why.
3. **Per node, if a node already took it.** Each node records the revision it was on before the fetch
   in `$STATE_DIR/update.prev_rev`; that value is what to return to:

   ```sh
   git -C /opt/mycelium checkout --detach "$(cat /var/lib/mycelium/update.prev_rev)"
   fungi apply          # re-render + validate + promote from the older tree
   ```

   Disarm first if the timer would just pull the bad tip back: `sudo rm -f /var/lib/mycelium/update.armed`.
4. **Then fix forward.** A node pinned to a detached revision is not receiving updates. Land the real
   fix, cut the next tag, re-arm, and confirm `mycelium_update_last_success_timestamp_seconds` moves.

## Verify a release (operator / downloader)

Use the helper (fail-closed — integrity always, authenticity when you supply the key):

```sh
# from the directory holding mycelium-X.Y.Z.tar.gz + SHA256SUMS + SHA256SUMS.sig.
# The key must come from OUTSIDE that directory: `make dist` is `git archive`, so allowed_signers ships
# inside the tarball, and verifying an archive against a key it carried is the archive attesting to
# itself. verify-release.sh refuses a --allowed-signers that resolves inside the directory it checks.
KEY=~/mycelium-allowed_signers   # fetched independently of this download
scripts/verify-release.sh . --allowed-signers "$KEY" --signer "$(awk 'NF{print $1; exit}' "$KEY")" [--tag vX.Y.Z]
```

It runs, fail-closed, the underlying checks:

```sh
sha256sum -c SHA256SUMS                             # integrity (macOS: shasum -a 256 -c)
ssh-keygen -Y verify -f allowed_signers -I "$(awk 'NF{print $1; exit}' allowed_signers)" -n file -s SHA256SUMS.sig < SHA256SUMS
git verify-tag vX.Y.Z                               # authenticity of the source (tag = root of trust)
```

Without `--allowed-signers` the helper checks **integrity only** and warns that authenticity is
unverified — supply the maintainer's published signing key (an `allowed_signers` line) to verify the
signature.

On a node, `node-bootstrap.sh --allowed-signers <file>` performs the tag/commit signature check automatically (`verify_signed_ref`, fail-closed) before applying a fetched ref — so the same key that signs the release also gates every node update.

## Notes

- **Version scheme:** `0.<phase>.<patch>` during the alpha; `1.0.0` is reserved for the first stable public release. The MINOR digit tracks the lifecycle phase.
- **What ships:** `make dist` archives every *tracked* file. Per-node identity, secrets, params, and rendered configs are gitignored and never tracked, so they can never enter the artifact (`release_dist_sane` pins this).
- **No CI signing key:** keeping the signing key off CI means a CI compromise cannot forge a release; the trade-off is the two manual signing steps above.
