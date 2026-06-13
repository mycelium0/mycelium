// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// goodConfig is a minimal valid config reused across the table tests.
func goodConfig() Config {
	return Config{
		Version:  ConfigVersion,
		WindowMS: 60000,
		Targets: []Target{
			{Ref: "anchor-a", Method: MethodTCP, Address: "1.1.1.1:443", IntervalMS: 5000, TimeoutMS: 2000},
			{Ref: "anchor-b", Method: MethodTLS, Address: "8.8.8.8:443", ServerName: "dns.google", IntervalMS: 5000, TimeoutMS: 2000},
		},
	}
}

func TestMethodIsValid(t *testing.T) {
	if MethodUnknown.IsValid() || !MethodTCP.IsValid() || !MethodTLS.IsValid() {
		t.Fatal("Method.IsValid mismatch")
	}
}

func TestConfigValidate(t *testing.T) {
	mutate := func(f func(c *Config)) Config {
		c := goodConfig()
		f(&c)
		return c
	}
	cases := []struct {
		name    string
		cfg     Config
		wantErr error // nil sentinel means "expect success"; a special marker handled below
		wantOK  bool
	}{
		{"ok", goodConfig(), nil, true},
		{"bad version", mutate(func(c *Config) { c.Version = 99 }), ErrUnsupportedVersion, false},
		{"zero window", mutate(func(c *Config) { c.WindowMS = 0 }), ErrBadInterval, false},
		{"no targets", mutate(func(c *Config) { c.Targets = nil }), ErrNoTargets, false},
		{"empty ref", mutate(func(c *Config) { c.Targets[0].Ref = "" }), ErrEmptyField, false},
		{"dup ref", mutate(func(c *Config) { c.Targets[1].Ref = c.Targets[0].Ref }), ErrDuplicateRef, false},
		{"bad method", mutate(func(c *Config) { c.Targets[0].Method = "icmp" }), ErrBadMethod, false},
		{"empty address", mutate(func(c *Config) { c.Targets[0].Address = "" }), ErrEmptyField, false},
		{"zero interval", mutate(func(c *Config) { c.Targets[0].IntervalMS = 0 }), ErrBadInterval, false},
		{"zero timeout", mutate(func(c *Config) { c.Targets[0].TimeoutMS = 0 }), ErrBadInterval, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.cfg.Validate()
			if tc.wantOK {
				if err != nil {
					t.Fatalf("want success, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatal("want an error, got nil")
			}
			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Fatalf("want %v, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestConfigValidateBadAddress(t *testing.T) {
	c := goodConfig()
	c.Targets[0].Address = "1.1.1.1" // missing port
	if err := c.Validate(); err == nil {
		t.Fatal("want an error for an address with no port, got nil")
	}
}

func TestLoadConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "reach.json")
	const data = `{
  "version": 1,
  "window_ms": 60000,
  "targets": [
    {"ref": "anchor-a", "method": "tcp", "address": "1.1.1.1:443", "interval_ms": 5000, "timeout_ms": 2000}
  ]
}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Version != ConfigVersion || len(cfg.Targets) != 1 || cfg.Targets[0].Ref != "anchor-a" {
		t.Fatalf("loaded config mismatch: %+v", cfg)
	}
}

func TestLoadConfigMissingFile(t *testing.T) {
	if _, err := LoadConfig(filepath.Join(t.TempDir(), "does-not-exist.json")); err == nil {
		t.Fatal("want an error for a missing config file, got nil")
	}
}

func TestLoadConfigRejectsInvalid(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.json")
	// Valid JSON, but no targets — must be rejected by Validate, not silently loaded.
	if err := os.WriteFile(path, []byte(`{"version":1,"window_ms":1000,"targets":[]}`), 0o600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	if _, err := LoadConfig(path); !errors.Is(err, ErrNoTargets) {
		t.Fatalf("want ErrNoTargets, got %v", err)
	}
}
