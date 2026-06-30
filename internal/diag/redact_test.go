// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package diag

import (
	"strings"
	"testing"
)

// piiNeedles are realistic-looking but FAKE PII values, one per redaction class (incl. the classes a
// pre-release audit found leaking: BARE single-label / location-coded hostnames — labelled, in a
// dial/lookup error verb, and dotted; short REALITY short_ids; '::'-form and IPv4-mapped IPv6; MACs;
// sub-32 and quoted field secrets; ASN variants; $HOME usernames). After Redact, NONE may survive.
var piiNeedles = []string{
	"203.0.113.47",                               // IPv4 (TEST-NET-3 documentation range)
	"2001:db8::dead:beef",                        // IPv6 '::' compressed (documentation range)
	"fe80::cafe",                                 // IPv6 link-local, '::' form, free-floating
	"203.0.113.5",                                // IPv4 embedded in a ::ffff: mapped address
	"node7.secret-provider.example",              // FQDN / SNI / donor (dotted)
	"deadbeef99.tracker.example",                 // FQDN whose leading label is hex-ish (must NOT fragment)
	"nl1-amsterdam",                              // BARE location-coded hostname via _HOSTNAME= (no dot)
	"kz1-almaty",                                 // BARE location-coded hostname via sni= (no dot)
	"pl1-warsaw",                                 // BARE host in a dial-error operand (USER_DEANON residual)
	"nl4-rotterdam",                              // BARE host in a lookup-error operand
	"secret pass phrase",                         // QUOTED secret value (spaces) via password="…"
	"11111111-2222-4333-8444-555555555555",       // client UUID
	"AOz1pK3rJ8XwVxqLmNbCdEfGhIjKlMnOpQrStUvWxY", // x25519 / REALITY base64url key (43)
	"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef", // 64-hex key material
	"0123abcd", // short REALITY short_id (8 hex) — the UUID/64-hex/≥32 gap
	"c29tZXNlY3JldHBza3ZhbHVlMTIzNDU2Nzg5MA==", // shadowsocks PSK / password (base64, ≥32)
	"hunter2pw",         // sub-32 plaintext secret via password= field
	"de:ad:be:ef:00:11", // MAC address
	"AS64500",           // autonomous-system number
	"64999",             // ASN written as "ASN 64999" (variant form)
	"operator7",         // username via /home/<user> path
}

// seededBundle embeds every needle in plausible journal / config log lines. The trailing lines pin the
// non-over-redaction invariants: a clock time survives (the IPv6 rule must not eat HH:MM:SS) and the
// English word "as" + digits survives (the ASN rule must not eat it).
const seededBundle = `level=error msg="handshake" src=203.0.113.47 uuid=11111111-2222-4333-8444-555555555555
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
`

func TestRedactScrubsEveryNeedle(t *testing.T) {
	out := Redact(seededBundle)

	for _, n := range piiNeedles {
		if strings.Contains(out, n) {
			t.Errorf("PII needle survived redaction: %q\n--- output ---\n%s", n, out)
		}
	}
	// Structural scaffolding is preserved — we redact values, not lines/keys.
	for _, keep := range []string{"level=error", "_HOSTNAME=", "reality private_key=", "shadowsocks psk=", "shadowsocks password="} {
		if !strings.Contains(out, keep) {
			t.Errorf("redaction destroyed structural context %q (should redact values, not keys)", keep)
		}
	}
	// Non-over-redaction invariants: a clock time and the English "as"+digits must survive.
	if !strings.Contains(out, "12:34:56") {
		t.Errorf("redaction ate a clock timestamp (12:34:56) as if it were IPv6\n--- output ---\n%s", out)
	}
	if !strings.Contains(out, "downloaded as 12345 chunks") {
		t.Errorf("ASN rule over-redacted the English word \"as\"+digits\n--- output ---\n%s", out)
	}
	// Order invariant (load-bearing): a hex-leading FQDN must be redacted WHOLE to a single
	// [redacted-host], NOT fragmented to [redacted-key].[redacted-host] by an earlier generic pass.
	if !strings.Contains(out, "FQDN [redacted-host] must not fragment") {
		t.Errorf("rule-order invariant violated: hex-leading FQDN not redacted whole\n--- output ---\n%s", out)
	}
	if strings.Contains(out, "[redacted-key].[redacted-host]") {
		t.Errorf("rule-order invariant violated: hex-leading FQDN FRAGMENTED\n--- output ---\n%s", out)
	}
}

func TestRedactIsDeterministicAndIdempotent(t *testing.T) {
	once := Redact(seededBundle)
	if Redact(seededBundle) != once {
		t.Error("Redact is not deterministic")
	}
	// Idempotence is load-bearing: a re-run over already-redacted text must be a no-op — no class may
	// re-match an emitted "[redacted-*]" sentinel and append cruft.
	if Redact(once) != once {
		t.Errorf("Redact is not idempotent:\n--- once ---\n%s\n--- twice ---\n%s", once, Redact(once))
	}
}

// TestRedactBundleSelfHost pins the collector's own-hostname belt: the node's hostname is scrubbed even
// when it appears UNLABELLED in prose, the scrub is WORD-ANCHORED (it never corrupts a benign substring),
// it is length-floored (a short/common hostname is skipped rather than mangling the bundle), and an empty
// selfHost degrades to plain Redact.
func TestRedactBundleSelfHost(t *testing.T) {
	const host = "nl1-amsterdam"
	out := RedactBundle("starting node nl1-amsterdam now; sibling nl1-amsterdam reachable", host)
	if strings.Contains(out, host) {
		t.Errorf("RedactBundle left the node hostname %q: %q", host, out)
	}
	// Word-anchored: a hostname that is a substring of a longer word must NOT be scrubbed inside it.
	wa := RedactBundle("a node and a nodejs runtime", "node")
	if !strings.Contains(wa, "nodejs") {
		t.Errorf("RedactBundle scrubbed inside the longer word 'nodejs' (not word-anchored): %q", wa)
	}
	if strings.Contains(wa, "a node and") {
		t.Errorf("RedactBundle did not scrub the standalone hostname 'node': %q", wa)
	}
	// Length floor: a short hostname (<4) is skipped, so it cannot corrupt benign substrings.
	sf := RedactBundle("form1 submitted; m1tch ok", "m1")
	if !strings.Contains(sf, "form1") || !strings.Contains(sf, "m1tch") {
		t.Errorf("RedactBundle with a short hostname corrupted benign substrings: %q", sf)
	}
	// Empty selfHost degrades to plain Redact.
	if RedactBundle("ip 203.0.113.7 ok", "") != Redact("ip 203.0.113.7 ok") {
		t.Error("RedactBundle with empty selfHost must equal Redact")
	}
}
