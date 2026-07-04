// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "fmt"

// AnastomosisBridge — the cross-Commune contract grammar (ADR-0026 Decision 2), DECLARED IN FULL but
// PHASE-4 DEFERRED.
//
// The bridge is the cross-Commune (society-fusion) counterpart to the intra-Commune hypha (edge-fusion,
// hypha.go). Two SOVEREIGN Communes — a CA boundary — so when federation goes live it rides libp2p
// (NAT-traversed, DCUtR + self-hosted Circuit Relay v2), never Nebula's same-CA relay (ADR-0037).
//
// The whole 8-term grammar is typed here so the architecture is VISIBLE and reviewable now, but per ADR-0026
// Decision 5 + ADR-0037 build order NOTHING establishes, negotiates, revokes, quarantines, or propagates a
// bridge before Phase 4-5, and cross-Commune capability grading does not run before Phase 6. Built INERT
// alongside the hypha: typed data + a pure, STRUCTURAL Validate() only (a contract you can construct and
// validate is not a bridge anything acts on). ZERO production callers (federation_inert gate). A bridge
// contract MUST NOT embed raw traffic, user identity, location, or a complete topology map — enforced by
// construction (no such field exists) and by the telemetry boundary (ADR-0021/0024).

// AbusePropagationRule (Decision 2, term 4): whether/which immune signals cross, and with what binding
// effect — the contract clause ADR-0025 requires for any cross-Commune binding to exist at all.
type AbusePropagationRule struct {
	Propagate bool     `json:"propagate"` // do immune signals cross this bridge at all
	Classes   []string `json:"classes"`   // which immune-signal classes (coarse, enumerable; never raw evidence/PII)
	Binding   bool     `json:"binding"`   // binding effect vs advisory-only
}

// QuarantineRule (Decision 2, term 5): how a quarantine on one side is reflected — always scoped,
// reversible, TTL-bounded (ADR-0024).
type QuarantineRule struct {
	Reflect  bool        `json:"reflect"`  // is a quarantine on one side reflected on the other
	Lifetime DecayPolicy `json:"lifetime"` // scoped, reversible, TTL-bounded
}

// RevocationRule (Decision 2, term 6): how either side withdraws the bridge. Revocation is unilateral —
// neither side can compel the other to stay bridged (ADR-0024).
type RevocationRule struct {
	Unilateral bool `json:"unilateral"` // either side may withdraw (true by doctrine)
}

// RecoveryRule (Decision 2, term 7): the defined path to re-establish/re-widen after a cut, so a bridge can
// heal — consistent with heal-requires-clot (ADR-0024).
type RecoveryRule struct {
	RequiresClot bool `json:"requires_clot"` // the re-widen path gates on a settled clot before healing
}

// EvidenceClass is a coarse, enumerable category — never raw evidence, never PII (ADR-0026 Decision 2).
type EvidenceClass string

// EvidenceRequirement (Decision 2, term 8): the evidence class a propagated abuse/quarantine signal must
// carry to have effect under this contract.
type EvidenceRequirement struct {
	Class EvidenceClass `json:"class"`
}

// AnastomosisBridge is the full signed contract between two sovereign Communes (ADR-0026 Decision 2).
// DECLARED-ONLY / Phase-4-deferred (see file header).
type AnastomosisBridge struct {
	Version          int                      `json:"version"` // NetworkStateVersion
	LocalCommune     IdentityHandle           `json:"local_commune"`
	PeerCommune      IdentityHandle           `json:"peer_commune"`
	TrustRelations   []TrustScope             `json:"trust_relations"`   // term 1 — bounded trust scopes, never a global grant
	AllowedClasses   []TrafficCapabilityClass `json:"allowed_classes"`   // term 2
	ForbiddenClasses []TrafficCapabilityClass `json:"forbidden_classes"` // term 3 — stated explicitly
	AbusePropagation AbusePropagationRule     `json:"abuse_propagation"` // term 4
	Quarantine       QuarantineRule           `json:"quarantine"`        // term 5
	Revocation       RevocationRule           `json:"revocation"`        // term 6
	Recovery         RecoveryRule             `json:"recovery"`          // term 7
	Evidence         EvidenceRequirement      `json:"evidence"`          // term 8
	Lifetime         DecayPolicy              `json:"lifetime"`          // TTL-bounded
	SignerKeyID      string                   `json:"signer_key_id"`     // the contract is signed (ADR-0002/0014)
}

// Validate checks the bridge contract is STRUCTURALLY well-formed — distinct Communes, valid capability
// grammar (allowed disjoint from forbidden), a signer, and a bounded lifetime. It is PURE and does NOT
// establish, negotiate, or act on a bridge (inert; the live path is Phase 4-5).
func (b *AnastomosisBridge) Validate() error {
	if b.Version != NetworkStateVersion {
		return fmt.Errorf("anastomosis bridge: version %d != NetworkStateVersion %d", b.Version, NetworkStateVersion)
	}
	if err := b.LocalCommune.Validate(); err != nil {
		return fmt.Errorf("anastomosis bridge local_commune: %w", err)
	}
	if err := b.PeerCommune.Validate(); err != nil {
		return fmt.Errorf("anastomosis bridge peer_commune: %w", err)
	}
	// A bridge is cross-Commune: the two ends must be distinct genetics (an identical handle is not a bridge).
	if b.LocalCommune == b.PeerCommune {
		return fmt.Errorf("an anastomosis bridge is cross-Commune: local_commune and peer_commune must differ")
	}
	// The capability grammar reuses the hypha CapabilityPolicy check (classes valid; allowed ∩ forbidden = ∅).
	if err := (CapabilityPolicy{Allowed: b.AllowedClasses, Forbidden: b.ForbiddenClasses}).Validate(); err != nil {
		return fmt.Errorf("anastomosis bridge capability grammar: %w", err)
	}
	for _, ts := range b.TrustRelations {
		if err := ts.Validate(); err != nil {
			return fmt.Errorf("anastomosis bridge trust_relations: %w", err)
		}
	}
	if b.SignerKeyID == "" {
		return fmt.Errorf("%w: an anastomosis bridge contract must be signed (signer_key_id)", ErrEmptyField)
	}
	if err := b.Lifetime.Validate(); err != nil {
		return fmt.Errorf("anastomosis bridge lifetime: %w", err)
	}
	return nil
}
