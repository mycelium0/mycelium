// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package diag builds the operator's node diagnostics bundle (RP-0011 chunk E). Its first, gating
// responsibility is REDACTION: a diagnostics bundle is meant to be attached to a public bug report, so
// it must carry NONE of the PII the project forbids collecting (SECURITY.md §4.2) — client/source IPs,
// hostnames/FQDNs/SNI, client UUIDs, key material, per-protocol secrets, AS numbers. Redact is a pure,
// fail-safe-by-over-redaction function: when in doubt it scrubs MORE, never less. The collector
// (diag collect) pipes everything through it, and log_bundle_redaction.sh proves it against seeded PII.
package diag

import "regexp"

// rule is one ordered redaction pass. Order is load-bearing (see the rules block): the labelled
// key=value pass runs first, then the structural classes that own their delimiters (UUID / IPv6 / MAC /
// IPv4 / FQDN), then the generic opaque-token passes, so a broad "long token" pass can never partially
// mangle (fragment) a structured value a more specific rule would otherwise scrub whole.
type rule struct {
	re   *regexp.Regexp
	repl string
}

var rules = []rule{
	// 1. Labelled sensitive field: redact the VALUE after a closed set of sensitive keys, wholesale and
	//    length/charset-agnostic — this catches short secrets, REALITY short_ids, and (critically) BARE
	//    single-label hostnames (e.g. _HOSTNAME=, sni=, peer=) that the dotted-FQDN rule below cannot.
	//    It runs FIRST so a value is never partially eaten by a later generic pass, and it keeps the
	//    structural "key=" prefix. The value class stops only at whitespace / , ; " ' so it consumes the
	//    whole token (incl. an emitted "[redacted-field]" on a second pass — hence idempotent).
	{regexp.MustCompile(`(?i)\b(_hostname|hostname|host|server_name|servername|sni|domain|fqdn|peer|` +
		`pre_shared_key|preshared_key|private_key|public_key|access_key|api_key|apikey|` +
		`password|passwd|pass|psk|secret|token|key|short_id|shortid|client_id|uuid|` +
		`username|user|owner|email|mail)=[^\s,;"']+`), "${1}=[redacted-field]"},
	// 2. Username via a filesystem path (/home/<user>, /Users/<user>).
	{regexp.MustCompile(`(?i)(/home/|/users/)[^/\s:]+`), "${1}[redacted-user]"},
	// 3. Client UUID (8-4-4-4-12 hex) — e.g. a VLESS id.
	{regexp.MustCompile(`\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`), "[redacted-uuid]"},
	// 4. IPv6 — anchored on a CAPTURED leading delimiter (group 1, re-emitted) because \b cannot anchor
	//    before a leading ':'. Matches either a fully-expanded 8-group form (7 colons) or any '::'
	//    compressed form, incl. an embedded IPv4 tail (::ffff:a.b.c.d). It requires '::' OR 7 colons, so
	//    a clock time HH:MM:SS (<=2 colons, no '::') is NOT matched — no journal-timestamp over-redaction.
	{regexp.MustCompile(`(^|[^0-9a-fA-F:.])` +
		`((?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}` +
		`|(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{0,4}::(?:[0-9a-fA-F]{1,4}:)*` +
		`(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3}|[0-9a-fA-F]{1,4})?)`), "${1}[redacted-ipv6]"},
	// 5. MAC address (six 2-hex groups). After IPv6; a MAC has exactly 5 colons, no clock-time clash.
	{regexp.MustCompile(`\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b`), "[redacted-mac]"},
	// 6. IPv4 dotted quad.
	{regexp.MustCompile(`\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b`), "[redacted-ipv4]"},
	// 7. FQDN / hostname / SNI / donor (>=1 dotted label + a TLD). BEFORE the hex/secret passes so a
	//    hostname whose leading label is hex-ish is redacted WHOLE, not fragmented. Over-redacts public
	//    domains too — safe for a bundle; the node's own hostname / donor SNI is the sensitive part.
	{regexp.MustCompile(`\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}\b`), "[redacted-host]"},
	// 8. 64-hex digest / key material (REALITY private key hex, sha256, etc.).
	{regexp.MustCompile(`\b[0-9a-fA-F]{64}\b`), "[redacted-key]"},
	// 9. x25519 / REALITY base64url key (43–44 chars) — distinct label before the generic passes.
	{regexp.MustCompile(`\b[A-Za-z0-9_-]{43,44}\b`), "[redacted-key]"},
	// 10. Short opaque hex token (>=8) — REALITY short_id and friends that fall between the UUID/64-hex
	//     rules and the >=32 secret pass. Hex-only and dot-less, so it cannot touch an FQDN or a word.
	{regexp.MustCompile(`\b[0-9a-fA-F]{8,}\b`), "[redacted-key]"},
	// 11. Any other long opaque token (>=32) — shadowsocks PSK, passwords, bootstrap/join secrets, etc.
	//     NOTE: `=` is deliberately NOT in the class so a free `key=<secret>` pair (not caught by rule 1)
	//     is not swallowed whole; the secret VALUE is what gets redacted.
	{regexp.MustCompile(`\b[A-Za-z0-9+/_-]{32,}\b`), "[redacted-secret]"},
	// 12. Autonomous-system number — AS / ASN, with an optional space / '=' / ':' before the digits.
	{regexp.MustCompile(`(?i)\bas(?:n)?[\s=:]*[0-9]{2,}\b`), "[redacted-asn]"},
}

// Redact scrubs every PII class from s, fail-safe by over-redaction (it never leaves a class un-scrubbed
// because a value "looked" benign). It is pure, deterministic, and idempotent.
func Redact(s string) string {
	for _, r := range rules {
		s = r.re.ReplaceAllString(s, r.repl)
	}
	return s
}
