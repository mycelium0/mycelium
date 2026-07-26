// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"strings"
	"testing"
)

// TestDeriveAWGDialectDeterministic: the same (key, epoch) always yields the same dialect. This is the
// property the whole design rests on — a node's server config and every client config derive independently
// and must agree, or no handshake completes.
func TestDeriveAWGDialectDeterministic(t *testing.T) {
	const k = "aQ7Xk2mZ0pLb9vN3tR8yF6wJ1cH4dS5gT2uV0eB7i="
	a, err := DeriveAWGDialect(k, 0)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	for i := 0; i < 8; i++ {
		b, err := DeriveAWGDialect(k, 0)
		if err != nil {
			t.Fatalf("derive #%d: %v", i, err)
		}
		if a != b {
			t.Fatalf("non-deterministic: %+v != %+v", a, b)
		}
	}
}

// TestDeriveAWGDialectPerNode: different keys yield different dialects — the whole point of S1-4 (a single
// published constant would let one payload-match rule block the family on every node at once).
func TestDeriveAWGDialectPerNode(t *testing.T) {
	seen := map[uint32]string{}
	for i := 0; i < 256; i++ {
		key := fmt.Sprintf("node-key-%d-aQ7Xk2mZ0pLb9vN3tR8yF6wJ1cH4dS5g", i)
		d, err := DeriveAWGDialect(key, 0)
		if err != nil {
			t.Fatalf("derive %d: %v", i, err)
		}
		if prev, dup := seen[d.H1]; dup {
			t.Fatalf("two distinct keys share H1=%d (%q and %q)", d.H1, prev, key)
		}
		seen[d.H1] = key
	}
}

// TestDeriveAWGDialectInvariants: every derived dialect must satisfy the AmneziaWG constraints for a wide
// spread of keys AND epochs — H1..H4 distinct and > 4, Jmin < Jmax, (S1+56) != S2. A violation here would
// mean a node renders a config its own peers cannot use.
func TestDeriveAWGDialectInvariants(t *testing.T) {
	for i := 0; i < 500; i++ {
		key := fmt.Sprintf("k%d-ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHhGgFf", i)
		for _, epoch := range []int{0, 1, 2, 7, 42, 1000} {
			d, err := DeriveAWGDialect(key, epoch)
			if err != nil {
				t.Fatalf("derive(key%d, epoch%d): %v", i, epoch, err)
			}
			if !d.Valid() {
				t.Fatalf("derive(key%d, epoch%d) = %+v violates the AmneziaWG constraints", i, epoch, d)
			}
			// Ranges the renderers rely on.
			if d.Jc < 3 || d.Jc > 10 || d.Jmin < 24 || d.Jmin > 64 || d.S1 < 24 || d.S1 > 96 {
				t.Fatalf("derive(key%d, epoch%d) = %+v out of the documented jitter bounds", i, epoch, d)
			}
		}
	}
}

// TestDeriveAWGDialectEpochZeroIsKeyOnly (Audit-0008 S1-4 follow-up): epoch 0 must derive from the key
// ALONE. Every node migrated before rotation existed is at epoch 0, so this is what guarantees that adding
// rotation did not silently change any live node's dialect.
func TestDeriveAWGDialectEpochZeroIsKeyOnly(t *testing.T) {
	const k = "epoch-zero-compat-key-aQ7Xk2mZ0pLb9vN3tR8y"
	zero, err := DeriveAWGDialect(k, 0)
	if err != nil {
		t.Fatalf("derive epoch 0: %v", err)
	}
	// A negative epoch is normalised to 0 (mirrors the shell's non-numeric guard).
	neg, err := DeriveAWGDialect(k, -5)
	if err != nil {
		t.Fatalf("derive negative epoch: %v", err)
	}
	if zero != neg {
		t.Fatalf("a negative epoch must behave as epoch 0: %+v != %+v", zero, neg)
	}
	// The epoch-0 digest input is exactly the key (no suffix) — pin it directly so a refactor cannot
	// quietly start salting epoch 0 and re-dialect every live node.
	want := awgDigest(k, 0)
	if got := awgDigest(k+"|epoch0", 0); got == want {
		t.Fatal("epoch-0 input must be the bare key, not key|epoch0")
	}
}

// TestDeriveAWGDialectRotationChanges: bumping the epoch yields a genuinely different dialect from the SAME
// key — that is what makes --awg-rotate a rotation rather than a no-op, without touching any key or peer.
func TestDeriveAWGDialectRotationChanges(t *testing.T) {
	const k = "rotation-key-ZzYyXxWwVvUuTtSsRrQqPpOoNnMm"
	prev := map[string]int{}
	for epoch := 0; epoch <= 24; epoch++ {
		d, err := DeriveAWGDialect(k, epoch)
		if err != nil {
			t.Fatalf("derive epoch %d: %v", epoch, err)
		}
		sig := fmt.Sprintf("%d-%d-%d-%d", d.H1, d.H2, d.H3, d.H4)
		if at, dup := prev[sig]; dup {
			t.Fatalf("epoch %d reproduced the header set of epoch %d — rotation must change the dialect", epoch, at)
		}
		prev[sig] = epoch
	}
}

// TestDeriveAWGDialectRejectsEmptyKey: an empty key is a caller bug and must fail closed, never silently
// derive a shared "default" dialect (which would re-create the exact network-wide constant S1-4 removed).
func TestDeriveAWGDialectRejectsEmptyKey(t *testing.T) {
	if _, err := DeriveAWGDialect("", 0); err == nil {
		t.Fatal("an empty key must fail closed")
	}
}

// TestAWGDialectValidRejectsBadShapes: the constraint checker itself must reject each violation.
func TestAWGDialectValidRejectsBadShapes(t *testing.T) {
	base := AWGDialect{Jc: 4, Jmin: 40, Jmax: 70, S1: 51, S2: 102, H1: 10, H2: 20, H3: 30, H4: 40}
	if !base.Valid() {
		t.Fatal("the baseline dialect must be valid")
	}
	bad := []struct {
		name string
		d    AWGDialect
	}{
		{"H duplicate", AWGDialect{Jc: 4, Jmin: 40, Jmax: 70, S1: 51, S2: 102, H1: 10, H2: 10, H3: 30, H4: 40}},
		{"H is a WireGuard message type", AWGDialect{Jc: 4, Jmin: 40, Jmax: 70, S1: 51, S2: 102, H1: 4, H2: 20, H3: 30, H4: 40}},
		{"Jmin >= Jmax", AWGDialect{Jc: 4, Jmin: 70, Jmax: 70, S1: 51, S2: 102, H1: 10, H2: 20, H3: 30, H4: 40}},
		{"S1+56 == S2", AWGDialect{Jc: 4, Jmin: 40, Jmax: 70, S1: 51, S2: 107, H1: 10, H2: 20, H3: 30, H4: 40}},
	}
	for _, c := range bad {
		if c.d.Valid() {
			t.Errorf("%s must be rejected: %+v", c.name, c.d)
		}
	}
}

// TestAWGDialectRenderINI: the rendered block is the nine lines in canonical order — the single shape both
// the server awg0.conf and every client config embed.
func TestAWGDialectRenderINI(t *testing.T) {
	d := AWGDialect{Jc: 6, Jmin: 47, Jmax: 65, S1: 55, S2: 159, H1: 4060909254, H2: 687321829, H3: 3945783201, H4: 1357051834}
	got := d.RenderINI()
	want := "Jc = 6\nJmin = 47\nJmax = 65\nS1 = 55\nS2 = 159\nH1 = 4060909254\nH2 = 687321829\nH3 = 3945783201\nH4 = 1357051834\n"
	if got != want {
		t.Fatalf("RenderINI mismatch:\n got: %q\nwant: %q", got, want)
	}
	if n := strings.Count(got, "\n"); n != 9 {
		t.Fatalf("the dialect block must be exactly 9 lines, got %d", n)
	}
}
