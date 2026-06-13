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
// EdgeReport and TransportClass are INERT, typed Phase-0-2 schemas — data models and pure validation
// only (no I/O, no network, no emission). They are the substrate for the *in-region edge reporting*
// the Mycelium observability doctrine makes its priority (VIS-0006 §4): the only vantage that can tell
// whether a node is reachable FROM a network where access is blocked is the edge — the user/client
// inside that network. ACTUALLY EMITTING an EdgeReport is opt-in telemetry and is **Phase 2**
// (the Measurement track), gated behind Phase 0-1 completion; NOTHING produces or consumes this type
// in Phase 0-2. The shape exists now so the future does not have to break it.
// -----------------------------------------------------------------------------

// TransportClass names a COARSE transport FAMILY for an edge reachability report — the same
// independent-family taxonomy as ADR-0010 / ADR-0020 (VLESS+REALITY over TLS/TCP is ONE family
// regardless of Vision/gRPC/XHTTP framing). It is deliberately coarse: an edge report says "the
// REALITY-TCP family was reachable from this region bucket", never which node, endpoint, port, or
// SNI. Wire values are the lowercase strings below; never hardcode them at call sites
// (development.md §1.1).
type TransportClass string

const (
	// TransportClassUnknown is the zero value and is never valid on the wire.
	TransportClassUnknown TransportClass = ""
	// TransportClassRealityTCP is the VLESS+REALITY over TLS/TCP family (Vision/gRPC/XHTTP).
	TransportClassRealityTCP TransportClass = "reality-tcp"
	// TransportClassQUICUDP is the QUIC/UDP family (Hysteria2, TUIC).
	TransportClassQUICUDP TransportClass = "quic-udp"
	// TransportClassShadowsocksTCP is the Shadowsocks-2022 over TCP family.
	TransportClassShadowsocksTCP TransportClass = "shadowsocks-tcp"
	// TransportClassShadowTLSTCP is the ShadowTLS over TCP family.
	TransportClassShadowTLSTCP TransportClass = "shadowtls-tcp"
	// TransportClassTrojanTLS is the Trojan over TLS family.
	TransportClassTrojanTLS TransportClass = "trojan-tls"
	// TransportClassAmneziaWGUDP is the AmneziaWG (obfuscated WireGuard) over UDP family.
	TransportClassAmneziaWGUDP TransportClass = "amneziawg-udp"
)

// IsValid reports whether the class is one of the canonical members (the unset zero value is not
// valid).
func (c TransportClass) IsValid() bool {
	switch c {
	case TransportClassRealityTCP, TransportClassQUICUDP, TransportClassShadowsocksTCP,
		TransportClassShadowTLSTCP, TransportClassTrojanTLS, TransportClassAmneziaWGUDP:
		return true
	default:
		return false
	}
}

// EdgeReport is the inert, typed shape of an OPT-IN, identity-free reachability report from an EDGE
// vantage — a client inside a network where access may be blocked. It answers the vantage question
// (VIS-0006 §1): could the edge reach a transport CLASS, bucketed by a COARSE region? It carries NO
// PII by construction — no client identity, no precise location, no IP/ASN, no destination endpoint or
// SNI; only a coarse region bucket, a coarse transport class, aggregate reachable/unreachable counts
// that must meet a minimum-aggregation floor, and a decay policy. Inert in Phase 0-2; emission is
// Phase-2 opt-in telemetry.
//
// RegionBucket MUST be a coarse, opaque bucket label (never a precise location, city, or AS number).
// Validate() enforces structure and the floor, but cannot by itself prove a bucket is coarse — pinning
// RegionBucket/TransportClass to closed, audited vocabularies and adding the noise/cumulative-disclosure
// model is a Phase-2 prerequisite tracked in the stress-digest schema-hardening ADR (VIS-0006 §9), not
// here.
type EdgeReport struct {
	Version        int              `json:"version"`         // schema version (NetworkStateVersion)
	RegionBucket   string           `json:"region_bucket"`   // opaque COARSE region label (no precise geo, no ASN, no identity)
	TransportClass TransportClass   `json:"transport_class"` // coarse transport family (no node/endpoint/port/SNI)
	Reachable      int              `json:"reachable"`       // aggregated edge observations that REACHED the class
	Unreachable    int              `json:"unreachable"`     // aggregated edge observations that FAILED to reach it
	SampleCount    int              `json:"sample_count"`    // total underlying edge observations (= reachable + unreachable)
	MinAggregate   int              `json:"min_aggregate"`   // minimum-aggregation (k-anonymity) floor this report must meet
	SpeedClass     SignalSpeedClass `json:"speed_class"`     // always SignalSpeedMedium (an aggregated edge summary)
	ObservedAt     time.Time        `json:"observed_at"`     // RFC 3339, UTC
	Retention      DecayPolicy      `json:"retention"`       // how this report decays and when it is dropped
}

// ReachRatio returns reachable / (reachable + unreachable) in [0,1], or 0 when there are no
// observations. It is a pure helper, not a stored field.
func (r *EdgeReport) ReachRatio() float64 {
	total := r.Reachable + r.Unreachable
	if total <= 0 {
		return 0
	}
	return float64(r.Reachable) / float64(total)
}

// Validate checks the schema version, a non-empty coarse region bucket, a known transport class,
// non-negative counts whose sum equals the sample count, a non-negative aggregation floor that the
// sample count meets, the medium speed class, and a valid retention policy. It is pure: same input,
// same verdict, no side effects. It does NOT verify that the bucket/class are drawn from a closed
// vocabulary (a Phase-2 hardening step) and it performs no I/O.
func (r *EdgeReport) Validate() error {
	if r.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported edge report version %d (want %d)", r.Version, NetworkStateVersion)
	}
	if r.RegionBucket == "" {
		return fmt.Errorf("%w: region_bucket", ErrEmptyField)
	}
	if !r.TransportClass.IsValid() {
		return fmt.Errorf("%w: transport class %q", ErrUnknownEnum, r.TransportClass)
	}
	if r.Reachable < 0 || r.Unreachable < 0 {
		return fmt.Errorf("edge report (%s/%s): reachable and unreachable must be >= 0", r.RegionBucket, r.TransportClass)
	}
	if r.Reachable+r.Unreachable != r.SampleCount {
		return fmt.Errorf("edge report (%s/%s): reachable+unreachable (%d) must equal sample_count (%d)",
			r.RegionBucket, r.TransportClass, r.Reachable+r.Unreachable, r.SampleCount)
	}
	if r.MinAggregate < 0 {
		return fmt.Errorf("edge report (%s/%s): min_aggregate must be >= 0, got %d", r.RegionBucket, r.TransportClass, r.MinAggregate)
	}
	if r.SampleCount < r.MinAggregate {
		return fmt.Errorf("%w: have %d, need %d", ErrAggregationFloor, r.SampleCount, r.MinAggregate)
	}
	if r.SpeedClass != SignalSpeedMedium {
		return fmt.Errorf("%w: edge reports are medium-class, got %q", ErrUnknownEnum, r.SpeedClass)
	}
	if err := r.Retention.Validate(); err != nil {
		return fmt.Errorf("edge report retention: %w", err)
	}
	return nil
}
