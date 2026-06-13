#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_dataplane_pii.sh — conformance: the node-local data-plane stats exporter (cmd/dataplane-stats)
# exports ONLY allowlisted, label-free AGGREGATE metrics and never decodes per-connection metadata,
# so the telemetry surface carries no PII (THREAT-MODEL: telemetry must never become a user trail).
# Author: mindicator & silicon bags quartet.
#
# This is the OFFLINE static guard. The RUNTIME proof — that the live /metrics output contains none
# of a PII-stuffed clash_api response — lives in cmd/dataplane-stats/main_test.go (run by `go test`),
# whose existence this gate also requires so the runtime check cannot be silently dropped.
#
# CHECKS
#   1. The exporter source exists.
#   2. Every mycelium_dataplane_* metric NAME it references is in the allowlist (no new metric slips
#      in unreviewed).
#   3. The exporter never NAMES a clash_api per-connection metadata field (destinationIP/sourceIP/
#      host/sniffHost/chains/rulePayload/metadata) — it counts connections via json.RawMessage and
#      never decodes their contents, so it cannot emit them.
#   4. The runtime PII test exists and actually asserts the no-PII / no-label invariant.
#
# Exit: 0 = exporter is aggregate-only and the runtime PII test is present; 1 = a violation; 2 = env.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

SRC="$REPO_ROOT/cmd/dataplane-stats/main.go"
TST="$REPO_ROOT/cmd/dataplane-stats/main_test.go"

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== data-plane exporter PII-safety check ==\n'

# 1. Source present.
if [ -f "$SRC" ]; then okln "exporter source present: ${SRC#"$REPO_ROOT"/}"; else
	printf 'FAIL: exporter source not found: %s\n' "$SRC" >&2; exit 2; fi

# 2. Metric-name allowlist. Every mycelium_dataplane_* token in the source must be allowlisted.
ALLOW=" mycelium_dataplane_clash_api_reachable mycelium_dataplane_upload_bytes_total mycelium_dataplane_download_bytes_total mycelium_dataplane_active_connections "
unknown=0
while IFS= read -r m; do
	[ -n "$m" ] || continue
	case "$ALLOW" in
		*" $m "*) : ;;
		*) badln "exporter references a non-allowlisted metric: $m"; unknown=1 ;;
	esac
done < <(grep -oE 'mycelium_dataplane_[a-z_]+' "$SRC" | sort -u)
[ "$unknown" -eq 0 ] && okln "all mycelium_dataplane_* metric names are allowlisted (aggregate-only)"

# 3. The exporter must NOT name any clash per-connection metadata field (would imply decoding it).
#    Scoped to the exporter source ONLY (the test fixture legitimately contains these strings).
if grep -nE 'destinationIP|sourceIP|sniffHost|rulePayload|"host"|"chains"|"metadata"' "$SRC" >/dev/null 2>&1; then
	badln "exporter source names a clash per-connection metadata field (must never decode/emit it)"
	grep -nE 'destinationIP|sourceIP|sniffHost|rulePayload|"host"|"chains"|"metadata"' "$SRC" | sed 's/^/        /'
else
	okln "exporter never names a per-connection metadata field (counts via json.RawMessage only)"
fi
# Belt-and-suspenders: the connection list must be held as raw, undecoded JSON.
if grep -q 'Connections[[:space:]]*\[\]json.RawMessage' "$SRC"; then
	okln "connection list is []json.RawMessage — contents are counted, never decoded"
else
	badln "the connection list is not []json.RawMessage — it may be decoding per-connection metadata"
fi

# 4. The runtime PII test must exist and assert the invariant.
if [ -f "$TST" ]; then
	if grep -q 'piiNeedles' "$TST" && grep -qiE 'PII|label' "$TST"; then
		okln "runtime PII test present and asserts the no-PII/no-label invariant: ${TST#"$REPO_ROOT"/}"
	else
		badln "runtime PII test present but does not assert the no-PII/no-label invariant"
	fi
else
	badln "runtime PII test missing: ${TST#"$REPO_ROOT"/} (the runtime no-PII proof must exist)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the data-plane exporter is not provably aggregate-only / PII-safe.\n' >&2
	exit 1
fi
printf 'PASS: the data-plane exporter exports only allowlisted aggregate metrics; no PII surface.\n'
exit 0
