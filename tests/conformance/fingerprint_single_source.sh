#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# fingerprint_single_source.sh — conformance (RP-0015 increment A): the CLIENT uTLS ClientHello preset
# ("fingerprint") is single-sourced and threaded CONSISTENTLY through every render + verify + probe site.
#
# The fragility RP-0015 removes: the fingerprint was the literal "chrome" hardcoded in seven-plus places
# with no single source and no way to change it without a code edit. This gate keeps the knob honest:
#
#   1. The closed vocabulary lives ONCE in Go (internal/spec, surfaced by `myceliumctl vocab`) and is
#      mirrored into control/vocab.json (.client_fingerprints): a non-empty array, "chrome" first (the
#      default), NEVER a randomiser ("random"/"randomized" — a unique per-connection JA4 is itself a tell,
#      principle 1). The byte-identity of the Go source ↔ the file is the vocab_single_source gate's job;
#      here we assert the fingerprint-specific shape + that client_fingerprint is an operator toggle key.
#   2. The shell has ONE normaliser (jqlib.sh `myc_client_fingerprint`) — the twin of Go
#      spec.NormalizeClientFingerprint — that resolves .client_fingerprint against the closed vocab.
#   3. Every CLIENT render/verify/probe site RESOLVES the fingerprint from that parameter (default "chrome")
#      rather than emitting a bare hardcoded literal: the sing-box subscription (render_singbox.sh), the
#      legacy vision subscription (render.sh), the share-link (render_bundle.sh), the donor-verify client
#      (nb_donor.sh), and the ShadowTLS L7 probe (nb_selftest.sh). A drifting hardcoded `fingerprint:
#      "chrome"` / `client-fingerprint: chrome` / `fp=chrome` at any of those sites fails the gate.
#
# DELIBERATELY out of scope (asserted static, not policed as drift): ONLY the QUIC hy2/tuic uTLS — a
# separate handshake axis; hy2/tuic share-links carry no fp, so those outbounds keep a static
# `fingerprint: "chrome"` (`fp-static` annotation). The two-hop egress and the aggregate share-link fp are
# NO LONGER waived: since Audit-0008 S2-3/S2-4 both normalize through the closed vocab (the Go
# NormalizeClientFingerprint + its shell twins myc_client_fingerprint / the jq `normfp`), and section 5
# below polices them as drift.
#
# jq-only + grep; no Go required (the Go registry + render threading are covered by
# `go test ./internal/spec/...` and the share_link/subscription equivalence gates).
#
# Exit: 0 = single-source holds, 1 = drift / missing thread / bad vocab shape, 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
VOCAB="$REPO_ROOT/control/vocab.json"
LIB="$REPO_ROOT/control/lib"

printf '== fingerprint single-source check (RP-0015 client uTLS preset) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$VOCAB" ] || { printf 'FAIL: control/vocab.json not found: %s\n' "$VOCAB" >&2; exit 2; }
jq -e . "$VOCAB" >/dev/null 2>&1 || { printf 'FAIL: control/vocab.json is not valid JSON.\n' >&2; exit 1; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# grep helper: PATTERN present in FILE (fixed-string by default to keep JSON literals inert).
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
# count occurrences of a FIXED string in FILE (0 when absent — grep -c prints "0" and exits 1 on no match,
# so capture its output rather than branch on its exit status, which would double-print).
cnt() { local n; n="$(grep -cF -- "$2" "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# --- 1: the closed vocabulary shape in vocab.json ---------------------------------------------------

if jq -e '(.client_fingerprints | type) == "array" and (.client_fingerprints | length) >= 2' "$VOCAB" >/dev/null 2>&1; then
	okln "vocab.json carries a non-empty client_fingerprints array"
else
	badln "vocab.json is missing a non-empty .client_fingerprints array"
fi
if jq -e '.client_fingerprints[0] == "chrome"' "$VOCAB" >/dev/null 2>&1; then
	okln "the default client fingerprint is chrome (first entry)"
else
	badln ".client_fingerprints[0] is not \"chrome\" (the default must be first)"
fi
# principle 1: no randomiser is ever a member.
if jq -e '(.client_fingerprints | index("random")) == null and (.client_fingerprints | index("randomized")) == null' "$VOCAB" >/dev/null 2>&1; then
	okln "client_fingerprints excludes random/randomized (no per-connection randomiser)"
else
	badln "client_fingerprints must NOT contain random/randomized (a unique JA4 is itself a tell)"
fi
# every member is a lowercase preset token (no whitespace / uppercase leaking in).
if jq -e '.client_fingerprints | all(test("^[a-z][a-z0-9]*$"))' "$VOCAB" >/dev/null 2>&1; then
	okln "every client fingerprint is a clean lowercase preset token"
else
	badln "a client_fingerprints entry is not a clean lowercase token"
fi
# the operator knob is in the closed allowlist (so an override may set it; nb_render_params reads this).
if jq -e '.operator_toggle_keys | index("client_fingerprint") != null' "$VOCAB" >/dev/null 2>&1; then
	okln "client_fingerprint is in the operator_toggle_keys allowlist"
else
	badln "operator_toggle_keys is missing client_fingerprint (the knob would be un-settable)"
fi

# --- 2: the single shell normaliser -----------------------------------------------------------------

JQLIB="$LIB/jqlib.sh"
if [ -f "$JQLIB" ] && has "$JQLIB" 'myc_client_fingerprint()' && has "$JQLIB" '.client_fingerprints'; then
	okln "jqlib.sh defines myc_client_fingerprint reading .client_fingerprints (the shell normaliser)"
else
	badln "jqlib.sh must define myc_client_fingerprint resolving .client_fingerprints (single normaliser)"
fi

# --- 3: every CLIENT render/verify/probe site RESOLVES the parameter (no bare hardcoded literal) -----

# render_singbox.sh — the authoritative sing-box client render + its Clash emit.
RS="$LIB/render_singbox.sh"
if [ -f "$RS" ]; then
	if has "$RS" 'myc_client_fingerprint' && has "$RS" 'fingerprint: $fp'; then
		okln "render_singbox.sh resolves client_fingerprint and threads it into the tls defs (\$fp)"
	else
		badln "render_singbox.sh does not resolve/thread client_fingerprint into its tls defs"
	fi
	if [ "$(cnt "$RS" 'fingerprint: "chrome"')" -eq 0 ] && [ "$(cnt "$RS" 'client-fingerprint: chrome')" -eq 0 ]; then
		okln "render_singbox.sh has no bare hardcoded chrome fingerprint (sing-box or clash)"
	else
		badln "render_singbox.sh still emits a bare hardcoded chrome fingerprint (drift)"
	fi
else
	badln "render_singbox.sh not found: $RS"
fi

# render.sh — the legacy single-family (vision) subscription render + its Clash emit.
RSH="$LIB/render.sh"
if [ -f "$RSH" ]; then
	if has "$RSH" 'myc_client_fingerprint' && has "$RSH" 'fingerprint: $fp'; then
		okln "render.sh resolves client_fingerprint and threads it (\$fp)"
	else
		badln "render.sh does not resolve/thread client_fingerprint"
	fi
	if [ "$(cnt "$RSH" 'fingerprint: "chrome"')" -eq 0 ] && [ "$(cnt "$RSH" 'client-fingerprint: chrome')" -eq 0 ]; then
		okln "render.sh has no bare hardcoded chrome fingerprint"
	else
		badln "render.sh still emits a bare hardcoded chrome fingerprint (drift)"
	fi
else
	badln "render.sh not found: $RSH"
fi

# render_bundle.sh — the share-link (myc_bundle_link) threads fp; no bare fp=chrome literal.
RB="$LIB/render_bundle.sh"
if [ -f "$RB" ]; then
	if has "$RB" 'myc_client_fingerprint' && has "$RB" 'fp=%s'; then
		okln "render_bundle.sh resolves client_fingerprint and the links carry fp=%s (threaded)"
	else
		badln "render_bundle.sh does not resolve/thread client_fingerprint into the share-links"
	fi
	if [ "$(cnt "$RB" 'fp=chrome')" -eq 0 ]; then
		okln "render_bundle.sh has no bare hardcoded fp=chrome share-link literal"
	else
		badln "render_bundle.sh still emits a bare hardcoded fp=chrome link literal (drift)"
	fi
else
	badln "render_bundle.sh not found: $RB"
fi

# nb_donor.sh — the ephemeral donor-verify client mimics the SAME fingerprint (principle 3).
ND="$LIB/nb_donor.sh"
if [ -f "$ND" ]; then
	if has "$ND" 'myc_client_fingerprint' && has "$ND" '\"fingerprint\":\"$fp\"'; then
		okln "nb_donor.sh resolves client_fingerprint and the verify-client mimics it (\$fp)"
	else
		badln "nb_donor.sh does not resolve/thread client_fingerprint into the verify-client"
	fi
	if [ "$(cnt "$ND" '\"fingerprint\":\"chrome\"')" -eq 0 ]; then
		okln "nb_donor.sh has no bare hardcoded chrome fingerprint in the verify-client"
	else
		badln "nb_donor.sh still hardcodes a chrome fingerprint in the verify-client (drift)"
	fi
else
	badln "nb_donor.sh not found: $ND"
fi

# nb_selftest.sh — the ShadowTLS L7 probe reconstructs the client with the SAME fingerprint (principle 3).
NS="$LIB/nb_selftest.sh"
if [ -f "$NS" ]; then
	if has "$NS" 'myc_client_fingerprint' && has "$NS" 'fingerprint:$fp'; then
		okln "nb_selftest.sh resolves client_fingerprint and the L7 probe mimics it (\$fp)"
	else
		badln "nb_selftest.sh does not resolve/thread client_fingerprint into the L7 probe"
	fi
	if [ "$(cnt "$NS" 'fingerprint:"chrome"')" -eq 0 ]; then
		okln "nb_selftest.sh has no bare hardcoded chrome fingerprint in the probe"
	else
		badln "nb_selftest.sh still hardcodes a chrome fingerprint in the probe (drift)"
	fi
else
	badln "nb_selftest.sh not found: $NS"
fi

# --- 4: post-rotation consistency (RP-0015 B) — the actuator's delta key IS the render/verify/probe key ----
# A fingerprint rotation (B3) persists its move as `.client_fingerprint` into the operator-overrides overlay,
# which write_params merges into params.json. Every render/verify/probe site resolves the value from
# params.client_fingerprint via myc_client_fingerprint (section 3), so as long as the actuator writes the SAME
# key the renders read, a rotated NON-default preset flows to every site — render == donor-verify == probe on
# the rotated value, with no per-site re-plumbing. This closes the loop between increments A and B.
RA="$LIB/nb_rotate_apply.sh"
if [ -f "$RA" ]; then
	if has "$RA" '.client_fingerprint = $t' && has "$JQLIB" '.client_fingerprint // empty'; then
		okln "the fp rotation delta writes .client_fingerprint — the SAME key myc_client_fingerprint reads (post-rotation consistency)"
	else
		badln "the fp rotation delta key does not match the key the renders resolve (post-rotation drift risk)"
	fi
	# The rotation move must ride the operator-overrides overlay (so it survives --update); client_fingerprint
	# is an operator_toggle_key (asserted in section 1), so the merge keeps it.
	if has "$RA" 'persist_fp_to_overlay' && has "$RA" 'OPERATOR_OVERRIDES'; then
		okln "the fp rotation persists through the operator-overrides overlay (survives --update)"
	else
		badln "the fp rotation does not persist through the operator-overrides overlay"
	fi
else
	badln "nb_rotate_apply.sh not found: $RA"
fi

# --- 5: the two-hop egress + aggregate share-link fp normalize through the closed vocab (Audit-0008 S2-3/S2-4) --
# render_singbox.sh two-hop: the egress uTLS preset is the NORMALIZED value ($thfp, from myc_client_fingerprint),
# never a bare field-default that could splice an invalid uTLS token into the second hop.
if [ -f "$RS" ]; then
	if has "$RS" 'fingerprint: $thfp' && [ "$(cnt "$RS" 'fingerprint: ($th.fingerprint // "chrome")')" -eq 0 ]; then
		okln "render_singbox.sh two-hop egress fingerprint is normalized (\$thfp), no bare field-default (S2-3)"
	else
		badln "render_singbox.sh two-hop egress fingerprint is not normalized through the closed vocab (S2-3 regressed)"
	fi
else
	badln "render_singbox.sh not found (two-hop fp check): $RS"
fi
# render_aggregate.sh: the parsed share-link fp for the TLS/reality/trojan outbounds runs through `normfp`
# (the jq twin of NormalizeClientFingerprint); no bare `$q.fp // "chrome"` splice remains. The QUIC hy2/tuic
# `fingerprint: "chrome"` literals are the separate fp-static axis and are intentionally NOT policed here.
RAG="$LIB/render_aggregate.sh"
if [ -f "$RAG" ]; then
	if has "$RAG" 'def normfp:' && has "$RAG" '| normfp)' && [ "$(cnt "$RAG" '$q.fp // "chrome"')" -eq 0 ]; then
		okln "render_aggregate.sh normalizes share-link fp through normfp, no bare (\$q.fp // \"chrome\") splice (S2-4)"
	else
		badln "render_aggregate.sh does not normalize the share-link fp through the closed vocab (S2-4 regressed)"
	fi
else
	badln "render_aggregate.sh not found (aggregate fp check): $RAG"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the client fingerprint is not single-sourced / consistently threaded (RP-0015 A).\n' >&2
	exit 1
fi
printf 'PASS: the client uTLS fingerprint is single-sourced and threaded through every render/verify/probe site.\n'
exit 0
