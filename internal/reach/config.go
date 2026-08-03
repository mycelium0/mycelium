// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package reach is the node-local reachability and per-transport health
// measurement layer (Phase 0 observability, ADR-0019). It periodically probes
// operator-configured anchors, records each outcome into a per-anchor sliding
// window, and projects that window onto the inert fast-class
// spec.TransportHealth shape. It is strictly local: it never classifies channel
// state, rotates a transport, actuates routing, assembles topology, or emits
// anything off the node. Those are Phase 2+ (see ../spec/network.go phase note
// and the ROADMAP). The component runs only when an operator supplies a config.
//
// Privacy boundary: a Target's Ref is the opaque label that appears in exposed
// output; its Address/ServerName are dial details that stay local and never
// appear in any snapshot. Probe anchors are operator state and are never
// committed to the repository; the repo ships only an example with allowlisted
// public-DNS anchors.
package reach

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
)

// ConfigVersion is the schema version of the reachability monitor config. It is
// the single source of truth for the config shape; call sites must not hardcode
// it elsewhere.
const ConfigVersion = 1

// Sentinel errors so callers and tests can branch with errors.Is.
var (
	// ErrEmptyField is returned when a structurally required field is empty.
	ErrEmptyField = errors.New("reach: a required field is empty")
	// ErrBadMethod is returned when a target's probe method is not a known member.
	ErrBadMethod = errors.New("reach: unknown probe method")
	// ErrNoTargets is returned when a config carries no targets.
	ErrNoTargets = errors.New("reach: config has no targets")
	// ErrDuplicateRef is returned when two targets share a ref.
	ErrDuplicateRef = errors.New("reach: duplicate target ref")
	// ErrBadInterval is returned when an interval, timeout, or window is not a
	// usable positive duration.
	ErrBadInterval = errors.New("reach: interval, timeout, and window must be > 0")
	// ErrUnsupportedVersion is returned when a config declares an unknown version.
	ErrUnsupportedVersion = errors.New("reach: unsupported config version")
)

// Method is how a single anchor is probed. Wire values are the lowercase strings
// below; never hardcode them at call sites.
type Method string

const (
	// MethodUnknown is the zero value and is never valid on the wire.
	MethodUnknown Method = ""
	// MethodTCP probes a bare TCP connect to the anchor address.
	MethodTCP Method = "tcp"
	// MethodTLS probes a TCP connect plus a verifying TLS handshake. It uses the
	// standard library only (crypto/tls); it never skips certificate
	// verification, so the operator must set ServerName (or an address whose host
	// matches the anchor's certificate). A MethodTCP/MethodTLS pair on the same
	// address distinguishes "TCP reached but TLS cut" from "TCP refused".
	MethodTLS Method = "tls"
	// MethodQUIC probes a UDP-only QUIC listener (hysteria2, tuic).
	//
	// It exists because MethodTCP is not merely unhelpful against a UDP listener —
	// it is CONFIRMABLY WRONG. Measured on all three live nodes: hysteria2 and
	// tuic reported 0 successes against 8 failures, permanently, because a TCP
	// connect to a UDP-only port is refused every time. That is not "no signal",
	// it is a loud false negative, so the assembler's zero-sample guard (which
	// deliberately refuses to read silence as a black-hole) never fires, the
	// tuner floors both weights, and the rotation planner marks the pair
	// ineligible. The two families most likely to survive a block became the two
	// the failover mechanism could never select — while a real client carried
	// HTTP 204 through both.
	//
	// The probe does NOT merely open a UDP socket: net.Dial on UDP is
	// connectionless and would succeed against a dead port, which is the same
	// defect mirrored. Instead it sends a QUIC long-header packet carrying a
	// version no implementation supports. RFC 9000 §6 requires a server to answer
	// that with Version Negotiation, so ALIVE is a datagram arriving — loud —
	// rather than an absence. A closed port yields ICMP port-unreachable, which a
	// connected UDP socket surfaces as ECONNREFUSED: DEAD is loud too.
	MethodQUIC Method = "quic"
)

// IsValid reports whether the method is one of the canonical members (the unset
// zero value is not valid).
func (m Method) IsValid() bool {
	switch m {
	case MethodTCP, MethodTLS, MethodQUIC:
		return true
	default:
		return false
	}
}

// Target is one reachability anchor. Ref is the opaque operator label that
// appears in the exposed snapshot. Address and ServerName are local dial details
// and must never appear in any exposed output.
type Target struct {
	Ref        string `json:"ref"`                   // opaque label (no address/SNI/location) — the only field shown
	Method     Method `json:"method"`                // "tcp" or "tls"
	Address    string `json:"address"`               // host:port to dial — LOCAL ONLY, never exposed
	ServerName string `json:"server_name,omitempty"` // optional TLS SNI — LOCAL ONLY, never exposed
	IntervalMS int    `json:"interval_ms"`           // probe interval, milliseconds
	TimeoutMS  int    `json:"timeout_ms"`            // per-probe timeout, milliseconds
}

// Config is the operator-supplied reachability monitor configuration.
type Config struct {
	Version  int      `json:"version"`   // schema version (ConfigVersion)
	WindowMS int      `json:"window_ms"` // sliding observation window per anchor, milliseconds
	Targets  []Target `json:"targets"`   // the anchors to probe
}

// Validate checks the config is structurally usable: a supported version, a
// positive window, at least one target, and for every target a non-empty unique
// ref, a known method, a dialable host:port address, and positive interval and
// timeout. It is pure.
func (c *Config) Validate() error {
	if c.Version != ConfigVersion {
		return fmt.Errorf("%w: got %d, want %d", ErrUnsupportedVersion, c.Version, ConfigVersion)
	}
	if c.WindowMS <= 0 {
		return fmt.Errorf("%w: window_ms is %d", ErrBadInterval, c.WindowMS)
	}
	if len(c.Targets) == 0 {
		return ErrNoTargets
	}
	seen := make(map[string]struct{}, len(c.Targets))
	for i := range c.Targets {
		t := &c.Targets[i]
		if t.Ref == "" {
			return fmt.Errorf("%w: target[%d].ref", ErrEmptyField, i)
		}
		if _, dup := seen[t.Ref]; dup {
			return fmt.Errorf("%w: %q", ErrDuplicateRef, t.Ref)
		}
		seen[t.Ref] = struct{}{}
		if !t.Method.IsValid() {
			return fmt.Errorf("%w: target %q method %q", ErrBadMethod, t.Ref, t.Method)
		}
		if t.Address == "" {
			return fmt.Errorf("%w: target %q address", ErrEmptyField, t.Ref)
		}
		if _, _, err := net.SplitHostPort(t.Address); err != nil {
			return fmt.Errorf("reach: target %q address %q is not host:port: %w", t.Ref, t.Address, err)
		}
		if t.IntervalMS <= 0 || t.TimeoutMS <= 0 {
			return fmt.Errorf("%w: target %q interval_ms=%d timeout_ms=%d", ErrBadInterval, t.Ref, t.IntervalMS, t.TimeoutMS)
		}
	}
	return nil
}

// LoadConfig reads and validates a reachability config from path. A missing or
// malformed file is an error (the caller, having been given a path, fails fast —
// ADR-0019). The file lives in a local, gitignored path by convention.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reach: read config %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("reach: parse config %s: %w", path, err)
	}
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("reach: invalid config %s: %w", path, err)
	}
	return &c, nil
}
