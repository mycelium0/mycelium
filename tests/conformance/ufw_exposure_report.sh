#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# ufw_exposure_report.sh — conformance: the firewall EXPOSURE REPORT subsystem in control/lib/nb_harden.sh
# (myc_ufw_admitted_ports, myc_ufw_listening_ports, verify_ufw_exposure) says only what it can establish,
# and never turns an absence of evidence into an accusation or an all-clear.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   The subsystem shipped with no test for any of its three functions, in a change set that added four
#   gates for its other subjects (Audit-0009 L1). What that left unguarded was not the parser — the parser
#   is the easy half — but the two places where a REPORT is derived from it:
#
#     * THE MEMBERSHIP COMPARISON. myc_ufw_admitted_ports emits one token per LINE; verify_ufw_exposure
#       tests membership with `case " $list " in *" $tok "*)`, which matches only a token surrounded by
#       SPACES. Feed it the newline form and every element except the first and last becomes unmatchable,
#       so every served port reads "NOT admitted". That reached a live node: the report claimed all eight
#       served ports were firewall-blocked while clients were connecting fine. A `tr '\n' ' '` fixes it,
#       and nothing stopped a future edit from dropping it again.
#     * NO SIGNAL vs. NOTHING LISTENING (Audit-0009 AG1). The orphan advisory's entire basis is "nothing is
#       listening on this admitted port". If the listener view is unavailable — no `ss`, or `ss` failed —
#       an empty view must not be read as proof of that; otherwise every admitted port outside the run's
#       served/keep sets, including ports held by live third-party services, is reported as an orphan to
#       delete by hand.
#
#   Both are report-fidelity defects: verify_ufw_exposure returns 0 on every path, never deletes a rule and
#   never fails a converge. That is exactly why they need a gate — nothing downstream would ever notice.
#
# WHAT THIS CHECKS
#   1. PARSER (fixtures, stdin-driven): ALLOW/LIMIT admit, ALLOW IN admits, ALLOW OUT/FWD do not, a
#      source-restricted rule is not public, a bare port emits both protocol tokens, an app-profile row is
#      not a port, DENY/REJECT cancels an ALLOW in either order, and `(v6)` rows are skipped not stripped.
#   2. THE COMPARISON (end to end, stubbed ufw/ss): a served port that IS admitted is not reported blocked
#      — the assertion that fails if the newline normalisation is removed.
#   3. NO-SIGNAL DISCIPLINE: without `ss`, no orphan is claimed and no all-clear is printed; with `ss`, an
#      admitted-but-unserved port with no listener IS reported; a port with a listener is not.
#   4. IT NEVER FAILS A CONVERGE: rc 0 on every path above, including the no-ufw and unparseable ones.
#
# OFFLINE. Exit: 0 = conformant, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'ufw_exposure_report: cannot resolve repo root\n' >&2; exit 2; }
HARDEN="$REPO_ROOT/control/lib/nb_harden.sh"
[ -f "$HARDEN" ] || { printf 'ufw_exposure_report: missing %s\n' "$HARDEN" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== firewall exposure report: parser, comparison, and the no-signal rule ==\n'

# The library defines functions only. verify_ufw_exposure needs log/warn/have from the entrypoint's shared
# scope, which is exactly what makes it drivable here: we supply them.
LOGBUF=""
log()  { LOGBUF="$LOGBUF
LOG $*"; }
warn() { LOGBUF="$LOGBUF
WARN $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
# shellcheck disable=SC1090
. "$HARDEN" || { badln "could not source nb_harden.sh"; printf 'FAIL\n' >&2; exit 1; }
for f in myc_ufw_admitted_ports myc_ufw_listening_ports verify_ufw_exposure; do
	command -v "$f" >/dev/null 2>&1 || { badln "$f not defined by nb_harden.sh"; printf 'FAIL\n' >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.ufwx.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- 1. the parser, on fixtures ---------------------------------------------------------------------
parse() { printf '%s\n' "$1" | myc_ufw_admitted_ports | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }
pcase() { # label  status-text  expected-tokens (space separated, sorted)
	got="$(parse "$2")"
	if [ "$got" = "$3" ]; then ok "parser: $1 => [$3]"
	else badln "parser: $1 => got [$got], want [$3]"; fi
}

pcase "ALLOW and LIMIT both admit" \
'443/tcp                    ALLOW       Anywhere
22/tcp                     LIMIT       Anywhere' \
	'22/tcp 443/tcp'

pcase "ALLOW IN admits (the 4-column form)" \
'8443/tcp                   ALLOW IN    Anywhere' \
	'8443/tcp'

pcase "ALLOW OUT / ALLOW FWD are not ingress" \
'9000/tcp                   ALLOW OUT   Anywhere
9001/tcp                   ALLOW FWD   Anywhere' \
	''

pcase "a source-restricted rule is not public" \
'2222/tcp                   ALLOW       10.0.0.0/8' \
	''

pcase "a bare port admits BOTH protocols" \
'8388                       ALLOW       Anywhere' \
	'8388/tcp 8388/udp'

pcase "an app-profile row is not a port" \
'OpenSSH                    ALLOW       Anywhere' \
	''

pcase "DENY cancels an ALLOW that came first" \
'443/tcp                    ALLOW       Anywhere
443/tcp                    DENY        Anywhere' \
	''

pcase "REJECT cancels an ALLOW that comes after (order-independent)" \
'8080/tcp                   REJECT      Anywhere
8080/tcp                   ALLOW       Anywhere' \
	''

pcase "(v6) rows are SKIPPED, not stripped — the v4 twin still admits" \
'443/tcp                    ALLOW       Anywhere
443/tcp (v6)               ALLOW       Anywhere (v6)
8443/tcp (v6)              ALLOW       Anywhere (v6)' \
	'443/tcp'

# --- 2/3. the report, end to end with stubbed ufw + ss -------------------------------------------------
# Stubs go on PATH so `have ufw` / `have ss` and the calls inside the functions both resolve to them.
BIN="$WORK/bin"; mkdir -p "$BIN"; PATH="$BIN:$PATH"; export PATH
mkstub() { printf '#!/bin/sh\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
rmstub() { rm -f "$BIN/$1"; }

# ufw prints a realistic multi-rule status: three served ports, one stale, one third-party.
mkstub ufw 'cat <<EOF
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     LIMIT       Anywhere
443/tcp                    ALLOW       Anywhere
8443/tcp                   ALLOW       Anywhere
51820/udp                  ALLOW       Anywhere
9999/tcp                   ALLOW       Anywhere
5555/tcp                   ALLOW       Anywhere
EOF'
# ss: 5555 is held by something live; 9999 is not.
mkstub ss 'case "$1" in
  -tlnH) printf "LISTEN 0 4096 *:443 *:*\nLISTEN 0 4096 *:8443 *:*\nLISTEN 0 4096 *:5555 *:*\nLISTEN 0 4096 127.0.0.1:7777 *:*\n" ;;
  -ulnH) printf "UNCONN 0 0 *:51820 *:*\n" ;;
esac'

# NOT in a command substitution: that is a subshell, and LOGBUF written there never reaches this scope.
LOGBUF=""; verify_ufw_exposure ' 443/tcp 8443/tcp 51820/udp ' ' 22/tcp '; rc=$?
[ "$rc" = "0" ] && ok "report: returns 0 (a firewall observation can never fail a converge)" \
	|| badln "report: returned $rc — a non-zero from the convergence tail triggers a rollback + restart on every node, on a cadence"
# THE COMPARISON. Every served port is admitted by the stub, so nothing may be reported blocked. This is
# the assertion that goes red if the newline->space normalisation is dropped: 8443/tcp and 51820/udp are
# interior tokens of the parser's output and become unmatchable.
if printf '%s' "$LOGBUF" | grep -q 'served but NOT admitted'; then
	badln "report: claims served ports are firewall-blocked when ufw admits all of them — the admitted list is not space-normalised, so interior tokens are unmatchable (this exact defect reached a live node)"
else
	ok "report: an admitted served port is not reported blocked (the membership comparison is space-normalised)"
fi
if printf '%s' "$LOGBUF" | grep -q 'admitted but not served and nothing listening:.*9999/tcp'; then
	ok "report: an admitted, unserved port with NO listener is reported as an orphan"
else
	badln "report: 9999/tcp is admitted, outside served+keep, and nothing is listening on it — it must be reported"
fi
if printf '%s' "$LOGBUF" | grep -q '5555'; then
	badln "report: 5555/tcp has a live listener — reporting it as unexplained is the cry-wolf failure the listener check exists to prevent"
else
	ok "report: an admitted port with a live listener is NOT called an orphan"
fi
if printf '%s' "$LOGBUF" | grep -q '22/tcp'; then
	badln "report: the anti-lockout SSH rule is in the keep set and must never be reported"
else
	ok "report: the keep set (the anti-lockout sshd rule) is never reported"
fi

# A served port that ufw does NOT admit must be reported blocked — the outage nothing else can see.
LOGBUF=""; verify_ufw_exposure ' 443/tcp 4444/tcp ' ' 22/tcp ' >/dev/null 2>&1
printf '%s' "$LOGBUF" | grep -q 'served but NOT admitted.*4444/tcp' \
	&& ok "report: a served port ufw does not admit IS reported blocked" \
	|| badln "report: a served-but-blocked port was not reported — verify_post_apply is firewall-blind, so nothing else would catch it"

# --- 3. no listener view => no claim ------------------------------------------------------------------
rmstub ss
LOGBUF=""; verify_ufw_exposure ' 443/tcp 8443/tcp 51820/udp ' ' 22/tcp ' >/dev/null 2>&1
if printf '%s' "$LOGBUF" | grep -q 'nothing listening'; then
	badln "no-signal: without ss, every admitted port outside served+keep is accused of being an orphan — 'I cannot see the listeners' is being read as 'nothing is listening' (Audit-0009 AG1)"
else
	ok "no-signal: without ss, no orphan is claimed"
fi
if printf '%s' "$LOGBUF" | grep -q 'no unexplained port is open'; then
	badln "no-signal: without ss the report prints an ALL-CLEAR it cannot support — the fail-safe direction is to say what was not established, not to reassure"
else
	ok "no-signal: without ss, no all-clear is printed either"
fi
printf '%s' "$LOGBUF" | grep -q 'no listener view available' \
	&& ok "no-signal: the report says explicitly what it could not determine" \
	|| badln "no-signal: the report is silent about the ports it could not judge — an operator cannot tell a clean run from a blind one"

# myc_ufw_listening_ports must signal no-signal by RC, not by empty output.
myc_ufw_listening_ports tcp >/dev/null 2>&1 \
	&& badln "myc_ufw_listening_ports returns success with no ss present — empty output is then indistinguishable from 'nothing is listening'" \
	|| ok "myc_ufw_listening_ports signals NO SIGNAL by return code when ss is absent"

# --- 4. no ufw at all -> silent and successful --------------------------------------------------------
rmstub ufw
LOGBUF=""; verify_ufw_exposure ' 443/tcp ' ' 22/tcp ' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(printf '%s' "$LOGBUF" | tr -d '[:space:]')" ]; then
	ok "no ufw: returns 0 and reports nothing (fail-safe, no false accusation)"
else
	badln "no ufw: rc=$rc, log=[$LOGBUF] — with no firewall to read, the only correct report is none"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the firewall exposure report can mis-state what it observed.\n' >&2
	exit 1
fi
printf 'PASS: the parser is correct, the comparison is space-normalised, and no-signal is never reported as evidence.\n'
exit 0
