// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"sync"
	"testing"
	"time"
)

var base = time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)

func TestRegistryRecordAndHealth(t *testing.T) {
	r := NewRegistry(60 * time.Second)
	r.Record("a", true, base)
	r.Record("a", false, base.Add(time.Second))
	r.Record("a", true, base.Add(2*time.Second))

	h, ok := r.Health("a", base.Add(2*time.Second))
	if !ok {
		t.Fatal("want known ref a")
	}
	if h.TransportRef != "a" || h.Successes != 2 || h.Failures != 1 {
		t.Fatalf("health = %+v, want ref a 2/1", h)
	}
	if err := h.Validate(); err != nil {
		t.Fatalf("produced TransportHealth must validate: %v", err)
	}
	if got := h.SuccessRatio(); got < 0.66 || got > 0.67 {
		t.Fatalf("SuccessRatio = %v, want ~0.6667", got)
	}
}

func TestRegistryWindowPruning(t *testing.T) {
	r := NewRegistry(10 * time.Second)
	r.Record("a", true, base)                     // ages out
	r.Record("a", true, base.Add(20*time.Second)) // inside window

	h, _ := r.Health("a", base.Add(20*time.Second))
	if h.Successes != 1 || h.Failures != 0 {
		t.Fatalf("after pruning health = %+v, want 1/0", h)
	}
	// The aged-out sample must also be excluded when read at a later now.
	h2, _ := r.Health("a", base.Add(25*time.Second))
	if h2.Successes != 1 {
		t.Fatalf("read-time window health = %+v, want 1 success", h2)
	}
}

func TestRegistryUnknownRef(t *testing.T) {
	r := NewRegistry(time.Minute)
	if _, ok := r.Health("missing", base); ok {
		t.Fatal("want ok=false for an unknown ref")
	}
}

func TestRegistrySnapshotOrder(t *testing.T) {
	r := NewRegistry(time.Minute)
	r.Record("x", true, base)
	r.Record("y", false, base)
	r.Record("x", false, base.Add(time.Second))

	snap := r.Snapshot(base.Add(time.Second))
	if len(snap) != 2 {
		t.Fatalf("snapshot len = %d, want 2", len(snap))
	}
	if snap[0].TransportRef != "x" || snap[1].TransportRef != "y" {
		t.Fatalf("snapshot order = [%s,%s], want [x,y]", snap[0].TransportRef, snap[1].TransportRef)
	}
	if snap[0].Successes != 1 || snap[0].Failures != 1 {
		t.Fatalf("x health = %+v, want 1/1", snap[0])
	}
}

func TestRegistryConcurrent(t *testing.T) {
	r := NewRegistry(time.Minute)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			ref := "ref-" + string(rune('a'+n%3))
			for j := 0; j < 100; j++ {
				r.Record(ref, j%2 == 0, base.Add(time.Duration(j)*time.Millisecond))
			}
		}(i)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for j := 0; j < 100; j++ {
			_ = r.Snapshot(base.Add(time.Duration(j) * time.Millisecond))
		}
	}()
	wg.Wait()
	if len(r.Snapshot(base.Add(time.Second))) == 0 {
		t.Fatal("expected some refs recorded")
	}
}
