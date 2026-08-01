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
# code is merged/installed/executed.
#
# WHAT THE SIGNATURE ESTABLISHES (amended, Audit-0009 V1). This header used to say the verified signature
# IS the "semi-auto human approval". It is not, and saying so misled every reader of the armed path: local
# signing is unconditional, so every commit on a mutable branch pin is signed whether or not it was meant
# to ship. What verify_signed_ref establishes is PROVENANCE — this came from the operator's key, not from
# a forged or third-party push — which is the property the armed fetch actually depends on. APPROVAL is a
# separate artifact and a branch-tip pin has none: the approving act is the `git push`, which leaves the
# node nothing to verify. Pin --repo-ref to an immutable signed TAG, or arm --staged/--ack, to have both.
# See ADR-0015 Decision 2.
# ---------------------------------------------------------------------------
# _insecure_bypass_permitted — PURE decision: may --insecure-no-verify actually bypass the signature gate
# in THIS execution context? rc 0 = permitted, rc 1 = refused. Reads only DRY_RUN and the two environment
# facts below, so a gate can drive it directly with no side effects (Audit-0009 W1).
#
# THE DEFECT THIS CLOSES. The flag is documented everywhere as testing-only and "never on the timer", and
# every one of those statements was PROSE: verify_signed_ref warned and returned 0 regardless of who
# invoked it or from where. Prose is not containment — a drop-in on an armed node could carry the flag and
# the code would cheerfully disable its own provenance gate every 15 minutes as root. The rule now has
# teeth: the bypass is permitted ONLY where it cannot run unattended.
#
#   * --dry-run          -> PERMITTED. Nothing is fetched, promoted or executed, so there is nothing to
#                           authenticate; this is also how the offline conformance gate exercises the
#                           update path (tests/conformance/node_update_artifact_root.sh).
#   * under systemd      -> REFUSED. $INVOCATION_ID is set by systemd for every unit invocation, which is
#                           exactly the unattended case the doctrine forbids. This is the load-bearing arm.
#   * stdin not a TTY    -> REFUSED. "Local testing" means a human at a terminal. A cron job, a pipe, a
#                           remote non-interactive ssh command and a CI runner are all unattended.
#   * otherwise          -> PERMITTED, with the existing loud warning.
#
# Deliberately NOT overridable by an env var: an escape hatch for the escape hatch is how this ends up
# back on a timer. An operator who genuinely needs an unattended unsigned fetch must say so in the unit,
# and there is no flag that lets them.
_insecure_bypass_permitted() {
	[ "${DRY_RUN:-0}" -eq 1 ] && return 0
	[ -n "${INVOCATION_ID:-}" ] && return 1
	[ -t 0 ] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# clear_retired_config_snapshots — drop the secret-bearing failure snapshots once a config is live and
# verified. Called at the TOP of converge_node_tail, so it runs on EVERY promote path rather than one.
#
# WHAT THESE FILES ARE (Audit-0009 R1). config.failed.json and config.invalid.json each hold a
# byte-for-byte rendered sing-box server config: the REALITY private key, every transport password, and
# every client's `users` entry. config.lastgood.json, their pre-existing peer, is bounded by construction —
# the next promote overwrites it. These two were not: they were cleared only inside flow_update, and
# flow_revoke / flow_node_apply / rotate / disable-two-hop all end in converge_node_tail, which cleared
# nothing. So on a node in the posture the runbook documents as valid — installed but NOT armed, where
# flow_update runs only when an operator invokes it — a credential the operator had deliberately RETIRED
# (a revoked client's UUID and PSK, a secret superseded by a rotation) survived at rest, unbounded in time,
# past the very operation whose purpose was to retire it, while the revoke line reported the UUID "gone
# from every inbound on BOTH engines".
#
# WHY AT THE TOP OF THE TAIL, not the bottom: apply_node_xray_engine — the tail's first step — writes
# xray.config.failed.json when it rejects a candidate. Clearing afterwards would delete the evidence the
# same run just produced. Clearing first retires only what predates this converge, which is exactly the
# set that is now stale.
#
# NOT a security boundary, a RETENTION bound. All three files are 0600 in the state dir, inside the secret
# boundary the threat model already documents; nothing here widens or narrows that. What changes is how
# long a retired credential lingers there.
clear_retired_config_snapshots() {
	[ "${DRY_RUN:-0}" -eq 0 ] || return 0
	local f
	for f in "${FAILED_CONFIG:-}" "${FAILED_SINCE:-}" "${INVALID_CONFIG:-}" "${XRAY_INVALID_CONFIG:-}" \
	         "${STATE_DIR:+$STATE_DIR/xray.config.failed.json}"; do
		[ -n "$f" ] || continue
		[ -e "$f" ] || continue
		rm -f "$f" 2>/dev/null || true
	done
}

# ---------------------------------------------------------------------------
# myc_update_retry_hold ATTEMPTS FAILED_MTIME NOW — PURE anti-flap hold arithmetic for flow_update's
# byte-identity refusal. Echoes "HOLD AGE" in seconds on stdout; the caller holds iff AGE < HOLD. No
# stat(1), no date(1), no file access, no globals beyond the two tunables — the I/O stays at the call
# site so this can be driven directly from a value table.
#
# WHY IT IS A FUNCTION AT ALL (Audit-0009 M1/O1). The arithmetic used to be inline in flow_update, and
# its gate asserted the SPELLING of the expressions with literal greps — never executing them. Two
# single-token mutations (flipping a `-le`, reversing a subtraction) disabled the guard outright while
# all nine assertions stayed green, and a pure rename with no behaviour change turned the gate red. That
# is the incentive exactly backwards. Extracted, the ladder is a table the gate can check.
#
# WHY AN ATTEMPT COUNT, NOT A CALENDAR DELTA (Audit-0009 P1). The hold used to be the elapsed time
# between two file mtimes, so any gap in the timer's cadence — a node offline, a dead timer, a run of
# ticks dying before the guard — sent the SECOND failure of the same candidate straight to the 6 h cap
# instead of the documented 1 h → 1 h → 2 h → 4 h → 6 h ramp: the node furthest behind waited longest.
# The ladder now counts consecutive failures of this candidate, which is what "escalate" meant all along:
#   attempts  1     2     3     4     5+
#   hold      1 h   1 h   2 h   4 h   6 h (capped)
#
# FAIL-SAFE, deliberately. Any unusable input yields "0 0" — AGE < HOLD is then false, so the caller
# PROMOTES. This is a throttle over an already fail-closed path (validate → promote → verify → rollback);
# the worst case of a broken calculator is today's un-throttled behaviour, which that machinery already
# contains. It must never invent a hold out of garbage: a guard that can wedge updates is worse than the
# flap it fixes.
myc_update_retry_hold() {
	local attempts="${1:-}" fmtime="${2:-}" now="${3:-}"
	local min="${UPDATE_RETRY_HOLD_MIN_SEC:-3600}" max="${UPDATE_RETRY_HOLD_MAX_SEC:-21600}"
	local age hold step
	case "$fmtime" in ''|*[!0-9]*) printf '0 0\n'; return 0 ;; esac
	case "$now"    in ''|*[!0-9]*) printf '0 0\n'; return 0 ;; esac
	case "$min"    in ''|*[!0-9]*) min=3600 ;; esac
	case "$max"    in ''|*[!0-9]*) max=21600 ;; esac
	[ "$max" -ge "$min" ] || max="$min"
	age=$(( now - fmtime ))
	# A clock that went backwards is not evidence of a young failure — it is no evidence at all.
	[ "$age" -ge 0 ] || { printf '0 0\n'; return 0; }
	# An unreadable or absent count is one attempt: throttle at the FLOOR rather than not at all. The
	# count is rewritten on every failure (flow_update), so this self-heals on the next tick.
	case "$attempts" in ''|*[!0-9]*) attempts=1 ;; esac
	[ "$attempts" -ge 1 ] || attempts=1
	hold="$min"; step="$attempts"
	# Double once per attempt past the second; the `< max` term bounds the loop for any count.
	while [ "$step" -gt 2 ] && [ "$hold" -lt "$max" ]; do
		hold=$(( hold * 2 )); step=$(( step - 1 ))
	done
	[ "$hold" -le "$max" ] || hold="$max"
	printf '%s %s\n' "$hold" "$age"
}

verify_signed_ref() {
	# verify_signed_ref REVISION — fail-closed unless REVISION carries a valid signature from the
	# operator's out-of-band key. Honors SSH allowedSigners (preferred) or GPG. Refuses on any
	# failure. --insecure-no-verify (testing only) is the ONLY way to bypass this, and only where
	# _insecure_bypass_permitted allows it.
	local rev="$1"
	if [ "$INSECURE_NO_VERIFY" -eq 1 ]; then
		if ! _insecure_bypass_permitted; then
			warn "--insecure-no-verify was passed, but this is an UNATTENDED context$([ -n "${INVOCATION_ID:-}" ] && printf ' (running under systemd)' || printf ' (stdin is not a terminal)')."
			warn "The flag disables the provenance gate that stands between a fetched commit and root"
			warn "execution on this node. It is a by-hand, at-a-terminal testing tool, and refusing it here is"
			warn "the containment the documentation alone never provided (Audit-0009 W1)."
			die "refusing to bypass signature verification unattended (fail-closed). Pass --allowed-signers with a real key, or run this by hand from a terminal."
		fi
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
# keep_invalid_candidate SRC DEST LABEL REPRO_CMD — preserve the bytes a validator just rejected, for the
# operator to diff. 0600: a rejected candidate inlines the same secrets as the live config.
#
# AT THE VALIDATE SEAM, not in one flow (Audit-0009 AE1). This lived inside flow_update, which made it a
# special case of one caller rather than a property of validation — and the engine it did not cover is the
# one that needed it most. An xray candidate rejected by `xray run -test` was unlinked and the run died on
# EVERY path including the unattended one, which reaches that gate through converge_node_tail AFTER the
# sing-box config is already promoted: a red unit, a half-converged node (new sing-box config live, stale
# xray config) and no bytes to diff — because the same tick's fetch had already replaced the template and
# the renderer that produced them.
#
# Written only when the bytes CHANGE, so the mtime means "when this exact invalid candidate first appeared"
# rather than "one tick ago". Never fatal, never blocking: failing to keep evidence must not turn a
# validation failure into a different failure.
keep_invalid_candidate() {
	local src="$1" dest="$2" label="$3" repro="$4"
	[ "${DRY_RUN:-0}" -eq 0 ] || return 0
	[ -n "$dest" ] && [ -f "$src" ] || return 0
	if [ ! -f "$dest" ] || ! cmp -s "$src" "$dest"; then
		install -m 0600 "$src" "$dest" 2>/dev/null || return 0
	fi
	warn "the rejected $label candidate was kept at $dest (0600); its mtime is when these exact bytes first failed."
	warn "'$repro' reproduces the failure without re-rendering."
	return 0
}

validate_config() {
	local cfg="$1"
	log "validating candidate with 'sing-box check' (fail-closed gate)"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] sing-box check -c $cfg"; return 0; fi
	have "$SINGBOX_BIN" || die "sing-box binary missing; cannot validate."
	"$SINGBOX_BIN" check -c "$cfg" && return 0
	keep_invalid_candidate "$cfg" "${INVALID_CONFIG:-}" "sing-box" \
		"$SINGBOX_BIN check -c ${INVALID_CONFIG:-}"
	return 1
}

promote_config() {
	# Atomically replace the live config with the candidate, keeping a known-good backup.
	local candidate="$1"
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] promote $candidate -> $SINGBOX_CONFIG"; return 0; fi
	# SERIALISE THE MUTATION (Audit-0009 G1). Five flows render-validate-promote, and with the update
	# timer armed a hand-run --node-apply races a tick. Candidates are already written atomically and are
	# now per-flow, so nothing can read a torn or foreign candidate — what remained unprotected is THIS
	# window: two promoters interleaving the lastgood snapshot and the live replace, which can leave
	# lastgood holding the OTHER flow's config, i.e. a rollback net pointing at the wrong rev.
	# Bounded and non-wedging, the nb_donor.sh pattern: fd 9 in a subshell (auto-released on exit),
	# `flock -w 30` so a stuck holder DEGRADES to unserialised rather than hanging the timer, and no lock
	# at all where flock is absent. The critical section is a copy and an install — milliseconds — so the
	# wait is never the reason a tick is slow. Deliberately NOT wrapped around fetch/render: a lock held
	# across an unbounded `git fetch` would disable recovery during exactly the outage it exists for.
	(
		if have flock; then exec 9>"$STATE_DIR/promote.lock" 2>/dev/null && flock -w 30 9 2>/dev/null || true; fi
		# ATOMIC on both writes (Audit-0009 H1). This function documents "atomically replace", and did
		# neither: `cp -f` truncates the destination in place, and `install` writes the target directly.
		# A reader (sing-box reload, a concurrent validate, the rollback path) could observe a half-written
		# live config or a half-written last-known-good — the rollback net torn exactly when it is needed.
		# mktemp in the DESTINATION directory keeps the rename on one filesystem, which is what makes
		# `mv -f` atomic; a rename cannot be observed half-done.
		if [ -f "$SINGBOX_CONFIG" ]; then
			lg_tmp="$(mktemp "$(dirname "$LASTGOOD_CONFIG")/.lastgood.XXXXXX")" \
				&& cp -f "$SINGBOX_CONFIG" "$lg_tmp" \
				&& chmod 0640 "$lg_tmp" 2>/dev/null \
				&& mv -f "$lg_tmp" "$LASTGOOD_CONFIG" \
				|| { rm -f "${lg_tmp:-}" 2>/dev/null; die "could not snapshot the last-known-good config (fail-closed; refusing to promote without a rollback target)."; }
		fi
	# 0640 root:<sing-box group>, NOT 0644 (Audit-0008 S1-1): the live config INLINES the REALITY private
	# key, every transport password + client UUID, and the clash_api Bearer secret — it must not be
	# world-readable. The service reads it via Group=$SINGBOX_RUN_GROUP; a co-resident non-group principal
	# (e.g. node_exporter) must not. Mirrors the ansible path + how privkey/params are already held (0640/0600).
		live_tmp="$(mktemp "$(dirname "$SINGBOX_CONFIG")/.live.XXXXXX")" \
			&& install -m 0640 -o root -g "$SINGBOX_RUN_GROUP" "$candidate" "$live_tmp" \
			&& mv -f "$live_tmp" "$SINGBOX_CONFIG" \
			|| { rm -f "${live_tmp:-}" 2>/dev/null; die "could not promote the candidate atomically (fail-closed; the live config is unchanged)."; }
	)
	log "promoted candidate to live config: $SINGBOX_CONFIG"
}

rollback_config() {
	need_root
	if [ -f "$LASTGOOD_CONFIG" ]; then
		warn "rolling back to last known-good config (fail-closed)."
		run install -m 0640 -o root -g "$SINGBOX_RUN_GROUP" "$LASTGOOD_CONFIG" "$SINGBOX_CONFIG"
	else
		warn "no last-known-good config to roll back to; leaving the running service untouched."
	fi
}

# ---------------------------------------------------------------------------
# Xray engine config spine (ADR-0032 dual-engine) — the per-engine peers of the four sing-box
# primitives above: render the enabled xray-engine inbound (vless-xhttp-tls) THROUGH the same
# myceliumctl pipeline into a candidate, validate with `xray run -test` (the fail-closed gate the
# renderer does not run itself), promote atomically keeping a known-good backup, rollback on failure.
# Reached only under the node_needs_xray guard, so a stock node never invokes them.
# ---------------------------------------------------------------------------
render_xray_candidate() {
	local candidate="$1"
	log "rendering xray candidate config via myceliumctl -> $candidate"
	[ -x "$MYCTL" ] || die "myceliumctl not found/executable: $MYCTL"
	[ -f "$XRAY_RENDER_TEMPLATE" ] || die "xray render template missing: $XRAY_RENDER_TEMPLATE"
	[ -f "$PARAMS_JSON" ] || die "params.json missing; run write_params first."
	[ -f "$IDENTITIES_JSON" ] || die "identities.json missing; run ensure_identity first."
	run "$MYCTL" render-server \
		--engine xray --proto vless-xhttp-tls \
		--template "$XRAY_RENDER_TEMPLATE" \
		--params "$PARAMS_JSON" \
		--state "$IDENTITIES_JSON" \
		--out "$candidate" \
		|| die "xray render-server failed (fail-closed; nothing promoted)."
}

# `xray run -test` is the fail-closed GATE the renderer does NOT run itself (peer of validate_config).
validate_xray_config() {
	local cfg="$1"
	log "validating xray candidate with 'xray run -test' (fail-closed gate)"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] xray run -test -c $cfg"; return 0; fi
	have "$XRAY_BIN" || die "xray binary missing; cannot validate."
	"$XRAY_BIN" run -test -c "$cfg" && return 0
	keep_invalid_candidate "$cfg" "${XRAY_INVALID_CONFIG:-}" "xray" \
		"$XRAY_BIN run -test -c ${XRAY_INVALID_CONFIG:-}"
	return 1
}

promote_xray_config() {
	# Atomically replace the live xray config with the candidate, keeping a known-good backup.
	local candidate="$1"
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] promote $candidate -> $XRAY_CONFIG"; return 0; fi
	install -d -m 0750 -o root -g "$XRAY_RUN_GROUP" "$XRAY_ETC"
	# THE SAME TREATMENT AS THE PRIMARY ENGINE, which this path went without. Its first line has always
	# claimed "atomically replace ... keeping a known-good backup" and it did neither: `cp -f` truncates the
	# rollback target in place before refilling it, `install` wrote the live target directly, and nothing
	# serialised two promoters. That is exactly what Audit-0009 H1/G1 found on the sing-box twin and
	# 5f7aee2 fixed — on one engine. The hardening was never carried across.
	#
	# This is not the lesser path. converge_node_tail runs the xray step AFTER sing-box is already promoted
	# and verified, so a torn xray known-good is reached on a node that is already mid-change, on the
	# unattended timer, with nobody watching — and the reader most likely to meet it is rollback_xray_config,
	# i.e. the net failing at the one moment it is needed.
	#
	# Its OWN lock, not the sing-box one: the two engines promote independently and inside the same tail, so
	# sharing a lock would have the xray step wait on a sing-box promote for no reason. Same bounded
	# `flock -w 30` shape — a stuck holder degrades to unserialised rather than wedging the timer — and the
	# mktemp lives in the DESTINATION directory so `mv -f` stays a same-filesystem rename.
	(
		if have flock; then exec 9>"$STATE_DIR/promote.xray.lock" 2>/dev/null && flock -w 30 9 2>/dev/null || true; fi
		if [ -f "$XRAY_CONFIG" ]; then
			xlg_tmp="$(mktemp "$(dirname "$XRAY_LASTGOOD_CONFIG")/.xlastgood.XXXXXX")" \
				&& cp -f "$XRAY_CONFIG" "$xlg_tmp" \
				&& chmod 0640 "$xlg_tmp" 2>/dev/null \
				&& mv -f "$xlg_tmp" "$XRAY_LASTGOOD_CONFIG" \
				|| { rm -f "${xlg_tmp:-}" 2>/dev/null; die "could not snapshot the last-known-good xray config (fail-closed; refusing to promote without a rollback target)."; }
		fi
		# 0640 root:<xray group>, NOT 0644 (Audit-0008 S1-1): the xray config inlines the same class of secrets;
		# xray reads it via Group=$XRAY_RUN_GROUP. Not world-readable.
		xlive_tmp="$(mktemp "$(dirname "$XRAY_CONFIG")/.xlive.XXXXXX")" \
			&& install -m 0640 -o root -g "$XRAY_RUN_GROUP" "$candidate" "$xlive_tmp" \
			&& mv -f "$xlive_tmp" "$XRAY_CONFIG" \
			|| { rm -f "${xlive_tmp:-}" 2>/dev/null; die "could not promote the xray candidate atomically (fail-closed; the live xray config is unchanged)."; }
	)
	log "promoted xray candidate to live config: $XRAY_CONFIG"
}

rollback_xray_config() {
	need_root
	if [ -f "$XRAY_LASTGOOD_CONFIG" ]; then
		warn "rolling back xray to last known-good config (fail-closed)."
		run install -m 0640 -o root -g "$XRAY_RUN_GROUP" "$XRAY_LASTGOOD_CONFIG" "$XRAY_CONFIG"
	else
		warn "no last-known-good xray config to roll back to; leaving the running service untouched."
	fi
}
