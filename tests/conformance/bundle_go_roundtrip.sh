#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# bundle_go_roundtrip.sh — conformance: a bundle rendered by the SHELL producer (control/myceliumctl
# bundle -> render_bundle.sh) round-trips through the AUTHORITATIVE Go validator
# (myceliumctl validate-bundle -> internal/spec.Bundle.Validate). This is the RP-0008 P1 boundary
# contract that closes the audit's C11 (validation was hand-mirrored in Go + >=2 shell sites with no
# production round-trip — exactly the gap that let N1 ship): the shell renders, Go is the single
# authority on validity, and this gate proves the two agree on rendered output. It also exercises the
# C13 (closed region vocab) and C15 (dated bundle) Go invariants against a real rendered + tampered
# bundle.
#
# Author: mindicator & silicon bags quartet.
#
# SKIP-IF-NO-GO: the offline suite runs in environments without a Go toolchain (the maintainer's macOS
# host; the jq-only CI lane). There this gate SKIPs (exit 0 with a note) — it is NOT a failure, exactly
# like validate_configs skips absent yaml/xray tools. Where Go IS present (a node with go1.26, or a CI
# lane that installs Go) it runs the full render -> validate round-trip. The Go-side unit mirror
# (internal/spec.TestBundleJSONRoundTrip / TestBundleJSONWireShape) runs under `go test` regardless.
#
# Exit: 0 = round-trip holds (or skipped, no Go), 1 = the shell-rendered bundle fails Go validation OR a
#       tampered bundle is wrongly accepted, 2 = usage/env error.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
CTL="$REPO_ROOT/control/myceliumctl"

printf '== bundle Go round-trip check (shell render -> Go validate-bundle) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -x "$CTL" ] || [ -f "$CTL" ] || { printf 'FAIL: control/myceliumctl not found: %s\n' "$CTL" >&2; exit 2; }

# Resolve a Go toolchain: PATH first, then the well-known node install locations. Absent => SKIP.
GO=""
if command -v go >/dev/null 2>&1; then
	GO="$(command -v go)"
else
	for cand in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do
		[ -x "$cand" ] && { GO="$cand"; break; }
	done
fi
if [ -z "$GO" ]; then
	printf '\nSKIP: no Go toolchain present (PATH or the known node locations) — the round-trip gate needs\n'
	printf '      `go run ./cmd/myceliumctl validate-bundle`. This is NOT a failure (jq-only host/CI lane);\n'
	printf '      the Go-side unit mirror runs under `go test ./internal/spec/...` where Go is installed.\n'
	printf 'PASS (skipped): bundle Go round-trip not exercised here.\n'
	exit 0
fi
printf 'go: %s\n' "$GO"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.bgrt.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# Minimal render fixtures. Dummy reality material is fine: the bundle Link is an opaque string at the
# typed level, so Go validates STRUCTURE (version/class/region/health/tag/link/dated), never key format.
PARAMS="$WORK/params.json"
STATE="$WORK/identities.json"
jq -n '{
	node_address: "node.example.invalid",
	donor_host: "www.example.invalid", donor_sni: "www.example.invalid",
	reality_public_key: "DUMMYPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	short_ids: [ "0123abcd" ],
	tls_sni: "tls.example.invalid",
	grpc_service_name: "grpc.health.v1.Health", xhttp_path: "/",
	ss_password: "x", trojan_password: "x", hysteria2_password: "x", shadowtls_password: "x",
	vless_reality_vision_enabled: true, vless_reality_vision_port: 443,
	vless_reality_grpc_enabled:   true, vless_reality_grpc_port:   8443
}' > "$PARAMS"
jq -n '{ version: 1, clients: [ { name: "alice", id: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", created: "2026-01-01T00:00:00Z" } ] }' > "$STATE"

BUNDLE="$WORK/bundle.json"
if ! bash "$CTL" bundle --params "$PARAMS" --state "$STATE" --out "$BUNDLE" 2>"$WORK/render.err"; then
	badln "shell render failed: $(tr -d '\n' < "$WORK/render.err" | cut -c1-200)"
	printf '\n-- Result --\nFAIL: could not render a bundle to validate.\n' >&2
	exit 1
fi
okln "shell producer rendered a bundle ($(jq '.endpoints|length' "$BUNDLE") endpoints)"

# validate_go FILE -> 0 if the Go validator accepts the bundle, non-zero otherwise. `go run` is offline
# (the module has no external deps). Build cache is kept inside WORK so the gate touches nothing global.
validate_go() {
	( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod "$GO" run ./cmd/myceliumctl validate-bundle "$1" ); }

# 1. The shell-rendered bundle MUST pass the authoritative Go validator (the C11 round-trip).
if validate_go "$BUNDLE" >"$WORK/ok.out" 2>&1; then
	okln "shell-rendered bundle passes Go spec.Bundle.Validate (C11 round-trip holds)"
else
	badln "shell-rendered bundle REJECTED by Go validator: $(tr -d '\n' < "$WORK/ok.out" | cut -c1-200)"
fi

# 2. Tamper cases: each must be REJECTED by Go (the validator actually enforces the invariant, not just
#    parses). A precise region (C13), a populated health (Phase-1 invariant), and a missing timestamp
#    (C15) are the three the audit calls out.
tamper_rejected() { # NAME  JQ_EXPR
	local name="$1" expr="$2" f="$WORK/tampered.json"
	jq "$expr" "$BUNDLE" > "$f"
	if validate_go "$f" >"$WORK/t.out" 2>&1; then
		badln "Go validator WRONGLY accepted a tampered bundle ($name)"
	else
		okln "Go validator rejects $name (fail-closed)"
	fi
}
tamper_rejected "a precise region (C13 closed vocab)" '.endpoints[0].region = "us-ca-sf-aws-1a"'
tamper_rejected "a populated health (Phase-1 advisory-only)" '.endpoints[0].health = "alive"'
tamper_rejected "a missing generated_at (C15)" 'del(.generated_at)'
tamper_rejected "an unknown transport_class" '.endpoints[0].transport_class = "vmess"'

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the shell-rendered bundle does not round-trip cleanly through the Go validator.\n' >&2
	exit 1
fi
printf 'PASS: shell-rendered bundle validates through the Go spine and tampered bundles are refused.\n'
exit 0
