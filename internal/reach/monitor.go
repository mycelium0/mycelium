// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/mindicator/mycelium/internal/spec"
)

// Monitor runs the node-local reachability measurement loop: each target is
// probed on its own interval and the outcome is recorded into a shared Registry
// as fast-class spec.TransportHealth. It is strictly local (ADR-0019): it never
// classifies channel state, rotates a transport, actuates routing, assembles
// topology, or emits anything off the node. It exists only when an operator
// supplies a config.
type Monitor struct {
	cfg    Config
	prober Prober
	reg    *Registry
	now    func() time.Time // injectable clock; defaults to time.Now
}

// New builds a Monitor from a validated config. A nil prober defaults to the
// network dial prober. It returns an error if the config does not validate
// (fail-closed — the caller, having been handed a config, must not run a
// half-configured monitor).
func New(cfg Config, prober Prober) (*Monitor, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("reach: refusing to start monitor: %w", err)
	}
	if prober == nil {
		prober = NewDialProber()
	}
	return &Monitor{
		cfg:    cfg,
		prober: prober,
		reg:    NewRegistry(time.Duration(cfg.WindowMS) * time.Millisecond),
		now:    time.Now,
	}, nil
}

// Run probes every target on its interval until ctx is cancelled, then waits for
// the per-target goroutines to drain and returns ctx.Err(). Each target gets one
// goroutine and one ticker.
func (m *Monitor) Run(ctx context.Context) error {
	var wg sync.WaitGroup
	for i := range m.cfg.Targets {
		t := m.cfg.Targets[i]
		wg.Add(1)
		go func() {
			defer wg.Done()
			m.runTarget(ctx, t)
		}()
	}
	wg.Wait()
	return ctx.Err()
}

// runTarget probes t immediately, then on every interval tick, until ctx ends.
func (m *Monitor) runTarget(ctx context.Context, t Target) {
	ticker := time.NewTicker(time.Duration(t.IntervalMS) * time.Millisecond)
	defer ticker.Stop()
	m.probeOnce(ctx, t)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.probeOnce(ctx, t)
		}
	}
}

// probeOnce runs one probe and records its outcome, unless ctx has already been
// cancelled (so shutdown does not record a spurious failure).
func (m *Monitor) probeOnce(ctx context.Context, t Target) {
	if ctx.Err() != nil {
		return
	}
	res := m.prober.Probe(ctx, t)
	if ctx.Err() != nil {
		return
	}
	m.reg.Record(t.Ref, res.OK, m.now())
}

// Snapshot returns the current redacted per-anchor health (opaque refs only).
func (m *Monitor) Snapshot() []spec.TransportHealth {
	return m.reg.Snapshot(m.now())
}
