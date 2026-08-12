// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"errors"
	"testing"
	"time"
)

// baseLimits mirrors a live node's measured limits (m1, 2026-08-11) so the arithmetic in these tests is
// the arithmetic that actually runs, not a convenient round number.
func baseLimits() RotationLimits {
	return RotationLimits{
		FlipConfirmations:          3,
		MinWeightMargin:            0.1,
		MinInterval:                30 * time.Minute,
		Window:                     time.Hour,
		MaxPerWindow:               2,
		MaxRollbacksPerWindow:      1,
		CooldownAfterRollback:      time.Hour,
		MaxSuppressionTTL:          24 * time.Hour,
		MaxOutstandingSuppressions: 2,
	}
}

// aProto returns a proto id that is genuinely in the closed registry, so these tests exercise the same
// anchor production does rather than a string that happens to look plausible.
func aProto(t *testing.T, want string) string {
	t.Helper()
	if _, ok := ClassForProto(want); !ok {
		t.Fatalf("registry has no proto %q — this test's fixture is stale, not the code", want)
	}
	return want
}

// TestSuppressionMustExpire is the invariant this whole mechanism exists for: a permanent suppression
// must be unrepresentable, not merely discouraged. If this test ever passes with a zero ExpiresAt, the
// loop can again take a transport out of service forever and nothing will put it back.
func TestSuppressionMustExpire(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	p := aProto(t, "hysteria2")

	permanent := SuppressionLease{
		Proto: p, Direction: DirectionIngress, Evidence: EvidenceListenerFault,
		Since: now, Count: 1, // ExpiresAt deliberately zero
	}
	err := permanent.Validate()
	if err == nil {
		t.Fatal("a lease with no expiry validated — a permanent suppression is representable again")
	}
	if !errors.Is(err, ErrLeasePermanent) {
		t.Fatalf("wrong refusal for a permanent lease: %v", err)
	}

	// Expiring at or before the grant is the same hole with an extra step.
	for _, exp := range []time.Time{now, now.Add(-time.Second)} {
		l := permanent
		l.ExpiresAt = exp
		if err := l.Validate(); !errors.Is(err, ErrLeasePermanent) {
			t.Fatalf("expiry %v was accepted or refused for the wrong reason: %v", exp, err)
		}
	}
}

// TestEvidenceDirectionPairing is ADR-0039 in one table. The node may act on what it observes about
// itself, in either direction; it may act on a reachability verdict only where its own probe is
// end-to-end evidence, which is egress alone.
func TestEvidenceDirectionPairing(t *testing.T) {
	rows := []struct {
		ev      SuppressionEvidence
		dir     TransportDirection
		allowed bool
		why     string
	}{
		{EvidenceListenerFault, DirectionIngress, true, "the node's own listener is a fact about the node"},
		{EvidenceListenerFault, DirectionEgress, true, "same fact, other direction"},
		{EvidenceRenderRefused, DirectionIngress, true, "an unrenderable member cannot be served"},
		{EvidenceRenderRefused, DirectionEgress, true, "same"},
		{EvidenceEgressUnreachable, DirectionEgress, true, "the node IS the client on an egress path"},
		{EvidenceEgressUnreachable, DirectionIngress, false,
			"THE ADR: a reachability verdict about an ingress member is a claim about the CLIENT's network, which the node is not on"},
		{EvidenceUnknown, DirectionIngress, false, "the zero value is never evidence"},
		{SuppressionEvidence("no-traffic"), DirectionIngress, false,
			"absence of traffic is indistinguishable from nobody needing that family today"},
		{SuppressionEvidence("clients-report-blocked"), DirectionIngress, false,
			"a node cannot produce client-vantage evidence; that channel is Phase-3 work"},
	}
	for _, r := range rows {
		if got := r.ev.permittedFor(r.dir); got != r.allowed {
			t.Errorf("permittedFor(%q, %q) = %v, want %v — %s", r.ev, r.dir, got, r.allowed, r.why)
		}
	}
}

// TestGrantRefusals drives every refusal. Each row is a way the loop could remove service it has no
// business removing; a row that stops firing is a guard that has quietly gone missing.
func TestGrantRefusals(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	lim := baseLimits()
	p := aProto(t, "hysteria2")
	ok := GrantRequest{
		Proto: p, Direction: DirectionIngress, Evidence: EvidenceListenerFault,
		CarryingTraffic: false, IndependentFamiliesAfter: 4,
	}

	if _, err := (LeaseSet{Version: LeaseSetVersion}).Grant(ok, now, lim); err != nil {
		t.Fatalf("the control row must be granted, else every refusal below proves nothing: %v", err)
	}

	rows := []struct {
		name string
		mut  func(GrantRequest) GrantRequest
		want error
	}{
		{"client-vantage evidence on an ingress member",
			func(r GrantRequest) GrantRequest { r.Evidence = EvidenceEgressUnreachable; return r }, ErrLeaseEvidence},
		{"member is carrying live traffic",
			func(r GrantRequest) GrantRequest { r.CarryingTraffic = true; return r }, ErrLeaseInUse},
		{"would breach the independent-family floor",
			func(r GrantRequest) GrantRequest { r.IndependentFamiliesAfter = 1; return r }, ErrLeaseFloor},
	}
	for _, row := range rows {
		if _, err := (LeaseSet{Version: LeaseSetVersion}).Grant(row.mut(ok), now, lim); !errors.Is(err, row.want) {
			t.Errorf("%s: got %v, want %v", row.name, err, row.want)
		}
	}

	// The budget bounds how much service one correlated fault can remove, and a RENEWAL of something
	// already suppressed must not count against it — otherwise a member at the cap can never have its
	// term extended and silently returns to service while still broken.
	full := LeaseSet{Version: LeaseSetVersion}
	var err error
	for _, name := range []string{"hysteria2", "tuic"} {
		r := ok
		r.Proto = aProto(t, name)
		if full, err = full.Grant(r, now, lim); err != nil {
			t.Fatalf("seeding the budget: %v", err)
		}
	}
	third := ok
	third.Proto = aProto(t, "shadowtls")
	if _, err := full.Grant(third, now, lim); !errors.Is(err, ErrLeaseBudget) {
		t.Errorf("a third suppression at cap 2 was not refused: %v", err)
	}
	renew := ok
	renew.Proto = aProto(t, "tuic")
	if _, err := full.Grant(renew, now.Add(time.Minute), lim); err != nil {
		t.Errorf("renewing an existing lease at cap must be allowed, got %v", err)
	}
}

// TestBackoffConverges is the anti-flap arithmetic, stated as the property that matters: an
// intermittently failing member must cost a DECREASING number of service changes, and must never grow
// a term without bound.
func TestBackoffConverges(t *testing.T) {
	lim := baseLimits() // MinInterval 30m, cap 24h
	want := []time.Duration{
		30 * time.Minute, time.Hour, 2 * time.Hour, 4 * time.Hour,
		8 * time.Hour, 16 * time.Hour, 24 * time.Hour, 24 * time.Hour, 24 * time.Hour,
	}
	for i, w := range want {
		if got := NextTTL(i+1, lim); got != w {
			t.Errorf("NextTTL(%d) = %v, want %v", i+1, got, w)
		}
	}

	// The cap is load-bearing, not cosmetic: without it the term passes any horizon and the lease
	// becomes the permanent suppression Validate cannot catch, because an expiry IS technically set.
	if got := NextTTL(60, lim); got != lim.MaxSuppressionTTL {
		t.Errorf("NextTTL(60) = %v, want the cap %v — an uncapped backoff is a permanent suppression with extra steps", got, lim.MaxSuppressionTTL)
	}

	// Worst case in one hour, with the shipped defaults: the first term alone is 30 minutes and the
	// second is an hour, so at most two suppress/restore pairs can begin inside any hour and the third
	// cannot. State it as an assertion so a limits change that breaks it is caught here.
	var elapsed time.Duration
	cycles := 0
	for n := 1; elapsed < time.Hour; n++ {
		elapsed += NextTTL(n, lim)
		cycles++
	}
	if cycles > 2 {
		t.Errorf("%d suppression terms fit inside one hour; the anti-beacon posture assumes at most 2", cycles)
	}

	// Degenerate limits must not produce a zero or negative term — that would expire instantly and turn
	// the backoff into a hot loop.
	if got := NextTTL(1, RotationLimits{}); got <= 0 {
		t.Errorf("NextTTL with zero limits = %v; a non-positive term expires on arrival and flaps", got)
	}
}

// TestExpiryIsTheRestorePath: reaping is the whole restore mechanism. Nothing asserts the member is
// healthy — the loop merely withdraws its own claim, which is why it needs no precondition.
func TestExpiryIsTheRestorePath(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	lim := baseLimits()
	p := aProto(t, "hysteria2")

	s, err := (LeaseSet{Version: LeaseSetVersion}).Grant(GrantRequest{
		Proto: p, Direction: DirectionIngress, Evidence: EvidenceListenerFault,
		IndependentFamiliesAfter: 4,
	}, now, lim)
	if err != nil {
		t.Fatalf("grant: %v", err)
	}

	if got := s.Suppressed(now.Add(time.Minute)); len(got) != 1 || got[0] != p {
		t.Fatalf("in force: got %v, want [%s]", got, p)
	}
	// Half-open, matching the rotation window convention: a lease expiring exactly at now is done.
	at := now.Add(NextTTL(1, lim))
	if got := s.Suppressed(at); len(got) != 0 {
		t.Errorf("a lease expiring exactly at now is still in force: %v — the boundary convention drifted", got)
	}
	if got := s.Reap(at); len(got.Leases) != 0 {
		t.Errorf("Reap left %d lease(s) at expiry", len(got.Leases))
	}
	// Reap must not disturb a lease that is still in force.
	if got := s.Reap(now.Add(time.Minute)); len(got.Leases) != 1 {
		t.Errorf("Reap dropped a lease that had not expired")
	}
}

// TestBackoffSurvivesExpiry: a member that fails repeatedly must be suppressed for LONGER each time,
// which requires the count to outlive the lease. If Reap reset it, an hourly fault would be suppressed
// for thirty minutes forever and the backoff would accomplish nothing.
func TestBackoffSurvivesExpiry(t *testing.T) {
	lim := baseLimits()
	p := aProto(t, "tuic")
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)

	s := LeaseSet{Version: LeaseSetVersion}
	var terms []time.Duration
	for i := 0; i < 3; i++ {
		var err error
		s, err = s.Grant(GrantRequest{
			Proto: p, Direction: DirectionIngress, Evidence: EvidenceListenerFault,
			History: LeaseHistory{LastCount: i}, IndependentFamiliesAfter: 4,
		}, now, lim)
		if err != nil {
			t.Fatalf("grant %d: %v", i+1, err)
		}
		l := s.Leases[0]
		terms = append(terms, l.ExpiresAt.Sub(l.Since))
		now = l.ExpiresAt
		s = s.Reap(now)
	}
	for i := 1; i < len(terms); i++ {
		if terms[i] <= terms[i-1] {
			t.Errorf("term %d (%v) did not exceed term %d (%v) — the backoff does not survive expiry, so a repeating fault is retried at the same rate forever",
				i+1, terms[i], i, terms[i-1])
		}
	}
}

// TestOperatorCanOverrule: Release is the human's verb. A loop the operator cannot overrule immediately
// is one they will work around by editing files it owns, which is how two disagreeing records appeared
// in the first place.
func TestOperatorCanOverrule(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	lim := baseLimits()
	p := aProto(t, "shadowtls")
	s, err := (LeaseSet{Version: LeaseSetVersion}).Grant(GrantRequest{
		Proto: p, Direction: DirectionIngress, Evidence: EvidenceListenerFault,
		IndependentFamiliesAfter: 4,
	}, now, lim)
	if err != nil {
		t.Fatalf("grant: %v", err)
	}
	if got := s.Release(p).Suppressed(now.Add(time.Minute)); len(got) != 0 {
		t.Errorf("Release left %v suppressed", got)
	}
	// Releasing something not suppressed is a no-op, not an error: an operator should be able to run it
	// without first checking.
	if got := s.Release(aProto(t, "hysteria2")); len(got.Leases) != 1 {
		t.Errorf("releasing an unsuppressed proto disturbed the set")
	}
}

// TestSetValidateRefusesDuplicatesAndOverBudget guards the file's own shape: two leases for one proto
// would let two disagreeing terms exist for the same member, which is the duplicate-truth defect this
// design was built to remove.
func TestSetValidateRefusesDuplicatesAndOverBudget(t *testing.T) {
	now := time.Date(2026, 8, 12, 10, 0, 0, 0, time.UTC)
	lim := baseLimits()
	p := aProto(t, "hysteria2")
	l := SuppressionLease{
		Proto: p, Direction: DirectionIngress, Evidence: EvidenceListenerFault,
		Since: now, ExpiresAt: now.Add(time.Hour), Count: 1,
	}
	dup := LeaseSet{Version: LeaseSetVersion, Leases: []SuppressionLease{l, l}}
	if err := dup.Validate(lim); err == nil {
		t.Error("two leases for one proto validated")
	}
	if err := (LeaseSet{Version: 99}).Validate(lim); err == nil {
		t.Error("an unknown schema version validated")
	}
	over := LeaseSet{Version: LeaseSetVersion}
	for _, n := range []string{"hysteria2", "tuic", "shadowtls"} {
		x := l
		x.Proto = aProto(t, n)
		over.Leases = append(over.Leases, x)
	}
	if err := over.Validate(lim); !errors.Is(err, ErrLeaseBudget) {
		t.Errorf("3 leases against a cap of 2 validated: %v", err)
	}
}
