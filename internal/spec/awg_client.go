// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// awg_client.go — the two remaining AmneziaWG CONTROL decisions, moved out of shell into their owning
// layer (RP-0008 "no new control-decisions-in-bash"; the shell twin's own header already earmarked the
// Selective-Growth policy for this migration):
//
//  1. ResolveAWGRoutes — the Selective-Growth split-tunnel AllowedIPs decision (VIS-0009 / ADR-0027).
//     "The mycelium does not grow where it is not needed": a generated client carries ONLY traffic whose
//     native path is impaired. The one rule that matters is that we NEVER silently full-tunnel — a full
//     tunnel is reachable only through a deliberate, RECORDED opt-out.
//  2. NextAWGPeerHost — which in-tunnel address a newly enrolled peer gets, with the probe range held back.
//
// Both are pure: no files, no network, no exec. The callers read the filesystem (the region-exclude file,
// the live awg0.conf) and hand the CONTENT in, so the decision itself stays testable.

import (
	"fmt"
	"strings"
)

// AWG in-tunnel addressing constants. These mirror control/lib/nb_render_awg.sh; the shell keeps its own
// copies because it renders without the spine binary, and awg_dialect_go_equiv-style gates pin the
// derived outputs rather than the constants.
const (
	// AWGTunnelV4 is the server's in-tunnel v4 address (RFC1918); peers get .2, .3, …
	AWGTunnelV4 = "10.13.13.1/24"
	// AWGPeerBaseV4 is the /24 prefix peers are addressed from.
	AWGPeerBaseV4 = "10.13.13"
	// AWGPeerBaseV6 is the ULA prefix (RFC4193) used only when the node has global IPv6.
	AWGPeerBaseV6 = "fd13:13:13::"
	// AWGSGOptOutMarker is the exact comment a deliberately full-tunnel client config carries, so the
	// no_full_tunnel_default gate can tell a RECORDED opt-out from a silent default.
	AWGSGOptOutMarker = "# selective-growth: opt-out (full-tunnel)"

	// AWGFirstPeerHost is the first host assignable to a client (.0 network, .1 the server).
	AWGFirstPeerHost = 2
	// AWGProbeReservedFrom is the first host of the range reserved for the node-local L7 liveness probe
	// (.240–.254). A client is never assigned into it, so the probe's reserved-range pre-clean can never
	// remove a real peer.
	AWGProbeReservedFrom = 240
)

// AWGRoutePolicy is the input to the Selective-Growth decision. RegionExclude carries the RAW lines of the
// operator's region-exclude file (comments and blanks included — this function strips them exactly as the
// shell does), so the decision itself never touches the filesystem.
type AWGRoutePolicy struct {
	// FullTunnelOptOut is the operator's deliberate, recorded choice to emit a full-tunnel client.
	FullTunnelOptOut bool
	// SplitTunnel is the default-on Selective-Growth mode. Off WITHOUT FullTunnelOptOut is refused.
	SplitTunnel bool
	// RegionExclude holds the raw region-exclude file lines (may be nil/empty).
	RegionExclude []string
	// HasV6 reports whether the node carries a global IPv6 address (dual-stack tunnel).
	HasV6 bool
}

// AWGRoutes is the resolved client route set: the AllowedIPs entries plus the opt-out marker (empty unless
// this is a deliberate full tunnel) and any advisory notes the caller should surface to the operator.
type AWGRoutes struct {
	Lines  []string
	Marker string
	Notes  []string
}

// Join renders the route set as the single `AllowedIPs = a, b, c` value.
func (r AWGRoutes) Join() string { return strings.Join(r.Lines, ", ") }

// FullTunnel reports whether this route set is a default route (i.e. a deliberate full tunnel).
func (r AWGRoutes) FullTunnel() bool {
	for _, l := range r.Lines {
		if l == "0.0.0.0/0" {
			return true
		}
	}
	return false
}

// ResolveAWGRoutes applies the Selective-Growth resolution order (VIS-0009 / ADR-0027):
//
//  1. FullTunnelOptOut          -> deliberate full tunnel: the recorded marker + default route(s).
//  2. SplitTunnel off, no opt-out -> REFUSED (an undocumented full tunnel is never emitted).
//  3. a usable region-exclude list -> that route set verbatim, with the IPv6-leak guard applied.
//  4. otherwise                 -> SAFE NARROW: the in-tunnel range(s) only, with a loud note.
//
// IPv6-leak guard (case 3): a v4-only region-exclude list would leave the client's PUBLIC IPv6 outside the
// tunnel — the host keeps its own v6 default route, so impaired-path destinations would egress DIRECT over
// v6 and defeat the split. A v4-only list therefore gains ::/0: the node routes it when it has global v6,
// otherwise it is dropped and apps fall back to (tunnelled) IPv4. Never leak v6.
//
// Pure; the returned Notes are advisory text for the caller to log, never a side effect here.
func ResolveAWGRoutes(p AWGRoutePolicy) (AWGRoutes, error) {
	if p.FullTunnelOptOut {
		lines := []string{"0.0.0.0/0"}
		if p.HasV6 {
			lines = append(lines, "::/0")
		}
		return AWGRoutes{
			Lines:  lines,
			Marker: AWGSGOptOutMarker,
			Notes:  []string{"emitting a DELIBERATE full-tunnel client (marker recorded); prefer a region-exclude list (Selective Growth)"},
		}, nil
	}
	if !p.SplitTunnel {
		return AWGRoutes{}, fmt.Errorf("awg-routes: split-tunnel is off with no full-tunnel opt-out — refusing an undocumented full-tunnel client")
	}

	var notes []string
	var lines []string
	for _, raw := range p.RegionExclude {
		// Strip a trailing comment, then surrounding whitespace — exactly as the shell twin does.
		if i := strings.IndexByte(raw, '#'); i >= 0 {
			raw = raw[:i]
		}
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if line == "0.0.0.0/0" || line == "::/0" {
			notes = append(notes, fmt.Sprintf("region-exclude file lists a default route (%s) — that is a full tunnel; ignoring that entry", line))
			continue
		}
		lines = append(lines, line)
	}

	if len(lines) > 0 {
		hasV6Route := false
		for _, l := range lines {
			if strings.Contains(l, ":") {
				hasV6Route = true
				break
			}
		}
		if !hasV6Route {
			lines = append(lines, "::/0")
			notes = append(notes, "region-exclude list is IPv4-only — appended ::/0 to stop an IPv6 leak")
		}
		notes = append(notes, "AllowedIPs from the region-exclude list (Selective Growth)")
		return AWGRoutes{Lines: lines, Notes: notes}, nil
	}
	if len(p.RegionExclude) > 0 {
		notes = append(notes, "the region-exclude list yielded no usable CIDRs — falling back to the safe narrow default")
	}

	// SAFE NARROW: the in-tunnel ranges only. This client will NOT carry out-of-region impaired-path
	// traffic until a region-exclude list is supplied — intentional; we never silently full-tunnel.
	narrow := []string{awgTunnelV4Network()}
	if p.HasV6 {
		narrow = append(narrow, AWGPeerBaseV6+"/64")
	}
	notes = append(notes, "no region-exclude list configured — emitting a SAFE NARROW client (tunnel ranges only); it will NOT carry out-of-region impaired-path traffic until a region-exclude AllowedIPs file is supplied")
	return AWGRoutes{Lines: narrow, Notes: notes}, nil
}

// awgTunnelV4Network turns the server's in-tunnel address into its /24 network (10.13.13.1/24 ->
// 10.13.13.0/24), mirroring the shell's sed.
func awgTunnelV4Network() string { return AWGPeerBaseV4 + ".0/24" }

// NextAWGPeerHost returns the lowest free host number for a NEW peer, given the host numbers already taken
// (in any order, duplicates allowed). Clients occupy .2–.239; .240–.254 stays reserved for the node-local
// L7 probe, so this fails closed rather than handing out an address the probe's pre-clean would reap.
func NextAWGPeerHost(used []int) (int, error) {
	taken := make(map[int]bool, len(used))
	for _, u := range used {
		taken[u] = true
	}
	for n := AWGFirstPeerHost; n < AWGProbeReservedFrom; n++ {
		if !taken[n] {
			return n, nil
		}
	}
	return 0, fmt.Errorf("awg-peer: no free client address (.%d–.%d exhausted; .%d–.254 is reserved for the L7 probe)",
		AWGFirstPeerHost, AWGProbeReservedFrom-1, AWGProbeReservedFrom)
}

// UsedAWGPeerHosts extracts the host numbers already assigned in a live awg0.conf, by reading its peer
// `AllowedIPs = 10.13.13.N/32[, ...]` lines. Unrelated lines are ignored; the server's own Address line is
// not a peer line and is skipped by construction (it is `Address = `, not `AllowedIPs = `).
func UsedAWGPeerHosts(awgConf string) []int {
	var out []int
	prefix := AWGPeerBaseV4 + "."
	for _, line := range strings.Split(awgConf, "\n") {
		line = strings.TrimSpace(line)
		rest, ok := strings.CutPrefix(line, "AllowedIPs = ")
		if !ok {
			continue
		}
		// A peer's AllowedIPs may list several entries; take the v4 /32 in our peer prefix.
		for _, field := range strings.Split(rest, ",") {
			field = strings.TrimSpace(field)
			hostPart, ok := strings.CutPrefix(field, prefix)
			if !ok {
				continue
			}
			num, _, ok := strings.Cut(hostPart, "/")
			if !ok {
				continue
			}
			n := 0
			valid := num != ""
			for _, c := range num {
				if c < '0' || c > '9' {
					valid = false
					break
				}
				n = n*10 + int(c-'0')
			}
			if valid {
				out = append(out, n)
			}
		}
	}
	return out
}
