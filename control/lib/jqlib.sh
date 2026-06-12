# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# jqlib.sh — thin jq wrappers used as the single rendering engine for Phase 0.
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl. Depends on common.sh (myc_die, myc_require_jq, myc_atomic_write).

# myc_json_valid FILE -> 0 if FILE is valid JSON, 1 otherwise. Quiet.
myc_json_valid() {
	myc_require_jq
	jq -e . "$1" >/dev/null 2>&1
}

# myc_assert_json FILE [LABEL] — die unless FILE is valid JSON.
myc_assert_json() {
	local file label
	file="$1"
	label="${2:-$1}"
	if [ ! -f "$file" ]; then
		myc_die "$label: file not found: $file"
	fi
	if ! myc_json_valid "$file"; then
		myc_die "$label: not valid JSON: $file"
	fi
}

# myc_jq_read FILE FILTER [JQ_ARGS...] — run a read-only jq filter on FILE.
myc_jq_read() {
	myc_require_jq
	local file filter
	file="$1"; shift
	filter="$1"; shift
	jq "$@" "$filter" "$file"
}

# myc_jq_edit FILE [JQ_ARGS...] FILTER
# Apply FILTER to FILE and write the result back atomically. Any jq options
# (e.g. --arg/--argjson pairs) go between FILE and FILTER; the FILTER is always
# the LAST argument — matching ordinary jq invocation style. The result is
# verified to still be valid JSON before it replaces the original, so a broken
# filter can never corrupt state.
myc_jq_edit() {
	myc_require_jq
	local file filter tmp
	file="$1"; shift
	[ "$#" -ge 1 ] || myc_die "myc_jq_edit: missing filter"
	# The filter is the last positional argument; everything before it is jq opts.
	# Pop the last argument portably (bash 3.2 has no negative indexing).
	local args=() i n
	n="$#"
	i=1
	for a in "$@"; do
		if [ "$i" -eq "$n" ]; then
			filter="$a"
		else
			args[$((i - 1))]="$a"
		fi
		i=$((i + 1))
	done
	myc_assert_json "$file"
	tmp="$(mktemp "${TMPDIR:-/tmp}/myc.jqedit.XXXXXX")" || myc_die "could not create temp file"
	# Expanding an empty array under `set -u` is an error in bash 3.2, so branch.
	if [ "${#args[@]}" -gt 0 ]; then
		if ! jq "${args[@]}" "$filter" "$file" >"$tmp" 2>/dev/null; then
			rm -f "$tmp"
			myc_die "jq edit failed on $file (filter rejected)"
		fi
	else
		if ! jq "$filter" "$file" >"$tmp" 2>/dev/null; then
			rm -f "$tmp"
			myc_die "jq edit failed on $file (filter rejected)"
		fi
	fi
	if ! jq -e . "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		myc_die "jq edit on $file produced invalid JSON; refusing to write"
	fi
	myc_atomic_write "$file" <"$tmp"
	rm -f "$tmp"
}

# myc_state_init FILE
# Ensure the identity state file exists and has the canonical shape:
#   { "version": 1, "clients": [ ... ] }
# Idempotent: an existing valid state file is left untouched.
myc_state_init() {
	myc_require_jq
	local file
	file="$1"
	if [ -f "$file" ]; then
		myc_assert_json "$file" "state"
		# Make sure the .clients array exists; add it if a hand-edited file lacks it.
		if ! jq -e 'has("clients") and (.clients | type == "array")' "$file" >/dev/null 2>&1; then
			myc_jq_edit "$file" '. + {clients: (.clients // [])} + {version: (.version // 1)}'
		fi
		return 0
	fi
	myc_mkdir_p "$(myc_dirname_of "$file")"
	printf '%s\n' '{"version":1,"clients":[]}' | jq . | myc_atomic_write "$file"
}

# myc_params_to_json PARAMS_FILE
# Echo the params as JSON on stdout. Accepts JSON directly. If the file is not
# JSON, attempt a YAML->JSON conversion via yq; if yq is absent, die with a
# clear instruction (params-as-JSON is always supported; see README).
myc_params_to_json() {
	myc_require_jq
	local file
	file="$1"
	if [ ! -f "$file" ]; then
		myc_die "params file not found: $file"
	fi
	if jq -e . "$file" >/dev/null 2>&1; then
		jq . "$file"
		return 0
	fi
	# Not JSON. Try YAML via yq (either mikefarah/yq or kislyuk/yq).
	if myc_have yq; then
		local converted
		if converted="$(yq -o=json '.' "$file" 2>/dev/null)" && \
		   printf '%s' "$converted" | jq -e . >/dev/null 2>&1; then
			printf '%s\n' "$converted"
			return 0
		fi
		if converted="$(yq . "$file" 2>/dev/null)" && \
		   printf '%s' "$converted" | jq -e . >/dev/null 2>&1; then
			printf '%s\n' "$converted"
			return 0
		fi
		myc_die "could not parse params file as JSON or YAML: $file"
	fi
	myc_die "params file is not JSON and 'yq' is not installed: $file
Provide params as JSON (see control/params.example.json), or install 'yq' to use YAML."
}

# myc_params_get PARAMS_JSON_TEXT JQ_PATH [DEFAULT]
# Read a value out of already-normalised params JSON (passed as text on stdin
# is awkward in bash 3.2, so we take it as the first argument). If the value is
# absent or null and a DEFAULT is given, the default is returned; otherwise die.
myc_params_get() {
	myc_require_jq
	local json path def out
	json="$1"; path="$2"; def="${3-__MYC_NODEFAULT__}"
	out="$(printf '%s' "$json" | jq -r "$path // empty" 2>/dev/null)"
	if [ -n "$out" ]; then
		printf '%s\n' "$out"
		return 0
	fi
	if [ "$def" != "__MYC_NODEFAULT__" ]; then
		printf '%s\n' "$def"
		return 0
	fi
	myc_die "required params field missing or empty: $path"
}
