<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

## What & why

<!-- One or two sentences: what this changes and why. Link the RP/ADR that scopes it. -->

- Record: <!-- RP-00NN / ADR-00NN, or "trivial fix — no record" -->

## Checklist

- [ ] Scoped by an RP/ADR (or a trivial fix that needs none).
- [ ] Gates-first / inert-before-behaviour: new capability is a typed schema + a conformance gate, **default-off**, additive.
- [ ] `bash tests/run.sh` passes; for Go changes, `make build vet fmt-check test race` passes.
- [ ] No node IP / hostname / domain / country / secret / personal contact in the diff or commit messages.
- [ ] Neutral, honest voice; English only; no anonymity or "operates a network" claim.
- [ ] Docs/changelog updated if behaviour or canon changed.

## Notes for the reviewer

<!-- Anything surprising, any deliberate trade-off, anything you want a close look at. -->
