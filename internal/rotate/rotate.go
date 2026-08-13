// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package rotate is the Phase-2 auto-rotation PLANNER (RP-0012, executing the RP-0010 Plane-3 ADAPT
// decision). It is the explicit
// Layer-2 rotation policy (development.md §2.2 #4 — no silent bypass) expressed as a pure decision:
// given a node's OWN connectivity verdict for the active transport, its OWN tuner-ranked candidate
// weights, the rotation limits, and the between-tick state, Plan returns a RotationPlan — either a
// hold (with a concrete reason) or a single rotation WITHIN the closed transport set. The executor
// that applies the plan reuses the existing node render -> validate (sing-box check) -> promote ->
// verify -> rollback path; this package never touches a node.
//
// It is pure and deterministic (same input -> byte-identical plan), imports only internal/spec +
// fmt + time, reads no wall clock (the clock is the `Now` parameter), starts no goroutine, and does
// NO I/O — the rotator_pure_planner gate enforces that. By construction the input carries only
// node-LOCAL signals (the active verdict + local weights), never a global/peer/digest signal, so a
// rotation can never be driven by a cross-node signal (AC-4 advisory-never-actuates); and a
// RotationCandidate must resolve in the closed TransportRegistry, so a rotation can never grow the
// protocol set (AC-5).
package rotate

import (
	"fmt"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

// DefaultRotationLimits returns the documented Phase-2 policy: rotate only after 3 consecutive
// impaired verdicts, only for a candidate beating the incumbent by 0.1, at most 2 rotations per hour
// and no more than one per 30 minutes, and a one-hour hold latch after a single rollback. MinInterval
// (30m) == Window/MaxPerWindow (1h / 2), so the cooldown alone bounds the rolling-window count (no
// boundary burst) — the rolling-window correctness invariant in spec.RotationLimits.Validate.
func DefaultRotationLimits() spec.RotationLimits {
	return spec.RotationLimits{
		FlipConfirmations:     3,
		MinWeightMargin:       0.1,
		MinInterval:           30 * time.Minute,
		Window:                time.Hour,
		MaxPerWindow:          2,
		MaxRollbacksPerWindow: 1,
		CooldownAfterRollback: time.Hour,
	}
}

// PlanInput is everything the planner needs for one decision. Every field is node-LOCAL: there is
// deliberately no field for a peer / global / digest signal (AC-4).
type PlanInput struct {
	Active        spec.RotationCandidate   `json:"active"`         // the currently-active transport member (its tuner weight is the incumbent)
	ActiveVerdict spec.Verdict             `json:"active_verdict"` // the node's own detector verdict for the active member
	Ranked        []spec.RotationCandidate `json:"ranked"`         // the node's own tuner-ranked candidate members (with weights + promote flags)
	Limits        spec.RotationLimits      `json:"limits"`         // the rotation policy
	State         spec.RotationState       `json:"state"`          // between-tick memory
	Now           time.Time                `json:"now"`            // injected clock (never read internally)

	// IssuedBaseline is the proto set that ALREADY-ISSUED client subscriptions contain — what a client in
	// someone's hands can actually dial. It exists because the rotation space is the INTERSECTION of what
	// the node serves and what clients hold: enabling a transport cannot reach an existing client, but
	// disabling one always can. Empty means "unknown", and unknown fails closed: not knowing what was
	// issued is not permission to remove something.
	IssuedBaseline []string `json:"issued_baseline,omitempty"`

	// Served is the set of members this node is actually serving, each with its OWN verdict and its own
	// direction. A node serves a set for people with different constraints (ADR-0040 §2.2): there is no
	// single member whose health stands for the node, and judging one while the others are invisible is
	// what let a healthy-looking node hide an impaired member.
	//
	// EMPTY means "this producer has not been updated yet", and Plan normalises it from Active/
	// ActiveVerdict so an older measure daemon keeps working unchanged. When it is populated, Active and
	// ActiveVerdict are IGNORED — one source of truth after normalisation, never two.
	Served []ServedMember `json:"served,omitempty"`
}

// ServedMember is one transport this node serves, with the evidence the node holds about it.
type ServedMember struct {
	Member  spec.RotationCandidate `json:"member"`  // the member itself (weight, promote flag, path signals)
	Verdict spec.Verdict           `json:"verdict"` // this node's own detector verdict for THIS member
	// Direction is what the node can observe about it (ADR-0040 §2.3). Ingress: the client dials in, so
	// the loopback probe establishes that the LISTENER serves and never that a client's network reaches
	// it. Egress: the node dials out, so its own probe is end-to-end evidence for that exact path.
	// Recorded per member rather than derived, because the same proto can serve in either role.
	Direction spec.TransportDirection `json:"direction"`
}

// Validate is fail-closed on the member, its verdict, and its direction.
func (m ServedMember) Validate() error {
	if err := m.Member.Validate(); err != nil {
		return err
	}
	if err := m.Verdict.Validate(); err != nil {
		return err
	}
	if !m.Direction.Valid() {
		return fmt.Errorf("served member %q: unknown direction %q", m.Member.Proto, m.Direction)
	}
	return nil
}

// impaired reports whether a connectivity state warrants considering a rotation (anything but a
// clean or not-yet-known channel).
func impaired(s spec.ConnState) bool {
	return s != spec.ConnStateClean && s != spec.ConnStateUnknown
}

// Plan is the pure rotation decision. It validates its inputs, advances the windowed/streak state,
// and applies the guard order (clean -> hysteresis -> cooldown -> rate/latch -> better-candidate);
// it emits a rotation only when every guard passes, otherwise a hold with a concrete reason. The
// returned plan always satisfies spec.RotationPlan.Validate.
func Plan(in PlanInput) (spec.RotationPlan, error) {
	if err := in.Limits.Validate(); err != nil {
		return spec.RotationPlan{}, fmt.Errorf("rotate plan: %w", err)
	}
	// NORMALISE THE SET FIRST, so everything below reads exactly one source (ADR-0040 §2.2).
	//
	// A producer that has not been updated sends Active/ActiveVerdict and no Served; it becomes a
	// one-member set with direction ingress, which is what a served inbound is, and the planner behaves
	// exactly as it did. A producer that sends Served has Active/ActiveVerdict ignored — never merged,
	// because two half-populated sources is the duplicate-truth defect this change exists to remove.
	served := in.Served
	if len(served) == 0 {
		if err := in.Active.Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan active: %w", err)
		}
		if err := in.ActiveVerdict.Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan active verdict: %w", err)
		}
		served = []ServedMember{{Member: in.Active, Verdict: in.ActiveVerdict, Direction: spec.DirectionIngress}}
	}
	for i := range served {
		if err := served[i].Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan served member %d: %w", i, err)
		}
	}
	for i := range in.Ranked {
		if err := in.Ranked[i].Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan candidate %d: %w", i, err)
		}
	}

	// Advance the rate-limit window and the impaired streak (pure; from State + Now). Only the
	// WINDOWED counters reset on a window roll; LastRotateAt and HoldUntil are deliberately carried
	// forward (the cooldown and the rollback latch span window boundaries), so the cooldown/latch
	// guards below read them from in.State while the rate guard reads the windowed ns.RotationsInWindow.
	ns := in.State
	if in.State.WindowStart.IsZero() || in.Now.Sub(in.State.WindowStart) >= in.Limits.Window {
		ns.WindowStart = in.Now
		ns.RotationsInWindow = 0
		ns.RollbacksInWindow = 0
	}
	// PER-MEMBER HYSTERESIS. Each served member carries its own streak, so an impairment on one can
	// never advance the counter that authorises demoting another (ADR-0040 §2.2). A member that clears
	// resets only itself; a member that disappears from the served set drops out of the map rather than
	// leaving a stale streak that would let it be demoted the moment it returns.
	// MIGRATION OFF THE SCALAR. A node whose rotate_state.json predates the map carries `impaired_streak`
	// and nothing else, and dropping it is not free: every member would re-earn its streak from zero, so
	// the first upgraded tick silently delays every rotation by FlipConfirmations ticks — on a node whose
	// transport is failing right now. It is attributable, because the scalar was BY CONSTRUCTION the
	// streak of the one member the old planner judged: the incumbent. So credit it to that member, and
	// only when the map is genuinely absent.
	//
	// This is the one place the legacy Active is read while Served is populated, and it is read as
	// PROVENANCE (whose counter was this?), never as evidence. An incumbent that is not in the served set
	// carries no counter forward — attributing a stranger's streak to a served member would authorise
	// acting on it a full cycle early.
	scalarOwner := ""
	if in.State.ImpairedStreaks == nil {
		if in.Active.Proto != "" {
			scalarOwner = in.Active.Proto
		} else if len(served) == 1 {
			scalarOwner = served[0].Member.Proto
		}
	}
	ns.ImpairedStreaks = make(map[string]int, len(served))
	for i := range served {
		m := served[i]
		if !impaired(m.Verdict.State) {
			continue
		}
		// Saturate at FlipConfirmations so a long hold/latch cannot grow a streak without bound.
		n := in.State.ImpairedStreaks[m.Member.Proto] + 1
		if m.Member.Proto == scalarOwner {
			n = in.State.ImpairedStreak + 1
		}
		if n > in.Limits.FlipConfirmations {
			n = in.Limits.FlipConfirmations
		}
		ns.ImpairedStreaks[m.Member.Proto] = n
	}

	// WHICH MEMBER THIS PLAN IS ABOUT. Deterministic, because the planner is pure and its decision must
	// be reproducible: the impaired member with the longest streak, ties broken by registry order (the
	// same order the candidate choice uses). A healthy set selects nothing and holds.
	regOrder := registryOrder()
	subject := -1
	for i := range served {
		if !impaired(served[i].Verdict.State) {
			continue
		}
		if subject == -1 {
			subject = i
			continue
		}
		a, b := served[i], served[subject]
		sa, sb := ns.ImpairedStreaks[a.Member.Proto], ns.ImpairedStreaks[b.Member.Proto]
		if sa > sb || (sa == sb && regOrder[a.Member.Proto] < regOrder[b.Member.Proto]) {
			subject = i
		}
	}
	active := in.Active
	activeVerdict := in.ActiveVerdict
	if subject >= 0 {
		active = served[subject].Member
		activeVerdict = served[subject].Verdict
		ns.ImpairedStreak = ns.ImpairedStreaks[active.Proto]
	} else {
		// Nothing impaired: report the first member as the subject so a hold names something real, and
		// zero the projection.
		active = served[0].Member
		activeVerdict = served[0].Verdict
		ns.ImpairedStreak = 0
	}

	hold := func(reason spec.RotationReason, because string) (spec.RotationPlan, error) {
		p := spec.RotationPlan{
			Act: false, From: active, Reason: reason, HeldBecause: because,
			NextState: ns, DecidedAt: in.Now,
		}
		p.To.Action = spec.RotationActionNone
		if err := p.Validate(); err != nil {
			return spec.RotationPlan{}, fmt.Errorf("rotate plan (hold) invalid: %w", err)
		}
		return p, nil
	}

	// Guard 1 — never rotate a healthy channel.
	if !impaired(activeVerdict.State) {
		return hold(spec.RotationReasonClean, "active member is clean/healthy")
	}
	// Guard 2 — rollback latch / explicit hold window.
	if in.Now.Before(in.State.HoldUntil) {
		return hold(spec.RotationReasonRollbackHold, "in post-rollback hold latch")
	}
	// Guard 3 — hysteresis: the impairment must persist FlipConfirmations times.
	if ns.ImpairedStreak < in.Limits.FlipConfirmations {
		return hold(spec.RotationReasonStreakTooShort, "impaired verdict has not persisted long enough")
	}
	// Guard 4 — cooldown since the last rotation.
	if !in.State.LastRotateAt.IsZero() && in.Now.Sub(in.State.LastRotateAt) < in.Limits.MinInterval {
		return hold(spec.RotationReasonInCooldown, "within min-interval of the last rotation")
	}
	// NO GUARD 5. The per-window budget guard used to sit here and it could not bind.
	//
	// RotationsInWindow rises only at an act, and every act also sets LastRotateAt = Now. Guard 4 then
	// forces consecutive acts at least MinInterval apart, so by the time a tick reaches this point
	// `Now - WindowStart >= MaxPerWindow * MinInterval`. RotationLimits.Validate requires
	// `MinInterval * MaxPerWindow >= Window` (exactly — see the note there on why it multiplies rather
	// than divides), and the window rolls at `>= Window`. The two intervals do not overlap: the roll
	// always fires first. For every configuration the system accepts, this guard was dead code that read
	// exactly like enforcement — and three separate attempts to test it produced three assertions that
	// could not fail, because no valid input can reach it.
	//
	// The anti-beacon property it was believed to provide now lives entirely in that inequality, which is
	// asserted for the shipped defaults and for any operator-supplied limits at load time. Deleting the
	// guard is what makes the property checkable: an inequality over three numbers can be verified by
	// reading it, a guard that never runs cannot.

	// Guard 6 — pick the best closed-set candidate that beats the incumbent by the margin.
	order := registryOrder()
	bestIdx, anyBetterByMargin := -1, false
	for i := range in.Ranked {
		c := in.Ranked[i]
		if c.Proto == active.Proto {
			continue
		}
		// Never rotate ONTO a member this node's own L7 probe reports client-DEAD — a co-failed sibling
		// (e.g. a second REALITY member sharing the same broken dest as the failing active). Excluded
		// BEFORE the margin/promote checks so a dead candidate neither becomes the target nor sets
		// anyBetterByMargin (which would mislabel the hold as "target not promoted"). Audit-0007 S2.
		if c.L7Dead {
			continue
		}
		// Likewise never rotate ONTO a member whose served client flows the passive path-level observer
		// reports meeting RSTs (RP-0014 chunk B) — a co-reset sibling (an on-path element resetting several
		// classes at once) is no safer a target than an L7-dead one.
		if c.PathReset {
			continue
		}
		// And never rotate ONTO a member whose established served flows the observer reports in a downstream
		// post-connect throughput collapse (RP-0014 chunk B increment 2) — a co-collapsing sibling is no safer.
		if c.PathCollapse {
			continue
		}
		if c.Weight < active.Weight+in.Limits.MinWeightMargin {
			continue
		}
		anyBetterByMargin = true
		if !c.Promoted {
			continue
		}
		if bestIdx == -1 || better(c, in.Ranked[bestIdx], order) {
			bestIdx = i
		}
	}
	if bestIdx == -1 {
		if anyBetterByMargin {
			return hold(spec.RotationReasonTargetNotPromoted, "the best candidate is not tuner-promoted yet")
		}
		// DEMOTE-ACTIVE. Everything above has already established that the incumbent is confirmed broken:
		// impaired, past the hysteresis streak, past the cooldown, within budget. Reaching here only means
		// no SIBLING is better by the margin, which on a node whose transports are all healthy-but-equal is
		// the normal case — and is precisely why this branch used to be a permanent dead end.
		//
		// It is a dead end no longer, because the successor does not have to be advertised. Every issued
		// subscription already carries a urltest group over the whole served set: the client holds all the
		// endpoints and health-checks them itself. The node does not choose a successor — it stops serving
		// the broken member and the client moves itself to one it already has.
		//
		// MEASURED before this was allowed. Client on one node, through another node's urltest group, real
		// fault (the active member's port DROPped): the client failed at once and recovered 276s later WITH
		// THE PORT STILL BLOCKED — one full urltest interval. So it works, and it costs up to one interval
		// of total blackout; an outage SHORTER than the interval produces no failover at all.
		//
		// Gated on the INTERSECTION floor, never the served set — see DemoteKeepsIndependentFallback for
		// the config that satisfies a served-set floor while stranding every client already holding one.
		served := make([]string, 0, len(in.Ranked)+1)
		served = append(served, active.Proto)
		for i := range in.Ranked {
			served = append(served, in.Ranked[i].Proto)
		}
		if ok, fams := spec.DemoteKeepsIndependentFallback(served, in.IssuedBaseline, active.Proto); ok {
			// An ACT plan spends the budget, whatever the action. The promote branch below does this and
			// the demote branch did not, which meant the anti-beacon limits applied to one kind of
			// rotation and not the other: LastRotateAt never advanced so the cooldown never bit,
			// RotationsInWindow never rose so the per-hour cap was never spent, and the streak was never
			// cleared so the very next tick qualified again. An unattended loop could have demoted every
			// ninety seconds without limit — on a node whose whole design is to not beacon. Found on the
			// first real execution of this path, which is what the drill was for.
			ns.LastRotateAt = in.Now
			ns.RotationsInWindow++
			ns.ImpairedStreak = 0
			to := active
			to.Action = spec.RotationActionDemoteActive
			to.ToPort = 0
			p := spec.RotationPlan{
				Act: true, From: active, To: to,
				Reason:      spec.RotationReasonDegradedActive,
				HeldBecause: fmt.Sprintf("the active member is confirmed impaired and no sibling beats it by the margin; ceasing to serve it leaves %d independent families that issued clients still hold, and their urltest group selects one", len(fams)),
				NextState:   ns, DecidedAt: in.Now,
			}
			if err := p.Validate(); err != nil {
				return spec.RotationPlan{}, fmt.Errorf("rotate plan (demote) invalid: %w", err)
			}
			return p, nil
		}
		return hold(spec.RotationReasonNoBetterCandidate, "no closed-set candidate beats the incumbent by the margin, and ceasing to serve the incumbent would not leave two independent families that issued clients hold")
	}

	// Act — rotate to the chosen candidate. This branch only ever PROMOTES a healthy sibling, so the
	// action is normalised unconditionally here (a candidate's incoming Action is advisory only).
	// demote-active is emitted above on its own gated path; rotate-port and regen-reality stay reserved —
	// both change what a client must DIAL, and unlike a demote the client cannot discover the new value
	// from a set it already holds.
	to := in.Ranked[bestIdx]
	to.Action = spec.RotationActionPromoteSibling
	// AND THE PORT IS NOT A THING THIS BRANCH MAY MOVE. The comment above says rotate-port "stays
	// reserved", and the reservation was enforced on the action NAME only — while the capability rode in
	// under promote-sibling. The executor reads .to.to_port with no reference to .to.action
	// (nb_rotate_apply.sh: the dry-run preview and the live overlay persist both), and port keys are in
	// the operator allowlist, so the moved port SURVIVES write_params. ToPort reaches a candidate from
	// the node-local measure config, which generate_measure_configs writes with to_port:0 but which runs
	// only from operator verbs — never from a converge or a timer tick — so a hand-edited value persists
	// indefinitely and the 90-second loop acts on it unattended. Every subscription already in a client's
	// hands names the old port and there is no live channel to re-fetch: the exact outage the reservation
	// exists to prevent, executed under a name the reservation did not cover.
	//
	// The demote branch three screens up has defended itself this way since it was unreserved. This one
	// never did. Zeroing it here rather than validating downstream keeps the closed set closed at the ONE
	// place that decides the move.
	to.ToPort = 0
	ns.LastRotateAt = in.Now
	ns.RotationsInWindow++
	ns.ImpairedStreak = 0
	p := spec.RotationPlan{
		Act: true, From: active, To: to,
		Reason: spec.RotationReasonDegradedActive, NextState: ns, DecidedAt: in.Now,
	}
	if err := p.Validate(); err != nil {
		return spec.RotationPlan{}, fmt.Errorf("rotate plan (act) invalid: %w", err)
	}
	return p, nil
}

// RecordOutcome folds the executor's apply result back into the state. A successful promote needs no
// adjustment (Plan already advanced the window). A rollback spends the rollback budget, and once the
// budget is exhausted the planner LATCHES into a hold for CooldownAfterRollback (leave last-known-good
// running, stop the retry storm, surface for the operator). This budget-then-latch is exactly a
// CIRCUIT-BREAKER open->half-open transition (standard prior art); a vendored breaker (e.g. sony/
// gobreaker) was considered and the ~10-line bespoke latch kept deliberately, to preserve the package's
// zero-dependency purity (no net/os/syscall — the rotator_pure_planner gate) and the Mycelium-specific
// regen/port/sibling actuation it gates. Pure. CALL ORDER: it must run within the
// same tick that produced the plan's NextState (executor: persist NextState, apply, then RecordOutcome
// on the result before the next Plan), so the rollback budget lands in the correct window.
func RecordOutcome(state spec.RotationState, limits spec.RotationLimits, rolledBack bool, now time.Time) spec.RotationState {
	if !rolledBack {
		return state
	}
	s := state
	s.RollbacksInWindow++
	if s.RollbacksInWindow >= limits.MaxRollbacksPerWindow {
		s.HoldUntil = now.Add(limits.CooldownAfterRollback)
	}
	return s
}

// registryOrder maps each closed-set proto to its position in the canonical TransportRegistry, for
// deterministic tie-breaking (a lower index wins).
func registryOrder() map[string]int {
	reg := spec.TransportRegistry()
	m := make(map[string]int, len(reg))
	for i, d := range reg {
		m[d.Proto] = i
	}
	return m
}

// better reports whether candidate a should be preferred over b: higher weight wins; on an exact
// tie, the lower registry index wins (deterministic).
// better ranks two viable candidates. EXPOSURE FIRST: the safest tier wins outright, so a riskier shape
// is chosen only when nothing safer is viable (dead / reset / collapsing / not beating the incumbent are
// all filtered out before this point). Measured weight ranks only WITHIN a tier, and the registry order
// breaks a remaining tie.
//
// Weight deliberately does NOT out-rank exposure: a risky shape that happens to work today would
// otherwise be promoted over a safe one, which inverts the point. The cost of a risky shape is not paid
// while it works — it is paid when it is classified, and by then it has also taught the observer what
// this node is. Availability is protected by the viability filters above, not by demoting safety here.
func better(a, b spec.RotationCandidate, order map[string]int) bool {
	ea, eb := exposureOf(a.Proto), exposureOf(b.Proto)
	if ea != eb {
		return ea < eb
	}
	if a.Weight != b.Weight {
		return a.Weight > b.Weight
	}
	return order[a.Proto] < order[b.Proto]
}

// exposureOf returns a proto's detection-exposure tier from the closed registry. An unknown proto sorts
// LAST (never silently treated as safe) — Validate rejects it upstream, so this is a belt, not a path.
func exposureOf(proto string) spec.ExposureTier {
	for _, d := range spec.TransportRegistry() {
		if d.Proto == proto {
			return d.Exposure
		}
	}
	return spec.ExposureNoCover + 1
}
