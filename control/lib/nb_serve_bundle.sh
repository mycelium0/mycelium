# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_serve_bundle.sh — node-bootstrap library: render the node's typed distribution Bundle and serve
# it fail-closed (last-known-good), plus the served-bundle staleness signal.
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: render the node's typed Bundle (internal/spec/bundle.go) via
# `myceliumctl bundle`, validate it, and promote it to the SERVED path ONLY after it validates —
# never overwriting the served file with an invalid one (C10), and exposing a bundle_served_age_seconds
# staleness signal so a stuck last-known-good fallback is observable, not silent (C25).
# CLASSIFICATION: CONTROL-LOGIC (validation) — the authoritative round-trip is the Go check
# (internal/spec.Bundle.Validate + Endpoint.Validate); this shell gate mirrors EVERY branch Go enforces
# and is EARMARKED for the RP-0008 Go migration, where it becomes a thin caller of the authoritative
# `validate-bundle`. Until then it stays bash, byte-identical. This file is meant to be SOURCED into
# scripts/node-bootstrap.sh, never executed directly; it defines functions + their dedicated constants
# only and relies on the entrypoint's shared globals (MYCTL, STATE_DIR, PARAMS_JSON, IDENTITIES_JSON,
# DRY_RUN) and helpers (log/warn/die/have/run/need_root) being defined at call time. Behaviour is
# byte-identical to the inline definitions it replaced.

# Served distribution bundle (RP-0007-b). The node renders its typed Bundle (internal/spec/bundle.go)
# via `myceliumctl bundle`, then SERVES it (e.g. via the caddy role's loopback bundle vhost) so a
# client self-polls (profile-update-interval). The SERVED copy is updated fail-closed: a freshly
# rendered bundle replaces the served file ONLY after it validates; on any failure the last-known-good
# served bundle is left in place (never serve an invalid bundle). Loopback-only by default; the
# operator fronts it via their chosen reach path, so the channel is never a single public chokepoint.
BUNDLE_DIR="/etc/mycelium/bundle"
BUNDLE_SERVED="$BUNDLE_DIR/bundle.json"           # the file the server serves (last-known-good)
BUNDLE_CANDIDATE="$STATE_DIR/bundle.candidate.json"
# C25 staleness signal: a tiny metrics file recording how old the SERVED bundle is (seconds since its
# mtime) at the last render attempt. A stuck last-known-good (fail-closed fallback that keeps serving an
# old bundle while fresh renders keep failing) is otherwise SILENT — only a warn, no age. This file lets a
# node-local exporter/operator observe the skew (a Prometheus-textfile-style `bundle_served_age_seconds N`
# line) without adding any daemon. Local-only / gitignored.
BUNDLE_SERVED_AGE_FILE="$STATE_DIR/bundle_served_age_seconds.prom"

# ---------------------------------------------------------------------------
# Served distribution bundle (RP-0007-b) — render + serve fail-closed.
#
# Renders the node's typed Bundle (internal/spec/bundle.go) via `myceliumctl bundle` into a
# candidate, then promotes it to the SERVED path ONLY after it validates. FAIL-CLOSED: if the fresh
# render fails (myceliumctl exits non-zero) OR the candidate is not valid JSON with the bundle shape,
# the previously-served (last-known-good) bundle is LEFT IN PLACE and the served file is never
# overwritten with an invalid one. The first-ever bootstrap has no last-known-good, so a failure
# there is a hard error (nothing valid to serve).
#
# Authoritative validation (internal/spec.Bundle.Validate) is Go-side; this shell gate enforces EVERY
# branch that Bundle.Validate + Endpoint.Validate check (version, >=1 endpoint, and per endpoint:
# non-empty tag, transport_class in the closed vocab, non-empty region, integer priority >= 0, health
# "unknown", non-empty link — C10), so a structurally-broken bundle never reaches the served path
# fail-open relative to the Go type.
# ---------------------------------------------------------------------------

# bundle_served_age_seconds — echo the age (seconds since mtime) of the SERVED bundle, or empty if none.
# Portable across GNU/BSD stat (Linux nodes use GNU; the macOS test host uses BSD).
bundle_served_age_seconds() {
	[ -f "$BUNDLE_SERVED" ] || { printf ''; return 0; }
	local mtime now
	mtime="$(stat -c %Y "$BUNDLE_SERVED" 2>/dev/null || stat -f %m "$BUNDLE_SERVED" 2>/dev/null || printf '')"
	[ -n "$mtime" ] || { printf ''; return 0; }
	now="$(date +%s 2>/dev/null || printf '')"
	[ -n "$now" ] || { printf ''; return 0; }
	local age=$(( now - mtime ))
	[ "$age" -lt 0 ] && age=0
	printf '%s' "$age"
}

# record_bundle_served_age STALE_FLAG — write the staleness metric file (Prometheus textfile style) and,
# when STALE_FLAG=1 (a fail-closed fallback kept the last-known-good), emit a loud age signal so a stuck
# stale bundle is OBSERVABLE, not just warned about once. Best-effort: never fails the caller.
record_bundle_served_age() {
	local stale_flag="${1:-0}" age
	[ "$DRY_RUN" -eq 1 ] && return 0
	age="$(bundle_served_age_seconds)"
	[ -n "$age" ] || return 0
	{
		printf '# HELP bundle_served_age_seconds Age (seconds) of the served distribution bundle at last render attempt.\n'
		printf '# TYPE bundle_served_age_seconds gauge\n'
		printf 'bundle_served_age_seconds %s\n' "$age"
		printf '# HELP bundle_served_stale Whether the served bundle is a kept last-known-good (1) vs freshly promoted (0).\n'
		printf '# TYPE bundle_served_stale gauge\n'
		printf 'bundle_served_stale %s\n' "$stale_flag"
	} >"$BUNDLE_SERVED_AGE_FILE" 2>/dev/null || true
	if [ "$stale_flag" = "1" ]; then
		warn "served bundle is now a STALE last-known-good: bundle_served_age_seconds=$age (a fresh render kept failing — investigate; metric at $BUNDLE_SERVED_AGE_FILE)."
	fi
}

render_serve_bundle() {
	[ -x "$MYCTL" ] || { warn "myceliumctl not found; skipping bundle render (sub channel unaffected)."; return 0; }
	[ -f "$PARAMS_JSON" ] || { warn "params.json missing; skipping bundle render."; return 0; }
	[ -f "$IDENTITIES_JSON" ] || { warn "identities.json missing; skipping bundle render."; return 0; }

	log "rendering served distribution bundle via myceliumctl -> $BUNDLE_CANDIDATE"
	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] $MYCTL bundle --params $PARAMS_JSON --state $IDENTITIES_JSON --out $BUNDLE_CANDIDATE"
		log "[dry-run] would serve validated bundle at $BUNDLE_SERVED (fail-closed: keep last-known-good on failure)"
		return 0
	fi

	# Render the candidate. A non-zero exit means NOTHING is promoted (fail-closed).
	if ! "$MYCTL" bundle --params "$PARAMS_JSON" --state "$IDENTITIES_JSON" --out "$BUNDLE_CANDIDATE" 2>/dev/null; then
		rm -f "$BUNDLE_CANDIDATE" 2>/dev/null || true
		if [ -f "$BUNDLE_SERVED" ]; then
			warn "bundle render failed; keeping the last-known-good served bundle ($BUNDLE_SERVED) — fail-closed."
			record_bundle_served_age 1
			return 0
		fi
		die "bundle render failed and there is no last-known-good served bundle (fail-closed; nothing valid to serve)."
	fi

	# Structural validation mirroring internal/spec.Bundle.Validate + Endpoint.Validate (bundle.go) —
	# the authoritative round-trip is the Go check, but this jq gate must enforce EVERY branch Go does so
	# the served path is not fail-open relative to the type (C10). Per Endpoint.Validate: non-empty tag,
	# transport_class in the closed vocab, non-empty region, priority an integer >= 0, health == unknown
	# (Phase-1), non-empty link. Per Bundle.Validate: version == NetworkStateVersion (1), >= 1 endpoint.
	if ! jq -e '
		(.version == 1)
		and (.endpoints | type == "array") and (.endpoints | length >= 1)
		and (.endpoints | all((.tag | type == "string") and ((.tag | length) > 0)))
		and (.endpoints | all(.transport_class | IN(
			"reality-tcp","xhttp-tls","ws-tls","quic-udp","shadowsocks-tcp",
			"shadowtls-tcp","trojan-tls","amneziawg-udp")))
		and (.endpoints | all((.region | type == "string") and ((.region | length) > 0)))
		and (.endpoints | all((.priority | type == "number") and (.priority >= 0) and ((.priority | floor) == .priority)))
		and (.endpoints | all(.health == "unknown"))
		and (.endpoints | all((.link | type == "string") and ((.link | length) > 0)))
		and (.generated_at | type == "string")
	' "$BUNDLE_CANDIDATE" >/dev/null 2>&1; then
		rm -f "$BUNDLE_CANDIDATE" 2>/dev/null || true
		if [ -f "$BUNDLE_SERVED" ]; then
			warn "freshly rendered bundle failed validation; keeping the last-known-good served bundle — fail-closed."
			record_bundle_served_age 1
			return 0
		fi
		die "freshly rendered bundle failed validation and there is no last-known-good to fall back to (fail-closed)."
	fi

	# Promote the validated candidate to the served path (atomic install into the served dir).
	need_root
	run mkdir -p "$BUNDLE_DIR"
	run install -m 0644 "$BUNDLE_CANDIDATE" "$BUNDLE_SERVED"
	rm -f "$BUNDLE_CANDIDATE" 2>/dev/null || true
	# Fresh promotion: the served bundle is now current (stale=0, age ~0). Record the metric so an operator
	# can distinguish a healthy fresh serve from a stuck last-known-good.
	record_bundle_served_age 0
	log "served bundle updated (validated): $BUNDLE_SERVED ($(jq '.endpoints | length' "$BUNDLE_SERVED" 2>/dev/null || echo '?') endpoint(s))."
	log "serve it over HTTPS with a profile-update-interval header so clients self-poll (see roles/caddy: caddy_serve_bundle)."
}
