#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# front_deploy_inert.sh — conformance (ADR-0033 P2-3): the operator-CDN-front deploy wiring
# (control/lib/nb_front.sh front_setup) is DEFAULT-OFF and INERT. A node fronts ONLY if the operator
# places a node-local front.config.json with enabled=true; nothing in the deploy path ever creates or
# enables a front on its own (bring-your-own-domain, opt-in — ADR-0033). OFFLINE + INSPECT-ONLY.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS CHECKS
#   1. front_setup returns early (no-op) when the front config file is ABSENT (the default).
#   2. front_setup returns early when the config is present but enabled != true.
#   3. front_setup is READ-ONLY on the front config — it never writes/creates/enables it (no operator
#      consent is ever synthesised by the node).
#   4. The committed example front.config.example.json ships enabled=false.
#   5. No bootstrap auto-path writes a front.config.json (the operator supplies it).
#   6. front_setup is reached only via render_serve_bundle (the serve path), never an auto-arm.
#
# Exit: 0 = default-off + no auto-enable, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'front_deploy_inert: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib"
NBF="$LIB/nb_front.sh"
SB="$LIB/nb_serve_bundle.sh"
EX="$REPO_ROOT/control/front.config.example.json"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== operator CDN-front deploy-wiring default-off / no-auto-enable check (ADR-0033 P2-3) ==\n'
for f in "$NBF" "$SB" "$EX"; do [ -f "$f" ] || { printf 'FAIL: missing %s\n' "$f" >&2; exit 2; }; done

fn="$(awk '/^front_setup\(\)/{f=1} f{print} /^}/{if(f)exit}' "$NBF")"

# 1. absent config => early no-op
printf '%s' "$fn" | grep -qE '\[ -f "\$FRONT_CONFIG" \] \|\| return 0' \
	&& ok "front_setup is a no-op when front.config.json is absent (default-off)" \
	|| badln "front_setup does not early-return when the front config is absent (not default-off)"

# 2. disabled => no-op
printf '%s' "$fn" | grep -qE 'enabled" != "true"|!= "true"' \
	&& ok "front_setup is a no-op when the front config is not enabled=true" \
	|| badln "front_setup does not gate on enabled=true"

# 3. read-only on the config (never writes/creates/enables it)
if printf '%s' "$fn" | grep -qE '>[[:space:]]*"\$FRONT_CONFIG"|install[^|]*"\$FRONT_CONFIG"|tee[^|]*"\$FRONT_CONFIG"|enabled[[:space:]]*=[[:space:]]*true'; then
	badln "front_setup writes/enables the front config (the node must never synthesise operator consent)"
else
	ok "front_setup is READ-ONLY on the front config (only reads .enabled; never writes/enables it)"
fi

# 4. example ships disabled
if command -v jq >/dev/null 2>&1; then
	[ "$(jq -r '.enabled' "$EX" 2>/dev/null)" = "false" ] && ok "front.config.example.json ships enabled=false" || badln "the example front config is not enabled=false"
else
	grep -qE '"enabled"[[:space:]]*:[[:space:]]*false' "$EX" && ok "front.config.example.json ships enabled=false" || badln "the example front config is not enabled=false"
fi

# 5. no bootstrap auto-path writes a front.config.json
if grep -rnE '>[[:space:]]*"?\$?\{?STATE_DIR\}?/front\.config\.json|front\.config\.json"?[[:space:]]*<<|install[^|]*front\.config\.json' "$LIB" "$REPO_ROOT/scripts/node-bootstrap.sh" 2>/dev/null | grep -vE '^\s*#'; then
	badln "a bootstrap path writes a front.config.json (the operator must supply it — bring-your-own-domain)"
else
	ok "no bootstrap path writes a front.config.json (operator-supplied, opt-in)"
fi

# 6. front_setup is invoked only via render_serve_bundle (the serve path), never an auto-arm dispatch.
#    Exclude nb_front.sh (the definition + its doc comments) and strip leading #-comment lines (after the
#    grep `file:line:` prefix) so only real call sites remain.
calls="$(grep -rnE '(^|[^A-Za-z0-9_])front_setup([^A-Za-z0-9_(]|$)' "$LIB"/*.sh "$REPO_ROOT/scripts/node-bootstrap.sh" 2>/dev/null \
	| grep -vE '/nb_front\.sh:' \
	| grep -vE ':[[:space:]]*#' \
	| grep -vE 'front_setup\(\)' \
	| grep -vE 'command -v front_setup' || true)"
bad_calls="$(printf '%s\n' "$calls" | grep -vE 'nb_serve_bundle\.sh' | grep -vE '^\s*$' || true)"
if [ -z "$bad_calls" ]; then
	ok "front_setup is invoked only from render_serve_bundle (no auto-arm path)"
else
	badln "front_setup is invoked outside the serve path: $(printf '%s' "$bad_calls" | tr '\n' '|')"
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the operator CDN-front deploy wiring is default-off, opt-in, and never self-enables.\n'
	exit 0
fi
printf 'FAIL: the front deploy wiring could front without an explicit operator opt-in — see above.\n' >&2
exit 1
