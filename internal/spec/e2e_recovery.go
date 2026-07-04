// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// e2e_recovery.go — the RP-0013 (Phase-3) end-to-end client-recovery contract, expressed as a PURE
// invariant on a rendered Bundle. Phase 2 makes a NODE self-drive (measure→detect→rotate); Phase 3 proves
// the loop closes at the CLIENT: a stock client holding the served subscription must ALWAYS retain a live
// fallback on an INDEPENDENT transport family when its active endpoint is blocked.
//
// Independence is FAMILY-level (TransportClass), not endpoint-level: the REALITY Vision / gRPC / XHTTP
// shapes are ONE family — same handshake fingerprint surface, same donor, same keypair (ADR-0020 §5) — so
// a bundle carrying only those is a single point of block no matter how many endpoints it lists (one block
// takes them all). The contract (RP-0013 AC-2, "always a live fallback"): the served bundle spans >= 2
// DISTINCT families, so blocking one whole family still leaves the client >= 1 endpoint on another.
//
// This is the SERVE-TIME invariant the older gates deliberately did not check (transport_family_independence
// asserts the CAPABILITY exists; sub_channel_not_single_point asserts the class-MAPPING spans >=2). Here we
// check the actual rendered ARTIFACT a client would import. It is pure and rotation-safe by construction:
// a RP-0012 rotation stays within the closed set and has no family-DISABLE action, so it can never reduce
// the served family set (it swaps the active shape / regenerates a parameter, it does not remove a family).

// DistinctClasses returns the set of distinct transport FAMILIES (TransportClass) present in the bundle's
// endpoints, in first-seen (registry-priority) order. Deterministic; pure.
func (b Bundle) DistinctClasses() []TransportClass {
	seen := make(map[TransportClass]bool, len(b.Endpoints))
	out := make([]TransportClass, 0, len(b.Endpoints))
	for _, ep := range b.Endpoints {
		if !seen[ep.TransportClass] {
			seen[ep.TransportClass] = true
			out = append(out, ep.TransportClass)
		}
	}
	return out
}

// IndependentFallbackOK reports whether the served bundle satisfies the RP-0013 e2e recovery contract:
// >= 2 DISTINCT transport families, so no single-family block can remove the client's last path. A bundle
// that lists several endpoints of ONE family (e.g. REALITY Vision + gRPC + XHTTP) is NOT ok — they fail
// together. This is the "always a live fallback" precondition for end-to-end client recovery. Pure.
func (b Bundle) IndependentFallbackOK() bool {
	return len(b.DistinctClasses()) >= 2
}

// enabledFamiliesDistinct counts the distinct transport FAMILIES (TransportClass) across a set of enabled
// proto descriptors — the same RP-0013 fallback contract applied on a render path that works from
// descriptors (RenderSubscription's sing-box-dialable set) rather than a finished Bundle. Pure.
func enabledFamiliesDistinct(ds []ProtoDescriptor) int {
	seen := make(map[TransportClass]bool, len(ds))
	for i := range ds {
		seen[ds[i].Class] = true
	}
	return len(seen)
}
