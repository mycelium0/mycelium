<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Contributing to Mycelium

Thank you for your interest in Mycelium — server software for resilient, private connectivity over
unreliable networks. Contributions are welcome under the terms below.

> **Read this first.** In Mycelium, **user and operator safety is functional requirement #1** — not a
> checkbox at the end. Half of what looks like a "useful feature" is an attack surface here. Before writing a line, read **[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md)**
> and **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## The full guide

The complete contributor handbook is **[docs/contributing.md](docs/contributing.md)** — how to scope
work through an RP/ADR, how a unit of change is structured, the required code/tests/docs, how review
works, and which contributions are disqualified on security grounds. The engineering charter is
**[docs/development.md](docs/development.md)**; the audit/refactor policy is
**[docs/refactoring.md](docs/refactoring.md)**.

## Quick start

1. **Scope it.** A behaviour change needs a record first: a Change Proposal (`docs/proposals/`) for
   work, or an ADR (`docs/adr/`) for a decision. Trivial fixes (typos, a single dangling link) do not.
2. **Gates-first, inert-before-behaviour.** New capability lands as a typed schema + a conformance
   gate before any behaviour consumes it; everything is **default-off** and additive.
3. **Run the suite.** `bash tests/run.sh` (the offline conformance gates), `bash control/selftest.sh`,
   and for Go changes `make build vet fmt-check test race`. CI runs these on every pull request.
   **A macOS-only run does not settle anything** — BSD and GNU `grep` disagree, and a macOS run has
   reported a tree clean that Linux reported dirty. Iterate anywhere; conclude on Linux. The full
   protocol, including how to run against a node without breaking its updates, is
   [development.md §7.6](docs/development.md).
4. **Match the surroundings.** Keep the neutral, honest voice (this is software for resilient secure
   connectivity; it makes no anonymity claim and operates no network); English only in the repo.
5. **Open a pull request.** Fill in the template; link the RP/ADR; confirm the gates pass.

## Reporting bugs

Open an issue with the **Bug report** template. **Do not paste raw logs, IP addresses, hostnames,
domains, or keys** into a public issue — attach a sanitized bundle instead (see the template's
privacy notice).

Where a security finding goes depends on its class, and [SECURITY.md §6.1](SECURITY.md#61-not-every-finding-wants-a-window)
is the authority — this file does not restate the rule. In short: node takeover, provenance-gate
bypass, key or secret leak, user identity or traffic linkability, and supply chain go to a **private
[GitHub Security Advisory](https://github.com/mycelium0/mycelium/security/advisories/new)**; a finding
that a *deployed transport shape is detectable or fingerprintable* is asked to be **published
immediately**, and a public issue is the right place for it.

## Licensing & authorship

The code is **GNU AGPL-3.0-or-later** ([LICENSE](LICENSE)). By contributing you agree your
contribution is licensed under the same terms. If you run a modified version as a network service,
the AGPL requires you to offer your users the modified source. The project's **shared identity** (the
name, logo, trust roots, and signing keys) is governed separately — see
[TRADEMARKS.md](TRADEMARKS.md), [ACCEPTABLE-USE.md](ACCEPTABLE-USE.md), and
[GOVERNANCE.md](GOVERNANCE.md). A fork is welcome but must use its own name.
