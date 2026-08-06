// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package rotate

import (
	"testing"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

// Network-condition scenarios for the auto-rotation loop (development.md §7.3, §14.3).
//
// WHY THESE EXIST AND WHAT THEY ARE NOT.
//   development.md §14.3 makes netsim scenarios mandatory for ANY change to the rotation loop, each with
//   a measurable criterion. The reserved-move fix (To.ToPort zeroed on every act branch) is such a
//   change and landed without them.
//
//   §7.3 describes those scenarios in terms of tc/netem, RST injection and containers. That harness does
//   not exist in this tree, and standing one up is a subsystem, not a step inside a remediation RP. What
//   IS testable here — deterministically, with no sockets — is the half the scenarios actually exercise:
//   the loop is a pure decision function over a per-tick signal sequence, and every §7.3 criterion
//   ("produces the correct diagnosis", "switches within the SLO", "does not enter an infinite rotation
//   cycle") is a statement about that function's output over a sequence.
//
//   So these drive the REAL Plan over the four §7.3 signal patterns and assert the SLO in TICKS. They do
//   not prove the detector derives the right ConnState from wire signals (that is the detector's own
//   evaluation) and they do not measure wall-clock recovery. RP-0017 §7 records the socket/netem half as
//   deferred with this reason rather than skipped: §7.5 permits running such suites locally and recording
//   the result, it does not permit pretending the requirement was met.
//
// THE SLO, stated once. With DefaultRotationLimits the loop must act on the tick where the impaired
// streak reaches FlipConfirmations — no earlier (that is the hysteresis) and no later (that is the
// recovery bound). Every scenario below is measured against that number, not against a hand-copied
// constant, so a change to the limit moves the expectation with it.

// runTicks feeds one verdict per tick through the real Plan, carrying NextState forward exactly as the
// executor does, and returns the 0-based index of every tick on which the loop ACTED.
//
// Carrying NextState is the whole point: a scenario that rebuilt fresh state each tick would never
// accumulate a streak, never spend the window budget, and never latch — it would report hysteresis and
// anti-flap working when neither had been exercised.
func runTicks(t *testing.T, in PlanInput, verdicts []spec.Verdict) []int {
	t.Helper()
	acted := []int{}
	st := in.State
	for i, v := range verdicts {
		cur := in
		cur.State = st
		cur.ActiveVerdict = v
		cur.Now = t0.Add(time.Duration(i) * 90 * time.Second) // the loop's own cadence
		p, err := Plan(cur)
		if err != nil {
			t.Fatalf("tick %d: Plan: %v", i, err)
		}
		if err := p.Validate(); err != nil {
			t.Fatalf("tick %d: emitted plan invalid: %v", i, err)
		}
		if p.Act {
			acted = append(acted, i)
		}
		st = p.NextState
	}
	return acted
}

func repeat(v spec.Verdict, n int) []spec.Verdict {
	out := make([]spec.Verdict, n)
	for i := range out {
		out[i] = v
	}
	return out
}

// TestNetsimSustainedImpairmentActsWithinSLO covers §7.3's first three scenarios — RST injection,
// post-connect throttling, and full shutdown of the selected transport. Each is a DIFFERENT wire
// signal that must reach the same conclusion: sustained impairment moves the node, and it moves on the
// hysteresis boundary rather than on the first bad tick.
func TestNetsimSustainedImpairmentActsWithinSLO(t *testing.T) {
	lim := DefaultRotationLimits()
	slo := lim.FlipConfirmations // the tick the streak completes; 0-based index slo-1

	cases := []struct {
		name    string
		verdict spec.Verdict
	}{
		{"rst_injection", vdt(spec.ConnStateBlocked, spec.ReasonConnectionReset)},
		{"handshake_timeout", vdt(spec.ConnStateBlocked, spec.ReasonHandshakeTimeout)},
		{"throttle", vdt(spec.ConnStateThrottled, spec.ReasonThroughputCollapse)},
		{"shutdown", vdt(spec.ConnStateShutdown, spec.ReasonUnreachable)},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			in := base()
			in.State = spec.RotationState{} // a fresh node: no streak, no window, no latch
			acted := runTicks(t, in, repeat(tc.verdict, slo+3))

			if len(acted) == 0 {
				t.Fatalf("%s: sustained impairment over %d ticks produced NO rotation. The transport is "+
					"confirmed impaired and the node keeps serving it — clients stay on a path the loop "+
					"itself has diagnosed as dead.", tc.name, slo+3)
			}
			if acted[0] != slo-1 {
				t.Fatalf("%s: first act on tick %d, expected tick %d (FlipConfirmations=%d). Earlier is a "+
					"hysteresis failure — one bad sample must not move a node, or a transient blip costs "+
					"every client a reconnect. Later means impairment persists past the SLO.",
					tc.name, acted[0], slo-1, lim.FlipConfirmations)
			}
			// EXACTLY ONE act in this window. MinInterval (30 min) is four times wider than the six
			// 90-second ticks here, so the cooldown blocks everything after the first. Asserting the
			// per-window BUDGET here could not fail — the comparison was always `1 > 2`, and deleting the
			// budget guard changed nothing. The budget has its own scenario below, ticking past the
			// cooldown so it is the binding constraint rather than a bystander (Audit-0010 F-012a).
			if len(acted) != 1 {
				t.Fatalf("%s: %d acts across %d ticks (at %v), expected exactly 1 — MinInterval is %v, wider "+
					"than this whole window, so a second act means the cooldown did not hold.",
					tc.name, len(acted), slo+3, acted, lim.MinInterval)
			}
		})
	}
}

// TestNetsimWindowBudgetIsUnreachableUnderValidLimits records what is actually true about the
// per-window rotation budget, because two attempts to "test" it produced assertions that could not fail.
//
// FIRST ATTEMPT: assert `len(acted) <= MaxPerWindow` inside the sustained-impairment scenario. That spans
// six 90-second ticks against a 30-minute MinInterval, so the cooldown blocked everything after the first
// act and the comparison was permanently `1 > 2`.
//
// SECOND ATTEMPT: give the budget its own scenario, spacing the ticks PAST the cooldown so the cap would
// be the binding constraint. It passed, and deleting the budget guard from Plan did not fail it — because
// the cap CANNOT be the binding constraint. RotationLimits.Validate refuses any limits where
// `MinInterval < Window/MaxPerWindow` (internal/spec/rotate.go), so for every VALID configuration the
// cooldown already spaces acts at least Window/MaxPerWindow apart, which bounds a rolling window to
// MaxPerWindow acts on its own. `if ns.RotationsInWindow >= in.Limits.MaxPerWindow` is therefore
// unreachable for any limits the system will accept.
//
// So the honest test is not a scenario that pretends to exercise the guard. It is: (1) pin the INVARIANT
// that makes the guard redundant, and (2) pin the property that actually matters — the observed count
// never exceeds the cap. If the validity rule is ever relaxed, (1) fails, the guard becomes load-bearing,
// and whoever relaxed it is told here that it now needs a real test.
func TestNetsimWindowBudgetIsUnreachableUnderValidLimits(t *testing.T) {
	lim := DefaultRotationLimits()
	if err := lim.Validate(); err != nil {
		t.Fatalf("the defaults do not validate: %v", err)
	}

	// (1) THE INVARIANT. This is why the budget guard cannot bind.
	spacingFloor := lim.Window / time.Duration(lim.MaxPerWindow)
	if lim.MinInterval < spacingFloor {
		t.Fatalf("MinInterval (%v) is now SHORTER than Window/MaxPerWindow (%v). The cooldown no longer "+
			"bounds the per-window count on its own, so `RotationsInWindow >= MaxPerWindow` in rotate.Plan "+
			"has become the binding constraint — and it has no test, because until now it could not be "+
			"reached. Write one before shipping this.", lim.MinInterval, spacingFloor)
	}

	// (2) THE PROPERTY. Ticks spaced past the cooldown, sustained impairment throughout: the count must
	// stay within the cap however the two mechanisms divide the work between them.
	in := base()
	in.State = spec.RotationState{}
	blocked := vdt(spec.ConnStateBlocked, spec.ReasonConnectionReset)
	spacing := lim.MinInterval + time.Minute
	ticks := int(lim.Window/spacing) + 2

	acted, st := 0, in.State
	for i := 0; i < ticks; i++ {
		cur := in
		cur.State = st
		cur.ActiveVerdict = blocked
		cur.Now = t0.Add(time.Duration(i) * spacing)
		p, err := Plan(cur)
		if err != nil {
			t.Fatalf("tick %d: Plan: %v", i, err)
		}
		if p.Act {
			acted++
		}
		st = p.NextState
	}
	if acted == 0 {
		t.Fatalf("no rotation across %d ticks spaced %v apart under sustained impairment — the act path is "+
			"never reached, so this row measures nothing", ticks, spacing)
	}
	if acted > lim.MaxPerWindow {
		t.Fatalf("%d rotations inside one %v window, cap %d. An unattended loop that keeps rotating is a "+
			"beacon on a rhythm.", acted, lim.Window, lim.MaxPerWindow)
	}
}

// TestNetsimCleanLinkNeverMoves is the control. Without it every assertion above is equally consistent
// with a loop that rotates unconditionally.
func TestNetsimCleanLinkNeverMoves(t *testing.T) {
	in := base()
	in.State = spec.RotationState{}
	acted := runTicks(t, in, repeat(vdt(spec.ConnStateClean, spec.ReasonNone), 20))
	if len(acted) != 0 {
		t.Fatalf("a healthy link produced %d rotation(s) at ticks %v. A false migration costs every "+
			"client on the node a reconnect and teaches the observer that the node reacts.", len(acted), acted)
	}
}

// TestNetsimFlappingDoesNotOscillate is §7.3's anti-flapping scenario: a link alternately alive and dead
// must not drive an endless rotation cycle.
//
// The criterion is BOUNDED MOVES, not zero moves. A genuinely oscillating link may be worth leaving
// once; what must never happen is one move per oscillation. Both the streak reset on a clean tick and
// the per-window budget bound it, and this asserts the composite rather than either mechanism alone.
func TestNetsimFlappingDoesNotOscillate(t *testing.T) {
	lim := DefaultRotationLimits()
	in := base()
	in.State = spec.RotationState{}

	seq := make([]spec.Verdict, 0, 40)
	for i := 0; i < 20; i++ {
		seq = append(seq, vdt(spec.ConnStateBlocked, spec.ReasonConnectionReset))
		seq = append(seq, vdt(spec.ConnStateClean, spec.ReasonNone))
	}
	acted := runTicks(t, in, seq)

	if len(acted) > lim.MaxPerWindow {
		t.Fatalf("an oscillating link produced %d rotations (ticks %v); the window budget is %d. This is "+
			"the infinite-rotation cycle §7.3 exists to forbid: every move restarts every client's "+
			"connection, and a node that moves on each oscillation announces itself on a rhythm.",
			len(acted), acted, lim.MaxPerWindow)
	}
}

// TestNetsimNoScenarioEmitsAPortMove is the scenario-level guard for the reserved-move set — the change
// these netsim tests were owed for.
//
// The unit test for it asserts on a single Plan call. This asserts it over every §7.3 signal pattern
// with state carried forward, because the failure mode was never a single malformed call: it was the
// unattended loop, ticking every ninety seconds, carrying a to_port supplied once by a hand-edited
// measure config and never reset by any converge.
func TestNetsimNoScenarioEmitsAPortMove(t *testing.T) {
	poisoned := cand("vless-reality-grpc", 0.9, true)
	poisoned.FromPort = 8443
	poisoned.ToPort = 9443

	patterns := map[string][]spec.Verdict{
		"sustained_block": repeat(vdt(spec.ConnStateBlocked, spec.ReasonConnectionReset), 12),
		"throttle":        repeat(vdt(spec.ConnStateThrottled, spec.ReasonThroughputCollapse), 12),
		"shutdown":        repeat(vdt(spec.ConnStateShutdown, spec.ReasonUnreachable), 12),
	}

	for name, seq := range patterns {
		t.Run(name, func(t *testing.T) {
			in := base()
			in.State = spec.RotationState{}
			in.Ranked = []spec.RotationCandidate{poisoned}

			st := in.State
			for i, v := range seq {
				cur := in
				cur.State = st
				cur.ActiveVerdict = v
				cur.Now = t0.Add(time.Duration(i) * 90 * time.Second)
				p, err := Plan(cur)
				if err != nil {
					t.Fatalf("tick %d: Plan: %v", i, err)
				}
				if p.Act && p.To.ToPort != 0 {
					t.Fatalf("tick %d: the loop emitted an act plan carrying to_port=%d under action %q. "+
						"The executor applies to_port without consulting the action and the port key survives "+
						"write_params, so this is a served-port move performed unattended while rotate-port is "+
						"unrequestable — and every subscription in a client's hands names the old port, with no "+
						"live channel to re-fetch.", i, p.To.ToPort, p.To.Action)
				}
				st = p.NextState
			}
		})
	}
}
