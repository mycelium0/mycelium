# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_update_apply.sh — node-bootstrap library: the signed-pull / fail-closed apply state machine —
# authenticate fetched artifacts (verify_signed_ref), fetch them (myc_fetch_artifacts), and the
# render -> validate -> promote / rollback config primitives (render_candidate, validate_config,
# promote_config, rollback_config).
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: own the on-node apply state machine (ADR-0015) — (1) verify_signed_ref, the
# out-of-band-key SUPPLY-CHAIN authenticity gate that must pass BEFORE any fetched code runs; (2)
# myc_fetch_artifacts, the swappable fetch step (pinned git pull NOW; signed release tarball LATER) that
# is the ONLY place that knows HOW canonical artifacts arrive and that refuses anything failing the
# signature gate; (3) render_candidate, which renders the canonical config THROUGH myceliumctl into a
# candidate file (never promoting); (4) validate_config, the fail-closed `sing-box check` gate the
# renderer does not run itself; (5) promote_config, the atomic live-config replace that keeps a
# known-good backup; and (6) rollback_config, the restore-from-last-known-good path.
# CLASSIFICATION: CONTROL-LOGIC (the apply state machine) — the fail-closed render/validate/promote/
# rollback sequence and the signature gate are the on-node decision spine, and are the HIGHEST-VALUE
# EARMARK for the RP-0008 Go migration (internal/spec / cmd), where the typed apply pipeline will own
# this. Until then it stays bash, byte-identical. This file is meant to be SOURCED into
# scripts/node-bootstrap.sh, never executed directly; it defines functions only and relies on the
# entrypoint's shared globals (CHECKOUT_DIR, REPO_URL, REPO_REF, ALLOWED_SIGNERS, INSECURE_NO_VERIFY,
# DRY_RUN, MYCTL, RENDER_TEMPLATE, PARAMS_JSON, IDENTITIES_JSON, SINGBOX_BIN, SINGBOX_CONFIG,
# LASTGOOD_CONFIG) and helpers (log/warn/die/have/run/need_root) being defined at call time — they are
# all final after arg-parse / the derived-path block, above the source point. The flow_* dispatchers in
# the entrypoint (flow_bootstrap/flow_update/flow_ack/flow_revoke) call render_candidate/validate_config/
# promote_config/rollback_config (and flow_update calls myc_fetch_artifacts); those calls resolve at
# runtime from the shared sourced scope. The --update re-exec-from-immutable-copy guard stays in
# flow_update (orchestration). Behaviour is byte-identical to the inline definitions it replaced.

# ---------------------------------------------------------------------------
# Authenticity gate for fetched artifacts (SUPPLY-CHAIN). Fast-forward-only stops history
# rewrites but does NOT stop a brand-new malicious commit reaching every node: a single bad push
# to a PUBLIC repo would otherwise be applied network-wide by a root timer, and "sing-box check"
# only validates config SCHEMA, never PROVENANCE. So we require the canonical ref to carry a
# signature from an OUT-OF-BAND operator key (never committed) and verify it BEFORE any fetched
# code is merged/installed/executed. The verified signature IS the real "semi-auto human
# approval" — not merely "a commit exists on origin".
# ---------------------------------------------------------------------------
verify_signed_ref() {
	# verify_signed_ref REVISION — fail-closed unless REVISION carries a valid signature from the
	# operator's out-of-band key. Honors SSH allowedSigners (preferred) or GPG. Refuses on any
	# failure. --insecure-no-verify (testing only) is the ONLY way to bypass this.
	local rev="$1"
	if [ "$INSECURE_NO_VERIFY" -eq 1 ]; then
		warn "SIGNATURE VERIFICATION DISABLED via --insecure-no-verify — fetched code is UNAUTHENTICATED."
		warn "This is acceptable ONLY for local testing. NEVER run the network timer with this flag."
		return 0
	fi
	[ -n "$ALLOWED_SIGNERS" ] \
		|| die "no --allowed-signers given: cannot authenticate fetched artifacts (fail-closed). Ship the operator's out-of-band signing key and pass --allowed-signers, or use --insecure-no-verify for local testing only."
	[ -e "$ALLOWED_SIGNERS" ] || die "--allowed-signers path not found: $ALLOWED_SIGNERS (fail-closed)."
	have git || die "git required to verify the signed ref."
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would verify-commit/verify-tag $rev against $ALLOWED_SIGNERS"; return 0; fi

	# Prefer SSH-signature verification (operator allowedSigners file). gitconfig is scoped to this
	# checkout only; we do not mutate any global config.
	local ok=0
	# If REVISION resolves to an annotated tag, verify the tag object; otherwise verify the commit.
	local objtype
	objtype="$(git -C "$CHECKOUT_DIR" cat-file -t "$rev" 2>/dev/null || true)"
	if git -C "$CHECKOUT_DIR" -c gpg.ssh.allowedSignersFile="$ALLOWED_SIGNERS" -c gpg.format=ssh \
		verify-tag "$rev" >/dev/null 2>&1; then ok=1; fi
	if [ "$ok" -ne 1 ] && [ "$objtype" = "commit" ] \
		&& git -C "$CHECKOUT_DIR" -c gpg.ssh.allowedSignersFile="$ALLOWED_SIGNERS" -c gpg.format=ssh \
			verify-commit "$rev" >/dev/null 2>&1; then ok=1; fi
	# Fall back to GPG verification (GNUPGHOME pointed at the operator keyring) if SSH did not match.
	if [ "$ok" -ne 1 ]; then
		if GNUPGHOME="$ALLOWED_SIGNERS" git -C "$CHECKOUT_DIR" verify-tag "$rev" >/dev/null 2>&1; then ok=1; fi
		if [ "$ok" -ne 1 ] && [ "$objtype" = "commit" ] \
			&& GNUPGHOME="$ALLOWED_SIGNERS" git -C "$CHECKOUT_DIR" verify-commit "$rev" >/dev/null 2>&1; then ok=1; fi
	fi
	[ "$ok" -eq 1 ] \
		|| die "signature verification FAILED for '$rev' — refusing to apply unauthenticated artifacts (fail-closed). A valid operator signature is the required approval."
	log "signature verified for '$rev' against the operator key (out-of-band)."
}

# ---------------------------------------------------------------------------
# fetch step — abstracted so the source is swappable (pinned git pull NOW; signed release
# tarball LATER). This is the ONLY place that knows HOW canonical artifacts arrive.
# ---------------------------------------------------------------------------
myc_fetch_artifacts() {
	# Bring CHECKOUT_DIR to the pinned canonical state. Returns 0 on success.
	# DEFAULT IMPLEMENTATION: a pinned, fast-forward-only git fetch + a SIGNATURE-VERIFIED merge.
	# To swap to releases later, replace the body with: download the signed tarball, verify its
	# signature + checksum, and unpack into CHECKOUT_DIR. The signature gate (verify_signed_ref /
	# the tarball's detached signature) MUST be preserved — it is the provenance guarantee, not an
	# optional extra. The rest of the updater is unchanged.
	have git || die "git required for the default fetch implementation (or swap myc_fetch_artifacts)."
	if [ ! -d "$CHECKOUT_DIR/.git" ]; then
		[ -n "$REPO_URL" ] || die "no checkout at $CHECKOUT_DIR and no --repo-url given (fail-closed)."
		log "cloning canonical artifacts: $REPO_URL -> $CHECKOUT_DIR"
		run git clone ${REPO_REF:+--branch "$REPO_REF"} "$REPO_URL" "$CHECKOUT_DIR" \
			|| die "git clone failed."
		# Verify the cloned ref (or HEAD) is operator-signed before anything is ever executed from it.
		verify_signed_ref "${REPO_REF:-HEAD}"
		return 0
	fi
	local ref
	ref="$REPO_REF"
	[ -n "$ref" ] || ref="$(git -C "$CHECKOUT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
	log "fetching canonical artifacts (ref: ${ref:-current})"
	# Fetch ONLY updates remote-tracking refs + tags; it does NOT touch the working tree, so no
	# fetched code runs yet. We verify the SIGNATURE on the fetched objects BEFORE merging.
	run git -C "$CHECKOUT_DIR" fetch --prune --tags origin || die "git fetch failed."
	# Resolve the exact revision we are about to apply. Pin --repo-ref to an IMMUTABLE SIGNED TAG;
	# a bare branch HEAD is advanceable by any push and is verified per-commit only as a fallback.
	local target
	if git -C "$CHECKOUT_DIR" rev-parse -q --verify "refs/tags/${ref}^{tag}" >/dev/null 2>&1 \
		|| git -C "$CHECKOUT_DIR" rev-parse -q --verify "refs/tags/${ref}" >/dev/null 2>&1; then
		target="refs/tags/${ref}"          # an immutable signed tag — the recommended pin
	else
		target="origin/${ref:-HEAD}"       # a moving branch — verified per-commit (less preferred)
		warn "tracking branch '$ref' (mutable): pin --repo-ref to a SIGNED TAG so the approval is immutable."
	fi
	# AUTHENTICITY GATE: refuse unless the target carries a valid operator signature.
	verify_signed_ref "$target"
	# Fast-forward ONLY: never rewrite local history; never take a force-push silently. Only after a
	# successful signature check does the verified revision touch the working tree.
	run git -C "$CHECKOUT_DIR" merge --ff-only "$target" \
		|| die "fast-forward update failed (history diverged or force-pushed) — refusing (fail-closed)."
}

# ---------------------------------------------------------------------------
# Render the canonical config THROUGH the existing myceliumctl pipeline, into a candidate file.
# Echoes the candidate path on success. NEVER promotes here.
# ---------------------------------------------------------------------------
render_candidate() {
	local candidate="$1"
	log "rendering candidate config via myceliumctl -> $candidate"
	[ -x "$MYCTL" ] || die "myceliumctl not found/executable: $MYCTL"
	[ -f "$RENDER_TEMPLATE" ] || die "renderer-compatible template missing: $RENDER_TEMPLATE"
	[ -f "$PARAMS_JSON" ] || die "params.json missing; run write_params first."
	[ -f "$IDENTITIES_JSON" ] || die "identities.json missing; run ensure_identity first."
	run "$MYCTL" render-server \
		--engine singbox \
		--template "$RENDER_TEMPLATE" \
		--params "$PARAMS_JSON" \
		--state "$IDENTITIES_JSON" \
		--out "$candidate" \
		|| die "render-server failed (fail-closed; nothing promoted)."
}

# sing-box check is the fail-closed GATE the renderer does NOT run itself.
validate_config() {
	local cfg="$1"
	log "validating candidate with 'sing-box check' (fail-closed gate)"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] sing-box check -c $cfg"; return 0; fi
	have "$SINGBOX_BIN" || die "sing-box binary missing; cannot validate."
	"$SINGBOX_BIN" check -c "$cfg" || return 1
}

promote_config() {
	# Atomically replace the live config with the candidate, keeping a known-good backup.
	local candidate="$1"
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] promote $candidate -> $SINGBOX_CONFIG"; return 0; fi
	if [ -f "$SINGBOX_CONFIG" ]; then cp -f "$SINGBOX_CONFIG" "$LASTGOOD_CONFIG"; fi
	install -m 0644 "$candidate" "$SINGBOX_CONFIG"
	log "promoted candidate to live config: $SINGBOX_CONFIG"
}

rollback_config() {
	need_root
	if [ -f "$LASTGOOD_CONFIG" ]; then
		warn "rolling back to last known-good config (fail-closed)."
		run install -m 0644 "$LASTGOOD_CONFIG" "$SINGBOX_CONFIG"
	else
		warn "no last-known-good config to roll back to; leaving the running service untouched."
	fi
}
