// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"crypto/rand"
	"errors"
	"fmt"
	"time"
)

// StateVersion is the on-disk schema version of the identity state file. It
// mirrors the shell tool's shape: {"version":1,"clients":[{name,id,created}]}.
const StateVersion = 1

// Identity is a single issued client credential.
type Identity struct {
	Name    string `json:"name"`
	ID      string `json:"id"`      // UUID (RFC 4122)
	Created string `json:"created"` // RFC 3339, UTC
}

// IdentityState is the full client-identity state, persisted as JSON.
type IdentityState struct {
	Version int        `json:"version"`
	Clients []Identity `json:"clients"`
}

// Sentinel errors so callers (and tests) can branch with errors.Is.
var (
	// ErrDuplicateName is returned when adding a client whose name already exists.
	ErrDuplicateName = errors.New("a client with that name already exists")
	// ErrDuplicateID is returned on the (astronomically unlikely) UUID collision.
	ErrDuplicateID = errors.New("generated UUID already present")
	// ErrNotFound is returned when no client matches a name or id selector.
	ErrNotFound = errors.New("no client matches the given name or id")
)

// NewIdentityState returns an empty state at the current schema version.
func NewIdentityState() *IdentityState {
	return &IdentityState{Version: StateVersion, Clients: []Identity{}}
}

// Validate checks structural invariants: a known version and no duplicate names
// or ids (a client is uniquely keyed by both, matching the shell tool).
func (s *IdentityState) Validate() error {
	if s.Version != StateVersion {
		return fmt.Errorf("unsupported state version %d (want %d)", s.Version, StateVersion)
	}
	names := make(map[string]struct{}, len(s.Clients))
	ids := make(map[string]struct{}, len(s.Clients))
	for i, c := range s.Clients {
		if c.Name == "" {
			return fmt.Errorf("client at index %d has an empty name", i)
		}
		if c.ID == "" {
			return fmt.Errorf("client %q has an empty id", c.Name)
		}
		if _, dup := names[c.Name]; dup {
			return fmt.Errorf("%w: %q", ErrDuplicateName, c.Name)
		}
		if _, dup := ids[c.ID]; dup {
			return fmt.Errorf("%w: %q", ErrDuplicateID, c.ID)
		}
		names[c.Name] = struct{}{}
		ids[c.ID] = struct{}{}
	}
	return nil
}

// HasName reports whether a client with the given name exists.
func (s *IdentityState) HasName(name string) bool {
	for _, c := range s.Clients {
		if c.Name == name {
			return true
		}
	}
	return false
}

// HasID reports whether a client with the given id exists.
func (s *IdentityState) HasID(id string) bool {
	for _, c := range s.Clients {
		if c.ID == id {
			return true
		}
	}
	return false
}

// Add issues a new client with the given name, a freshly generated UUID, and an
// RFC 3339 creation timestamp (now, in UTC). It mirrors the shell tool: a
// duplicate name is rejected, and a UUID collision is an error (retry).
func (s *IdentityState) Add(name string, now time.Time) (Identity, error) {
	if name == "" {
		return Identity{}, errors.New("client name is required")
	}
	if s.HasName(name) {
		return Identity{}, fmt.Errorf("%w: %q", ErrDuplicateName, name)
	}
	id, err := NewUUID()
	if err != nil {
		return Identity{}, fmt.Errorf("generate uuid: %w", err)
	}
	if s.HasID(id) {
		return Identity{}, fmt.Errorf("%w: %q", ErrDuplicateID, id)
	}
	c := Identity{Name: name, ID: id, Created: now.UTC().Format(time.RFC3339)}
	s.Clients = append(s.Clients, c)
	return c, nil
}

// Revoke removes every client whose name OR id equals sel and returns the count
// removed. Removing nothing yields ErrNotFound.
func (s *IdentityState) Revoke(sel string) (int, error) {
	if sel == "" {
		return 0, errors.New("a name or id selector is required")
	}
	kept := make([]Identity, 0, len(s.Clients))
	removed := 0
	for _, c := range s.Clients {
		if c.Name == sel || c.ID == sel {
			removed++
			continue
		}
		kept = append(kept, c)
	}
	if removed == 0 {
		return 0, fmt.Errorf("%w: %q", ErrNotFound, sel)
	}
	s.Clients = kept
	return removed, nil
}

// NewUUID returns a random RFC 4122 version-4 UUID. The 122 random bits come from
// the operating-system CSPRNG (crypto/rand) — the same audited entropy source
// class as `openssl rand`. This formats those bytes; it does not implement any
// cryptographic primitive (ADR-0002).
func NewUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}
