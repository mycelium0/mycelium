#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# unit_netlink_parity.sh — conformance: every source that produces a sing-box / xray systemd unit
# MUST grant AF_NETLINK in that unit's RestrictAddressFamilies directive (unit-parity / §15.8 guard).
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS (post-incident, refactoring.md §4.4). sing-box (and xray) subscribe to
# route/interface updates via rtnetlink at startup; a hardened unit that omits AF_NETLINK from
# RestrictAddressFamilies makes the engine FATAL ("subscribe route updates: address family not
# supported by protocol") and crash-loop. The unit definition is duplicated across two hand-
# maintained deploy sources of truth — the bash bootstrap heredoc (scripts/node-bootstrap.sh) and
# the Ansible Jinja templates — and an incident fix that touched only one copy reproduced a live
# production crash-loop on the other (Audit-0004 F-001). This gate makes the two paths unable to
# diverge silently again.
#
# SCOPE — only the TLS-engine (sing-box / xray) units are checked. A single source file may emit
# several units (e.g. node-bootstrap.sh also writes node_exporter + a dataplane-metrics unit). The
# gate identifies the engine unit by its ExecStart binary (a literal path, a shell var like
# $SINGBOX_BIN, or a Jinja var like {{ singbox_bin_path }} — all lowercase-match singbox/sing-box/
# sing_box/xray) and checks ONLY that unit's RestrictAddressFamilies. node_exporter (loopback host-
# metric reader, no netlink) and the dataplane-metrics oneshot are correctly NOT required to grant it.
#
# CHECKS, per declared source:
#   1. the source exists;
#   2. it contains at least one sing-box/xray engine unit with a RestrictAddressFamilies directive;
#   3. EVERY such engine-unit RestrictAddressFamilies includes the AF_NETLINK token.
#
# Exit: 0 = all engine units grant AF_NETLINK; 1 = a divergence; 2 = environment error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# Sources that emit a sing-box/xray systemd unit. Add a row whenever a new such source appears.
SOURCES=(
	"scripts/node-bootstrap.sh"
	"infra/ansible/roles/singbox/templates/singbox.service.j2"
	"infra/ansible/roles/xray/templates/xray.service.j2"
)

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== sing-box/xray unit AF_NETLINK parity check ==\n'

# awk: track whether the current unit's ExecStart is an engine binary; on each RestrictAddressFamilies
# directive within an engine unit, require AF_NETLINK. Emits offending lines, then "TOTAL=n BAD=n".
# eng resets at each file (FNR==1) and is re-decided at every ExecStart/ExecStartPre line.
read -r -d '' AWK <<'AWK_PROG' || true
FNR==1 { eng=0 }
/ExecStart/ {
	low=tolower($0)
	eng = (low ~ /singbox|sing-box|sing_box|xray/) ? 1 : 0
}
/^[ \t]*RestrictAddressFamilies=/ {
	if (eng==1) {
		total++
		if ($0 !~ /AF_NETLINK/) { printf "%s:%d: %s\n", FILENAME, FNR, $0; bad++ }
	}
}
END { printf "TOTAL=%d BAD=%d\n", total+0, bad+0 }
AWK_PROG

for rel in "${SOURCES[@]}"; do
	src="$REPO_ROOT/$rel"
	if [ ! -f "$src" ]; then
		printf 'FAIL: declared unit source not found: %s\n' "$rel" >&2
		exit 2
	fi

	out="$(awk "$AWK" "$src")"
	total="$(printf '%s\n' "$out" | sed -n 's/.*TOTAL=\([0-9]*\).*/\1/p')"
	bad="$(printf '%s\n'   "$out" | sed -n 's/.*BAD=\([0-9]*\).*/\1/p')"
	badlines="$(printf '%s\n' "$out" | grep -v '^TOTAL=' || true)"

	if [ "${total:-0}" -eq 0 ]; then
		badln "$rel: no sing-box/xray engine unit with a RestrictAddressFamilies directive found (a unit lost its RAF, or the engine ExecStart changed shape)"
	elif [ "${bad:-0}" -ne 0 ]; then
		badln "$rel: engine unit RestrictAddressFamilies without AF_NETLINK:"
		printf '%s\n' "$badlines" | sed 's/^/        /'
	else
		okln "$rel: all ${total} engine-unit RestrictAddressFamilies directive(s) grant AF_NETLINK"
	fi
done

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a sing-box/xray unit source omits AF_NETLINK — that deploy path would crash-loop the engine.\n' >&2
	exit 1
fi
printf 'PASS: every sing-box/xray unit source grants AF_NETLINK (no deploy-path divergence).\n'
exit 0
