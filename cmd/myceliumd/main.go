// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Command myceliumd is the Mycelium node control-agent daemon (the Go spine,
// ADR-0012). This Phase 0 skeleton exposes a PII-safe health/readiness endpoint
// and the spine version, and is the seat the Phase-2 network-state detector and
// auto-rotation loop will occupy later. It holds no policy/rotation logic yet,
// binds to loopback by default, and logs no PII.
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

	"github.com/mindicator/mycelium/internal/spec"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:9551",
		"health/readiness listen address (loopback by default; exposes no PII)")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]string{"status": "ok", "version": spec.Version})
	})
	mux.HandleFunc("/version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]string{"version": spec.Version})
	})

	srv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

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
