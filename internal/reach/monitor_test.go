// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// fakeProber records call counts and returns a fixed outcome per ref. It ignores
// the context and the network so the loop is deterministic.
type fakeProber struct {
	mu     sync.Mutex
	calls  map[string]int
	result map[string]bool
}

func newFakeProber(result map[string]bool) *fakeProber {
	return &fakeProber{calls: map[string]int{}, result: result}
}

func (f *fakeProber) Probe(_ context.Context, t Target) Result {
	f.mu.Lock()
	f.calls[t.Ref]++
	ok := f.result[t.Ref]
	f.mu.Unlock()
	return Result{OK: ok}
}

func (f *fakeProber) count(ref string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[ref]
}

func TestMonitorNewRejectsInvalidConfig(t *testing.T) {
	if _, err := New(Config{Version: 0}, newFakeProber(nil)); err == nil {
		t.Fatal("want an error for an invalid config, got nil")
	}
}

func TestMonitorRunRecords(t *testing.T) {
	cfg := Config{
		Version:  ConfigVersion,
		WindowMS: 60000,
		Targets: []Target{
			{Ref: "up", Method: MethodTCP, Address: "127.0.0.1:1", IntervalMS: 5, TimeoutMS: 5},
			{Ref: "down", Method: MethodTCP, Address: "127.0.0.1:1", IntervalMS: 5, TimeoutMS: 5},
		},
	}
	fake := newFakeProber(map[string]bool{"up": true, "down": false})
	m, err := New(cfg, fake)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- m.Run(ctx) }()

	deadline := time.Now().Add(2 * time.Second)
	for fake.count("up") < 1 || fake.count("down") < 1 {
		if time.Now().After(deadline) {
			cancel()
			<-done
			t.Fatal("targets were not probed within the deadline")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	if runErr := <-done; !errors.Is(runErr, context.Canceled) {
		t.Fatalf("Run returned %v, want context.Canceled", runErr)
	}

	var sawUp, sawDown bool
	for _, h := range m.Snapshot() {
		switch h.TransportRef {
		case "up":
			sawUp = true
			if h.Successes < 1 || h.Failures != 0 {
				t.Fatalf("up health = %+v, want successes>=1 failures=0", h)
			}
		case "down":
			sawDown = true
			if h.Failures < 1 || h.Successes != 0 {
				t.Fatalf("down health = %+v, want failures>=1 successes=0", h)
			}
		}
	}
	if !sawUp || !sawDown {
		t.Fatalf("snapshot missing a ref: sawUp=%v sawDown=%v", sawUp, sawDown)
	}
}
