#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# hy2_hop_redirect_kept.sh — conformance: when the issued client configs advertise a hysteria2 port-hop
# RANGE, the firewall rule that makes that range real exists, covers it, and points at the port actually
# served — and the node NOTICES when it does not. EXECUTED over a value table.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   hysteria2 is the only family sing-box lets a client hop across a port range (verified against
#   1.13.13: tuic rejects `server_ports` outright), and the client is given the range UP FRONT — which is
#   the whole appeal, since the served port can then move inside it and no client has to learn anything.
#
#   But the hysteria2 INBOUND cannot listen on a range either. The server holds ONE port and a REDIRECT in
#   nat/PREROUTING delivers the range onto it. So the range is a promise the client config makes and the
#   FIREWALL keeps — and nothing else on this node can see whether it is kept:
#     * verify_post_apply checks that the service is active, the socket is bound, and a LOOPBACK handshake
#       completes. Loopback traffic never traverses PREROUTING, so the redirect is invisible to it.
#     * harden_ufw adds rules and never removes them, so a range that CHANGES leaves the old redirect
#       pointing at whatever it used to point at.
#   A missing or drifted rule therefore kills hysteria2 for the entire population while every green light
#   on the node stays green. That is the exact shape this project has hit repeatedly: a component
#   reporting confidently on something it cannot observe.
#
# WHAT IT CHECKS, by RUNNING the real functions against a throwaway root with a recording iptables stub
#   1. The range is parsed, and a malformed or out-of-bounds one yields NOTHING rather than a rule.
#   2. With a range configured, a redirect is installed covering it and targeting the served port.
#   3. Changing the range REPLACES the old rule — reconcile, not merely add.
#   4. Clearing the range REMOVES the rule; an obsolete redirect must not survive.
#   5. verify fails when the rule is absent, when it covers a different range, and when it points at a
#      different port. Each of those is a live outage that nothing else would report.
#   6. verify passes trivially when no range is advertised — nothing promised, nothing to keep.
#
# OFFLINE. No root. Nothing outside its own mktemp root.
# Exit: 0 = the promise is kept and its absence is noticed; 1 = it is not; 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'hy2_hop_redirect_kept: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_harden.sh"
# common.sh, because nb_harden.sh now DELEGATES the hop-range decision to the single shell
# comparator that lives there (ADR-0038). Sourcing the lib without it made _hy2_hop_range call an
# undefined function, so every row read "no range" and the gate was testing a different program —
# this project's own recurring test defect, arriving through a new dependency rather than a new gate.
COMMON="$REPO_ROOT/control/lib/common.sh"
VOCAB="$REPO_ROOT/control/vocab.json"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
for f in "$LIB" "$COMMON" "$VOCAB" "$FIXTURE"; do
	[ -f "$f" ] || { printf 'hy2_hop_redirect_kept: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'hy2_hop_redirect_kept: jq required\n' >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== hysteria2 port hopping: is the promise the client config makes actually kept ==\n'

log()  { :; }
warn() { :; }
die()  { printf 'lib: %s\n' "$*" >&2; exit 1; }
run()  { "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }

# A STATEFUL iptables stub: -A appends to a rule file, -D removes a matching line, -S prints them. The
# state is what makes reconcile observable — an add-only stub could not tell "replaced" from "added".
install_ipt_stub() {
	cat >"$STUBDIR/iptables" <<'STUB'
#!/usr/bin/env bash
# One file PER FAMILY, keyed on the tool name: reconcile installs an IPv4 rule and an IPv6
# twin, and a shared file cannot tell "one per family" from "two of one".
case "$0" in *ip6tables) f="${FAKENODE_ROOT:?}/nat6.rules" ;; *) f="${FAKENODE_ROOT:?}/nat.rules" ;; esac
: >>"$f"
args=("$@"); out=(); tbl=""; act=""; chain=""
i=0
while [ $i -lt ${#args[@]} ]; do
	case "${args[$i]}" in
		-t) tbl="${args[$((i+1))]}"; i=$((i+2)) ;;
		-A|-D|-S) act="${args[$i]}"; chain="${args[$((i+1))]:-}"; i=$((i+2)) ;;
		*) out+=("${args[$i]}"); i=$((i+1)) ;;
	esac
done
[ "$tbl" = nat ] || exit 0
case "$act" in
	-S) sed "s|^|-A $chain |" "$f" ;;
	-A) printf '%s\n' "${out[*]}" >>"$f" ;;
	-D) grep -vxF "${out[*]}" "$f" >"$f.n" 2>/dev/null; mv "$f.n" "$f" ;;
esac
exit 0
STUB
	chmod +x "$STUBDIR/iptables"
	# ip6tables shares the stub: reconcile now installs an IPv6 twin (Audit-0010 F-010a) and verify
	# checks it. Without this the fixture has no v6 tool, `have ip6tables` is false, and every v6 row
	# would be skipped — the gate would pass while testing only half the program it claims to cover.
	cp "$STUBDIR/iptables" "$STUBDIR/ip6tables"
	chmod +x "$STUBDIR/ip6tables"
	: >"$FAKENODE_ROOT/nat6.rules"
	cat >"$STUBDIR/ip" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = route ] && printf 'default via 10.0.0.1 dev eth0 proto static\n'
exit 0
STUB
	chmod +x "$STUBDIR/ip"
}

seed() { # RANGE_OR_EMPTY  LISTEN_PORT
	jq -n --arg r "$1" --argjson p "$2" \
		'{hysteria2_enabled:true, hysteria2_port:$p} + (if $r != "" then {hysteria2_hop_ports:$r} else {} end)' \
		> "$FAKENODE_ROOT/params.json"
	PARAMS_JSON="$FAKENODE_ROOT/params.json"
}

# --- 1. parsing: a malformed range must yield nothing, never a rule ---------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_ipt_stub
	# shellcheck source=/dev/null
	. "$COMMON"
	MYC_VOCAB="$VOCAB"
	# shellcheck source=/dev/null
	. "$LIB"
	for row in "20000:21000|20000:21000" "|" "abc|" "20000|" "0:100|" "5000:4000|" "1000:70000|" "20000:21000:5|"; do
		want="${row##*|}"; r="${row%%|*}"
		seed "$r" 8444
		got="$(_hy2_hop_range)"
		[ "$got" = "$want" ] \
			&& ok "range '$r' -> '${got:-<none>}'" \
			|| badln "range '$r' resolved to '${got}', expected '${want:-<none>}'. Whatever this returns becomes a firewall rule; a malformed value must yield NO rule rather than a wrong one."
	done
	exit "$fail"
) || fail=1

# --- 2-4. install, replace, remove -------------------------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_ipt_stub
	# shellcheck source=/dev/null
	. "$COMMON"
	MYC_VOCAB="$VOCAB"
	# shellcheck source=/dev/null
	. "$LIB"

	seed "20000:21000" 8444
	reconcile_hy2_hop_nat
	# `grep -c` prints 0 AND exits 1 on no match, so a `|| printf 0` fallback yields "0\n0" and every
	# comparison below silently reads a two-line string. Capture plainly; default only the empty case.
	n="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat.rules" 2>/dev/null)"; n="${n:-0}"
	n6="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat6.rules" 2>/dev/null)"; n6="${n6:-0}"
	{ [ "$n" = "1" ] && [ "$n6" = "1" ]; } \
		&& ok "a configured range installs exactly one redirect PER FAMILY (v4 + v6)" \
		|| badln "expected one redirect per family, found v4=$n v6=$n6. The inbounds listen on '::' and resolve_node_address falls back to IPv6, so a node with only the v4 rule hands every v6 client a range backed by nothing — and the v4-only verifier used to call that verified."
	grep -qF -- '--dport 20000:21000' "$FAKENODE_ROOT/nat.rules" && grep -qF -- '--to-ports 8444' "$FAKENODE_ROOT/nat.rules" \
		&& ok "it covers the advertised range and targets the served port" \
		|| badln "the redirect does not cover 20000:21000 -> 8444: $(cat "$FAKENODE_ROOT/nat.rules")"

	seed "30000:31000" 8444
	reconcile_hy2_hop_nat
	# `grep -c` prints 0 AND exits 1 on no match, so a `|| printf 0` fallback yields "0\n0" and every
	# comparison below silently reads a two-line string. Capture plainly; default only the empty case.
	n="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat.rules" 2>/dev/null)"; n="${n:-0}"
	n6="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat6.rules" 2>/dev/null)"; n6="${n6:-0}"
	if [ "$n" = "1" ] && [ "$n6" = "1" ] && grep -qF -- '--dport 30000:31000' "$FAKENODE_ROOT/nat.rules" \
	   && grep -qF -- '--dport 30000:31000' "$FAKENODE_ROOT/nat6.rules"; then
		ok "changing the range REPLACES the rule (reconcile, not append)"
	else
		badln "after a range change there are v4=$n v6=$n6 rules. harden_ufw only ever ADDS, so an obsolete redirect would keep sending an old range at a port — this one must reconcile."
	fi

	# COLLISION (Audit-0010 F-001): a range that CONTAINS another served UDP port must not become a rule.
	# A REDIRECT over it swallows every inbound packet for that family, and no check on the node can see
	# the loss — the reach probes anchor on 127.0.0.1 and loopback never traverses a `-i wan` PREROUTING
	# rule, so the measure daemon keeps scoring the dead family alive and the planner can promote it.
	jq -n '{hysteria2_enabled:true, hysteria2_port:8444, tuic_port:8445, hysteria2_hop_ports:"8000:9000"}' >"$FAKENODE_ROOT/params.json"
	PARAMS_JSON="$FAKENODE_ROOT/params.json"
	: >"$FAKENODE_ROOT/nat.rules"
	reconcile_hy2_hop_nat >/dev/null 2>&1
	n="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat.rules" 2>/dev/null)"; n="${n:-0}"
	[ "$n" = "0" ] \
		&& ok "a range CONTAINING another served UDP port installs no redirect (fail-closed)" \
		|| badln "a redirect was installed for a range that swallows tuic's own port. Every inbound tuic packet is now sent to the hysteria2 listener, tuic is dead for the whole population, and nothing on the node reports it: the reach anchors are loopback and never traverse PREROUTING, so the planner may promote the dead family as its safe fallback."

	seed "" 8444
	reconcile_hy2_hop_nat
	# `grep -c` prints 0 AND exits 1 on no match, so a `|| printf 0` fallback yields "0\n0" and every
	# comparison below silently reads a two-line string. Capture plainly; default only the empty case.
	n="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat.rules" 2>/dev/null)"; n="${n:-0}"
	n6="$(grep -cF 'myc-hy2-hop' "$FAKENODE_ROOT/nat6.rules" 2>/dev/null)"; n6="${n6:-0}"
	{ [ "$n" = "0" ] && [ "$n6" = "0" ]; } && ok "clearing the range removes BOTH redirects" \
		|| badln "an obsolete redirect survived the range being cleared ($n rules) — it keeps redirecting a range nothing advertises"
	exit "$fail"
) || fail=1

# --- 5-6. the verification must NOTICE ---------------------------------------------------------------
(
	set -u
	fail=0
	fakenode_init
	install_ipt_stub
	# shellcheck source=/dev/null
	. "$COMMON"
	MYC_VOCAB="$VOCAB"
	# shellcheck source=/dev/null
	. "$LIB"

	seed "" 8444
	verify_hy2_hop_nat >/dev/null 2>&1 \
		&& ok "no range advertised: nothing promised, verification passes" \
		|| badln "verification failed when no range is configured"

	seed "20000:21000" 8444
	: >"$FAKENODE_ROOT/nat.rules"
	verify_hy2_hop_nat >/dev/null 2>&1 \
		&& badln "the range is advertised to every client and NO redirect exists, yet verification passed. This is the outage nothing else on the node can see: loopback probes do not traverse PREROUTING, so every other check stays green." \
		|| ok "an advertised range with no redirect FAILS verification"

	printf 'eth0 -p udp -m udp --dport 30000:31000 -m comment --comment myc-hy2-hop -j REDIRECT --to-ports 8444\n' >"$FAKENODE_ROOT/nat.rules"
	verify_hy2_hop_nat >/dev/null 2>&1 \
		&& badln "a redirect covering a DIFFERENT range passed verification — clients hop across 20000:21000 and reach nothing" \
		|| ok "a redirect covering the wrong range FAILS verification"

	printf 'eth0 -p udp -m udp --dport 20000:21000 -m comment --comment myc-hy2-hop -j REDIRECT --to-ports 9999\n' >"$FAKENODE_ROOT/nat.rules"
	verify_hy2_hop_nat >/dev/null 2>&1 \
		&& badln "a redirect pointing at a port nothing serves passed verification" \
		|| ok "a redirect pointing at the wrong port FAILS verification"

	# v4 CORRECT, v6 MISSING — the exact state a node was left in before the twin existed, and the state
	# the IPv4-only verifier used to call "verified" (Audit-0010 F-010a).
	printf 'eth0 -p udp -m udp --dport 20000:21000 -m comment --comment myc-hy2-hop -j REDIRECT --to-ports 8444\n' >"$FAKENODE_ROOT/nat.rules"
	: >"$FAKENODE_ROOT/nat6.rules"
	verify_hy2_hop_nat >/dev/null 2>&1 \
		&& badln "the IPv4 redirect alone passed verification. The inbounds listen on '::' and resolve_node_address falls back to a global IPv6 address, so on such a node every client dials v6, no rule backs the range, and this is precisely the outage nothing else can see." \
		|| ok "an IPv4-only redirect FAILS verification (the IPv6 twin is required)"

	printf 'eth0 -p udp -m udp --dport 20000:21000 -m comment --comment myc-hy2-hop -j REDIRECT --to-ports 8444\n' >"$FAKENODE_ROOT/nat6.rules"
	verify_hy2_hop_nat >/dev/null 2>&1 \
		&& ok "both families correct: verification passes" \
		|| badln "a correct redirect pair was rejected — the check would fail every healthy converge"
	exit "$fail"
) || fail=1

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the hysteria2 hop range is advertised without the rule that makes it real, or its absence goes unnoticed.\n' >&2
	exit 1
fi
printf 'PASS: the redirect follows the advertised range, and every way of losing it is reported.\n'
exit 0
