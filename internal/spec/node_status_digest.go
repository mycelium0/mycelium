// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"sort"
	"time"
)

// aggregateHealth collapses a transport CLASS's member advisory-healths into ONE class HealthValue,
// alive-dominant: the class is alive if ANY member is alive (the class still has a working path),
// else degraded if any member is degraded, else unknown. The inputs are already the lossy
// advisory-health projection (never the detector's fine state), so this never re-introduces it.
func aggregateHealth(hs []HealthValue) HealthValue {
	anyAlive, anyDegraded := false, false
	for _, h := range hs {
		switch h {
		case HealthAlive:
			anyAlive = true
		case HealthDegraded:
			anyDegraded = true
		}
	}
	switch {
	case anyAlive:
		return HealthAlive
	case anyDegraded:
		return HealthDegraded
	default:
		return HealthUnknown
	}
}

// BuildNodeStatusDigest constructs an emit-safe NodeStatusDigest (ADR-0030) from per-class advisory-
// health observations — each the lossy `AdvisoryHealth()` projection of one member's fine connectivity
// state (the ONLY externalisable view; the caller projects, never this function, so this package never
// touches the detector's fine state). It is the INERT constructor for the advisory-emit seam: pure, no I/O,
// no live emission, no signing — RP-0010 C5 / ADR-0030 land the seam; the live emitter/cache/publisher
// is a future cross-cutting RP. It enforces the privacy invariants BY CONSTRUCTION:
//
//   - k-FLOOR + OMIT-NOT-ZERO (ADR-0030 AGGREGATION_FLOOR): a class is emitted only if it has >= k
//     member observations; a sub-floor class is DROPPED entirely — never zeroed or imputed — so a
//     single member's state is never externally distinguishable.
//   - CLASS-AGGREGATE (no per-node row): each cell is one (class, HealthValue), aggregated
//     alive-dominant; there is no per-member row and no member reference — the type makes the rejected
//     per-node shape unrepresentable.
//   - REGION_COARSENESS: region is forced to RegionUnspecified until the region-vocab hardening lands.
//   - deterministic: classes are emitted in a stable (sorted) order, so the same observations yield the
//     same digest (no map-iteration nondeterminism — relevant to CUMULATIVE_DISCLOSURE).
//
// It returns ErrAggregationFloor if NO class meets the floor (emit nothing rather than a sub-floor
// digest — fail-closed). scope is the operator's coarse, opaque, non-geographic trust scope (never a
// per-node identifier). ttl bounds the digest against replay. The result is Validate()-clean.
func BuildNodeStatusDigest(scope TrustScope, obs map[TransportClass][]HealthValue, k int, ttl time.Duration, now time.Time) (NodeStatusDigest, error) {
	if k < 1 {
		return NodeStatusDigest{}, fmt.Errorf("node status digest: k (min-aggregation floor) must be >= 1, got %d", k)
	}
	if ttl <= 0 {
		return NodeStatusDigest{}, fmt.Errorf("%w (node status digest build: ttl must be > 0)", ErrBadTTL)
	}

	// Stable class order (sorted by the closed-vocab string) for determinism.
	classes := make([]TransportClass, 0, len(obs))
	for c := range obs {
		classes = append(classes, c)
	}
	sort.Slice(classes, func(i, j int) bool { return classes[i] < classes[j] })

	var cells []ClassHealth
	sample := 0
	for _, c := range classes {
		hs := obs[c]
		if len(hs) < k { // k-floor: omit-not-zero
			continue
		}
		if !c.IsValid() {
			return NodeStatusDigest{}, fmt.Errorf("%w: observation class %q", ErrUnknownEnum, c)
		}
		cells = append(cells, ClassHealth{Class: c, Health: aggregateHealth(hs)})
		sample += len(hs)
	}
	if len(cells) == 0 {
		return NodeStatusDigest{}, fmt.Errorf("%w: no transport class meets the k=%d floor (emit nothing, never a sub-floor digest)", ErrAggregationFloor, k)
	}

	d := NodeStatusDigest{
		Version:      NetworkStateVersion,
		Scope:        scope,
		Classes:      cells,
		Region:       RegionUnspecified,
		SampleCount:  sample,
		MinAggregate: k,
		IssuedAt:     now.UTC(),
		ExpiresAt:    now.UTC().Add(ttl),
	}
	if err := d.Validate(); err != nil {
		return NodeStatusDigest{}, fmt.Errorf("node status digest build produced an invalid digest: %w", err)
	}
	return d, nil
}
