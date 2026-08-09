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
- **Not the maintainer's signing key** — you cannot obtain it, because it is not published yet. This
  line used to list it as a requirement, which made the prerequisites unsatisfiable: a reader working
  top-down could not get past item 2, and the explanation was 60 lines further down. Until the key ships
  there is no authenticity check available to anyone, and step 1b below is the path that works today. The
  gap is stated in full at step 1 and tracked in [SECURITY.md §8](SECURITY.md#8-open-questions-tbd).

## Before you run this

**No release is tagged yet.** Step 1 below describes the release path and will 404 today; until a tag
exists, install from a clone — see *1b* immediately after it. Everything from step 2 onward is the same
either way.

**What `deploy` changes on your host, before you point it at one** (all default-on; `--no-harden`
disables the host-hardening group):

| It does this | Where |
|---|---|
| **Deletes `/var/log/journal`** and makes journald RAM-only (`Storage=volatile`, 64 MB) | `control/lib/nb_harden.sh` |
| **Rewrites sshd config** — password and keyboard-interactive auth off, root key-only. Refuses if it finds no authorized key (anti-lockout) | same |
| **Enables ufw** with a default-deny policy and opens only the ports it serves plus live sshd | same |
| Installs systemd units, downloads and compiles engines **on the box** | `nb_install.sh`, `nb_render_awg.sh` |

Use a host you are willing to hand over to this. It is not designed to share a machine with your other
services.

**Requirements the package cannot give you:** a Debian-family host with `apt` and systemd; outbound
HTTPS to `github.com` and `go.dev`; enough CPU and RAM to compile Go on the box; and a public IP — on a
NAT'd host, address auto-detection **refuses** the private address and you must pass `--node-address`
yourself.

**Read first:** [THREAT-MODEL](docs/THREAT-MODEL.md) — what this does and does not protect, and the
legal exposure an exit node carries. [ACCEPTABLE-USE](ACCEPTABLE-USE.md) — what you agree not to do.

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

## 1b. …or install from a clone (what to do TODAY)

```sh
sudo git clone --depth 1 https://github.com/mycelium0/mycelium.git /opt/mycelium
cd /opt/mycelium
```

There is no authenticity check on this path — you are trusting the transport and GitHub, exactly as with
any `git clone`. That is strictly weaker than the verified path above, and it is the honest state of
things until a signed release is published.

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

## 4. Connect a client

`deploy --clients alice` mints alice's material **on the node**; nothing is sent anywhere and nothing is
served publicly. Retrieve it over your existing SSH session:

```sh
# AmneziaWG — a ready-to-import wg/awg config
sudo cat /var/lib/mycelium/awg/clients/alice.conf

# sing-box / Clash-Meta — generated on demand from the node's own params + identities
sudo /opt/mycelium/control/myceliumctl subscription --engine singbox \
     --params /var/lib/mycelium/params.json \
     --state  /var/lib/mycelium/identities.json \
     --out    /tmp/sub
sudo cat /tmp/sub/*.singbox.json     # sing-box
sudo cat /tmp/sub/*.clash.yaml       # Clash-Meta
```

The served bundle vhost binds **loopback only** by default, so there is no URL to hand a phone: copy the
file out yourself, or front it with your own HTTPS (see the caddy role). That is deliberate — an
always-on public subscription endpoint is a single point of block and a discovery surface.

### Read the `AllowedIPs` line before you decide the client works

The AmneziaWG config you just printed carries, by default:

```
AllowedIPs = 10.13.13.0/24
```

**That is the tunnel subnet, not your traffic.** With that line the handshake completes, the peer stays
up on `PersistentKeepalive`, `wg show` looks perfect — and your default route is untouched, so nothing
you do goes through the node. Every status surface, on the node and on the client, reports success.

This is deliberate, not a bug: the node **never silently full-tunnels** you. Choosing what a client sends
through a node is a decision the operator makes explicitly, and there is no default that is right for
everyone. But it does mean a fresh `deploy` gives you a client that connects and carries nothing, and you
have to pick one of these:

| you want | pass to `deploy` | what the client gets |
|---|---|---|
| everything through the node | `--full-tunnel` | `AllowedIPs = 0.0.0.0/0` — plus `::/0` on a dual-stack node |
| only certain destinations | `--region-exclude <file>` | one `AllowedIPs` entry per CIDR in the file (plus `::/0` if the file is IPv4-only, so v6 cannot leak around the split) |
| the default | neither | tunnel ranges only — connects, routes nothing |

```sh
# everything through the node
sudo /opt/mycelium/scripts/fungi deploy --clients alice --full-tunnel

# or: only the CIDRs you list, one per line
printf '%s\n' 198.51.100.0/24 203.0.113.0/24 | sudo tee /etc/mycelium/region-exclude.txt
sudo /opt/mycelium/scripts/fungi deploy --clients alice --region-exclude /etc/mycelium/region-exclude.txt
```

Re-running `deploy` re-renders alice's config in place; re-import it on the client afterwards.

The sing-box and Clash-Meta subscriptions above are unaffected by this — they carry their own routing
rules and are full-tunnel by default. The asymmetry is real and worth knowing: the same node can hand you
one client that routes everything and another that routes nothing.

**Then actually dial it**, from a different machine, before you trust the node. `deploy` reporting
success means the node is serving locally; it does not mean your provider's security group, or the
network you are on, lets a client reach it. Nothing on the node can observe that — the liveness probes
are loopback by design — so your own client is the only thing that can tell you.

## Later

```sh
sudo /opt/mycelium/scripts/fungi apply    # apply node-descriptor changes (transports / reachability)
```

### Updating a node

**The documented signed-update path is not runnable yet** (Audit-0011 #10): it requires the maintainer's
`allowed_signers`, which is not published, and `verify_signed_ref` refuses to apply anything it cannot
authenticate. Until the key exists, the supported interim is to re-run the install: fetch the newer tree
the same way you first obtained it, then `fungi deploy` again. An unarmed node never updates itself, and
that is the current state for everyone.

**A tarball install is not a git checkout, and `fungi update` is a git fetch.** Run it against the tree
you extracted above and it will refuse — correctly — because there is nothing to fetch into. Two supported
ways forward; pick one deliberately, because only the second can ever run unattended.

**The verification chain is NOT end to end, and saying otherwise would be false** (Audit-0011 #17).
The tarball you check covers this repository. AmneziaWG is then built on the node from `git clone`
of upstream **mutable tags**, and the engines are fetched by pinned SHA256 — good, but a different
trust root from the one you just verified. Treat the release check as covering Mycelium's own code.

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
