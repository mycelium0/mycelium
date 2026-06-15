// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"time"
)

// -----------------------------------------------------------------------------
// Phase discipline.
//
// Bundle is the INERT, typed shape of a per-node distribution bundle — the matured form of the Phase-0
// out-of-band hand-rendered subscription (ADR-0020 §1), and the §15.8 seam the fungi layer (VIS-0007)
// later sits behind. It is a data model + pure validation only (no I/O, no serving, no network). The
// served endpoint that emits it (`profile-update-interval`, fail-closed last-known-good) and the
// client-side `myceliumctl aggregate` that merges several are RP-0007-b/-d build, gated behind the
// Phase-0 GO; NOTHING serves or consumes this type yet. The shape exists now so the future does not
// have to break it (mirrors EdgeReport's discipline).
//
// HEALTH IS ADVISORY-ONLY AND, IN PHASE 1, MUST BE UNKNOWN. A populated health field is a latent
// global health/abuse oracle — exactly what ADR-0025 forbids as a default primitive. Until the
// measurement track (Phase 2) can populate it from edge signals WITHOUT becoming such an oracle,
// Validate() requires Health == HealthUnknown. Health never actuates trust; it is a display hint only.
// -----------------------------------------------------------------------------

// HealthValue is a COARSE, closed-vocabulary advisory health label for a bundle endpoint. It is a
// display hint, never a trust input (ADR-0025: no global abuse/health oracle). Wire values are the
// lowercase strings below.
type HealthValue string

const (
	// HealthUnknown is the zero value and the ONLY value permitted in Phase 1 (advisory-only; the
	// measurement track that populates the others is Phase 2).
	HealthUnknown HealthValue = "unknown"
	// HealthAlive marks an endpoint a vantage recently reached (Phase 2+).
	HealthAlive HealthValue = "alive"
	// HealthDegraded marks an endpoint reachable but impaired (Phase 2+).
	HealthDegraded HealthValue = "degraded"
)

// IsValid reports whether the health value is one of the canonical members.
func (h HealthValue) IsValid() bool {
	switch h {
	case HealthUnknown, HealthAlive, HealthDegraded:
		return true
	default:
		return false
	}
}

// Endpoint is one selectable entry in a distribution bundle: a coarse transport CLASS (the closed
// ADR-0010/0020 family taxonomy, NOT a node/endpoint/port/SNI leak — those live opaquely in Link), a
// coarse region bucket, a client selection-order hint, an advisory health label, and the opaque
// client config the holder dials (e.g. a vless:// URL). The bundle carries the dialable Link because it
// IS the client's own subscription (unlike EdgeReport, which is identity-free telemetry); Region remains
// a coarse bucket so the bundle does not itself become a precise-location map.
type Endpoint struct {
	Tag            string         `json:"tag"`             // client-facing label for this endpoint; non-empty
	TransportClass TransportClass `json:"transport_class"` // coarse family (closed vocab)
	Region         string         `json:"region"`          // opaque COARSE region bucket (no precise geo/ASN)
	Priority       int            `json:"priority"`        // selection-order hint (lower = preferred); >= 0
	Health         HealthValue    `json:"health"`          // advisory only; Phase 1 requires HealthUnknown
	Link           string         `json:"link"`            // opaque dialable client config (e.g. vless:// URL); non-empty
}

// Validate checks one endpoint: non-empty tag, a known transport class, a non-empty coarse region, a
// non-negative priority, a known health value that (in Phase 1) is HealthUnknown, and a non-empty link.
// Pure: same input, same verdict, no I/O. Like EdgeReport.Validate it cannot by itself prove the region
// bucket is coarse (a Phase-2 closed-vocabulary-hardening step), only that the structure holds.
func (e *Endpoint) Validate() error {
	if e.Tag == "" {
		return fmt.Errorf("%w: tag", ErrEmptyField)
	}
	if !e.TransportClass.IsValid() {
		return fmt.Errorf("%w: transport class %q", ErrUnknownEnum, e.TransportClass)
	}
	if e.Region == "" {
		return fmt.Errorf("%w: region", ErrEmptyField)
	}
	if e.Priority < 0 {
		return fmt.Errorf("endpoint %q: priority must be >= 0, got %d", e.Tag, e.Priority)
	}
	if !e.Health.IsValid() {
		return fmt.Errorf("%w: health %q", ErrUnknownEnum, e.Health)
	}
	if e.Health != HealthUnknown {
		// Phase-1 invariant (ADR-0025): health is advisory-only and never actuates trust; populating it is
		// the Phase-2 measurement track. Reject any non-unknown value until then.
		return fmt.Errorf("endpoint %q: health is advisory-only in Phase 1 and must be %q, got %q",
			e.Tag, HealthUnknown, e.Health)
	}
	if e.Link == "" {
		return fmt.Errorf("%w: link", ErrEmptyField)
	}
	return nil
}

// Bundle is the inert, typed shape of a per-node distribution bundle: a schema version, a non-empty list
// of selectable endpoints, and a generation timestamp. The served, self-updating endpoint that emits it
// is Phase-1 build (RP-0007-b); this type is the data model it produces and the client aggregates.
type Bundle struct {
	Version     int        `json:"version"`      // schema version (NetworkStateVersion)
	Endpoints   []Endpoint `json:"endpoints"`    // selectable entries; at least one
	GeneratedAt time.Time  `json:"generated_at"` // RFC 3339, UTC
}

// Validate checks the schema version, that at least one endpoint is present, and that every endpoint
// validates. Pure: no I/O, no network. It does not serve, sign, or transmit anything.
func (b *Bundle) Validate() error {
	if b.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported bundle version %d (want %d)", b.Version, NetworkStateVersion)
	}
	if len(b.Endpoints) == 0 {
		return fmt.Errorf("%w: endpoints", ErrEmptyField)
	}
	for i := range b.Endpoints {
		if err := b.Endpoints[i].Validate(); err != nil {
			return fmt.Errorf("bundle endpoint[%d]: %w", i, err)
		}
	}
	return nil
}
