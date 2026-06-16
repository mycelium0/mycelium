#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node-bootstrap.sh — canonical ON-NODE bootstrap + semi-auto network updater.
# Author: mindicator & silicon bags quartet.
#
# WHAT THIS IS
#   A single, idempotent script that runs ON a node (NOT a control host — that is the Ansible
#   path in scripts/bootstrap.sh, left intact and complementary). It makes every node in the
#   network identical and IS the delivery mechanism: an operator pushes once to the public repo
#   and every node pulls + re-renders + validates + applies (fail-closed), so the whole network is
#   testable together with no per-node hand-work.
#
# TWO MODES
#   (default / bootstrap)   First run on a fresh node. Hardens the host, installs a pinned and
#                           checksum-verified sing-box, generates per-node identity LOCALLY if
#                           absent, picks + verifies a RANDOM donor SNI, writes a LOCAL-ONLY
#                           params.json, RENDERS the canonical config through the existing
#                           myceliumctl pipeline, runs "sing-box check", installs + (re)starts
#                           the service, sets up the userspace AmneziaWG path, verifies listeners.
#                           Re-running converges (idempotent).
#   --update                Semi-auto network update. Fetches the latest canonical artifacts (the
#                           fetch step is abstracted behind myc_fetch_artifacts — defaults to a
#                           pinned pull of the public repo, swappable to a signed release tarball),
#                           re-renders FROM THE LOCAL identity, runs "sing-box check", and on
#                           success reloads the service. On ANY failure it ROLLS BACK to the
#                           previous known-good config and leaves the running service untouched.
#   --update --staged       Stricter cadence: stage the candidate config and WAIT for an operator
#                           ack marker (an --ack run) before promoting. Never auto-applies.
#   --ack                   Promote a previously staged candidate (the operator's explicit "go").
#
# SEMI-AUTO = the human approval IS the git push. Nodes pull and apply automatically BUT
# fail-closed: a bad push can never brick the network because the candidate is validated and
# rolled back before it can replace the live config.
#
# FAIL-CLOSED EVERYWHERE. No secrets, IPs, hostnames, jurisdictions, or contact details are ever
# written into any committed file — only into LOCAL-ONLY, gitignored node state. All key material
# comes from audited generators (sing-box / openssl / awg); never hand-rolled (ADR-0002).
#
# WORDING: the node provides a persistent private network; framing is neutral throughout.
#
# USAGE
#   node-bootstrap.sh [--update [--staged] | --ack] [options]
#     (no mode)        bootstrap/converge this node from scratch (idempotent)
#     --update         fetch + re-render + validate + apply-with-rollback (the timer runs this)
#     --update --staged  stage a validated candidate; do not apply until --ack
#     --ack            promote a staged candidate (operator's explicit approval)
#     --revoke NAME    revoke a client (NAME|ID) + re-render + reload + refresh the served bundle
#     --disable-two-hop  remove the node-local two_hop.json overlay, re-render + reload + refresh the
#                        served bundle (the supported way to turn two-hop OFF; no manual file surgery)
#
#   options:
#     --repo-url URL       canonical artifact source (default: the pinned public repo remote)
#     --repo-ref REF       pinned ref to verify + apply; SHOULD be an immutable SIGNED tag, not a
#                          moving branch (a branch HEAD can be advanced by any push). Default: the
#                          checkout's current branch (verification still required unless --insecure).
#     --allowed-signers F  path to an out-of-band operator allowedSigners file (SSH-signature
#                          verification) OR a GPG keyring/home; the signed ref is verified against it
#                          BEFORE any fetched code runs. This file is NEVER committed (fail-closed).
#     --insecure-no-verify EXPLICITLY opt out of signature verification (testing only; loud warning).
#                          Without it, an unverifiable ref is REFUSED and nothing fetched is executed.
#     --checkout DIR       where the canonical checkout lives (default: /opt/mycelium)
#     --state-dir DIR      per-node state (default: /var/lib/mycelium)
#     --tooling-dir DIR    installed control/ tooling (default: /usr/local/lib/mycelium)
#     --singbox-version V  pinned sing-box release tag (e.g. v1.13.13); REQUIRED for install
#     --singbox-sha256 H   expected SHA256 of the sing-box release archive; REQUIRED for install
#     --clients "a b c"    client identity names to ensure exist (default: a single "default")
#     --node-address ADDR  this node's OWN reachable address (host or IP) that generated client
#                          subscriptions will dial. If omitted, the script auto-detects the primary
#                          public address; if that fails it falls back to a loud placeholder and
#                          warns that subscriptions will not connect until a real value is set.
#     --donor HOST         force a specific donor SNI instead of random selection (testing)
#     --no-harden          skip host hardening (sshd/ufw/journald) — converge data plane only
#     --no-amneziawg       skip the AmneziaWG userspace path
#     --dry-run            print what would happen; change nothing
#     --yes                non-interactive; assume "yes" to safe prompts
#     -h | --help          show this help
#
# Exit: 0 = success, non-zero = a fail-closed precondition or a validation/rollback path triggered.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate ourselves and the repository checkout regardless of caller CWD.
# ---------------------------------------------------------------------------
NB_SELF="${BASH_SOURCE[0]}"
while [ -h "$NB_SELF" ]; do
	d="$(cd -P "$(dirname "$NB_SELF")" && pwd)"
	NB_SELF="$(readlink "$NB_SELF")"
	case "$NB_SELF" in /*) ;; *) NB_SELF="$d/$NB_SELF" ;; esac
done
NB_DIR="$(cd -P "$(dirname "$NB_SELF")" && pwd)"
REPO_ROOT="$(cd -P "$NB_DIR/.." && pwd)"

log()  { printf 'node-bootstrap: %s\n' "$*"; }
warn() { printf 'node-bootstrap: warning: %s\n' "$*" >&2; }
die()  { printf 'node-bootstrap: error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Defaults (every node-specific value is a placeholder / runtime-selected — NEVER committed).
# ---------------------------------------------------------------------------
MODE="bootstrap"            # bootstrap | update | ack | revoke | disable-two-hop
REVOKE_NAME=""              # client NAME|ID to revoke (with --revoke): revoke + re-render + reload
STAGED=0
DRY_RUN=0
ASSUME_YES=0
DO_HARDEN=1
DO_AMNEZIAWG=1
DO_OBSERVABILITY=1          # install node_exporter (loopback) + the data-plane unit-active textfile metric

REPO_URL=""                 # default resolved from the checkout's origin remote
REPO_REF=""                 # default resolved from the checkout's current branch
ALLOWED_SIGNERS=""          # out-of-band operator key(s) used to verify the signed ref (fail-closed)
INSECURE_NO_VERIFY=0        # 1 only via --insecure-no-verify (testing); never the default
CHECKOUT_DIR="/opt/mycelium"
STATE_DIR="/var/lib/mycelium"
TOOLING_DIR="/usr/local/lib/mycelium"
SINGBOX_VERSION=""          # e.g. v1.13.13 — operator-pinned; required to install/upgrade
SINGBOX_SHA256=""           # expected archive SHA256 — operator-supplied; fail-closed
CLIENT_NAMES="default"
FORCE_DONOR=""
NODE_ADDRESS=""             # this node's own reachable address for client subscriptions; if empty,
                            # auto-detect with a fail-closed fallback to a loud placeholder.

# Documented placeholder used ONLY when no real node address is known. Subscriptions generated
# against it are NON-FUNCTIONAL by design, with a loud warning (see write_params / the runbook).
NODE_ADDRESS_PLACEHOLDER="node.example.invalid"

# Canonical on-node paths (match infra/ansible/roles/singbox/defaults/main.yml conventions).
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_ETC="/usr/local/etc/sing-box"
SINGBOX_CONFIG="$SINGBOX_ETC/config.json"
SINGBOX_RUN_USER="sing-box"
SINGBOX_RUN_GROUP="sing-box"
AWG_BIN_DIR="/usr/local/bin"   # amneziawg-go + awg/awg-quick land here when built from source

# Canonical sing-box release source (public GitHub releases). The exact tag + hash are operator
# pins (fail-closed); only the public base URL is committed.
SINGBOX_DL_BASE="https://github.com/SagerNet/sing-box/releases/download"

# AmneziaWG constants (RP-0009 C3): the userspace source repos + pinned tags (AWG_GO_REPO/
# AWG_TOOLS_REPO/AWG_GO_TAG/AWG_TOOLS_TAG), the in-tunnel "dialect" (AWG_TUNNEL_*/AWG_PEER_BASE_*/
# AWG_MTU/AWG_JC..S2/AWG_H1..H4), and the split-tunnel-on default + opt-out marker (AWG_SPLIT_TUNNEL/
# AWG_SG_OPTOUT_MARKER) live with their functions in control/lib/nb_render_awg.sh, sourced below. They
# are dedicated to the AmneziaWG path (used only by compute_client_allowed/render_awg0/install_awg_tools/
# setup_amneziawg). AWG_REGION_EXCLUDE_FILE + AWG_FULL_TUNNEL_OPTOUT stay HERE: they are operator-set by
# arg-parse and propagated through the --update re-exec (orchestration), so the lib references them at
# call time from the shared sourced scope. AWG_BIN_DIR stays in the canonical-paths block above.

# --- Selective Growth: client-side split-tunnel operator inputs (VIS-0009; ADR-0027; closed-by-default
# lineage ADR-0026) -----------------------------------------------------------------------------------
# "The mycelium does not grow where it is not needed." A generated CLIENT config carries ONLY traffic
# whose native path is impaired; natively-reachable destinations route DIRECT (split-tunnel). The
# WireGuard-class transport is CIDR-only, so it can only APPROXIMATE this via a region-exclude
# AllowedIPs route set (domain-aware split is the xray-class engine's job, not this path's). These
# knobs touch ONLY the generated client config(s); the server awg0.conf is never affected. The two
# operator inputs below are set by arg-parse + propagated through the --update re-exec, so they stay in
# the entrypoint; compute_client_allowed/render_awg0 (in control/lib/nb_render_awg.sh) read them at call
# time. The split-tunnel-on default + the opt-out marker live with those functions in that lib.
AWG_REGION_EXCLUDE_FILE=""         # path to a file of PRECOMPUTED region-exclude AllowedIPs CIDRs (one per
                                   # line; '#'-comments + blanks ignored). This is the route set to INSTALL —
                                   # i.e. the complement of the in-region native CIDRs against the default
                                   # route, produced out-of-band by an AllowedIPs calculator over the
                                   # region's CIDR list. We do NOT do CIDR-complement arithmetic in bash:
                                   # the route policy stays operator-owned and auditable. Empty => safe
                                   # narrow default (tunnel ranges only); we NEVER silently full-tunnel.
AWG_FULL_TUNNEL_OPTOUT=0           # 1 = deliberately emit a full-tunnel client (0.0.0.0/0[, ::/0]) WITH the
                                   # documented Selective-Growth opt-out marker. Records intent AND keeps
                                   # tests/conformance/no_full_tunnel_default.sh green.

# node_exporter (host metrics) — pinned public release, loopback-only (scraped over an SSH tunnel, the
# host firewall opens NO port for it). Plus a tiny textfile metric mycelium_dataplane_unit_active so the
# SingBoxDown alert can fire. Pins + layout mirror infra/ansible/roles/observability + group_vars; the
# SHA256 values are PUBLIC release checksums (committable).
NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_DL_BASE="https://github.com/prometheus/node_exporter/releases/download"
NODE_EXPORTER_SHA256_amd64="6809dd0b3ec45fd6e992c19071d6b5253aed3ead7bf0686885a51d85c6643c66"
NODE_EXPORTER_SHA256_arm64="627382b9723c642411c33f48861134ebe893e70a63bcc8b3fc0619cd0bfac4be"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"
NODE_EXPORTER_LISTEN="127.0.0.1:9100"
NODE_EXPORTER_TEXTFILE_DIR="/var/lib/node_exporter/textfile"

usage() { sed -n '2,/^set -euo pipefail$/p' "$NB_SELF" | sed 's/^# \{0,1\}//; s/^#$//'; }

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
	case "$1" in
		--update)          MODE="update"; shift ;;
		--ack)             MODE="ack"; shift ;;
		--revoke)          MODE="revoke"; REVOKE_NAME="${2:?--revoke needs a client NAME or ID}"; shift 2 ;;
		--disable-two-hop) MODE="disable-two-hop"; shift ;;
		--staged)          STAGED=1; shift ;;
		--repo-url)        REPO_URL="${2:?--repo-url needs a value}"; shift 2 ;;
		--repo-ref)        REPO_REF="${2:?--repo-ref needs a value}"; shift 2 ;;
		--allowed-signers) ALLOWED_SIGNERS="${2:?--allowed-signers needs a value}"; shift 2 ;;
		--insecure-no-verify) INSECURE_NO_VERIFY=1; shift ;;
		--checkout)        CHECKOUT_DIR="${2:?--checkout needs a value}"; shift 2 ;;
		--state-dir)       STATE_DIR="${2:?--state-dir needs a value}"; shift 2 ;;
		--tooling-dir)     TOOLING_DIR="${2:?--tooling-dir needs a value}"; shift 2 ;;
		--singbox-version) SINGBOX_VERSION="${2:?--singbox-version needs a value}"; shift 2 ;;
		--singbox-sha256)  SINGBOX_SHA256="${2:?--singbox-sha256 needs a value}"; shift 2 ;;
		--clients)         CLIENT_NAMES="${2:?--clients needs a value}"; shift 2 ;;
		--region-exclude)  AWG_REGION_EXCLUDE_FILE="${2:?--region-exclude needs a path}"; shift 2 ;;
		--full-tunnel)     AWG_FULL_TUNNEL_OPTOUT=1; shift ;;
		--node-address)    NODE_ADDRESS="${2:?--node-address needs a value}"; shift 2 ;;
		--donor)           FORCE_DONOR="${2:?--donor needs a value}"; shift 2 ;;
		--no-harden)       DO_HARDEN=0; shift ;;
		--no-amneziawg)    DO_AMNEZIAWG=0; shift ;;
		--no-observability) DO_OBSERVABILITY=0; shift ;;
		--dry-run)         DRY_RUN=1; shift ;;
		--yes|-y)          ASSUME_YES=1; shift ;;
		-h|--help)         usage; exit 0 ;;
		*) die "unknown argument: $1 (run with --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# ARTIFACT_ROOT — the directory that holds the CANONICAL on-node artifacts (donor list, renderer
# template, control/ tooling). This is DELIBERATELY NOT REPO_ROOT.
#
# WHY: REPO_ROOT is derived from this script's OWN path ($NB_SELF/..). In flow_update the script
# copies ITSELF to a throwaway tmp dir and re-exec's from there (the self-modification guard), so
# after re-exec $NB_SELF lives under that tmp dir and REPO_ROOT resolves to the tmp PARENT — which
# does NOT contain nodes/ or control/. Resolving artifacts off REPO_ROOT would then make the donor
# list, the renderer template, the in-repo myceliumctl fallback, and install_tooling's source all
# point at the wrong (tmp) place and the render would fail on every update.
#
# The real checkout (default /opt/mycelium) is passed through the re-exec args as --checkout, so it
# is always known to the re-exec'd copy. Prefer it; fall back to REPO_ROOT only for the in-place
# (non-re-exec) bootstrap case where the script still lives inside the checkout.
if [ -n "$CHECKOUT_DIR" ] && [ -d "$CHECKOUT_DIR" ]; then
	ARTIFACT_ROOT="$CHECKOUT_DIR"
else
	ARTIFACT_ROOT="$REPO_ROOT"
fi

# ---------------------------------------------------------------------------
# Sourced control/lib modules (RP-0009 decomposition). These nb_*.sh libs hold function groups
# carved out of this orchestrator (identity, donor selection, host hardening, package/engine
# install); they are SOURCED (not subshelled) so the entrypoint's shared globals (paths, STATE_DIR,
# the SINGBOX_*/DRY_RUN vars, MYCTL, …) and the die()/log()/warn()/run()/need_root()/have() helpers
# remain shared exactly as when the functions were inline. Sourcing only DEFINES functions; their
# bodies reference those globals/helpers at CALL time, which is after this point.
#
# RESOLVED FROM ARTIFACT_ROOT, NOT REPO_ROOT: after the --update re-exec the script runs from a tmp
# copy whose $NB_SELF/.. (= REPO_ROOT) has no control/ tree; ARTIFACT_ROOT points at the real
# checkout (passed through as --checkout), so the libs resolve correctly on every update too. This
# is the same artifact-root discipline tests/conformance/node_update_artifact_root.sh gates.
#
# C2 adds the render/serve CONTROL-LOGIC modules: nb_render_params (write_params + the C19 operator-
# override seed/merge + resolve_node_address, with OPERATOR_TOGGLE_KEYS/OPERATOR_OVERRIDES) and
# nb_serve_bundle (render_serve_bundle + bundle_served_age*, with the BUNDLE_* served-path constants).
# C3 adds the routing/split-tunnel modules: nb_two_hop (assert_two_hop_shape + flow_disable_two_hop, the
# two-hop egress routing policy) and nb_render_awg (compute_client_allowed/sg_allowed_join/render_awg0/
# install_awg_tools/setup_amneziawg — the AmneziaWG second family + Selective-Growth split-tunnel policy,
# with the AWG dialect + userspace-source + split-tunnel-default constants). flow_disable_two_hop is the
# --disable-two-hop dispatch target; that case (below) resolves it at runtime in the shared sourced scope.
# They define functions + their dedicated constants only; the constants reference STATE_DIR (already
# final after arg-parse, above) and the function bodies reference shared globals/helpers at call time.
NB_LIB_DIR="$ARTIFACT_ROOT/control/lib"
for _lib in nb_identity nb_donor nb_harden nb_install nb_render_params nb_serve_bundle nb_two_hop nb_render_awg; do
	# shellcheck source=/dev/null
	. "$NB_LIB_DIR/${_lib}.sh" || die "cannot source $NB_LIB_DIR/${_lib}.sh (fail-closed; the control/lib tree must be present in the checkout)"
done
unset _lib

# Derived per-node state paths (all LOCAL-ONLY / gitignored — never committed).
PARAMS_JSON="$STATE_DIR/params.json"             # flat render schema (see control/README.md)
IDENTITIES_JSON="$STATE_DIR/identities.json"     # {version,clients:[{name,id,created}]}
IDENTITY_SECRETS="$STATE_DIR/identity.json"      # 0600: REALITY priv/pub, per-proto secrets, donor
TLS_DIR="$STATE_DIR/tls"                         # per-node self-signed cert + key (service-readable)
# Canonical artifacts resolve off ARTIFACT_ROOT (the real checkout), NOT REPO_ROOT — see above.
DONOR_LIST="$ARTIFACT_ROOT/nodes/dataplane/donor-sni-candidates.json"
RENDER_TEMPLATE="$ARTIFACT_ROOT/nodes/dataplane/singbox/server.template.renderer.json"
LASTGOOD_CONFIG="$STATE_DIR/config.lastgood.json"
STAGED_CONFIG="$STATE_DIR/config.staged.json"
ACK_MARKER="$STATE_DIR/config.staged.ack"
# C2 (RP-0009): the operator-override path (OPERATOR_OVERRIDES + OPERATOR_TOGGLE_KEYS) lives with its
# functions in control/lib/nb_render_params.sh, and the served-bundle paths (BUNDLE_DIR/BUNDLE_SERVED/
# BUNDLE_CANDIDATE/BUNDLE_SERVED_AGE_FILE) with theirs in control/lib/nb_serve_bundle.sh — both sourced
# above. Those constants are used ONLY by the functions that moved, so they moved with them; they
# reference STATE_DIR (already final by the time the libs are sourced).

# myceliumctl entrypoint: prefer the installed tooling copy; fall back to the in-repo (checkout) one.
MYCTL="$TOOLING_DIR/control/myceliumctl"
[ -x "$MYCTL" ] || MYCTL="$ARTIFACT_ROOT/control/myceliumctl"

run() {
	# run CMD... — honor --dry-run. Always log the command for an audit trail.
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'node-bootstrap: [dry-run] %s\n' "$*"
		return 0
	fi
	"$@"
}

need_root() {
	# Under --dry-run we MUTATE NOTHING (every real action is gated behind run()), so previewing the
	# plan must not require root. This also lets the offline update/re-exec path be tested unprivileged
	# (see tests/conformance/node_update_artifact_root.sh). A real (non-dry-run) step still fails closed.
	[ "$DRY_RUN" -eq 1 ] && return 0
	[ "$(id -u)" -eq 0 ] || die "this step needs root; re-run with sudo (fail-closed)."
}

# ---------------------------------------------------------------------------
# Generators (gen_reality_keypair/gen_uuid/gen_secret_b64/gen_shortid) live in
# control/lib/nb_identity.sh; donor selection (donor_candidates/donor_verify/donor_offers_h2/
# pick_donor) lives in control/lib/nb_donor.sh — both sourced above (RP-0009). They are WRAPPERS
# ONLY around audited tools (ADR-0002): not one byte of key material is produced by this script.
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
# Host hardening (harden_journald/harden_sshd/harden_ufw) lives in control/lib/nb_harden.sh;
# the PINNED + checksum-verified sing-box install, the unprivileged sing-box user/dirs, the
# per-node self-signed cert, and ensure_identity (the per-node LOCAL-only identity) live in
# control/lib/nb_install.sh + control/lib/nb_identity.sh — all sourced above (RP-0009). They are
# idempotent, fail-closed OS-glue; the identity generators they call stay byte-identical.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# params.json (the FLAT render schema) — write_params + the C19 operator-override seed/merge +
# resolve_node_address live in control/lib/nb_render_params.sh, sourced above (RP-0009 C2). They are
# CONTROL-LOGIC (the operator-override allowlist + the two-hop-merge decision), earmarked for the
# RP-0008 Go migration. The two-hop ROUTING POLICY — assert_two_hop_shape (the fail-closed overlay
# shape check write_params calls before merging a present two_hop.json) and flow_disable_two_hop (the
# --disable-two-hop remove path) — moved to control/lib/nb_two_hop.sh (RP-0009 C3), sourced above; both
# resolve at call time from the shared sourced scope.
# ---------------------------------------------------------------------------

# OPERATOR-TOGGLE OVERRIDES (C19 defect 2) + write_params + resolve_node_address moved to
# control/lib/nb_render_params.sh (RP-0009 C2), together with their dedicated OPERATOR_TOGGLE_KEYS +
# OPERATOR_OVERRIDES constants. They are sourced above; write_params calls assert_two_hop_shape (below),
# resolved at call time from the shared sourced scope.

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

# ---------------------------------------------------------------------------
# Served distribution bundle (RP-0007-b) — render_serve_bundle + bundle_served_age_seconds +
# record_bundle_served_age moved to control/lib/nb_serve_bundle.sh (RP-0009 C2), together with the
# BUNDLE_DIR/BUNDLE_SERVED/BUNDLE_CANDIDATE/BUNDLE_SERVED_AGE_FILE served-path constants. They are
# sourced above; the flow_* dispatchers (below) call render_serve_bundle on every promotion path (C25).
# This is CONTROL-LOGIC (validation), earmarked for the RP-0008 Go migration (the authoritative
# internal/spec.Bundle.Validate round-trip).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# systemd service install + (re)start / reload. install_singbox_unit (the hardened sing-box unit)
# and restart_singbox live in control/lib/nb_install.sh, sourced above (RP-0009); apply_singbox
# stays here (it is the flow-level apply primitive the update path calls). The unit's
# RestrictAddressFamilies incl. AF_NETLINK is kept in lockstep with the Ansible template by
# tests/conformance/unit_netlink_parity.sh — change BOTH together (Audit-0004 F-001/F-017).
# ---------------------------------------------------------------------------
# apply_singbox — make the running service pick up a new config. sing-box is Type=simple with NO
# ExecReload, so there is no real "reload": applying a config IS a restart (it briefly drops live
# connections). We do not pretend otherwise. Returns the restart's own status so callers can
# distinguish a failed restart from a failed post-check.
apply_singbox()   { need_root; run systemctl enable sing-box 2>/dev/null || true; run systemctl restart sing-box; }

# ---------------------------------------------------------------------------
# AmneziaWG second family — the Selective-Growth split-tunnel AllowedIPs policy (compute_client_allowed
# + sg_allowed_join), the awg0.conf + per-client render (render_awg0), and the userspace build/bring-up
# (install_awg_tools + setup_amneziawg) moved to control/lib/nb_render_awg.sh (RP-0009 C3), together with
# their dedicated AmneziaWG dialect + userspace-source + split-tunnel-default constants. They are sourced
# above; flow_bootstrap (below) calls setup_amneziawg, resolved at call time from the shared sourced
# scope (the timer-driven flow_update NEVER does). MIXED classification: the split-tunnel AllowedIPs
# decision is CONTROL-LOGIC (earmarked for the RP-0008 Go migration); the userspace setup is OS-glue.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Node-local observability (Phase 0): a PINNED, checksum-verified node_exporter bound to loopback
# (the host firewall opens NO port for it — Prometheus scrapes it over an SSH tunnel), plus a tiny
# textfile metric `mycelium_dataplane_unit_active{engine="singbox"}` so the SingBoxDown alert can
# fire. Pure measurement; no PII (host metrics + a 0/1 unit-state gauge). Mirrors the observability
# Ansible role. flow_update never calls this — only flow_bootstrap does.
# ---------------------------------------------------------------------------
install_node_exporter() {
	local cur archm archkey shavar sha ver tarball url tmp got extracted
	if [ -x "$NODE_EXPORTER_BIN" ]; then
		cur="$("$NODE_EXPORTER_BIN" --version 2>&1 | head -n1 || true)"
		if printf '%s' "$cur" | grep -q "$NODE_EXPORTER_VERSION"; then
			log "node_exporter $NODE_EXPORTER_VERSION already installed; skipping."
			return 0
		fi
	fi
	archm="$(uname -m)"
	case "$archm" in
		x86_64)  archkey="amd64" ;;
		aarch64) archkey="arm64" ;;
		*) die "unsupported architecture for node_exporter: $archm (fail-closed)." ;;
	esac
	shavar="NODE_EXPORTER_SHA256_$archkey"; sha="${!shavar}"
	ver="$NODE_EXPORTER_VERSION"
	tarball="node_exporter-${ver}.linux-${archkey}.tar.gz"
	url="$NODE_EXPORTER_DL_BASE/v${ver}/${tarball}"
	tmp="$(mktemp -d)"
	log "downloading node_exporter ${ver} (${archkey})"
	if ! run curl -fsSL "$url" -o "$tmp/$tarball"; then rm -rf "$tmp"; die "node_exporter download failed (fail-closed)."; fi
	if have sha256sum; then
		got="$(sha256sum "$tmp/$tarball" | awk '{print $1}')"
		[ "$got" = "$sha" ] || { rm -rf "$tmp"; die "node_exporter SHA256 mismatch (got $got, want $sha) — refusing (fail-closed)."; }
	else
		warn "sha256sum unavailable; cannot verify the node_exporter checksum."
	fi
	run tar -xzf "$tmp/$tarball" -C "$tmp"
	extracted="$tmp/node_exporter-${ver}.linux-${archkey}/node_exporter"
	[ -f "$extracted" ] || { rm -rf "$tmp"; die "node_exporter binary not found in the archive."; }
	run install -m 0755 "$extracted" "$NODE_EXPORTER_BIN"
	rm -rf "$tmp"
	log "installed node_exporter ${ver} to $NODE_EXPORTER_BIN."
}

render_node_exporter_unit() {
	[ "$DRY_RUN" -eq 1 ] && { log "[dry-run] would write node_exporter.service"; return 0; }
	cat >/etc/systemd/system/node_exporter.service <<UNIT
# Mycelium Phase 0 — node_exporter (host metrics, loopback only). Rendered by node-bootstrap.sh.
[Unit]
Description=Mycelium node_exporter (host metrics, loopback only)
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=$NODE_EXPORTER_BIN --web.listen-address=$NODE_EXPORTER_LISTEN --collector.textfile.directory=$NODE_EXPORTER_TEXTFILE_DIR
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
PrivateDevices=true
DevicePolicy=closed
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
RemoveIPC=true
UMask=0077
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# No SystemCallFilter / MemoryDenyWriteExecute here: node_exporter's host-metric collectors use
# syscalls an aggressive seccomp filter blocks, which SIGSYS-kills it (status=31/SYS core-dump loop).
# The filesystem / privilege / namespace protections above remain; this is a loopback-only reader.

[Install]
WantedBy=multi-user.target
UNIT
}

write_dataplane_metrics_generator() {
	[ "$DRY_RUN" -eq 1 ] && { log "[dry-run] would write the data-plane metrics generator + timer"; return 0; }
	# The generator: write mycelium_dataplane_unit_active{engine="singbox"} atomically (temp+rename) so
	# node_exporter never reads a half-written file. It carries ONLY a 0/1 gauge + the engine label
	# (the canonical alert label, not PII).
	cat >/usr/local/bin/mycelium-dataplane-metrics.sh <<'GEN'
#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Mycelium — write the data-plane unit-active textfile metric for node_exporter. No PII: a 0/1 gauge.
set -euo pipefail
DIR="/var/lib/node_exporter/textfile"
OUT="$DIR/mycelium_dataplane.prom"
active=0
systemctl is-active --quiet sing-box && active=1
tmp="$(mktemp "$DIR/.mdp.XXXXXX")"
{
	echo '# HELP mycelium_dataplane_unit_active 1 if the data-plane systemd unit is active, else 0.'
	echo '# TYPE mycelium_dataplane_unit_active gauge'
	printf 'mycelium_dataplane_unit_active{engine="singbox"} %d\n' "$active"
} >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$OUT"
GEN
	chmod 0755 /usr/local/bin/mycelium-dataplane-metrics.sh
	cat >/etc/systemd/system/mycelium-dataplane-metrics.service <<'UNIT'
[Unit]
Description=Mycelium data-plane unit-active textfile metric (writes a 0/1 gauge for node_exporter)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/mycelium-dataplane-metrics.sh
UNIT
	cat >/etc/systemd/system/mycelium-dataplane-metrics.timer <<'UNIT'
[Unit]
Description=Refresh the Mycelium data-plane unit-active metric every 15s
[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=1s
[Install]
WantedBy=timers.target
UNIT
}

setup_observability() {
	[ "$DO_OBSERVABILITY" -eq 1 ] || { log "observability step skipped (--no-observability)."; return 0; }
	log "setting up node-local observability (node_exporter + data-plane unit-active metric, loopback only)"
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would install node_exporter + the unit-active textfile metric"; return 0; fi
	install_node_exporter
	getent group node_exporter >/dev/null 2>&1 || run groupadd --system node_exporter
	getent passwd node_exporter >/dev/null 2>&1 || run useradd --system -g node_exporter -s /usr/sbin/nologin -M -d /nonexistent node_exporter
	run install -d -m 0750 -o root -g node_exporter "$NODE_EXPORTER_TEXTFILE_DIR"
	render_node_exporter_unit
	write_dataplane_metrics_generator
	run systemctl daemon-reload
	run /usr/local/bin/mycelium-dataplane-metrics.sh || warn "first metric write failed (will retry on the timer)."
	run systemctl enable --now node_exporter 2>/dev/null || run systemctl restart node_exporter
	run systemctl enable --now mycelium-dataplane-metrics.timer 2>/dev/null || warn "could not enable the metrics timer."
	log "node_exporter on $NODE_EXPORTER_LISTEN (loopback) + mycelium_dataplane_unit_active active."
}

# ---------------------------------------------------------------------------
# Verify listeners (best-effort; reports, does not fail the converge unless the service is dead).
# ---------------------------------------------------------------------------
verify_listeners() {
	log "verifying the data plane is up"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would check systemctl is-active + listening ports"; return 0; fi
	if ! systemctl is-active --quiet sing-box; then
		die "sing-box service is not active after apply (fail-closed)."
	fi
	log "sing-box is active."
	if have ss; then
		log "listening sockets owned by sing-box:"
		ss -tulpn 2>/dev/null | grep -i 'sing-box' || warn "no sing-box sockets seen yet (may still be starting)."
	fi
}

# ---------------------------------------------------------------------------
# Tooling install (install_tooling: copy control/ tooling to TOOLING_DIR so myceliumctl is
# self-locating on-node, sourced from ARTIFACT_ROOT) and the base-package install (install_base_deps)
# live in control/lib/nb_install.sh, sourced above (RP-0009). install_tooling sources control/ from
# ARTIFACT_ROOT — NOT REPO_ROOT — for the same re-exec reason ARTIFACT_ROOT exists.
# ---------------------------------------------------------------------------

# ===========================================================================
# Mode flows.
# ===========================================================================

flow_bootstrap() {
	log "=== bootstrap / converge ==="
	install_base_deps
	if [ "$DO_HARDEN" -eq 1 ]; then
		harden_journald
		harden_sshd
	fi
	install_singbox
	install_tooling
	ensure_identity
	write_params
	local candidate="$STATE_DIR/config.candidate.json"
	render_candidate "$candidate"
	if ! validate_config "$candidate"; then
		rm -f "$candidate" 2>/dev/null || true
		die "candidate failed 'sing-box check' on first bootstrap (fail-closed). Fix params/template."
	fi
	promote_config "$candidate"
	rm -f "$candidate" 2>/dev/null || true
	install_singbox_unit
	restart_singbox
	setup_amneziawg
	setup_observability
	# Render the served distribution bundle (RP-0007-b). Fail-closed: keeps last-known-good on failure.
	render_serve_bundle
	if [ "$DO_HARDEN" -eq 1 ]; then harden_ufw; fi
	verify_listeners
	log "bootstrap complete. The REALITY private key, client UUIDs, and per-protocol secrets remain"
	log "ONLY on this node ($STATE_DIR, 0600). Export only the REALITY public key + subscriptions."
}

flow_update() {
	log "=== semi-auto update (fetch + re-render + validate + apply-with-rollback) ==="
	# SELF-MODIFICATION GUARD. myc_fetch_artifacts rewrites the working tree IN PLACE, including
	# this very script (the unit invokes /opt/mycelium/scripts/node-bootstrap.sh). bash reads
	# scripts lazily by byte offset, so mutating the file under the open fd makes the rest of this
	# function execute a half-old/half-new script (skipping validation/rollback). Re-exec from an
	# immutable copy BEFORE any fetch, so fetch+render+validate+apply all run from a stable image.
	if [ "${MYC_REEXEC:-0}" != "1" ]; then
		local reexec_dir reexec_self
		reexec_dir="$(mktemp -d)"
		reexec_self="$reexec_dir/node-bootstrap.sh"
		cp "$NB_SELF" "$reexec_self" || die "could not stage an immutable copy of the updater (fail-closed)."
		chmod 0755 "$reexec_self"
		log "re-executing the updater from an immutable copy ($reexec_self) to survive self-modification."
		# Rebuild argv as an ARRAY (no word-splitting / empty-arg hazards), preserving the resolved
		# repo/checkout context so the copy locates the same tree.
		local -a reexec_args=(--update)
		if [ "$STAGED" -eq 1 ]; then reexec_args+=(--staged); fi
		if [ -n "$REPO_URL" ]; then reexec_args+=(--repo-url "$REPO_URL"); fi
		if [ -n "$REPO_REF" ]; then reexec_args+=(--repo-ref "$REPO_REF"); fi
		if [ -n "$ALLOWED_SIGNERS" ]; then reexec_args+=(--allowed-signers "$ALLOWED_SIGNERS"); fi
		if [ "$INSECURE_NO_VERIFY" -eq 1 ]; then reexec_args+=(--insecure-no-verify); fi
		reexec_args+=(--checkout "$CHECKOUT_DIR" --state-dir "$STATE_DIR" --tooling-dir "$TOOLING_DIR")
		if [ -n "$SINGBOX_VERSION" ]; then reexec_args+=(--singbox-version "$SINGBOX_VERSION"); fi
		if [ -n "$SINGBOX_SHA256" ]; then reexec_args+=(--singbox-sha256 "$SINGBOX_SHA256"); fi
		reexec_args+=(--clients "$CLIENT_NAMES")
		if [ -n "$AWG_REGION_EXCLUDE_FILE" ]; then reexec_args+=(--region-exclude "$AWG_REGION_EXCLUDE_FILE"); fi
		if [ "$AWG_FULL_TUNNEL_OPTOUT" -eq 1 ]; then reexec_args+=(--full-tunnel); fi
		if [ -n "$NODE_ADDRESS" ]; then reexec_args+=(--node-address "$NODE_ADDRESS"); fi
		if [ "$DO_HARDEN" -eq 0 ]; then reexec_args+=(--no-harden); fi
		if [ "$DO_AMNEZIAWG" -eq 0 ]; then reexec_args+=(--no-amneziawg); fi
		if [ "$DO_OBSERVABILITY" -eq 0 ]; then reexec_args+=(--no-observability); fi
		if [ "$DRY_RUN" -eq 1 ]; then reexec_args+=(--dry-run); fi
		if [ "$ASSUME_YES" -eq 1 ]; then reexec_args+=(--yes); fi
		MYC_REEXEC=1 MYC_REEXEC_DIR="$reexec_dir" exec "$reexec_self" "${reexec_args[@]}"
	fi
	# From here on we are running from the immutable copy; mutating the tree is now safe. Clean up
	# the staged copy when this process exits (the kernel keeps the open image valid until then).
	if [ -n "${MYC_REEXEC_DIR:-}" ]; then trap 'rm -rf "$MYC_REEXEC_DIR"' EXIT; fi
	# myc_fetch_artifacts already REFUSED to merge anything that failed signature verification, so
	# the tree we are about to copy + execute is operator-authenticated; this avoids running
	# freshly-fetched, unverified shell code as root (no RCE-via-update).
	myc_fetch_artifacts
	install_tooling
	# Re-render from the LOCAL identity (NEVER regenerate keys on update).
	[ -f "$IDENTITY_SECRETS" ] || die "no local identity; run bootstrap before --update (fail-closed)."
	write_params
	local candidate="$STATE_DIR/config.candidate.json"
	render_candidate "$candidate"
	if ! validate_config "$candidate"; then
		rm -f "$candidate" 2>/dev/null || true
		die "candidate failed 'sing-box check' — NOT applied; live config + service untouched (fail-closed)."
	fi
	# NO-OP SHORT-CIRCUIT: if the validated candidate is byte-identical to the live config, do not
	# promote/restart. The timer runs every few minutes; an unchanged push must cause ZERO restarts
	# (a restart drops live client connections on an always-on PPN).
	if [ "$DRY_RUN" -eq 0 ] && [ -f "$SINGBOX_CONFIG" ] && cmp -s "$candidate" "$SINGBOX_CONFIG"; then
		rm -f "$candidate" 2>/dev/null || true
		log "candidate is identical to the live config; no change to apply (service untouched)."
		return 0
	fi
	if [ "$STAGED" -eq 1 ]; then
		run cp -f "$candidate" "$STAGED_CONFIG"
		rm -f "$candidate" 2>/dev/null || true
		log "staged a validated candidate at $STAGED_CONFIG."
		log "It will NOT be applied until an operator ack: run '$0 --ack'."
		return 0
	fi
	# Default: apply with rollback. Applying = an explicit RESTART (sing-box Type=simple has no real
	# reload), so we restart and then assert health BEFORE declaring success.
	promote_config "$candidate"
	rm -f "$candidate" 2>/dev/null || true
	install_singbox_unit
	if apply_singbox && verify_post_apply; then
		log "update applied and verified."
		# Re-render the served bundle from the now-live identity/params (fail-closed: keeps
		# last-known-good if the fresh render does not validate — never serves an invalid bundle).
		render_serve_bundle
	else
		warn "post-apply verification failed; rolling back."
		rollback_config
		apply_singbox || true
		verify_post_apply || warn "service still unhealthy after rollback — operator attention needed."
		die "update rolled back (fail-closed). The previous known-good config was restored."
	fi
}

flow_ack() {
	log "=== promote staged candidate (operator ack) ==="
	[ -f "$STAGED_CONFIG" ] || die "no staged candidate at $STAGED_CONFIG (nothing to ack)."
	if ! validate_config "$STAGED_CONFIG"; then
		die "staged candidate no longer passes 'sing-box check' (fail-closed). Re-stage with --update --staged."
	fi
	promote_config "$STAGED_CONFIG"
	install_singbox_unit
	if apply_singbox && verify_post_apply; then
		run rm -f "$STAGED_CONFIG" "$ACK_MARKER"
		log "staged candidate promoted and verified."
	else
		warn "post-apply verification failed; rolling back."
		rollback_config
		apply_singbox || true
		die "ack rolled back (fail-closed)."
	fi
}

# flow_revoke — atomic on-node client revoke: drop the client from the identity state, re-render the
# server config WITHOUT it, validate fail-closed, promote, reload sing-box, and verify (rollback on
# failure). One command instead of revoke-then-manually-re-render. LOCAL only — no fetch, no key
# regeneration; other clients' links are unchanged (nothing to re-distribute). Closes the D4 atomic
# revoke-wrapper item (Audit-0004); the revoke itself reuses myceliumctl + the tested render/apply path.
flow_revoke() {
	log "=== revoke client + re-render + reload (atomic, no fetch) ==="
	[ -n "$REVOKE_NAME" ] || die "--revoke needs a client NAME or ID."
	[ -x "$MYCTL" ] || die "myceliumctl not found/executable: $MYCTL"
	[ -f "$IDENTITIES_JSON" ] || die "identities.json missing — nothing to revoke (bootstrap first)."
	run "$MYCTL" identity revoke "$REVOKE_NAME" --state "$IDENTITIES_JSON" \
		|| die "revoke failed — is '$REVOKE_NAME' a known client? (myceliumctl identity list)"
	local candidate="$STATE_DIR/config.candidate.json"
	render_candidate "$candidate"
	if ! validate_config "$candidate"; then
		rm -f "$candidate" 2>/dev/null || true
		die "candidate failed 'sing-box check' after revoke (fail-closed; nothing promoted)."
	fi
	promote_config "$candidate"
	rm -f "$candidate" 2>/dev/null || true
	install_singbox_unit
	if apply_singbox && verify_post_apply; then
		# C25: the served distribution bundle embeds the FIRST identity's UUID as the endpoint credential.
		# Revoking that identity without re-rendering leaves the served bundle's Link pointing at a dead
		# UUID. Re-render the served bundle on this promotion path too (fail-closed: keeps last-known-good
		# if the fresh render does not validate), so the served distribution never advertises a revoked
		# credential.
		render_serve_bundle
		log "revoked '$REVOKE_NAME'; config re-rendered + sing-box reloaded + served bundle refreshed — the client's UUID is gone from every inbound. Other clients' links are unchanged."
	else
		warn "post-apply verification failed after revoke; rolling back."
		rollback_config
		apply_singbox || true
		die "revoke rolled back (fail-closed) — the prior config (with the client) is restored."
	fi
}

# flow_disable_two_hop — the C21 documented remove-two-hop path (delete the node-local two_hop.json
# overlay, re-render + validate + promote + reload, and refresh the served bundle) moved to
# control/lib/nb_two_hop.sh (RP-0009 C3), sourced above. The dispatch `case` (below) calls it; that call
# resolves at runtime from the shared sourced scope. It is CONTROL-LOGIC (routing policy), earmarked for
# the RP-0008 Go migration.

verify_post_apply() {
	# Robust post-apply health check. ExecStartPre's "sing-box check" only validates SCHEMA; a config
	# that passes check can still fail at RUNTIME (port already in use, cert unreadable under the
	# sandbox, bind failure). With Restart=on-failure the unit can momentarily flap through "active"
	# right after restart, so a single is-active probe can wrongly report success. We therefore:
	#   1) settle briefly so an immediate crash surfaces (RestartSec is 5s; we wait past the first
	#      start window without masking a flap), then
	#   2) assert the unit is active AND that the EXPECTED listen ports from the live config are
	#      actually bound. Any miss is a failure -> the caller rolls back (fail-closed).
	if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
	# Settle: poll is-active a few times so a config that binds-then-dies cannot pass as healthy.
	local i
	for i in 1 2 3 4 5 6; do
		systemctl is-active --quiet sing-box || { warn "sing-box not active during settle window."; return 1; }
		sleep 1
	done
	systemctl is-active --quiet sing-box || { warn "sing-box not active after settle."; return 1; }
	# Confirm the expected ports are bound (reuse the live-config port set + an ss check).
	verify_listen_ports || return 1
	return 0
}

# verify_listen_ports — assert every expected TCP/UDP port from the live config is actually bound.
# Returns 0 if all expected ports are listening (or if we cannot determine the set — best-effort,
# never a false failure when the tooling is unavailable).
verify_listen_ports() {
	have ss || { warn "ss not available; cannot confirm bound ports (skipping port assertion)."; return 0; }
	have jq || { warn "jq not available; cannot read expected ports (skipping port assertion)."; return 0; }
	[ -f "$SINGBOX_CONFIG" ] || return 0
	local want_tcp want_udp
	want_tcp="$(jq -r '
		[.inbounds[]? | select(.listen_port != null)
		 | select(.type=="vless" or .type=="trojan" or .type=="shadowtls"
		          or (.type=="shadowsocks" and (.listen|test("127\\.0\\.0\\.1")|not)))
		 | .listen_port] | unique | .[]' "$SINGBOX_CONFIG" 2>/dev/null)"
	want_udp="$(jq -r '
		[.inbounds[]? | select(.listen_port != null)
		 | select(.type=="hysteria2" or .type=="tuic") | .listen_port] | unique | .[]' \
		"$SINGBOX_CONFIG" 2>/dev/null)"
	local listening_tcp listening_udp p missing=0
	listening_tcp="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | sort -u)"
	listening_udp="$(ss -ulnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | sort -u)"
	for p in $want_tcp; do
		[ -n "$p" ] || continue
		printf '%s\n' "$listening_tcp" | grep -qx "$p" || { warn "expected TCP port $p is NOT bound."; missing=1; }
	done
	for p in $want_udp; do
		[ -n "$p" ] || continue
		printf '%s\n' "$listening_udp" | grep -qx "$p" || { warn "expected UDP port $p is NOT bound."; missing=1; }
	done
	[ "$missing" -eq 0 ] || return 1
	log "all expected listen ports are bound."
	return 0
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
# MYC_NB_NO_DISPATCH=1 lets a test SOURCE this script to exercise the pure helpers (assert_two_hop_shape,
# seed/merge_operator_overrides, bundle_served_age_seconds) WITHOUT running a root-requiring flow. It is
# never set in production; the normal invocation leaves it unset and dispatches as before.
if [ "${MYC_NB_NO_DISPATCH:-0}" != "1" ]; then
	case "$MODE" in
		bootstrap)       flow_bootstrap ;;
		update)          flow_update ;;
		ack)             flow_ack ;;
		revoke)          flow_revoke ;;
		disable-two-hop) flow_disable_two_hop ;;
		*) die "unknown mode: $MODE" ;;
	esac
fi
exit 0
