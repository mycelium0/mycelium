// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// awg_render.go — the AmneziaWG CLIENT config renderer, owned by the Go spine (RP-0008).
//
// This is the artefact a user actually imports: it carries the client's key, its in-tunnel address, the
// node's endpoint, the resolved Selective-Growth routes, and — critically — the node's per-node DIALECT.
// Server and client must agree on all nine dialect values or no handshake completes, so the same
// AWGDialect value renders both sides (RenderINI is the single source of those lines).
//
// The bash twin (render_awg_client_conf in control/lib/nb_render_awg.sh) stays for nodes without the spine
// binary; tests/conformance/awg_client_conf_go_equiv.sh pins the two byte-identical, exactly as the other
// renderers are pinned.

import (
	"fmt"
	"strings"
)

// AWGClientConfig is everything needed to render one client's config. Secrets (PrivateKey, PresharedKey)
// are rendered verbatim into the output — the result is 0600 node-local material handed over out-of-band,
// never logged.
type AWGClientConfig struct {
	// PrivateKey is the CLIENT's own private key (generated on the node, model A).
	PrivateKey string
	// Host is the client's in-tunnel host number within AWGPeerBaseV4 (.2–.239).
	Host int
	// HasV6 renders the dual-stack in-tunnel address + resolver.
	HasV6 bool
	// MTU is the tunnel MTU.
	MTU int
	// Dialect is the node's per-node obfuscation dialect — must be the SAME one the server serves.
	Dialect AWGDialect
	// ServerPublicKey is the node's AmneziaWG public key (the [Peer] the client dials).
	ServerPublicKey string
	// PresharedKey is this client's PSK (shared with its server-side [Peer] entry).
	PresharedKey string
	// Endpoint is the node's reachable "address:port".
	Endpoint string
	// Routes is the resolved Selective-Growth route set (carries the opt-out marker when deliberate).
	Routes AWGRoutes
	// Keepalive is the PersistentKeepalive interval in seconds (NAT mappings survive idle periods).
	Keepalive int
}

// AWGDefaultMTU / AWGDefaultKeepalive are the canonical values the renderers use.
const (
	AWGDefaultMTU       = 1280
	AWGDefaultKeepalive = 25
)

// awgClientDNS returns the resolvers a client reaches through the tunnel.
func awgClientDNS(hasV6 bool) string {
	if hasV6 {
		return "1.1.1.1, 2606:4700:4700::1111"
	}
	return "1.1.1.1"
}

// AWGPeerAddress renders a peer's in-tunnel address field for the given host number: the v4 /32, plus the
// v6 /128 when the node is dual-stack.
func AWGPeerAddress(host int, hasV6 bool) string {
	addr := fmt.Sprintf("%s.%d/32", AWGPeerBaseV4, host)
	if hasV6 {
		addr += fmt.Sprintf(", %s%d/128", AWGPeerBaseV6, host)
	}
	return addr
}

// Validate rejects a config that could not produce a working client, BEFORE it is written and handed over.
// A silently broken client config is worse than a refusal: it looks like a working artefact.
func (c AWGClientConfig) Validate() error {
	if strings.TrimSpace(c.PrivateKey) == "" {
		return fmt.Errorf("awg-client: empty client PrivateKey")
	}
	if strings.TrimSpace(c.ServerPublicKey) == "" {
		return fmt.Errorf("awg-client: empty server PublicKey (the client would have no peer to dial)")
	}
	if strings.TrimSpace(c.Endpoint) == "" {
		return fmt.Errorf("awg-client: empty Endpoint (the client would not know where to connect)")
	}
	if c.Host < AWGFirstPeerHost || c.Host >= AWGProbeReservedFrom {
		return fmt.Errorf("awg-client: host .%d is outside the assignable client range .%d–.%d",
			c.Host, AWGFirstPeerHost, AWGProbeReservedFrom-1)
	}
	if len(c.Routes.Lines) == 0 {
		return fmt.Errorf("awg-client: empty AllowedIPs (the client would route nothing)")
	}
	if !c.Dialect.Valid() {
		return fmt.Errorf("awg-client: the dialect violates the AmneziaWG constraints — the handshake could not complete")
	}
	// A full tunnel MUST carry the recorded Selective-Growth marker (VIS-0009/ADR-0027): a default route
	// without it is exactly the "silent full tunnel" the doctrine forbids.
	if c.Routes.FullTunnel() && c.Routes.Marker == "" {
		return fmt.Errorf("awg-client: a full-tunnel client without the Selective-Growth opt-out marker (refusing a silent full tunnel)")
	}
	return nil
}

// RenderAWGClientConfig renders the complete, ready-to-import client config. Deterministic and pure: the
// same input always yields the same bytes, which is what lets a conformance gate pin it against the shell.
func RenderAWGClientConfig(c AWGClientConfig) (string, error) {
	if c.MTU == 0 {
		c.MTU = AWGDefaultMTU
	}
	if c.Keepalive == 0 {
		c.Keepalive = AWGDefaultKeepalive
	}
	if err := c.Validate(); err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("[Interface]\n")
	fmt.Fprintf(&b, "PrivateKey = %s\n", c.PrivateKey)
	fmt.Fprintf(&b, "Address = %s\n", AWGPeerAddress(c.Host, c.HasV6))
	fmt.Fprintf(&b, "DNS = %s\n", awgClientDNS(c.HasV6))
	fmt.Fprintf(&b, "MTU = %d\n", c.MTU)
	b.WriteString(c.Dialect.RenderINI())
	b.WriteString("\n[Peer]\n")
	fmt.Fprintf(&b, "PublicKey = %s\n", c.ServerPublicKey)
	fmt.Fprintf(&b, "PresharedKey = %s\n", c.PresharedKey)
	fmt.Fprintf(&b, "Endpoint = %s\n", c.Endpoint)
	if c.Routes.Marker != "" {
		fmt.Fprintf(&b, "%s\n", c.Routes.Marker)
	}
	fmt.Fprintf(&b, "AllowedIPs = %s\n", c.Routes.Join())
	fmt.Fprintf(&b, "PersistentKeepalive = %d\n", c.Keepalive)
	return b.String(), nil
}

// RenderAWGServerPeer renders the server-side [Peer] stanza that admits this client — the counterpart of
// the client config above. Kept beside it so the two can never drift: the client's address here and in its
// own [Interface] come from the same AWGPeerAddress call.
func RenderAWGServerPeer(name string, publicKey, presharedKey string, host int, hasV6 bool) string {
	var b strings.Builder
	b.WriteString("\n[Peer]\n")
	fmt.Fprintf(&b, "# name = %s\n", name)
	fmt.Fprintf(&b, "PublicKey = %s\n", publicKey)
	fmt.Fprintf(&b, "PresharedKey = %s\n", presharedKey)
	fmt.Fprintf(&b, "AllowedIPs = %s\n", AWGPeerAddress(host, hasV6))
	return b.String()
}
