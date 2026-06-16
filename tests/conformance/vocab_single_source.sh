#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# vocab_single_source.sh — conformance: the control-plane vocabulary (the proto->class table, the
# per-proto default ports + params keys, and the closed transport-class/region/health sets) has ONE
# source of truth in Go (internal/spec, surfaced by `myceliumctl vocab`), and the committed
# control/vocab.json the shell renderer reads is a faithful, in-sync copy of that emission (RP-0008 P2).
#
# Before RP-0008 P2 these facts lived in three-plus hand-maintained shell tables that drifted silently
# (render_bundle.sh `myc_bundle_class_of`, render_singbox.sh `MYC_SB_PROTOS` + port defaults, the
# conformance mirrors). This gate is what keeps "Go owns it, the shell consumes a file" honest:
#
#   1. (always, jq-only) control/vocab.json is present, valid JSON, and internally consistent — the
#      proto registry covers EXACTLY the closed transport-class vocabulary, proto names + params keys are
#      unique, and ports are in range. A hand-edit that breaks the shape fails here on every lane.
#   2. (where Go is present — a node with go1.26, a CI lane that installs Go) `myceliumctl vocab` is
#      regenerated and asserted BYTE-IDENTICAL to the committed control/vocab.json. This is the drift
#      catch: edit the Go registry without regenerating the file (or vice-versa) and this fails.
#
# SKIP-IF-NO-GO applies ONLY to step 2 (the regen/diff). Step 1 always runs. This mirrors
# bundle_go_roundtrip.sh: the offline jq-only host cannot run Go, but the Go-side unit mirror
# (internal/spec.TestTransportRegistry* under `go test`) and the node lanes cover the regen.
#
# Exit: 0 = single-source holds (or regen skipped, no Go), 1 = file drift / inconsistency, 2 = usage/env.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
VOCAB="$REPO_ROOT/control/vocab.json"

printf '== vocab single-source check (Go internal/spec -> control/vocab.json) ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required.\n' >&2; exit 2; }
[ -f "$VOCAB" ] || { printf 'FAIL: control/vocab.json not found: %s\n' "$VOCAB" >&2; exit 2; }
jq -e . "$VOCAB" >/dev/null 2>&1 || { printf 'FAIL: control/vocab.json is not valid JSON.\n' >&2; exit 1; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

# --- Step 1: internal consistency of the committed file (always, jq-only). --------------------------

# Top-level keys present and of the right shape.
if jq -e '
	(.version | type) == "number"
	and (.transport_classes | type) == "array" and (.transport_classes | length) >= 1
	and (.region_buckets   | type) == "array" and (.region_buckets   | length) >= 1
	and (.health_values    | type) == "array" and (.health_values    | length) >= 1
	and (.protos | type) == "array" and (.protos | length) >= 1
' "$VOCAB" >/dev/null 2>&1; then
	okln "control/vocab.json has the expected top-level shape"
else
	badln "control/vocab.json is missing a required top-level key or has the wrong type"
fi

# The proto registry covers EXACTLY the closed transport-class vocabulary: no class without a proto,
# no proto introducing a class outside the vocabulary. This is the invariant that lets the shell trust
# the file as the whole story (it mirrors internal/spec.TestTransportRegistryClassesAreValidAndClosed).
if jq -e '
	(([.protos[].class] | unique) as $covered
	 | (.transport_classes | unique) as $vocab
	 | $covered == $vocab)
' "$VOCAB" >/dev/null 2>&1; then
	okln "proto registry covers exactly the closed transport-class vocabulary"
else
	badln "proto-class coverage != transport_classes (a class lacks a proto, or a proto leaks a class)"
fi

# Phase-1 closed sets: region is exactly {unspecified}; health includes unknown (the Phase-1 value).
if jq -e '(.region_buckets | sort) == ["unspecified"]' "$VOCAB" >/dev/null 2>&1; then
	okln "region vocabulary is the single Phase-1 bucket {unspecified}"
else
	badln "region_buckets is not exactly [\"unspecified\"] (Phase-1 closed vocab)"
fi
if jq -e '.health_values | index("unknown") != null' "$VOCAB" >/dev/null 2>&1; then
	okln "health vocabulary contains the Phase-1 value \"unknown\""
else
	badln "health_values is missing \"unknown\""
fi

# Proto names unique.
if [ "$(jq '[.protos[].proto] | length' "$VOCAB")" -eq "$(jq '[.protos[].proto] | unique | length' "$VOCAB")" ]; then
	okln "proto names are unique"
else
	badln "duplicate proto name in the registry"
fi

# params keys unique among the params-toggled protos (non-empty enable/port keys).
if [ "$(jq '[.protos[] | select(.enable_key != "") | .enable_key] | length' "$VOCAB")" \
   -eq "$(jq '[.protos[] | select(.enable_key != "") | .enable_key] | unique | length' "$VOCAB")" ] \
 && [ "$(jq '[.protos[] | select(.port_key != "") | .port_key] | length' "$VOCAB")" \
   -eq "$(jq '[.protos[] | select(.port_key != "") | .port_key] | unique | length' "$VOCAB")" ]; then
	okln "params enable/port keys are unique"
else
	badln "duplicate params enable_key or port_key in the registry"
fi

# Ports: params-toggled protos in 1..65535; non-toggled (amneziawg) carries 0 + empty keys.
if jq -e '
	.protos | all(
		if .engine == "amneziawg"
		then .default_port == 0 and .enable_key == "" and .port_key == "" and .scheme == ""
		else (.default_port >= 1 and .default_port <= 65535
		      and (.enable_key | length) > 0 and (.port_key | length) > 0 and (.scheme | length) > 0)
		end)
' "$VOCAB" >/dev/null 2>&1; then
	okln "ports/keys are consistent with each proto's engine (toggled in range; amneziawg standalone)"
else
	badln "a proto has an out-of-range port or an engine/keys mismatch"
fi

# --- Step 1b: the shell renderer CONSUMES the file and keeps NO inline copy of the table (RP-0008 P2).
# This is what makes "Go owns it, the shell reads a file" enforceable: render_bundle.sh must read
# control/vocab.json AND must not re-introduce a hand-maintained proto->class case statement. We assert
# the wire class literals never appear as `printf '<class>'` shell statements there (comments naming a
# class are fine; an emitted class string is the old table form).
RB="$REPO_ROOT/control/lib/render_bundle.sh"
if [ -f "$RB" ]; then
	if grep -Eq 'MYC_VOCAB|vocab\.json' "$RB"; then
		okln "render_bundle.sh reads the Go-owned vocab file (consumes Go, not an inline table)"
	else
		badln "render_bundle.sh does not reference control/vocab.json — it is not consuming the Go source"
	fi
	if grep -Eq "printf '(reality-tcp|quic-udp|shadowsocks-tcp|shadowtls-tcp|trojan-tls|amneziawg-udp|xhttp-tls|ws-tls)'" "$RB"; then
		badln "render_bundle.sh still emits a transport class as a shell literal (an inline proto->class table survived)"
	else
		okln "render_bundle.sh keeps no inline proto->class table (no class emitted as a shell literal)"
	fi
else
	badln "render_bundle.sh not found: $RB"
fi

# --- Step 2: drift catch — regenerate from Go and assert byte-identical (skips without Go). ----------
GO=""
if command -v go >/dev/null 2>&1; then
	GO="$(command -v go)"
else
	for cand in /usr/local/go/bin/go /usr/lib/go-1.26/bin/go /usr/lib/go/bin/go; do
		[ -x "$cand" ] && { GO="$cand"; break; }
	done
fi

if [ -z "$GO" ]; then
	printf '\nSKIP (regen only): no Go toolchain present — cannot regenerate `myceliumctl vocab` to diff\n'
	printf '      against control/vocab.json. The internal-consistency checks above ran; the Go regen runs\n'
	printf '      on the node/CI lanes and under `go test ./internal/spec/...`.\n'
else
	printf 'go: %s\n' "$GO"
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.vss.XXXXXX")" || { printf 'FAIL: mktemp failed.\n' >&2; exit 2; }
	trap 'rm -rf "$WORK"' EXIT
	if ( cd "$REPO_ROOT" && GOCACHE="$WORK/gocache" GOFLAGS=-mod=mod "$GO" run ./cmd/myceliumctl vocab ) > "$WORK/regen.json" 2>"$WORK/regen.err"; then
		if diff -u "$VOCAB" "$WORK/regen.json" > "$WORK/diff.out" 2>&1; then
			okln "control/vocab.json is byte-identical to \`myceliumctl vocab\` (no drift)"
		else
			badln "control/vocab.json has DRIFTED from the Go emission — regenerate: \`go run ./cmd/myceliumctl vocab > control/vocab.json\`"
			sed -n '1,20p' "$WORK/diff.out" >&2
		fi
	else
		badln "could not run \`myceliumctl vocab\`: $(tr -d '\n' < "$WORK/regen.err" | cut -c1-200)"
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the vocabulary is not single-sourced (file drift or internal inconsistency).\n' >&2
	exit 1
fi
printf 'PASS: control/vocab.json is internally consistent and in sync with the Go source of truth.\n'
exit 0
