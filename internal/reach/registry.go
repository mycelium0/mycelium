// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"sync"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

// sample is one recorded probe outcome at a point in time. It holds no address,
// identity, or location — only when it happened and whether it succeeded.
type sample struct {
	at time.Time
	ok bool
}

// Registry holds, per opaque anchor ref, a sliding window of probe outcomes and
// projects them onto the inert fast-class spec.TransportHealth shape. It is
// concurrency-safe (the monitor records from one goroutine per target while the
// daemon's HTTP handler reads snapshots) and time is injected via the now
// argument so it is testable without sleeping.
type Registry struct {
	mu     sync.Mutex
	window time.Duration
	obs    map[string][]sample
	refs   []string // refs in first-seen order, for stable snapshots
}

// NewRegistry returns an empty registry whose health windows span the given
// duration. A non-positive window is clamped by the caller (the config validator
// rejects it); NewRegistry stores it as given.
func NewRegistry(window time.Duration) *Registry {
	return &Registry{window: window, obs: make(map[string][]sample)}
}

// Record appends an outcome for ref observed at now and drops samples that have
// aged out of the window. First use of a ref registers it for snapshots.
func (r *Registry) Record(ref string, ok bool, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, seen := r.obs[ref]; !seen {
		r.refs = append(r.refs, ref)
	}
	samples := append(r.obs[ref], sample{at: now, ok: ok})
	cutoff := now.Add(-r.window)
	drop := 0
	for drop < len(samples) && samples[drop].at.Before(cutoff) {
		drop++
	}
	r.obs[ref] = samples[drop:]
}

// healthLocked builds the TransportHealth for ref over the window ending at now.
// The caller must hold r.mu.
func (r *Registry) healthLocked(ref string, now time.Time) spec.TransportHealth {
	cutoff := now.Add(-r.window)
	var succ, fail int
	for _, s := range r.obs[ref] {
		if s.at.Before(cutoff) {
			continue
		}
		if s.ok {
			succ++
		} else {
			fail++
		}
	}
	return spec.TransportHealth{
		TransportRef: ref,
		Successes:    succ,
		Failures:     fail,
		WindowStart:  cutoff,
		WindowEnd:    now,
	}
}

// Health returns the TransportHealth for ref over the window ending at now, and
// whether ref is known.
func (r *Registry) Health(ref string, now time.Time) (spec.TransportHealth, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.obs[ref]; !ok {
		return spec.TransportHealth{}, false
	}
	return r.healthLocked(ref, now), true
}

// Snapshot returns the TransportHealth for every known ref over the window
// ending at now, in first-seen order. The result carries opaque refs only.
func (r *Registry) Snapshot(now time.Time) []spec.TransportHealth {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]spec.TransportHealth, 0, len(r.refs))
	for _, ref := range r.refs {
		out = append(out, r.healthLocked(ref, now))
	}
	return out
}
