// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package reach

import (
	"context"
	"net"
	"testing"
)

// acceptAndCloseListener returns a TCP listener that accepts connections and
// closes them immediately, plus a cleanup. A bare TCP connect to it succeeds; a
// TLS handshake against it fails (it speaks no TLS).
func acceptAndCloseListener(t *testing.T) (addr string, stop func()) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	return l.Addr().String(), func() { _ = l.Close() }
}

// freeAddr returns an address that nothing listens on (a connect there refuses).
func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	return addr
}

func TestDialProberTCPSuccess(t *testing.T) {
	addr, stop := acceptAndCloseListener(t)
	defer stop()
	res := NewDialProber().Probe(context.Background(), Target{
		Ref: "ok", Method: MethodTCP, Address: addr, TimeoutMS: 2000,
	})
	if !res.OK || res.Err != nil {
		t.Fatalf("want TCP connect success, got OK=%v err=%v", res.OK, res.Err)
	}
}

func TestDialProberTCPRefused(t *testing.T) {
	res := NewDialProber().Probe(context.Background(), Target{
		Ref: "refused", Method: MethodTCP, Address: freeAddr(t), TimeoutMS: 2000,
	})
	if res.OK || res.Err == nil {
		t.Fatalf("want TCP connect failure, got OK=%v err=%v", res.OK, res.Err)
	}
}

func TestDialProberTLSHandshakeFails(t *testing.T) {
	// A plain TCP listener does not speak TLS, so the handshake must fail closed.
	addr, stop := acceptAndCloseListener(t)
	defer stop()
	res := NewDialProber().Probe(context.Background(), Target{
		Ref: "tls", Method: MethodTLS, Address: addr, ServerName: "example.com", TimeoutMS: 2000,
	})
	if res.OK {
		t.Fatal("want TLS handshake failure against a plain listener, got OK=true")
	}
}

func TestDialProberCancelledContext(t *testing.T) {
	addr, stop := acceptAndCloseListener(t)
	defer stop()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := NewDialProber().Probe(ctx, Target{
		Ref: "cancelled", Method: MethodTCP, Address: addr, TimeoutMS: 2000,
	})
	if res.OK {
		t.Fatal("want failure with a cancelled context, got OK=true")
	}
}
