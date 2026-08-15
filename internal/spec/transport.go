// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"regexp"
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
	// ServesUDP is whether this proto occupies a UDP port on the host. DECLARED, not inferred from the
	// class: shadowsocks-2022 is class shadowsocks-TCP and nonetheless serves UDP too (harden_ufw opens
	// it in the udp family), so deriving the set from class names silently omitted it — and the set is
	// what decides whether a hysteria2 hop range would swallow another family.
	ServesUDP bool `json:"serves_udp"`
	// SharedSecretAuth is whether this proto authenticates every client against ONE node-wide secret
	// rather than per-person material. DECLARED for the same reason ServesUDP is: it is a property of
	// how the renderer builds the user list, not of the class, and inferring it was how it stayed
	// invisible.
	//
	// It exists because a node cannot revoke one person from a family whose credential everyone holds.
	// Measured on a live node (Audit-0012): two clients' emitted subscriptions are byte-identical on
	// hysteria2, shadowsocks and shadowtls. In control/lib/render_singbox.sh the four families below
	// build users as `(.password // $pw)` with $pw a node-wide key, while tuic uses
	// `(.password // .id)` — falling back to that client's own UUID — and the vless families key on the
	// UUID directly.
	//
	// ADR-0040 §2.1 decides this must change: a fungi serves several people, so credentials are
	// per-person. Until that RP lands, this flag is what lets `--revoke` refuse to claim a person was
	// removed when they were not, instead of printing a guarantee it has not established.
	SharedSecretAuth bool `json:"shared_secret_auth"`
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
	{Proto: "hysteria2", Class: TransportClassQUICUDP, EnableKey: "hysteria2_enabled", PortKey: "hysteria2_port", DefaultPort: 8444, Scheme: "hysteria2", Engine: EngineSingBox, Exposure: ExposureQUIC, ServesUDP: true, SharedSecretAuth: true},
	{Proto: "tuic", Class: TransportClassQUICUDP, EnableKey: "tuic_enabled", PortKey: "tuic_port", DefaultPort: 8445, Scheme: "tuic", Engine: EngineSingBox, Exposure: ExposureQUIC, ServesUDP: true},
	{Proto: "shadowsocks", Class: TransportClassShadowsocksTCP, EnableKey: "shadowsocks_enabled", PortKey: "shadowsocks_port", DefaultPort: 8388, Scheme: "ss", Engine: EngineSingBox, Exposure: ExposureNoCover, ServesUDP: true, SharedSecretAuth: true},
	{Proto: "shadowtls", Class: TransportClassShadowTLSTCP, EnableKey: "shadowtls_enabled", PortKey: "shadowtls_port", DefaultPort: 8446, Scheme: "ss", Engine: EngineSingBox, Exposure: ExposureCoveredTLS, SharedSecretAuth: true},
	{Proto: "trojan", Class: TransportClassTrojanTLS, EnableKey: "trojan_enabled", PortKey: "trojan_port", DefaultPort: 8447, Scheme: "trojan", Engine: EngineSingBox, Exposure: ExposureOwnCertTLS, SharedSecretAuth: true},
	{Proto: "amneziawg", Class: TransportClassAmneziaWGUDP, EnableKey: "", PortKey: "", DefaultPort: 0, Scheme: "", Engine: EngineAmneziaWG, Exposure: ExposureObfuscatedUDP, ServesUDP: true},
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

// --- hysteria2 port hopping: the ONE place the rule and its numbers live (ADR-0038) ---------------
//
// A hop range is a promise the CLIENT CONFIG makes and the FIREWALL keeps: the subscription renderer
// emits `server_ports`, and a nat/PREROUTING REDIRECT delivers that range onto the single port the
// hysteria2 inbound holds. Three consumers therefore judge one value — this package, the shell client
// renderer, and the firewall reconcile — and when they disagree the node enters a state NOTHING on it
// can observe: clients hop across ports nothing serves while verify_post_apply reports healthy,
// because it checks the service, the bind and a LOOPBACK handshake, and loopback never traverses
// PREROUTING.
//
// So the policy is expressed exactly once, here, and the numbers are EMITTED into control/vocab.json
// (Vocab.ParamsValidation) for the shell consumers to compare against. A shell consumer may compare;
// it may not re-derive. See ADR-0038 and development.md §2.2 item 8.

// DefaultHysteria2HopInterval is how often a hopping client moves to another port in its range. It is a
// sing-box duration string. BASIS: the hop must not become a rhythm of its own (a fixed short period is
// a timing signature), and it must not be so long that a blocked port holds the client for minutes. 30s
// sits above the ~10s scale at which a periodic rebind is conspicuous and below the urltest interval
// (aggregate.go urltestInterval), so a hop never races the client's own re-selection.
const DefaultHysteria2HopInterval = "30s"

// PortRangeBounds is an inclusive admissible port window. It exists as a type so the bounds can be
// EMITTED into the vocab artifact rather than restated by each consumer.
type PortRangeBounds struct {
	Min int `json:"min"` // lowest admissible port
	Max int `json:"max"` // highest admissible port
}

// hysteria2HopPortBounds are the bounds a hop range must fall inside.
//
// BASIS for Min: 1024 is the unprivileged floor. Below it a range would demand CAP_NET_BIND_SERVICE
// semantics the REDIRECT does not need and would overlap the well-known range where an unexplained UDP
// flow is most conspicuous. BASIS for Max: 65535 is the protocol maximum.
var hysteria2HopPortBounds = PortRangeBounds{Min: 1024, Max: 65535}

// Hysteria2HopPortBounds returns the admissible hop-range window (a copy; the bounds are immutable).
func Hysteria2HopPortBounds() PortRangeBounds { return hysteria2HopPortBounds }

// maxPortFieldDigits caps one field of a port range. BASIS: 65535 is five digits, so anything longer is
// not a port however it is padded. It exists to make zero-padded and absurdly long fields REFUSED rather
// than silently normalised, and it is emitted so every consumer applies the same cap.
const maxPortFieldDigits = 5

// hysteria2HopIntervalPattern is the ERE an accepted hop interval must match: a positive integer with a
// Go/sing-box duration unit, e.g. `30s`, `2m`, `1h`. Deliberately NOT the full Go duration grammar —
// this value becomes a client-config field and a timing parameter, and the compound forms Go accepts
// (`1h2m3s`) buy nothing here while widening what has to be agreed on by two languages.
const hysteria2HopIntervalPattern = `^[1-9][0-9]{0,4}(ms|s|m|h)$`

// ValidHysteria2HopInterval reports whether s is an acceptable hop period. Empty is NOT valid; callers
// substitute DefaultHysteria2HopInterval when the operator sets nothing.
//
// A duration is structured, so ARCHITECTURE's ownership rule covers it: without this it was
// operator-settable and judged by nobody, and an unparseable value reached both the client config and
// the server render, where sing-box refuses the whole document — a converge that fails on every tick
// with a message about JSON rather than about the knob the operator actually mistyped.
func ValidHysteria2HopInterval(s string) bool {
	return hysteria2HopIntervalRe.MatchString(s)
}

var hysteria2HopIntervalRe = regexp.MustCompile(hysteria2HopIntervalPattern)

// UDPPortKeys returns the params keys naming ports this node serves over UDP, in registry order.
// Derived from the registry's ServesUDP flag, never hand-listed: a transport added with that flag joins
// the set automatically, which is the point — the collision check must not go stale the day a family is
// added. AmneziaWG carries the flag but no params port key (its port lives in the awg subsystem), so it
// is absent here by construction and the firewall reconcile resolves it separately; that split is
// deliberate and is the only place the two halves legitimately differ.
func UDPPortKeys() []string {
	out := make([]string, 0, 4)
	for i := range transportRegistry {
		d := transportRegistry[i]
		if d.PortKey == "" {
			continue
		}
		if d.ServesUDP {
			out = append(out, d.PortKey)
		}
	}
	return out
}

// Hysteria2HopRangeCollisions returns the UDP port keys whose configured value falls INSIDE the given
// hop range, excluding the hysteria2 port the range is redirected onto. Empty means the range is safe.
//
// A REDIRECT covers every WAN-inbound UDP packet in its range, so a range containing another served UDP
// port sends that family's traffic to the hysteria2 listener — and nothing on the node reports it,
// because every reach anchor is 127.0.0.1 and loopback never traverses a `-i <wan>` PREROUTING rule. The
// firewall reconcile refuses such a range; this is the RENDERER's half, so a client is never handed a
// range the node has already decided not to make real (Audit-0010 F-001, the deferred leg).
func Hysteria2HopRangeCollisions(rangeStr string, servedPort int, portOf func(key string) (int, bool)) []string {
	lo, hi, ok := parseHysteria2HopRange(rangeStr)
	if !ok || portOf == nil {
		return nil
	}
	var clash []string
	for _, k := range UDPPortKeys() {
		p, ok := portOf(k)
		if !ok || p == servedPort {
			continue
		}
		if p >= lo && p <= hi {
			clash = append(clash, k)
		}
	}
	return clash
}

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
	b := hysteria2HopPortBounds
	return ok && lo >= b.Min && hi <= b.Max && lo < hi
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
		if len(f) > maxPortFieldDigits {
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
	// ParamsValidation carries the BOUNDS AND DEFAULTS a shell consumer needs in order to judge a
	// structured operator-settable knob without re-deriving the rule (ADR-0038). It is emitted, not
	// restated: a consumer compares against these numbers; the policy that produced them lives in this
	// package and nowhere else.
	ParamsValidation ParamsValidationVocab `json:"params_validation"`
	// BlockFamilies maps each transport class to the family that blocks WITH it — the equivalence the
	// RP-0013 ">= 2 independent families" floor is counted over. Emitted because the shell bundle
	// renderer is the one that actually runs on a node (control/myceliumctl is the shell tool;
	// myceliumctl-go is installed non-load-bearing), and it must COMPARE this rather than re-derive it
	// (ADR-0038). Two tools disagreeing about whether a bundle is publishable is exactly the
	// duplicate-truth defect §2.2 item 8 forbids — measured in Audit-0012, where the Go renderer refused
	// a single-family bundle and the shell one emitted it at rc=0.
	BlockFamilies map[string]string `json:"block_families"`
	// IndependentFamilyFloor is how many distinct block families a served bundle must span.
	IndependentFamilyFloor int `json:"independent_family_floor"`
	// TransportDirections and SuppressionEvidence are the closed sets a suppression lease is written in.
	// Emitted for the same reason the block families are: the shell re-checks a lease file it did not
	// write — hand-edited, restored from a backup, produced by an older spine — and a hand-kept copy of
	// these two lists in a shell case statement would drift from the Go rule the moment either grows.
	TransportDirections []TransportDirection  `json:"transport_directions"`
	SuppressionEvidence []SuppressionEvidence `json:"suppression_evidence"`
}

// ParamsValidationVocab is the emitted half of the params-knob validation contract. Additive: a shell
// reading an older vocab finds it absent and must FAIL CLOSED — no bounds means no range, which is the
// unconfigured state (no `server_ports` emitted, no REDIRECT installed), never a permissive default.
type ParamsValidationVocab struct {
	// Hysteria2HopPorts is the admissible window for the hysteria2 port-hop range (`LO:HI`).
	Hysteria2HopPorts PortRangeBounds `json:"hysteria2_hop_ports"`
	// MaxPortFieldDigits caps the digits in one field of a port range. It is EMITTED because it is
	// policy, not an implementation detail: without it the shell accepted `001024:065535` and
	// `0000000000000000000000000000002000:3000` — numerically in bounds under `test -ge`, which parses
	// base 10 — while this package rejected every one (Audit-0010 F-006). Two answers to one input is
	// the divergence ADR-0038 exists to remove, and it survived the first collapse because only the
	// NUMBERS were emitted and the SHAPE was left restated on each side.
	MaxPortFieldDigits int `json:"max_port_field_digits"`
	// Hysteria2HopInterval is the default hop period when the operator sets a range but no interval.
	Hysteria2HopInterval string `json:"hysteria2_hop_interval_default"`
	// UDPPortKeys are the params keys naming a port this node serves over UDP. EMITTED because deciding
	// WHICH keys those are is policy (it is derived from the registry's transport classes plus the
	// AmneziaWG dataplane, which is not a params-toggled proto), while checking whether a number falls
	// inside a range is not. A hop range that CONTAINS one of these ports makes the REDIRECT swallow that
	// family's traffic, and no check on the node can see it: the reach anchors are loopback and never
	// traverse a `-i <wan>` PREROUTING rule (Audit-0010 F-001).
	UDPPortKeys []string `json:"udp_port_keys"`
	// Hysteria2HopIntervalPattern is an ERE every accepted hop interval must match. A duration cannot be
	// bounded by two integers, so the owner emits the SHAPE instead — same principle, different carrier.
	// Until this existed the interval was operator-settable and judged by nobody (Audit-0010 F-005),
	// contradicting the ownership rule ARCHITECTURE gained in the very same commit range.
	Hysteria2HopIntervalPattern string `json:"hysteria2_hop_interval_pattern"`
}

// NewVocab returns the canonical Vocab built from the Go-owned registries. It is pure:
// no I/O, no network. Serialising it deterministically is the caller's job
// (encoding/json with this struct's fixed field order is stable).
func NewVocab() Vocab {
	return Vocab{
		Version:                NetworkStateVersion,
		TransportClasses:       TransportClasses(),
		RegionBuckets:          RegionBuckets(),
		HealthValues:           HealthValues(),
		OperatorToggleKeys:     OperatorToggleKeys(),
		ClientFingerprints:     ClientFingerprints(),
		Protos:                 TransportRegistry(),
		BlockFamilies:          blockFamilyVocab(),
		IndependentFamilyFloor: IndependentFamilyFloor,
		TransportDirections:    ValidDirections(),
		SuppressionEvidence:    ValidEvidence(),
		ParamsValidation: ParamsValidationVocab{
			Hysteria2HopPorts:           Hysteria2HopPortBounds(),
			MaxPortFieldDigits:          maxPortFieldDigits,
			UDPPortKeys:                 UDPPortKeys(),
			Hysteria2HopInterval:        DefaultHysteria2HopInterval,
			Hysteria2HopIntervalPattern: hysteria2HopIntervalPattern,
		},
	}
}
