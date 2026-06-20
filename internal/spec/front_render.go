// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"
)

// FrontEndpointPriorityBase offsets a fronted endpoint's selection priority so it sorts AFTER every
// direct endpoint (whose priorities are the small registry indices). A front is complementary /
// last-resort doctrine (ADR-0033 §5), so the client prefers the direct path and falls to the front.
const FrontEndpointPriorityBase = 1000

// RenderBundleFront renders the node's Bundle and, when an enabled front is configured for a frontable
// transport this node actually serves, APPENDS one extra fronted Endpoint pointing at the operator's
// front domain (ADR-0033 P2). It is purely additive: a disabled / non-matching / not-served front leaves
// the bundle byte-identical to RenderBundle (so a node without a front is unchanged and the
// bundle_render_go_equiv gate — which passes no front — stays green). The fronted endpoint reuses the
// SAME base resolution as the direct ones (bundleBaseLinkParams) so the two cannot drift, gets a distinct
// `-front` tag, and a last-resort priority. Pure.
func RenderBundleFront(params map[string]json.RawMessage, firstClientID, firstClientPassword string, fc FrontConfig, generatedAt time.Time) (Bundle, error) {
	b, err := RenderBundle(params, firstClientID, firstClientPassword, generatedAt)
	if err != nil {
		return Bundle{}, err
	}
	if !fc.Enabled {
		return b, nil // default-off: byte-identical to RenderBundle
	}
	if err := fc.Validate(); err != nil {
		return Bundle{}, fmt.Errorf("bundle front: %w", err)
	}
	// Locate the frontable transport in the registry and require this node to actually serve it.
	var d ProtoDescriptor
	idx, found := -1, false
	for i := range transportRegistry {
		if transportRegistry[i].Proto == fc.Transport {
			d, idx, found = transportRegistry[i], i, true
			break
		}
	}
	if !found || d.EnableKey == "" || !paramBool(params, d.EnableKey) {
		return b, nil // front configured for a transport this node does not serve — fail-safe no-op
	}
	base, err := bundleBaseLinkParams(params, firstClientID, firstClientPassword)
	if err != nil {
		return Bundle{}, err
	}
	lp := base
	lp.Port = paramStr(params, d.PortKey, strconv.Itoa(d.DefaultPort))
	fronted, ok := FrontLinkParams(d.Proto, lp, fc)
	if !ok {
		return b, nil
	}
	link, err := ShareLink(d.Proto, fronted)
	if err != nil {
		return Bundle{}, fmt.Errorf("bundle front: %w", err)
	}
	region := paramStr(params, "region_bucket", "unspecified")
	b.Endpoints = append(b.Endpoints, Endpoint{
		Tag:            "mycelium-" + d.Proto + "-front",
		TransportClass: d.Class,
		Region:         RegionBucket(region),
		Priority:       FrontEndpointPriorityBase + idx,
		Health:         HealthUnknown,
		Link:           link,
	})
	return b, nil
}

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
