// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"context"
	"net"
	"testing"
	"time"
)

// TestProbeQUICThreeWay pins the property that made MethodQUIC necessary: BOTH verdicts must come
// from an observation, never from an absence.
//
// The defect this replaces was a TCP anchor pointed at a UDP-only listener, which reported a
// permanent, confident FALSE NEGATIVE (0 successes / 8 failures on every live node) for hysteria2 and
// tuic. The mirror-image mistake is just as easy: net.Dial on UDP is connectionless and succeeds
// against a dead port, so a probe that merely dialled would report a permanent false POSITIVE. The
// closed-port row below is what forbids that implementation.
func TestProbeQUICThreeWay(t *testing.T) {
	// A responder standing in for a QUIC server: anything bound that answers a datagram.
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer pc.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			if n < 5 {
				continue
			}
			// A Version Negotiation packet: long header, version field zero, echoed CIDs.
			_, _ = pc.WriteTo([]byte{0xc0, 0, 0, 0, 0, 0, 0, 0, 0}, addr)
		}
	}()

	// A closed port: bind one, learn its address, then release it.
	tmp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen tmp: %v", err)
	}
	closedAddr := tmp.LocalAddr().String()
	tmp.Close()

	p := NewDialProber()
	ctx := context.Background()

	t.Run("a listener that answers is ALIVE", func(t *testing.T) {
		got := p.Probe(ctx, Target{Ref: "live", Method: MethodQUIC, Address: pc.LocalAddr().String(), TimeoutMS: 2000})
		if !got.OK {
			t.Fatalf("a bound, answering UDP listener must probe OK; got err=%v", got.Err)
		}
	})

	t.Run("a closed port is DEAD, not silently alive", func(t *testing.T) {
		got := p.Probe(ctx, Target{Ref: "dead", Method: MethodQUIC, Address: closedAddr, TimeoutMS: 2000})
		if got.OK {
			t.Fatal("a CLOSED udp port probed OK. net.Dial on UDP is connectionless and never fails by " +
				"itself, so an implementation that only dials reports every dead QUIC listener as alive — " +
				"the same class of confident lie as the TCP-anchor-on-a-UDP-port defect this method replaces, " +
				"only inverted. The probe must require an actual reply.")
		}
	})

	t.Run("a bound port that never answers is not counted alive", func(t *testing.T) {
		mute, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen mute: %v", err)
		}
		defer mute.Close()
		start := time.Now()
		got := p.Probe(ctx, Target{Ref: "mute", Method: MethodQUIC, Address: mute.LocalAddr().String(), TimeoutMS: 300})
		if got.OK {
			t.Fatal("a bound UDP socket that never replies probed OK — liveness must come from a reply, " +
				"not from the absence of an error")
		}
		if time.Since(start) > 3*time.Second {
			t.Fatalf("probe did not honour its timeout (took %s)", time.Since(start))
		}
	})
}

// TestMethodQUICIsCanonical guards the generator/consumer seam: control/lib/nb_measure.sh emits
// method:"quic" for the quic-udp class, and a Method the Go side rejects would fail the daemon closed
// at config load — visible only on a node, at the worst moment.
func TestMethodQUICIsCanonical(t *testing.T) {
	if !MethodQUIC.IsValid() {
		t.Fatal("MethodQUIC must be canonical: the shell reach-config generator emits it for every quic-udp member")
	}
	if MethodQUIC != "quic" {
		t.Fatalf("wire value drifted to %q; nb_measure.sh emits the literal \"quic\"", MethodQUIC)
	}
}
