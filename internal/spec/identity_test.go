// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"errors"
	"regexp"
	"testing"
	"time"
)

var uuidV4Re = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func TestNewUUIDFormatV4(t *testing.T) {
	seen := make(map[string]struct{})
	for i := 0; i < 200; i++ {
		u, err := NewUUID()
		if err != nil {
			t.Fatalf("NewUUID: %v", err)
		}
		if !uuidV4Re.MatchString(u) {
			t.Fatalf("not an RFC 4122 v4 uuid: %q", u)
		}
		if _, dup := seen[u]; dup {
			t.Fatalf("duplicate uuid generated: %q", u)
		}
		seen[u] = struct{}{}
	}
}

func TestAddOKAndDuplicateName(t *testing.T) {
	s := NewIdentityState()
	now := time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)
	c, err := s.Add("alice", now)
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if c.Name != "alice" || c.ID == "" {
		t.Fatalf("unexpected client: %+v", c)
	}
	if c.Created != "2026-06-12T10:00:00Z" {
		t.Fatalf("created = %q, want RFC3339 UTC", c.Created)
	}
	if len(s.Clients) != 1 {
		t.Fatalf("len = %d, want 1", len(s.Clients))
	}
	if _, err := s.Add("alice", now); !errors.Is(err, ErrDuplicateName) {
		t.Fatalf("want ErrDuplicateName, got %v", err)
	}
}

func TestRevokeByNameAndID(t *testing.T) {
	s := NewIdentityState()
	now := time.Now()
	if _, err := s.Add("alice", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add("bob", now); err != nil {
		t.Fatal(err)
	}
	n, err := s.Revoke("alice")
	if err != nil || n != 1 {
		t.Fatalf("revoke by name: n=%d err=%v", n, err)
	}
	if s.HasName("alice") {
		t.Fatal("alice still present after revoke")
	}
	bobID := s.Clients[0].ID
	n, err = s.Revoke(bobID)
	if err != nil || n != 1 {
		t.Fatalf("revoke by id: n=%d err=%v", n, err)
	}
	if len(s.Clients) != 0 {
		t.Fatalf("len = %d, want 0", len(s.Clients))
	}
	if _, err := s.Revoke("nobody"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestValidateDuplicatesAndVersion(t *testing.T) {
	s := &IdentityState{Version: StateVersion, Clients: []Identity{
		{Name: "a", ID: "id1", Created: "t"},
		{Name: "a", ID: "id2", Created: "t"},
	}}
	if err := s.Validate(); !errors.Is(err, ErrDuplicateName) {
		t.Fatalf("want ErrDuplicateName, got %v", err)
	}
	s.Clients[1].Name = "b"
	s.Clients[1].ID = "id1"
	if err := s.Validate(); !errors.Is(err, ErrDuplicateID) {
		t.Fatalf("want ErrDuplicateID, got %v", err)
	}
	s.Clients[1].ID = "id2"
	if err := s.Validate(); err != nil {
		t.Fatalf("valid state errored: %v", err)
	}
	s.Version = 99
	if err := s.Validate(); err == nil {
		t.Fatal("want an unsupported-version error")
	}
}

func TestJSONRoundTrip(t *testing.T) {
	s := NewIdentityState()
	if _, err := s.Add("alice", time.Date(2026, 6, 12, 10, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	var got IdentityState
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Version != StateVersion || len(got.Clients) != 1 || got.Clients[0].Name != "alice" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}
