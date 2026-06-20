// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// FrontPort is the port a CDN/ingress front listens on — always 443, because the whole point of
// fronting is to blend with ordinary HTTPS (a non-443 front would defeat the purpose). The front is the
// operator's edge; the client dials front-domain:443 and (in the default relay mode) the encrypted
// tunnel passes through to the node, so the node's own-cert pin is unchanged end to end.
const FrontPort = "443"

// FrontLinkParams re-points a frontable transport's client endpoint at the operator's CDN/ingress front
// (ADR-0033 P2). It returns (fronted, true) ONLY when the front is enabled, has a domain, and proto is
// EXACTLY the configured, frontable front.Transport; in every other case it returns (base, false) so a
// caller can splice it in without branching (a disabled / non-matching front is a no-op). Callers MUST
// have validated the FrontConfig (FrontConfig.Validate) first — this function does not re-police the
// closed vocab; it only rewrites the dial target.
//
// The rewrite is mode-AGNOSTIC at the client: both relay and terminate make the client dial
// front-domain:443 with SNI = the front domain (the edge routes on it). The relay-vs-terminate
// difference is entirely at the EDGE (passthrough vs TLS-terminating), compiled into the edge proxy
// config by a later chunk — not into the client link. For vless-ws-tls the link's `host=` is also the
// TLSSNI field, so re-pointing TLSSNI re-points both the SNI and the WebSocket Host to the front domain.
// Pure: no I/O, deterministic.
func FrontLinkParams(proto string, base LinkParams, fc FrontConfig) (LinkParams, bool) {
	if !fc.Enabled || fc.Domain == "" || proto != fc.Transport || !IsFrontableTransport(proto) {
		return base, false
	}
	out := base
	out.Server = fc.Domain
	out.Port = FrontPort
	out.TLSSNI = fc.Domain
	return out, true
}
