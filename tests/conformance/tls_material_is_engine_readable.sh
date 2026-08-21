#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# tls_material_is_engine_readable.sh — conformance: the cert the engine has to open is made readable by
# the engine, on every converge — not only on the run that generated it.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   MEASURED by the from-zero drill, 2026-08-17. A node was rebuilt from nothing with the operator's own
#   wildcard cert restored into $STATE_DIR/tls, and came up with sing-box in a restart loop:
#
#       FATAL initialize inbound[1]: read certificate: open .../tls/fullchain.pem: permission denied
#
#   It failed at `systemctl start` — AFTER `sing-box check` had passed and the candidate had been
#   promoted. `check` parses the config as root and never opens the key as the service user, so the whole
#   render -> validate -> promote chain reported success while the data plane was down. A fail-LATE, past
#   every gate that was supposed to catch it.
#
#   THE CAUSE, and it is the shape this project keeps finding: the ownership reconciliation sat at the END
#   of `ensure_self_signed_cert`, below an early `return 0` taken when a cert is already present. So the
#   one case it exists for — an operator-supplied cert, which is EVERY node serving a real SNI, because a
#   public name cannot be self-signed — was the one case it never ran in.
#
# WHAT IT CHECKS, by DRIVING the shipped function
#   1. With a cert ALREADY PRESENT, ensure_self_signed_cert still reconciles ownership and mode. This is
#      the branch that was broken.
#   2. With no cert, it generates one AND reconciles — the branch that always worked, so that fixing the
#      first did not break the second.
#   3. It is reconciliation, not generation: an existing cert is never overwritten. A node whose operator
#      placed a real cert must not have it replaced by a self-signed one on the next converge.
#
#   `run` is stubbed to a recorder rather than executed: chown needs root, and what is under test is what
#   the function DOES — which commands it issues against which path — not whether this host permits them.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the engine can open its own cert; 1 = it may not.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'tls_material_is_engine_readable: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_install.sh"
[ -f "$LIB" ] || { printf 'tls_material_is_engine_readable: missing %s\n' "$LIB" >&2; exit 2; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the engine can open the cert it is told to serve ==\n\n'

# drive <preexisting:yes|no> -> the recorded command trace
drive() {
	local pre="$1" W
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.tlsm.XXXXXX")" || return 1
	mkdir -p "$W/tls"
	if [ "$pre" = yes ]; then
		printf 'PRE-EXISTING CERT\n' >"$W/tls/fullchain.pem"
		printf 'PRE-EXISTING KEY\n'  >"$W/tls/privkey.pem"
	fi
	(
		export STATE_DIR="$W" DRY_RUN=0 TRACE="$W/trace"
		TLS_DIR="$W/tls"; SINGBOX_RUN_GROUP="sing-box"
		log() { :; }; warn() { :; }; die() { printf 'die %s\n' "$*" >>"$TRACE"; exit 7; }
		have() { command -v "$1" >/dev/null 2>&1; }
		# The recorder. Every mutation this function performs goes through run(), so the trace IS what it did.
		run() { printf '%s\n' "$*" >>"$TRACE"; }
		# shellcheck source=/dev/null
		. "$LIB" >/dev/null 2>&1 || exit 2
		TLS_DIR="$W/tls"; SINGBOX_RUN_GROUP="sing-box"
		ensure_self_signed_cert "example.invalid"
	) >/dev/null 2>&1
	cat "$W/trace" 2>/dev/null
	# report whether the pre-existing content survived
	[ "$pre" = yes ] && { grep -q 'PRE-EXISTING CERT' "$W/tls/fullchain.pem" 2>/dev/null && printf 'PRESERVED\n'; }
	rm -rf "$W"
}

# ---------------------------------------------------------------------------------------------------
# 1. THE BRANCH THAT WAS BROKEN.
# ---------------------------------------------------------------------------------------------------
printf -- '-- a cert that is already there --\n'
t="$(drive yes)"
if grep -q 'chown -R root:sing-box' <<<"$t" ; then
	ok "ownership is reconciled even though nothing was generated"
else
	badln "ensure_self_signed_cert did NOT chown an already-present cert (trace: $(printf '%s' "$t" | tr '\n' '|' | cut -c1-160)). That is the from-zero failure: an operator-supplied cert stays unreadable by the engine, sing-box check still passes because it never opens the key as the service user, and the node reports a successful deploy with its data plane in a restart loop."
fi
grep -q 'chmod 0640 .*privkey.pem' <<<"$t" \
	&& ok "and the key is 0640 — readable by the service group, by nobody else" \
	|| badln "the private key mode is not reconciled to 0640 on the already-present branch"
grep -q 'chmod 0644 .*fullchain.pem' <<<"$t" \
	&& ok "and the chain is 0644" \
	|| badln "the certificate chain mode is not reconciled on the already-present branch"

# ---------------------------------------------------------------------------------------------------
# 2. THE BRANCH THAT ALWAYS WORKED — fixing one must not break the other.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and a node with no cert at all --\n'
t2="$(drive no)"
grep -q 'openssl req -x509' <<<"$t2" \
	&& ok "a fresh node still generates its self-signed cert" \
	|| badln "no cert is generated on an empty node (trace: $(printf '%s' "$t2" | tr '\n' '|' | cut -c1-140)) — a fresh bootstrap would have no TLS material at all"
grep -q 'chown -R root:sing-box' <<<"$t2" \
	&& ok "and reconciles ownership after generating it" \
	|| badln "the generate branch no longer chowns; it did before, and moving the reconciliation must not have dropped it"

# ---------------------------------------------------------------------------------------------------
# 3. RECONCILE, NEVER REPLACE.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and it never replaces what the operator placed --\n'
if grep -q 'PRESERVED' <<<"$t" ; then
	ok "an existing cert survives the converge untouched"
else
	badln "the operator's cert did not survive. Overwriting a real certificate with a self-signed one takes every genuine-TLS transport off the air, and the node cannot get the real one back by itself — there is no ACME client on these nodes."
fi
grep -q 'openssl req -x509' <<<"$t" \
	&& badln "the already-present branch ran the generator. That is the same defect from the other side: a converge would replace the operator's certificate." \
	|| ok "and the generator is not run when a cert is already there"

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the engine may be unable to open the cert it is told to serve.\n' >&2
	exit 1
fi
printf 'PASS: the cert is reconciled on every converge, generated only when absent, and never replaced.\n'
exit 0
