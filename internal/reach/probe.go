// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"errors"
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
	if t.Method == MethodQUIC {
		return probeQUIC(pctx, t, start)
	}
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

// quicProbeVersion is a QUIC version number no implementation supports, chosen so the only correct
// server behaviour is Version Negotiation. It is deliberately NOT one of the 0x?a?a?a?a values
// reserved to force version-negotiation exercise, because some stacks special-case those.
const quicProbeVersion uint32 = 0x1a2a3a4a

// quicInitialMinBytes is QUIC's minimum datagram size for a client Initial (RFC 9000 §14.1). A server
// is entitled to drop anything smaller, so an under-sized probe would read as a dead port.
const quicInitialMinBytes = 1200

// probeQUIC establishes liveness of a UDP-only QUIC listener without speaking the transport's own
// protocol or holding any credential.
//
// Both outcomes are POSITIVE observations, which is the whole point — see MethodQUIC:
//   - alive: the server answers the unknown version with a Version Negotiation datagram;
//   - dead: the port is closed, the kernel returns ICMP port-unreachable, and because the socket is
//     connected that surfaces as ECONNREFUSED on the read rather than as silence.
//
// A timeout is neither, and is reported as a failure exactly as a TCP timeout is: this probe's
// contract is "did the anchor answer", and an unanswered probe is an unreachable anchor from here.
func probeQUIC(ctx context.Context, t Target, start time.Time) Result {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "udp", t.Address)
	if err != nil {
		return Result{OK: false, Latency: time.Since(start), Err: err}
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(dl); err != nil {
			return Result{OK: false, Latency: time.Since(start), Err: err}
		}
	}

	dcid := make([]byte, 8)
	scid := make([]byte, 8)
	if _, err := rand.Read(dcid); err != nil {
		return Result{OK: false, Latency: time.Since(start), Err: err}
	}
	if _, err := rand.Read(scid); err != nil {
		return Result{OK: false, Latency: time.Since(start), Err: err}
	}

	pkt := make([]byte, 0, quicInitialMinBytes)
	pkt = append(pkt, 0xc0) // long header, fixed bit set
	var ver [4]byte
	binary.BigEndian.PutUint32(ver[:], quicProbeVersion)
	pkt = append(pkt, ver[:]...)
	pkt = append(pkt, byte(len(dcid)))
	pkt = append(pkt, dcid...)
	pkt = append(pkt, byte(len(scid)))
	pkt = append(pkt, scid...)
	for len(pkt) < quicInitialMinBytes {
		pkt = append(pkt, 0)
	}

	if _, err := conn.Write(pkt); err != nil {
		return Result{OK: false, Latency: time.Since(start), Err: err}
	}
	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		return Result{OK: false, Latency: time.Since(start), Err: err}
	}
	// Any datagram at all proves something is bound and speaking; a well-formed Version Negotiation
	// (long header, version field zero) proves it is a QUIC server specifically.
	if n < 5 {
		return Result{OK: false, Latency: time.Since(start), Err: errQUICShortReply}
	}
	return Result{OK: true, Latency: time.Since(start)}
}

// errQUICShortReply marks a reply too small to be any QUIC packet — something answered, but not a
// QUIC server, so the anchor is not the listener we asked about.
var errQUICShortReply = errors.New("reach: quic probe: reply too short to be a QUIC packet")
