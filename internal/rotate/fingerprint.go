// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package rotate

import (
	"fmt"

	"github.com/mycelium0/mycelium/internal/spec"
)

// PlanFingerprint is the pure client-fingerprint rotation decision (RP-0015 increment B) — the SCALAR
// analogue of Plan. It mirrors Plan's guard order verbatim on the single client_fingerprint parameter
// (no members, no weights): validate -> advance the windowed/streak state -> clean -> rollback-latch ->
// hysteresis -> cooldown -> per-window budget -> a valid closed-vocab target; it emits a rotation only
// when every guard passes, otherwise a hold with a concrete reason. It REUSES spec.RotationLimits +
// spec.RotationState (the same policy + between-tick memory as transport rotation, threaded on a SEPARATE
// fp state instance so the two budgets never contend). The returned plan always satisfies
// spec.FingerprintPlan.Validate. Like Plan, it never reads disk or a clock — Now + State are injected.
//
// The "impaired" signal here is in.Faulted (the node's own same-listener A/B read the current preset DEAD
// while a stable Target read ALIVE, generation-gated) — the fingerprint-specific-vs-transport-wide
// discriminator lives upstream in the producer + the daemon fold, so a transport-wide block never reaches
// this planner as Faulted=true and the useless "rotate the preset when the transport is blocked" rotation
// is structurally unreachable.
func PlanFingerprint(in spec.FingerprintPlanInput) (spec.FingerprintPlan, error) {
	if err := in.Limits.Validate(); err != nil {
		return spec.FingerprintPlan{}, fmt.Errorf("fingerprint plan: %w", err)
	}
	if in.Current != "" && !spec.ValidClientFingerprint(in.Current) {
		return spec.FingerprintPlan{}, fmt.Errorf("fingerprint plan: current preset %q is not a closed-vocab value", in.Current)
	}

	// Advance the rate-limit window and the impaired streak (pure; from State + Now) — identical to Plan.
	// Only the WINDOWED counters reset on a window roll; LastRotateAt and HoldUntil carry forward (the
	// cooldown + the rollback latch span window boundaries).
	ns := in.State
	if in.State.WindowStart.IsZero() || in.Now.Sub(in.State.WindowStart) >= in.Limits.Window {
		ns.WindowStart = in.Now
		ns.RotationsInWindow = 0
		ns.RollbacksInWindow = 0
	}
	if in.Faulted {
		// Saturate at FlipConfirmations so a long hold/latch cannot grow the streak without bound.
		ns.ImpairedStreak = in.State.ImpairedStreak + 1
		if ns.ImpairedStreak > in.Limits.FlipConfirmations {
			ns.ImpairedStreak = in.Limits.FlipConfirmations
		}
	} else {
		ns.ImpairedStreak = 0
	}

	hold := func(reason spec.RotationReason, because string) (spec.FingerprintPlan, error) {
		p := spec.FingerprintPlan{
			Act: false, From: in.Current, Reason: reason, HeldBecause: because,
			NextState: ns, DecidedAt: in.Now,
		}
		if err := p.Validate(); err != nil {
			return spec.FingerprintPlan{}, fmt.Errorf("fingerprint plan (hold) invalid: %w", err)
		}
		return p, nil
	}

	// Guard 1 — no fingerprint-specific fault on the current preset.
	if !in.Faulted {
		return hold(spec.RotationReasonClean, "no fingerprint-specific fault on the current preset")
	}
	// Guard 2 — rollback latch / explicit hold window.
	if in.Now.Before(in.State.HoldUntil) {
		return hold(spec.RotationReasonRollbackHold, "in post-rollback hold latch")
	}
	// Guard 3 — hysteresis: the fingerprint-specific verdict must persist FlipConfirmations times.
	if ns.ImpairedStreak < in.Limits.FlipConfirmations {
		return hold(spec.RotationReasonStreakTooShort, "fingerprint-specific verdict has not persisted long enough")
	}
	// Guard 4 — cooldown since the last fingerprint rotation.
	if !in.State.LastRotateAt.IsZero() && in.Now.Sub(in.State.LastRotateAt) < in.Limits.MinInterval {
		return hold(spec.RotationReasonInCooldown, "within min-interval of the last fingerprint rotation")
	}
	// Guard 5 — per-window rotation budget (anti-beacon), on the SEPARATE fp window.
	if ns.RotationsInWindow >= in.Limits.MaxPerWindow {
		return hold(spec.RotationReasonNoBudget, "per-window fingerprint-rotation budget spent")
	}
	// Guard 6 — a valid closed-vocab target distinct from the current preset (never a randomiser). The
	// producer's A/B already found this Target ALIVE; the planner re-checks it is a real vocabulary member.
	if !spec.ValidClientFingerprint(in.Target) || in.Target == in.Current {
		return hold(spec.RotationReasonNoBetterCandidate, "no valid closed-vocab preset to rotate to")
	}

	// Act — rotate the client fingerprint to the A/B-chosen preset.
	ns.LastRotateAt = in.Now
	ns.RotationsInWindow++
	ns.ImpairedStreak = 0
	p := spec.FingerprintPlan{
		Act: true, From: in.Current, To: in.Target,
		Reason: spec.RotationReasonDegradedActive, NextState: ns, DecidedAt: in.Now,
	}
	if err := p.Validate(); err != nil {
		return spec.FingerprintPlan{}, fmt.Errorf("fingerprint plan (act) invalid: %w", err)
	}
	return p, nil
}
