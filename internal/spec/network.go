// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"errors"
	"fmt"
	"time"
)

// NetworkStateVersion is the schema version of the distributed-awareness data
// models in this file (EdgeState, TopologyFragment, SporeEnvelope, and the
// signal types). It is bumped independently of StateVersion (identity state) and
// of Version (the SemVer spine). It is the single runtime source of truth for
// these schemas (development.md §1.1) — call sites must not hardcode it.
const NetworkStateVersion = 1

// -----------------------------------------------------------------------------
// Phase discipline.
//
// EVERY type in this file is an INERT, typed Phase-0-2 schema. They are data
// models and pure validation logic only: no goroutines, no I/O, no network, no
// DHT, no gossip, no registry, no announce-into-mesh, and no autonomous cord
// promotion. Behaviour that reads or acts on these structures is wired in
// Phase 3-4 (see VIS-0003 §4 "Non-goals — phase discipline" and VIS-0004). The
// shapes exist now so that the future does not have to break them; nothing here
// runs on its own.
// -----------------------------------------------------------------------------

// Sentinel errors for the network schemas so callers (and tests) can branch with
// errors.Is.
var (
	// ErrUnknownEnum is returned when a typed-string enum field holds a value
	// outside its canonical set.
	ErrUnknownEnum = errors.New("value is not a known enum member")
	// ErrEmptyField is returned when a structurally required field is empty.
	ErrEmptyField = errors.New("a required field is empty")
	// ErrBadTTL is returned when an artifact's expiry is not strictly after its
	// issue time.
	ErrBadTTL = errors.New("expires_at must be strictly after issued_at")
	// ErrOutOfRange is returned when a measured ratio or weight falls outside its
	// permitted [0,1] interval.
	ErrOutOfRange = errors.New("measured value is outside the permitted range")
	// ErrAggregationFloor is returned when an aggregated summary does not meet its
	// minimum-aggregation floor (the k-anonymity-style sample threshold).
	ErrAggregationFloor = errors.New("aggregated sample count is below the minimum-aggregation floor")
)

// TrustScope is a bounded, named region of trust within which an artifact, edge,
// or signal is meaningful. It is the unit of compartmentalisation: revocations,
// stress, and topology are scoped to it and never leak raw across it
// (concept 9, the compartment wound response). It carries no global identity —
// it is a label plus an optional bound on how far it may propagate. It is inert
// in Phase 0-2; scope-aware reconciliation is Phase 3-4 (VIS-0003 §2).
//
// The compartment "sealed/healing" state of concept 9 is deliberately NOT a bare
// boolean here: sealing is threshold-gated and TTL-bounded so false seals
// self-heal (VIS-0004 §5 concept 9), and that contract lives on the future
// QuarantinePolicy-adjacent compartment state, not on this label. TrustScope
// stays a pure scope identifier.
type TrustScope struct {
	ID      string `json:"id"`       // opaque scope identifier (no PII, no location)
	Label   string `json:"label"`    // human-readable name for operators
	MaxHops int    `json:"max_hops"` // 0 = local only; how far this scope may propagate
}

// Validate checks that a TrustScope has a non-empty id and a non-negative hop
// bound. It is pure: same input, same verdict, no side effects.
func (t *TrustScope) Validate() error {
	if t.ID == "" {
		return fmt.Errorf("%w: trust scope id", ErrEmptyField)
	}
	if t.MaxHops < 0 {
		return fmt.Errorf("trust scope %q: max_hops must be >= 0, got %d", t.ID, t.MaxHops)
	}
	return nil
}

// SignalSpeedClass classifies a signal by how fast it may influence the network,
// per the signal-speed-classes doctrine (concept 7). Faster classes drive
// cheaper, more reversible decisions; slower and threshold-signed classes drive
// trust and revocation. The wire values are the lowercase strings below; never
// hardcode them at call sites (development.md §1.1).
type SignalSpeedClass string

const (
	// SignalSpeedUnknown is the zero value; it is never a valid wire value and
	// signals an unset or unrecognised class.
	SignalSpeedUnknown SignalSpeedClass = ""
	// SignalSpeedFast is volatile health that feeds routing only (concept 7).
	SignalSpeedFast SignalSpeedClass = "fast"
	// SignalSpeedMedium is aggregated stress summaries that bias exploration
	// (concept 7).
	SignalSpeedMedium SignalSpeedClass = "medium"
	// SignalSpeedSlow is corroborated evidence that may adjust trust (concept 7).
	SignalSpeedSlow SignalSpeedClass = "slow"
	// SignalSpeedHard is a threshold-signed hard signal that may drive revocation
	// or quarantine (concept 7).
	SignalSpeedHard SignalSpeedClass = "hard"
)

// IsValid reports whether the class is one of the canonical members (the unset
// zero value is not valid).
func (c SignalSpeedClass) IsValid() bool {
	switch c {
	case SignalSpeedFast, SignalSpeedMedium, SignalSpeedSlow, SignalSpeedHard:
		return true
	default:
		return false
	}
}

// TransportHealth is a per-transport, fast-class observation window: a count of
// recent successes and failures plus the window bounds. It feeds routing only
// (SignalSpeedFast, concept 7). It carries no peer identity, no traffic, and no
// location — only opaque transport and observer references and counters. Inert
// in Phase 0-2; nothing aggregates or publishes it yet.
type TransportHealth struct {
	TransportRef string    `json:"transport_ref"` // opaque transport identifier (no SNI, no endpoint)
	Successes    int       `json:"successes"`     // successful probes/sends in the window
	Failures     int       `json:"failures"`      // failed probes/sends in the window
	WindowStart  time.Time `json:"window_start"`  // RFC 3339, UTC
	WindowEnd    time.Time `json:"window_end"`    // RFC 3339, UTC
}

// SuccessRatio returns successes / (successes + failures) in [0,1], or 0 when the
// window is empty. It is a pure helper, not a stored field.
func (h *TransportHealth) SuccessRatio() float64 {
	total := h.Successes + h.Failures
	if total <= 0 {
		return 0
	}
	return float64(h.Successes) / float64(total)
}

// Validate checks structural invariants: a non-empty transport reference,
// non-negative counters, and a window whose end is not before its start.
func (h *TransportHealth) Validate() error {
	if h.TransportRef == "" {
		return fmt.Errorf("%w: transport_ref", ErrEmptyField)
	}
	if h.Successes < 0 || h.Failures < 0 {
		return fmt.Errorf("transport %q: counters must be >= 0", h.TransportRef)
	}
	if h.WindowEnd.Before(h.WindowStart) {
		return fmt.Errorf("transport %q: window_end is before window_start", h.TransportRef)
	}
	return nil
}

// StressSignal is a redacted, scoped summary of failure pressure observed within
// a TrustScope — the stress-memory doctrine carried as a medium-class signal
// (concept 7) that biases exploration. It is deliberately lossy: it holds a
// reason code and a count, never raw traffic, peer identities, or location, and
// it must meet a minimum-aggregation floor before it may be shared (concept 9,
// the minimum-aggregation/k-anonymity floor). Retention and fade are governed by
// a DecayPolicy. Inert in Phase 0-2; no node emits or merges it yet.
type StressSignal struct {
	Scope        TrustScope       `json:"scope"`         // the compartment this stress belongs to
	ReasonCode   string           `json:"reason_code"`   // coarse, enumerable cause class (no free-text PII)
	SampleCount  int              `json:"sample_count"`  // number of underlying observations aggregated
	MinAggregate int              `json:"min_aggregate"` // minimum-aggregation floor this summary must meet
	SpeedClass   SignalSpeedClass `json:"speed_class"`   // always SignalSpeedMedium for stress summaries
	ObservedAt   time.Time        `json:"observed_at"`   // RFC 3339, UTC
	Retention    DecayPolicy      `json:"retention"`     // how this summary decays and when it is dropped
}

// Validate checks that the signal is scoped, redacted to a reason code, carries a
// non-negative aggregation floor, meets that floor, is medium-class, and has a
// valid retention policy. It is pure.
func (s *StressSignal) Validate() error {
	if err := s.Scope.Validate(); err != nil {
		return fmt.Errorf("stress signal scope: %w", err)
	}
	if s.ReasonCode == "" {
		return fmt.Errorf("%w: reason_code", ErrEmptyField)
	}
	if s.MinAggregate < 0 {
		return fmt.Errorf("stress signal: min_aggregate must be >= 0, got %d", s.MinAggregate)
	}
	if s.SampleCount < s.MinAggregate {
		return fmt.Errorf("%w: have %d, need %d", ErrAggregationFloor, s.SampleCount, s.MinAggregate)
	}
	if s.SpeedClass != SignalSpeedMedium {
		return fmt.Errorf("%w: stress summaries are medium-class, got %q", ErrUnknownEnum, s.SpeedClass)
	}
	if err := s.Retention.Validate(); err != nil {
		return fmt.Errorf("stress signal retention: %w", err)
	}
	return nil
}

// GradientKind names a measured directional bias that may, in a later phase, tilt
// exploration and route selection. The source-sink members implement concept 1
// (bias growth toward under-served sinks). Wire values are the lowercase strings
// below; never hardcode them (development.md §1.1).
type GradientKind string

const (
	// GradientKindUnknown is the zero value and is never valid on the wire.
	GradientKindUnknown GradientKind = ""
	// GradientKindDemand is measured demand for reachability in a scope.
	GradientKindDemand GradientKind = "demand"
	// GradientKindScarcity is measured scarcity of capacity in a scope.
	GradientKindScarcity GradientKind = "scarcity"
	// GradientKindPriority is a locally-raised scoped priority earned by
	// contribution (concept 2: reciprocal mutualism, never tokenomics).
	GradientKindPriority GradientKind = "priority"
	// GradientKindSource marks spare-capacity nodes/regions as flow sources
	// (concept 1).
	GradientKindSource GradientKind = "source"
	// GradientKindSink marks degraded/under-served scopes as flow sinks toward
	// which growth is biased (concept 1).
	GradientKindSink GradientKind = "sink"
)

// IsValid reports whether the kind is one of the canonical members.
func (k GradientKind) IsValid() bool {
	switch k {
	case GradientKindDemand, GradientKindScarcity, GradientKindPriority, GradientKindSource, GradientKindSink:
		return true
	default:
		return false
	}
}

// GradientSignal is a measured, scoped bias affecting exploration and routing —
// the gradient doctrine ("gradients guide"). Its Magnitude is a normalised [0,1]
// strength; it is a field that exists in the data model but drives nothing in
// Phase 0-2 (trust-gradient routing is Phase 5, VIS-0003 §4). It carries no
// identities, only a kind, a scope, and a magnitude.
type GradientSignal struct {
	Kind       GradientKind `json:"kind"`        // which directional bias this measures
	Scope      TrustScope   `json:"scope"`       // the region the bias applies to
	Magnitude  float64      `json:"magnitude"`   // normalised strength in [0,1]
	MeasuredAt time.Time    `json:"measured_at"` // RFC 3339, UTC
}

// Validate checks that the kind is known, the scope is valid, and the magnitude
// lies in [0,1]. It is pure.
func (g *GradientSignal) Validate() error {
	if !g.Kind.IsValid() {
		return fmt.Errorf("%w: gradient kind %q", ErrUnknownEnum, g.Kind)
	}
	if err := g.Scope.Validate(); err != nil {
		return fmt.Errorf("gradient scope: %w", err)
	}
	if g.Magnitude < 0 || g.Magnitude > 1 {
		return fmt.Errorf("%w: gradient magnitude %v not in [0,1]", ErrOutOfRange, g.Magnitude)
	}
	return nil
}

// EdgeLifecycle is the authoritative state of a single edge between two endpoints
// (VIS-0003 §4, the established edge-lifecycle vocabulary). It extends the linear
// chain with dormant and scarred as first-class members (concept 6, VIS-0004 §5):
// an edge may decay ordinarily, lie dormant and re-testable, or be scarred/dangerous
// and require stronger evidence before reuse. Wire values are the lowercase strings
// below; never hardcode them (development.md §1.1).
type EdgeLifecycle string

const (
	// EdgeLifecycleUnknown is the zero value and is never valid on the wire.
	EdgeLifecycleUnknown EdgeLifecycle = ""
	// EdgeLifecycleCandidate is a known-but-untested edge.
	EdgeLifecycleCandidate EdgeLifecycle = "candidate"
	// EdgeLifecycleProbed has been cheaply tested by a hyphal probe.
	EdgeLifecycleProbed EdgeLifecycle = "probed"
	// EdgeLifecycleActive is in current use.
	EdgeLifecycleActive EdgeLifecycle = "active"
	// EdgeLifecycleReinforced has accumulated measured usefulness.
	EdgeLifecycleReinforced EdgeLifecycle = "reinforced"
	// EdgeLifecycleCord is a promoted, measured path endpoint (see CordPromotion).
	EdgeLifecycleCord EdgeLifecycle = "cord"
	// EdgeLifecycleDegraded is losing usefulness and is a candidate for demotion.
	EdgeLifecycleDegraded EdgeLifecycle = "degraded"
	// EdgeLifecycleDormant is inactive but re-testable without extra evidence
	// (concept 6).
	EdgeLifecycleDormant EdgeLifecycle = "dormant"
	// EdgeLifecycleScarred is dangerous/suspicious and needs stronger evidence
	// before reuse (concept 6).
	EdgeLifecycleScarred EdgeLifecycle = "scarred"
	// EdgeLifecycleDecayed has aged out of usefulness.
	EdgeLifecycleDecayed EdgeLifecycle = "decayed"
	// EdgeLifecyclePruned has been actively removed to lower enumeration surface
	// and improve dispersion (concept 4).
	EdgeLifecyclePruned EdgeLifecycle = "pruned"
)

// IsValid reports whether the lifecycle value is one of the canonical members.
func (e EdgeLifecycle) IsValid() bool {
	switch e {
	case EdgeLifecycleCandidate, EdgeLifecycleProbed, EdgeLifecycleActive,
		EdgeLifecycleReinforced, EdgeLifecycleCord, EdgeLifecycleDegraded,
		EdgeLifecycleDormant, EdgeLifecycleScarred, EdgeLifecycleDecayed,
		EdgeLifecyclePruned:
		return true
	default:
		return false
	}
}

// EdgeState is the inert, typed record for one edge: its lifecycle, opaque
// endpoint references, measured link weights, and a TTL after which the record
// is stale. Latency and reliability are normalised hints, not promises. No state
// machine runs over these in Phase 0-2; transitions are wired in Phase 3-4
// (VIS-0003 §4).
type EdgeState struct {
	Version     int           `json:"version"`     // schema version (NetworkStateVersion)
	FromRef     string        `json:"from_ref"`    // opaque local endpoint reference (no identity)
	ToRef       string        `json:"to_ref"`      // opaque remote endpoint reference (no identity)
	Lifecycle   EdgeLifecycle `json:"lifecycle"`   // current lifecycle state
	Reliability float64       `json:"reliability"` // measured reliability hint in [0,1]
	LatencyMS   int           `json:"latency_ms"`  // measured one-way latency hint in milliseconds
	Scope       TrustScope    `json:"scope"`       // the trust scope this edge belongs to
	UpdatedAt   time.Time     `json:"updated_at"`  // RFC 3339, UTC
	ExpiresAt   time.Time     `json:"expires_at"`  // RFC 3339, UTC — record is stale after this
}

// Validate checks the schema version, a known lifecycle, non-empty endpoint
// references, a reliability in [0,1], a non-negative latency, a valid scope, and
// a strictly-positive TTL. It is pure.
func (e *EdgeState) Validate() error {
	if e.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported edge state version %d (want %d)", e.Version, NetworkStateVersion)
	}
	if !e.Lifecycle.IsValid() {
		return fmt.Errorf("%w: edge lifecycle %q", ErrUnknownEnum, e.Lifecycle)
	}
	if e.FromRef == "" {
		return fmt.Errorf("%w: from_ref", ErrEmptyField)
	}
	if e.ToRef == "" {
		return fmt.Errorf("%w: to_ref", ErrEmptyField)
	}
	if e.Reliability < 0 || e.Reliability > 1 {
		return fmt.Errorf("%w: reliability %v not in [0,1]", ErrOutOfRange, e.Reliability)
	}
	if e.LatencyMS < 0 {
		return fmt.Errorf("edge %s->%s: latency_ms must be >= 0", e.FromRef, e.ToRef)
	}
	if err := e.Scope.Validate(); err != nil {
		return fmt.Errorf("edge scope: %w", err)
	}
	if !e.ExpiresAt.After(e.UpdatedAt) {
		return fmt.Errorf("%w (edge %s->%s)", ErrBadTTL, e.FromRef, e.ToRef)
	}
	return nil
}

// TopologyFragment is a TTL-bounded, scoped, partial view of local topology — a
// set of EdgeStates within one TrustScope. It is NEVER a full map and never a
// complete peer list (VIS-0002 §4, VIS-0003 §2: no node holds global topology).
// It exists as a shape for later scoped reconciliation; nothing assembles or
// exchanges fragments in Phase 0-2.
type TopologyFragment struct {
	Version   int         `json:"version"`    // schema version (NetworkStateVersion)
	Scope     TrustScope  `json:"scope"`      // the single scope this fragment covers
	Edges     []EdgeState `json:"edges"`      // partial edge set — never the whole graph
	IssuedAt  time.Time   `json:"issued_at"`  // RFC 3339, UTC
	ExpiresAt time.Time   `json:"expires_at"` // RFC 3339, UTC — fragment is stale after this
}

// NewTopologyFragment returns an empty fragment at the current schema version
// for the given scope, with an initialised (non-nil) edge slice.
func NewTopologyFragment(scope TrustScope) *TopologyFragment {
	return &TopologyFragment{Version: NetworkStateVersion, Scope: scope, Edges: []EdgeState{}}
}

// Validate checks the schema version, a valid scope, a strictly-positive TTL, and
// that every contained edge validates and belongs to this fragment's scope (a
// fragment never mixes scopes). It is pure.
func (f *TopologyFragment) Validate() error {
	if f.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported topology fragment version %d (want %d)", f.Version, NetworkStateVersion)
	}
	if err := f.Scope.Validate(); err != nil {
		return fmt.Errorf("fragment scope: %w", err)
	}
	if !f.ExpiresAt.After(f.IssuedAt) {
		return fmt.Errorf("%w (topology fragment)", ErrBadTTL)
	}
	for i := range f.Edges {
		if err := f.Edges[i].Validate(); err != nil {
			return fmt.Errorf("fragment edge at index %d: %w", i, err)
		}
		if f.Edges[i].Scope.ID != f.Scope.ID {
			return fmt.Errorf("fragment edge at index %d: scope %q does not match fragment scope %q",
				i, f.Edges[i].Scope.ID, f.Scope.ID)
		}
	}
	return nil
}

// SporeType names the kind of payload a SporeEnvelope carries — the enumerated
// spore types from doctrine (VIS-0002 §3). A spore NEVER carries raw traffic,
// full topology maps, complete peer lists, user identities, or private content.
// Wire values are the lowercase strings below; never hardcode them
// (development.md §1.1).
type SporeType string

const (
	// SporeTypeUnknown is the zero value and is never valid on the wire.
	SporeTypeUnknown SporeType = ""
	// SporeTypeBootstrap carries bootstrap hints for joining.
	SporeTypeBootstrap SporeType = "bootstrap"
	// SporeTypeRouteCapsule carries a compact route hint.
	SporeTypeRouteCapsule SporeType = "route-capsule"
	// SporeTypeTrustInvitation carries an inviter-bound join capability.
	SporeTypeTrustInvitation SporeType = "trust-invitation"
	// SporeTypeRevocation carries a scoped, threshold-signed, TTL-bounded
	// revocation notice.
	SporeTypeRevocation SporeType = "revocation"
	// SporeTypeManifest carries a signed update or cache manifest.
	SporeTypeManifest SporeType = "manifest"
	// SporeTypeStressDigest carries a redacted, aggregated stress summary.
	SporeTypeStressDigest SporeType = "stress-digest"
	// SporeTypeNodeStatus carries a CLASS-AGGREGATE advisory fleet-awareness digest (a NodeStatusDigest):
	// per-class transport health within a coarse scope, k-floored and TTL-bounded — NEVER a per-node row
	// or a stable node identifier (ADR-0030). Inert in Phase 0-2.
	SporeTypeNodeStatus SporeType = "node-status"
)

// IsValid reports whether the spore type is one of the canonical members.
func (t SporeType) IsValid() bool {
	switch t {
	case SporeTypeBootstrap, SporeTypeRouteCapsule, SporeTypeTrustInvitation,
		SporeTypeRevocation, SporeTypeManifest, SporeTypeStressDigest, SporeTypeNodeStatus:
		return true
	default:
		return false
	}
}

// SporeEnvelope is the inert, typed shape of a signed, TTL-bounded, portable
// artifact carried over any bridge (the spore doctrine, VIS-0002 §3). The
// signature is referenced by a standard primitive only: an opaque signer key id
// plus raw signature bytes (ADR-0002). This schema deliberately does NOT name or
// define a cipher, KDF, or signature scheme — the algorithm lives in the verifier
// against a named standard primitive, never here. Inert in Phase 0-2: nothing
// issues, verifies, or germinates spores yet.
type SporeEnvelope struct {
	Version     int        `json:"version"`       // schema version (NetworkStateVersion)
	Type        SporeType  `json:"type"`          // which enumerated spore type this is
	Scope       TrustScope `json:"scope"`         // the trust scope this spore is valid within
	Payload     []byte     `json:"payload"`       // opaque, type-specific bytes (never raw traffic/identities)
	IssuedAt    time.Time  `json:"issued_at"`     // RFC 3339, UTC
	ExpiresAt   time.Time  `json:"expires_at"`    // RFC 3339, UTC — replay-bounded TTL
	SignerKeyID string     `json:"signer_key_id"` // opaque key id of the signer (standard primitive, ADR-0002)
	Signature   []byte     `json:"signature"`     // raw signature bytes over the envelope (ADR-0002)
}

// Validate checks the schema version, a known spore type, a valid scope, a
// non-empty payload, a strictly-positive TTL, and the presence of a signer key
// id and signature bytes. It does NOT verify the signature (that is a Phase 3-4
// verifier's job against a named standard primitive); it only checks structural
// presence. It is pure.
func (s *SporeEnvelope) Validate() error {
	if s.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported spore version %d (want %d)", s.Version, NetworkStateVersion)
	}
	if !s.Type.IsValid() {
		return fmt.Errorf("%w: spore type %q", ErrUnknownEnum, s.Type)
	}
	if err := s.Scope.Validate(); err != nil {
		return fmt.Errorf("spore scope: %w", err)
	}
	if len(s.Payload) == 0 {
		return fmt.Errorf("%w: spore payload", ErrEmptyField)
	}
	if !s.ExpiresAt.After(s.IssuedAt) {
		return fmt.Errorf("%w (spore)", ErrBadTTL)
	}
	if s.SignerKeyID == "" {
		return fmt.Errorf("%w: signer_key_id", ErrEmptyField)
	}
	if len(s.Signature) == 0 {
		return fmt.Errorf("%w: signature", ErrEmptyField)
	}
	return nil
}

// CordPromotion is the inert, typed record of a promoted path-set (a cord) with
// its measured usefulness and a reversible demotion bound. A cord is the
// reinforced backbone in the edge lifecycle; promotion records the measurement
// that justified it and the threshold below which it must be demoted (concept 6,
// reversible). Promotion is NEVER autonomous in Phase 0-2: this struct only
// records an operator-driven decision. Autonomous, measurement-driven promotion
// is Phase 7 (VIS-0003 §4).
type CordPromotion struct {
	Version     int        `json:"version"`      // schema version (NetworkStateVersion)
	CordID      string     `json:"cord_id"`      // opaque identifier for the promoted cord
	PathRefs    []string   `json:"path_refs"`    // opaque references to the edges in the promoted path-set
	Scope       TrustScope `json:"scope"`        // the trust scope the cord serves
	Usefulness  float64    `json:"usefulness"`   // measured usefulness in [0,1] that justified promotion
	DemoteBelow float64    `json:"demote_below"` // usefulness threshold at/under which demotion is required
	Reversible  bool       `json:"reversible"`   // must be true in Phase 0-2 (no irreversible promotion)
	Autonomous  bool       `json:"autonomous"`   // must be false in Phase 0-2 (operator-driven only)
	PromotedAt  time.Time  `json:"promoted_at"`  // RFC 3339, UTC
}

// Validate checks the schema version, a non-empty cord id, a non-empty path-set,
// a valid scope, usefulness and demote-below both in [0,1], and the Phase-0-2
// invariants that a cord is reversible and not autonomously promoted. It is pure.
func (c *CordPromotion) Validate() error {
	if c.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported cord promotion version %d (want %d)", c.Version, NetworkStateVersion)
	}
	if c.CordID == "" {
		return fmt.Errorf("%w: cord_id", ErrEmptyField)
	}
	if len(c.PathRefs) == 0 {
		return fmt.Errorf("%w: path_refs", ErrEmptyField)
	}
	if err := c.Scope.Validate(); err != nil {
		return fmt.Errorf("cord scope: %w", err)
	}
	if c.Usefulness < 0 || c.Usefulness > 1 {
		return fmt.Errorf("%w: usefulness %v not in [0,1]", ErrOutOfRange, c.Usefulness)
	}
	if c.DemoteBelow < 0 || c.DemoteBelow > 1 {
		return fmt.Errorf("%w: demote_below %v not in [0,1]", ErrOutOfRange, c.DemoteBelow)
	}
	if !c.Reversible {
		return fmt.Errorf("cord %q: promotion must be reversible in Phase 0-2", c.CordID)
	}
	if c.Autonomous {
		return fmt.Errorf("cord %q: autonomous promotion is forbidden in Phase 0-2 (Phase 7)", c.CordID)
	}
	return nil
}

// DecayPolicy parameterises how an artifact or signal fades and when it is
// dropped — the decay/pruning doctrine ("dead paths decay"), shaped like
// route-flap damping: exponential decay with hysteresis. It is pure data; no
// timer or sweeper acts on it in Phase 0-2. RetentionFloor is the minimum value
// kept regardless of decay (so scarred/stress history is not silently forgotten,
// concept 6).
type DecayPolicy struct {
	TTL            time.Duration `json:"ttl_ns"`          // hard lifetime; the artifact is dropped after this
	HalfLife       time.Duration `json:"half_life_ns"`    // exponential-decay half-life of the weight
	Hysteresis     float64       `json:"hysteresis"`      // [0,1] band that damps flapping between states
	RetentionFloor float64       `json:"retention_floor"` // [0,1] minimum retained weight (e.g. scar memory)
}

// Validate checks that TTL and HalfLife are strictly positive, and that
// Hysteresis and RetentionFloor lie in [0,1]. It is pure.
func (d *DecayPolicy) Validate() error {
	if d.TTL <= 0 {
		return fmt.Errorf("decay policy: ttl must be > 0, got %s", d.TTL)
	}
	if d.HalfLife <= 0 {
		return fmt.Errorf("decay policy: half_life must be > 0, got %s", d.HalfLife)
	}
	if d.Hysteresis < 0 || d.Hysteresis > 1 {
		return fmt.Errorf("%w: hysteresis %v not in [0,1]", ErrOutOfRange, d.Hysteresis)
	}
	if d.RetentionFloor < 0 || d.RetentionFloor > 1 {
		return fmt.Errorf("%w: retention_floor %v not in [0,1]", ErrOutOfRange, d.RetentionFloor)
	}
	return nil
}

// NodeRole names a temporary niche a node may occupy in the growth front
// (concept 5). Roles are NICHES, not permanent classes: a node may hold several
// at once and may shed them. Wire values are the lowercase strings below; never
// hardcode them (development.md §1.1).
type NodeRole string

const (
	// NodeRoleUnknown is the zero value and is never valid on the wire.
	NodeRoleUnknown NodeRole = ""
	// NodeRoleFrontierProbe temporarily explores the growth front (concept 5).
	NodeRoleFrontierProbe NodeRole = "frontier-probe"
	// NodeRoleAnchor temporarily acts as a stable anchor (concept 5).
	NodeRoleAnchor NodeRole = "anchor"
	// NodeRoleCacheCustodian temporarily holds scoped cached artifacts
	// (concept 5, concept 8: storage organs).
	NodeRoleCacheCustodian NodeRole = "cache-custodian"
	// NodeRoleBridgeCarrier temporarily carries bytes across a bridge (concept 5).
	NodeRoleBridgeCarrier NodeRole = "bridge-carrier"
	// NodeRoleRelayCandidate is a candidate relay not yet promoted (concept 5).
	NodeRoleRelayCandidate NodeRole = "relay-candidate"
	// NodeRoleCordEndpoint temporarily terminates a promoted cord (concept 5).
	NodeRoleCordEndpoint NodeRole = "cord-endpoint"
)

// IsValid reports whether the role is one of the canonical members.
func (r NodeRole) IsValid() bool {
	switch r {
	case NodeRoleFrontierProbe, NodeRoleAnchor, NodeRoleCacheCustodian,
		NodeRoleBridgeCarrier, NodeRoleRelayCandidate, NodeRoleCordEndpoint:
		return true
	default:
		return false
	}
}

// DiscoveryBackend is the inert interface shape for the Phase 3-4 distributed
// awareness layer. It is DECLARED ONLY: there is no implementation in Phase 0-2,
// and binding it to a DHT, gossip transport, or distributed registry is
// explicitly deferred (VIS-0003 §4: no DHT runs, no gossip propagates, no
// announce-into-mesh). It exists so that callers and tests can be written against
// a stable signature now; any Phase 0-2 implementation must be a no-op stub.
type DiscoveryBackend interface {
	// Announce would publish a TTL-bounded spore into the awareness layer within
	// its trust scope. Not implemented in Phase 0-2 (no announce-into-mesh).
	Announce(spore SporeEnvelope) error
	// Find would resolve hint spores matching a query within a trust scope. Not
	// implemented in Phase 0-2 (no DHT/gossip running).
	Find(scope TrustScope, query string) ([]SporeEnvelope, error)
	// ReportStress would contribute a redacted, aggregation-floored stress summary
	// to the awareness layer. Not implemented in Phase 0-2.
	ReportStress(signal StressSignal) error
}

// ClassHealth is one per-CLASS advisory health cell in a NodeStatusDigest: a coarse transport class and
// its advisory health. It is deliberately per-CLASS — there is NO node identifier here, by construction.
type ClassHealth struct {
	Class  TransportClass `json:"class"`  // coarse transport family (closed vocab)
	Health HealthValue    `json:"health"` // advisory health for this class (alive/degraded/unknown)
}

// NodeStatusDigest is the INERT, typed shape of the advisory fleet-awareness digest (ADR-0030) — the
// CLASS-AGGREGATE projection a self-healing node may emit so an operator's other nodes can sense coarse
// fleet weather. By CONSTRUCTION it carries NO node identifier, NO per-node row, NO stable cross-digest
// correlator, and NO precise region: those are forbidden because the rejected per-node design (a stable
// node_ref + a per-node health vector) lets an observer reconstruct the fleet map (ADR-0030,
// THREAT-MODEL asset #5). The stable own-node handle lives ONLY in the operator-local, never-transmitted
// fleet cache. Health is ADVISORY and never actuates trust (ADR-0025). The digest is the class-aggregate
// payload; a SporeEnvelope of type SporeTypeNodeStatus carries the signature (ADR-0002/0014) when wrapped.
//
// PHASE DISCIPLINE: inert in Phase 0-2. Nothing emits, signs, merges, coarsens, or consumes it yet; the
// shape exists now so the future Advisory-Fleet-Awareness build (a cross-cutting Measurement & Immunity
// increment) cannot drift back to the unsafe per-node form — the type itself makes a per-node row
// unrepresentable.
type NodeStatusDigest struct {
	Version      int           `json:"version"`       // schema version (NetworkStateVersion)
	Scope        TrustScope    `json:"scope"`         // coarse trust scope (opaque, never per-node, never geo)
	Classes      []ClassHealth `json:"classes"`       // per-CLASS advisory health; never a per-node row
	Region       RegionBucket  `json:"region"`        // coarse bucket; Phase invariant: RegionUnspecified only
	SampleCount  int           `json:"sample_count"`  // observations aggregated into this digest
	MinAggregate int           `json:"min_aggregate"` // minimum-aggregation floor (k) this digest must meet
	IssuedAt     time.Time     `json:"issued_at"`     // RFC 3339, UTC
	ExpiresAt    time.Time     `json:"expires_at"`    // RFC 3339, UTC — replay-bounded TTL
}

// Validate checks the advisory-fleet digest's safety invariants (ADR-0030), pure (no I/O): a supported
// schema version; a valid coarse scope; at least one per-class cell, each with a known transport class
// and a known advisory health; a region that — until the closed-vocabulary hardening ADR lands — must be
// RegionUnspecified (REGION_COARSENESS); a non-negative aggregation floor the sample count MEETS
// (AGGREGATION_FLOOR, the k-anonymity-style floor); and a strictly-positive TTL. It cannot by itself
// prove the upstream coarsening; it proves the structure forbids a per-node map.
func (d *NodeStatusDigest) Validate() error {
	if d.Version != NetworkStateVersion {
		return fmt.Errorf("unsupported node status digest version %d (want %d)", d.Version, NetworkStateVersion)
	}
	if err := d.Scope.Validate(); err != nil {
		return fmt.Errorf("node status digest scope: %w", err)
	}
	if len(d.Classes) == 0 {
		return fmt.Errorf("%w: classes", ErrEmptyField)
	}
	for i := range d.Classes {
		if !d.Classes[i].Class.IsValid() {
			return fmt.Errorf("%w: class %q at index %d", ErrUnknownEnum, d.Classes[i].Class, i)
		}
		if !d.Classes[i].Health.IsValid() {
			return fmt.Errorf("%w: health %q at index %d", ErrUnknownEnum, d.Classes[i].Health, i)
		}
	}
	if d.Region != RegionUnspecified {
		// REGION_COARSENESS (ADR-0030): a populated region re-opens the enumeration surface until the
		// closed-vocab + NoisePolicy hardening ADR lands; region is unspecified-only until then.
		return fmt.Errorf("%w: region %q (the advisory digest carries only %q until the region-vocab hardening lands)",
			ErrUnknownEnum, d.Region, RegionUnspecified)
	}
	if d.MinAggregate < 0 {
		return fmt.Errorf("node status digest: min_aggregate must be >= 0, got %d", d.MinAggregate)
	}
	if d.SampleCount < d.MinAggregate {
		// AGGREGATION_FLOOR (ADR-0030): a sub-floor digest must be omitted, never emitted.
		return fmt.Errorf("%w: have %d, need %d", ErrAggregationFloor, d.SampleCount, d.MinAggregate)
	}
	if !d.ExpiresAt.After(d.IssuedAt) {
		return fmt.Errorf("%w (node status digest)", ErrBadTTL)
	}
	return nil
}
