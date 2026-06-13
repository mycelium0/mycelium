// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A clash_api /connections response deliberately STUFFED with per-connection PII — destinations,
// hosts, SNIs, an identity-shaped chain, and client/destination IPs. The exporter must surface the
// aggregates and NONE of these strings.
const piiConnectionsJSON = `{
  "downloadTotal": 9999,
  "uploadTotal": 4242,
  "connections": [
    {"id":"c1","metadata":{"network":"tcp","destinationIP":"203.0.113.77","sourceIP":"100.64.0.5","host":"secret-destination.example","sniffHost":"sni-secret.example"},"chains":["user-uuid-7e6ce5cd-dead-beef-0000"],"rulePayload":"geosite-secret"},
    {"id":"c2","metadata":{"network":"udp","destinationIP":"198.51.100.9","host":"another-private-dest.example"}}
  ],
  "memory": 123456
}`

// piiNeedles are strings that MUST NOT appear anywhere in the exported metrics.
var piiNeedles = []string{
	"203.0.113.77", "198.51.100.9", "100.64.0.5",
	"secret-destination.example", "another-private-dest.example", "sni-secret.example",
	"user-uuid-7e6ce5cd-dead-beef-0000", "geosite-secret",
	"metadata", "destinationIP", "sourceIP", "sniffHost", "chains", "rulePayload",
}

func fakeClash(t *testing.T, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/connections" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
}

func TestRenderEmitsAggregatesAndNoPII(t *testing.T) {
	ts := fakeClash(t, piiConnectionsJSON)
	defer ts.Close()

	out := render(ts.URL, "")

	for _, want := range []string{
		"mycelium_dataplane_clash_api_reachable 1",
		"mycelium_dataplane_upload_bytes_total 4242",
		"mycelium_dataplane_download_bytes_total 9999",
		"mycelium_dataplane_active_connections 2",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("metrics output missing %q\n--- output ---\n%s", want, out)
		}
	}
	for _, bad := range piiNeedles {
		if strings.Contains(out, bad) {
			t.Fatalf("PII LEAK: metrics output contains %q\n--- output ---\n%s", bad, out)
		}
	}
	// The output must carry NO Prometheus labels at all (no '{' on a metric line).
	for _, line := range strings.Split(out, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.Contains(line, "{") {
			t.Fatalf("metric line carries a label (forbidden): %q", line)
		}
	}
}

func TestRenderUnreachableClashAPI(t *testing.T) {
	ts := fakeClash(t, piiConnectionsJSON)
	url := ts.URL
	ts.Close() // now the URL refuses connections

	out := render(url, "")
	if !strings.Contains(out, "mycelium_dataplane_clash_api_reachable 0") {
		t.Fatalf("want reachable 0 when clash_api is down, got:\n%s", out)
	}
	if strings.Contains(out, "mycelium_dataplane_upload_bytes_total") {
		t.Fatalf("byte counters must be omitted when clash_api is unreachable, got:\n%s", out)
	}
}

func TestRenderSendsBearerWhenSecretSet(t *testing.T) {
	gotAuth := ""
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"downloadTotal":1,"uploadTotal":2,"connections":[]}`))
	}))
	defer ts.Close()

	out := render(ts.URL, "s3cret-token")
	if gotAuth != "Bearer s3cret-token" {
		t.Fatalf("clash_api request Authorization = %q, want %q", gotAuth, "Bearer s3cret-token")
	}
	if !strings.Contains(out, "mycelium_dataplane_active_connections 0") {
		t.Fatalf("want active_connections 0 for an empty list, got:\n%s", out)
	}
}
