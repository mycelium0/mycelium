// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package main

import (
	"context"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// sdNotify sends an sd_notify(3) datagram to systemd's NOTIFY_SOCKET if it is set, and is a no-op
// otherwise (so the daemon runs identically outside systemd). It is zero-dependency, best-effort
// liveness — a single datagram on the unix socket systemd provides — used for Type=notify readiness
// (READY=1) and the watchdog ping. Errors are ignored: liveness reporting must never affect the
// daemon's own behaviour. This reuses systemd's service-liveness contract rather than hand-rolling a
// supervisor (ADR-0031 compose-not-reinvent).
func sdNotify(state string) {
	sock := os.Getenv("NOTIFY_SOCKET")
	if sock == "" {
		return
	}
	// An abstract namespace socket is given as "@…"; the kernel address is a leading NUL.
	if strings.HasPrefix(sock, "@") {
		sock = "\x00" + sock[1:]
	}
	c, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: sock, Net: "unixgram"})
	if err != nil {
		return
	}
	defer c.Close()
	_, _ = c.Write([]byte(state))
}

// runWatchdog pings systemd's hardware-watchdog contract (WatchdogSec, surfaced as WATCHDOG_USEC) at
// half its interval until ctx is cancelled, so systemd restarts a hung daemon. It is a no-op when the
// watchdog is not configured. Reuses systemd's WatchdogSec instead of a hand-rolled liveness loop.
func runWatchdog(ctx context.Context) {
	usec, err := strconv.Atoi(os.Getenv("WATCHDOG_USEC"))
	if err != nil || usec <= 0 {
		return
	}
	interval := time.Duration(usec/2) * time.Microsecond
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			sdNotify("WATCHDOG=1")
		}
	}
}
