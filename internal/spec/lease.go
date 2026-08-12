// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package spec — suppression leases (ADR-0039).
//
// WHAT THIS IS FOR
//
//	The rotation loop can take a transport out of service. Until now it could not put one back: the
//	closed RotationAction set has demote-active and no inverse, and revert_rotation_overlay() runs only
//	on a failed apply. Measured on three live nodes on 2026-08-11 — a deliberate loopback-only fault
//	produced a correct unattended demote, and the transport was still suppressed long after the fault
//	cleared, with nothing reporting it.
//
//	The obvious repair — "restore when the verdict goes clean again" — is WRONG, and the reason is the
//	whole design. measure.New seeds every registry member ConnStateClean at construction, and the daemon
//	restarts on every spine change, so a clean verdict for a member the node is NOT SERVING is
//	manufacturable rather than observed. Restoring on it would be the loop asserting a fact it cannot
//	establish, which is the defect class ADR-0039 exists to close.
//
//	So the loop's write is not a decision, it is a LEASE: a time-bounded claim that stops being in force
//	at ExpiresAt, at which point the identical test that produced it runs again against a served member.
//	Expiry needs no precondition — the loop is withdrawing its own claim, not asserting anything — which
//	is why it is the only one of {suppress, restore-on-clean, expire} that fail-closed permits
//	unconditionally.
//
// THE INVARIANT THAT IS THE POINT
//
//	Value == false  =>  ExpiresAt is set and after Since.
//
//	A permanent suppression is UNREPRESENTABLE, not merely refused. Validate() cannot be forgotten at a
//	call site the way a guard can, and no future branch can construct one by accident.
package spec

import (
	"errors"
	"fmt"
	"sort"
	"time"
)

// TransportDirection is the CLOSED set of roles a transport member can serve in on a node, and it
// exists because the two roles differ in WHAT THE NODE CAN OBSERVE — not in how they are configured.
//
//	DirectionIngress — client -> node. The node terminates it. Its loopback probe (ADR-0036) can prove
//	  the LISTENER serves; it can never prove a client's network reaches it, because the node is not on
//	  that network. Suppressing an ingress member therefore requires evidence of a fault AT THE NODE.
//	DirectionEgress — node -> elsewhere (an upstream, a peer, a cover host). The node is the client, so
//	  its own probe IS end-to-end evidence for exactly the path in question, and a reachability verdict
//	  is a sound basis for suppression.
//
// This distinction is the machine-checkable form of ADR-0039 §2.1. Collapsing it is how the loop came
// to treat "my loopback dial failed" as "clients cannot reach me".
type TransportDirection string

const (
	// DirectionUnknown is the zero value and is never a valid wire value.
	DirectionUnknown TransportDirection = ""
	// DirectionIngress is a served inbound: the client dials the node.
	DirectionIngress TransportDirection = "ingress"
	// DirectionEgress is an outbound the node itself dials.
	DirectionEgress TransportDirection = "egress"
)

// ValidDirections is the closed set, emitted into control/vocab.json so shell compares rather than
// re-deriving (ADR-0038).
func ValidDirections() []TransportDirection {
	return []TransportDirection{DirectionIngress, DirectionEgress}
}

// Valid reports whether d is a member of the closed set.
func (d TransportDirection) Valid() bool {
	return d == DirectionIngress || d == DirectionEgress
}

// SuppressionEvidence is the CLOSED set of things that may justify taking a member out of service.
//
// Every member of this set is something the node OBSERVES ABOUT ITSELF. There is deliberately no member
// for "clients report they cannot reach it", "traffic stopped arriving", or any other client-vantage
// signal — not because those are uninteresting, but because a node cannot produce them (ADR-0039 §2.2:
// the only direct evidence originates at a client, and that channel is Phase-3 work). Their absence
// from this enum is what makes "suppressed because nobody connected today" unrepresentable rather than
// merely discouraged.
type SuppressionEvidence string

const (
	// EvidenceUnknown is the zero value and is never valid.
	EvidenceUnknown SuppressionEvidence = ""
	// EvidenceListenerFault — the node's own listener or engine is not serving this member: the bind is
	// absent, the engine is down, or the loopback L7 handshake against its own listener fails. Sound for
	// BOTH directions: it is a statement about the node.
	EvidenceListenerFault SuppressionEvidence = "listener-fault"
	// EvidenceRenderRefused — the member's config could not be rendered or failed validation, so serving
	// it is not possible. Sound for both directions.
	EvidenceRenderRefused SuppressionEvidence = "render-refused"
	// EvidenceEgressUnreachable — the node dialled this member's remote itself and could not reach it.
	// Sound ONLY for DirectionEgress, where the node is the client and its probe is end-to-end evidence
	// for the exact path. Paired with an ingress member it is a category error, and Validate refuses it.
	EvidenceEgressUnreachable SuppressionEvidence = "egress-unreachable"
)

// ValidEvidence is the closed set, emitted into control/vocab.json.
func ValidEvidence() []SuppressionEvidence {
	return []SuppressionEvidence{EvidenceListenerFault, EvidenceRenderRefused, EvidenceEgressUnreachable}
}

// permittedFor reports whether this evidence may justify suppressing a member serving in direction d.
// The one asymmetry is the whole of ADR-0039: an egress probe is end-to-end for its own path, an
// ingress probe is not.
func (e SuppressionEvidence) permittedFor(d TransportDirection) bool {
	switch e {
	case EvidenceListenerFault, EvidenceRenderRefused:
		return d.Valid()
	case EvidenceEgressUnreachable:
		return d == DirectionEgress
	}
	return false
}

// Errors callers match on. A caller that cannot distinguish "the lease set is full" from "this evidence
// is not permitted for this direction" ends up logging one message for two different operator actions.
var (
	// ErrLeasePermanent is returned when a suppression carries no expiry — the invariant that makes a
	// permanent suppression unrepresentable.
	ErrLeasePermanent = errors.New("suppression lease: a suppression must expire")
	// ErrLeaseEvidence is returned when the evidence cannot justify suppression in that direction.
	ErrLeaseEvidence = errors.New("suppression lease: evidence is not permitted for this direction")
	// ErrLeaseBudget is returned when granting would exceed MaxOutstandingSuppressions.
	ErrLeaseBudget = errors.New("suppression lease: outstanding-suppression budget exhausted")
	// ErrLeaseInUse is returned when the member is currently carrying traffic.
	ErrLeaseInUse = errors.New("suppression lease: member is carrying traffic")
	// ErrLeaseFloor is returned when granting would drop the node below its independent-family floor.
	ErrLeaseFloor = errors.New("suppression lease: would breach the independent-family floor")
)

// SuppressionLease is one loop-owned, time-bounded claim that a member is not to be served.
//
// It is deliberately NOT an operator setting and does not live in the operator's overlay: one truth
// type, one owner (development.md §2.2 item 8). The loop's temporary reaction and the operator's
// durable choice were previously stored in the same field, which is why an operator repair and a stale
// loop delta could disagree about the same transport with neither owning the answer.
type SuppressionLease struct {
	// Proto is the closed-registry proto id this lease suppresses.
	Proto string `json:"proto"`
	// Direction is the role the member was serving in when the lease was granted. It is recorded rather
	// than re-derived so a later reader can check the evidence/direction pairing without the registry.
	Direction TransportDirection `json:"direction"`
	// Evidence is why the loop was entitled to grant it.
	Evidence SuppressionEvidence `json:"evidence"`
	// Since is when this lease was granted (RFC3339 UTC).
	Since time.Time `json:"since"`
	// ExpiresAt is when it stops being in force. NEVER zero — see the package comment.
	ExpiresAt time.Time `json:"expires_at"`
	// Count is how many consecutive times this proto has been suppressed, >= 1. It drives the backoff:
	// a member that keeps failing is suppressed for longer each time, so an intermittent fault costs a
	// bounded and DECREASING number of config changes rather than an unbounded flap.
	Count int `json:"count"`
}

// Validate is fail-closed. Rule L4 is the reason this file exists.
func (l SuppressionLease) Validate() error {
	if l.Proto == "" {
		return fmt.Errorf("suppression lease: empty proto")
	}
	if _, ok := ClassForProto(l.Proto); !ok {
		// The closed-set anchor, the same one RotationCandidate.Validate uses: a lease for a proto
		// outside the registry would suppress something no renderer knows about.
		return fmt.Errorf("suppression lease: unknown proto %q", l.Proto)
	}
	if !l.Direction.Valid() {
		return fmt.Errorf("suppression lease: unknown direction %q for %s", l.Direction, l.Proto)
	}
	if !l.Evidence.permittedFor(l.Direction) {
		return fmt.Errorf("%w: %q cannot suppress a %s member (%s)",
			ErrLeaseEvidence, l.Evidence, l.Direction, l.Proto)
	}
	if l.Since.IsZero() {
		return fmt.Errorf("suppression lease: %s has no grant time", l.Proto)
	}
	// L4 — THE INVARIANT. A suppression that never expires is the state this whole mechanism exists to
	// make impossible; refusing it here means no call site can construct one, however it is reached.
	if l.ExpiresAt.IsZero() {
		return fmt.Errorf("%w: %s carries no expiry", ErrLeasePermanent, l.Proto)
	}
	if !l.ExpiresAt.After(l.Since) {
		return fmt.Errorf("%w: %s expires at or before it was granted (since=%s expires=%s)",
			ErrLeasePermanent, l.Proto, l.Since.UTC().Format(time.RFC3339), l.ExpiresAt.UTC().Format(time.RFC3339))
	}
	if l.Count < 1 {
		return fmt.Errorf("suppression lease: %s has count %d, want >= 1", l.Proto, l.Count)
	}
	return nil
}

// InForce reports whether this lease still suppresses at now. Half-open by the same convention the
// rotation window uses: a lease expiring exactly at now is no longer in force.
func (l SuppressionLease) InForce(now time.Time) bool { return now.Before(l.ExpiresAt) }

// LeaseSet is the node's whole suppression state: at most one lease per proto.
type LeaseSet struct {
	Version int                `json:"version"`
	Leases  []SuppressionLease `json:"leases"`
}

// LeaseSetVersion is the on-disk schema version.
const LeaseSetVersion = 1

// Validate checks the set as a whole. lim.MaxOutstandingSuppressions bounds how much of the node's
// service surface the loop may remove at once — without it, a correlated fault (a bad render, an engine
// restart) could suppress everything one member at a time, each grant individually justified.
func (s LeaseSet) Validate(lim RotationLimits) error {
	if s.Version != LeaseSetVersion {
		return fmt.Errorf("lease set: version %d, want %d", s.Version, LeaseSetVersion)
	}
	seen := make(map[string]struct{}, len(s.Leases))
	for _, l := range s.Leases {
		if err := l.Validate(); err != nil {
			return err
		}
		if _, dup := seen[l.Proto]; dup {
			return fmt.Errorf("lease set: %s appears twice — one lease per proto", l.Proto)
		}
		seen[l.Proto] = struct{}{}
	}
	if max := lim.MaxOutstandingSuppressions; max > 0 && len(s.Leases) > max {
		return fmt.Errorf("%w: %d leases, cap %d", ErrLeaseBudget, len(s.Leases), max)
	}
	return nil
}

// Suppressed returns the protos suppressed at now, sorted. Callers render from this; it is the only
// question the renderer asks of the lease layer.
func (s LeaseSet) Suppressed(now time.Time) []string {
	out := make([]string, 0, len(s.Leases))
	for _, l := range s.Leases {
		if l.InForce(now) {
			out = append(out, l.Proto)
		}
	}
	sort.Strings(out)
	return out
}

// Expired returns leases whose term has run out at now, sorted by proto. These are what the executor
// reaps — and reaping is the whole restore path: the loop withdraws its claim and the member returns to
// whatever the operator asked for.
func (s LeaseSet) Expired(now time.Time) []SuppressionLease {
	out := make([]SuppressionLease, 0, len(s.Leases))
	for _, l := range s.Leases {
		if !l.InForce(now) {
			out = append(out, l)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Proto < out[j].Proto })
	return out
}

// Reap drops expired leases, keeping the rest in a stable order.
//
// It deliberately does NOT reset Count: the backoff has to survive expiry, or a member that fails every
// hour is suppressed for the same short span forever and the backoff accomplishes nothing. Count decays
// through Grant's forget window instead — see NextTTL.
func (s LeaseSet) Reap(now time.Time) LeaseSet {
	kept := make([]SuppressionLease, 0, len(s.Leases))
	for _, l := range s.Leases {
		if l.InForce(now) {
			kept = append(kept, l)
		}
	}
	sort.Slice(kept, func(i, j int) bool { return kept[i].Proto < kept[j].Proto })
	return LeaseSet{Version: LeaseSetVersion, Leases: kept}
}

// Release removes any lease for proto, expired or in force. This is the OPERATOR's verb: it exists so a
// human can overrule the loop immediately rather than waiting out a term they disagree with. It is not
// reachable from the planner.
func (s LeaseSet) Release(proto string) LeaseSet {
	kept := make([]SuppressionLease, 0, len(s.Leases))
	for _, l := range s.Leases {
		if l.Proto != proto {
			kept = append(kept, l)
		}
	}
	return LeaseSet{Version: LeaseSetVersion, Leases: kept}
}

// LeaseHistory is what Grant needs to know about a proto's past to size the next term. It is passed in
// rather than read from disk so the planner stays pure (no clock, no I/O) — the same posture the
// rotation planner already holds.
type LeaseHistory struct {
	// LastCount is the Count of the most recent lease for this proto, in force or expired. Zero when the
	// proto has never been suppressed, or when its last suppression is older than the forget window.
	LastCount int `json:"last_count"`
}

// GrantRequest is everything Grant needs. Every field is evidence someone else established; Grant
// decides only whether the grant is permitted and how long it lasts.
type GrantRequest struct {
	Proto     string              `json:"proto"`
	Direction TransportDirection  `json:"direction"`
	Evidence  SuppressionEvidence `json:"evidence"`
	History   LeaseHistory        `json:"history"`

	// CarryingTraffic is whether this member is serving live sessions RIGHT NOW. A member that is
	// carrying traffic is not suppressed, whatever the probe says: the node cannot see the clients on
	// it, and taking it away would break the working channel of everyone using it in order to react to
	// a fault they are visibly not experiencing (ADR-0039 §2.1).
	CarryingTraffic bool `json:"carrying_traffic"`

	// IndependentFamiliesAfter is how many independent transport families would still be served if this
	// grant went through. RP-0013 floors it at 2: a client blocked on one family is served by another,
	// and that is the whole reason wrongly removing a family costs more than wrongly keeping one.
	IndependentFamiliesAfter int `json:"independent_families_after"`
}

// IndependentFamilyFloor is the minimum number of independent families a node must keep serving
// (RP-0013 AC-6). Suppression may never take a node below it, whatever the evidence.
const IndependentFamilyFloor = 2

// Grant returns the set with a lease for req.Proto added or renewed, or an error naming the refusal.
//
// It is a pure function of its arguments and now — no clock, no disk, no registry mutation — so it can
// be driven exhaustively by a value table, which is how the refusals below are proven to fire.
func (s LeaseSet) Grant(req GrantRequest, now time.Time, lim RotationLimits) (LeaseSet, error) {
	if !req.Direction.Valid() {
		return s, fmt.Errorf("suppression lease: unknown direction %q for %s", req.Direction, req.Proto)
	}
	if !req.Evidence.permittedFor(req.Direction) {
		// The refusal ADR-0039 is about. Worth a message an operator can act on: it names the boundary
		// rather than saying "invalid".
		return s, fmt.Errorf("%w: %q cannot suppress the %s member %s — a node observes its own faults, "+
			"never whether a client's network reaches it (ADR-0039)",
			ErrLeaseEvidence, req.Evidence, req.Direction, req.Proto)
	}
	if req.CarryingTraffic {
		return s, fmt.Errorf("%w: %s is serving live sessions — a probe failure is not permission to "+
			"disconnect the clients visibly succeeding on it", ErrLeaseInUse, req.Proto)
	}
	if req.IndependentFamiliesAfter < IndependentFamilyFloor {
		return s, fmt.Errorf("%w: suppressing %s would leave %d independent families, floor is %d (RP-0013)",
			ErrLeaseFloor, req.Proto, req.IndependentFamiliesAfter, IndependentFamilyFloor)
	}

	renewal := false
	for _, l := range s.Leases {
		if l.Proto == req.Proto {
			renewal = true
			break
		}
	}
	if max := lim.MaxOutstandingSuppressions; max > 0 && !renewal && len(s.Leases) >= max {
		return s, fmt.Errorf("%w: %d already suppressed, cap %d — refusing to remove more of this node's "+
			"service surface at once", ErrLeaseBudget, len(s.Leases), max)
	}

	count := req.History.LastCount + 1
	lease := SuppressionLease{
		Proto:     req.Proto,
		Direction: req.Direction,
		Evidence:  req.Evidence,
		Since:     now.UTC(),
		ExpiresAt: now.UTC().Add(NextTTL(count, lim)),
		Count:     count,
	}
	if err := lease.Validate(); err != nil {
		return s, err
	}

	out := make([]SuppressionLease, 0, len(s.Leases)+1)
	for _, l := range s.Leases {
		if l.Proto != req.Proto {
			out = append(out, l)
		}
	}
	out = append(out, lease)
	sort.Slice(out, func(i, j int) bool { return out[i].Proto < out[j].Proto })
	return LeaseSet{Version: LeaseSetVersion, Leases: out}, nil
}

// NextTTL is the backoff: the n-th consecutive suppression of a proto lasts MinInterval << (n-1),
// capped at MaxSuppressionTTL.
//
// WHY BACKOFF AND NOT A FIXED TERM. The failure this must survive is an INTERMITTENT fault: impaired,
// clears, impaired, clears. Under a fixed term every cycle costs a full suppress/restore pair — a
// config change, a service reload, and a client-visible flap, forever. Doubling makes the cost of a
// persistent problem converge: the member is retried less and less often, so a genuinely broken
// transport settles at the cap instead of oscillating, while a one-off fault still gets a short term
// and a prompt retry.
//
// The cap is not optional. Without it the term grows past any horizon and the lease becomes the
// permanent suppression this file exists to prevent — Validate would still pass, since the expiry is
// technically set, which is exactly the kind of letter-not-spirit hole worth closing here rather than
// in a review comment.
func NextTTL(count int, lim RotationLimits) time.Duration {
	base := lim.MinInterval
	if base <= 0 {
		base = 30 * time.Minute
	}
	cap := lim.MaxSuppressionTTL
	if cap <= 0 {
		cap = 24 * time.Hour
	}
	if count < 1 {
		count = 1
	}
	ttl := base
	for i := 1; i < count; i++ {
		if ttl > cap/2 {
			return cap
		}
		ttl *= 2
	}
	if ttl > cap {
		return cap
	}
	return ttl
}
