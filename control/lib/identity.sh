# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# identity.sh — client identity issuance/revocation backed by a JSON state file.
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl. Depends on common.sh and jqlib.sh.
#
# State shape:
#   { "version": 1, "clients": [ { "name": STR, "id": UUID, "created": RFC3339 }, ... ] }
# A client is uniquely keyed by BOTH name and id; we forbid duplicate names and
# duplicate ids. UUIDs are produced by 'xray uuid' only (no custom crypto).

# myc_identity_add STATE_FILE NAME
# Append a new client. Generates the UUID via 'xray uuid'. Fails if the name
# already exists. Prints the created record (compact JSON) on stdout.
myc_identity_add() {
	local state name id created
	state="$1"; name="$2"
	if [ -z "$name" ]; then
		myc_die "identity add: --name is required"
	fi
	myc_state_init "$state"
	if jq -e --arg n "$name" 'any(.clients[]; .name == $n)' "$state" >/dev/null 2>&1; then
		myc_die "identity add: a client named '$name' already exists in $state"
	fi
	id="$(myc_xray_uuid)"
	created="$(myc_now_utc)"
	# Defend against an id collision (astronomically unlikely, but cheap to check).
	if jq -e --arg i "$id" 'any(.clients[]; .id == $i)' "$state" >/dev/null 2>&1; then
		myc_die "identity add: generated UUID already present (retry): $id"
	fi
	myc_jq_edit "$state" \
		--arg n "$name" --arg i "$id" --arg c "$created" \
		'.clients += [{name: $n, id: $i, created: $c}]'
	jq -c --arg i "$id" '.clients[] | select(.id == $i)' "$state"
}

# myc_identity_revoke STATE_FILE SELECTOR
# Remove the client whose name OR id equals SELECTOR. Fails if no match.
myc_identity_revoke() {
	local state sel before after
	state="$1"; sel="$2"
	if [ -z "$sel" ]; then
		myc_die "identity revoke: a NAME or ID is required"
	fi
	myc_state_init "$state"
	before="$(jq '.clients | length' "$state")"
	if ! jq -e --arg s "$sel" 'any(.clients[]; .name == $s or .id == $s)' "$state" >/dev/null 2>&1; then
		myc_die "identity revoke: no client matches name/id '$sel' in $state"
	fi
	myc_jq_edit "$state" --arg s "$sel" \
		'.clients |= map(select(.name != $s and .id != $s))'
	after="$(jq '.clients | length' "$state")"
	myc_log "revoked $((before - after)) client(s) matching '$sel'"
}

# myc_identity_list STATE_FILE
# Print clients as an aligned table on stdout. Empty state prints a header only.
myc_identity_list() {
	local state
	state="$1"
	myc_state_init "$state"
	printf '%-24s  %-36s  %s\n' "NAME" "ID" "CREATED"
	jq -r '.clients[] | [.name, .id, .created] | @tsv' "$state" \
		| while IFS="$(printf '\t')" read -r n i c; do
			printf '%-24s  %-36s  %s\n' "$n" "$i" "$c"
		done
}

# myc_identity_clients_json STATE_FILE
# Echo the clients array as JSON (used by render/subscription). Validates state.
myc_identity_clients_json() {
	local state
	state="$1"
	myc_assert_json "$state" "state"
	jq -e '.clients' "$state" >/dev/null 2>&1 || myc_die "state has no .clients array: $state"
	jq '.clients' "$state"
}
