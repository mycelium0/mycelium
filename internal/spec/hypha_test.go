// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"testing"
	"time"
)

func hyphaHandle(id string) IdentityHandle {
	return IdentityHandle{Kind: IdentityKindNebulaCert, CAFingerprint: "ca-fp-commune-1", NodeIdentity: id}
}
func hyphaDecay() DecayPolicy {
	return DecayPolicy{TTL: time.Hour, HalfLife: time.Minute, Hysteresis: 0.1, RetentionFloor: 0}
}
func hyphaScope() TrustScope { return TrustScope{ID: "scope-1", Label: "commune-1", MaxHops: 1} }

func validSibling() SiblingDescriptor {
	return SiblingDescriptor{
		Version:      NetworkStateVersion,
		Local:        hyphaHandle("node-a"),
		Sibling:      hyphaHandle("node-b"),
		Scope:        hyphaScope(),
		Capabilities: CapabilityPolicy{Allowed: []TrafficCapabilityClass{CapLocalControl}, Forbidden: []TrafficCapabilityClass{CapEgressTraffic}},
		Consent:      ConsentState{LocalOptIn: true, SiblingOptIn: true},
		Lifetime:     hyphaDecay(),
		HopDepth:     1,
	}
}

func TestIdentityHandleValidate(t *testing.T) {
	tests := []struct {
		name    string
		h       IdentityHandle
		wantErr bool
	}{
		{"valid nebula-cert", IdentityHandle{Kind: IdentityKindNebulaCert, CAFingerprint: "ca-1", NodeIdentity: "n1"}, false},
		{"valid libp2p-peer (no CA)", IdentityHandle{Kind: IdentityKindLibp2pPeer, NodeIdentity: "peer-1"}, false},
		{"unknown kind rejected", IdentityHandle{Kind: "carrier-pigeon", NodeIdentity: "n1"}, true},
		{"empty kind rejected", IdentityHandle{NodeIdentity: "n1"}, true},
		{"empty node identity rejected", IdentityHandle{Kind: IdentityKindNebulaCert, CAFingerprint: "ca-1"}, true},
		{"nebula-cert without CA rejected", IdentityHandle{Kind: IdentityKindNebulaCert, NodeIdentity: "n1"}, true},
	}
	for _, tc := range tests {
		if err := tc.h.Validate(); (err != nil) != tc.wantErr {
			t.Errorf("%s: Validate() err=%v, wantErr=%v", tc.name, err, tc.wantErr)
		}
	}
}

func TestTrafficCapabilityClass(t *testing.T) {
	for _, c := range []TrafficCapabilityClass{CapLocalControl, CapEmergencyCoordination, CapMessaging,
		CapSignedContentReplication, CapSoftwareUpdates, CapRealTimeMedia, CapRelayTraffic, CapEgressTraffic, CapUnknownBulkTraffic} {
		if !c.IsValid() {
			t.Errorf("%q should be a valid capability class", c)
		}
	}
	if CapUnknown.IsValid() || TrafficCapabilityClass("bulk-mystery").IsValid() {
		t.Error("zero value and unknown class must be invalid")
	}
	// The three high-risk classes and only those.
	high := map[TrafficCapabilityClass]bool{CapRelayTraffic: true, CapEgressTraffic: true, CapUnknownBulkTraffic: true}
	for _, c := range []TrafficCapabilityClass{CapLocalControl, CapEmergencyCoordination, CapMessaging,
		CapSignedContentReplication, CapSoftwareUpdates, CapRealTimeMedia, CapRelayTraffic, CapEgressTraffic, CapUnknownBulkTraffic} {
		if c.IsHighRisk() != high[c] {
			t.Errorf("%q IsHighRisk()=%v, want %v", c, c.IsHighRisk(), high[c])
		}
	}
}

func TestCapabilityPolicyValidate(t *testing.T) {
	if err := (CapabilityPolicy{Allowed: []TrafficCapabilityClass{CapMessaging}, Forbidden: []TrafficCapabilityClass{CapEgressTraffic}}).Validate(); err != nil {
		t.Errorf("valid policy rejected: %v", err)
	}
	if err := (CapabilityPolicy{Allowed: []TrafficCapabilityClass{"nonsense"}}).Validate(); err == nil {
		t.Error("unknown allowed class must be rejected")
	}
	if err := (CapabilityPolicy{Allowed: []TrafficCapabilityClass{CapMessaging}, Forbidden: []TrafficCapabilityClass{CapMessaging}}).Validate(); err == nil {
		t.Error("a class both allowed and forbidden must be rejected")
	}
}

func TestSiblingDescriptorValidate(t *testing.T) {
	if err := (func() error { d := validSibling(); return d.Validate() })(); err != nil {
		t.Fatalf("valid sibling descriptor rejected: %v", err)
	}
	mutations := []struct {
		name   string
		mutate func(*SiblingDescriptor)
	}{
		{"wrong version", func(d *SiblingDescriptor) { d.Version = NetworkStateVersion + 99 }},
		{"cross-CA rejected (that is a bridge)", func(d *SiblingDescriptor) { d.Sibling.CAFingerprint = "ca-fp-commune-2" }},
		{"non-nebula endpoint rejected", func(d *SiblingDescriptor) {
			d.Sibling = IdentityHandle{Kind: IdentityKindLibp2pPeer, NodeIdentity: "peer-x"}
		}},
		{"missing double-opt-in rejected", func(d *SiblingDescriptor) { d.Consent.SiblingOptIn = false }},
		{"hop depth 0 rejected", func(d *SiblingDescriptor) { d.HopDepth = 0 }},
		{"hop depth 3 rejected", func(d *SiblingDescriptor) { d.HopDepth = 3 }},
		{"bad capability rejected", func(d *SiblingDescriptor) { d.Capabilities.Allowed = []TrafficCapabilityClass{"weird"} }},
		{"bad scope rejected", func(d *SiblingDescriptor) { d.Scope.ID = "" }},
	}
	for _, m := range mutations {
		d := validSibling()
		m.mutate(&d)
		if err := d.Validate(); err == nil {
			t.Errorf("%s: expected Validate() error, got nil", m.name)
		}
	}
}

func TestHyphaInvitationValidate(t *testing.T) {
	valid := HyphaInvitation{
		Version:      NetworkStateVersion,
		Introducer:   hyphaHandle("fungi-1"),
		Invitee:      hyphaHandle("node-c"),
		Scope:        hyphaScope(),
		Capabilities: CapabilityPolicy{Allowed: []TrafficCapabilityClass{CapLocalControl}},
		Lifetime:     hyphaDecay(),
		IntroDepth:   2,
		MaxDegree:    8,
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid invitation rejected: %v", err)
	}
	for _, m := range []struct {
		name   string
		mutate func(*HyphaInvitation)
	}{
		{"intro depth 0 rejected", func(i *HyphaInvitation) { i.IntroDepth = 0 }},
		{"intro depth 3 rejected", func(i *HyphaInvitation) { i.IntroDepth = 3 }},
		{"max degree 0 rejected", func(i *HyphaInvitation) { i.MaxDegree = 0 }},
		{"bad invitee rejected", func(i *HyphaInvitation) { i.Invitee = IdentityHandle{} }},
	} {
		v := valid
		m.mutate(&v)
		if err := v.Validate(); err == nil {
			t.Errorf("%s: expected Validate() error, got nil", m.name)
		}
	}
}

func TestAnastomosisBridgeValidate(t *testing.T) {
	valid := AnastomosisBridge{
		Version:          NetworkStateVersion,
		LocalCommune:     IdentityHandle{Kind: IdentityKindLibp2pPeer, NodeIdentity: "commune-1"},
		PeerCommune:      IdentityHandle{Kind: IdentityKindLibp2pPeer, NodeIdentity: "commune-2"},
		TrustRelations:   []TrustScope{hyphaScope()},
		AllowedClasses:   []TrafficCapabilityClass{CapSignedContentReplication},
		ForbiddenClasses: []TrafficCapabilityClass{CapEgressTraffic, CapUnknownBulkTraffic},
		AbusePropagation: AbusePropagationRule{Propagate: true, Classes: []string{"abuse"}, Binding: false},
		Quarantine:       QuarantineRule{Reflect: true, Lifetime: hyphaDecay()},
		Revocation:       RevocationRule{Unilateral: true},
		Recovery:         RecoveryRule{RequiresClot: true},
		Evidence:         EvidenceRequirement{Class: "coarse-abuse-category"},
		Lifetime:         hyphaDecay(),
		SignerKeyID:      "signer-key-1",
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid bridge contract rejected: %v", err)
	}
	for _, m := range []struct {
		name   string
		mutate func(*AnastomosisBridge)
	}{
		{"same-Commune rejected (not a bridge)", func(b *AnastomosisBridge) { b.PeerCommune = b.LocalCommune }},
		{"unsigned contract rejected", func(b *AnastomosisBridge) { b.SignerKeyID = "" }},
		{"allowed∩forbidden rejected", func(b *AnastomosisBridge) {
			b.ForbiddenClasses = append(b.ForbiddenClasses, CapSignedContentReplication)
		}},
		{"wrong version rejected", func(b *AnastomosisBridge) { b.Version = 0 }},
	} {
		v := valid
		m.mutate(&v)
		if err := v.Validate(); err == nil {
			t.Errorf("%s: expected Validate() error, got nil", m.name)
		}
	}
}
