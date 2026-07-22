#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fp_ab_probe_producer.sh — conformance (RP-0015 increment B, B1): the fingerprint A/B producer
# `measure_fp_ab_probe` (control/lib/nb_selftest.sh) resolves whether a client-DEAD verdict on a
# fingerprint-CARRYING member is caused by the CURRENT uTLS preset or by the transport underneath it, and
# does so as an ADVISORY own-marker producer that NEVER rotates. This gate pins both the behaviour (the four
# verdicts, walk-to-first-alive, the fail-safe) and the structural invariants (closed-vocab, no randomiser,
# same-listener A/B, own-marker, inert).
#
# It sources jqlib.sh + nb_selftest.sh with minimal stubs (have/warn/log) and STUBS the two live probes
# (donor_verify_reality / _l7_probe_shadowtls_dial) so the decision surface is exercised offline — no engine,
# no network. The live handshake behaviour is covered by the B4 arming drill.
#
# Exit: 0 = producer honours its contract, 1 = a behaviour/invariant violated, 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
NS="$REPO_ROOT/control/lib/nb_selftest.sh"
VOCAB="$REPO_ROOT/control/vocab.json"

printf '== fp A/B producer check (RP-0015 increment B, B1) ==\n'
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$NS" ] || { printf 'FAIL: nb_selftest.sh not found: %s\n' "$NS" >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# --- Part 1: structural invariants (grep the function body). -----------------------------------------
FN="$(awk '/^measure_fp_ab_probe\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$NS")"
[ -n "$FN" ] || { printf 'FAIL: could not extract measure_fp_ab_probe from nb_selftest.sh\n' >&2; exit 1; }

# The alternate presets come ONLY from the Go-owned closed vocab (control/vocab.json .client_fingerprints),
# with the current excluded — never a randomiser (principle 1: a unique JA4 is itself a tell).
printf '%s' "$FN" | grep -qF '.client_fingerprints[]?' && printf '%s' "$FN" | grep -qF 'select(. != $cur)' \
	&& okln "alternates are the closed vocab with current excluded" \
	|| badln "alternates are not derived from .client_fingerprints minus current"
if printf '%s' "$FN" | grep -qE '\$RANDOM|openssl rand|shuf|sort -R'; then
	badln "a randomiser feeds the preset choice (forbidden — closed-set only)"
else
	okln "no randomiser feeds the preset choice"
fi
# Same-listener A/B: the two arms differ ONLY in the appended fp arg (transport/dest/port held constant).
printf '%s' "$FN" | grep -qF 'donor_verify_reality "$suspect_dest" "$alt"' \
	&& printf '%s' "$FN" | grep -qF '_l7_probe_shadowtls_dial "$suspect_tag" "$suspect_port" "$alt"' \
	&& okln "same-listener A/B: arms vary only the uTLS preset arg, holding the transport constant" \
	|| badln "the A/B arms do not hold the transport constant while varying only the preset"
# Own advisory marker: writes fp_probe.json, only READS the l7 marker (never writes it), and is INERT.
printf '%s' "$FN" | grep -qF 'fp_probe.json' && okln "writes its OWN advisory marker (fp_probe.json)" \
	|| badln "does not write its own fp_probe.json marker"
if printf '%s' "$FN" | grep -qE '>[[:space:]]*"?\$l7marker|flow_rotate|apply_singbox|promote_config|rotate_'; then
	badln "the producer rotates/actuates or writes the L7 marker (must be inert, own-marker only)"
else
	okln "inert: never rotates/actuates and never writes the transport L7 marker"
fi
# Fingerprint-BLIND families (genuine-TLS ws-tls, QUIC hy2/tuic) are NOT A/B'd (openssl/insecure carry no uTLS).
if printf '%s' "$FN" | grep -qE 'ws-tls|hysteria2|tuic'; then
	badln "a fingerprint-blind family (ws-tls/hy2/tuic) leaked into the fp-carrying A/B set"
else
	okln "fingerprint-blind families (ws-tls/QUIC) are excluded from the A/B set"
fi

# --- Part 2: behavioural verdict table (source + stub + run). ----------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.fpab.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
export STATE_DIR="$WORK" SINGBOX_CONFIG="$WORK/config.json" PARAMS_JSON="$WORK/params.json" MYC_VOCAB="$VOCAB"
printf '{"client_fingerprint":"chrome"}' > "$PARAMS_JSON"
printf '{"inbounds":[{"tag":"vless-reality-vision-in","type":"vless","listen_port":443,"tls":{"server_name":"cover.example.invalid","reality":{"enabled":true,"handshake":{"server":"cover.example.invalid"}}}}]}' > "$SINGBOX_CONFIG"

# Minimal stubs so the runtime lib sources + the no-engine paths run; jq is real.
have() { command -v "$1" >/dev/null 2>&1; }
warn() { :; }
log()  { :; }
myc_die() { printf 'die: %s\n' "$*" >&2; return 1; }
# shellcheck source=/dev/null
. "$REPO_ROOT/control/lib/jqlib.sh" 2>/dev/null || { printf 'FAIL: cannot source jqlib.sh\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$NS" 2>/dev/null || { printf 'FAIL: cannot source nb_selftest.sh\n' >&2; exit 2; }

verdict_of() { jq -r '.verdict' "$WORK/fp_probe.json" 2>/dev/null; }
target_of()  { jq -r '.target_fingerprint' "$WORK/fp_probe.json" 2>/dev/null; }
expect() { # expect LABEL WANT_VERDICT WANT_TARGET
	local v t; v="$(verdict_of)"; t="$(target_of)"
	if [ "$v" = "$2" ] && [ "$t" = "$3" ]; then okln "$1 -> verdict=$v target='$t'"
	else badln "$1 -> got verdict=$v target='$t', want verdict=$2 target='$3'"; fi
}

# clean: no fingerprint-carrying member is DEAD.
printf '{"observed_at":"x","checked":1,"dead":[]}' > "$WORK/l7_selftest.json"
measure_fp_ab_probe >/dev/null 2>&1; expect "clean (nothing dead)" "clean" ""
# current_fingerprint is resolved from params (chrome).
[ "$(jq -r '.current_fingerprint' "$WORK/fp_probe.json")" = "chrome" ] \
	&& okln "current_fingerprint resolved from params (chrome)" || badln "current_fingerprint not resolved from params"

# cannot-judge: the L7 marker is absent (a transient — never a signal).
rm -f "$WORK/l7_selftest.json"
measure_fp_ab_probe >/dev/null 2>&1; expect "cannot-judge (no L7 marker)" "cannot-judge" ""

# From here the reality member reads DEAD; vary the stubbed A/B outcome.
printf '{"observed_at":"x","checked":1,"dead":["vless-reality-vision"]}' > "$WORK/l7_selftest.json"

# fingerprint-specific: an alternate reads ALIVE -> target = that alternate.
donor_verify_reality() { [ "$2" = "firefox" ] && return 0 || return 1; }
measure_fp_ab_probe >/dev/null 2>&1; expect "fingerprint-specific (firefox alive)" "fingerprint-specific" "firefox"
[ "$(jq -r '.suspect_refs[0]' "$WORK/fp_probe.json")" = "vless-reality-vision" ] \
	&& okln "suspect_refs names the dead member" || badln "suspect_refs missing the dead member"

# walk-to-first-alive: firefox AND edge alive -> picks firefox (canonical order, first alive).
donor_verify_reality() { case "$2" in firefox|edge) return 0;; *) return 1;; esac; }
measure_fp_ab_probe >/dev/null 2>&1; expect "walk-to-first-alive (firefox before edge)" "fingerprint-specific" "firefox"

# transport-wide: ALL alternates DEAD -> no fp signal (defer to the >=2-family backstop).
donor_verify_reality() { return 1; }
measure_fp_ab_probe >/dev/null 2>&1; expect "transport-wide (all alts dead)" "transport-wide" ""

# fail-safe: an alternate that cannot-judge (rc 2) is NOT a target.
donor_verify_reality() { return 2; }
measure_fp_ab_probe >/dev/null 2>&1; expect "fail-safe (all alts cannot-judge)" "transport-wide" ""

# The verdict vocabulary is exactly the closed, neutral set — no banned framing tokens.
if jq -e '.verdict | IN("fingerprint-specific","transport-wide","clean","cannot-judge")' "$WORK/fp_probe.json" >/dev/null 2>&1; then
	okln "verdict token is from the closed neutral set"
else
	badln "verdict token is outside the closed neutral set"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the fp A/B producer violated its contract.\n' >&2
	exit 1
fi
printf 'PASS: measure_fp_ab_probe honours the verdict table + the closed-set/own-marker/inert invariants.\n'
exit 0
