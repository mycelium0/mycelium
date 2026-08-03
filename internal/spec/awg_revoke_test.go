// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
)

const awgSample = `[Interface]
PrivateKey = SERVERKEY
Address = 10.13.13.1/24
ListenPort = 443
Jc = 9
Jmin = 49
Jmax = 103
S1 = 86
S2 = 232
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
# name = alice
PublicKey = KEYALICE
PresharedKey = PSKALICE
AllowedIPs = 10.13.13.2/32

[Peer]
# name = bob
PublicKey = KEYBOB
AllowedIPs = 10.13.13.3/32
`

// TestStripAWGPeersIsIdempotent is the regression that the shell gate could not express. The bash
// stripper captured the blank line between sections into the preceding block and re-emitted one, so
// every pass added a blank per surviving peer, without bound — five no-op passes over a live 31-line
// config produced 41 lines. Its gate compared the SECOND revoke of a name that by then owned nothing,
// which short-circuits before the stripper runs, so the growth was invisible. Here the operation itself
// is repeated, which is the only form of the question that means anything.
func TestStripAWGPeersIsIdempotent(t *testing.T) {
	for _, tc := range []struct {
		name   string
		remove []string
	}{
		{"remove nothing", nil},
		{"remove an absent key", []string{"NOSUCHKEY"}},
		{"remove one", []string{"KEYALICE"}},
		{"remove all", []string{"KEYALICE", "KEYBOB"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			once := StripAWGPeers(awgSample, tc.remove)
			cur := once
			for i := 0; i < 5; i++ {
				next := StripAWGPeers(cur, tc.remove)
				if next != cur {
					t.Fatalf("pass %d changed the config; a strip must be byte-identical when repeated.\n--- before ---\n%q\n--- after ---\n%q", i+2, cur, next)
				}
				cur = next
			}
			if n := strings.Count(once, "\n\n\n"); n != 0 {
				t.Fatalf("output contains a run of blank lines (%d) — the separator is being claimed by a section", n)
			}
		})
	}
}

func TestStripAWGPeersRemovesExactly(t *testing.T) {
	for _, tc := range []struct {
		name      string
		remove    []string
		wantPeers []string
	}{
		{"none", nil, []string{"KEYALICE", "KEYBOB"}},
		{"first", []string{"KEYALICE"}, []string{"KEYBOB"}},
		{"second", []string{"KEYBOB"}, []string{"KEYALICE"}},
		{"both", []string{"KEYALICE", "KEYBOB"}, nil},
		{"unknown key is a no-op", []string{"KEYNOBODY"}, []string{"KEYALICE", "KEYBOB"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := StripAWGPeers(awgSample, tc.remove)
			_, peers := ParseAWGConf(got)
			if len(peers) != len(tc.wantPeers) {
				t.Fatalf("peer count = %d, want %d", len(peers), len(tc.wantPeers))
			}
			for i, p := range peers {
				if p.PublicKey != tc.wantPeers[i] {
					t.Errorf("peer %d = %q, want %q", i, p.PublicKey, tc.wantPeers[i])
				}
			}
			if !strings.Contains(got, "[Interface]") || !strings.Contains(got, "PrivateKey = SERVERKEY") {
				t.Error("the [Interface] section did not survive — after the next start this node has no AmneziaWG at all")
			}
			if n := CountAWGDialectLines(got); n != 9 {
				t.Errorf("dialect fields = %d, want 9: a rewrite that loses one bricks the NEXT --awg-regen rather than failing here", n)
			}
		})
	}
}

// TestAWGFieldSeparatorForms: `PublicKey=K` is legal config. A matcher anchored on the literal
// "PublicKey = " does not see such a peer, which in a revoke means failing to remove it while reporting
// success. Every spacing a human or a generator might produce must resolve to the same key.
func TestAWGFieldSeparatorForms(t *testing.T) {
	for _, form := range []string{
		"PublicKey = KEYX",
		"PublicKey=KEYX",
		"PublicKey =KEYX",
		"PublicKey= KEYX",
		"  PublicKey  =  KEYX  ",
	} {
		conf := "[Interface]\nPrivateKey = S\n\n[Peer]\n# name = x\n" + form + "\nAllowedIPs = 10.0.0.2/32\n"
		_, peers := ParseAWGConf(conf)
		if len(peers) != 1 || peers[0].PublicKey != "KEYX" {
			t.Fatalf("form %q parsed as %+v — a peer written this way would survive a revoke that reported success", form, peers)
		}
		if got := StripAWGPeers(conf, []string{"KEYX"}); strings.Contains(got, "KEYX") {
			t.Fatalf("form %q survived the strip", form)
		}
	}
}

// TestAWGRevokeTargets covers the two resolutions and the unnamed census. The name marker may FOLLOW the
// key: the bash resolver decided at the PublicKey line and therefore never saw such a marker.
func TestAWGRevokeTargets(t *testing.T) {
	confMarkerAfterKey := "[Interface]\nPrivateKey = S\n\n[Peer]\nPublicKey = K1\n# name = alice\nAllowedIPs = 10.0.0.2/32\n"
	confTwoUnderOneName := "[Interface]\nPrivateKey = S\n\n[Peer]\n# name = alice\nPublicKey = K1\n\n[Peer]\n# name = alice\nPublicKey = K2\n"
	confUnnamed := "[Interface]\nPrivateKey = S\n\n[Peer]\nPublicKey = ORPHAN\n\n[Peer]\n# name = alice\nPublicKey = K1\n"

	for _, tc := range []struct {
		name        string
		conf        string
		who, stored string
		wantTargets []string
		wantUnnamed []string
	}{
		{"marker after the key is still seen", confMarkerAfterKey, "alice", "", []string{"K1"}, nil},
		{"stored key alone resolves", confMarkerAfterKey, "", "K1", []string{"K1"}, nil},
		{"two peers under one name: BOTH", confTwoUnderOneName, "alice", "K1", []string{"K1", "K2"}, nil},
		{"an unnamed peer is reported, not silently missed", confUnnamed, "alice", "K1", []string{"K1"}, []string{"ORPHAN"}},
		{"a name that owns nothing targets nothing", confTwoUnderOneName, "carol", "", nil, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			targets, unnamed := AWGRevokeTargets(tc.conf, tc.who, tc.stored)
			if strings.Join(targets, ",") != strings.Join(tc.wantTargets, ",") {
				t.Errorf("targets = %v, want %v", targets, tc.wantTargets)
			}
			if strings.Join(unnamed, ",") != strings.Join(tc.wantUnnamed, ",") {
				t.Errorf("unnamed = %v, want %v — an unreachable peer that is not reported lets the caller claim a guarantee it cannot honour", unnamed, tc.wantUnnamed)
			}
		})
	}
}

// TestVerifyAWGStripCatches drives the arithmetic over hand-built "rewrites" that a buggy stripper would
// plausibly produce. The prefix case is the one that bit: the bash check compared keys by substring, so
// KEY contained in KEY2 reported as still-present and aborted a revoke that had succeeded.
func TestVerifyAWGStripCatches(t *testing.T) {
	before := awgSample
	good := StripAWGPeers(before, []string{"KEYALICE"})

	if err := VerifyAWGStrip(before, good, []string{"KEYALICE"}); err != nil {
		t.Fatalf("a correct rewrite was rejected: %v", err)
	}
	if err := VerifyAWGStrip(before, before, []string{"KEYALICE"}); err == nil {
		t.Error("a rewrite that removed NOTHING was accepted while a key was to be removed")
	}
	if err := VerifyAWGStrip(before, StripAWGPeers(before, []string{"KEYALICE", "KEYBOB"}), []string{"KEYALICE"}); err == nil {
		t.Error("a rewrite that removed one peer TOO MANY was accepted")
	}
	noDialect := strings.ReplaceAll(good, "Jc = 9\n", "")
	if err := VerifyAWGStrip(before, noDialect, []string{"KEYALICE"}); err == nil {
		t.Error("a rewrite that dropped a dialect field was accepted — that bricks the next --awg-regen instead of failing here")
	}
	// A key that is a strict prefix of another must not read as "still present".
	pfx := "[Interface]\nPrivateKey = S\n\n[Peer]\n# name = a\nPublicKey = KEY\n\n[Peer]\n# name = b\nPublicKey = KEY2\n"
	if err := VerifyAWGStrip(pfx, StripAWGPeers(pfx, []string{"KEY"}), []string{"KEY"}); err != nil {
		t.Errorf("a correct rewrite was rejected because one key is a prefix of another: %v", err)
	}
}

func TestAWGRevokeNeeded(t *testing.T) {
	for _, tc := range []struct {
		live              int
		stored, inBackups bool
		want              bool
	}{
		{0, false, false, false},
		{1, false, false, true},
		{0, true, false, true},
		{0, false, true, true}, // survives only in a backup — what a failed dialect rollback restores
	} {
		if got := AWGRevokeNeeded(tc.live, tc.stored, tc.inBackups); got != tc.want {
			t.Errorf("AWGRevokeNeeded(%d,%v,%v) = %v, want %v", tc.live, tc.stored, tc.inBackups, got, tc.want)
		}
	}
}
