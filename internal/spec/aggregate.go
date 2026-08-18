// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"bytes"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"encoding/json"
)

// OutboundFromLink parses an opaque client share-link (the same schemes ShareLink emits — vless://,
// hysteria2://, tuic://, ss://, trojan://) into a sing-box client OUTBOUND, the inverse of ShareLink and
// the Go-owned port of the shell `myc_agg_link_outbound` (control/lib/render_aggregate.sh), RP-0008 P3-c.
// It returns the compact-JSON outbound (byte-identical to the shell jq emission — the
// aggregate_outbound_go_equiv gate pins this), or nil when the shell yields null: a ShadowTLS ss-link
// (the Link carries only the inner SS material, never the v3 handshake password/version, so the detour
// outbound cannot be faithfully reconstructed — fail closed) or any unknown scheme. Pure; no network, no
// eval — every value is decoded from the string. tag is the already-namespaced outbound tag to stamp on.
func OutboundFromLink(tag, link string) (json.RawMessage, error) {
	v, err := outboundValue(tag, link)
	if err != nil || v == nil {
		return nil, err
	}
	// Marshal WITHOUT HTML escaping so '&' / '<' / '>' inside a value stay literal (matching jq's
	// compact output); Encode appends a newline, which the raw outbound must not carry.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return json.RawMessage(bytes.TrimRight(buf.Bytes(), "\n")), nil
}

// OutboundSkipReason names why a link must not become a lone sing-box outbound, or "" when it may.
//
// Two distinct cases, and neither is a parse failure:
//   - xhttp: sing-box has no such transport (Xray-only, ADR-0032). An outbound carrying it makes sing-box
//     reject the WHOLE profile, so it is worse than useless in a client config.
//   - ShadowTLS: a PAIR (outer shadowsocks + shadowtls detour) that one outbound cannot express.
//
// Exported because the single-link CLI verb must REFUSE with a cause an operator can act on. The aggregate
// renderers still emit xhttp — see the note at its case — which is a recorded open defect, not a use of
// this function.
func OutboundSkipReason(link string) string {
	main := uriBefore(link, "#")
	scheme := uriBefore(main, "://")
	q := parseQuery(uriAfter(uriAfter(main, "://"), "?"))
	if scheme == "vless" && q["type"] == "xhttp" {
		return "it carries the xhttp transport, which sing-box cannot load — an Xray-only carrier (ADR-0032). A sing-box client profile must not contain it: one such outbound makes sing-box reject the WHOLE profile"
	}
	if scheme == "ss" && q["plugin"] == "shadow-tls" {
		return "ShadowTLS is a pair — an outer shadowsocks outbound whose detour is the shadowtls half — which one outbound cannot express. Render it through `subscription`, which emits both halves"
	}
	return ""
}

// outboundValue is OutboundFromLink's typed core: it returns the outbound as a typed struct (an aggVless /
// aggHy2 / ... value), or nil for the fail-closed null cases (a ShadowTLS ss-link or an unknown scheme).
// RenderAggregate uses the typed value directly so the merged profile indents uniformly like `jq .`.
func outboundValue(tag, link string) (any, error) {
	main := uriBefore(link, "#")
	scheme := uriBefore(main, "://")
	rest := uriAfter(main, "://")
	authority := uriBefore(rest, "?")
	q := parseQuery(uriAfter(rest, "?"))

	var userinfoRaw, hostport string
	if strings.Contains(authority, "@") {
		userinfoRaw = uriBefore(authority, "@")
		hostport = uriAfter(authority, "@")
	} else {
		hostport = authority
	}
	host := uriDecode(uriBefore(hostport, ":"))
	port := 0
	if n, err := strconv.Atoi(uriAfter(hostport, ":")); err == nil { // C28: hostnames only, no IPv6 literal
		port = n
	}
	ui := uriDecode(userinfoRaw) // decoded userinfo (vless uuid / hy2,trojan password)

	var v any
	switch scheme {
	case "vless":
		// RP-0015 / Audit-0008 S2-4: the fp is carried by the parsed share-link query (which the render
		// splices from the operator's client_fingerprint); the default only applies to a link that omits fp.
		// Normalize against the closed vocab so a hand-edited/foreign link cannot splice an invalid uTLS
		// token (byte-twin of the shell's `normfp` in render_aggregate.sh).
		tls := aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: NormalizeClientFingerprint(qd(q, "fp", DefaultClientFingerprint))}}
		if q["security"] == "reality" {
			tls.Reality = &aggReality{Enabled: true, PublicKey: q["pbk"], ShortID: q["sid"]}
		} else {
			tls.ALPN = strings.Split(qd(q, "alpn", "h2,http/1.1"), ",")
		}
		ob := aggVless{Type: "vless", Tag: tag, Server: host, ServerPort: port, UUID: ui,
			Flow: q["flow"], PacketEncoding: "xudp", TLS: tls}
		switch q["type"] { // network transport; tcp (or unset) carries no transport block
		case "grpc":
			ob.Transport = &aggTransport{Type: "grpc", ServiceName: qd(q, "serviceName", "grpc")}
		case "xhttp":
			// STILL RENDERED HERE, and that is a KNOWN OPEN DEFECT rather than an endorsement.
			//
			// sing-box has no `xhttp` transport — it is an Xray-only carrier (ADR-0032) — so a sing-box
			// profile containing this outbound fails to load ENTIRELY: `decode config: outbounds[N].
			// transport: unknown transport type: xhttp`. One un-dialable member costs the client every
			// other member too. MEASURED 2026-08-17.
			//
			// It is not skipped here because skipping changes a contract this renderer shares with the
			// shell one: render_aggregate.sh DIES on a member that yields no outbound (it is how the
			// ShadowTLS pair is refused), and both are pinned byte-for-byte by aggregate_*_go_equiv.sh.
			// Turning "cannot render" into "silently drop" is a design change across two producers and
			// their equivalence gates, not a patch. Tracked; the node's own subscription renderer already
			// excludes xhttp-tls, so no client-facing path is affected today.
			//
			// What IS fixed: OutboundSkipReason names it, and the single-link CLI verb refuses instead of
			// handing back a config nothing can load.
			ob.Transport = &aggTransport{Type: "xhttp", Path: qd(q, "path", "/")}
		case "ws":
			ob.Transport = &aggTransport{Type: "ws", Path: qd(q, "path", "/ws"),
				Headers: &aggWSHeaders{Host: qd2(q, "host", "sni", "")}}
		}
		v = ob
	case "hysteria2":
		// QUIC uTLS: a separate handshake axis from the REALITY/TLS client fingerprint; hy2/tuic share-links
		// carry no fp, so the RP-0015 client_fingerprint knob deliberately does not reach here (fp-static).
		v = aggHy2{Type: "hysteria2", Tag: tag, Server: host, ServerPort: port, Password: ui,
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: "chrome"},
				ALPN: strings.Split(qd(q, "alpn", "h3"), ",")}}
	case "tuic":
		// QUIC uTLS: separate handshake axis (fp-static; see hysteria2).
		v = aggTuic{Type: "tuic", Tag: tag, Server: host, ServerPort: port,
			UUID: uriDecode(uriBefore(userinfoRaw, ":")), Password: uriDecode(uriAfter(userinfoRaw, ":")),
			CongestionControl: qd(q, "congestion_control", "bbr"),
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: "chrome"},
				ALPN: strings.Split(qd(q, "alpn", "h3"), ",")}}
	case "ss":
		if q["plugin"] == "shadow-tls" { // fail closed: inner-only material, cannot rebuild the v3 detour
			return nil, nil
		}
		v = aggSS{Type: "shadowsocks", Tag: tag, Server: host, ServerPort: port,
			Method: uriDecode(uriBefore(userinfoRaw, ":")), Password: uriDecode(uriAfter(userinfoRaw, ":"))}
	case "trojan":
		v = aggTrojan{Type: "trojan", Tag: tag, Server: host, ServerPort: port, Password: ui,
			TLS: aggTLS{Enabled: true, ServerName: q["sni"], UTLS: aggUTLS{Enabled: true, Fingerprint: NormalizeClientFingerprint(qd(q, "fp", DefaultClientFingerprint))},
				ALPN: strings.Split(qd(q, "alpn", "h2,http/1.1"), ",")}}
	default:
		return nil, nil
	}
	return v, nil
}

// --- outbound shapes (field order mirrors the shell jq construction order; omitempty drops the keys jq's
// conditional `+ {}` / `// `-defaulted branches omit, so the compact JSON is byte-identical). -----------

type aggUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint"`
}
type aggReality struct {
	Enabled   bool   `json:"enabled"`
	PublicKey string `json:"public_key"`
	ShortID   string `json:"short_id"`
}
type aggTLS struct {
	Enabled    bool        `json:"enabled"`
	ServerName string      `json:"server_name"`
	UTLS       aggUTLS     `json:"utls"`
	ALPN       []string    `json:"alpn,omitempty"`    // tls (own-cert) branch only
	Reality    *aggReality `json:"reality,omitempty"` // reality branch only
}
type aggWSHeaders struct {
	Host string `json:"Host"`
}
type aggTransport struct {
	Type        string        `json:"type"`
	ServiceName string        `json:"service_name,omitempty"` // grpc
	Path        string        `json:"path,omitempty"`         // xhttp/ws
	Headers     *aggWSHeaders `json:"headers,omitempty"`      // ws
}
type aggVless struct {
	Type           string        `json:"type"`
	Tag            string        `json:"tag"`
	Server         string        `json:"server"`
	ServerPort     int           `json:"server_port"`
	UUID           string        `json:"uuid"`
	Flow           string        `json:"flow"`
	PacketEncoding string        `json:"packet_encoding"`
	TLS            aggTLS        `json:"tls"`
	Transport      *aggTransport `json:"transport,omitempty"`
}
type aggHy2 struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Password   string `json:"password"`
	TLS        aggTLS `json:"tls"`
}
type aggTuic struct {
	Type              string `json:"type"`
	Tag               string `json:"tag"`
	Server            string `json:"server"`
	ServerPort        int    `json:"server_port"`
	UUID              string `json:"uuid"`
	Password          string `json:"password"`
	CongestionControl string `json:"congestion_control"`
	TLS               aggTLS `json:"tls"`
}
type aggSS struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Method     string `json:"method"`
	Password   string `json:"password"`
}
type aggTrojan struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
	Password   string `json:"password"`
	TLS        aggTLS `json:"tls"`
}

// --- pure-string URI helpers (match the shell jq before/after/urldecode/query_to_obj exactly) ----------

// uriBefore returns everything before the FIRST sep (or the whole string if sep is absent) — jq `before`.
func uriBefore(s, sep string) string {
	if i := strings.Index(s, sep); i >= 0 {
		return s[:i]
	}
	return s
}

// uriAfter returns everything after the FIRST sep (or "" if sep is absent) — jq `after`.
func uriAfter(s, sep string) string {
	if i := strings.Index(s, sep); i >= 0 {
		return s[i+len(sep):]
	}
	return ""
}

// uriDecode is the inverse of uriEncode (jq urldecode): split on "%", keep the first chunk literal, and
// for each later chunk turn a leading two hex digits into the byte they encode (rest literal), else keep
// the stray "%" literal. Byte-wise.
func uriDecode(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	parts := strings.Split(s, "%")
	var b strings.Builder
	b.WriteString(parts[0])
	for _, p := range parts[1:] {
		if len(p) >= 2 && isHex(p[0]) && isHex(p[1]) {
			b.WriteByte(hexNibble(p[0])<<4 | hexNibble(p[1]))
			b.WriteString(p[2:])
		} else {
			b.WriteByte('%')
			b.WriteString(p)
		}
	}
	return b.String()
}

func isHex(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
func hexNibble(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	default:
		return c - 'A' + 10
	}
}

// parseQuery parses "k=v&k2=v2" into a map (last value wins, matching jq `add`). Keys are
// producer-controlled literals (never encoded); only the VALUE is percent-decoded. Empty values (k=) are
// preserved. Empty input -> empty map (jq query_to_obj).
func parseQuery(s string) map[string]string {
	m := map[string]string{}
	if s == "" {
		return m
	}
	for _, part := range strings.Split(s, "&") {
		if part == "" {
			continue
		}
		m[uriBefore(part, "=")] = uriDecode(uriAfter(part, "="))
	}
	return m
}

// qd returns m[key] when the key is PRESENT (even an empty value) and def only when it is ABSENT — jq's
// `($q.k // "def")` (the `//` operator defaults on null/absent, never on a present empty string). The
// query map has no entry for an absent param, so presence == ok.
func qd(m map[string]string, key, def string) string {
	if v, ok := m[key]; ok {
		return v
	}
	return def
}

// qd2 is qd with a second fallback key before the literal default (jq `($q.a // $q.b // "def")`).
func qd2(m map[string]string, a, b, def string) string {
	if v, ok := m[a]; ok {
		return v
	}
	if v, ok := m[b]; ok {
		return v
	}
	return def
}

// --- aggregate: fold M per-node Bundles -> one client sing-box profile (RP-0008 P3-c part 2) ----------

// AggregateInput is one of the operator's own nodes for the client-side merge: a parsed distribution
// Bundle plus the LABEL that namespaces its outbound tags so tags from different nodes never collide.
type AggregateInput struct {
	Bundle Bundle
	Label  string
}

// MYC_URLTEST_* single source with render_singbox.sh (C22 anti-flapping hysteresis for the cross-node
// auto-switch); the probe URL is the same generate_204 endpoint the subscription path uses.
const (
	// 90s, matching the node's own rotate tick, so the system has ONE control period instead of two
	// unrelated ones. MEASURED at the old 5m: a client whose selected member's port was DROPped stayed
	// completely dead for 276 seconds and only then moved to a sibling — sing-box's urltest re-selects on
	// its interval and nothing else, so the interval IS the blackout. An outage shorter than the interval
	// produced no failover at all.
	//
	// The interval also bounds recovery from a block the NODE CANNOT SEE, which is the case this product
	// exists for: there the client's own re-test is the entire recovery mechanism and no node-side
	// decision helps. That is what argues for the shorter period rather than the probe budget.
	//
	// MEASURED AGAIN AFTER THE CHANGE, same fault, same vantage: 169s of blackout instead of 276s. NOT
	// 90s — the interval governs how often the group RE-TESTS, and the re-test itself must time out
	// before the selected member is abandoned. sing-box exposes no per-test timeout (the urltest option
	// surface is interval / tolerance / idle_timeout / interrupt_exist_connections, verified against the
	// 1.13.13 binary), so ~169s is close to the floor this mechanism can reach.
	//
	// The cost is probe regularity: one HTTPS GET per member per interval. idle_timeout (30m) is what
	// bounds it — the group stops testing when nothing is using the tunnel, so an idle client is not a
	// heartbeat.
	urltestInterval    = "90s"
	urltestTolerance   = 150
	urltestIdleTimeout = "30m"
	urltestURL         = "https://www.gstatic.com/generate_204"
)

// RenderAggregate folds >=2 per-node Bundles into ONE sing-box client profile — the Go port of the shell
// myc_render_aggregate. Each input's endpoints become namespaced client outbounds ("<label>.<tag-without-
// mycelium-prefix>", parsed via outboundValue), then ONE urltest "auto" over all of them, ONE selector
// "mycelium" (default "auto"), then direct + block. LOCAL-only, pure (no network). Fail-closed throughout:
// ASCII labels only, unique labels, a recognised scheme consistent with the declared transport_class, a
// ShadowTLS link refused, port in 1..65535. Byte-identical to the shell (aggregate_render_go_equiv pins it).
// AggregateReport is what a fold could not represent, and what survived. Returned alongside the profile so
// a caller can TELL the operator which members were left out — a client quietly missing a transport it was
// told it had is precisely the defect class this project exists to remove.
type AggregateReport struct {
	Dropped  []string // "node/tag (why)" for each member this fold could not represent
	Families []string // the distinct block families the surviving profile spans
}

// RenderAggregate folds >=2 bundles into one client profile. Kept for callers that do not need the report.
func RenderAggregate(inputs []AggregateInput) ([]byte, error) {
	out, _, err := RenderAggregateReport(inputs)
	return out, err
}

// RenderAggregateReport is RenderAggregate plus what it had to leave out.
func RenderAggregateReport(inputs []AggregateInput) ([]byte, AggregateReport, error) {
	if len(inputs) < 2 {
		return nil, AggregateReport{}, fmt.Errorf("aggregate: need >=2 --bundle inputs to merge (got %d); a single node already has its own subscription", len(inputs))
	}
	var proxies []any
	var tags []string
	// Members this fold could not represent for the target client engine. Collected rather than fatal —
	// see the ShadowTLS note below — and reported, because a client silently missing a transport it was
	// told it had is the defect this project spends its time removing.
	var dropped []string
	famSeen := map[string]struct{}{}
	seen := map[string]bool{}
	for idx := range inputs {
		label := inputs[idx].Label
		// C27: ASCII whitelist only — refuse non-ASCII/whitespace labels (homoglyph tag-collision risk).
		if strings.IndexFunc(label, func(r rune) bool {
			return !((r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-')
		}) >= 0 {
			return nil, AggregateReport{}, fmt.Errorf("aggregate: node label %q contains a character outside the ASCII whitelist [A-Za-z0-9._-] — non-ASCII/whitespace labels are refused (homoglyph tag-collision risk). Use an ASCII --name", label)
		}
		safe := label
		if safe == "" {
			safe = fmt.Sprintf("node%d", idx+1)
		}
		if seen[safe] {
			return nil, AggregateReport{}, fmt.Errorf("aggregate: duplicate node label %q — every --name must be unique so tags never collide across nodes", safe)
		}
		seen[safe] = true
		for _, ep := range inputs[idx].Bundle.Endpoints {
			shortTag := strings.TrimPrefix(ep.Tag, "mycelium-")
			if shortTag == "" {
				shortTag = ep.Tag
			}
			nsTag := safe + "." + shortTag
			link := ep.Link
			// DROPPED, not fatal. The refusal itself is right: an ss:// ShadowTLS link carries only the
			// INNER shadowsocks material (method:password + masquerade SNI) and NOT the v3 handshake
			// password or version, so the pair the subscription renderer emits cannot be reconstructed
			// from the link alone — and a bare SS outbound would dial the ShadowTLS port with the wrong
			// credential. What was wrong is that it killed the WHOLE fold.
			//
			// A fungi network is heterogeneous BY DESIGN: different nodes offer different transports, and
			// the point of an aggregate is to hand one client several nodes. Under the old contract a
			// single node serving ShadowTLS made the entire multi-node profile unbuildable — measured
			// 2026-08-19 on two live nodes, where `aggregate` refused outright and produced nothing.
			// One member the client cannot dial must cost that member, never the other nodes.
			//
			// The fail-closed line moves to where it belongs: what SURVIVES must still clear the RP-0013
			// independent-family floor (checked after the loop). Dropping is safe; leaving a client with
			// one family is not.
			if strings.Contains(link, "plugin=shadow-tls") {
				dropped = append(dropped, fmt.Sprintf("%s/%s (ShadowTLS: the share-link carries only the inner material, not the v3 handshake — render it from `subscription`, which has the params)", safe, shortTag))
				continue
			}
			// xhttp is an Xray-only carrier (ADR-0032): sing-box has no such transport, and an outbound
			// carrying one makes it reject the WHOLE profile — so including it would cost the client every
			// other node in the fold. Dropped for the same reason and with the same accounting.
			if OutboundSkipReason(link) != "" && !strings.Contains(link, "plugin=shadow-tls") {
				dropped = append(dropped, fmt.Sprintf("%s/%s (%s)", safe, shortTag, OutboundSkipReason(link)))
				continue
			}
			scheme := uriBefore(link, "://")
			if !aggSchemeClassOK(scheme, string(ep.TransportClass)) {
				switch scheme {
				case "vless", "hysteria2", "tuic", "ss", "trojan":
					return nil, AggregateReport{}, fmt.Errorf("aggregate: endpoint scheme %q is inconsistent with its declared transport_class %q (node %q, tag %q) — the Link protocol and the typed family disagree", scheme, ep.TransportClass, safe, ep.Tag)
				default:
					return nil, AggregateReport{}, fmt.Errorf("aggregate: endpoint link has an unrecognised scheme %q (node %q, tag %q) — expected one of vless/hysteria2/tuic/ss/trojan", scheme, safe, ep.Tag)
				}
			}
			ob, err := outboundValue(nsTag, link)
			if err != nil || ob == nil {
				return nil, AggregateReport{}, fmt.Errorf("aggregate: could not parse endpoint link into a client outbound (node %q, tag %q)", safe, ep.Tag)
			}
			if port := aggOutboundPort(ob); port < 1 || port > 65535 {
				return nil, AggregateReport{}, fmt.Errorf("aggregate: endpoint link port %d out of range 1..65535 (node %q, tag %q)", port, safe, ep.Tag)
			}
			proxies = append(proxies, ob)
			tags = append(tags, nsTag)
			if fam, ok := BlockFamilyForProto(shortTag); ok {
				famSeen[fam] = struct{}{}
			}
		}
	}
	if len(proxies) == 0 {
		return nil, AggregateReport{}, fmt.Errorf("aggregate: produced zero outbounds across %d input bundle(s). Dropped: %s", len(inputs), strings.Join(dropped, "; "))
	}
	// THE FAIL-CLOSED LINE, moved to where it belongs. Dropping a member the client engine cannot dial is
	// safe; handing back a profile whose survivors span fewer than RP-0013's independent families is not —
	// one block then takes the client's last path, which is the whole reason the floor exists. This is the
	// check that replaces "every member must render", and it judges the RESULT rather than the inputs.
	fams := make([]string, 0, len(famSeen))
	for f := range famSeen {
		fams = append(fams, f)
	}
	sort.Strings(fams)
	if len(fams) < IndependentFamilyFloor {
		return nil, AggregateReport{Dropped: dropped, Families: fams},
			fmt.Errorf("aggregate: the folded profile spans %d independent family/families (%s), floor is %d (RP-0013) — a client blocked on one would have nowhere left. Dropped: %s",
				len(fams), strings.Join(fams, " "), IndependentFamilyFloor, strings.Join(dropped, "; "))
	}
	outbounds := make([]any, 0, len(proxies)+4)
	outbounds = append(outbounds, proxies...)
	outbounds = append(outbounds,
		aggURLTest{Type: "urltest", Tag: "auto", Outbounds: tags, URL: urltestURL,
			Interval: urltestInterval, Tolerance: urltestTolerance, IdleTimeout: urltestIdleTimeout},
		aggSelector{Type: "selector", Tag: "mycelium", Outbounds: append([]string{"auto"}, tags...), Default: "auto"},
		aggTagged{Type: "direct", Tag: "direct"},
		aggTagged{Type: "block", Tag: "block"},
	)
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(aggProfile{Outbounds: outbounds}); err != nil {
		return nil, AggregateReport{}, err
	}
	return buf.Bytes(), AggregateReport{Dropped: dropped, Families: fams}, nil
}

// aggSchemeClassOK reports whether a share-link scheme is consistent with the endpoint's declared
// transport_class (C26 — the Link protocol and the typed family must agree). Mirrors the shell case table.
func aggSchemeClassOK(scheme, class string) bool {
	switch scheme + ":" + class {
	case "vless:reality-tcp", "vless:xhttp-tls", "vless:ws-tls",
		"hysteria2:quic-udp", "tuic:quic-udp",
		"ss:shadowsocks-tcp", "ss:shadowtls-tcp",
		"trojan:trojan-tls":
		return true
	}
	return false
}

// aggOutboundPort extracts server_port from a typed outbound value (C09 range check).
func aggOutboundPort(ob any) int {
	switch o := ob.(type) {
	case aggVless:
		return o.ServerPort
	case aggHy2:
		return o.ServerPort
	case aggTuic:
		return o.ServerPort
	case aggSS:
		return o.ServerPort
	case aggTrojan:
		return o.ServerPort
	default:
		return 0
	}
}

type aggProfile struct {
	Outbounds []any `json:"outbounds"`
}
type aggURLTest struct {
	Type        string   `json:"type"`
	Tag         string   `json:"tag"`
	Outbounds   []string `json:"outbounds"`
	URL         string   `json:"url"`
	Interval    string   `json:"interval"`
	Tolerance   int      `json:"tolerance"`
	IdleTimeout string   `json:"idle_timeout"`
}
type aggSelector struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Outbounds []string `json:"outbounds"`
	Default   string   `json:"default"`
}
type aggTagged struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}
