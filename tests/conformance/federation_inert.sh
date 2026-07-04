#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# federation_inert.sh — conformance: the Phase-3 federation contract (hypha + anastomosis-bridge) is
# genuinely INERT — typed data + pure Validate() only, with NO live transport and NO production caller.
# Author: mindicator & silicon bags quartet.
#
# WHY (ADR-0037, ADR-0026 Decision 5, ADR-0013 phase discipline)
#   The hypha edge-fusion seam (SiblingDescriptor / HyphaInvitation) is BUILT in Phase 3 and the
#   AnastomosisBridge grammar is DECLARED (Phase-4 deferred) — but NOTHING may establish, dial, negotiate,
#   or propagate a bond/bridge before Phase 4-5. This gate fails closed if that inertness is broken:
#     (A) ZERO production callers — the federation types appear ONLY in their own spec files + tests, never
#         in cmd/ or any other internal/ package (a caller = the seam went live);
#     (B) PURITY — the source files import no transport/exec/network package (net, net/http, os/exec, a
#         libp2p/nebula/gossip client, Dial/ListenAndServe) — they are pure data + Validate();
#     (C) MUST NOT ENUMERATE — the types carry no neighbour-list / topology-map field (ADR-0029 Decision 5:
#         a fungi MAY introduce, MUST NOT enumerate).
#
# Exit: 0 = inert, 1 = a violation, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

HYPHA="internal/spec/hypha.go"
BRIDGE="internal/spec/anastomosis_bridge.go"
TESTF="internal/spec/hypha_test.go"

for f in "$HYPHA" "$BRIDGE" "$TESTF"; do
	[ -f "$f" ] || { printf 'FAIL: federation source %s not found\n' "$f" >&2; exit 2; }
done

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== federation inertness (hypha built + bridge declared; both inert) ==\n'

# (A) Zero production callers: the federation types may appear ONLY in their own spec files + the test.
TYPES='SiblingDescriptor|HyphaInvitation|AnastomosisBridge|IdentityHandle|TrafficCapabilityClass|CapabilityPolicy|IdentityKind'
callers="$(grep -rlnE "$TYPES" --include='*.go' cmd internal 2>/dev/null \
	| grep -vE "^(${HYPHA}|${BRIDGE}|${TESTF})$" || true)"
if [ -z "$callers" ]; then
	okln "zero production callers — the federation types live only in their spec files + test"
else
	badln "the federation types are referenced OUTSIDE their inert spec files (the seam went live):"
	printf '%s\n' "$callers" | sed 's/^/          /' >&2
fi

# (B) Purity: the two SOURCE files import no transport/exec/network machinery.
if grep -nE '"(net|net/http|net/url|os/exec)"|go-libp2p|slackhq/nebula|gossipsub|\bDial\b|ListenAndServe|exec\.Command' "$HYPHA" "$BRIDGE" >/dev/null 2>&1; then
	badln "a federation source imports/uses transport/exec machinery (not inert):"
	grep -nE '"(net|net/http|net/url|os/exec)"|go-libp2p|slackhq/nebula|gossipsub|\bDial\b|ListenAndServe|exec\.Command' "$HYPHA" "$BRIDGE" | sed 's/^/          /' >&2
else
	okln "pure — no net/exec/transport import in the federation sources (data + Validate only)"
fi

# (C) MUST NOT enumerate: no neighbour-list / topology-map field on the federation types.
if grep -nE 'Neighbou?rs|PeerList|NeighborList|TopologyMap|\[\]IdentityHandle' "$HYPHA" "$BRIDGE" >/dev/null 2>&1; then
	badln "a federation type carries a neighbour-list / topology-map field (ADR-0029: MUST NOT enumerate):"
	grep -nE 'Neighbou?rs|PeerList|NeighborList|TopologyMap|\[\]IdentityHandle' "$HYPHA" "$BRIDGE" | sed 's/^/          /' >&2
else
	okln "no neighbour-list / topology-map field — a fungi MAY introduce, MUST NOT enumerate"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the Phase-3 federation seam is not inert (a caller, a transport import, or an enumeration\n' >&2
	printf '      field). Live federation is Phase 4-5 (ADR-0026 Decision 5 / ADR-0037) — keep it callerless.\n' >&2
	exit 1
fi
printf 'PASS: hypha built + bridge declared, both inert — zero callers, pure, no enumeration.\n'
exit 0
