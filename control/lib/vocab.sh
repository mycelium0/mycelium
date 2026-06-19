# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# vocab.sh — the shell-side accessor for the Go-owned control vocabulary (control/vocab.json, emitted by
# `myceliumctl vocab` from internal/spec). This is the SINGLE place the shell resolves the vocab file
# and parses the proto registry, so the renderers never re-declare the proto->class table, the
# priority-ordered proto list, or the per-proto default ports (RP-0008 P2). render_singbox.sh,
# render_bundle.sh, and render_aggregate.sh all read through here.
# Author: mindicator & silicon bags quartet.
#
# Sourced by myceliumctl after common.sh + jqlib.sh (needs myc_die + jq). The node-bootstrap path has
# its own inline read of $ARTIFACT_ROOT/control/vocab.json (it does not source the myceliumctl libs).
#
# FAIL-CLOSED: a missing/empty/unreadable vocab file is a hard error, never a silent fall-back to an
# inline copy of the table — the inline copies are exactly what P2 removed. The file ships with the rest
# of control/ via install_tooling, so a node that lacks it has a broken artifact and should fail loudly.

# MYC_VOCAB -> path to the committed, Go-emitted vocabulary file. Overridable for tests.
MYC_VOCAB="${MYC_VOCAB:-$MYC_ROOT/vocab.json}"

# Cached parses (loaded once per process by myc_vocab_load): the "proto<TAB>class" rows, the
# "proto<TAB>default_port" rows for the params-toggled (sing-box/xray) protos, and the space-separated
# priority-ordered proto list (the old MYC_SB_PROTOS).
_MYC_VOCAB_CLASSMAP=""
_MYC_VOCAB_PORTMAP=""
_MYC_VOCAB_PROTOS=""
_MYC_VOCAB_PROTOS_SINGBOX=""

myc_vocab_load() {
	[ -n "$_MYC_VOCAB_PROTOS" ] && return 0
	[ -f "$MYC_VOCAB" ] || myc_die "vocab: control/vocab.json not found ($MYC_VOCAB) — the Go-owned transport vocabulary is required (RP-0008 P2)."
	_MYC_VOCAB_CLASSMAP="$(jq -r '.protos[] | "\(.proto)\t\(.class)"' "$MYC_VOCAB" 2>/dev/null)" \
		|| myc_die "vocab: could not read the proto->class map from $MYC_VOCAB."
	_MYC_VOCAB_PORTMAP="$(jq -r '.protos[] | select(.engine != "amneziawg") | "\(.proto)\t\(.default_port)"' "$MYC_VOCAB" 2>/dev/null)" \
		|| myc_die "vocab: could not read the proto->port map from $MYC_VOCAB."
	_MYC_VOCAB_PROTOS="$(jq -r '[.protos[] | select(.engine != "amneziawg") | .proto] | join(" ")' "$MYC_VOCAB" 2>/dev/null)" \
		|| myc_die "vocab: could not read the proto list from $MYC_VOCAB."
	# The sing-box ENGINE's servable protos (engine == "sing-box"): excludes the xray-only protos
	# (e.g. vless-xhttp-tls — the xhttp transport is Xray-core only) AND the standalone amneziawg
	# dataplane. The sing-box renderer iterates THIS list so enabling an xray-engine proto never tries
	# to render an inbound sing-box cannot serve (ADR-0032 dual-engine). The full myc_vocab_protos list
	# (sing-box + xray) stays the source for endpoint enumeration (bundle), which spans both engines.
	_MYC_VOCAB_PROTOS_SINGBOX="$(jq -r '[.protos[] | select(.engine == "sing-box") | .proto] | join(" ")' "$MYC_VOCAB" 2>/dev/null)" \
		|| myc_die "vocab: could not read the sing-box proto list from $MYC_VOCAB."
	[ -n "$_MYC_VOCAB_PROTOS" ] || myc_die "vocab: $MYC_VOCAB has an empty proto registry."
	return 0
}

# myc_vocab_class_of PROTO -> the closed-vocab transport CLASS for PROTO (internal/spec TransportClass*),
# or the empty string if PROTO is not in the registry (the prior fail-open-to-empty behaviour callers
# already handle).
myc_vocab_class_of() {
	local target="$1" p c
	myc_vocab_load
	while IFS="$(printf '\t')" read -r p c; do
		[ "$p" = "$target" ] && { printf '%s' "$c"; return 0; }
	done <<MYC_VOCAB_EOF
$_MYC_VOCAB_CLASSMAP
MYC_VOCAB_EOF
	printf ''
}

# myc_vocab_port PROTO -> the registry default listen port for PROTO. Dies if PROTO has no registered
# port (callers pass only registered sing-box/xray protos; an empty result would be a silent miscompile).
myc_vocab_port() {
	local target="$1" p n
	myc_vocab_load
	while IFS="$(printf '\t')" read -r p n; do
		[ "$p" = "$target" ] && { printf '%s' "$n"; return 0; }
	done <<MYC_VOCAB_EOF
$_MYC_VOCAB_PORTMAP
MYC_VOCAB_EOF
	myc_die "vocab: no default port registered for proto '$target' in $MYC_VOCAB."
}

# myc_vocab_protos -> the space-separated, priority-ordered sing-box/xray proto list (the old
# MYC_SB_PROTOS, minus the standalone amneziawg dataplane). Spans BOTH engines — used for endpoint
# enumeration (bundle). For the sing-box RENDERER use myc_vocab_protos_singbox (below).
myc_vocab_protos() {
	myc_vocab_load
	printf '%s' "$_MYC_VOCAB_PROTOS"
}

# myc_vocab_protos_singbox -> only the protos the sing-box ENGINE serves (engine == "sing-box"). The
# sing-box renderer's MYC_SB_PROTOS derives from this so an enabled xray-engine proto (vless-xhttp-tls)
# is skipped, not fatally rendered into a config sing-box cannot load (ADR-0032 dual-engine).
myc_vocab_protos_singbox() {
	myc_vocab_load
	printf '%s' "$_MYC_VOCAB_PROTOS_SINGBOX"
}
