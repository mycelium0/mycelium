#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# subscription_go_equiv.sh — conformance: the Go subscription renderer (spec.RenderSubscription,
# `myceliumctl subscription --engine singbox`) is BYTE-IDENTICAL to the shell producer
# (control/myceliumctl subscription --engine singbox -> myc_sb_render_subscription) for the same
# params + identities (RP-0008 P3-d, the strangler equivalence gate). Both emit, per client, a
# <safe>.singbox.json (sing-box client config) and a <safe>.clash.yaml (Clash-Meta). The subscription
# carries NO live clock, so the comparison is a straight per-file byte diff (no normalization). The gate
# exercises the dual-engine filter (ADR-0032): vless-xhttp-tls is enabled in the fixture and MUST be
# skipped by BOTH producers (a sing-box client cannot dial xhttp). Until green, the shell stays
# authoritative (no cutover); the Go renderer is additive.
# Author: mindicator & silicon bags quartet.
#
# VALID-NAME CONTRACT: the equivalence is asserted for valid client names (non-empty, free of the
# characters the shell's `jq @tsv | read` loop mishandles). The Go port deliberately does NOT reproduce
# two latent shell quirks on pathological names — an EMPTY name (rejected upstream by identity add) and a
# literal backslash/control char (the shell leaves the @tsv escape doubled). Realistic labels are
# unaffected; the fixtures below use valid names (incl. a space, which both sanitise identically).
#
# SKIP-IF-NO-GO: the offline jq-only host cannot run the Go side (mirrors the other *_go_equiv gates);
# the Go-node/CI lane runs the diff, and the Go-side unit test TestRenderSubscriptionShape pins the
# structure where Go is unavailable.
#
# Exit: 0 = byte-identical (or skipped without Go); 1 = a rendered file diverged; 2 = usage/env error.

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." && pwd)}"
CTL="$REPO_ROOT/control/myceliumctl"
command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }

printf '== subscription render Go↔shell byte-equivalence (RP-0008 P3-d) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

GO=""
if command -v go >/dev/null 2>&1; then GO="$(command -v go)"; else
	for c in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do [ -x "$c" ] && { GO="$c"; break; }; done
fi
if [ -z "$GO" ]; then
	printf 'SKIP: no Go toolchain — the Go-node/CI lane runs the subscription byte-equivalence (TestRenderSubscriptionShape mirrors it).\n'
	exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.subge.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
SPINE="$WORK/spine"
if ! ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 "$GO" build -o "$SPINE" ./cmd/myceliumctl ) >/dev/null 2>&1; then
	printf 'FAIL: could not build the Go spine.\n' >&2; exit 2
fi

# Fixture A: ALL params-toggled transports enabled — incl. vless-xhttp-tls (an xray-engine proto that
# BOTH producers must SKIP) and vless-ws-tls (a sing-box own-cert family, so tls_sni is required) — with
# distinct per-family paths and special characters (reserved + space) to exercise quoting + name
# sanitisation in both producers identically. Two clients: one WITH a per-identity password, one without
# (shared-secret fallback). A space in a client name exercises the `tr -c ... '_'` sanitiser.
PARAMS="$WORK/params.json"; STATE="$WORK/identities.json"
jq -n '{
	node_address: "node.example.invalid",
	donor_host: "www.example.invalid", donor_sni: "www.example.invalid",
	reality_public_key: "DUMMYPUBKEY_aB-cd12",
	short_ids: [ "0123abcd" ],
	tls_sni: "tls.example.invalid",
	grpc_service_name: "grpc.health.v1.Health",
	xhttp_path: "/x?a=1", xhttp_path_tls: "/xt#y", ws_path: "/ws&z",
	ss_password: "ss/pw+1", trojan_password: "tr&pw", hysteria2_password: "hy2:pw", shadowtls_password: "stls@pw",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_reality_grpc_enabled:   true, vless_reality_grpc_port:   8443,
	vless_reality_xhttp_enabled:  true, vless_reality_xhttp_port:  2096,
	vless_xhttp_tls_enabled:      true, vless_xhttp_tls_port:      2087,
	vless_ws_tls_enabled:         true, vless_ws_tls_port:         2089,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	tuic_enabled:                 true, tuic_port:                 8445,
	shadowsocks_enabled:          true, shadowsocks_port:          8388,
	shadowtls_enabled:            true, shadowtls_port:            8446,
	trojan_enabled:               true, trojan_port:               8447
}' > "$PARAMS"
jq -n '{ version: 1, clients: [
	{ name: "alice one", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z", password: "idpw/1" },
	{ name: "bob-2.x",   id: "b0b00000-0000-4000-8000-000000000000", created: "2026-01-01T00:00:00Z" }
] }' > "$STATE"

# Fixture B: subset (REALITY vision/grpc + Hysteria2 + ShadowTLS), default paths, NO own-cert family (so
# tls_sni may be unset -> the donor-SNI fallback path), one client with an EMPTY password (shared-secret
# fallback + the tuic-uses-uuid quirk must match in both).
PARAMS_B="$WORK/params_b.json"; STATE_B="$WORK/identities_b.json"
jq -n '{
	node_address: "node2.example.invalid",
	donor_host: "donor.example.invalid", donor_sni: "donor.example.invalid",
	reality_public_key: "PUB2", short_ids: [ "feed0001" ],
	ss_password: "SS_SECRET", hysteria2_password: "HY_SECRET", shadowtls_password: "STLS_SECRET", trojan_password: "TR_SECRET",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_reality_grpc_enabled:   true, vless_reality_grpc_port:   8443,
	hysteria2_enabled:            true, hysteria2_port:            8444,
	shadowtls_enabled:            true, shadowtls_port:            8446
}' > "$PARAMS_B"
jq -n '{ version: 1, clients: [ { name: "carol", id: "ca501000-0000-4000-8000-000000000000", created: "2026-01-01T00:00:00Z" } ] }' > "$STATE_B"

fail=0
compare_fixture() { # NAME PARAMS STATE
	local name="$1" params="$2" state="$3"
	local shd="$WORK/sh.$RANDOM" god="$WORK/go.$RANDOM"
	mkdir -p "$shd" "$god"
	if ! bash "$CTL" subscription --engine singbox --params "$params" --state "$state" --out "$shd" 2>"$WORK/sh.err"; then
		printf '  FAIL  [%s] shell render failed: %s\n' "$name" "$(tr -d '\n' < "$WORK/sh.err" | cut -c1-160)"; fail=1; return
	fi
	if ! "$SPINE" subscription --engine singbox --params "$params" --state "$state" --out "$god" 2>"$WORK/go.err"; then
		printf '  FAIL  [%s] Go render failed: %s\n' "$name" "$(tr -d '\n' < "$WORK/go.err" | cut -c1-160)"; fail=1; return
	fi
	# Same set of files?
	local shf gof
	shf="$(cd "$shd" && ls -1 | sort | tr '\n' ' ')"
	gof="$(cd "$god" && ls -1 | sort | tr '\n' ' ')"
	if [ "$shf" != "$gof" ]; then
		printf '  FAIL  [%s] file set differs:\n    shell: %s\n    go:    %s\n' "$name" "$shf" "$gof"; fail=1; return
	fi
	local f any=0
	for f in $shf; do
		any=1
		if ! diff -u "$shd/$f" "$god/$f" > "$WORK/diff.out" 2>&1; then
			printf '  FAIL  [%s] %s diverged:\n' "$name" "$f"; sed 's/^/    /' "$WORK/diff.out" | head -40; fail=1
		fi
	done
	[ "$any" -eq 1 ] && [ "$fail" -eq 0 ] && printf '  ok    [%s] byte-identical across: %s\n' "$name" "$shf"
}
compare_fixture "A: all transports + 2 clients (xhttp-tls skipped, ws-tls own-cert, name sanitised)" "$PARAMS" "$STATE"
compare_fixture "B: subset, empty client password -> shared-secret fallback" "$PARAMS_B" "$STATE_B"

printf '\n-- Result --\n'
if [ "$fail" -eq 0 ]; then
	printf 'PASS: spec.RenderSubscription is byte-identical to the shell subscription producer (both fixtures).\n'
	exit 0
fi
printf 'FAIL: the Go subscription renderer is not byte-identical — do NOT cut over (RP-0008 P3 equivalence).\n' >&2
exit 1
