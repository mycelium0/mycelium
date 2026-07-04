// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "fmt"

// Federation contract — the INERT, substrate-agnostic Phase-3 hypha seam (ADR-0037, ADR-0026 Decision 5).
//
// A hypha is a same-operator, same-CA F2F bond between two of ONE Commune's nodes (edge-fusion, ADR-0026) —
// the intra-Commune counterpart to the cross-Commune AnastomosisBridge (declared in anastomosis_bridge.go).
// It is a CONTRACT over a proven transport, NOT a wire protocol: when federation goes live (Phase 4+), a
// hypha rides Nebula (operator CA/PKI + Noise; ADR-0037), and a bridge rides libp2p — the CA boundary IS the
// Commune boundary. This file authors NO transport and NO cryptography (ADR-0002/0031): signatures are
// SignerKeyID references and the link is carried by the chosen substrate.
//
// INERTNESS (ADR-0013 / ADR-0026 Decision 5): these are typed data + pure Validate() only. Nothing
// establishes, dials, negotiates, or propagates a hypha before its phase; the types have ZERO production
// callers (federation_inert gate). A descriptor you can construct and validate is not a bond anything acts
// on before Phase 4.

// IdentityKind selects which substrate handle an IdentityHandle carries (ADR-0037 field 1).
type IdentityKind string

const (
	// IdentityKindUnknown is the zero value (invalid).
	IdentityKindUnknown IdentityKind = ""
	// IdentityKindNebulaCert is a role-A hypha endpoint: an operator-CA-signed Nebula cert. Same CA = same
	// Commune, so both ends of a hypha share a ca_fingerprint.
	IdentityKindNebulaCert IdentityKind = "nebula-cert"
	// IdentityKindLibp2pPeer is a role-B bridge endpoint: a libp2p peer-id (cross-CA, NAT-traversed).
	IdentityKindLibp2pPeer IdentityKind = "libp2p-peer"
)

// IsValid reports whether k is a known, non-zero identity kind.
func (k IdentityKind) IsValid() bool {
	switch k {
	case IdentityKindNebulaCert, IdentityKindLibp2pPeer:
		return true
	default:
		return false
	}
}

// IdentityHandle names a federation peer WITHOUT reinventing a transport identity: it holds the substrate's
// own handle so the inert contract composes with either substrate at Phase 4 (ADR-0037). Opaque — never an
// IP, hostname, or geographic location (ADR-0021 telemetry boundary).
type IdentityHandle struct {
	Kind          IdentityKind `json:"kind"`
	CAFingerprint string       `json:"ca_fingerprint,omitempty"` // the Commune CA fingerprint (Nebula); the CA boundary IS the Commune boundary
	NodeIdentity  string       `json:"node_identity"`            // cert name (Nebula) or peer-id (libp2p); opaque
}

// Validate checks the handle is a known kind with a non-empty opaque identity, and that a Nebula-cert handle
// carries the Commune CA fingerprint it is rooted in. Pure.
func (h IdentityHandle) Validate() error {
	if !h.Kind.IsValid() {
		return fmt.Errorf("%w: identity handle kind %q", ErrUnknownEnum, h.Kind)
	}
	if h.NodeIdentity == "" {
		return fmt.Errorf("%w: identity handle node_identity", ErrEmptyField)
	}
	if h.Kind == IdentityKindNebulaCert && h.CAFingerprint == "" {
		return fmt.Errorf("%w: a nebula-cert identity requires a ca_fingerprint (the Commune CA it is rooted in)", ErrEmptyField)
	}
	return nil
}

// TrafficCapabilityClass is the risk-graded, consent-gated capability taxonomy (ADR-0026 Decision 3;
// ADR-0037 field 2). A carrier offers a flow class; genetics decide which capability classes may ride it.
type TrafficCapabilityClass string

const (
	CapUnknown                  TrafficCapabilityClass = ""
	CapLocalControl             TrafficCapabilityClass = "local-control"
	CapEmergencyCoordination    TrafficCapabilityClass = "emergency-coordination"
	CapMessaging                TrafficCapabilityClass = "messaging"
	CapSignedContentReplication TrafficCapabilityClass = "signed-content-replication"
	CapSoftwareUpdates          TrafficCapabilityClass = "software-updates"
	CapRealTimeMedia            TrafficCapabilityClass = "real-time-media"
	CapRelayTraffic             TrafficCapabilityClass = "relay-traffic"
	CapEgressTraffic            TrafficCapabilityClass = "egress-traffic"
	CapUnknownBulkTraffic       TrafficCapabilityClass = "unknown-bulk-traffic"
)

// IsValid reports whether c is one of the nine known capability classes.
func (c TrafficCapabilityClass) IsValid() bool {
	switch c {
	case CapLocalControl, CapEmergencyCoordination, CapMessaging, CapSignedContentReplication,
		CapSoftwareUpdates, CapRealTimeMedia, CapRelayTraffic, CapEgressTraffic, CapUnknownBulkTraffic:
		return true
	default:
		return false
	}
}

// IsHighRisk reports the high-risk classes (relay / egress / unknown-bulk) that require the strongest trust
// and immunity policy and may be refused outright (ADR-0026 Decision 3). Anonymous egress is NOT a default
// primitive.
func (c TrafficCapabilityClass) IsHighRisk() bool {
	switch c {
	case CapRelayTraffic, CapEgressTraffic, CapUnknownBulkTraffic:
		return true
	default:
		return false
	}
}

// CapabilityPolicy grades what a bond consents to carry. Forbidden is stated EXPLICITLY (ADR-0026 Decision 2)
// so a widening is always an explicit change, never "everything not allowed". Pure data + Validate().
type CapabilityPolicy struct {
	Allowed   []TrafficCapabilityClass `json:"allowed"`
	Forbidden []TrafficCapabilityClass `json:"forbidden"`
}

// Validate checks every class is known and that no class is both allowed and forbidden. Pure.
func (p CapabilityPolicy) Validate() error {
	allowed := make(map[TrafficCapabilityClass]bool, len(p.Allowed))
	for _, c := range p.Allowed {
		if !c.IsValid() {
			return fmt.Errorf("%w: allowed capability %q", ErrUnknownEnum, c)
		}
		allowed[c] = true
	}
	for _, c := range p.Forbidden {
		if !c.IsValid() {
			return fmt.Errorf("%w: forbidden capability %q", ErrUnknownEnum, c)
		}
		if allowed[c] {
			return fmt.Errorf("capability %q is both allowed and forbidden", c)
		}
	}
	return nil
}

// ConsentState records the double-opt-in both ends of a hypha must express (ADR-0029 Decision 5;
// ADR-0037 field 4).
type ConsentState struct {
	LocalOptIn   bool `json:"local_opt_in"`
	SiblingOptIn bool `json:"sibling_opt_in"`
}

// BothOptedIn reports whether both sides consented.
func (c ConsentState) BothOptedIn() bool { return c.LocalOptIn && c.SiblingOptIn }

// Introduction depth bounds (ADR-0029 Decision 5; ADR-0037 field 5): a fungi may introduce at depth 1–2.
const (
	MinHopDepth = 1
	MaxHopDepth = 2
)

// SiblingDescriptor is the intra-Commune hypha bond (BUILT inert, Phase 3). Both endpoints are same-CA
// Nebula-cert identities (a cross-CA bond is an AnastomosisBridge, not a hypha). It carries NO neighbour
// list / topology map — a fungi MUST NOT enumerate (ADR-0029 Decision 5).
type SiblingDescriptor struct {
	Version      int              `json:"version"`      // NetworkStateVersion
	Local        IdentityHandle   `json:"local"`        // this node
	Sibling      IdentityHandle   `json:"sibling"`      // the bonded sibling (same operator, same CA)
	Scope        TrustScope       `json:"scope"`        // the compartment this bond belongs to
	Capabilities CapabilityPolicy `json:"capabilities"` // what may / must-not ride the bond
	Consent      ConsentState     `json:"consent"`      // double-opt-in
	Lifetime     DecayPolicy      `json:"lifetime"`     // TTL-bounded, self-expiring
	HopDepth     int              `json:"hop_depth"`    // 1..2
}

// Validate checks a well-formed, same-CA, double-opt-in hypha bond within the hop-depth bound. Pure; it does
// NOT establish anything (inert — Phase 4 provides the live transport).
func (d *SiblingDescriptor) Validate() error {
	if d.Version != NetworkStateVersion {
		return fmt.Errorf("sibling descriptor: version %d != NetworkStateVersion %d", d.Version, NetworkStateVersion)
	}
	if err := d.Local.Validate(); err != nil {
		return fmt.Errorf("sibling descriptor local: %w", err)
	}
	if err := d.Sibling.Validate(); err != nil {
		return fmt.Errorf("sibling descriptor sibling: %w", err)
	}
	// A hypha is intra-Commune, same operator: both endpoints are Nebula-cert identities under one CA.
	if d.Local.Kind != IdentityKindNebulaCert || d.Sibling.Kind != IdentityKindNebulaCert {
		return fmt.Errorf("a hypha bond is intra-Commune: both endpoints must be nebula-cert identities (a cross-CA bond is an AnastomosisBridge, not a hypha)")
	}
	if d.Local.CAFingerprint != d.Sibling.CAFingerprint {
		return fmt.Errorf("a hypha bond is same-CA (one Commune): local/sibling ca_fingerprint differ — a cross-CA bond is an AnastomosisBridge")
	}
	if err := d.Scope.Validate(); err != nil {
		return fmt.Errorf("sibling descriptor scope: %w", err)
	}
	if err := d.Capabilities.Validate(); err != nil {
		return fmt.Errorf("sibling descriptor capabilities: %w", err)
	}
	if !d.Consent.BothOptedIn() {
		return fmt.Errorf("a hypha requires double-opt-in: both local_opt_in and sibling_opt_in must be true (ADR-0029)")
	}
	if err := d.Lifetime.Validate(); err != nil {
		return fmt.Errorf("sibling descriptor lifetime: %w", err)
	}
	if d.HopDepth < MinHopDepth || d.HopDepth > MaxHopDepth {
		return fmt.Errorf("%w: hypha hop_depth %d not in [%d,%d]", ErrOutOfRange, d.HopDepth, MinHopDepth, MaxHopDepth)
	}
	return nil
}

// HyphaInvitation is the constrained introduction (BUILT inert, Phase 3; ADR-0029 Decision 5): a fungi MAY
// introduce two nodes to form a DIRECT hypha (double-opt-in, scoped, TTL-bounded), then STEPS AWAY — the
// bond survives the introducer's departure (the introducer is not a relay or coordinator). A fungi MUST NOT
// enumerate: this invitation carries NO neighbour list. It is carried as the Payload of a
// SporeTypeTrustInvitation SporeEnvelope (network.go) — reusing the existing signed, TTL-bounded envelope
// rather than reinventing a carrier.
type HyphaInvitation struct {
	Version      int              `json:"version"`
	Introducer   IdentityHandle   `json:"introducer"` // the fungi that introduces, then steps away
	Invitee      IdentityHandle   `json:"invitee"`
	Scope        TrustScope       `json:"scope"`
	Capabilities CapabilityPolicy `json:"capabilities"`
	Lifetime     DecayPolicy      `json:"lifetime"`    // TTL on the invitation
	IntroDepth   int              `json:"intro_depth"` // 1..2
	MaxDegree    int              `json:"max_degree"`  // max bonds a fungi may introduce (degree bound)
}

// Validate checks a well-formed, bounded-depth, degree-capped invitation. Pure; introduces nothing (inert).
func (i *HyphaInvitation) Validate() error {
	if i.Version != NetworkStateVersion {
		return fmt.Errorf("hypha invitation: version %d != NetworkStateVersion %d", i.Version, NetworkStateVersion)
	}
	if err := i.Introducer.Validate(); err != nil {
		return fmt.Errorf("hypha invitation introducer: %w", err)
	}
	if err := i.Invitee.Validate(); err != nil {
		return fmt.Errorf("hypha invitation invitee: %w", err)
	}
	if err := i.Scope.Validate(); err != nil {
		return fmt.Errorf("hypha invitation scope: %w", err)
	}
	if err := i.Capabilities.Validate(); err != nil {
		return fmt.Errorf("hypha invitation capabilities: %w", err)
	}
	if err := i.Lifetime.Validate(); err != nil {
		return fmt.Errorf("hypha invitation lifetime: %w", err)
	}
	if i.IntroDepth < MinHopDepth || i.IntroDepth > MaxHopDepth {
		return fmt.Errorf("%w: hypha invitation intro_depth %d not in [%d,%d]", ErrOutOfRange, i.IntroDepth, MinHopDepth, MaxHopDepth)
	}
	if i.MaxDegree < 1 {
		return fmt.Errorf("%w: hypha invitation max_degree must be >= 1, got %d", ErrOutOfRange, i.MaxDegree)
	}
	return nil
}
