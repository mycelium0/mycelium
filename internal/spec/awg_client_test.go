// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
)

// TestResolveAWGRoutesNeverSilentlyFullTunnels is the load-bearing invariant of VIS-0009/ADR-0027: a full
// tunnel is reachable ONLY through the deliberate opt-out, and when taken it is always RECORDED by the
// marker. No other input combination may produce a default route.
func TestResolveAWGRoutesNeverSilentlyFullTunnels(t *testing.T) {
	for _, v6 := range []bool{false, true} {
		for _, region := range [][]string{nil, {}, {"# only a comment"}, {"10.0.0.0/8"}, {"0.0.0.0/0"}, {"::/0"}} {
			r, err := ResolveAWGRoutes(AWGRoutePolicy{SplitTunnel: true, RegionExclude: region, HasV6: v6})
			if err != nil {
				t.Fatalf("split-tunnel resolve must not error (region=%v v6=%v): %v", region, v6, err)
			}
			if r.FullTunnel() {
				t.Fatalf("SILENT FULL TUNNEL for region=%v v6=%v -> %v", region, v6, r.Lines)
			}
			if r.Marker != "" {
				t.Fatalf("a non-opt-out client must carry no opt-out marker (region=%v)", region)
			}
		}
	}
}

// TestResolveAWGRoutesDeliberateFullTunnel: the opt-out yields the default route(s) AND the marker.
func TestResolveAWGRoutesDeliberateFullTunnel(t *testing.T) {
	r, err := ResolveAWGRoutes(AWGRoutePolicy{FullTunnelOptOut: true, SplitTunnel: true})
	if err != nil {
		t.Fatalf("opt-out resolve: %v", err)
	}
	if got := r.Join(); got != "0.0.0.0/0" {
		t.Fatalf("v4-only full tunnel = %q, want 0.0.0.0/0", got)
	}
	if r.Marker != AWGSGOptOutMarker {
		t.Fatalf("a deliberate full tunnel must record the marker, got %q", r.Marker)
	}
	r6, err := ResolveAWGRoutes(AWGRoutePolicy{FullTunnelOptOut: true, SplitTunnel: true, HasV6: true})
	if err != nil {
		t.Fatalf("opt-out v6 resolve: %v", err)
	}
	if got := r6.Join(); got != "0.0.0.0/0, ::/0" {
		t.Fatalf("dual-stack full tunnel = %q, want \"0.0.0.0/0, ::/0\"", got)
	}
}

// TestResolveAWGRoutesRefusesUndocumented: split-tunnel off without the opt-out is refused outright.
func TestResolveAWGRoutesRefusesUndocumented(t *testing.T) {
	if _, err := ResolveAWGRoutes(AWGRoutePolicy{SplitTunnel: false}); err == nil {
		t.Fatal("split-tunnel off with no opt-out must be refused")
	}
}

// TestResolveAWGRoutesRegionExclude: the list is taken verbatim, comments/blanks stripped, and a listed
// default route is dropped (it would be a full tunnel by the back door).
func TestResolveAWGRoutesRegionExclude(t *testing.T) {
	r, err := ResolveAWGRoutes(AWGRoutePolicy{
		SplitTunnel: true,
		RegionExclude: []string{
			"  10.0.0.0/8  ",
			"# a comment line",
			"",
			"192.168.0.0/16 # trailing comment",
			"0.0.0.0/0",
			"2001:db8::/32",
		},
	})
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	want := "10.0.0.0/8, 192.168.0.0/16, 2001:db8::/32"
	if got := r.Join(); got != want {
		t.Fatalf("routes = %q, want %q", got, want)
	}
	if r.FullTunnel() {
		t.Fatal("a listed 0.0.0.0/0 must be dropped, not honoured")
	}
}

// TestResolveAWGRoutesIPv6LeakGuard (ADR-0027): a v4-only region-exclude list gains ::/0, so the client's
// public IPv6 cannot egress DIRECT and defeat the split.
func TestResolveAWGRoutesIPv6LeakGuard(t *testing.T) {
	r, err := ResolveAWGRoutes(AWGRoutePolicy{SplitTunnel: true, RegionExclude: []string{"10.0.0.0/8", "172.16.0.0/12"}})
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if !strings.HasSuffix(r.Join(), "::/0") {
		t.Fatalf("a v4-only list must gain ::/0, got %q", r.Join())
	}
	// A list that already routes v6 must NOT gain a second one.
	r2, err := ResolveAWGRoutes(AWGRoutePolicy{SplitTunnel: true, RegionExclude: []string{"10.0.0.0/8", "2001:db8::/32"}})
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if strings.Count(r2.Join(), "::/0") != 0 {
		t.Fatalf("a list that already carries a v6 route must not gain ::/0, got %q", r2.Join())
	}
}

// TestResolveAWGRoutesSafeNarrow: with no list at all the client gets the in-tunnel ranges only.
func TestResolveAWGRoutesSafeNarrow(t *testing.T) {
	r, err := ResolveAWGRoutes(AWGRoutePolicy{SplitTunnel: true})
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got := r.Join(); got != "10.13.13.0/24" {
		t.Fatalf("safe narrow = %q, want 10.13.13.0/24", got)
	}
	r6, _ := ResolveAWGRoutes(AWGRoutePolicy{SplitTunnel: true, HasV6: true})
	if got := r6.Join(); got != "10.13.13.0/24, fd13:13:13::/64" {
		t.Fatalf("dual-stack safe narrow = %q", got)
	}
}

// TestNextAWGPeerHost: allocation starts at .2, fills gaps, and never hands out the probe-reserved range.
func TestNextAWGPeerHost(t *testing.T) {
	n, err := NextAWGPeerHost(nil)
	if err != nil || n != 2 {
		t.Fatalf("first peer = %d (%v), want 2", n, err)
	}
	if n, _ := NextAWGPeerHost([]int{2, 3, 5}); n != 4 {
		t.Fatalf("gap fill = %d, want 4", n)
	}
	// Exhaust .2–.239: the next allocation must FAIL rather than reach into the probe range.
	var all []int
	for i := AWGFirstPeerHost; i < AWGProbeReservedFrom; i++ {
		all = append(all, i)
	}
	if _, err := NextAWGPeerHost(all); err == nil {
		t.Fatal("an exhausted client range must fail closed, never allocate into .240–.254 (the L7 probe range)")
	}
}

// TestUsedAWGPeerHosts: host numbers are read from the live config's peer AllowedIPs lines, including a
// dual-stack peer, and the server's own Address line is not mistaken for a peer.
func TestUsedAWGPeerHosts(t *testing.T) {
	conf := `[Interface]
PrivateKey = KEY
Address = 10.13.13.1/24, fd13:13:13::1/64
ListenPort = 51820

[Peer]
PublicKey = A
AllowedIPs = 10.13.13.2/32

[Peer]
PublicKey = B
AllowedIPs = 10.13.13.7/32, fd13:13:13::7/128
`
	got := UsedAWGPeerHosts(conf)
	if len(got) != 2 || got[0] != 2 || got[1] != 7 {
		t.Fatalf("used hosts = %v, want [2 7]", got)
	}
	if n, _ := NextAWGPeerHost(got); n != 3 {
		t.Fatalf("next after {2,7} = %d, want 3", n)
	}
}
