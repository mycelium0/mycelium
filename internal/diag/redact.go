// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package diag builds the operator's node diagnostics bundle (RP-0011 chunk E). Its first, gating
// responsibility is REDACTION: a diagnostics bundle is meant to be attached to a public bug report, so
// it must carry as little as possible of the PII the project forbids collecting (SECURITY.md §4.2) —
// client/source IPs, hostnames/FQDNs/SNI, client UUIDs, key material, per-protocol secrets, AS numbers.
// Redact is fail-safe BY OVER-REDACTION: when in doubt it scrubs more, never less. It scrubs every
// STRUCTURED/labelled PII class — labelled `key=value` fields, dial/lookup/connect error operands,
// IPv4/IPv6/MAC addresses, dotted FQDNs, UUIDs, key material and opaque tokens (≥8 hex / ≥32 chars),
// and AS numbers. KNOWN RESIDUAL: a free-floating, unlabelled, dot-less, sub-8-char opaque value with no
// surrounding key or verb cannot be told apart from ordinary prose and is left intact (redacting every
// dot-less word would destroy the bundle). The collector (diag collect) routes everything through
// RedactBundle, and log_bundle_redaction.sh proves the invariant against seeded PII.
package diag

import "regexp"

// rule is one ordered redaction pass. Order is load-bearing (see the rules block): the labelled
// key=value and verb-anchored passes run first, then the structural classes that own their delimiters
// (UUID / IPv6 / MAC / IPv4 / FQDN), then the generic opaque-token passes, so a broad "long token" pass
// can never partially mangle (fragment) a structured value a more specific rule would otherwise scrub
// whole. log_bundle_redaction.sh + redact_test.go pin both the no-leak AND the whole-redaction invariant.
type rule struct {
	re   *regexp.Regexp
	repl string
}

var rules = []rule{
	// 1. Labelled sensitive field: redact the VALUE (bare OR quoted) after a closed set of sensitive
	//    keys, wholesale and length/charset-agnostic — catches short secrets, REALITY short_ids, and
	//    (critically) BARE single-label hostnames (e.g. _HOSTNAME=, sni=, peer=) the dotted-FQDN rule
	//    below cannot. Runs FIRST so a value is never partially eaten by a later generic pass; keeps the
	//    structural "key=" prefix. The value is a quoted run ("a b" / 'a b') OR a bare token (stops at
	//    whitespace / , ; " ') — so a quoted secret with spaces is redacted whole.
	{regexp.MustCompile(`(?i)\b(_hostname|hostname|host|server_name|servername|sni|domain|fqdn|peer|` +
		`pre_shared_key|preshared_key|private_key|public_key|access_key|api_key|apikey|` +
		`password|passwd|pass|psk|secret|token|key|short_id|shortid|client_id|uuid|` +
		`username|user|owner|email|mail)=` +
		`(?:"[^"]*"|'[^']*'|[^\s,;"']+)`), "${1}=[redacted-field]"},
	// 2. Username via a filesystem path (/home/<user>, /Users/<user>).
	{regexp.MustCompile(`(?i)(/home/|/users/)[^/\s:]+`), "${1}[redacted-user]"},
	// 3. Dial / connect / lookup error operand — closes the UNLABELLED bare (dot-less, location-coded)
	//    peer/egress hostname that a sing-box/xray error line carries (e.g. `dial tcp <host>:443: …`,
	//    `lookup <host>: no such host`). Verb-anchored so it does NOT over-redact ordinary prose; the
	//    operand is redacted whether host or IP. Runs before the address rules so it captures it whole.
	{regexp.MustCompile(`(?i)\b((?:dial(?: tcp| udp)?|lookup|connect to|connection from|` +
		`process connection from)\s+)[^\s,;]+`), "${1}[redacted-host]"},
	// 4. Client UUID (8-4-4-4-12 hex) — e.g. a VLESS id.
	{regexp.MustCompile(`\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`), "[redacted-uuid]"},
	// 5. IPv6 — anchored on a CAPTURED leading delimiter (group 1, re-emitted) because \b cannot anchor
	//    before a leading ':'. Matches a fully-expanded 8-group form (7 colons) or any '::' compressed
	//    form (incl. an embedded IPv4 tail). Requires '::' OR 7 colons, so a clock time HH:MM:SS
	//    (<=2 colons, no '::') is NOT matched — no journal-timestamp over-redaction.
	{regexp.MustCompile(`(^|[^0-9a-fA-F:.])` +
		`((?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}` +
		`|(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{0,4}::(?:[0-9a-fA-F]{1,4}:)*` +
		`(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3}|[0-9a-fA-F]{1,4})?)`), "${1}[redacted-ipv6]"},
	// 6. MAC address (six 2-hex groups). After IPv6; a MAC has exactly 5 colons, no clock-time clash.
	{regexp.MustCompile(`\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b`), "[redacted-mac]"},
	// 7. IPv4 dotted quad.
	{regexp.MustCompile(`\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b`), "[redacted-ipv4]"},
	// 8. FQDN / hostname / SNI / donor (>=1 dotted label + a TLD). BEFORE the hex/secret passes so a
	//    hostname whose leading label is hex-ish is redacted WHOLE, not fragmented.
	{regexp.MustCompile(`\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}\b`), "[redacted-host]"},
	// 9. 64-hex digest / key material (REALITY private key hex, sha256, etc.).
	{regexp.MustCompile(`\b[0-9a-fA-F]{64}\b`), "[redacted-key]"},
	// 10. x25519 / REALITY base64url key (43–44 chars) — distinct label before the generic passes.
	{regexp.MustCompile(`\b[A-Za-z0-9_-]{43,44}\b`), "[redacted-key]"},
	// 11. Short opaque hex token (>=8) — REALITY short_id and friends between the UUID/64-hex rules and
	//     the >=32 secret pass. Hex-only and dot-less, so it cannot touch an FQDN or a word.
	{regexp.MustCompile(`\b[0-9a-fA-F]{8,}\b`), "[redacted-key]"},
	// 12. Any other long opaque token (>=32) — shadowsocks PSK, passwords, bootstrap/join secrets, etc.
	{regexp.MustCompile(`\b[A-Za-z0-9+/_-]{32,}\b`), "[redacted-secret]"},
	// 13. Autonomous-system number — AS/ASN abutting the digits with at most one delimiter. CASE-
	//     SENSITIVE on the AS token so the English word "as" + digits ("downloaded as 12345") is NOT
	//     redacted (a real ASN reference is "AS64500" / "ASN 64500").
	{regexp.MustCompile(`\bAS(?:N)?[ :=]?[0-9]{2,}\b`), "[redacted-asn]"},
}

// Redact scrubs every STRUCTURED PII class from s, fail-safe by over-redaction (it never leaves a
// structured class un-scrubbed because a value "looked" benign). It is pure, deterministic, and
// idempotent. It does NOT scrub a free-floating, unlabelled, dot-less, sub-8-char opaque value (see the
// package doc's KNOWN RESIDUAL) — for the node's own hostname belt, callers use RedactBundle.
func Redact(s string) string {
	for _, r := range rules {
		s = r.re.ReplaceAllString(s, r.repl)
	}
	return s
}

// RedactBundle is the entry point a diagnostics COLLECTOR uses: it first scrubs the node's own hostname
// (selfHost) by exact, WORD-ANCHORED match — the one node-identifying value a log message body could echo
// without a label or a dot — then runs the full class-based Redact. The self-host scrub is word-anchored
// (\b…\b on a regexp-quoted selfHost) and skipped for a short hostname (<4 chars), so it cannot corrupt
// the bundle by replacing a common substring. selfHost="" (e.g. os.Hostname() failed) degrades to plain
// Redact. It stays pure (no I/O) so it is unit-testable without a live node.
func RedactBundle(s, selfHost string) string {
	if len(selfHost) >= 4 {
		s = regexp.MustCompile(`(?i)\b`+regexp.QuoteMeta(selfHost)+`\b`).ReplaceAllString(s, "[redacted-host]")
	}
	return Redact(s)
}
