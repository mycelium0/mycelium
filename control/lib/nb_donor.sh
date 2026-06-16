# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_donor.sh — node-bootstrap library: REALITY donor-SNI selection + runtime verification.
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: choose ONE verified donor SNI for this node (RANDOM per node from the
# committed candidate list), enforcing TLSv1.3-over-x25519 as the hard gate and h2 ALPN as a soft
# preference. CLASSIFICATION: OS-glue — it probes a REAL external host over the network (openssl
# s_client) and reads the committed candidate list (jq); the chosen value is stored in LOCAL
# identity state, never committed. This file is meant to be SOURCED into scripts/node-bootstrap.sh,
# never executed directly; it defines functions only and relies on the entrypoint's shared globals
# (DONOR_LIST, FORCE_DONOR, DRY_RUN) and helpers (log/warn/die/have) being defined at call time.
# Behaviour is byte-identical to the inline definitions it replaced.

donor_candidates() {
	have jq || die "jq required to read the donor candidate list."
	[ -f "$DONOR_LIST" ] || die "donor candidate list not found: $DONOR_LIST"
	jq -r '.candidates[]?' "$DONOR_LIST"
}

donor_verify() {
	# donor_verify HOST -> 0 if HOST negotiates TLSv1.3 over an x25519 group (REALITY's HARD
	# requirement). The donor list's "require" also promises h2 ALPN "where offered"; that is a
	# best-effort PREFERENCE, not a hard gate (see donor_offers_h2 + pick_donor), so the script's
	# check and the JSON's promise agree (we do not over-promise).
	local host="$1"
	have openssl || { warn "openssl missing; cannot verify donor '$host' — treating as unverified."; return 1; }
	# Fail-closed: a non-TLSv1.3 / non-x25519 donor is rejected so a bad SNI never reaches the config.
	echo | openssl s_client -groups x25519 -tls1_3 \
		-servername "$host" -connect "$host:443" 2>/dev/null \
		| grep -q 'TLSv1.3'
}

donor_offers_h2() {
	# donor_offers_h2 HOST -> 0 if HOST negotiates the h2 ALPN. Best-effort PREFERENCE only: a donor
	# that lacks h2 is still acceptable (the JSON promises h2 "where offered"), so a non-zero here
	# never rejects a donor — it only de-prioritises it in pick_donor. REALITY mirrors whatever the
	# donor actually negotiates, so preferring an h2 donor keeps the borrowed fingerprint realistic.
	local host="$1"
	have openssl || return 1
	echo | openssl s_client -alpn h2,http/1.1 -tls1_3 \
		-servername "$host" -connect "$host:443" 2>/dev/null \
		| grep -Eq '^[[:space:]]*ALPN protocol:[[:space:]]*h2[[:space:]]*$'
}

pick_donor() {
	# Echo a verified donor host. Honors --donor (still verified). Tries candidates in random order.
	if [ -n "$FORCE_DONOR" ]; then
		if [ "$DRY_RUN" -eq 1 ] || donor_verify "$FORCE_DONOR"; then
			printf '%s\n' "$FORCE_DONOR"; return 0
		fi
		die "forced donor '$FORCE_DONOR' did not negotiate TLSv1.3 over x25519 (fail-closed)."
	fi
	local shuffled host
	# Shuffle without external deps: number, sort -R if available, else awk rand-tag.
	if have shuf; then
		shuffled="$(donor_candidates | shuf)"
	elif sort -R </dev/null >/dev/null 2>&1; then
		shuffled="$(donor_candidates | sort -R)"
	else
		shuffled="$(donor_candidates | awk 'BEGIN{srand()} {printf "%f\t%s\n", rand(), $0}' | sort | cut -f2-)"
	fi
	# Two-pass selection that keeps the JSON's "h2 ALPN where offered" promise honest WITHOUT
	# over-promising: TLSv1.3+x25519 is the HARD gate (donor_verify); h2 is a soft PREFERENCE. Pass 1
	# returns the first candidate that passes the hard gate AND offers h2; if none does, pass 2 falls
	# back to the first candidate that merely passes the hard gate. So a network with only non-h2 donors
	# still bootstraps (no false failure), but an h2 donor wins when one exists.
	local first_hard_ok=""
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		if [ "$DRY_RUN" -eq 1 ]; then printf '%s\n' "$host"; return 0; fi
		if donor_verify "$host"; then
			[ -n "$first_hard_ok" ] || first_hard_ok="$host"   # remember for the fallback pass
			if donor_offers_h2 "$host"; then printf '%s\n' "$host"; return 0; fi
			warn "donor candidate '$host' passes TLSv1.3/x25519 but did not offer h2 ALPN; preferring an h2 donor if available."
		else
			warn "donor candidate '$host' failed verification; trying the next."
		fi
	done <<EOF
$shuffled
EOF
	if [ -n "$first_hard_ok" ]; then
		warn "no candidate offered h2 ALPN; using '$first_hard_ok' (TLSv1.3/x25519 verified — the hard requirement)."
		printf '%s\n' "$first_hard_ok"; return 0
	fi
	die "no donor candidate negotiated TLSv1.3 over x25519 (fail-closed). Update the candidate list."
}
