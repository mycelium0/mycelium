// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package diag

import (
	"strings"
	"testing"
)

// piiNeedles are realistic-looking but FAKE PII values, one per redaction class. The runtime invariant
// is simple and load-bearing: after Redact, NONE of these may survive anywhere in the output.
var piiNeedles = []string{
	"203.0.113.47",                                                     // IPv4 (TEST-NET-3 documentation range)
	"2001:db8::dead:beef",                                              // IPv6 (documentation range)
	"node7.secret-provider.example",                                    // FQDN / hostname / SNI / donor
	"11111111-2222-4333-8444-555555555555",                             // client UUID
	"AOz1pK3rJ8XwVxqLmNbCdEfGhIjKlMnOpQrStUvWxY",                       // x25519 / REALITY base64url key (43)
	"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef", // 64-hex key material
	"c29tZXNlY3JldHBza3ZhbHVlMTIzNDU2Nzg5MA==",                         // shadowsocks PSK / password (base64, >=32)
	"AS64500", // autonomous-system number
}

func TestRedactScrubsEveryNeedle(t *testing.T) {
	// A synthetic bundle: the needles embedded in plausible log lines.
	var b strings.Builder
	b.WriteString("level=error msg=\"handshake from client\" src=203.0.113.47 uuid=11111111-2222-4333-8444-555555555555\n")
	b.WriteString("_HOSTNAME=node7.secret-provider.example sni=node7.secret-provider.example\n")
	b.WriteString("reality private_key=AOz1pK3rJ8XwVxqLmNbCdEfGhIjKlMnOpQrStUvWxY short_id=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n")
	b.WriteString("shadowsocks psk=c29tZXNlY3JldHBza3ZhbHVlMTIzNDU2Nzg5MA== peer=[2001:db8::dead:beef] as=AS64500\n")
	out := Redact(b.String())

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
}

func TestRedactIsDeterministicAndIdempotent(t *testing.T) {
	in := "ip 203.0.113.47 host a.b.example uuid 11111111-2222-4333-8444-555555555555"
	once := Redact(in)
	if Redact(in) != once {
		t.Error("Redact is not deterministic")
	}
	if Redact(once) != once {
		t.Errorf("Redact is not idempotent: %q -> %q", once, Redact(once))
	}
}
