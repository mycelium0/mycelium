// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// -----------------------------------------------------------------------------
// Canonical transport registry — the single Go-owned source of the proto->class
// table the shell renderer used to hardcode in parallel copies (RP-0008 P2).
//
// Before this, the wire-proto -> coarse-class mapping, the per-proto default
// ports, the params enable/port key names, and the closed transport-class
// vocabulary lived in three or more hand-maintained shell tables
// (control/lib/render_bundle.sh `myc_bundle_class_of`, render_singbox.sh
// `MYC_SB_PROTOS` + port defaults, render_aggregate.sh's scheme/class consistency
// check, and the conformance mirrors). Any edit had to be replicated by hand
// across every copy or the renderer and its gate silently diverged.
//
// This file is now that source of truth. `myceliumctl vocab` serialises the
// registry deterministically; the committed control/vocab.json is the artifact
// the shell reads at render time (nodes carry no Go binary, so the renderer reads
// a generated-and-gate-verified file rather than shelling out to Go live). The
// vocab_single_source gate fails if the committed file drifts from this Go
// emission, so Go stays authoritative even though the shell consumes a file.
//
// INERT in Phase 0-2 beyond emission: this is a data model + pure lookups, no I/O
// and no network (mirrors the EdgeReport/Bundle phase discipline).
// -----------------------------------------------------------------------------

// ProtoEngine names the data-plane engine that actually serves a proto. It is part
// of the registry because servability is engine-specific: sing-box (the primary
// engine) cannot serve the `xhttp` transport at all, so vless-xhttp-tls is an
// xray-only member kept for the future Xray serving path, and amneziawg is its own
// UDP dataplane rendered outside the sing-box config entirely.
type ProtoEngine string

const (
	// EngineSingBox is the primary engine and serves every proto except the two below.
	EngineSingBox ProtoEngine = "sing-box"
	// EngineXray serves vless-xhttp-tls (sing-box cannot serve the xhttp transport).
	EngineXray ProtoEngine = "xray"
	// EngineAmneziaWG is the standalone obfuscated-WireGuard UDP dataplane (not a sing-box inbound).
	EngineAmneziaWG ProtoEngine = "amneziawg"
)

// ProtoDescriptor is one row of the canonical transport registry: a concrete wire
// PROTO (the dash-form name the shell renderer switches on, e.g. "vless-reality-vision")
// mapped to its coarse transport CLASS, the params keys that enable it and set its
// port, its default port, its share-link URI scheme, and the engine that serves it.
// EnableKey/PortKey/Scheme are empty and DefaultPort is 0 for protos that are not
// params-toggled sing-box/xray inbounds (i.e. amneziawg, which the awg subsystem owns).
type ProtoDescriptor struct {
	Proto       string         `json:"proto"`        // wire proto name, dash form (renderer switch key)
	Class       TransportClass `json:"class"`        // coarse closed-vocab transport family
	EnableKey   string         `json:"enable_key"`   // params bool key that enables it ("" if not params-toggled)
	PortKey     string         `json:"port_key"`     // params int key for its listen port ("" if not params-toggled)
	DefaultPort int            `json:"default_port"` // canonical default listen port (0 if not params-toggled)
	Scheme      string         `json:"scheme"`       // share-link URI scheme ("" if it has no bundle share-link)
	Engine      ProtoEngine    `json:"engine"`       // data-plane engine that serves it
}

// transportRegistry is the ordered canonical proto table. The order of the
// sing-box/xray rows is the renderer PRIORITY order (the historical MYC_SB_PROTOS
// ordering, lower index = preferred); amneziawg is appended because it is a
// separate UDP dataplane, not a sing-box inbound. Editing this slice is the ONLY
// place the proto->class/port/key/scheme/engine facts are defined.
var transportRegistry = []ProtoDescriptor{
	{Proto: "vless-reality-vision", Class: TransportClassRealityTCP, EnableKey: "vless_reality_vision_enabled", PortKey: "vless_reality_vision_port", DefaultPort: 443, Scheme: "vless", Engine: EngineSingBox},
	{Proto: "vless-reality-grpc", Class: TransportClassRealityTCP, EnableKey: "vless_reality_grpc_enabled", PortKey: "vless_reality_grpc_port", DefaultPort: 8443, Scheme: "vless", Engine: EngineSingBox},
	{Proto: "vless-reality-xhttp", Class: TransportClassRealityTCP, EnableKey: "vless_reality_xhttp_enabled", PortKey: "vless_reality_xhttp_port", DefaultPort: 2096, Scheme: "vless", Engine: EngineSingBox},
	{Proto: "vless-xhttp-tls", Class: TransportClassXHTTPTLS, EnableKey: "vless_xhttp_tls_enabled", PortKey: "vless_xhttp_tls_port", DefaultPort: 2087, Scheme: "vless", Engine: EngineXray},
	{Proto: "vless-ws-tls", Class: TransportClassWSTLS, EnableKey: "vless_ws_tls_enabled", PortKey: "vless_ws_tls_port", DefaultPort: 2089, Scheme: "vless", Engine: EngineSingBox},
	{Proto: "hysteria2", Class: TransportClassQUICUDP, EnableKey: "hysteria2_enabled", PortKey: "hysteria2_port", DefaultPort: 8444, Scheme: "hysteria2", Engine: EngineSingBox},
	{Proto: "tuic", Class: TransportClassQUICUDP, EnableKey: "tuic_enabled", PortKey: "tuic_port", DefaultPort: 8445, Scheme: "tuic", Engine: EngineSingBox},
	{Proto: "shadowsocks", Class: TransportClassShadowsocksTCP, EnableKey: "shadowsocks_enabled", PortKey: "shadowsocks_port", DefaultPort: 8388, Scheme: "ss", Engine: EngineSingBox},
	{Proto: "shadowtls", Class: TransportClassShadowTLSTCP, EnableKey: "shadowtls_enabled", PortKey: "shadowtls_port", DefaultPort: 8446, Scheme: "ss", Engine: EngineSingBox},
	{Proto: "trojan", Class: TransportClassTrojanTLS, EnableKey: "trojan_enabled", PortKey: "trojan_port", DefaultPort: 8447, Scheme: "trojan", Engine: EngineSingBox},
	{Proto: "amneziawg", Class: TransportClassAmneziaWGUDP, EnableKey: "", PortKey: "", DefaultPort: 0, Scheme: "", Engine: EngineAmneziaWG},
}

// transportClasses is the canonical CLOSED transport-class vocabulary in audited
// order (the zero/unknown value is deliberately excluded — it is never valid on the
// wire). The registry covers exactly this set; TestTransportRegistry binds them.
var transportClasses = []TransportClass{
	TransportClassRealityTCP,
	TransportClassQUICUDP,
	TransportClassShadowsocksTCP,
	TransportClassShadowTLSTCP,
	TransportClassTrojanTLS,
	TransportClassAmneziaWGUDP,
	TransportClassXHTTPTLS,
	TransportClassWSTLS,
}

// regionBuckets is the canonical closed region vocabulary (Phase 1: only the
// zero-information "unspecified" bucket; widened only by a Phase-2 expansion).
var regionBuckets = []RegionBucket{
	RegionUnspecified,
}

// healthValues is the canonical closed advisory-health vocabulary. Phase-1 bundles
// must carry only HealthUnknown (Bundle.Validate enforces that); the others exist
// for the Phase-2 measurement track.
var healthValues = []HealthValue{
	HealthUnknown,
	HealthAlive,
	HealthDegraded,
}

// TransportRegistry returns a copy of the canonical proto registry in priority order.
// Callers may mutate the returned slice without affecting the source of truth.
func TransportRegistry() []ProtoDescriptor {
	out := make([]ProtoDescriptor, len(transportRegistry))
	copy(out, transportRegistry)
	return out
}

// ClassForProto returns the coarse transport class for a wire proto name, and ok=false
// (with TransportClassUnknown) when the proto is not in the registry. This is the
// Go-owned replacement for the shell `myc_bundle_class_of` case statement.
func ClassForProto(proto string) (TransportClass, bool) {
	for i := range transportRegistry {
		if transportRegistry[i].Proto == proto {
			return transportRegistry[i].Class, true
		}
	}
	return TransportClassUnknown, false
}

// TransportClasses returns a copy of the closed transport-class vocabulary in canonical order.
func TransportClasses() []TransportClass {
	out := make([]TransportClass, len(transportClasses))
	copy(out, transportClasses)
	return out
}

// RegionBuckets returns a copy of the closed region-bucket vocabulary in canonical order.
func RegionBuckets() []RegionBucket {
	out := make([]RegionBucket, len(regionBuckets))
	copy(out, regionBuckets)
	return out
}

// HealthValues returns a copy of the closed advisory-health vocabulary in canonical order.
func HealthValues() []HealthValue {
	out := make([]HealthValue, len(healthValues))
	copy(out, healthValues)
	return out
}

// operatorTunableKnobs are the operator-settable params that are NOT a per-proto enable/port toggle:
// the transport-shape knobs (paths / gRPC service name) and the coarse region bucket. They are
// deliberately NOT identity-derived, so an override may set them without pinning a secret/key stale.
var operatorTunableKnobs = []string{"xhttp_path", "xhttp_path_tls", "ws_path", "grpc_service_name", "region_bucket"}

// OperatorToggleKeys returns the CLOSED allowlist of params keys an operator may override: every
// params-toggled proto's *_enabled flag, then every *_port key (registry order), then the tunable
// knobs. Identity-derived fields (keys, secrets, node_address, cert paths, short_ids) are excluded by
// construction — only registry enable/port keys + the knob list are included — so an override can never
// pin them stale. This is the SINGLE source consumed by BOTH write_params (the override merge) and the
// auto-rotation executor (enable-key validation); the shell reads it from control/vocab.json (RP-0008
// P2), never restating it. Pure; deterministic order.
func OperatorToggleKeys() []string {
	out := make([]string, 0, len(transportRegistry)*2+len(operatorTunableKnobs))
	for i := range transportRegistry {
		if transportRegistry[i].EnableKey != "" {
			out = append(out, transportRegistry[i].EnableKey)
		}
	}
	for i := range transportRegistry {
		if transportRegistry[i].PortKey != "" {
			out = append(out, transportRegistry[i].PortKey)
		}
	}
	out = append(out, operatorTunableKnobs...)
	return out
}

// Vocab is the serialisable aggregate of every Go-owned control-plane vocabulary:
// the closed transport-class / region-bucket / advisory-health sets and the full
// proto registry. It is what `myceliumctl vocab` emits and the committed
// control/vocab.json mirrors; the shell renderer reads that file instead of keeping
// its own copies of these tables (RP-0008 P2).
type Vocab struct {
	Version            int               `json:"version"`              // schema version (NetworkStateVersion)
	TransportClasses   []TransportClass  `json:"transport_classes"`    // closed coarse-family vocabulary
	RegionBuckets      []RegionBucket    `json:"region_buckets"`       // closed region vocabulary (Phase 1: only "unspecified")
	HealthValues       []HealthValue     `json:"health_values"`        // closed advisory-health vocabulary
	OperatorToggleKeys []string          `json:"operator_toggle_keys"` // closed allowlist of operator-settable params keys
	Protos             []ProtoDescriptor `json:"protos"`               // canonical proto registry, priority order
}

// NewVocab returns the canonical Vocab built from the Go-owned registries. It is pure:
// no I/O, no network. Serialising it deterministically is the caller's job
// (encoding/json with this struct's fixed field order is stable).
func NewVocab() Vocab {
	return Vocab{
		Version:            NetworkStateVersion,
		TransportClasses:   TransportClasses(),
		RegionBuckets:      RegionBuckets(),
		HealthValues:       HealthValues(),
		OperatorToggleKeys: OperatorToggleKeys(),
		Protos:             TransportRegistry(),
	}
}
