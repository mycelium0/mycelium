#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# pathsig_passive_observer.sh — conformance: the RP-0014 chunk-B path-level served-flow observer
# (control/lib/nb_measure.sh) is a PASSIVE, NODE-LOCAL, PAYLOAD-FREE by-product. It can never drop or
# reroute a packet (so it cannot alter the firewall), never transmits the observed data off-node, and
# retains only per-CLASS aggregate RST/SYN counts (never a source IP or per-peer identity). This is the
# ADR-0036 / AC-6 boundary made mechanical: watching the node's OWN served traffic passively is a
# by-product, not a new client-vantage probe.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   Chunk B is the detector's first path-level input, and its safety rests entirely on the observer
#   being incapable of harm: a DEDICATED, ADDITIVE nft table with `policy accept` whose rules ONLY
#   count, reading its own counters and writing one node-local marker. A future edit that turned a
#   counter rule into a drop/reject, added a source-address or payload match, or shipped the counts
#   off-node would silently convert a passive by-product into a firewall actuator or a surveillance
#   surface — without changing any Go control-plane code the other gates watch. This gate pins each of
#   those properties on the bash observer directly. OFFLINE + INSPECT-ONLY.
#
# WHAT THIS CHECKS (over control/lib/nb_measure.sh, bash comments stripped)
#   The nft-semantic checks run over the FULL emitted ruleset — every echo/printf statement in
#   pathsig_nft_apply that is piped to `nft -f -`, captured keyword-AGNOSTICally so a rule cannot hide
#   from a check by omitting a structural keyword — plus a guard that every DIRECT nft invocation (in or
#   out of the observer region) is a safe delete/list/read/apply form, never an out-of-band rule add.
#   1. DEDICATED table: the observer table is `inet mycelium_measure` (never filter/ufw/nat/mangle).
#   2. PASSIVE: the emitted chain declares `policy accept`, the ruleset counts (has `counter name`), and NO
#      emitted rule carries a packet-altering / rerouting / logging verdict (drop|reject|dnat|snat|
#      masquerade|redirect|tproxy|nftrace|log|queue num|ct ... set) — it only counts and falls through.
#   3. PAYLOAD-FREE + NO PER-PEER IDENTITY: no emitted rule matches on a source/dest address (saddr/daddr),
#      a meta selector, a payload expression (@ll/@nh/@th/@ih/string), a conntrack state
#      (ct state/status/mark/label/...), or an interface (iif/oif) — only the destination PORT + TCP flags.
#   4. NODE-LOCAL: the region never opens an off-node transmit (a network client — curl/wget/nc/ssh/dns/
#      python/...) — the counts stay on the node; the only sink is the local $STATE_DIR marker.
#   5. AGGREGATE-ONLY MARKER: the marker JSON the region writes carries ONLY the allowlisted keys
#      {observed_at, checked, reset}; `reset` is a list of closed-vocab class refs, never an IP/peer.
#   6. FAIL-SAFE + ADVISORY: the arm + probe entrypoints guard on `have nft && have jq || return 0`, and
#      the region actuates nothing — no systemctl / render / promote / rotate / node-apply / engine.
#   7. RUNTIME PROOF PRESENT: the Go fold + end-to-end tests that prove the marker actually drives
#      blocked/connection-reset exist, so the fold's runtime proof cannot be silently dropped.
#
# Exit: 0 = passive/node-local/payload-free/advisory; 1 = a violation; 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'pathsig_passive_observer: cannot resolve repo root\n' >&2; exit 2; }

SRC="$REPO_ROOT/control/lib/nb_measure.sh"
MEAS_TEST="$REPO_ROOT/internal/measure/measure_test.go"
DAEMON_TEST="$REPO_ROOT/cmd/myceliumd/measure_test.go"

# A real nft COMMAND invocation (not the word "nft" in prose/a unit Description): `nft` followed by a flag
# or a subcommand. Used to find rule emissions in and out of the observer region.
NFT_CMD='(^|[[:space:]]|;|\()nft[[:space:]]+(-[a-zA-Z]|add|insert|replace|delete|list|flush|create|monitor)'
NL='
'

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== path-signal observer passive/node-local/payload-free check (RP-0014 chunk B) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

[ -f "$SRC" ] || { printf 'FAIL: observer source not found: %s\n' "$SRC" >&2; exit 2; }
ok "observer source present: ${SRC#"$REPO_ROOT"/}"

# The pathsig REGION = the four observer functions, from the PATHSIG_NFT_TABLE constant up to (but not
# including) measure_enable(). Fail closed if it cannot be delimited (a refactor that moved the boundary
# markers must re-confirm this gate rather than silently checking nothing).
region="$(awk '/^PATHSIG_NFT_TABLE=/{f=1} /^measure_enable\(\)/{f=0} f' "$SRC")"
if [ -z "$region" ] || ! printf '%s' "$region" | grep -q 'pathsig_nft_apply()' || ! printf '%s' "$region" | grep -q 'measure_pathsig_probe()'; then
	printf 'FAIL: could not delimit the pathsig observer region (PATHSIG_NFT_TABLE .. measure_enable) — the boundary markers moved; re-confirm this gate.\n' >&2
	exit 1
fi
# Strip bash comments (full-line and trailing ` # ...`) so a comment can neither create a false hit nor
# hide a real one. The observer uses no '#' inside a string, so cutting at an unquoted-ish '#' is safe.
region_nc="$(printf '%s\n' "$region" | sed -E 's/(^|[[:space:]])#.*$/\1/')"

# The FULL nft ruleset the observer applies: EVERY echo/printf statement in pathsig_nft_apply (the block
# piped to `nft -f -`), captured keyword-AGNOSTICally so a rule cannot hide from the checks below by
# omitting a structural keyword. The shell log/warn lines are `log "..."`/`warn "..."` (not echo/printf),
# so they are naturally excluded and the nft-semantic checks never trip over the logging helper named "log".
apply_body="$(printf '%s\n' "$region_nc" | awk 'index($0,"pathsig_nft_apply()"){f=1} f{print} f&&/^\}/{f=0}')"
ruleset="$(printf '%s\n' "$apply_body" | grep -E '(^|[[:space:]]|;|\bdo[[:space:]])(echo|printf)[[:space:]]' || true)"
if [ -z "$ruleset" ]; then
	printf 'FAIL: found no nft ruleset (echo/printf) in pathsig_nft_apply — the observer ruleset is not where this gate can see it.\n' >&2
	exit 1
fi

# STRUCTURAL PRECONDITION for checks 2/3: the ruleset must be built ONLY from LITERAL echo/printf inside the
# `{ ... } | nft -f -` block. Otherwise the literal text this gate scans is not the text the kernel gets: a
# helper FUNCTION CALL in the block (`_emit_extra_rules`) or a bare-variable payload (`echo "$rule"`) would
# emit arbitrary rules whose literal payload is empty here — checks 2/3 would scan nothing and still pass.
pipe_block="$(printf '%s\n' "$apply_body" | awk '/^[[:space:]]*\{[[:space:]]*$/{f=1;next} /^[[:space:]]*\}[[:space:]]*\|[[:space:]]*nft[[:space:]]+-f/{f=0} f')"
if [ -z "$pipe_block" ]; then
	printf 'FAIL: could not delimit the `{ ... } | nft -f -` ruleset block in pathsig_nft_apply — the ruleset is built somewhere this gate cannot scan; re-confirm this gate.\n' >&2
	exit 1
fi
# Every statement in the block must be a literal emitter or loop control — nothing else may contribute text.
nonemit="$(printf '%s\n' "$pipe_block" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
	| grep -vE '^$' | grep -vE '(echo|printf)[[:space:]]' | grep -vE '^(do|done|for[[:space:]].*[[:space:]]do)$' || true)"
if [ -n "$nonemit" ]; then
	badln "the ruleset block contains a statement that is not a literal echo/printf (a helper call or substitution can emit rules this gate cannot scan):"
	printf '%s\n' "$nonemit" | sed 's/^/        /'
else
	ok "the ruleset block is built only from literal echo/printf (no helper call can smuggle in an unscanned rule)"
fi
# No emitter may carry a BARE VARIABLE as its whole payload (the rule text would live in the variable).
barevar="$(printf '%s\n' "$pipe_block" | grep -nE '(echo|printf)[[:space:]]+"?\$[A-Za-z_][A-Za-z0-9_]*"?[[:space:]]*(;|$)' || true)"
if [ -n "$barevar" ]; then
	badln "a ruleset emitter's whole payload is a bare variable — its rule text is invisible to the literal scans below:"
	printf '%s\n' "$barevar" | sed 's/^/        /'
else
	ok "no ruleset emitter hides its payload behind a bare variable"
fi

# Every DIRECT nft invocation in the region must be one of the safe management forms (delete a table, list,
# read counters, or apply the ruleset via a stdin pipe) — never an add/insert/replace of a rule (which could
# carry a drop/reroute verdict or a source-address match OUTSIDE the echo/printf ruleset captured above).
# Vetted PER INVOCATION, not per line: a compound line such as `nft list table X && nft add rule ... drop`
# would otherwise be laundered whole by a line-based filter that matched only its first, safe clause.
badnft=""
while IFS= read -r inv; do
	[ -n "$inv" ] || continue
	case "$inv" in
		"nft delete table"*|"nft list table"*|"nft -j list counters"*|"nft -f -"*) : ;;
		*) badnft="$badnft${badnft:+$NL}$inv" ;;
	esac
done <<EOF
$(printf '%s\n' "$region_nc" | grep -oE "nft[[:space:]]+(-[a-zA-Z]|add|insert|replace|delete|list|flush|create|monitor)[^;&|]*" || true)
EOF
if [ -n "$badnft" ]; then
	badln "the region has a direct nft invocation that is not a safe delete/list/read/apply form (a rule add/insert could bypass the ruleset checks):"
	printf '%s\n' "$badnft" | sed 's/^/        /'
else
	ok "every direct nft invocation is a safe delete/list/read/apply form (no out-of-band rule add/insert/replace)"
fi
# Whole-file guard: no nft rule emission may live OUTSIDE the pathsig region (so firewall mutation cannot
# migrate into measure_enable/_disable or elsewhere and escape every nft-semantic check).
outside_nc="$(awk '/^PATHSIG_NFT_TABLE=/{f=1} /^measure_enable\(\)/{f=0} !f{print}' "$SRC" | sed -E 's/(^|[[:space:]])#.*$/\1/')"
badoutside="$(printf '%s\n' "$outside_nc" | grep -nE "$NFT_CMD" || true)"
if [ -n "$badoutside" ]; then
	badln "an nft invocation lives OUTSIDE the observer region (it escapes the passivity checks — keep all nft in the pathsig functions):"
	printf '%s\n' "$badoutside" | sed 's/^/        /'
else
	ok "no nft rule emission lives outside the observer region (firewall mutation cannot migrate out)"
fi

# --- 1. DEDICATED, ADDITIVE table --------------------------------------------------------------------
if printf '%s\n' "$region_nc" | grep -q 'PATHSIG_NFT_TABLE="inet mycelium_measure"'; then
	ok "observer table is the dedicated 'inet mycelium_measure' (additive; cannot rewrite the real firewall)"
else
	badln "the observer table constant is not exactly 'inet mycelium_measure' — a shared/filter/nat table could alter the live firewall"
fi
if printf '%s\n' "$region_nc" | grep -nE '\b(table[[:space:]]+(inet|ip6?|arp|bridge|netdev)[[:space:]]+(filter|nat|mangle|raw|security)|table[[:space:]]+(filter|nat|mangle)|ufw[0-9a-z-]*)\b' | grep -qv 'mycelium_measure'; then
	badln "the observer region references a non-dedicated firewall table (filter/nat/mangle/ufw) — it must only ever touch inet mycelium_measure"
	printf '%s\n' "$region_nc" | grep -nE '\b(table[[:space:]]+(inet|ip6?|arp|bridge|netdev)[[:space:]]+(filter|nat|mangle|raw|security)|table[[:space:]]+(filter|nat|mangle)|ufw[0-9a-z-]*)\b' | sed 's/^/        /'
else
	ok "the observer region names no non-dedicated firewall table (never touches filter/nat/mangle/ufw)"
fi

# --- 2. PASSIVE (policy accept; counts; no altering verdict) — over the FULL ruleset -----------------
if printf '%s\n' "$ruleset" | grep -q 'policy accept'; then
	ok "the emitted input chain declares 'policy accept' (it never blocks a packet by default)"
else
	badln "the emitted input chain does not declare 'policy accept' — a non-accept policy could drop served traffic"
fi
if printf '%s\n' "$ruleset" | grep -q 'counter name'; then
	ok "the emitted ruleset installs counters ('counter name') — it observes"
else
	badln "the emitted ruleset installs no 'counter name' — the observer is not counting (or the ruleset moved)"
fi
# No packet-altering / rerouting / logging verdict ANYWHERE in the full ruleset. 'rst'/'syn'/'ack'/'fin'
# appear only in tcp-flags expressions + counter names, and 'accept' only as the chain policy — none are in
# this denylist, so a match here is a genuine drop/reroute/log/queue/ct-set verdict.
altering="$(printf '%s\n' "$ruleset" | grep -inE '\b(drop|reject|dnat|snat|masquerade|redirect|tproxy|nftrace)\b|\bqueue[[:space:]]+num\b|\blog\b|\bct\b[^"]*\bset\b' || true)"
if [ -n "$altering" ]; then
	badln "the emitted nft ruleset carries a packet-altering / rerouting / logging verdict (must be counter-only):"
	printf '%s\n' "$altering" | sed 's/^/        /'
else
	ok "the emitted nft ruleset carries no drop/reject/nat/redirect/tproxy/queue/log/ct-set verdict (counter-only)"
fi

# --- 3. PAYLOAD-FREE + NO PER-PEER IDENTITY — over the FULL ruleset -----------------------------------
# No emitted rule may match on a source/dest address, a meta selector, a payload expression, a conntrack
# state, or an interface — only the destination PORT + TCP flags. Any of these would make the observer
# capable of per-peer surveillance or payload inspection.
peer_or_payload="$(printf '%s\n' "$ruleset" | grep -inE '\b(saddr|daddr)\b|\bmeta\b|@(ll|nh|th|ih)\b|\bstring\b|\bct[[:space:]]+(state|status|mark|label|count|helper|expiration|direction|bytes|packets)\b|\b(iif|oif|iifname|oifname)\b' || true)"
if [ -n "$peer_or_payload" ]; then
	badln "an emitted rule matches on source identity, an interface, a meta selector, a payload, or conntrack state (must match only dport + tcp flags):"
	printf '%s\n' "$peer_or_payload" | sed 's/^/        /'
else
	ok "every emitted rule matches only on 'tcp dport' + 'tcp flags' — no address, meta, payload, ct-state, or interface"
fi

# --- 4. NODE-LOCAL (no off-node transmit) ------------------------------------------------------------
# A denylist of network clients matched in COMMAND position (start of statement / after a pipe/;/&/subshell
# / after whitespace) OR in assignment-RHS position (`sender=nc`, which would otherwise be invoked as "$sender"),
# followed by whitespace or EOL — so a flag like `jq -nc` or a word like "counters" is not a false hit.
# Comprehensive for realistic exfil (http, shell, dns, scripting); a TRIPWIRE, not a proof — a denylist can
# always be defeated by sufficient indirection, so it backs up (never replaces) the structural checks above.
transmit="$(printf '%s\n' "$region_nc" | grep -inE '(^|[[:space:]]|[|;&(=])(curl|wget|ncat|socat|telnet|ssh|scp|sftp|rsync|nc|dig|host|nslookup|getent|python3?|perl|ruby|node|logger|mail|mailx|sendmail|tftp|ftp|ping|openssl|busybox)([[:space:]]|[;&|)]|$)|/dev/(tcp|udp)/' || true)"
if [ -n "$transmit" ]; then
	badln "the observer region invokes an off-node transmit tool (the counts must never leave the node):"
	printf '%s\n' "$transmit" | sed 's/^/        /'
else
	ok "the observer region invokes no off-node transmit tool (http/shell/dns/scripting) — counts stay node-local"
fi

# --- 5. AGGREGATE-ONLY MARKER ------------------------------------------------------------------------
# Fail CLOSED on an unrecognised marker-writer shape: if the writer is refactored (e.g. to `jq -n`), this
# gate can no longer read its keys, so it must be re-confirmed by a human rather than silently pass.
marker_lines="$(printf '%s\n' "$region_nc" | grep -E "printf '\\{")"
if [ -z "$marker_lines" ]; then
	badln "no marker-writer of the known 'printf \"{...}\"' shape in the observer region — the marker's keys cannot be read, so the aggregate-only invariant is UNVERIFIED; re-confirm this gate against the new writer shape"
else
	badkeys="$(printf '%s\n' "$marker_lines" | grep -oE '"[a-z_]+":' | tr -d '":' | sort -u | grep -vxE 'observed_at|checked|reset' || true)"
	if [ -n "$badkeys" ]; then
		badln "the observer marker carries a key outside the aggregate allowlist {observed_at,checked,reset}: $(printf '%s' "$badkeys" | tr '\n' ' ')"
	else
		ok "the observer marker carries only the aggregate keys {observed_at, checked, reset} (no IP/peer/host field)"
	fi
fi

# --- 6. FAIL-SAFE + ADVISORY -------------------------------------------------------------------------
guarded=0
for fn in pathsig_nft_apply measure_pathsig_probe; do
	body="$(printf '%s\n' "$region_nc" | awk -v fn="$fn" 'index($0, fn"()"){f=1} f&&/^\}/{f=0;print;next} f')"
	if printf '%s\n' "$body" | grep -qE 'have nft && have jq \|\| return 0|have nft \|\| return 0'; then
		guarded=$((guarded + 1))
	else
		badln "$fn does not fail-safe on a missing nft/jq (must 'return 0' -> no signal when the tool is absent)"
	fi
done
[ "$guarded" -eq 2 ] && ok "the ruleset installer + the probe reader both fail-safe on a missing nft/jq (no fabricated signal)"
actuation="$(printf '%s\n' "$region_nc" | grep -inE '\bsystemctl\b|\b(sing-?box|xray)\b|\b(render_|promote_|apply_node|flow_node_apply|nb_rotate)|\brotate\b' || true)"
if [ -n "$actuation" ]; then
	badln "the observer region contains an actuation surface (systemctl / engine / render / promote / rotate):"
	printf '%s\n' "$actuation" | sed 's/^/        /'
else
	ok "the observer region actuates nothing (no systemctl / engine / render / promote / rotate) — advisory only"
fi

# --- 7. RUNTIME PROOF PRESENT (the fold + end-to-end Go tests) ---------------------------------------
# The gate above proves the observer is a safe PRODUCER. The proof that its marker actually drives the
# detector to blocked/connection-reset (the fold) lives in Go tests; require the COMPONENT readers/flags
# AND the two composition proofs (the Tick active-member fold + the daemon marker->PlanInput e2e), so the
# runtime proof of the fold cannot be silently deleted while this gate still passes.
need_meas="TestDetectorSignalConnectResetFold TestTickMarksCandidatePathReset TestTickPathResetFaultsBlockedReset"
missing_meas=""
for tn in $need_meas; do [ -f "$MEAS_TEST" ] && grep -q "$tn" "$MEAS_TEST" || missing_meas="$missing_meas $tn"; done
if [ -z "$missing_meas" ]; then
	ok "internal/measure fold tests present (ConnectReset fold + candidate exclusion + active-member blocked/reset)"
else
	badln "internal/measure/measure_test.go is missing chunk-B fold test(s):$missing_meas"
fi
need_daemon="TestReadPathMarker TestGateToResetMap TestPathSignalMarkerDrivesBlockedReset"
missing_daemon=""
for tn in $need_daemon; do [ -f "$DAEMON_TEST" ] && grep -q "$tn" "$DAEMON_TEST" || missing_daemon="$missing_daemon $tn"; done
if [ -z "$missing_daemon" ]; then
	ok "cmd/myceliumd marker tests present (readPathMarker + gateToResetMap + marker->PlanInput e2e fold)"
else
	badln "cmd/myceliumd/measure_test.go is missing chunk-B marker/e2e test(s):$missing_daemon"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the path-signal observer is not provably passive/node-local/payload-free — see above.\n' >&2
	exit 1
fi
printf 'PASS: the path-signal observer counts only (policy accept, dport+flags), keeps the counts node-local, writes an aggregate-only marker, fails safe, and never actuates.\n'
exit 0
