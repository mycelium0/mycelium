// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package identity

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/mindicator/mycelium/internal/spec"
)

func TestLoadMissingReturnsEmpty(t *testing.T) {
	p := filepath.Join(t.TempDir(), "nope", "identities.json")
	s, err := Load(p)
	if err != nil {
		t.Fatalf("Load missing: %v", err)
	}
	if s.Version != spec.StateVersion || len(s.Clients) != 0 {
		t.Fatalf("want a fresh empty state, got %+v", s)
	}
}

func TestSaveLoadRoundTripAndPerms(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state", "identities.json")
	s := spec.NewIdentityState()
	if _, err := s.Add("alice", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := Save(p, s); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.Clients) != 1 || got.Clients[0].Name != "alice" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("state perm = %o, want 600", perm)
	}
}

func TestSaveRejectsInvalidState(t *testing.T) {
	p := filepath.Join(t.TempDir(), "identities.json")
	bad := &spec.IdentityState{Version: spec.StateVersion, Clients: []spec.Identity{
		{Name: "a", ID: "x", Created: "t"},
		{Name: "a", ID: "y", Created: "t"}, // duplicate name
	}}
	if err := Save(p, bad); err == nil {
		t.Fatal("Save accepted an invalid (duplicate-name) state")
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("invalid Save must not create the target file; stat err = %v", err)
	}
}
