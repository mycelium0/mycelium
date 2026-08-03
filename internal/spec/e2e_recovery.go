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
// a RP-0012 rotation stays within the closed set. It CAN now reduce the served set, because demote-active
// exists — so the guarantee below is no longer supplied by the ABSENCE of an action. It is supplied by an
// executable precondition, DemoteKeepsIndependentFallback, which the planner must satisfy before it may
// emit one. This paragraph asserted the invariant in prose for a long time, and prose cannot fail a
// build. Historically it read: a rotation has no family-DISABLE action, so it can never reduce
// the served family set (it swaps the active shape / regenerates a parameter, it does not remove a family).

// DistinctClasses returns the set of distinct transport FAMILIES (TransportClass) present in the bundle's
// endpoints, in first-seen (registry-priority) order. Deterministic; pure. (Diagnostic detail; the recovery
// contract counts BLOCK families, below — DistinctBlockFamilies.)
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

// blockFamily folds a TransportClass to its BLOCK-INDEPENDENCE family — the coarser grouping the recovery
// contract must count, because two DISTINCT classes are NOT an independent fallback for one another if a
// SINGLE block takes both (Audit-0008 S1-3). After RP-0015 every own-cert TLS class presents the node's ONE
// tls_sni AND the ONE node-wide uTLS ClientHello preset, so a single SNI- or fingerprint-keyed block on the
// client→node handshake takes ws-tls + xhttp-tls + trojan + the QUIC families TOGETHER — they share the
// dominant block axis and fold to one family. The genuinely independent axes each stay their own family:
// reality-tcp (borrowed donor SNI + keypair), shadowtls-tcp (a distinct cover host), shadowsocks-tcp (no SNI),
// amneziawg-udp (no TLS). The fold is conservative on purpose — it demands MORE independent redundancy, never
// less — so a config of only own-cert-TLS families no longer false-certifies "always a live fallback".
func blockFamily(c TransportClass) TransportClass {
	switch c {
	case TransportClassXHTTPTLS, TransportClassWSTLS, TransportClassQUICUDP, TransportClassTrojanTLS:
		return TransportClass("own-tls-sni")
	default:
		return c
	}
}

// DistinctBlockFamilies returns the distinct BLOCK-independence families across the bundle's endpoints,
// first-seen order. Deterministic; pure.
func (b Bundle) DistinctBlockFamilies() []TransportClass {
	seen := make(map[TransportClass]bool, len(b.Endpoints))
	out := make([]TransportClass, 0, len(b.Endpoints))
	for _, ep := range b.Endpoints {
		fam := blockFamily(ep.TransportClass)
		if !seen[fam] {
			seen[fam] = true
			out = append(out, fam)
		}
	}
	return out
}

// IndependentFallbackOK reports whether the served bundle satisfies the RP-0013 e2e recovery contract:
// >= 2 DISTINCT BLOCK-independence families, so no single block can remove the client's last path. Several
// endpoints of one family (REALITY Vision + gRPC + XHTTP), OR several own-cert-TLS classes sharing the one
// SNI + preset (ws-tls + trojan), are each NOT ok — they fail together. The "always a live fallback"
// precondition for end-to-end client recovery. Pure.
func (b Bundle) IndependentFallbackOK() bool {
	return len(b.DistinctBlockFamilies()) >= 2
}

// enabledFamiliesDistinct counts the distinct BLOCK-independence families across a set of enabled proto
// descriptors — the same RP-0013 fallback contract applied on a render path that works from descriptors
// (RenderSubscription's sing-box-dialable set) rather than a finished Bundle. Pure.
func enabledFamiliesDistinct(ds []ProtoDescriptor) int {
	seen := make(map[TransportClass]bool, len(ds))
	for i := range ds {
		seen[blockFamily(ds[i].Class)] = true
	}
	return len(seen)
}

// descriptorForProto returns the registry descriptor for a proto name.
func descriptorForProto(proto string) (ProtoDescriptor, bool) {
	for i := range transportRegistry {
		if transportRegistry[i].Proto == proto {
			return transportRegistry[i], true
		}
	}
	return ProtoDescriptor{}, false
}

// DemoteKeepsIndependentFallback answers whether the node may stop serving `demote` without stranding a
// client that is already holding an issued subscription.
//
// THE FLOOR IS OVER THE INTERSECTION, and that is the whole point. The obvious version — "after the
// demote, does the SERVED set still span >= 2 block-independence families?" — passes on a config that
// strands every existing client. Concretely: a client was issued {vless-reality-vision, hysteria2}; the
// node later enabled shadowtls and trojan; a demote now drops vision and hysteria2. The served set is
// {shadowtls, trojan}, two families, floor satisfied, every node-local check green — and the client in
// someone's hands holds only two endpoints, both of which the node has stopped serving. That is the
// cdc5f61 shape exactly: the node's own view says healthy, the config it handed out is undialable.
//
// So the set that matters is what the node serves INTERSECTED with what issued clients actually hold.
// Enabling a transport is the direction that cannot reach an existing client — it never appears in their
// urltest group; disabling is the direction that always can.
//
// FAILS CLOSED on an empty or unknown baseline: not knowing what was issued is not permission to remove
// something. Pure.
func DemoteKeepsIndependentFallback(served, issuedBaseline []string, demote string) (bool, []TransportClass) {
	if len(issuedBaseline) == 0 {
		return false, nil
	}
	held := make(map[string]bool, len(issuedBaseline))
	for _, p := range issuedBaseline {
		held[p] = true
	}
	seen := make(map[TransportClass]bool, len(served))
	fams := make([]TransportClass, 0, len(served))
	for _, p := range served {
		if p == demote || !held[p] {
			continue
		}
		d, ok := descriptorForProto(p)
		if !ok {
			continue
		}
		f := blockFamily(d.Class)
		if !seen[f] {
			seen[f] = true
			fams = append(fams, f)
		}
	}
	return len(fams) >= 2, fams
}
