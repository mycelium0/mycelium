# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# render_aggregate.sh — the CLIENT-SIDE merge: take M per-node distribution Bundles
# (internal/spec/bundle.go shape, each rendered by `myceliumctl bundle`) and fold them into
# ONE client-importable sing-box profile, LOCALLY, with NO transmission. "One profile, all MY
# nodes." (RP-0007-d, chunk 5.)
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl. Depends on common.sh, jqlib.sh, render_singbox.sh (it reuses the SAME
# client-outbound + urltest + selector shape the subscription path emits, so the merged profile
# is the subscription's client format, just spanning several nodes).
#
# WHAT THIS IS — AND WHAT IT IS NOT (§15.8 / VIS-0007 seam):
#   * It is a PURELY LOCAL merge an operator runs on THEIR OWN machine over THEIR OWN nodes'
#     bundles: read M input files, write one output file. NO network I/O. NO upload. NO server.
#     No transmission of any kind — the merge never leaves the operator's device. This is the
#     hard invariant of this command.
#   * It is NOT a central cross-node endpoint. There is no service that aggregates across nodes,
#     no authority that holds the fleet's endpoints, nothing for an adversary to block once to
#     take the fleet down. A served cross-node aggregator WOULD be a single point of block and a
#     forbidden centralisation of topology; this is the opposite — every node still serves its
#     OWN bundle independently, and the operator stitches their own copies together at rest.
#   * The bound on the at-rest merged profile (one device holding the operator's M nodes) is
#     recorded as a BOUNDED, ACCEPTED exception in docs/THREAT-MODEL.md: own nodes, local, no
#     transmission.
#
# Phase discipline: health stays advisory-only (bundle.go). The merge carries endpoints exactly
# as the input bundles present them; it invents no health, no central ranking, no measurement.

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
#
# myc_agg_assert_bundle FILE LABEL — fail-closed structural check that FILE is a Bundle
# (internal/spec/bundle.go shape): valid JSON, integer .version, a non-empty .endpoints[] whose
# every member carries the six bundle.go fields (tag, transport_class, region, priority, health,
# link) with a non-empty link. This mirrors Bundle.Validate's coarse shape (the authoritative Go
# round-trip runs on a node); a malformed input must never silently produce a broken profile.
myc_agg_assert_bundle() {
	local file label
	file="$1"; label="$2"
	[ -f "$file" ] || myc_die "aggregate: input bundle not found ($label): $file"
	myc_assert_json "$file" "aggregate input bundle ($label)"
	jq -e '(.version | type) == "number"' "$file" >/dev/null 2>&1 \
		|| myc_die "aggregate: input bundle ($label) has no integer .version (not a bundle.go Bundle): $file"
	jq -e '(.endpoints | type) == "array" and (.endpoints | length) >= 1' "$file" >/dev/null 2>&1 \
		|| myc_die "aggregate: input bundle ($label) has no non-empty .endpoints[] (Bundle.Validate requires >=1): $file"
	jq -e '.endpoints | all(
		has("tag") and has("transport_class") and has("region")
		and has("priority") and has("health") and has("link")
		and ((.link | type) == "string") and ((.link | length) > 0)
	)' "$file" >/dev/null 2>&1 \
		|| myc_die "aggregate: input bundle ($label) has a malformed endpoint (each needs tag/transport_class/region/priority/health/link, link non-empty): $file"
}

# ---------------------------------------------------------------------------
# Link -> sing-box client outbound
# ---------------------------------------------------------------------------
#
# myc_agg_link_outbound TAG LINK -> a single-line JSON object: the sing-box client outbound for
# this endpoint, parsed from its opaque share-link (the SAME schemes render_bundle.sh emits:
# vless://, hysteria2://, tuic://, ss://, trojan://) into the SAME outbound shape the subscription
# path (render_singbox.sh) builds. TAG is the already-namespaced outbound tag to stamp on it.
#
# The parse is done ENTIRELY in jq from the link string (no eval, no network): split off the
# scheme, the #fragment, the userinfo@host:port authority, and the ?query into a key/value map.
# Every value flows through --arg, so nothing from the link is ever interpreted as shell or jq.
# An unrecognised scheme yields empty (the caller fails closed).
myc_agg_link_outbound() {
	local tag link
	tag="$1"; link="$2"
	jq -nc --arg tag "$tag" --arg link "$link" '
		# --- pure-jq URI parsing helpers (operate only on the passed string) ---
		def after($sep): if (. | contains($sep)) then (./ $sep)[1:] | join($sep) else "" end;
		def before($sep): (./ $sep)[0];
		# C07: percent-decode one URI component (the inverse of render_bundle.sh @uri). jq has no
		# built-in URI-decode, so decode %XX byte-by-byte: split on "%", keep the first chunk literal,
		# and for every following chunk turn its leading two hex digits into the byte they encode and
		# keep the rest of the chunk literal. Producer and parser thus agree on every value exactly —
		# a value like "/api?x=1#frag" survives encode->splice->parse->decode unchanged (C07 round-trip).
		# (jq tonumber does not parse hex, so the two hex digits are converted via an explicit nibble map.)
		def hexval: {"0":0,"1":1,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,"8":8,"9":9,
		             "a":10,"b":11,"c":12,"d":13,"e":14,"f":15,
		             "A":10,"B":11,"C":12,"D":13,"E":14,"F":15}[.];
		def urldecode:
			(. // "") as $s
			| if ($s | contains("%") | not) then $s
			else
				($s | split("%")) as $parts
				| ($parts[0]) +
				  ( $parts[1:]
					| map(
						if (test("^[0-9A-Fa-f]{2}")) then
							( ((.[0:1] | hexval) * 16) + (.[1:2] | hexval) ) as $code
							| ([$code] | implode) + .[2:]
						else
							# not a valid %XX escape — keep the stray % literal (defensive)
							"%" + .
						end
					)
					| join("")
				  )
			end;
		# parse "k=v&k2=v2" into an object {k: <decoded v>,...}. Keys are producer-controlled literals
		# (never encoded), so only the VALUE is percent-decoded. An empty value (k=) is preserved so the
		# parser and producer agree on the param set (C26: do not silently drop empty query params).
		def query_to_obj:
			if (. == "") then {}
			else
				split("&")
				| map(select(length > 0) | { (before("=")): (after("=") | urldecode) })
				| add // {}
			end;

		($link | before("#")) as $main         # everything before the fragment
		| ($main | before("://")) as $scheme    # uri scheme
		| ($main | after("://")) as $rest        # userinfo@host:port[?query]
		| ($rest | before("?")) as $authority    # userinfo@host:port
		| ($rest | after("?")  | query_to_obj) as $q
		# C07: $userinfo / $host are percent-decoded AFTER the structural split. The producer encodes
		# every reserved char (@, :, etc.) inside a value, so splitting on the literal @/: delimiters is
		# safe; we decode the extracted token back to its true value here.
		| ($authority | (if contains("@") then before("@") else "" end)) as $userinfo_raw
		| ($authority | (if contains("@") then after("@") else . end)) as $hostport
		# host:port — split on the first colon. C28 DECISION (Phase-1, recorded): IPv6 literals are
		# UNSUPPORTED here on purpose — Mycelium Links carry hostnames (node_address), never a bare
		# "[::1]:443" authority, so bracket-aware splitting is deliberately out of scope for Phase-1. A
		# bracketed IPv6 authority would mis-split; if a future phase emits IPv6-literal Links this must
		# grow bracket handling. Until then this is the explicit accepted limitation, not an oversight.
		| ($hostport | before(":")) as $host_raw
		| ($hostport | after(":")) as $portstr
		| ($host_raw | urldecode) as $host
		| ($userinfo_raw | urldecode) as $userinfo
		| ($portstr | tonumber? // 0) as $port
		# build the outbound by scheme (the tls block is inlined per scheme below)
		| (
			if $scheme == "vless" then
				# security=reality -> reality tls; security=tls -> plain own-cert tls.
				($q.security // "") as $sec
				| (if $sec == "reality"
					then { enabled: true, server_name: ($q.sni // ""),
					       utls: { enabled: true, fingerprint: ($q.fp // "chrome") },
					       reality: { enabled: true, public_key: ($q.pbk // ""), short_id: ($q.sid // "") } }
					else { enabled: true, server_name: ($q.sni // ""),
					       utls: { enabled: true, fingerprint: ($q.fp // "chrome") },
					       alpn: (($q.alpn // "h2,http/1.1") | split(",")) }
				end) as $tls
				| ({ type: "vless", tag: $tag, server: $host, server_port: $port,
				     uuid: $userinfo, flow: ($q.flow // ""), packet_encoding: "xudp", tls: $tls }
				  + ( ($q.type // "tcp") as $nt
				      | if $nt == "grpc" then { transport: { type: "grpc", service_name: ($q.serviceName // "grpc") } }
				        elif $nt == "xhttp" then { transport: { type: "xhttp", path: ($q.path // "/") } }
				        else {} end ))
			elif $scheme == "hysteria2" then
				{ type: "hysteria2", tag: $tag, server: $host, server_port: $port,
				  password: $userinfo,
				  tls: { enabled: true, server_name: ($q.sni // ""),
				         utls: { enabled: true, fingerprint: "chrome" },
				         alpn: (($q.alpn // "h3") | split(",")) } }
			elif $scheme == "tuic" then
				# tuic://uuid:password@host:port — split the RAW userinfo on the literal ":" (the producer
				# percent-encodes any ":" inside either half, so the first ":" is the real delimiter), then
				# percent-decode each half back to its true value (C07).
				($userinfo_raw | before(":") | urldecode) as $uuid
				| ($userinfo_raw | after(":") | urldecode) as $pw
				| { type: "tuic", tag: $tag, server: $host, server_port: $port,
				    uuid: $uuid, password: $pw, congestion_control: ($q.congestion_control // "bbr"),
				    tls: { enabled: true, server_name: ($q.sni // ""),
				           utls: { enabled: true, fingerprint: "chrome" },
				           alpn: (($q.alpn // "h3") | split(",")) } }
			elif $scheme == "ss" then
				# ss://method:password@host:port  (optionally ?plugin=shadow-tls&sni=...)
				# FAIL-CLOSED on a ShadowTLS share-link: the ss:// Link carries only the INNER
				# Shadowsocks material (method:password) + the masquerade SNI. It does NOT carry the
				# v3 handshake password or version, so the shadowtls+detour outbound the subscription
				# path emits (render_singbox.sh: a "shadowtls" version:3 handshake outbound that the
				# inner SS detours through) CANNOT be faithfully reconstructed from the Link alone.
				# Emitting a bare Shadowsocks outbound here would dial the ShadowTLS handshake port as
				# plain SS with the wrong (inner) credential, a non-dialable endpoint. Refuse it instead.
				# (N1: yield null so the fail-closed path in the caller rejects this endpoint loudly.)
				if (($q.plugin // "") == "shadow-tls") then null
				else
					# Split the RAW userinfo on the literal ":" (method is the unreserved cipher name;
					# the producer percent-encodes any ":" inside the password), then decode each half (C07).
					($userinfo_raw | before(":") | urldecode) as $method
					| ($userinfo_raw | after(":") | urldecode) as $pw
					| { type: "shadowsocks", tag: $tag, server: $host, server_port: $port,
					    method: $method, password: $pw }
				end
			elif $scheme == "trojan" then
				{ type: "trojan", tag: $tag, server: $host, server_port: $port,
				  password: $userinfo,
				  tls: { enabled: true, server_name: ($q.sni // ""),
				         utls: { enabled: true, fingerprint: ($q.fp // "chrome") },
				         alpn: (($q.alpn // "h2,http/1.1") | split(",")) } }
			else
				null
			end
		)
	'
}

# ---------------------------------------------------------------------------
# aggregate (client-side multi-node merge)
# ---------------------------------------------------------------------------
#
# myc_render_aggregate OUT  FILE1 LABEL1  FILE2 LABEL2  [FILE3 LABEL3 ...]
#
# Fold >=2 per-node Bundles into ONE sing-box client profile written to OUT. Each (FILE, LABEL)
# pair is one of the operator's own nodes; LABEL namespaces that node's outbound tags so tags
# from different nodes never collide. The result carries EVERY endpoint from EVERY input as a
# client outbound (parsed from its Link), plus ONE urltest "auto" over all of them and ONE
# selector ("mycelium", default through "auto") — a single cross-node auto-switch the operator
# imports once.
#
# LOCAL-ONLY: this reads the input files and writes OUT. It performs no network I/O whatsoever.
myc_render_aggregate() {
	local out
	out="$1"; shift
	[ -n "$out" ] || myc_die "aggregate: --out is required"

	# Remaining args are (file label) pairs. Require >=2 inputs (a merge of one node is just that
	# node's own bundle — use the served subscription for that).
	local n_inputs
	n_inputs=$(( $# / 2 ))
	[ "$n_inputs" -ge 2 ] || myc_die "aggregate: need >=2 --bundle inputs to merge (got $n_inputs); a single node already has its own subscription."

	# Accumulators: the merged outbound array and the ordered tag list (for the urltest/selector).
	local outbounds_json tags_json seen_labels
	outbounds_json='[]'
	tags_json='[]'
	seen_labels=' '   # space-delimited set of labels already used (collision guard)

	local idx file label
	idx=0
	while [ "$#" -ge 2 ]; do
		file="$1"; label="$2"; shift 2
		idx=$((idx + 1))

		# Validate the input is a bundle.go-shaped Bundle (fail-closed on anything else).
		myc_agg_assert_bundle "$file" "$label"

		# C27: reject any NON-ASCII label outright rather than fold it. A unicode label (e.g. a Cyrillic
		# "nоde1" homoglyph of "node1") would otherwise be mapped char-by-char to "_" by a permissive
		# sanitiser and could collide with, or visually impersonate, an ASCII label — a homoglyph tag
		# collision. The namespace token must be drawn from the ASCII whitelist [A-Za-z0-9._-] only; fail
		# closed on anything else so the operator picks an unambiguous --name. (NFC normalisation would
		# still leave confusable scripts; the simplest robust choice is ASCII-only.)
		case "$label" in
			*[!A-Za-z0-9._-]*)
				myc_die "aggregate: node label '$label' contains a character outside the ASCII whitelist [A-Za-z0-9._-] — non-ASCII/whitespace labels are refused (homoglyph tag-collision risk). Use an ASCII --name." ;;
		esac
		# Within the whitelist, the label is already tag-safe; default an empty one to a stable token.
		local safe_label
		safe_label="$label"
		[ -n "$safe_label" ] || safe_label="node${idx}"

		# Labels MUST be unique across inputs, or two nodes would share a namespace and their tags
		# could collide — the very thing namespacing exists to prevent. Fail-closed.
		case "$seen_labels" in
			*" $safe_label "*) myc_die "aggregate: duplicate node label '$safe_label' — every --name must be unique so tags never collide across nodes." ;;
		esac
		seen_labels="${seen_labels}${safe_label} "

		# Walk this node's endpoints in order; build one namespaced outbound per endpoint.
		local n_ep ep_i raw_tag short_tag ns_tag link outbound ep_class scheme ob_port
		n_ep="$(jq '.endpoints | length' "$file")"
		ep_i=0
		while [ "$ep_i" -lt "$n_ep" ]; do
			raw_tag="$(jq -r --argjson i "$ep_i" '.endpoints[$i].tag' "$file")"
			link="$(jq -r --argjson i "$ep_i" '.endpoints[$i].link' "$file")"
			ep_class="$(jq -r --argjson i "$ep_i" '.endpoints[$i].transport_class' "$file")"

			# Namespace the tag: "<label>.<endpoint-tag-without-mycelium-prefix>". Stripping the shared
			# "mycelium-" prefix keeps the namespaced tag readable (e.g. "nodeA.vless-reality-vision").
			short_tag="${raw_tag#mycelium-}"
			[ -n "$short_tag" ] || short_tag="$raw_tag"
			ns_tag="${safe_label}.${short_tag}"

			# Fail-closed BEFORE parsing on a ShadowTLS Link: its v3 handshake password/version are not
			# carried in the ss:// share-link, so a faithful shadowtls+detour client outbound cannot be
			# rebuilt from it (see myc_agg_link_outbound's ss branch). Refuse the whole merge with a
			# precise message rather than silently emit a non-dialable bare-Shadowsocks outbound (N1).
			case "$link" in
				*plugin=shadow-tls*)
					myc_die "aggregate: endpoint link is a ShadowTLS share-link (node '$safe_label', tag '$raw_tag') which cannot be reconstructed into a dialable client outbound from its Link alone (the v3 handshake password/version are not in the Link). Re-export this node via its served subscription, which carries the full shadowtls detour; the aggregate refuses it fail-closed rather than emit a broken bare-Shadowsocks outbound." ;;
			esac

			# C26: assert the Link's URI scheme is one we recognise AND that it is consistent with the
			# endpoint's declared transport_class. A mismatch (e.g. an ss:// Link tagged transport_class
			# reality-tcp) is a CONFLICTING_SOURCE_OF_TRUTH between the declared family and the actual
			# protocol — refuse it fail-closed rather than emit an outbound that contradicts its own class.
			scheme="${link%%://*}"
			case "$scheme" in
				vless|hysteria2|tuic|ss|trojan) : ;;
				*) myc_die "aggregate: endpoint link has an unrecognised scheme '$scheme' (node '$safe_label', tag '$raw_tag') — expected one of vless/hysteria2/tuic/ss/trojan." ;;
			esac
			# scheme -> the set of transport_class values that scheme may legitimately carry (mirrors
			# render_bundle.sh myc_bundle_class_of + internal/spec TransportClass*).
			case "$scheme:$ep_class" in
				vless:reality-tcp|vless:xhttp-tls) : ;;
				hysteria2:quic-udp|tuic:quic-udp) : ;;
				ss:shadowsocks-tcp|ss:shadowtls-tcp) : ;;
				trojan:trojan-tls) : ;;
				*) myc_die "aggregate: endpoint scheme '$scheme' is inconsistent with its declared transport_class '$ep_class' (node '$safe_label', tag '$raw_tag') — the Link protocol and the typed family disagree (a conflicting source of truth)." ;;
			esac

			outbound="$(myc_agg_link_outbound "$ns_tag" "$link")"
			if [ -z "$outbound" ] || [ "$outbound" = "null" ] || ! printf '%s' "$outbound" | jq -e . >/dev/null 2>&1; then
				myc_die "aggregate: could not parse endpoint link into a client outbound (node '$safe_label', tag '$raw_tag'). Unsupported scheme?"
			fi

			# C09 fail-closed: the parsed outbound MUST carry a server_port in 1..65535. A missing or
			# non-numeric port in the Link parses to 0 (the jq `tonumber? // 0` floor); routing that into
			# this explicit check turns a silently-degraded port:0 into a loud refusal (never emit port 0).
			ob_port="$(printf '%s' "$outbound" | jq -r '.server_port // 0')"
			case "$ob_port" in
				''|*[!0-9]*) myc_die "aggregate: endpoint link has a non-numeric port (node '$safe_label', tag '$raw_tag') — could not parse endpoint link into a dialable outbound." ;;
			esac
			if [ "$ob_port" -lt 1 ] || [ "$ob_port" -gt 65535 ]; then
				myc_die "aggregate: endpoint link port '$ob_port' is out of range 1..65535 (node '$safe_label', tag '$raw_tag') — could not parse endpoint link into a dialable outbound."
			fi

			outbounds_json="$(printf '%s' "$outbounds_json" | jq -c --argjson ob "$outbound" '. + [$ob]')"
			tags_json="$(printf '%s' "$tags_json" | jq -c --arg t "$ns_tag" '. + [$t]')"

			ep_i=$((ep_i + 1))
		done
		myc_log "aggregate: merged $n_ep endpoint(s) from node '$safe_label' ($file)"
	done

	# Tag-collision guard: across ALL nodes the namespaced tags MUST be unique. (They are by
	# construction — unique labels + per-node tags — but assert it so a future change can't regress.)
	if [ "$(printf '%s' "$tags_json" | jq 'length')" -ne "$(printf '%s' "$tags_json" | jq 'unique | length')" ]; then
		myc_die "aggregate: namespaced tag collision across nodes (internal invariant broken)."
	fi
	[ "$(printf '%s' "$outbounds_json" | jq 'length')" -ge 1 ] \
		|| myc_die "aggregate: produced zero outbounds (no endpoints across the inputs)."

	# Assemble the final sing-box client profile: every proxy outbound, then ONE urltest "auto"
	# over ALL of them, then ONE selector ("mycelium", default through "auto"), then direct/block —
	# the SAME outbound layout render_singbox.sh's subscription emits, just spanning several nodes.
	# C22 anti-flapping: reuse the SAME urltest hysteresis defaults the subscription render uses
	# (render_singbox.sh MYC_URLTEST_* — single source of truth), so the cross-node auto-switch does not
	# thrash between near-equal endpoints on jitter (THREAT-MODEL §6.1.6/§6.1.8). render_aggregate.sh
	# already sources render_singbox.sh, so these constants are in scope.
	local profile
	profile="$(jq -nc \
		--argjson proxies "$outbounds_json" \
		--argjson tags "$tags_json" \
		--arg utinterval "$MYC_URLTEST_INTERVAL" \
		--argjson uttolerance "$MYC_URLTEST_TOLERANCE" \
		--arg utidle "$MYC_URLTEST_IDLE_TIMEOUT" \
		'{
			outbounds: (
				$proxies
				+ [
					{ type: "urltest", tag: "auto", outbounds: $tags, url: "https://www.gstatic.com/generate_204", interval: $utinterval, tolerance: $uttolerance, idle_timeout: $utidle },
					{ type: "selector", tag: "mycelium", outbounds: (["auto"] + $tags), default: "auto" },
					{ type: "direct", tag: "direct" },
					{ type: "block", tag: "block" }
				]
			)
		}')"

	if [ -z "$profile" ] || ! printf '%s' "$profile" | jq -e . >/dev/null 2>&1; then
		myc_die "aggregate: merge produced invalid JSON (internal error)."
	fi
	# Structural fail-closed: exactly one urltest "auto" and one selector; the urltest covers every
	# proxy tag.
	if [ "$(printf '%s' "$profile" | jq '[.outbounds[] | select(.type=="urltest")] | length')" -ne 1 ]; then
		myc_die "aggregate: expected exactly one urltest outbound."
	fi
	if [ "$(printf '%s' "$profile" | jq '[.outbounds[] | select(.type=="selector")] | length')" -ne 1 ]; then
		myc_die "aggregate: expected exactly one selector outbound."
	fi
	if ! printf '%s' "$profile" | jq -e '
		([.outbounds[] | select(.type=="urltest") | .outbounds[]] | sort)
		== ([.outbounds[] | select(.type!="urltest" and .type!="selector" and .type!="direct" and .type!="block") | .tag] | sort)
	' >/dev/null 2>&1; then
		myc_die "aggregate: the urltest does not cover exactly the merged proxy outbounds."
	fi

	printf '%s\n' "$profile" | jq . | myc_atomic_write "$out"
	myc_assert_json "$out" "aggregated client profile"
	myc_log "wrote aggregated client profile: $out ($(printf '%s' "$tags_json" | jq 'length') proxy outbound(s) across $n_inputs node(s))"
}
