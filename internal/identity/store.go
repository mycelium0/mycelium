// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package identity persists Mycelium client-identity state to a JSON file with
// 0600 permissions and atomic writes. The data model and pure operations live in
// internal/spec (ADR-0012); this package is the thin file-I/O layer the CLI uses.
package identity

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mindicator/mycelium/internal/spec"
)

// Load reads the identity state from path. A missing file yields a fresh empty
// state (first run), not an error — matching the shell tool's state-init.
func Load(path string) (*spec.IdentityState, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return spec.NewIdentityState(), nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state %s: %w", path, err)
	}
	var s spec.IdentityState
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("parse state %s: %w", path, err)
	}
	if s.Clients == nil {
		s.Clients = []spec.Identity{}
	}
	if err := s.Validate(); err != nil {
		return nil, fmt.Errorf("invalid state %s: %w", path, err)
	}
	return &s, nil
}

// Save writes the state to path atomically (temp file + rename) with 0600
// permissions, creating the parent directory (0700) if needed. State files live
// in gitignored paths by project convention.
func Save(path string, s *spec.IdentityState) error {
	if err := s.Validate(); err != nil {
		return fmt.Errorf("refusing to save invalid state: %w", err)
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create state dir %s: %w", dir, err)
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("encode state: %w", err)
	}
	data = append(data, '\n')

	tmp, err := os.CreateTemp(dir, ".identities-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp state: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once the rename below succeeds

	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("chmod temp state: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp state: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp state: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("commit state %s: %w", path, err)
	}
	return nil
}
