// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strconv"
	"strings"
)

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
// ExposureTier ranks a transport by HOW EXPOSED IT IS TO DETECTION — not by how well it currently
// performs. Lower is safer, and the selection prefers the safest VIABLE shape: a riskier tier is reached
// only when nothing in a safer tier can carry the traffic (dead / reset / collapsing / not better than the
// incumbent). This is deliberately NOT the measured weight: a risky shape that happens to work today would
// otherwise out-rank a safe one, which is exactly backwards — the cost of a risky shape is not paid when it
// works, it is paid when it is classified, and by then it has also taught the observer what this node is.
//
// The ordering is the ADR-0010 per-transport reasoning made machine-readable; the one-line reasons live on
// each constant so a future edit has to argue with them rather than silently renumber.
type ExposureTier int

const (
	// ExposureBorrowedTLS — the handshake belongs to a REAL third-party site the node authenticates to
	// (REALITY's authenticated dest steal). An active probe reaches a genuine site. ADR-0010: "best
	// survivability against network degradation + active probing".
	ExposureBorrowedTLS ExposureTier = 1
	// ExposureCoveredTLS — a real TLS handshake to a real EXTERNAL cover host in front of the payload
	// (ShadowTLS v3). The outer layer answers active probing with someone else's certificate.
	ExposureCoveredTLS ExposureTier = 2
	// ExposureOwnCertTLS — genuine single-layer TLS terminated by the node's OWN certificate. Shape-wise
	// ordinary HTTPS, but the SNI/cert are server-attributable: it identifies THIS node, and every family
	// in this tier shares that one SNI (they fold to one block family — see e2e_recovery.go).
	ExposureOwnCertTLS ExposureTier = 3
	// ExposureQUIC — ordinary-looking QUIC/UDP, but UDP on a non-443 port is conspicuous where TCP/443 is
	// not, and whole networks excise UDP outright. Availability risk as much as detection risk.
	ExposureQUIC ExposureTier = 4
	// ExposureObfuscatedUDP — deliberately non-standard UDP that mimics nothing (AmneziaWG). The per-node
	// dialect means it is not matchable from the public repo, but it is still an unexplained UDP flow.
	ExposureObfuscatedUDP ExposureTier = 5
	// ExposureNoCover — high-entropy TCP with NO handshake cover at all (Shadowsocks-2022 standalone).
	// ADR-0010: "plain TCP shape without a TLS cover on its own". A classic flow-classifier target, and it
	// shares the node's IP with the strong shapes — the "taint" ADR-0010 rejected a wider set over. LAST
	// RESORT: valuable precisely because it is the only axis that survives a total TLS/QUIC failure.
	ExposureNoCover ExposureTier = 6
)

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
	Exposure    ExposureTier   `json:"exposure"`     // detection-exposure tier; lower = safer = preferred
}

// transportRegistry is the ordered canonical proto table. The order of the
// sing-box/xray rows is the renderer PRIORITY order (the historical MYC_SB_PROTOS
// ordering, lower index = preferred); amneziawg is appended because it is a
// separate UDP dataplane, not a sing-box inbound. Editing this slice is the ONLY
// place the proto->class/port/key/scheme/engine facts are defined.
var transportRegistry = []ProtoDescriptor{
	{Proto: "vless-reality-vision", Class: TransportClassRealityTCP, EnableKey: "vless_reality_vision_enabled", PortKey: "vless_reality_vision_port", DefaultPort: 443, Scheme: "vless", Engine: EngineSingBox, Exposure: ExposureBorrowedTLS},
	{Proto: "vless-reality-grpc", Class: TransportClassRealityTCP, EnableKey: "vless_reality_grpc_enabled", PortKey: "vless_reality_grpc_port", DefaultPort: 8443, Scheme: "vless", Engine: EngineSingBox, Exposure: ExposureBorrowedTLS},
	{Proto: "vless-reality-xhttp", Class: TransportClassRealityTCP, EnableKey: "vless_reality_xhttp_enabled", PortKey: "vless_reality_xhttp_port", DefaultPort: 2096, Scheme: "vless", Engine: EngineSingBox, Exposure: ExposureBorrowedTLS},
	{Proto: "vless-xhttp-tls", Class: TransportClassXHTTPTLS, EnableKey: "vless_xhttp_tls_enabled", PortKey: "vless_xhttp_tls_port", DefaultPort: 2087, Scheme: "vless", Engine: EngineXray, Exposure: ExposureOwnCertTLS},
	{Proto: "vless-ws-tls", Class: TransportClassWSTLS, EnableKey: "vless_ws_tls_enabled", PortKey: "vless_ws_tls_port", DefaultPort: 2089, Scheme: "vless", Engine: EngineSingBox, Exposure: ExposureOwnCertTLS},
	{Proto: "hysteria2", Class: TransportClassQUICUDP, EnableKey: "hysteria2_enabled", PortKey: "hysteria2_port", DefaultPort: 8444, Scheme: "hysteria2", Engine: EngineSingBox, Exposure: ExposureQUIC},
	{Proto: "tuic", Class: TransportClassQUICUDP, EnableKey: "tuic_enabled", PortKey: "tuic_port", DefaultPort: 8445, Scheme: "tuic", Engine: EngineSingBox, Exposure: ExposureQUIC},
	{Proto: "shadowsocks", Class: TransportClassShadowsocksTCP, EnableKey: "shadowsocks_enabled", PortKey: "shadowsocks_port", DefaultPort: 8388, Scheme: "ss", Engine: EngineSingBox, Exposure: ExposureNoCover},
	{Proto: "shadowtls", Class: TransportClassShadowTLSTCP, EnableKey: "shadowtls_enabled", PortKey: "shadowtls_port", DefaultPort: 8446, Scheme: "ss", Engine: EngineSingBox, Exposure: ExposureCoveredTLS},
	{Proto: "trojan", Class: TransportClassTrojanTLS, EnableKey: "trojan_enabled", PortKey: "trojan_port", DefaultPort: 8447, Scheme: "trojan", Engine: EngineSingBox, Exposure: ExposureOwnCertTLS},
	{Proto: "amneziawg", Class: TransportClassAmneziaWGUDP, EnableKey: "", PortKey: "", DefaultPort: 0, Scheme: "", Engine: EngineAmneziaWG, Exposure: ExposureObfuscatedUDP},
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
var operatorTunableKnobs = []string{"xhttp_path", "xhttp_path_tls", "ws_path", "grpc_service_name", "region_bucket", "client_fingerprint",
	// hysteria2 port hopping. WITHOUT these two the feature is not merely off by default — it is
	// UNSETTABLE: write_params regenerates params.json from identity + canonical ports, and
	// merge_operator_overrides honours only the keys in this allowlist, so a hand-set range was
	// erased on the very next converge (every timer tick). The capability shipped, the gate for it
	// passed, and no operator could turn it on.
	"hysteria2_hop_ports", "hysteria2_hop_interval"}

// DefaultClientFingerprint is the uTLS ClientHello preset the client render + the node-local verify/probe
// use unless an operator sets client_fingerprint. It is a REAL, current browser preset.
const DefaultClientFingerprint = "chrome"

// clientFingerprints is the CLOSED vocabulary of client uTLS presets an operator may set (RP-0015 —
// fingerprint-adaptivity): real, current browser fingerprints only, DefaultClientFingerprint first.
// `random`/`randomized` are DELIBERATELY excluded — a unique per-connection ClientHello is itself an
// entropy tell, the opposite of blending in — so a rotation (RP-0015 increment B) only ever moves WITHIN
// this set, never to a randomiser.
var clientFingerprints = []string{"chrome", "firefox", "edge", "safari", "ios", "android"}

// ClientFingerprints returns a copy of the closed client-fingerprint vocabulary (deterministic order).
func ClientFingerprints() []string {
	out := make([]string, len(clientFingerprints))
	copy(out, clientFingerprints)
	return out
}

// ValidClientFingerprint reports whether s is a member of the closed client-fingerprint vocabulary. It is
// the single validator the render + the operator-override merge use; an unknown value fails closed.
func ValidClientFingerprint(s string) bool {
	for _, f := range clientFingerprints {
		if f == s {
			return true
		}
	}
	return false
}

// DefaultHysteria2HopInterval is how often a hopping client moves to another port in its range. It is a
// sing-box duration string; the value is a compromise, not a tuning result — long enough that the hop is
// not itself a rhythm, short enough to leave a blocked port quickly.
const DefaultHysteria2HopInterval = "30s"

// ValidHysteria2HopRange reports whether s is a usable hysteria2 port-hop range ("LO:HI", 1024 <= LO < HI
// <= 65535). Empty is NOT valid here — empty means "no hopping", which callers check separately.
//
// THIS EXISTS BECAUSE TWO HALVES HAVE TO AGREE. The range is a promise the CLIENT CONFIG makes and the
// FIREWALL keeps: the subscription renderer emits `server_ports` and reconcile_hy2_hop_nat installs the
// nat/PREROUTING REDIRECT that delivers it. The shell half validated (a malformed value yields no rule);
// the renderer half did not. So an operator typo produced client configs advertising a range with NO rule
// behind it — every hysteria2 client on that node hopping to ports nothing serves, while the node's own
// checks stayed green because verify_post_apply is firewall-blind. Both halves now decide with the same
// predicate, and tests/conformance/hy2_hop_halves_agree.sh drives them against one value table.
//
// Deliberately hand-parsed rather than regex: this decides whether a rule is written into a firewall, and
// the shell peer is hand-parsed too — the two must be readable side by side to stay in step.
func ValidHysteria2HopRange(s string) bool {
	lo, hi, ok := parseHysteria2HopRange(s)
	return ok && lo >= 1024 && hi <= 65535 && lo < hi
}

// parseHysteria2HopRange splits "LO:HI" into two integers. ok is false for anything that is not exactly
// two all-digit fields — including the empty string, a bare port, and "1:2:3".
func parseHysteria2HopRange(s string) (lo, hi int, ok bool) {
	i := strings.IndexByte(s, ':')
	if i <= 0 || i == len(s)-1 {
		return 0, 0, false
	}
	a, b := s[:i], s[i+1:]
	if strings.ContainsRune(b, ':') {
		return 0, 0, false
	}
	for _, f := range []string{a, b} {
		if len(f) > 5 {
			return 0, 0, false
		}
		for _, c := range f {
			if c < '0' || c > '9' {
				return 0, 0, false
			}
		}
	}
	lo, err := strconv.Atoi(a)
	if err != nil {
		return 0, 0, false
	}
	hi, err = strconv.Atoi(b)
	if err != nil {
		return 0, 0, false
	}
	return lo, hi, true
}

// NormalizeClientFingerprint returns s if it is a valid closed-vocab preset, else DefaultClientFingerprint
// (fail-safe: an empty or unknown value renders as the default, never as an invalid uTLS token).
func NormalizeClientFingerprint(s string) string {
	if ValidClientFingerprint(s) {
		return s
	}
	return DefaultClientFingerprint
}

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
	ClientFingerprints []string          `json:"client_fingerprints"`  // closed client uTLS-preset vocabulary (RP-0015); [0] is the default
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
		ClientFingerprints: ClientFingerprints(),
		Protos:             TransportRegistry(),
	}
}
