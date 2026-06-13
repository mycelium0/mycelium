// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"context"
	"crypto/tls"
	"net"
	"time"
)

// Result is the outcome of a single probe. Err is for local logging only and is
// never placed in any exposed snapshot.
type Result struct {
	OK      bool
	Latency time.Duration
	Err     error
}

// Prober runs a single reachability probe against a target. It is the one
// network-facing seam of this package and is injected into Monitor so the loop
// is testable with a fake.
type Prober interface {
	Probe(ctx context.Context, t Target) Result
}

// dialProber is the default Prober. For MethodTCP it performs a TCP connect; for
// MethodTLS it additionally completes a verifying TLS handshake. It uses only the
// standard library (net, crypto/tls) and never disables certificate verification
// (no insecure-skip-verify — ADR-0002, ADR-0019). Each probe is bounded by the
// target's timeout.
type dialProber struct{}

// NewDialProber returns the default network Prober.
func NewDialProber() Prober { return dialProber{} }

// Probe dials the target within its timeout and reports success and latency. Any
// network or handshake failure is a recorded probe failure, never a panic.
func (dialProber) Probe(ctx context.Context, t Target) Result {
	timeout := time.Duration(t.TimeoutMS) * time.Millisecond
	pctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	start := time.Now()
	var d net.Dialer
	conn, err := d.DialContext(pctx, "tcp", t.Address)
	if err != nil {
		return Result{OK: false, Latency: time.Since(start), Err: err}
	}
	defer conn.Close()

	if t.Method == MethodTLS {
		serverName := t.ServerName
		if serverName == "" {
			if host, _, splitErr := net.SplitHostPort(t.Address); splitErr == nil {
				serverName = host
			}
		}
		tconn := tls.Client(conn, &tls.Config{
			ServerName: serverName,
			MinVersion: tls.VersionTLS12,
		})
		if err := tconn.HandshakeContext(pctx); err != nil {
			return Result{OK: false, Latency: time.Since(start), Err: err}
		}
	}
	return Result{OK: true, Latency: time.Since(start)}
}
