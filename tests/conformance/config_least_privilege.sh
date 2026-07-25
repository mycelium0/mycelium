#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# config_least_privilege.sh — conformance (Audit-0008 S1-1): the LIVE data-plane config (sing-box + xray)
# INLINES the REALITY private key, every transport password + client UUID, and the clash_api Bearer secret.
# It must NOT be world-readable, and its directory must NOT be world-traversable — otherwise a co-resident
# non-service principal (e.g. node_exporter, which runs as its own user outside the engine group) can read
# the secrets + present the Bearer secret to the loopback clash controller. This gate pins the least-privilege
# promote/rollback perms structurally (the live check needs a node; this is the offline guard against a
# regression back to 0644 / 0755).
#
# Exit: 0 = least-privilege perms held, 1 = a world-readable config / world-traversable dir path, 2 = usage.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
UPD="$REPO_ROOT/control/lib/nb_update_apply.sh"
INST="$REPO_ROOT/control/lib/nb_install.sh"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== live-config least-privilege check (Audit-0008 S1-1) ==\n'
[ -f "$UPD" ]  || { printf 'FAIL: nb_update_apply.sh missing.\n' >&2; exit 2; }
[ -f "$INST" ] || { printf 'FAIL: nb_install.sh missing.\n' >&2; exit 2; }

# 1) NO `install -m 0644` (or any other-readable mode) writing a live *_CONFIG in the promote/rollback lib.
if grep -nE 'install -m 0[0-7]?[0-7][4-7][4-7]?\b.*(SINGBOX_CONFIG|XRAY_CONFIG)' "$UPD" >/dev/null 2>&1 \
   || grep -nE 'install -m 0644' "$UPD" | grep -qE 'CONFIG'; then
	badln "nb_update_apply.sh promotes/rolls a live config with an other-readable mode (world-readable secrets)"
	grep -nE 'install -m 0644.*CONFIG' "$UPD" | sed 's/^/         /' >&2
else
	ok "no world-readable install mode on a live config in the promote/rollback paths"
fi

# 2) Every live-config install uses -m 0640 AND -g (a service group) — the least-privilege form.
cfg_installs="$(grep -nE 'install -m [0-9]+ .*(SINGBOX_CONFIG|XRAY_CONFIG)' "$UPD" 2>/dev/null || true)"
if [ -z "$cfg_installs" ]; then
	badln "could not find the config install lines (did the promote/rollback functions change shape?)"
else
	bad_form="$(printf '%s\n' "$cfg_installs" | grep -vE 'install -m 0640 -o root -g ' || true)"
	if [ -n "$bad_form" ]; then
		badln "a live-config install is not the least-privilege '0640 -o root -g <group>' form:"
		printf '%s\n' "$bad_form" | sed 's/^/         /' >&2
	else
		ok "every live-config install is 0640 -o root -g <service group>"
	fi
fi

# 3) The config directories are created 0750 (not 0755 / world-traversable).
for pair in "SINGBOX_ETC:$INST" "XRAY_ETC:$UPD"; do
	var="${pair%%:*}"; file="${pair##*:}"
	line="$(grep -nE "install -d -m [0-9]+ .*\\\$$var" "$file" 2>/dev/null | head -1)"
	if [ -z "$line" ]; then
		badln "no 'install -d' for \$$var found in $(basename "$file")"
	elif printf '%s' "$line" | grep -qE 'install -d -m 0750 -o root -g '; then
		ok "\$$var is created 0750 -o root -g <group> (not world-traversable)"
	else
		badln "\$$var directory is not 0750 -o root -g <group>: $(printf '%s' "$line" | sed 's/^[0-9]*://')"
	fi
done

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the live data-plane config or its directory is not least-privilege (world-readable secrets risk).\n' >&2
	exit 1
fi
printf 'PASS: the live config is promoted 0640 root:<group> in a 0750 dir — no world-readable secrets.\n'
exit 0
