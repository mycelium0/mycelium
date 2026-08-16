// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
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

	// Reachable is the public-entry POSTURE. WIRE/APPLY semantics: an ABSENT reachable key renders PUBLIC
	// ("::") so a node that has not adopted the field is byte-identical to today (the additive guard) — the
	// CLI always writes the field explicitly, so a CLI-produced descriptor is never ambiguous. The Go zero
	// value is false, so a NodeProfile *constructed in Go* is non-public until you opt in; that is a
	// construction default, NOT the absent-key wire default. Set true to declare the node a public entry; a
	// false node is provisioned + converged but not a public entry (it can still be an egress/relay
	// participant). NOTE: false governs the sing-box ingress; the optional Xray engine is covered fail-closed
	// at apply time (it refuses reachable=false + an Xray-only transport) pending dual-engine reachability.
	Reachable bool `json:"reachable"`

	// Harden is the HOST-FIREWALL posture. A POINTER, unlike Reachable, precisely because the three states
	// have to stay distinguishable: absent (the operator has said nothing), true, and false.
	//
	// WHY IT EXISTS (Audit-0009 I1). The convergence tail decided the firewall step from an argv default,
	// `${DO_HARDEN:-1}` — coherent while that tail ran only under an operator's hand, and not once the
	// unattended timer began calling it with no flags at all. A node deliberately bootstrapped with
	// --no-harden then had ufw force-enabled on the first tick, blocking every non-mycelium inbound service
	// on the host; anti-lockout preserved only SSH. A posture is node state, not an invocation's argv, so
	// it belongs here beside Reachable.
	//
	// WIRE/APPLY semantics: ABSENT means "not declared" and the reader falls back to the node's remembered
	// bootstrap posture, then to ON — so a node that has not adopted the field behaves exactly as today
	// (the additive guard). Present wins over both. Use HardenEnabled to read it; the nil case is ON, which
	// is the fail-safe direction for a firewall.
	Harden *bool `json:"harden,omitempty"`

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
	// Collapse is the PostConnectCollapse arm (RP-0014 chunk B increment 2). Declared here for one measured
	// reason: it was the only arm sentinel in this tree with no verb, no gate and no status surface, and it
	// was the only one that drifted — present on one node of three, since 2026-07-19, chosen by nobody and
	// visible to nothing. That is a mechanism rather than a coincidence, and the same reasoning
	// LoopDrift's own comment gives applies: a posture that cannot be compared across a population is one
	// that diverges silently.
	//
	// Like every field here it is a REQUEST, never a switch — arming stays a node-local sentinel
	// ($STATE_DIR/collapse-armed.enabled) so no committable file can turn on a signal that faults a
	// transport. What this field buys is that the request and the reality can be reconciled and reported.
	Collapse bool `json:"collapse"`
}

// WeatherSlot is the reserved, inert ADR-0030 weather opt-in. It MUST stay off in this phase; Validate
// refuses Enabled=true so the niche cannot be switched on before the awareness build-RP exists.
type WeatherSlot struct {
	Enabled bool `json:"enabled"` // reserved; MUST be false until the awareness build-RP
}

// ProtoByName returns the registry descriptor for a wire proto name (closed registry — internal/spec /
// control/vocab.json), so NodeProfile validates transport names against the single source of truth
// rather than restating any naming rule.
func ProtoByName(proto string) (ProtoDescriptor, bool) {
	for _, d := range TransportRegistry() {
		if d.Proto == proto {
			return d, true
		}
	}
	return ProtoDescriptor{}, false
}

// EnabledKeys returns the params enable-keys the descriptor's transports turn on, resolved THROUGH the
// Go-owned registry (never a restated naming rule) and sorted for determinism. This is the pure
// descriptor->params-toggle translation the bootstrap will later apply additively (RP-0011 chunk B/C);
// it is exposed now via `myceliumctl node plan` as a dry-run preview, with no live mutation. An empty
// Transports yields no keys (the node keeps its default-on set). It fails closed on any transport that
// is unknown or not operator-toggleable, mirroring Validate.
func (p NodeProfile) EnabledKeys() ([]string, error) {
	keys := make([]string, 0, len(p.Transports))
	for _, t := range p.Transports {
		d, ok := ProtoByName(t)
		if !ok {
			return nil, fmt.Errorf("%w: transports[] %q is not a known transport", ErrUnknownEnum, t)
		}
		if d.EnableKey == "" {
			return nil, fmt.Errorf("%w: transports[] %q is not operator-toggleable (the registry gives it no enable key)", ErrUnknownEnum, t)
		}
		keys = append(keys, d.EnableKey)
	}
	sort.Strings(keys)
	return keys, nil
}

// Validate enforces the ADR-0034 invariants, fail-closed and pure. An all-default profile (no
// transports, not reachable, no front, no ingress, no loops, weather off) is valid and inert.
func (p NodeProfile) Validate() error {
	// transports: every named transport must be a real, params-toggleable registry proto. The schema
	// reads the registry's EnableKey; it never restates the "<proto>_enabled" naming rule.
	for _, t := range p.Transports {
		d, ok := ProtoByName(t)
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

// WithTransport returns a copy of the profile with proto added (enable) or removed (disable) from
// Transports — deduplicated, with the remaining order preserved and an enabled proto appended last. It
// is a PURE list edit and does NOT validate proto (the caller validates it against the registry) or
// actuate anything; it is the descriptor mutation the `transport enable|disable` CLI verbs apply before
// writing node.config.json. Disabling a transport only removes it from the descriptor's additive enable
// set (it cannot turn off a default-on transport — that is the additive read semantics of apply_node_profile).
func (p NodeProfile) WithTransport(proto string, enable bool) NodeProfile {
	out := make([]string, 0, len(p.Transports)+1)
	for _, t := range p.Transports {
		if t == proto {
			continue // drop any existing occurrence (dedup)
		}
		out = append(out, t)
	}
	if enable {
		out = append(out, proto)
	}
	p.Transports = out
	return p
}

// ParseNodeProfile decodes a node profile, fail-closed: it REFUSES unknown fields so a stray node-"type"
// enum, an engine selector, or any field outside the closed capability set is rejected (ADR-0034 —
// capabilities, not types), then runs Validate. Pure; no I/O beyond the reader.
// NewNodeProfile returns the descriptor that is EQUIVALENT TO HAVING NO DESCRIPTOR AT ALL, and is the
// only correct starting point when a CLI verb creates one for a node that had none.
//
// This exists because the two defaults deliberately disagree: on the WIRE an absent `reachable` key means
// PUBLIC (the additive guard — a node that never adopted the field must render byte-identically), while
// the Go zero value is `false`. Starting an edit from the zero value therefore SILENTLY FLIPS a live
// public node to non-public as a side effect of an unrelated change — e.g. `transport enable X` on a node
// with no descriptor would, on the next apply, rebind its listeners to loopback and take it off the
// network. That happened on a live node; the apply only failed closed for an unrelated reason.
//
// Verbs that set a field explicitly (`reachable on|off`) overwrite it anyway; verbs that do not MUST start
// here so an edit changes exactly what the operator asked for and nothing else.
func NewNodeProfile() NodeProfile {
	on := true
	return NodeProfile{Reachable: true, Harden: &on}
}

// HardenEnabled reports whether the host firewall should be converged on this node. A DECLARED value
// wins; an absent one reads as ON, which is the fail-safe direction for a firewall and keeps a descriptor
// that predates the field behaving as it did. Callers that must distinguish "absent" from "declared true"
// — the shell tail does, so it can fall back to the node's remembered bootstrap posture first — read the
// pointer directly.
func (p NodeProfile) HardenEnabled() bool {
	if p.Harden == nil {
		return true
	}
	return *p.Harden
}

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

// LoopDrift names every divergence between the loops a node profile REQUESTS and the loops that are
// actually running.
//
// The profile's Loops field is a request, not a switch: arming a live-actuating loop happens only
// through the node-local sentinels, never from a committable file (the RP-0012 triple gate). That design
// is right, and it has a consequence nobody stated — the field can say one thing while the node does
// another, and nothing anywhere notices.
//
// Measured on all three live nodes: node.config.json declared {"update":false,"rotate":false,
// "measure":false} while all three timers were active. Nothing consumes the field, so it had drifted
// into a decorative statement that an operator reads as fact. A declaration that cannot be enforced must
// at least be RECONCILED against reality and reported, or it is worse than absent: absent says nothing,
// stale says something false.
//
// Advisory by construction. It returns text; it actuates nothing (ADR-0030).
func LoopDrift(requested, actual LoopsConfig) []string {
	var out []string
	check := func(name string, want, have bool) {
		switch {
		case want && !have:
			out = append(out, name+": the node profile REQUESTS this loop, but it is not running (arming is a node-local sentinel, never the profile — so this request has no effect until an operator arms it)")
		case !want && have:
			out = append(out, name+": this loop IS running, but the node profile does not request it. The profile is what an operator reads to learn what this node does; leaving it false while the loop runs makes the file state something untrue.")
		}
	}
	check("update", requested.Update, actual.Update)
	check("rotate", requested.Rotate, actual.Rotate)
	check("measure", requested.Measure, actual.Measure)
	check("collapse", requested.Collapse, actual.Collapse)
	return out
}
