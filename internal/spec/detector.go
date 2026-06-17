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
// Connectivity-state detector — the inert schema for RP-0010 Plane 2 (DETECT).
//
// This file is the typed VOCABULARY and DATA SHAPES of the connectivity-state
// detector (ADR-0031 "BUILD" verdict; RP-0010). It is pure: typed enums, data
// records, and pure Validate/projection logic only — no goroutines, no I/O, no
// network, no classifier. The classifier that maps a DetectorSignal window to a
// Verdict (the DETECT-plane logic) lives in its own package and is wired in a
// later RP-0010 chunk; the self-tuner that reinforces/decays a (class,path)
// weight rides spec.DecayPolicy in another. The shapes exist now so behaviour
// can be added without breaking them — the codebase's schema-before-behaviour
// discipline (cf. network.go, bundle.go).
//
// OPSEC BOUNDARY (load-bearing). ConnState and DetectReason are the
// FINE-GRAINED, node-local diagnosis that drives local rotation. They are NEVER
// transmitted. Only ConnState's LOSSY projection to the coarse advisory
// HealthValue (AdvisoryHealth, below) may ever leave the node, and then only
// inside a k-floored, TTL-bounded, class-aggregate NodeStatusDigest (ADR-0030) —
// never per node, never with the specific state or reason. The collapse is
// deliberate: an observer of the advisory must not be able to tell WHICH
// interference (throttle vs block vs shutdown) actually succeeded. Health is
// advisory and NEVER actuates trust (ADR-0025). The detector_state_closed_vocab
// conformance gate enforces, by construction, that no transmitted artifact type
// embeds ConnState or DetectReason.
// -----------------------------------------------------------------------------

// ConnState classifies the connectivity of a single transport channel into a
// small CLOSED set, from signals that are by-products of work the node already
// does (so detection adds no new probing fingerprint, RP-0010 AC-6). It is the
// node-local DETECT-plane output and is NEVER put on the wire (see the OPSEC
// boundary above). Wire/string values are the lowercase strings below; never
// hardcode them at call sites (development.md §1.1).
type ConnState string

const (
	// ConnStateUnknown is the zero value: no verdict has been reached (e.g. the
	// detector has not yet observed a full window). It is never a valid verdict
	// state and never a wire value.
	ConnStateUnknown ConnState = ""
	// ConnStateClean is an unimpaired channel: connect and handshake complete,
	// throughput holds after connect, the cover/own-cert probe answers correctly.
	ConnStateClean ConnState = "clean"
	// ConnStateThrottled is reachable but impaired: the channel connects and
	// handshakes, but throughput collapses after a successful connect — the
	// destination-AS "data dies after a small initial transfer" signature
	// (ADR-0027).
	ConnStateThrottled ConnState = "throttled"
	// ConnStateBlocked is handshake-layer interference: a transport connection is
	// established but the channel's handshake is reset, times out, or the active
	// probe fails — the shape no longer establishes on this path even though the
	// socket opens.
	ConnStateBlocked ConnState = "blocked"
	// ConnStateShutdown is total loss of the channel on this path: not even a
	// transport-layer connection can be opened (e.g. the address/AS is
	// black-holed).
	ConnStateShutdown ConnState = "shutdown"
)

// IsValid reports whether the state is one of the canonical impaired/clean
// members. The zero value (ConnStateUnknown) is NOT valid — a verdict must
// classify (see Verdict.Validate).
func (s ConnState) IsValid() bool {
	switch s {
	case ConnStateClean, ConnStateThrottled, ConnStateBlocked, ConnStateShutdown:
		return true
	default:
		return false
	}
}

// AdvisoryHealth projects the fine-grained, node-local ConnState DOWN to the
// coarse advisory HealthValue (ADR-0030) — the ONLY externalisable view of a
// channel's state. The projection is intentionally LOSSY: clean -> alive, and
// every impaired state (throttled / blocked / shutdown) collapses to the single
// value degraded, so the advisory can never reveal which interference class
// succeeded; an unset/unknown state maps to unknown ("no measurement"). This is
// the privacy contract, not an accident — keep throttled, blocked, and shutdown
// indistinguishable in the projection. It is pure.
func (s ConnState) AdvisoryHealth() HealthValue {
	switch s {
	case ConnStateClean:
		return HealthAlive
	case ConnStateThrottled, ConnStateBlocked, ConnStateShutdown:
		return HealthDegraded
	default:
		return HealthUnknown
	}
}

// DetectReason is the CLOSED, enumerable cause class a Verdict attributes its
// state to — never free text (so it carries no PII and stays a small,
// fingerprint-free vocabulary). Like ConnState it is node-local and NEVER
// transmitted. Each non-clean state names the dominant signal that produced it;
// a clean channel carries ReasonNone. Wire values are the lowercase strings
// below; never hardcode them (development.md §1.1).
type DetectReason string

const (
	// ReasonUnknown is the zero value and is never a valid wire value.
	ReasonUnknown DetectReason = ""
	// ReasonNone is the explicit "no degrading signal" cause — the only reason
	// permitted with ConnStateClean.
	ReasonNone DetectReason = "none"
	// ReasonHandshakeTimeout — a transport connection opened but the channel's
	// handshake did not complete within the window.
	ReasonHandshakeTimeout DetectReason = "handshake-timeout"
	// ReasonConnectionReset — the connection was reset (RST) at or near handshake.
	ReasonConnectionReset DetectReason = "connection-reset"
	// ReasonThroughputCollapse — throughput collapsed AFTER a successful connect
	// (the destination-AS signature; ADR-0027 / THREAT-MODEL).
	ReasonThroughputCollapse DetectReason = "throughput-collapse"
	// ReasonActiveProbeFailure — the cover-site / own-cert active probe did not
	// return the expected donor/certificate response.
	ReasonActiveProbeFailure DetectReason = "active-probe-failure"
	// ReasonSingleStreamDegradation — a single-stream shape degraded while a
	// multiplexed shape on the same node did not (the Phase-1 on-device finding).
	ReasonSingleStreamDegradation DetectReason = "single-stream-degradation"
	// ReasonUnreachable — not even a transport-layer connection could be opened
	// (the shutdown / black-hole cause).
	ReasonUnreachable DetectReason = "unreachable"
	// ReasonDegradedWindow — the fast-class success-ratio window is sustainedly
	// poor without a single fresh signature being dominant (aggregate degradation
	// rather than one attributable event).
	ReasonDegradedWindow DetectReason = "degraded-window"
)

// IsValid reports whether the reason is one of the canonical members. ReasonNone
// is valid (it is the explicit clean-channel cause); only the zero value
// (ReasonUnknown) is invalid.
func (r DetectReason) IsValid() bool {
	switch r {
	case ReasonNone, ReasonHandshakeTimeout, ReasonConnectionReset,
		ReasonThroughputCollapse, ReasonActiveProbeFailure,
		ReasonSingleStreamDegradation, ReasonUnreachable, ReasonDegradedWindow:
		return true
	default:
		return false
	}
}

// DetectorSignal is the node-local INPUT bundle a classifier consumes to reach a
// Verdict for one transport class on one path. It is assembled strictly from
// by-products of work the node already does (RP-0010 Plane 1 / WRAP of
// internal/reach) — it adds no new probing surface (AC-6). By construction it
// carries NO endpoint, SNI, peer identity, user traffic, or location: only a
// coarse transport class, the fast-class TransportHealth window (opaque
// transport ref + counters), and boolean by-product observations. Inert in
// Phase 0-2: no classifier runs over it here (that is a later RP-0010 chunk).
//
// ConnectOK and HandshakeOK are deliberately distinct so a later classifier can
// separate shutdown from blocked: shutdown is "!ConnectOK" (no transport-layer
// connection at all), whereas blocked is "ConnectOK && !HandshakeOK" (the socket
// opens but the channel's handshake does not establish). HandshakeOK implies
// ConnectOK.
type DetectorSignal struct {
	Class                TransportClass  `json:"class"`                  // coarse transport family (closed vocab)
	Health               TransportHealth `json:"health"`                 // fast-class success/failure window (no identity)
	ConnectOK            bool            `json:"connect_ok"`             // a transport-layer connection (socket) was established
	HandshakeOK          bool            `json:"handshake_ok"`           // the channel's handshake completed (implies ConnectOK)
	ConnectReset         bool            `json:"connect_reset"`          // a connect/handshake met a RST
	PostConnectCollapse  bool            `json:"post_connect_collapse"`  // throughput collapsed after a successful connect
	ActiveProbeOK        bool            `json:"active_probe_ok"`        // cover/own-cert probe returned the expected response
	SingleStreamDegraded bool            `json:"single_stream_degraded"` // single-stream shape degraded while a mux shape did not
	ObservedAt           time.Time       `json:"observed_at"`            // RFC 3339, UTC
}

// Validate checks the signal's structural invariants: a known coarse transport
// class, a valid TransportHealth window, and the ConnectOK/HandshakeOK
// implication (a completed handshake requires an established connection). The
// remaining boolean by-products are self-validating. It is pure (no I/O): same
// input, same verdict.
func (s *DetectorSignal) Validate() error {
	if !s.Class.IsValid() {
		return fmt.Errorf("%w: detector signal class %q", ErrUnknownEnum, s.Class)
	}
	if err := s.Health.Validate(); err != nil {
		return fmt.Errorf("detector signal health: %w", err)
	}
	if s.HandshakeOK && !s.ConnectOK {
		return fmt.Errorf("detector signal: handshake_ok cannot be true while connect_ok is false")
	}
	return nil
}

// Verdict is the node-local DETECT-plane output: the classified ConnState, the
// dominant DetectReason that produced it, the transport class and opaque path
// reference it concerns, and when it was decided. State and Reason are NEVER
// transmitted; only Verdict.State's AdvisoryHealth() projection may ever leave
// the node, k-floored, inside a class-aggregate NodeStatusDigest (ADR-0030).
// TransportRef is the opaque (class,path) key the RP-0010 self-tuner reinforces
// and decays on spec.DecayPolicy — it is node-local and, like TransportHealth's
// ref, carries no SNI/endpoint/identity. Pure data; nothing acts on it here.
type Verdict struct {
	State        ConnState      `json:"state"`         // node-local diagnosis (never transmitted)
	Reason       DetectReason   `json:"reason"`        // closed, enumerable dominant cause (never transmitted)
	Class        TransportClass `json:"class"`         // the transport class this verdict concerns
	TransportRef string         `json:"transport_ref"` // opaque node-local path key (no SNI/endpoint); the self-tuner's (class,path) key
	DecidedAt    time.Time      `json:"decided_at"`    // RFC 3339, UTC
}

// Validate checks: a known coarse transport class; a non-empty opaque transport
// reference; a classified (non-unknown) state; a valid reason; and the
// cross-field contract that a clean channel carries exactly ReasonNone while any
// impaired state carries a concrete (non-none, non-unknown) cause. It is pure.
func (v *Verdict) Validate() error {
	if !v.Class.IsValid() {
		return fmt.Errorf("%w: verdict class %q", ErrUnknownEnum, v.Class)
	}
	if v.TransportRef == "" {
		return fmt.Errorf("%w: verdict transport_ref", ErrEmptyField)
	}
	if !v.State.IsValid() {
		return fmt.Errorf("%w: verdict state %q", ErrUnknownEnum, v.State)
	}
	if !v.Reason.IsValid() {
		return fmt.Errorf("%w: verdict reason %q", ErrUnknownEnum, v.Reason)
	}
	if v.State == ConnStateClean && v.Reason != ReasonNone {
		return fmt.Errorf("verdict: a clean channel must carry %q, got %q", ReasonNone, v.Reason)
	}
	if v.State != ConnStateClean && v.Reason == ReasonNone {
		return fmt.Errorf("verdict: an impaired state %q must carry a concrete cause, not %q", v.State, ReasonNone)
	}
	return nil
}
