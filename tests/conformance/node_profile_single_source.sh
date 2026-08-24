#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_profile_single_source.sh — conformance (ADR-0034 / RP-0011 chunk B): the unified node profile is
# ONE node-local descriptor of CAPABILITIES, never a node-TYPE enum and never a second divergent profile.
# Pins: (1) exactly one internal/spec.NodeProfile schema, with no type/kind/variant selector field;
# (2) the schema reads the Go-owned registry for the proto->enable-key mapping, never restating the
# "<proto>_enabled" naming rule in Go; (3) the committed example ships every posture DEFAULT-OFF / inert
# (reachable / front / loops / weather all off, no "type" key); (4) the example uses the closed vocab
# (transports subset registry; a front transport is frontable-only); (5) NO bootstrap path writes a
# node.config.json — it is operator-supplied, like front.config.json (the schema is inert: nothing
# consumes it yet). OFFLINE + INSPECT-ONLY.
#
# Exit: 0 = single-source + inert + default-off, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'node_profile_single_source: cannot resolve repo root\n' >&2; exit 2; }
SCHEMA="$REPO_ROOT/internal/spec/nodeprofile.go"
EX="$REPO_ROOT/control/node.config.example.json"
VOCAB="$REPO_ROOT/control/vocab.json"
LIB="$REPO_ROOT/control/lib"
BOOT="$REPO_ROOT/scripts/node-bootstrap.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== unified node profile: single-source, capabilities-not-types, default-off (ADR-0034) ==\n'
for f in "$SCHEMA" "$EX" "$VOCAB"; do [ -f "$f" ] || { printf 'node_profile_single_source: missing %s\n' "$f" >&2; exit 2; }; done
command -v jq >/dev/null 2>&1 || { printf 'node_profile_single_source: jq required\n' >&2; exit 2; }

# 1a. exactly ONE NodeProfile schema across internal/ (no second divergent profile).
nprof="$(grep -rlE '^type NodeProfile struct' "$REPO_ROOT/internal" 2>/dev/null | wc -l | tr -d ' ')"
[ "$nprof" = "1" ] && ok "exactly one internal/spec.NodeProfile schema" \
	|| badln "expected exactly 1 'type NodeProfile struct' in internal/, found $nprof"

# 1b. no node-TYPE / kind / variant selector field in the NodeProfile struct (capabilities, not types).
body="$(awk '/^type NodeProfile struct/{f=1} f{print} /^}/{if(f)exit}' "$SCHEMA")"
if printf '%s' "$body" | grep -qE '^[[:space:]]+(Type|Kind|Variant|NodeType|Role)[[:space:]]'; then
	badln "NodeProfile has a type/kind/variant selector field (forbidden — capabilities, not types)"
else
	ok "NodeProfile has no node-TYPE/kind/variant selector field"
fi

# 2. the schema does NOT restate the proto->enable-key naming rule IN CODE (it reads the registry's
#    EnableKey). Strip full-line comments, then look for a '<proto>_enabled' string LITERAL — the only
#    way Go code restates the rule (a doc comment that merely mentions the rule is not a violation).
schema_code="$(grep -vE '^[[:space:]]*//' "$SCHEMA")"
if printf '%s' "$schema_code" | grep -qE '"[A-Za-z0-9_]*_enabled"'; then
	badln "nodeprofile.go restates an enable-key naming rule in code (a '<proto>_enabled' literal — must read the registry's EnableKey, vocab single source)"
else
	ok "nodeprofile.go reads the registry for enable keys (no restated enable-key literal in code)"
fi

# 3. the example ships every posture DEFAULT-OFF / inert, and carries no node-TYPE key.
chk() { jq -e "$1" "$EX" >/dev/null 2>&1 && ok "example: $2" || badln "example: $2 — violated"; }
chk '.reachable == false'                                              'reachable default-off'
chk '.front.enabled == false'                                         'front default-off'
chk '(.loops.update == false) and (.loops.rotate == false) and (.loops.measure == false)' 'all loops default-off'
chk '.weather.enabled == false'                                       'weather reserved/inert (off)'
chk '(has("type") or has("kind") or has("variant")) | not'            'no type/kind/variant key (capabilities, not types)'

# 4. the example uses the CLOSED vocab: transports subset of the registry; a front transport is frontable.
bad_t="$(jq -r '(.transports // [])[]' "$EX" 2>/dev/null | while read -r t; do
	jq -e --arg t "$t" 'any(.protos[]; .proto == $t)' "$VOCAB" >/dev/null 2>&1 || printf '%s ' "$t"
done)"
[ -z "$bad_t" ] && ok "example transports are all known registry protos" \
	|| badln "example transports not in the registry: $bad_t"
ft="$(jq -r '.front.transport // empty' "$EX" 2>/dev/null)"
if [ -n "$ft" ]; then
	case "$ft" in
		vless-xhttp-tls|vless-ws-tls) ok "example front.transport ($ft) is CDN-frontable" ;;
		*) badln "example front.transport ($ft) is not frontable (only vless-xhttp-tls / vless-ws-tls)" ;;
	esac
fi

# 5. NO bootstrap path writes a node.config.json (operator-supplied; the schema is inert — nothing
#    consumes it yet). Strip leading #-comments after the grep file:line: prefix.
writers="$(grep -rnE '>[[:space:]]*"?[^"]*node\.config\.json|install[^|]*node\.config\.json|tee[^|]*node\.config\.json|node\.config\.json"?[[:space:]]*<<|(^|[^a-z])(mv|cp|ln)[[:space:]][^|;&]*node\.config\.json' \
	"$LIB" "$BOOT" 2>/dev/null | grep -vE ':[[:space:]]*#' || true)"
if [ -n "$writers" ]; then
	badln "a bootstrap path writes a node.config.json (it must be operator-supplied): $(printf '%s' "$writers" | tr '\n' '|')"
else
	ok "no bootstrap path writes a node.config.json (operator-supplied, inert)"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the node profile is one node-local descriptor of default-off capabilities, inert.\n'
	exit 0
fi
printf 'FAIL: the unified node profile drifted from single-source / capabilities-not-types / inert — see above.\n' >&2
exit 1
