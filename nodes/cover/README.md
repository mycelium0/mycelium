<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Cover site

> Author: mindicator & silicon bags quartet · Phase 0 · component `cover`

A tiny, neutral static web site served by [Caddy](https://caddyserver.com/). Its only job is to
make a Phase 0 node look like an ordinary personal web server to anyone who points a browser (or a
probe) directly at its IP or domain. There is nothing project-specific on the page: it is a plain
landing page with a placeholder name and a couple of paragraphs.

## What this is for

A Phase 0 node terminates VLESS + XTLS-Vision + REALITY (the data plane). REALITY borrows the TLS
handshake of a **real, external donor site**, so a passive observer sees what looks like ordinary
HTTPS to a reputable host. The donor is *not* this machine.

The cover site answers a different question: **what does a direct, casual visitor to the node's own
address see?** Without an answer, a direct hit (a browser, a scanner, an active probe that connects
without a valid handshake) would receive a bare connection reset or an obviously empty service —
which is itself a tell. The cover site removes that tell by returning a benign, plausible web page.

In short:

- **REALITY handshake target** = external donor site (configured in the data plane, not here).
- **Fallback / origin for direct hits** = this cover site.

## How it composes with the data plane (Xray / REALITY)

In production the data-plane listener owns `:443` on the node, because that is where the REALITY
handshake must land. The cover site therefore does **not** bind `:443`. It composes in one of two
shapes; the `Caddyfile` in this directory ships both, with shape A active and shape B commented.

### Shape A — origin behind the data plane (recommended for production)

```
                       :443 (TCP/TLS)
   visitor / probe  ────────────────▶  data-plane listener (Xray, REALITY)
                                          │
            valid REALITY handshake  ─────┤───────────────▶  tunnel (carried traffic)
                                          │
       no/invalid handshake (fallback) ───┘──▶  127.0.0.1:8080  ──▶  Caddy → ./site
```

- The data-plane listener inspects the incoming connection. A valid REALITY handshake is carried as
  tunnel traffic. Anything else — a plain browser, a scanner, an active probe without the right
  keys — is treated as **fallback** and forwarded to the cover origin on loopback.
- Caddy listens only on `127.0.0.1:8080`, serves `./site`, and never terminates public TLS. The TLS
  the visitor sees is the data plane's REALITY/donor TLS, so the page is delivered inside a
  handshake that already looks legitimate.
- In Xray terms this is the inbound `realitySettings` + a `fallbacks` entry pointing at
  `127.0.0.1:8080`. The exact data-plane wiring lives in
  [`../dataplane/vless-reality/`](../dataplane/vless-reality/); this directory only provides the
  origin it falls back to.

### Shape B — standalone demo / staging host

On a box that is **not** running the data plane (a staging or demo host where you just want to see
the page), uncomment the `www.example.com` block in the `Caddyfile`. There Caddy owns `:80`/`:443`
and manages its own certificate via ACME. **Never** enable shape B on a box that also runs the data
plane — the data plane owns `:443` there and the two would collide.

## Files

| File | Purpose |
|---|---|
| `Caddyfile` | Caddy configuration. Shape A (loopback origin) active; shape B (standalone) commented. |
| `site/index.html` | The benign static landing page. No project identifiers, no network wording. |
| `README.md` | This document. |

> **No secrets here.** The `Caddyfile` uses sentinel placeholders (`admin@example.com`,
> `www.example.com`). Real addresses, hostnames, and the chosen donor are supplied at deploy time
> and land in gitignored override paths (`*.local`, `secrets/`, `state/`) — never committed.

## Running it

Caddy is a single binary. Pin a recent stable release at deploy time (for Phase 0, Caddy
**v2.10.2** or newer).

Validate the config without serving:

```sh
caddy validate --config ./Caddyfile
```

Run the origin (shape A) from this directory:

```sh
caddy run --config ./Caddyfile
```

Then check the origin directly over loopback:

```sh
curl -s http://127.0.0.1:8080/ | head
```

Or format the config in place (does not change behaviour):

```sh
caddy fmt --overwrite ./Caddyfile
```

## How to customise

The whole point is that the page should look like *someone's* ordinary site — so changing it to
suit the deploy is encouraged, as long as it stays benign and reveals nothing about the project.

1. **Edit `site/index.html`.** Replace the placeholder name (`Jordan Avery`), the tagline, and the
   paragraphs with any plausible, neutral personal content. Keep it consistent with the donor you
   chose (a small personal homepage is a low-suspicion shape). Add more static files under `site/`
   if you want a slightly richer page — keep everything self-contained and static.
2. **Avoid tells.** No project names, no network/PPN terminology, no admin panels, no login forms,
   no API endpoints, no directory listings. Just static HTML/CSS/images.
3. **Pick the deployment shape.** Leave shape A active for a real node; uncomment shape B only on a
   standalone host that does not run the data plane.
4. **Set real values at deploy time.** The operator email and (shape B) hostname are placeholders;
   supply real ones via a gitignored override so they never enter the repo.
5. **Keep responses quiet.** The config strips the `Server` header so responses do not name the web
   server software. Leave that in place.

## Acceptance check (Phase 0)

This component supports the proposal's acceptance criterion that *active probing of the server
returns the genuine donor site / a benign page rather than a tell-tale response*
(see [`../../docs/proposals/0001-bootstrap-phase-0-node.md`](../../docs/proposals/0001-bootstrap-phase-0-node.md)
§7). The data plane's fallback to this origin is what makes a direct, handshake-less hit look
ordinary.
