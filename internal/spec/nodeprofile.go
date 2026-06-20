// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"fmt"
	"io"
)

// NodeProfile is the INERT, node-local descriptor that unifies what a Mycelium node IS into ONE
// declaration (ADR-0034). Every differentiator — which transports it serves, whether it is a public
// entry, an operator CDN front, a two-hop ingress, which background loops it runs, and (reserved) the
// weather opt-in — is a default-off CAPABILITY field of ONE node form. There is deliberately NO
// node-TYPE enum (fungi is a reversible niche, not a class — ADR-0018) and NO engine selector (engines
// stay additive — ADR-0032; the engine is derived from the enabled transports, never chosen here).
//
// Nothing consumes it yet: this is the schema-before-behaviour anchor the RP-0011 CLI writes and the
// bootstrap will later read ADDITIVELY behind the write_params byte-identity pin (a node that adopts no
// new field renders byte-identically). It is node-local and NEVER committed — the committed surface is
// control/node.config.example.json with fail-closed placeholders. Pure data; nothing actuates on it here.
type NodeProfile struct {
	// Transports is the operator's desired enabled set, by friendly proto name (e.g.
	// "vless-reality-vision"). Each name maps to its params *_enabled toggle THROUGH the Go-owned
	// registry (control/vocab.json) — the schema never restates the naming rule. Empty/absent means
	// "use the node's default-on set", so an empty descriptor changes nothing.
	Transports []string `json:"transports,omitempty"`

	// Reachable is the public-entry POSTURE. Default false (safe): a freshly-provisioned node does not
	// auto-advertise. Set true only when the operator declares the node a public entry. A false node is
	// provisioned + converged but not a public entry (it can still be an egress/relay participant).
	Reachable bool `json:"reachable"`

	// Front folds the ADR-0033 operator CDN/ingress front (relay-preferred, bring-your-own-domain,
	// terminate ack-gated). Default-off; a disabled front is byte-identical to no front.
	Front FrontConfig `json:"front"`

	// Ingress folds the two-hop in-region ingress overlay (ADR-0029): an in-region inbound that routes
	// an auth_user to an out-of-region egress. Absent (nil) = not an ingress.
	Ingress *IngressTwoHop `json:"ingress,omitempty"`

	// Loops declares which opt-in background planes the node runs. All default-off. A field here only
	// REQUESTS a loop; arming a live-actuating loop still happens only through the node-local sentinels,
	// never auto-armed and never committable (the RP-0012 triple-gate doctrine holds).
	Loops LoopsConfig `json:"loops"`

	// Weather is the RESERVED, INERT slot for the ADR-0030 / ADR-0018 opt-in class-aggregate weather
	// publish niche. Declared, NOT built here: Validate refuses any non-inert weather config so the slot
	// cannot be switched on until the awareness build-RP fills it.
	Weather WeatherSlot `json:"weather"`
}

// IngressTwoHop is the inert shape of the two-hop ingress overlay (ADR-0029), mirroring the node-local
// two_hop.json the renderer reads. The upstream server/credential are real per-node values and live ONLY
// node-local — never committed (the committed example uses fail-closed placeholders).
type IngressTwoHop struct {
	Server  string `json:"server"`            // the upstream egress node address (node-local; never committed)
	SNI     string `json:"sni"`               // the upstream TLS SNI
	ViaUser string `json:"via_user"`          // the inbound identity whose traffic routes to the egress
	UUID    string `json:"uuid,omitempty"`    // the upstream credential (node-local; never committed)
	WSPath  string `json:"ws_path,omitempty"` // the upstream WebSocket path
}

// LoopsConfig declares the opt-in background planes (all default-off).
type LoopsConfig struct {
	Update  bool `json:"update"`  // the signed auto-pull update timer
	Rotate  bool `json:"rotate"`  // the RP-0012 auto-rotation loop (still triple-gated + armed separately)
	Measure bool `json:"measure"` // the RP-0010 MEASURE advisory daemon
}

// WeatherSlot is the reserved, inert ADR-0030 weather opt-in. It MUST stay off in this phase; Validate
// refuses Enabled=true so the niche cannot be switched on before the awareness build-RP exists.
type WeatherSlot struct {
	Enabled bool `json:"enabled"` // reserved; MUST be false until the awareness build-RP
}

// protoByName returns the registry descriptor for a wire proto name (closed registry — internal/spec /
// control/vocab.json), so NodeProfile validates transport names against the single source of truth
// rather than restating any naming rule.
func protoByName(proto string) (ProtoDescriptor, bool) {
	for _, d := range TransportRegistry() {
		if d.Proto == proto {
			return d, true
		}
	}
	return ProtoDescriptor{}, false
}

// Validate enforces the ADR-0034 invariants, fail-closed and pure. An all-default profile (no
// transports, not reachable, no front, no ingress, no loops, weather off) is valid and inert.
func (p NodeProfile) Validate() error {
	// transports: every named transport must be a real, params-toggleable registry proto. The schema
	// reads the registry's EnableKey; it never restates the "<proto>_enabled" naming rule.
	for _, t := range p.Transports {
		d, ok := protoByName(t)
		if !ok {
			return fmt.Errorf("%w: transports[] %q is not a known transport", ErrUnknownEnum, t)
		}
		if d.EnableKey == "" {
			return fmt.Errorf("%w: transports[] %q is not operator-toggleable (the registry gives it no enable key)", ErrUnknownEnum, t)
		}
	}
	// front: delegate to the ADR-0033 invariants (relay default, frontable-only, terminate-needs-ack).
	if err := p.Front.Validate(); err != nil {
		return fmt.Errorf("node front: %w", err)
	}
	// ingress: if present, the minimal two-hop shape is required, fail-closed (matches assert_two_hop_shape).
	if p.Ingress != nil {
		if p.Ingress.Server == "" {
			return fmt.Errorf("%w: ingress.server", ErrEmptyField)
		}
		if p.Ingress.SNI == "" {
			return fmt.Errorf("%w: ingress.sni", ErrEmptyField)
		}
		if p.Ingress.ViaUser == "" {
			return fmt.Errorf("%w: ingress.via_user", ErrEmptyField)
		}
	}
	// weather: reserved + inert — refuse any attempt to switch the niche on before it is built.
	if p.Weather.Enabled {
		return fmt.Errorf("node weather: the ADR-0030 weather opt-in is a reserved, inert slot in this phase and must stay disabled (the publisher is not built — ADR-0034)")
	}
	return nil
}

// ParseNodeProfile decodes a node profile, fail-closed: it REFUSES unknown fields so a stray node-"type"
// enum, an engine selector, or any field outside the closed capability set is rejected (ADR-0034 —
// capabilities, not types), then runs Validate. Pure; no I/O beyond the reader.
func ParseNodeProfile(r io.Reader) (NodeProfile, error) {
	var p NodeProfile
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return NodeProfile{}, fmt.Errorf("node profile: %w", err)
	}
	if err := p.Validate(); err != nil {
		return NodeProfile{}, err
	}
	return p, nil
}
