// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Command myceliumd is the Mycelium node control-agent daemon (the Go spine,
// ADR-0012). This Phase 0 build exposes a PII-safe health/readiness endpoint and
// the spine version, and — when the operator supplies a config — runs the
// node-local reachability/health monitor (ADR-0019) and serves its redacted
// snapshot. It binds to loopback by default and logs no PII. Channel-state
// classification, auto-rotation, and routing remain Phase 2 and are not present
// here; this daemon is the seat they will occupy later.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mindicator/mycelium/internal/reach"
	"github.com/mindicator/mycelium/internal/spec"
)

// reachView is the redacted per-anchor health shown on /reachability: the opaque
// operator ref plus counters and ratio over the window. It carries no address,
// SNI, destination, identity, or location.
type reachView struct {
	Ref          string    `json:"ref"`
	Successes    int       `json:"successes"`
	Failures     int       `json:"failures"`
	SuccessRatio float64   `json:"success_ratio"`
	WindowStart  time.Time `json:"window_start"`
	WindowEnd    time.Time `json:"window_end"`
}

func main() {
	listen := flag.String("listen", "127.0.0.1:9551",
		"health/readiness listen address (loopback by default; exposes no PII)")
	reachConfig := flag.String("reachability-config", "",
		"path to a node-local reachability monitor config (ADR-0019); empty disables the monitor")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]string{"status": "ok", "version": spec.Version})
	})
	mux.HandleFunc("/version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]string{"version": spec.Version})
	})

	// Node-local reachability monitor (ADR-0019). It runs only when the operator
	// supplies a config; an invalid config is a fail-fast error, not a silent
	// skip. It stays strictly local: it classifies no channel state, rotates no
	// transport, actuates no routing, and emits nothing off the node.
	if *reachConfig != "" {
		cfg, err := reach.LoadConfig(*reachConfig)
		if err != nil {
			log.Fatalf("myceliumd: reachability config: %v", err)
		}
		mon, err := reach.New(*cfg, nil)
		if err != nil {
			log.Fatalf("myceliumd: reachability monitor: %v", err)
		}
		go func() {
			if err := mon.Run(ctx); err != nil && err != context.Canceled {
				log.Printf("myceliumd: reachability monitor stopped: %v", err)
			}
		}()
		mux.HandleFunc("/reachability", func(w http.ResponseWriter, _ *http.Request) {
			snap := mon.Snapshot()
			views := make([]reachView, 0, len(snap))
			for _, h := range snap {
				views = append(views, reachView{
					Ref:          h.TransportRef,
					Successes:    h.Successes,
					Failures:     h.Failures,
					SuccessRatio: h.SuccessRatio(),
					WindowStart:  h.WindowStart,
					WindowEnd:    h.WindowEnd,
				})
			}
			writeJSON(w, map[string]any{"version": spec.Version, "anchors": views})
		})
		log.Printf("myceliumd: reachability monitor active (%d anchors)", len(cfg.Targets))
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("myceliumd %s: health endpoint on %s", spec.Version, *listen)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		log.Printf("myceliumd: server error: %v", err)
		os.Exit(1)
	case <-ctx.Done():
		log.Print("myceliumd: shutdown requested")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("myceliumd: graceful shutdown failed: %v", err)
		os.Exit(1)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
