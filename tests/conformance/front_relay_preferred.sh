#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# front_relay_preferred.sh — conformance: the inert CDN/ingress FRONT schema (internal/spec/front.go,
# ADR-0033 extends ADR-0029) keeps its CLOSED vocabulary and its doctrine invariants.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   An operator-provided CDN/ingress front is OPTIONAL and bring-your-own-domain, but it carries two
#   load-bearing doctrine rules that must not erode: (1) it is RELAY-PREFERRED — a TLS-terminating edge
#   sees the user's source address + destination hostnames (a metadata leak THREAT-MODEL calls "worse
#   than neutral"), so `terminate` is allowed only with an explicit acknowledgement, never a silent
#   default; (2) it may sit in front of ONLY the genuine-single-TLS own-cert HTTP transports
#   (vless-xhttp-tls / vless-ws-tls) — REALITY/raw/UDP cannot be fronted. This gate pins those at the
#   conformance layer so the discipline holds even where `go test` does not run (the offline suite).
#   OFFLINE + INSPECT-ONLY (the `go test` half runs only where a Go toolchain is present).
#
# WHAT THIS CHECKS (over internal/spec/front.go)
#   1. The schema source exists.
#   2. FrontMode is a CLOSED enum: exactly {relay, terminate} members + the unknown zero value + IsValid.
#   3. The frontable set is EXACTLY {vless-xhttp-tls, vless-ws-tls} and contains NO REALITY/raw/UDP proto.
#   4. Validate enforces the invariants: relay-default (EffectiveMode), terminate-needs-ack, a
#      domain-required-when-enabled check, and a frontable-only check.
#   5. The efficacy framing is recorded in the schema (complementary/last-resort, NOT a destination-class
#      throttle fix) so the option is never mistaken for the answer THREAT-MODEL documents it is not.
#   6. If Go is present, `go test ./internal/spec -run 'Front'` passes (the real invariant proof).
#
# Greps strip // line-comments for "does this CODE exist" checks, so a doc mention cannot satisfy a
# code assertion and a reformat cannot spuriously fail it.
#
# Exit: 0 = closed vocabulary + relay-preferred invariants intact, 1 = a violation, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'front_relay_preferred: cannot resolve repo root\n' >&2; exit 2; }
FC_GO="$REPO_ROOT/internal/spec/front.go"

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

fc_code() { sed -e 's://.*$::' "$FC_GO"; }

printf '== CDN/ingress front schema closed-vocab + relay-preferred check (internal/spec/front.go, ADR-0033) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

# 1. schema present
if [ -f "$FC_GO" ]; then
	ok "front schema present: internal/spec/front.go"
else
	printf 'FAIL: internal/spec/front.go is missing (the front schema is the closed-vocab anchor).\n' >&2
	exit 1
fi

# 2. FrontMode closed enum
check_mode() { # NAME VALUE
	if fc_code | grep -qE "^[[:space:]]*$1[[:space:]]+FrontMode[[:space:]]*=[[:space:]]*\"$2\"[[:space:]]*$"; then
		ok "FrontMode member present: $1"
	else
		badln "FrontMode member missing/misformatted: $1 = \"$2\""
	fi
}
check_mode FrontModeRelay relay
check_mode FrontModeTerminate terminate
n_modes="$(fc_code | grep -cE '^[[:space:]]*FrontMode[A-Za-z]+[[:space:]]+FrontMode[[:space:]]*=[[:space:]]*"')"
if [ "$n_modes" = "3" ]; then
	ok "FrontMode has exactly relay + terminate + the unknown zero value (no drift)"
else
	badln "FrontMode has $n_modes declared values (want 3: unknown + relay + terminate)"
fi
fc_code | grep -qE 'func \(m FrontMode\) IsValid\(\) bool' && ok "FrontMode.IsValid present (closed enum)" || badln "FrontMode.IsValid() missing"

# 3. frontable set is EXACTLY the two genuine-TLS own-cert HTTP transports, no REALITY/raw/UDP
fset="$(fc_code | awk '/frontableProtos[[:space:]]*=[[:space:]]*map\[string\]bool/{f=1} f{print} /^}/{if(f){exit}}')"
printf '%s\n' "$fset" | grep -qE '"vless-xhttp-tls"[[:space:]]*:[[:space:]]*true' && ok "frontable: vless-xhttp-tls" || badln "vless-xhttp-tls not in the frontable set"
printf '%s\n' "$fset" | grep -qE '"vless-ws-tls"[[:space:]]*:[[:space:]]*true'    && ok "frontable: vless-ws-tls"    || badln "vless-ws-tls not in the frontable set"
n_front="$(printf '%s\n' "$fset" | grep -cE '"[a-z0-9-]+"[[:space:]]*:[[:space:]]*true')"
if [ "$n_front" = "2" ]; then
	ok "frontable set has exactly 2 members (no drift toward fronting un-frontable transports)"
else
	badln "frontable set has $n_front members (want exactly 2: vless-xhttp-tls, vless-ws-tls)"
fi
if printf '%s\n' "$fset" | grep -qE 'reality|hysteria2|tuic|shadowsocks|shadowtls|trojan|amneziawg'; then
	badln "a REALITY/raw/UDP transport leaked into the frontable set (it cannot be fronted)"
else
	ok "no REALITY/raw/UDP transport in the frontable set"
fi
fc_code | grep -qE 'func IsFrontableTransport\(proto string\) bool' && ok "IsFrontableTransport present" || badln "IsFrontableTransport missing"

# 4. Validate invariants
fc_code | grep -qE 'func \(c FrontConfig\) Validate\(\) error' && ok "FrontConfig.Validate present" || badln "FrontConfig.Validate missing"
# relay-default: EffectiveMode maps the unknown sentinel to relay
if fc_code | grep -A4 -E 'func \(c FrontConfig\) EffectiveMode\(\) FrontMode' | grep -qE 'return FrontModeRelay'; then
	ok "relay is the default (EffectiveMode maps empty -> relay)"
else
	badln "EffectiveMode does not default to relay (the doctrine-clean default is missing)"
fi
# terminate requires the explicit ack
if fc_code | grep -qE 'FrontModeTerminate[[:space:]]*&&[[:space:]]*!c\.AckTerminateTradeoff'; then
	ok "terminate requires an explicit ack (no silent TLS-terminating front / metadata leak)"
else
	badln "terminate is NOT gated on AckTerminateTradeoff (a silent terminate would be the documented metadata leak)"
fi
# enabled => domain required
if fc_code | grep -qE 'c\.Domain[[:space:]]*==[[:space:]]*""'; then
	ok "an enabled front requires the operator's own domain"
else
	badln "no domain-required check (bring-your-own-domain not enforced)"
fi
# enabled => frontable-only
if fc_code | grep -qE '!IsFrontableTransport\(c\.Transport\)'; then
	ok "an enabled front is restricted to a frontable transport"
else
	badln "no frontable-transport check (a front could be placed on REALITY/raw/UDP)"
fi

# 5. efficacy framing recorded in the schema
if grep -qiE 'last-resort|complementary' "$FC_GO" && grep -qiE 'NOT a fix|never[^.]*fix|two-hop is primary|destination-class' "$FC_GO"; then
	ok "the efficacy framing is recorded (complementary/last-resort, not a destination-class throttle fix)"
else
	badln "the efficacy framing is missing from the schema (the front must not be mistaken for the answer THREAT-MODEL says it is not)"
fi

# 6. Go test half (skip-if-no-Go)
if command -v go >/dev/null 2>&1; then
	if ( cd "$REPO_ROOT" && go test ./internal/spec -run 'Front' >/dev/null 2>&1 ); then
		ok "go test ./internal/spec -run Front passes (the real invariant proof)"
	else
		badln "go test ./internal/spec -run Front FAILED"
	fi
else
	printf 'SKIP (go test half): no Go toolchain — the closed-vocab + invariant greps above ran; on a Go host the tests run too.\n'
fi

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the front schema is closed, relay-preferred, frontable-only, and honestly framed (advisory, inert).\n'
	exit 0
fi
printf 'FAIL: the front schema drifted open, lost the relay-preferred / frontable-only invariant, or dropped its efficacy framing.\n' >&2
exit 1
