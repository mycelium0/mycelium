#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fakenode.sh — a throwaway node root, SOURCEABLE, so the node's apply primitives can be EXECUTED
# offline instead of being grepped for.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS EXISTS
#   The seven-step transaction (render -> validate -> persist -> promote -> restart -> verify ->
#   rollback) is the most dangerous code in the tree: it runs as root, on a 15-minute unattended timer,
#   on every live node, and it is the only thing standing between a bad push and an unrecoverable node.
#   Every gate over it asserts SOURCE TEXT. `grep -rn flock tests/conformance/` returned nothing at all —
#   the atomicity and serialisation added in 5f7aee2 had no executable coverage of any kind.
#
#   Text assertions over this path have already failed in both directions, repeatedly: they went green on
#   a guard whose arithmetic was disabled by a one-token edit, and red on renames that changed nothing.
#   The way out is to run the real functions against a real filesystem and look at what they leave behind.
#
# WHAT IT GIVES YOU
#   * A node root under mktemp: $STATE_DIR, the sing-box and xray config dirs, params/identities, and a
#     pre-existing live config + last-known-good so the interesting branches are reachable.
#   * The entrypoint's shared helpers (log/warn/die/have/run/need_root) that control/lib/* resolve at call
#     time — the same shape control/selftest.sh uses.
#   * $STUBDIR first on PATH, stubbing the tools that would otherwise need root or touch the host:
#     `install` (records argv, then copies WITHOUT the ownership flags), `systemctl`, `ss`, `sing-box`,
#     `xray`. `flock` is deliberately NOT stubbed — serialisation is one of the properties under test, so
#     it must be the real thing or absent.
#   * fakenode_watch: a filesystem tripwire the mutating stubs call, so a test can assert the invariant at
#     EVERY intermediate step of a transaction rather than only at its end.
#
# THE HARD REFUSAL
#   Every path this fixture hands out is under its own mktemp root, and fakenode_init aborts the process
#   if any of them resolves outside it. A test that executes root-path primitives must not be one edit
#   away from executing them against /var/lib/mycelium — so the check is a refusal, not a warning, and it
#   runs before a single stub is installed. (Same discipline as pathsig_reset_drill.sh's armed-node
#   refusal.)
#
# USAGE
#   . tests/lab/fakenode.sh
#   fakenode_init                 # creates the root, exports the globals, installs the stubs
#   ... source the lib under test, call its functions ...
#   fakenode_cleanup              # removes the root (also runs on EXIT)

# ---------------------------------------------------------------------------
# DEFAULT ONLY IF UNSET. These were plain assignments, which CLOBBERED the values a parent had exported —
# so a child that sourced this file to fakenode_attach found an empty root and aborted before it ever
# reached the function under test. The gate above it then read that abort as "the code refused", and a row
# testing a fail-closed refusal passed vacuously against a mutant that had removed the refusal entirely.
# A fixture that erases the state it is meant to adopt is worse than no fixture: it manufactures green.
: "${FAKENODE_ROOT:=}"
: "${STUBDIR:=}"
: "${FAKENODE_ARGV_LOG:=}"
: "${FAKENODE_WATCH_LOG:=}"
_FAKENODE_PATH_SAVED=""

fakenode_die() { printf 'fakenode: %s\n' "$1" >&2; exit 2; }

# fakenode_init [--no-live] — build the root and export the globals control/lib/* expect.
fakenode_init() {
	local want_live=1
	[ "${1:-}" = "--no-live" ] && want_live=0

	FAKENODE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/myc.fakenode.XXXXXX")" || fakenode_die "mktemp failed"
	# Resolve, because the refusal below compares resolved prefixes and macOS hands out /var -> /private/var.
	FAKENODE_ROOT="$(cd -P "$FAKENODE_ROOT" && pwd)"

	STATE_DIR="$FAKENODE_ROOT/var/lib/mycelium"
	SINGBOX_ETC="$FAKENODE_ROOT/usr/local/etc/sing-box"
	XRAY_ETC="$FAKENODE_ROOT/usr/local/etc/xray"
	SINGBOX_CONFIG="$SINGBOX_ETC/config.json"
	LASTGOOD_CONFIG="$STATE_DIR/config.lastgood.json"
	XRAY_CONFIG="$XRAY_ETC/config.json"
	XRAY_LASTGOOD_CONFIG="$STATE_DIR/xray.config.lastgood.json"
	PARAMS_JSON="$STATE_DIR/params.json"
	IDENTITIES_JSON="$STATE_DIR/identities.json"
	SINGBOX_RUN_GROUP="sing-box"
	XRAY_RUN_GROUP="xray"
	DRY_RUN=0
	STUBDIR="$FAKENODE_ROOT/stub"
	FAKENODE_ARGV_LOG="$FAKENODE_ROOT/argv.log"
	FAKENODE_WATCH_LOG="$FAKENODE_ROOT/watch.log"

	# --- THE REFUSAL, before anything is created or stubbed --------------------------------------
	local p
	for p in "$STATE_DIR" "$SINGBOX_ETC" "$XRAY_ETC" "$SINGBOX_CONFIG" "$LASTGOOD_CONFIG" \
	         "$XRAY_CONFIG" "$XRAY_LASTGOOD_CONFIG" "$PARAMS_JSON" "$IDENTITIES_JSON" "$STUBDIR"; do
		case "$p" in
			"$FAKENODE_ROOT"/*) ;;
			*) fakenode_die "REFUSING TO RUN: '$p' resolves outside the throwaway root '$FAKENODE_ROOT'. This fixture executes root-path apply primitives; one wrong path and it executes them against the real node." ;;
		esac
	done

	mkdir -p "$STATE_DIR" "$SINGBOX_ETC" "$XRAY_ETC" "$STUBDIR" || fakenode_die "mkdir failed"
	: >"$FAKENODE_ARGV_LOG"; : >"$FAKENODE_WATCH_LOG"

	# 0600, because that is what a real node has — verified on all three live nodes: params.json,
	# identities.json, operator-overrides.json and clash.secret are 0600 there. Seeding them under the
	# ambient umask made the fixture LOOSER than production, and a gate checking for world-readable
	# secrets then reported the fixture's own file as a finding.
	( umask 077
	  printf '{"donor_sni":"example.invalid","node_bind":"::"}\n' >"$PARAMS_JSON"
	  printf '{"clients":[{"name":"alice","uuid":"u-1"}]}\n'      >"$IDENTITIES_JSON" )
	if [ "$want_live" -eq 1 ]; then
		printf '{"generation":"OLD","inbounds":[]}\n' >"$SINGBOX_CONFIG"
		printf '{"generation":"OLD","inbounds":[]}\n' >"$XRAY_CONFIG"
	fi

	# The stubs are separate PROCESSES. They inherit neither the shell variables nor the shell functions of
	# this fixture, so everything they need is exported explicitly — the first draft exported none of it and
	# the tripwire silently recorded nothing, which would have made every invariant below vacuous.
	export FAKENODE_ROOT FAKENODE_ARGV_LOG FAKENODE_WATCH_LOG
	export STATE_DIR SINGBOX_CONFIG LASTGOOD_CONFIG XRAY_CONFIG XRAY_LASTGOOD_CONFIG

	_fakenode_install_stubs
	_FAKENODE_PATH_SAVED="$PATH"
	PATH="$STUBDIR:$PATH"; export PATH
	trap 'fakenode_cleanup' EXIT
	return 0
}

# fakenode_attach — adopt a root an ANCESTOR already created, instead of making a new one. A test that
# needs faithful `set -e` semantics has to run the function under test in its own PROCESS (see the note in
# promote_transaction_atomic.sh: `( set -e; f ) || rc=$?` suppresses the very `set -e` it installs, because
# the subshell sits on the left of `||`). That child needs the same node root, not a fresh one.
fakenode_attach() {
	[ -n "${FAKENODE_ROOT:-}" ] || fakenode_die "fakenode_attach: FAKENODE_ROOT is not set — nothing to attach to"
	[ -d "$FAKENODE_ROOT" ]     || fakenode_die "fakenode_attach: '$FAKENODE_ROOT' does not exist"
	STUBDIR="$FAKENODE_ROOT/stub"
	SINGBOX_ETC="$(dirname "${SINGBOX_CONFIG:?}")"
	XRAY_ETC="$(dirname "${XRAY_CONFIG:?}")"
	SINGBOX_RUN_GROUP="sing-box"; XRAY_RUN_GROUP="xray"; DRY_RUN=0
	PARAMS_JSON="$STATE_DIR/params.json"; IDENTITIES_JSON="$STATE_DIR/identities.json"
	_FAKENODE_PATH_SAVED="$PATH"
	PATH="$STUBDIR:$PATH"; export PATH
	# NO trap here: the ancestor owns the root and will remove it.
	return 0
}

# The entrypoint's shared helpers. control/lib/* resolve these at CALL time from the sourced scope, which
# is exactly what makes the libraries drivable here.
log()       { printf 'log %s\n'  "$*" >>"$FAKENODE_ROOT/log"; }
warn()      { printf 'warn %s\n' "$*" >>"$FAKENODE_ROOT/log"; }
die()       { printf 'die %s\n'  "$*" >>"$FAKENODE_ROOT/log"; exit 1; }
have()      { command -v "$1" >/dev/null 2>&1; }
run()       { "$@"; }
need_root() { :; }

# The TRIPWIRE is an executable, not a function: the mutating stubs are child processes and cannot call a
# shell function. It snapshots the two config paths before and after every real operation, so a test can
# assert the whole-generation invariant at EVERY intermediate step of a transaction rather than only at its
# end — which is the difference between "the result is correct" and "no reader could ever observe a torn
# file". One line per observation:
#   <label> live=<GEN|absent|torn> lastgood=<GEN|absent|torn> temps=<count of .live.*/.lastgood.* around>
# The marker, not a hash: a hash tells you the bytes changed, the generation marker tells you WHICH whole
# generation a reader would have seen, and `torn` tells you they would have seen neither.
_fakenode_write_watcher() {
	cat >"$STUBDIR/fakenode-watch" <<'WATCH'
#!/usr/bin/env bash
gen() {
	[ -f "$1" ] || { printf 'absent'; return 0; }
	[ -s "$1" ] || { printf 'torn-empty'; return 0; }
	local g
	g="$(sed -n 's/.*"generation":"\([^"]*\)".*/\1/p' "$1" | head -1)"
	if [ -z "$g" ]; then printf 'torn'; else
		# a whole fixture config both opens and closes its object
		case "$(tr -d '[:space:]' <"$1")" in
			'{'*'}') printf '%s' "$g" ;;
			*)       printf 'torn' ;;
		esac
	fi
}
tmps="$(ls -1 "$(dirname "${SINGBOX_CONFIG:?}")"/.live.* "$(dirname "${LASTGOOD_CONFIG:?}")"/.lastgood.* 2>/dev/null | wc -l | tr -d ' ')"
printf '%s live=%s lastgood=%s temps=%s\n' "${1:-?}" "$(gen "$SINGBOX_CONFIG")" "$(gen "$LASTGOOD_CONFIG")" "$tmps" >>"${FAKENODE_WATCH_LOG:?}"
WATCH
	chmod +x "$STUBDIR/fakenode-watch"
}

# fakenode_generation FILE — the `generation` marker a fixture config carries, or `torn` if the file is not
# whole JSON. This is what separates "a reader saw the old config" from "a reader saw half a config".
fakenode_generation() {
	[ -f "$1" ] || { printf 'absent'; return 0; }
	if command -v jq >/dev/null 2>&1; then
		jq -r '.generation // "no-marker"' "$1" 2>/dev/null || printf 'torn'
	else
		sed -n 's/.*"generation":"\([^"]*\)".*/\1/p' "$1" | head -1
	fi
}

_fakenode_install_stubs() {
	_fakenode_write_watcher
	# install — the real one needs root for -o/-g. Record the FULL argv (so a test can assert the mode and
	# ownership the transaction asks for), then perform the copy without the ownership flags.
	cat >"$STUBDIR/install" <<'STUB'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >>"${FAKENODE_ARGV_LOG:?}"
mode=""; args=(); dir=0
while [ $# -gt 0 ]; do
	case "$1" in
		-m) mode="$2"; shift 2 ;;
		-o|-g) shift 2 ;;
		-d) dir=1; shift ;;
		*) args+=("$1"); shift ;;
	esac
done
if [ "$dir" -eq 1 ]; then mkdir -p "${args[@]}"; [ -n "$mode" ] && chmod "$mode" "${args[@]}"; exit 0; fi
[ "${#args[@]}" -ge 2 ] || exit 1
src="${args[0]}"; dst="${args[1]}"
fakenode-watch "install:pre:$(basename "$dst")"
/bin/cp -f "$src" "$dst" || exit 1
[ -n "$mode" ] && chmod "$mode" "$dst"
fakenode-watch "install:post:$(basename "$dst")"
exit 0
STUB
	# cp / mv — pass through to the real tool, but bracket each call with a watch observation. This is what
	# lets a test see the state BETWEEN the lastgood snapshot and the live replace.
	cat >"$STUBDIR/cp" <<'STUB'
#!/usr/bin/env bash
printf 'cp %s\n' "$*" >>"${FAKENODE_ARGV_LOG:?}"
fakenode-watch "cp:pre"
/bin/cp "$@"; rc=$?
fakenode-watch "cp:post"
exit $rc
STUB
	cat >"$STUBDIR/mv" <<'STUB'
#!/usr/bin/env bash
printf 'mv %s\n' "$*" >>"${FAKENODE_ARGV_LOG:?}"
fakenode-watch "mv:pre"
/bin/mv "$@"; rc=$?
fakenode-watch "mv:post"
exit $rc
STUB
	# The rest are inert recorders: nothing here may touch a real service or socket.
	local t
	for t in systemctl ss sing-box xray; do
		cat >"$STUBDIR/$t" <<STUB
#!/usr/bin/env bash
printf '$t %s\n' "\$*" >>"\${FAKENODE_ARGV_LOG:?}"
exit 0
STUB
	done
	chmod +x "$STUBDIR"/* || fakenode_die "could not make the stubs executable"
}

# fakenode_fail_tool TOOL PATTERN — make TOOL fail (exit 1) whenever its argv contains PATTERN, and behave
# normally otherwise. Deterministic fault injection that does not depend on who is running.
#
# The first draft injected by chmod-ing a directory read-only. That works for an ordinary user and does
# NOTHING for root, which ignores directory permissions — so the same row exercised a failure path on a
# laptop and the happy path on a node, and reported the happy path as a passing refusal. Fault injection
# must not be uid-dependent.
fakenode_fail_tool() {
	local tool="$1" pat="$2" real
	real="$(PATH="$_FAKENODE_PATH_SAVED" command -v "$tool")" || fakenode_die "fakenode_fail_tool: no real '$tool' on PATH"
	cat >"$STUBDIR/$tool" <<STUB
#!/usr/bin/env bash
case "\$*" in
	*'$pat'*) printf '$tool: injected failure (%s)\n' "\$*" >&2; exit 1 ;;
esac
exec '$real' "\$@"
STUB
	chmod +x "$STUBDIR/$tool"
}

# fakenode_saw PATTERN — did any recorded argv line contain PATTERN?
fakenode_saw() { grep -qF -- "$1" "$FAKENODE_ARGV_LOG" 2>/dev/null; }

# fakenode_reset_logs — clear the argv + watch logs between rows of a table.
fakenode_reset_logs() { : >"$FAKENODE_ARGV_LOG"; : >"$FAKENODE_WATCH_LOG"; }

fakenode_cleanup() {
	[ -n "${_FAKENODE_PATH_SAVED:-}" ] && { PATH="$_FAKENODE_PATH_SAVED"; export PATH; }
	case "${FAKENODE_ROOT:-}" in
		/*/myc.fakenode.*) rm -rf "$FAKENODE_ROOT" ;;
		*) [ -n "${FAKENODE_ROOT:-}" ] && printf 'fakenode: refusing to remove an unexpected root: %s\n' "$FAKENODE_ROOT" >&2 ;;
	esac
	FAKENODE_ROOT=""
}
