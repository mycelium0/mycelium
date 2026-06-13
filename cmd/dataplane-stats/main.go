// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Command dataplane-stats is the Mycelium node-local data-plane stats exporter (Phase-0
// observability — RP-0002 W4, ADR-0012). It reads the sing-box clash_api on loopback and re-exposes
// ONLY aggregate counters (total bytes up/down, active connection COUNT) in Prometheus text format
// on loopback 127.0.0.1:9550, where the central Prometheus scrapes it over an SSH tunnel.
//
// PRIVACY (THREAT-MODEL: telemetry must never become a user trail). The clash_api /connections
// response lists every live connection with its destination, host, SNI, and IPs. This exporter
// NEVER decodes or exposes that per-connection metadata: it reads only the two top-level byte totals
// and the LENGTH of the connection list. It emits NO labels at all, so there is no PII vector. It is
// pure measurement: it classifies nothing, rotates nothing, and acts on nothing (that is Phase 2).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Metric names — the COMPLETE, allowlisted set this exporter may emit (the no_dataplane_pii gate
// asserts nothing outside this set is exported, and that none carries a per-connection label).
const (
	metricReachable   = "mycelium_dataplane_clash_api_reachable"
	metricUploadBytes = "mycelium_dataplane_upload_bytes_total"
	metricDownBytes   = "mycelium_dataplane_download_bytes_total"
	metricActiveConns = "mycelium_dataplane_active_connections"
	scrapeTimeout     = 5 * time.Second
	maxClashBodyBytes = 8 << 20 // bound the clash_api response we read (8 MiB)
)

// clashConnections is the MINIMAL projection of the clash_api /connections response. Connections is
// []json.RawMessage on purpose: the elements are COUNTED but their contents (destination/host/SNI/IP)
// are never unmarshalled, logged, or exported — the per-connection metadata never leaves clash_api.
type clashConnections struct {
	DownloadTotal int64             `json:"downloadTotal"`
	UploadTotal   int64             `json:"uploadTotal"`
	Connections   []json.RawMessage `json:"connections"`
}

// collect queries the clash_api /connections endpoint and returns the aggregate projection plus
// whether the read+parse succeeded. Any error (unreachable, non-200, bad JSON) yields ok=false; the
// error detail is for local logging only and is never placed in exported output.
func collect(clashAPI, secret string) (clashConnections, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), scrapeTimeout)
	defer cancel()
	url := strings.TrimRight(clashAPI, "/") + "/connections"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return clashConnections{}, false
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return clashConnections{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return clashConnections{}, false
	}
	var c clashConnections
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxClashBodyBytes)).Decode(&c); err != nil {
		return clashConnections{}, false
	}
	return c, true
}

// render produces the Prometheus exposition text for one scrape. It is pure given (clashAPI, secret)
// and the remote response, so it is directly unit-testable. It emits only the allowlisted, label-free
// aggregate metrics.
func render(clashAPI, secret string) string {
	c, ok := collect(clashAPI, secret)
	var b strings.Builder
	gauge(&b, metricReachable,
		"1 if the sing-box clash_api was reachable and parsed this scrape, else 0.", boolFloat(ok))
	if ok {
		counter(&b, metricUploadBytes,
			"Total bytes uploaded (client->internet) since the data-plane process started.", float64(c.UploadTotal))
		counter(&b, metricDownBytes,
			"Total bytes downloaded (internet->client) since the data-plane process started.", float64(c.DownloadTotal))
		gauge(&b, metricActiveConns,
			"Number of currently active data-plane connections (count only; no per-connection detail).", float64(len(c.Connections)))
	}
	return b.String()
}

func gauge(b *strings.Builder, name, help string, v float64)   { emit(b, name, "gauge", help, v) }
func counter(b *strings.Builder, name, help string, v float64) { emit(b, name, "counter", help, v) }

// emit writes one HELP/TYPE/value triple. No labels are ever attached — the only metadata is the
// metric name itself, which is a fixed compile-time constant.
func emit(b *strings.Builder, name, typ, help string, v float64) {
	fmt.Fprintf(b, "# HELP %s %s\n", name, help)
	fmt.Fprintf(b, "# TYPE %s %s\n", name, typ)
	fmt.Fprintf(b, "%s %g\n", name, v)
}

func boolFloat(ok bool) float64 {
	if ok {
		return 1
	}
	return 0
}

func main() {
	listen := flag.String("listen", "127.0.0.1:9550",
		"metrics listen address (loopback by default; exposes only aggregate, label-free counters)")
	clashAPI := flag.String("clash-api", "http://127.0.0.1:9090",
		"sing-box clash_api base URL (loopback) to read aggregate counters from")
	secretFile := flag.String("clash-secret-file", "",
		"optional path to a file holding the clash_api secret (sent as a Bearer token)")
	flag.Parse()

	secret := ""
	if *secretFile != "" {
		data, err := os.ReadFile(*secretFile)
		if err != nil {
			log.Printf("dataplane-stats: could not read clash secret file %q: %v (continuing without a token)", *secretFile, err)
		} else {
			secret = strings.TrimSpace(string(data))
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = io.WriteString(w, render(*clashAPI, secret))
	})

	srv := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Printf("dataplane-stats: /metrics on %s (reads clash_api at %s; aggregate counters only, no PII)", *listen, *clashAPI)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		log.Printf("dataplane-stats: server error: %v", err)
		os.Exit(1)
	case <-ctx.Done():
		log.Print("dataplane-stats: shutdown requested")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("dataplane-stats: graceful shutdown failed: %v", err)
		os.Exit(1)
	}
}
