#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render_server_template_pinned.sh — conformance: the Go server renderer refuses a template it does not
# encode, instead of silently ignoring it.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   The shell renderer runs jq OVER nodes/dataplane/singbox/server.template.renderer.json, so editing that
#   file changes what a node serves. The Go renderer does NOT read it — reproducing jq's key order in Go
#   required encoding the shape in typed structs — and `--template` was accepted "for CLI parity" and then
#   discarded.
#
#   That was harmless only while the shell was the one that ran. The moment the Go renderer became
#   load-bearing, the discard turned into this tree's most expensive failure shape: an operator edits the
#   template, the node converges at rc=0, and the edit does nothing. No error, no drift report, a data
#   plane that silently is not what the repository says it is.
#
#   So the pin: spec.ShippedServerTemplateSHA256 records the bytes the structs encode, and the verb
#   refuses anything else. Editing the template is a THREE-part change — the file, the structs, the
#   constant — and this gate fails offline the moment they fall out of step.
#
# WHAT IT CHECKS
#   1. The constant equals the sha256 of the shipped template. This is the row that goes red when someone
#      edits the template and does not re-derive the structs — the whole point.
#   2. The verb REFUSES a modified template, DRIVEN, not read from source.
#   3. It still ACCEPTS the shipped one, so row 2 cannot pass by refusing everything.
#   4. The xray engine is still rejected for being unported, ahead of the template check, so an xray
#      caller gets the reason that applies to it.
#
# OFFLINE. No root, no network, no node. SKIP-IF-NO-GO for the driven rows; row 1 always runs.
# Exit: 0 = the template and the structs that encode it are in step; 1 = they are not; 2 = usage/env.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
PIN_SRC="$REPO_ROOT/internal/spec/render_server_template_pin.go"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
for f in "$TEMPLATE" "$PIN_SRC"; do
	[ -f "$f" ] || { printf 'render_server_template_pinned: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the Go server renderer refuses a template it does not encode ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1. THE CONSTANT MATCHES THE SHIPPED TEMPLATE.
# ---------------------------------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then have="$(sha256sum "$TEMPLATE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1;   then have="$(shasum -a 256 "$TEMPLATE" | awk '{print $1}')"
else printf 'FAIL: neither sha256sum nor shasum is available.\n' >&2; exit 2; fi
pinned="$(grep -oE 'ShippedServerTemplateSHA256 = "[0-9a-f]{64}"' "$PIN_SRC" | grep -oE '[0-9a-f]{64}')"
if [ -z "$pinned" ]; then
	badln "spec.ShippedServerTemplateSHA256 is missing or is not a 64-hex constant"
elif [ "$pinned" = "$have" ]; then
	ok "the pin matches the shipped template (${have:0:16}...)"
else
	badln "the pin (${pinned:0:16}...) does not match the shipped template (${have:0:16}...). The template was edited without re-deriving internal/spec/render_server_types.go from it. A node rendering through the Go spine would serve the OLD shape, at rc=0, with nothing to show for your edit."
fi

# ---------------------------------------------------------------------------------------------------
# 2-4. DRIVEN.
# ---------------------------------------------------------------------------------------------------
GO=""
if command -v go >/dev/null 2>&1; then GO="$(command -v go)"; else
	for c in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do [ -x "$c" ] && { GO="$c"; break; }; done
fi
if [ -z "$GO" ]; then
	printf '  SKIP  no Go toolchain; the Go/CI lane drives the refusal\n'
else
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.rstp.XXXXXX")" || exit 2
	trap 'rm -rf "$WORK"' EXIT
	if ! ( cd "$REPO_ROOT" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
			"$GO" build -o "$WORK/spine" ./cmd/myceliumctl ) >/dev/null 2>&1; then
		printf '  SKIP  the Go spine did not build here; CI drives these rows\n'
	else
		jq -n '{ version:1, clients:[ { name:"a", id:"a1b2c3d4-e5f6-7890-abcd-ef0123456789",
			created:"2026-01-01T00:00:00Z", password:"p" } ] }' > "$WORK/id.json"
		jq -n '{ node_address:"n.example.invalid", donor_host:"www.example.invalid",
			donor_sni:"www.example.invalid", reality_private_key:"SK", reality_public_key:"PK",
			short_ids:["0123abcd"], tls_sni:"n.example.invalid",
			vless_reality_vision_enabled:true, shadowsocks_enabled:true, ss_password:"p" }' > "$WORK/params.json"

		# 3 first: if the shipped template is not accepted, row 2 proves nothing.
		if "$WORK/spine" render-server --engine singbox --template "$TEMPLATE" \
			--params "$WORK/params.json" --state "$WORK/id.json" --out "$WORK/ok.json" >/dev/null 2>"$WORK/e"; then
			ok "the shipped template is accepted"
		else
			badln "the SHIPPED template was refused: $(tr -d '\n' < "$WORK/e" | cut -c1-200). Every refusal row below would then pass for the wrong reason."
		fi

		# The modification must actually MODIFY. The first draft of this row used `jq '.' TEMPLATE`, and the
		# shipped template is already in jq's exact output format — so the "modified" file was byte-identical
		# and the row asserted a refusal of the very bytes the pin accepts. It passed by being a no-op, which
		# is the same class of defect this suite keeps finding, committed by the test.
		#
		# A meaning-preserving edit is deliberately chosen: 'no meaning changed' is exactly the judgement a
		# machine must not make about a template whose shape is hand-encoded elsewhere.
		jq '. + {"_mycelium_gate_marker": true}' "$TEMPLATE" > "$WORK/reformatted.json" 2>/dev/null
		if cmp -s "$TEMPLATE" "$WORK/reformatted.json"; then
			badln "the 'modified' template is byte-identical to the shipped one, so the refusal row below would assert nothing. Change how it is modified."
		fi
		if "$WORK/spine" render-server --engine singbox --template "$WORK/reformatted.json" \
			--params "$WORK/params.json" --state "$WORK/id.json" --out /dev/null >/dev/null 2>"$WORK/e2"; then
			badln "a template with different BYTES was accepted. The structs were not re-derived from it, so the render ignores whatever it says — which is the silent failure this pin exists to prevent."
		else
			grep -qi 'template' "$WORK/e2" \
				&& ok "a template whose bytes differ is refused, and the message says why" \
				|| badln "the modified template was refused for an unstated reason: $(tr -d '\n' < "$WORK/e2" | cut -c1-160)"
		fi

		# 4. The engine guard comes FIRST, so an xray caller is told the thing that applies to it.
		if "$WORK/spine" render-server --engine xray --template "$WORK/reformatted.json" \
			--params "$WORK/params.json" --state "$WORK/id.json" --out /dev/null >/dev/null 2>"$WORK/e3"; then
			badln "the Go verb rendered --engine xray, which it does not implement"
		else
			grep -qi 'xray\|not ported' "$WORK/e3" \
				&& ok "an xray caller is refused for being unported, not for the template" \
				|| badln "an xray call was refused for the wrong reason: $(tr -d '\n' < "$WORK/e3" | cut -c1-160). Ordering the template check ahead of the engine guard tells the caller about a file it was right to pass."
		fi
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the template and the structs that encode it are out of step.\n' >&2
	exit 1
fi
printf 'PASS: the encoded template is pinned to the shipped one, and anything else is refused.\n'
exit 0
