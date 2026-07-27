#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# ss_l7_probe_failsafe.sh — conformance: the standalone Shadowsocks-2022 L7 liveness probe
# (`_l7_probe_shadowsocks_dial` in control/lib/nb_selftest.sh) may declare the LAST-RESORT transport DEAD
# only on POSITIVE evidence, judges by a data ROUND TRIP rather than an exit status, and reaches its
# target without leaving the host.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   This probe is the one family whose verdict cannot be read off a handshake: SS-2022 completes none, so
#   the criterion every other family uses ("the connection was still open when the timeout killed it")
#   reads ALIVE against a listener whose key no longer matches. The probe therefore judges on BYTES
#   returned through the tunnel from a target that speaks first — and that criterion has two failure modes
#   a future edit could reintroduce silently, both of which fault the transport a planner reaches only
#   when nothing safer is viable:
#     * A NO-BYTES result treated as DEAD without first proving the target itself is fine. Silence inside
#       the tunnel is ambiguous (dead listener vs. no sshd vs. a firewalled hairpin); only the CONTROL
#       dial over a plain `direct` outbound disambiguates it. Drop the control and every node without a
#       reachable banner-first target starts rotating off a healthy last resort.
#     * A PRIVATE target address. The served config blocks private destinations (`ip_is_private -> block`)
#       while the probe's own config carries no route rules — so a private target would be blocked in the
#       tunnel and succeed in the control, manufacturing a false DEAD on a healthy listener.
#   A third, subtler one is pinned because it already cost three wrong "SS liveness is unmeasurable"
#   verdicts: SS-2022 flushes its request header only with the FIRST PAYLOAD, so an EMPTY-stdin dial (the
#   idiom every TLS-family probe here uses) never sends the header and reads DEAD on a healthy listener.
#
# WHAT THIS CHECKS (over control/lib/nb_selftest.sh, bash comments stripped)
#   1. WIRED: the probe exists, and measure_l7_probe dispatches it for the shadowsocks type behind the
#      same 3-attempt retry-debounce as its siblings, folding a non-1 verdict as NOT-dead.
#   2. DEAD IS CONTROL-GATED: `_l7_probe_shadowsocks_dial` has exactly ONE `return 1`, and it is on the
#      line guarded by the control dial over a `direct` outbound.
#   3. FAIL-SAFE OTHERWISE: every other terminal path returns 2 (cannot-judge); the probe never exits.
#   4. BYTE CRITERION: the verdict is the SIZE of the captured output, never the dial's exit status (no
#      `124`/`$?` classification in the region).
#   5. PAYLOAD PRESENT: the dial feeds a non-empty stdin and the empty-stdin idiom (`: |`) is absent.
#   6. TARGET PROVENANCE: the target host comes from `_l7_own_public_addr` and from nothing else — never
#      params/node_address, a cover host, or a peer/member reference.
#   7. PRIVATE-ADDRESS REJECTION: `_l7_own_public_addr` rejects loopback/RFC1918/link-local/CGNAT and
#      accepts only IPv6 global unicast.
#   8. OWN LISTENER OVER LOOPBACK: the reconstructed client dials its own SS listener at 127.0.0.1 (only
#      the TARGET is public), and the credential is taken from the LIVE config.
#   9. NO OFF-HOST CONTACT: the region opens no network client of its own and names no external host.
#  10. DETOUR NOT ENROLLED: the shadowsocks enrolment clause requires a wildcard `listen` + a real port, so
#      the ShadowTLS inbound's hidden loopback inner SS is never probed as a served family.
#
# OFFLINE + INSPECT-ONLY. Exit: 0 = fail-safe, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'ss_l7_probe_failsafe: cannot resolve repo root\n' >&2; exit 2; }

SRC="${MYC_SS_PROBE_SRC:-$REPO_ROOT/control/lib/nb_selftest.sh}"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== standalone-Shadowsocks L7 probe fail-safe check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

[ -f "$SRC" ] || { printf 'FAIL: probe source not found: %s\n' "$SRC" >&2; exit 2; }

# The SS-probe REGION = the three functions the probe is built from, delimited by the first
# (_l7_own_public_addr) and the consumer that follows them (measure_l7_probe). Fail closed if the
# delimiters move: a refactor must re-confirm this gate rather than silently check nothing.
region="$(awk '/^_l7_own_public_addr\(\)/{f=1} /^measure_l7_probe\(\)/{f=0} f' "$SRC")"
if [ -z "$region" ] \
	|| ! printf '%s' "$region" | grep -q '_l7_connect_bytes()' \
	|| ! printf '%s' "$region" | grep -q '_l7_probe_shadowsocks_dial()'; then
	printf 'FAIL: could not delimit the SS-probe region (_l7_own_public_addr .. measure_l7_probe) — the\n' >&2
	printf '      boundary markers moved; re-confirm this gate.\n' >&2
	exit 1
fi

# Strip bash comments (full-line and trailing) so prose can neither create a false hit nor hide a real
# violation. Then carve out the two function bodies the per-check assertions need.
strip_comments() { sed -E 's/(^|[[:space:]])#.*$/\1/'; }
region_nc="$(printf '%s\n' "$region" | strip_comments)"
probe_fn="$(printf '%s\n' "$region_nc" | awk 'index($0,"_l7_probe_shadowsocks_dial()"){f=1} f{print} f&&/^\}/{f=0}')"
addr_fn="$(printf '%s\n' "$region_nc"  | awk 'index($0,"_l7_own_public_addr()"){f=1}     f{print} f&&/^\}/{f=0}')"
bytes_fn="$(printf '%s\n' "$region_nc" | awk 'index($0,"_l7_connect_bytes()"){f=1}       f{print} f&&/^\}/{f=0}')"
consumer="$(awk '/^measure_l7_probe\(\)/{f=1} f{print} f&&/^\}/{f=0}' "$SRC" | strip_comments)"

for pair in "probe_fn:_l7_probe_shadowsocks_dial" "addr_fn:_l7_own_public_addr" "bytes_fn:_l7_connect_bytes"; do
	v="${pair%%:*}"; n="${pair#*:}"
	eval "body=\$$v"
	[ -n "$body" ] || { printf 'FAIL: could not extract the body of %s.\n' "$n" >&2; exit 1; }
done
[ -n "$consumer" ] || { printf 'FAIL: could not extract measure_l7_probe.\n' >&2; exit 1; }

# 1. WIRED into the cadenced probe, behind the sibling retry-debounce.
if printf '%s' "$consumer" | grep -q '_l7_probe_shadowsocks_dial'; then
	ok "measure_l7_probe dispatches _l7_probe_shadowsocks_dial"
else
	badln "measure_l7_probe never calls _l7_probe_shadowsocks_dial — the probe is dead code and standalone SS is back to an L4-only verdict"
fi
if printf '%s' "$consumer" | grep -qE '\[ "\$type" = "shadowsocks" \]'; then
	ok "the shadowsocks type has its own branch (not folded into a TLS criterion)"
else
	badln "no explicit shadowsocks branch in measure_l7_probe — SS must NOT be judged by a TLS/QUIC criterion (it has no observable handshake)"
fi
ss_branch="$(printf '%s\n' "$consumer" | awk '/\[ "\$type" = "shadowsocks" \]/{f=1} f{print} f&&/^\t\telif|^\t\telse/{if(++n>1)f=0}' | head -20)"
if printf '%s' "$ss_branch" | grep -q 'for attempt in 1 2 3' \
	&& printf '%s' "$ss_branch" | grep -q '\-ne 1'; then
	ok "the branch retry-debounces (3 attempts) and folds a non-1 verdict as NOT dead (cannot-judge never rotates)"
else
	badln "the shadowsocks branch lost its 3-attempt debounce or its '-ne 1' fold — a one-off blip, or a cannot-judge, would write a dead marker"
fi

# 2. DEAD IS CONTROL-GATED: exactly one `return 1`, on the control-dial line.
r1_count="$(printf '%s\n' "$probe_fn" | grep -cE '(^|[[:space:];&|]|then[[:space:]])return 1' || true)"
r1_line="$(printf '%s\n' "$probe_fn" | grep -E '(^|[[:space:];&|]|then[[:space:]])return 1' | head -1)"
if [ "$r1_count" = "1" ]; then
	ok "_l7_probe_shadowsocks_dial has exactly one DEAD path"
else
	badln "_l7_probe_shadowsocks_dial has $r1_count 'return 1' paths — every DEAD verdict must go through the single control-gated one"
fi
if printf '%s' "$r1_line" | grep -q '_l7_connect_bytes' \
	&& printf '%s' "$r1_line" | grep -q '"type":"direct"'; then
	ok "the DEAD verdict is gated on the CONTROL dial (a plain direct outbound reaching the same target)"
else
	badln "the DEAD verdict is not guarded by a control dial over a direct outbound — silence inside the tunnel is ambiguous, and an unusable target would fault a healthy last-resort transport"
fi
# The control dial must be the SECOND dial: a control that ran first and short-circuited would change the
# meaning of the tunnel result.
if [ "$(printf '%s\n' "$probe_fn" | grep -c '_l7_connect_bytes' || true)" = "2" ] \
	&& printf '%s\n' "$probe_fn" | grep '_l7_connect_bytes' | head -1 | grep -q '"\$ob"'; then
	ok "exactly two dials: the tunnel dial first (ALIVE short-circuits), the control dial only on silence"
else
	badln "the probe does not make exactly two dials with the TUNNEL dial first — the healthy path must cost one dial and the control must only disambiguate silence"
fi

# 3. FAIL-SAFE OTHERWISE.
if [ "$(printf '%s\n' "$probe_fn" | grep -cE '(^|[[:space:];&|]|then[[:space:]])return 2' || true)" -ge 4 ]; then
	ok "every precondition failure returns 2 (cannot-judge), never 1"
else
	badln "too few cannot-judge exits in _l7_probe_shadowsocks_dial — a missing tool, a missing public address or a malformed inbound must yield 2, never a dead verdict"
fi
if printf '%s\n' "$probe_fn$bytes_fn$addr_fn" | grep -qE '(^|[[:space:];&|])exit[[:space:]]+[0-9]'; then
	badln "the probe region calls exit — a probe must return a verdict, never terminate the entrypoint mid-run (the marker would never be written)"
else
	ok "the region never exits (a verdict is always returned to the caller)"
fi

# 4. BYTE CRITERION, not exit status.
if printf '%s' "$bytes_fn" | grep -q '\-s "\$tmpo"'; then
	ok "_l7_connect_bytes judges by the SIZE of the captured output (a data round trip)"
else
	badln "_l7_connect_bytes no longer judges by captured-output size — SS-2022 holds the connection open whether or not the key matches, so anything else reads ALIVE on a dead listener"
fi
if printf '%s\n' "$bytes_fn$probe_fn" | grep -qE '\b124\b|\$\?'; then
	badln "the SS probe classifies on an exit status (124/\$?) — that is the TLS-family criterion and it is FALSE-ALIVE for Shadowsocks"
else
	ok "no exit-status classification in the SS path"
fi

# 5. PAYLOAD PRESENT (the empty-stdin regression).
# A payload is present iff the stdin producer piped into the dial is a printf with a NON-EMPTY format
# string (`printf '` immediately followed by anything but the closing quote). Deliberately not pinned to
# one exact byte — what must never regress is that SOMETHING is sent before the read.
if printf '%s' "$bytes_fn" | grep -qE "printf '[^']" \
	&& printf '%s' "$bytes_fn" | grep -q 'tools connect'; then
	ok "the dial feeds a non-empty payload (SS-2022 flushes its request header only with the first payload)"
else
	badln "_l7_connect_bytes does not send a payload before reading — SS-2022 never flushes its request header on an empty stdin, so a HEALTHY listener reads dead"
fi
if printf '%s' "$bytes_fn" | grep -qE '^[[:space:]]*: \|'; then
	badln "_l7_connect_bytes uses the empty-stdin idiom (': |') — correct for the TLS families, fatal here"
else
	ok "the empty-stdin idiom is absent from the SS dial"
fi

# 6. TARGET PROVENANCE.
if printf '%s' "$probe_fn" | grep -q '_l7_own_public_addr'; then
	ok "the target host is resolved by _l7_own_public_addr"
else
	badln "the probe does not resolve its target through _l7_own_public_addr — the target must be an address this host itself holds"
fi
if printf '%s' "$probe_fn" | grep -qE 'node_address|PARAMS_JSON|handshake\.server|\.dest|MEMBER|peer'; then
	badln "the probe derives its target from params/a cover host/a peer reference — an operator-settable hostname may point at a front or another host, and a peer/member target would make this a client-vantage probe (ADR-0036 forbids both)"
else
	ok "no params / cover-host / peer-reference target provenance"
fi

# 7. PRIVATE-ADDRESS REJECTION.
missing=""
for pat in '10\.\*' '127\.\*' '169\.254\.\*' '192\.168\.\*' '172\.1\[6-9\]\.\*' '100\.6\[4-9\]\.\*'; do
	printf '%s' "$addr_fn" | grep -q "$pat" || missing="$missing $pat"
done
if [ -z "$missing" ]; then
	ok "_l7_own_public_addr rejects loopback, RFC1918, link-local and CGNAT candidates"
else
	badln "_l7_own_public_addr no longer rejects:$missing — a private target is blocked by the served config's ip_is_private rule but NOT by the probe's own config, so it manufactures a false DEAD"
fi
if printf '%s' "$addr_fn" | grep -qE 'case "\$a" in 2\*\|3\*'; then
	ok "IPv6 candidates are restricted to global unicast 2000::/3 (ULA and link-local rejected)"
else
	badln "the IPv6 candidate filter no longer restricts to global unicast — a ULA (fd00::/8) target is private and would manufacture a false DEAD"
fi

# 8. OWN LISTENER OVER LOOPBACK + live credential.
if printf '%s' "$probe_fn" | grep -q 'server:"127.0.0.1"'; then
	ok "the reconstructed client dials the node's OWN SS listener over loopback (only the target is public)"
else
	badln "the probe no longer dials its own listener at 127.0.0.1 — the listener leg must stay loopback"
fi
if printf '%s' "$probe_fn" | grep -q 'SINGBOX_CONFIG' && printf '%s' "$probe_fn" | grep -q 'users\[0\]\.password'; then
	ok "the credential is reconstructed from the LIVE config, in the multi-user server_psk:user_psk form"
else
	badln "the probe does not build its credential from the live config in the multi-user form — a server-PSK-only password is REJECTED exactly like a wrong key, so the 'correct' arm would fail for the same reason as a dead listener and the probe would prove nothing"
fi

# 9. NO OFF-HOST CONTACT.
if printf '%s' "$region_nc" | grep -qE '(^|[[:space:];&|(])(curl|wget|nc|ncat|socat|dig|nslookup|host|ping|ssh|scp|python[0-9.]*)[[:space:]]'; then
	badln "the SS-probe region opens a network client of its own — the only permitted egress is the sing-box dial to an address this host holds (ADR-0036: no third-party beacon)"
else
	ok "the region opens no network client of its own"
fi
if printf '%s' "$region_nc" | grep -qE '(https?|wss?)://|[a-z0-9-]+\.(com|net|org|io|ru|cloud|host)\b'; then
	badln "the SS-probe region names an external host/URL — the probe is node-local by construction"
else
	ok "no external host or URL appears in the region"
fi

# 10. THE SHADOWTLS DETOUR IS NOT ENROLLED AS A SERVED FAMILY.
enrol="$(grep -n 'type=="shadowsocks"' "$SRC" | grep -v '^\s*#' | head -3)"
if printf '%s' "$enrol" | grep -q 'listen_port != null' && printf '%s' "$enrol" | grep -q '0\\\\.0\\\\.0\\\\.0'; then
	ok "the enrolment clause requires a wildcard listen + a real port (the ShadowTLS inner loopback SS is excluded)"
else
	badln "the shadowsocks enrolment clause no longer requires a public wildcard listener — the ShadowTLS inbound's hidden loopback inner SS would be probed as if it were a served family (it has no listen_port, so it would read dead forever)"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the standalone-Shadowsocks L7 probe is not fail-safe. It governs the LAST-RESORT exposure\n' >&2
	printf '      tier (spec.ExposureNoCover) — a false DEAD there removes the transport a node falls back to\n' >&2
	printf '      when nothing safer is viable, and a false ALIVE lets the planner rotate onto a dead one.\n' >&2
	exit 1
fi
printf 'PASS: the SS probe judges by a data round trip, marks dead only behind a control dial that proves\n'
printf '      its target is usable, rejects private targets, and contacts nothing off-host (ADR-0036).\n'
exit 0
