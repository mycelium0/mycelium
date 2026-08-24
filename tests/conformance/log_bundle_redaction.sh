#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# log_bundle_redaction.sh — conformance (RP-0011 chunk E, AC-9): the diagnostics redactor is PII-SAFE.
# A diagnostics bundle is meant to be attached to a PUBLIC bug report, so it must carry NONE of the PII
# the project forbids collecting (SECURITY.md §4.2). This gate is the GATE-BEFORE-BEHAVIOUR guard: it
# lands with the redactor, BEFORE any `diag collect` collector that would assemble a real bundle.
#
# It feeds a synthetic node bundle SEEDED with fake PII (IPv4/IPv6, FQDN/hostname/SNI, client UUID,
# key material, a shadowsocks PSK, an AS number) through `myceliumctl diag redact` and asserts that
# NONE of the seeds survive. It also requires the Go runtime redaction test to exist (so the in-code
# proof cannot be silently dropped), mirroring no_dataplane_pii.sh's discipline.
#
# Exit: 0 = the redactor scrubs every seeded class (or skipped w/o Go), 1 = a leak, 2 = usage/env error.

set -u
REPO_ROOT="${MYC_REPO_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'log_bundle_redaction: cannot resolve repo root\n' >&2; exit 2; }
RED="$REPO_ROOT/internal/diag/redact.go"
TST="$REPO_ROOT/internal/diag/redact_test.go"
[ -f "$RED" ] || { printf 'log_bundle_redaction: missing %s\n' "$RED" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== diagnostics bundle is PII-safe (RP-0011 chunk E / AC-9) ==\n'

# The collector, if present, must be PII-safe BY CONSTRUCTION: cmdDiagCollect must pipe its assembled
# bundle through diag.RedactBundle (own-hostname scrub + the class-based redactor) before printing — it
# must never fmt.Print the raw builder.
MAIN="$REPO_ROOT/cmd/myceliumctl/main.go"
if [ -f "$MAIN" ] && grep -q 'func cmdDiagCollect' "$MAIN"; then
	body="$(awk '/^func cmdDiagCollect\(/{f=1} f{print} /^}/{if(f)exit}' "$MAIN")"
	if printf '%s' "$body" | grep -qE 'fmt\.Print\(diag\.RedactBundle\('; then
		ok "diag collect prints only diag.RedactBundle(...) output (PII-safe by construction)"
	else
		badln "cmdDiagCollect does not pipe its bundle through diag.RedactBundle before printing"
	fi
	printf '%s' "$body" | grep -qE 'fmt\.Print\((&?b|b\.String\(\))' && badln "cmdDiagCollect prints the RAW builder (must redact first)" || true
fi

# The Go runtime redaction proof must exist + assert the invariant (cannot be silently dropped).
if [ -f "$TST" ] && grep -q 'piiNeedles' "$TST" && grep -qiE 'survived redaction|PII' "$TST"; then
	ok "Go runtime redaction test present + asserts the no-PII invariant: ${TST#"$REPO_ROOT"/}"
else
	badln "internal/diag/redact_test.go missing or does not assert the no-PII invariant (the runtime proof)"
fi

if ! command -v go >/dev/null 2>&1; then
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the live redaction assertion (TestRedactScrubsEveryNeedle mirrors it).\n'
	[ "$fail" -eq 0 ] && exit 0 || exit 1
fi

# Build the spine + run a SEEDED bundle through `diag redact`; assert NO seed survives.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.lbr.XXXXXX")" || { printf 'FAIL: mktemp\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
if ! ( cd "$REPO_ROOT" && go build -o "$WORK/mc" ./cmd/myceliumctl ) 2>"$WORK/build.err"; then
	badln "could not build myceliumctl: $(tr '\n' ' ' <"$WORK/build.err")"
	printf 'FAIL\n' >&2; exit 1
fi

# Seeded fake PII (one per class, incl. the classes a pre-release audit found leaking: BARE location-
# coded hostnames, short REALITY short_ids, '::'/mapped IPv6, MAC, sub-32 field secret, ASN variants,
# $HOME usernames, a hex-leading FQDN that must not fragment) embedded in plausible log/journal lines.
NEEDLES=(
	"203.0.113.47"
	"2001:db8::dead:beef"
	"fe80::cafe"
	"203.0.113.5"
	"node7.secret-provider.example"
	"deadbeef99.tracker.example"
	"nl1-amsterdam"
	"kz1-almaty"
	"11111111-2222-4333-8444-555555555555"
	"AOz1pK3rJ8XwVxqLmNbCdEfGhIjKlMnOpQrStUvWxY"
	"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	"0123abcd"
	"c29tZXNlY3JldHBza3ZhbHVlMTIzNDU2Nzg5MA=="
	"hunter2pw"
	"de:ad:be:ef:00:11"
	"AS64500"
	"64999"
	"operator7"
	"pl1-warsaw"
	"nl4-rotterdam"
	"secret pass phrase"
)
cat >"$WORK/bundle.txt" <<EOF
level=error msg="handshake from client" src=203.0.113.47 uuid=11111111-2222-4333-8444-555555555555
_HOSTNAME=nl1-amsterdam sni=kz1-almaty server_name=node7.secret-provider.example
reality private_key=AOz1pK3rJ8XwVxqLmNbCdEfGhIjKlMnOpQrStUvWxY short_id=0123abcd
long short_id ref deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
shadowsocks psk=c29tZXNlY3JldHBza3ZhbHVlMTIzNDU2Nzg5MA== password=hunter2pw
peer=[2001:db8::dead:beef] addr fe80::cafe mapped ::ffff:203.0.113.5 mac de:ad:be:ef:00:11
as=AS64500 also ASN 64999 owner User=operator3 path /home/operator7/.config
free-floating FQDN deadbeef99.tracker.example must not fragment
level=error dial tcp pl1-warsaw:443: connect: connection refused
lookup nl4-rotterdam: no such host
shadowsocks password="secret pass phrase" enabled=true
note downloaded as 12345 chunks in 3 batches
Jun 30 12:34:56 some-service started ok
EOF

out="$("$WORK/mc" diag redact <"$WORK/bundle.txt" 2>"$WORK/redact.err")" || { badln "diag redact failed: $(tr '\n' ' ' <"$WORK/redact.err")"; }
leaked=0
for n in "${NEEDLES[@]}"; do
	if printf '%s' "$out" | grep -Fq -- "$n"; then
		badln "PII seed SURVIVED redaction: $n"
		leaked=1
	fi
done
[ "$leaked" -eq 0 ] && ok "every seeded PII class (IPv4/IPv6/MAC/FQDN/bare-host/UUID/key/short_id/secret/ASN/user) is scrubbed by 'diag redact'"

# the redacted output should still carry the structural scaffolding (we scrub values, not whole lines)
printf '%s' "$out" | grep -q 'level=error' && ok "structural context preserved (values redacted, lines kept)" \
	|| badln "redaction destroyed structural context (should redact values only)"
# a clock time must survive — the IPv6 rule must not eat HH:MM:SS (would destroy log chronology)
printf '%s' "$out" | grep -q '12:34:56' && ok "clock timestamp preserved (IPv6 rule does not over-redact HH:MM:SS)" \
	|| badln "redaction ate a clock timestamp as if it were IPv6"
# the English word "as" + digits must survive — the ASN rule must be AS/ASN-anchored, not prose-eating
printf '%s' "$out" | grep -q 'downloaded as 12345 chunks' && ok "English \"as\"+digits preserved (ASN rule is AS-anchored, not prose-eating)" \
	|| badln "ASN rule over-redacted the English word \"as\"+digits"
# the rule-order invariant: a hex-leading FQDN is redacted WHOLE, not fragmented
printf '%s' "$out" | grep -q 'FQDN \[redacted-host\] must not fragment' && ok "rule-order invariant: hex-leading FQDN redacted whole" \
	|| badln "rule-order invariant violated: hex-leading FQDN fragmented or not redacted whole"

if [ "$fail" -eq 0 ]; then
	printf 'PASS: the diagnostics redactor scrubs every PII class; bundle output is safe for a public report.\n'
	exit 0
fi
printf 'FAIL: the diagnostics redactor leaks PII — a collector must NOT ship.\n' >&2
exit 1
