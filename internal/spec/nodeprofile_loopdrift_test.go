// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
)

func TestLoopDrift(t *testing.T) {
	all := LoopsConfig{Update: true, Rotate: true, Measure: true}
	none := LoopsConfig{}

	for _, tc := range []struct {
		name                string
		requested, actual   LoopsConfig
		wantCount           int
		wantMentions        []string
	}{
		{"agreement, nothing running", none, none, 0, nil},
		{"agreement, everything running", all, all, 0, nil},
		// the live state on m1/m2/m4: the profile says nothing runs, all three run
		{"profile silent while all three run", none, all, 3, []string{"update", "rotate", "measure"}},
		{"profile requests what is not armed", all, none, 3, []string{"update", "rotate", "measure"}},
		{"one loop drifts", none, LoopsConfig{Rotate: true}, 1, []string{"rotate"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := LoopDrift(tc.requested, tc.actual)
			if len(got) != tc.wantCount {
				t.Fatalf("drift lines = %d, want %d: %v", len(got), tc.wantCount, got)
			}
			joined := strings.Join(got, " | ")
			for _, m := range tc.wantMentions {
				if !strings.Contains(joined, m) {
					t.Errorf("drift does not mention %q: %s", m, joined)
				}
			}
		})
	}
}

// A drift report that cannot distinguish the two directions is not useful: "requested but not armed" is
// an operator's pending intent, "armed but not requested" is a file telling a stranger something untrue.
func TestLoopDriftDistinguishesDirection(t *testing.T) {
	notArmed := LoopDrift(LoopsConfig{Rotate: true}, LoopsConfig{})
	notDeclared := LoopDrift(LoopsConfig{}, LoopsConfig{Rotate: true})
	if len(notArmed) != 1 || len(notDeclared) != 1 {
		t.Fatalf("expected one line each, got %d and %d", len(notArmed), len(notDeclared))
	}
	if notArmed[0] == notDeclared[0] {
		t.Fatal("both directions produce the same message — an operator cannot tell a pending intent from a stale declaration")
	}
}
