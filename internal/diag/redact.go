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

// rule is one ordered redaction pass. Order matters: the most specific / longest patterns run first so
// a broad "long secret" pass cannot mislabel (or partially mangle) a UUID / key it would also match.
type rule struct {
	re   *regexp.Regexp
	repl string
}

var rules = []rule{
	// Client UUID (e.g. a VLESS id) — 8-4-4-4-12 hex. Before the generic long-token passes.
	{regexp.MustCompile(`\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`), "[redacted-uuid]"},
	// 64-hex digest / key material (REALITY private key hex, sha256, etc.).
	{regexp.MustCompile(`\b[0-9a-fA-F]{64}\b`), "[redacted-key]"},
	// x25519 / REALITY base64url key (43–44 chars) — distinct label before the generic secret pass.
	{regexp.MustCompile(`\b[A-Za-z0-9_-]{43,44}\b`), "[redacted-key]"},
	// Any other long opaque token (>=32) — shadowsocks PSK, passwords, bootstrap/join secrets, etc.
	// NOTE: `=` is deliberately NOT in the class so a `key=<secret>` pair is not swallowed whole (the
	// "key=" prefix would be lost); the secret VALUE after the `=` is what gets redacted. Trailing
	// base64 `=` padding is left behind (harmless — not the secret).
	{regexp.MustCompile(`\b[A-Za-z0-9+/_-]{32,}\b`), "[redacted-secret]"},
	// IPv6 (incl. :: compressed forms). Before IPv4 so an embedded v4 tail does not leak.
	{regexp.MustCompile(`\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b`), "[redacted-ipv6]"},
	// IPv4 dotted quad.
	{regexp.MustCompile(`\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b`), "[redacted-ipv4]"},
	// FQDN / hostname / SNI / donor (one or more dotted labels + a TLD). Over-redacts public domains
	// too — safe for a bundle; the node's own hostname / donor SNI is the sensitive part.
	{regexp.MustCompile(`\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}\b`), "[redacted-host]"},
	// Autonomous-system number.
	{regexp.MustCompile(`\bAS[0-9]{2,}\b`), "[redacted-asn]"},
}

// Redact scrubs every PII class from s, fail-safe by over-redaction (it never leaves a class un-scrubbed
// because a value "looked" benign). It is pure and deterministic.
func Redact(s string) string {
	for _, r := range rules {
		s = r.re.ReplaceAllString(s, r.repl)
	}
	return s
}
