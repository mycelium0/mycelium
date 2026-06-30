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
// pre-release audit found leaking: BARE single-label / location-coded hostnames, short REALITY
// short_ids, '::'-form and IPv4-mapped IPv6, MACs, sub-32 field secrets, ASN variants, $HOME usernames).
// The runtime invariant is simple and load-bearing: after Redact, NONE of these may survive anywhere.
var piiNeedles = []string{
	"203.0.113.47",                               // IPv4 (TEST-NET-3 documentation range)
	"2001:db8::dead:beef",                        // IPv6 '::' compressed (documentation range)
	"fe80::cafe",                                 // IPv6 link-local, '::' form, free-floating
	"203.0.113.5",                                // IPv4 embedded in a ::ffff: mapped address
	"node7.secret-provider.example",              // FQDN / SNI / donor (dotted)
	"deadbeef99.tracker.example",                 // FQDN whose leading label is hex-ish (must NOT fragment)
	"nl1-amsterdam",                              // BARE location-coded hostname via _HOSTNAME= (no dot)
	"kz1-almaty",                                 // BARE location-coded hostname via sni= (no dot)
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

// seededBundle embeds every needle in plausible journal / config log lines. A trailing clock-time line
// is included to prove the IPv6 rule does NOT over-redact HH:MM:SS (timestamp / chronology preserved).
const seededBundle = `level=error msg="handshake" src=203.0.113.47 uuid=11111111-2222-4333-8444-555555555555
_HOSTNAME=nl1-amsterdam sni=kz1-almaty server_name=node7.secret-provider.example
reality private_key=AOz1pK3rJ8XwVxqLmNbCdEfGhIjKlMnOpQrStUvWxY short_id=0123abcd
long short_id ref deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
shadowsocks psk=c29tZXNlY3JldHBza3ZhbHVlMTIzNDU2Nzg5MA== password=hunter2pw
peer=[2001:db8::dead:beef] addr fe80::cafe mapped ::ffff:203.0.113.5 mac de:ad:be:ef:00:11
as=AS64500 also ASN 64999 owner User=operator3 path /home/operator7/.config
free-floating FQDN deadbeef99.tracker.example must not fragment
Jun 30 12:34:56 some-service started ok
`

func TestRedactScrubsEveryNeedle(t *testing.T) {
	out := Redact(seededBundle)

	for _, n := range piiNeedles {
		if strings.Contains(out, n) {
			t.Errorf("PII needle survived redaction: %q\n--- output ---\n%s", n, out)
		}
	}
	// Sanity: the structural log scaffolding (keys, levels) is preserved — we redact values, not lines.
	for _, keep := range []string{"level=error", "_HOSTNAME=", "reality private_key=", "shadowsocks psk="} {
		if !strings.Contains(out, keep) {
			t.Errorf("redaction destroyed structural context %q (should redact values, not keys)", keep)
		}
	}
	// A clock time must survive — the IPv6 rule must not eat HH:MM:SS (would destroy log chronology).
	if !strings.Contains(out, "12:34:56") {
		t.Errorf("redaction ate a clock timestamp (12:34:56) as if it were IPv6\n--- output ---\n%s", out)
	}
}

func TestRedactIsDeterministicAndIdempotent(t *testing.T) {
	once := Redact(seededBundle)
	if Redact(seededBundle) != once {
		t.Error("Redact is not deterministic")
	}
	// Idempotence is load-bearing: a re-run over already-redacted text (e.g. a bundle piped through twice)
	// must be a no-op — no class may re-match an emitted "[redacted-*]" sentinel and append cruft.
	if Redact(once) != once {
		t.Errorf("Redact is not idempotent:\n--- once ---\n%s\n--- twice ---\n%s", once, Redact(once))
	}
}
