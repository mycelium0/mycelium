// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "testing"

func TestFingerprintPlanValidate(t *testing.T) {
	valid := func(p FingerprintPlan) { //nolint (helper)
		t.Helper()
		if err := p.Validate(); err != nil {
			t.Errorf("want valid, got %v (plan %+v)", err, p)
		}
	}
	invalid := func(name string, p FingerprintPlan) {
		t.Helper()
		if err := p.Validate(); err == nil {
			t.Errorf("%s: want invalid, got nil (plan %+v)", name, p)
		}
	}

	// A well-formed act (closed-vocab target != current, the acting reason).
	valid(FingerprintPlan{Act: true, From: "chrome", To: "firefox", Reason: RotationReasonDegradedActive})
	// A well-formed hold (no target, a stated cause, any valid reason).
	valid(FingerprintPlan{Act: false, From: "chrome", Reason: RotationReasonClean, HeldBecause: "no fault"})

	invalid("act off-vocab target", FingerprintPlan{Act: true, From: "chrome", To: "bogus", Reason: RotationReasonDegradedActive})
	invalid("act randomiser target", FingerprintPlan{Act: true, From: "chrome", To: "randomized", Reason: RotationReasonDegradedActive})
	invalid("act target == current", FingerprintPlan{Act: true, From: "chrome", To: "chrome", Reason: RotationReasonDegradedActive})
	invalid("act wrong reason", FingerprintPlan{Act: true, From: "chrome", To: "firefox", Reason: RotationReasonClean})
	invalid("hold carries a target", FingerprintPlan{Act: false, From: "chrome", To: "firefox", Reason: RotationReasonClean, HeldBecause: "x"})
	invalid("hold without a cause", FingerprintPlan{Act: false, From: "chrome", Reason: RotationReasonClean})
	invalid("unknown reason", FingerprintPlan{Act: false, From: "chrome", Reason: RotationReason("made-up"), HeldBecause: "x"})
}
