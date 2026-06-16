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

# AmneziaWG userspace sources (public; built from source — kernel-independent).
AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go"
AWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools"
# Pinned source tags for the userspace build. There is NO upstream prebuilt amneziawg-go release, so a
# from-zero node builds these from source (apt golang-go + build-essential). amneziawg-go matches the
# fleet; amneziawg-tools is the current tag. Bumping these is a separate, verified change.
AWG_GO_TAG="v0.2.18"
AWG_TOOLS_TAG="v1.0.20260223"

# AmneziaWG canonical "dialect": the in-tunnel addressing + obfuscation knobs shared fleet-wide. Every
# peer (server + all its clients) MUST share Jc/Jmin/Jmax/S1/S2/H1..H4 or the handshake fails. These
# are TUNABLE, NOT secret — and are the SAME values as infra/ansible/roles/amneziawg/defaults/main.yml
# (a node + its clients are one dialect). The render below uses them ONLY when first creating a node's
# awg0.conf; an existing awg0.conf is never overwritten.
AWG_TUNNEL_V4="10.13.13.1/24"      # server in-tunnel v4 (RFC1918); peers get .2, .3, …
AWG_TUNNEL_V6="fd13:13:13::1/64"   # server in-tunnel v6 (RFC4193 ULA); used only if the node has global v6
AWG_PEER_BASE_V4="10.13.13"
AWG_PEER_BASE_V6="fd13:13:13::"
AWG_MTU="1280"
AWG_JC="4"; AWG_JMIN="40"; AWG_JMAX="70"; AWG_S1="51"; AWG_S2="102"
AWG_H1="1148403838"; AWG_H2="1351874800"; AWG_H3="1936608092"; AWG_H4="1830553362"

# --- Selective Growth: client-side split-tunnel defaults (VIS-0009; ADR-0027; closed-by-default lineage
# ADR-0026) -------------------------------------------------------------------------------------------
# "The mycelium does not grow where it is not needed." A generated CLIENT config carries ONLY traffic
# whose native path is impaired; natively-reachable destinations route DIRECT (split-tunnel). The
# WireGuard-class transport is CIDR-only, so it can only APPROXIMATE this via a region-exclude
# AllowedIPs route set (domain-aware split is the xray-class engine's job, not this path's). These
# knobs touch ONLY the generated client config(s); the server awg0.conf is never affected.
AWG_SPLIT_TUNNEL=1                 # 1 = split-tunnel by default (Selective Growth); 0 only with the opt-out below
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
AWG_SG_OPTOUT_MARKER="# selective-growth: opt-out (full-tunnel)"  # exact marker the gate look-behinds for

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
NB_LIB_DIR="$ARTIFACT_ROOT/control/lib"
for _lib in nb_identity nb_donor nb_harden nb_install; do
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
# C19: operator-set TOGGLE overrides, persisted SEPARATELY from identity-derived fields. write_params
# regenerates the identity-derived fields every run (keys/secrets/ports/paths from local identity), but
# an operator who turns a transport ON (e.g. setting the hysteria2 enable flag) must NOT have that
# silently reverted to default-OFF on the next --update. This 0600 file records ONLY the operator-settable
# toggles (the *_enable* flags + the few operator-tunable knobs); it is merged ON TOP of the regenerated
# defaults so an operator enablement survives every re-render. Local-only / gitignored; absent on a node
# whose operator never overrode anything (then defaults apply, byte-identically to today).
OPERATOR_OVERRIDES="$STATE_DIR/operator-overrides.json"

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
# Build params.json (the FLAT render schema) from LOCAL identity + canonical port map.
# Ports come from the canonical map (PORTS.md / renderer defaults), NOT from params.example.json
# (whose port values drift — see the map-phase notes).
# ---------------------------------------------------------------------------
# resolve_node_address — echo this node's OWN reachable address for client subscriptions.
# Order: explicit --node-address > a previously stored value > best-effort auto-detect of the
# primary public/global address > the documented loud placeholder. The chosen value is LOCAL-ONLY
# (params.json, 0600) — a real IP/host is NEVER committed (the placeholder is the only committed
# default, and it is non-functional by design).
resolve_node_address() {
	if [ -n "$NODE_ADDRESS" ]; then printf '%s\n' "$NODE_ADDRESS"; return 0; fi
	# Reuse a value already recorded in params.json across re-runs (idempotent; respects an operator
	# who set a real address once).
	if [ -f "$PARAMS_JSON" ] && have jq; then
		local prev
		prev="$(jq -r '.node_address // empty' "$PARAMS_JSON" 2>/dev/null)"
		if [ -n "$prev" ] && [ "$prev" != "$NODE_ADDRESS_PLACEHOLDER" ]; then
			printf '%s\n' "$prev"; return 0
		fi
	fi
	# Best-effort auto-detect of the primary GLOBAL-scope address (no external service contacted).
	local addr=""
	if have ip; then
		addr="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
		[ -n "$addr" ] || addr="$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
	fi
	if [ -n "$addr" ]; then printf '%s\n' "$addr"; return 0; fi
	# Fail-closed fallback: the documented placeholder, with a loud warning at the call site.
	printf '%s\n' "$NODE_ADDRESS_PLACEHOLDER"
	return 0
}

# ---------------------------------------------------------------------------
# assert_two_hop_shape FILE — fail-closed shape validation of a node-local two_hop.json overlay
# (C17/C18/C21). Mirrors render_singbox.sh's fail-closed `.two_hop` guard so a malformed overlay is
# caught at the SAME consistency bar at params-write time, not only deep in the renderer. Any failure
# is a hard `die` (the caller has already decided the file is PRESENT, so absence is not this function's
# concern). Checks, in order:
#   * valid JSON object (not an array/scalar)                                  — well-formedness
#   * non-empty via_user                                                        (C17/C18 precondition)
#   * well-formed upstream: non-empty tag, non-empty server, integer server_port in 1..65535, non-empty
#     sni                                                                       (C17 well-formed upstream)
#   * via_user names an EXISTING identity (clients[].name in IDENTITIES_JSON)   (C18 unknown-user refusal)
#   * egress upstream is DISTINCT from this ingress node — server != node_address AND sni != donor_sni
#     (C21 ingress==egress refusal: a two-hop whose egress is the ingress itself is no second hop)
assert_two_hop_shape() {
	local file="$1" th ingress_addr ingress_sni
	have jq || die "jq required to validate the two_hop overlay (fail-closed)."
	jq -e 'type == "object"' "$file" >/dev/null 2>&1 \
		|| die "two_hop.json ($file) is not a JSON object (fail-closed; a two-hop overlay must be an object)."
	th="$(jq -c . "$file" 2>/dev/null)" \
		|| die "two_hop.json ($file) is not valid JSON (fail-closed)."
	# via_user must be present and non-empty (an unscoped egress no route selects is refused upstream too).
	local th_via; th_via="$(printf '%s' "$th" | jq -r '.via_user // ""')"
	[ -n "$th_via" ] || die "two_hop.json: via_user is empty (fail-closed; a two-hop must name the designated client that egresses out-of-region)."
	# Well-formed upstream: tag, server, sni non-empty; server_port an integer in range.
	local th_tag th_server th_sni th_port
	th_tag="$(printf '%s' "$th" | jq -r '.tag // ""')"
	th_server="$(printf '%s' "$th" | jq -r '.server // ""')"
	th_sni="$(printf '%s' "$th" | jq -r '.sni // ""')"
	th_port="$(printf '%s' "$th" | jq -r '.server_port // empty')"
	[ -n "$th_tag" ]    || die "two_hop.json: tag is empty (fail-closed; the upstream outbound needs a tag)."
	[ -n "$th_server" ] || die "two_hop.json: server is empty (fail-closed; the upstream needs an address)."
	[ -n "$th_sni" ]    || die "two_hop.json: sni is empty (fail-closed; the upstream TLS needs a server_name)."
	case "$th_port" in
		''|*[!0-9]*) die "two_hop.json: server_port is not a positive integer ('$th_port'); must be 1..65535 (fail-closed)." ;;
	esac
	if [ "$th_port" -lt 1 ] || [ "$th_port" -gt 65535 ]; then
		die "two_hop.json: server_port is out of range ('$th_port'); must be 1..65535 (fail-closed)."
	fi
	# C18: via_user must match an existing identity (clients[].name). An auth_user route for an unknown
	# user renders fine but NEVER matches — a dead, unscoped egress rule. Refuse it here.
	if [ -f "$IDENTITIES_JSON" ]; then
		if ! jq -e --arg u "$th_via" 'any(.clients[]?; .name == $u)' "$IDENTITIES_JSON" >/dev/null 2>&1; then
			die "two_hop.json: via_user '$th_via' is not a known client in $IDENTITIES_JSON (fail-closed; the auth_user route would never match — add the identity or fix via_user)."
		fi
	else
		die "two_hop.json: cannot verify via_user '$th_via' — $IDENTITIES_JSON is missing (fail-closed; bootstrap an identity before configuring two-hop)."
	fi
	# C21: the egress upstream must be DISTINCT from this ingress node, or the "two hops" are one. Compare
	# against this node's own reachable address and its donor_sni. Same host OR same SNI => die.
	ingress_addr="$(resolve_node_address)"
	if [ -f "$PARAMS_JSON" ] && have jq; then
		ingress_sni="$(jq -r '.donor_sni // ""' "$PARAMS_JSON" 2>/dev/null)"
	fi
	if [ -n "$ingress_addr" ] && [ "$th_server" = "$ingress_addr" ]; then
		die "two_hop.json: egress server '$th_server' is THIS node's own address (fail-closed; ingress and egress must be distinct nodes — a two-hop to itself is no second hop). See --disable-two-hop to remove the overlay."
	fi
	if [ -n "$ingress_sni" ] && [ "$th_sni" = "$ingress_sni" ]; then
		die "two_hop.json: egress sni '$th_sni' equals this node's donor_sni (fail-closed; egress must be a distinct node, not the ingress SNI). See --disable-two-hop to remove the overlay."
	fi
	log "two_hop overlay validated (via_user='$th_via', egress tag='$th_tag', distinct from ingress)."
}

# ---------------------------------------------------------------------------
# OPERATOR-TOGGLE OVERRIDES (C19 defect 2). write_params regenerates the FLAT params from the LOCAL
# identity + canonical ports every run, so any operator-set toggle (e.g. enabling a transport) would be
# silently reverted to its default on each --update. To preserve operator intent WITHOUT making the
# whole params file operator-owned (the keys/secrets/ports MUST stay identity-derived + canonical), we
# persist ONLY the operator-settable toggle subset in a dedicated 0600 overrides file and merge it ON
# TOP of the regenerated defaults.
#
# OPERATOR_TOGGLE_KEYS is the closed allowlist of keys an operator may override (the *_enabled flags +
# the handful of operator-tunable knobs). Identity-derived fields (keys, secrets, node_address, cert
# paths, short_ids) are DELIBERATELY excluded so they can never be pinned stale by an override.
OPERATOR_TOGGLE_KEYS='[
	"vless_reality_vision_enabled","vless_reality_grpc_enabled","vless_reality_xhttp_enabled",
	"vless_xhttp_tls_enabled","hysteria2_enabled","tuic_enabled","shadowsocks_enabled",
	"shadowtls_enabled","trojan_enabled",
	"vless_reality_vision_port","vless_reality_grpc_port","vless_reality_xhttp_port",
	"vless_xhttp_tls_port","hysteria2_port","tuic_port","shadowsocks_port","shadowtls_port",
	"trojan_port","xhttp_path","xhttp_path_tls","grpc_service_name","region_bucket"
]'

# seed_operator_overrides DEFAULTS_FILE — on the FIRST write under this logic (no overrides file yet),
# capture any operator toggles that DIFFER from the freshly-generated defaults from the PRIOR params.json
# (so an operator who enabled a transport before this change is not reverted on the upgrade). If there is
# no prior params or nothing differs, write an empty {} so subsequent reads are stable. Idempotent.
seed_operator_overrides() {
	local defaults_file="$1"
	[ -f "$OPERATOR_OVERRIDES" ] && return 0
	local seeded='{}'
	if [ -f "$PARAMS_JSON" ]; then
		# Keep only allowlisted keys whose PRIOR value differs from the freshly-generated default.
		seeded="$(jq -n \
			--slurpfile prev "$PARAMS_JSON" \
			--slurpfile def "$defaults_file" \
			--argjson keys "$OPERATOR_TOGGLE_KEYS" \
			'($prev[0] // {}) as $p | ($def[0] // {}) as $d
			 | reduce $keys[] as $k ({};
				 if ($p|has($k)) and ($p[$k] != $d[$k]) then . + { ($k): $p[$k] } else . end)' \
			2>/dev/null || printf '{}')"
		[ -n "$seeded" ] || seeded='{}'
	fi
	( umask 077; printf '%s\n' "$seeded" | jq . >"$OPERATOR_OVERRIDES" ) \
		|| die "could not write operator overrides file $OPERATOR_OVERRIDES (fail-closed)."
	if [ "$seeded" != '{}' ]; then
		log "operator overrides seeded from prior params (preserving operator-set toggles across --update): $OPERATOR_OVERRIDES"
	fi
}

# merge_operator_overrides DEFAULTS_FILE — merge the persisted operator toggles ON TOP of the freshly
# generated defaults, in place. Only allowlisted keys are honoured (a stray key in the overrides file is
# IGNORED, never injected), so the overrides file can never smuggle an identity-derived field.
merge_operator_overrides() {
	local defaults_file="$1"
	[ -f "$OPERATOR_OVERRIDES" ] || return 0
	jq -e 'type == "object"' "$OPERATOR_OVERRIDES" >/dev/null 2>&1 \
		|| die "operator overrides file $OPERATOR_OVERRIDES is not a JSON object (fail-closed; fix or remove it)."
	local merged
	merged="$(jq -n \
		--slurpfile def "$defaults_file" \
		--slurpfile ovr "$OPERATOR_OVERRIDES" \
		--argjson keys "$OPERATOR_TOGGLE_KEYS" \
		'($def[0] // {}) as $d | ($ovr[0] // {}) as $o
		 | reduce $keys[] as $k ($d;
			 if ($o|has($k)) then . + { ($k): $o[$k] } else . end)' \
		2>/dev/null)" \
		|| die "could not merge operator overrides into params (fail-closed)."
	[ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1 \
		|| die "operator-override merge produced invalid JSON (fail-closed)."
	printf '%s\n' "$merged" >"$defaults_file"
	log "params: applied operator-set toggle overrides on top of regenerated defaults (C19: operator enablement preserved across --update)."
}

write_params() {
	log "writing params.json (local-only render input) from node identity + canonical ports"
	need_root
	have jq || die "jq required to write params."
	[ -f "$IDENTITY_SECRETS" ] || die "node secrets missing; run identity step first."
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would write $PARAMS_JSON"; return 0; fi

	# Resolve this node's own reachable address for subscriptions (NEVER hardcoded to the placeholder).
	local node_address
	node_address="$(resolve_node_address)"
	if [ "$node_address" = "$NODE_ADDRESS_PLACEHOLDER" ]; then
		warn "node_address is the placeholder '$NODE_ADDRESS_PLACEHOLDER': generated client"
		warn "subscriptions will NOT connect. Set the real value with --node-address ADDR (or fix"
		warn "auto-detection) before generating subscriptions from this node's params.json."
	else
		log "recording node_address for subscriptions (local-only): $node_address"
	fi

	local s priv pub sid donor ss tj hy st
	s="$(cat "$IDENTITY_SECRETS")"
	priv="$(printf '%s' "$s" | jq -r '.reality.private_key')"
	pub="$(printf '%s'  "$s" | jq -r '.reality.public_key')"
	sid="$(printf '%s'  "$s" | jq -r '.reality.short_id')"
	donor="$(printf '%s' "$s" | jq -r '.donor.host')"
	ss="$(printf '%s'   "$s" | jq -r '.secrets.ss_password')"
	tj="$(printf '%s'   "$s" | jq -r '.secrets.trojan_password')"
	hy="$(printf '%s'   "$s" | jq -r '.secrets.hysteria2_password')"
	st="$(printf '%s'   "$s" | jq -r '.secrets.shadowtls_password')"
	# // "" so a legacy identity.json without clash_secret yields EMPTY (not the string "null"):
	# write_params then renders clash_api WITHOUT a secret, byte-identical to today (no-op update).
	clash="$(printf '%s' "$s" | jq -r '.secrets.clash_secret // ""')"

	# DEFAULT-ON SET (friends alpha, "Variant A" — recorded in ADR-0022 + THREAT-MODEL port posture):
	# the two certless REALITY transports — VLESS+REALITY+XTLS-Vision (443) and VLESS+REALITY+gRPC
	# (8443). NOTE: gRPC is the SAME reality-tls-tcp FAMILY as Vision (not a second independent family
	# for D2 — AmneziaWG/UDP is, ADR-0020 §5); it is a second always-on port for client failover, and
	# the only default-on set above single-443. This live default differs from the conservative
	# group_vars/Ansible default (Vision only) by design; pinned by
	# tests/conformance/live_artifact_posture.sh so it cannot silently grow. Everything else = OFF.
	#
	# HY2/TUIC are DEFAULT-OFF here, even though they are part of the broader canonical set, because
	# they present a per-node SELF-SIGNED cert (ADR-0014) that the client MUST verify via a SHA-256
	# cert pin. The client/subscription renderer does not yet EMIT that pin, and blanket
	# `insecure: true` trust is FORBIDDEN (ADR-0014 — it would accept any certificate / MITM-open).
	# So shipping HY2/TUIC on by default would yield clients that either cannot connect or only
	# connect insecurely. Re-enabling them requires the cert-pin client path (tracked follow-up);
	# until then keep them OFF. An operator can still override per node (the toggles below + the
	# firewall/render pipeline honour whatever is set here).
	local tmp
	tmp="$(mktemp "${STATE_DIR}/.params.XXXXXX")"
	jq -n \
		--arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg donor "$donor" \
		--arg ss "$ss" --arg tj "$tj" --arg hy "$hy" --arg st "$st" \
		--arg clash "$clash" \
		--arg node_address "$node_address" \
		--arg tls_cert "$TLS_DIR/fullchain.pem" --arg tls_key "$TLS_DIR/privkey.pem" \
		'{
			node_address: $node_address,
			donor_host: $donor, donor_sni: $donor,
			reality_private_key: $priv, reality_public_key: $pub,
			short_ids: [ $sid ],
			tls_sni: $donor,
			tls_certificate_path: $tls_cert, tls_key_path: $tls_key,
			grpc_service_name: "grpc.health.v1.Health",
			xhttp_path: "/",
			shadowtls_handshake_server: $donor, shadowtls_handshake_port: 443,
			ss_password: $ss, trojan_password: $tj, hysteria2_password: $hy, shadowtls_password: $st,
			clash_secret: $clash,

			vless_reality_vision_enabled: true,  vless_reality_vision_port: 443,
			vless_reality_grpc_enabled:   true,  vless_reality_grpc_port:   8443,
			vless_reality_xhttp_enabled:  false, vless_reality_xhttp_port:  2096,
			# vless-xhttp-tls: XHTTP over GENUINE single-layer TLS (own cert; NO reality). Default OFF
			# (fail-closed; rendered only when enabled). Canonical port 2087 (deliberately not 8443).
			vless_xhttp_tls_enabled:      false, vless_xhttp_tls_port:      2087,
			# HY2/TUIC default OFF: need a client cert pin the renderer does not yet emit (ADR-0014).
			hysteria2_enabled:            false, hysteria2_port:            8444,
			tuic_enabled:                 false, tuic_port:                 8445,
			shadowsocks_enabled:          false, shadowsocks_port:          8388,
			shadowtls_enabled:            false, shadowtls_port:            8446,
			trojan_enabled:               false, trojan_port:               8447
		}' >"$tmp"
	# C19 (defect 2): preserve operator-set toggles across regeneration. The block above is the
	# identity-derived + canonical DEFAULT. seed_operator_overrides captures (once) any pre-existing
	# operator enablement from the prior params; merge_operator_overrides then re-applies the persisted
	# operator toggles ON TOP of these defaults so an enablement set on a previous run is NOT reverted by
	# this --update. Only the allowlisted toggle keys are honoured; identity-derived fields stay as
	# regenerated. A node whose operator never overrode anything keeps an empty {} and renders identically.
	seed_operator_overrides "$tmp"
	merge_operator_overrides "$tmp"
	# Optional two-hop egress overlay (ADR-0029): a node acting as an in-region INGRESS for an
	# out-of-region egress drops a local-only two_hop.json into STATE_DIR; merge it into params so the
	# renderer (render_singbox.sh) emits the upstream outbound + auth_user route. Node-local + never
	# committed -> survives the fetch/re-render cycle; absent on every other node -> params render
	# byte-identically (gated, zero blast radius). See render_singbox.sh `.two_hop` handling.
	#
	# C19 FAIL-CLOSED: an ABSENT two_hop.json means the feature is OFF (fine — every other node). But a
	# PRESENT-yet-malformed two_hop.json (invalid JSON, wrong shape, or empty via_user) is operator error
	# that MUST hard-fail here, never silently write params WITHOUT the overlay. Writing fail-OPEN would
	# diverge from render_singbox.sh (which is fail-CLOSED on the same overlay): params would advertise a
	# node with no egress while the operator believes the egress is live. So: present => it must be a
	# well-formed object with a non-empty via_user and a well-formed upstream, or we `die`.
	if [ -f "$STATE_DIR/two_hop.json" ]; then
		assert_two_hop_shape "$STATE_DIR/two_hop.json"
		if jq --slurpfile th "$STATE_DIR/two_hop.json" '.two_hop = $th[0]' "$tmp" >"$tmp.th"; then
			mv -f "$tmp.th" "$tmp"
			log "params: merged node-local two_hop egress overlay (ADR-0029 in-region ingress)."
		else
			rm -f "$tmp.th" "$tmp"
			die "two_hop.json is present but could not be merged into params (fail-closed; refusing to write params WITHOUT the operator's two-hop overlay). Fix or remove $STATE_DIR/two_hop.json (see --disable-two-hop)."
		fi
	fi
	mv -f "$tmp" "$PARAMS_JSON"; chmod 0600 "$PARAMS_JSON"
	# Mirror the clash secret to a 0600 file so the loopback data-plane stats exporter can authenticate
	# to clash_api (--clash-secret-file). Empty on legacy nodes: leave no file (the exporter then reads
	# the still-open loopback clash_api exactly as today).
	if [ -n "$clash" ] && [ "$DRY_RUN" -eq 0 ]; then
		( umask 077; printf '%s' "$clash" >"$STATE_DIR/clash.secret" )
	fi
	log "wrote $PARAMS_JSON (0600, local-only)."
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
			"reality-tcp","xhttp-tls","quic-udp","shadowsocks-tcp",
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

# compute_client_allowed HAS_V6 -> set SG_ALLOWED_LINES (one CIDR/line) + SG_MARKER. Selective Growth
# (VIS-0009/ADR-0027): the generated CLIENT tunnel carries ONLY impaired-path traffic; we NEVER silently
# full-tunnel. Resolution order:
#   1. AWG_FULL_TUNNEL_OPTOUT=1            -> deliberate full tunnel: marker + default route(s).
#   2. split-tunnel ON + non-empty list   -> that file's region-exclude route set, verbatim.
#   3. split-tunnel ON + no/empty list    -> SAFE NARROW: in-tunnel range(s) only; warn loudly.
#   4. split-tunnel OFF without opt-out    -> refuse (return 1).
compute_client_allowed() {
	local has_v6="$1" line v4net
	SG_ALLOWED_LINES=""; SG_MARKER=""
	if [ "$AWG_FULL_TUNNEL_OPTOUT" -eq 1 ]; then
		SG_MARKER="$AWG_SG_OPTOUT_MARKER"
		if [ "$has_v6" -eq 1 ]; then SG_ALLOWED_LINES="0.0.0.0/0
::/0"; else SG_ALLOWED_LINES="0.0.0.0/0"; fi
		warn "AWG_FULL_TUNNEL_OPTOUT=1 — emitting a DELIBERATE full-tunnel client (marker recorded). Prefer a region-exclude list (Selective Growth)."
		return 0
	fi
	if [ "$AWG_SPLIT_TUNNEL" -eq 0 ]; then
		warn "AWG_SPLIT_TUNNEL=0 with no AWG_FULL_TUNNEL_OPTOUT — refusing an undocumented full-tunnel client."
		return 1
	fi
	if [ -n "$AWG_REGION_EXCLUDE_FILE" ] && [ -f "$AWG_REGION_EXCLUDE_FILE" ]; then
		while IFS= read -r line; do
			line="${line%%#*}"
			line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
			[ -n "$line" ] || continue
			case "$line" in
				0.0.0.0/0|::/0) warn "region-exclude file lists a default route ($line) — that is a full tunnel; ignoring that entry."; continue ;;
			esac
			if [ -z "$SG_ALLOWED_LINES" ]; then SG_ALLOWED_LINES="$line"; else SG_ALLOWED_LINES="$SG_ALLOWED_LINES
$line"; fi
		done < "$AWG_REGION_EXCLUDE_FILE"
		if [ -n "$SG_ALLOWED_LINES" ]; then
			# IPv6-leak guard (ADR-0027): a region-exclude list that carries NO v6 route leaves the client's
			# PUBLIC IPv6 outside the tunnel — the client still gets an in-tunnel v6 ULA AND the host keeps its
			# own v6 default route, so v6 egresses DIRECT, defeating the split (impaired-path destinations leak
			# over v6). If the list is v4-only, capture all v6 into the tunnel (::/0): the node routes it when it
			# has global v6, otherwise it is dropped and apps fall back to (tunnelled) IPv4. Never leak v6.
			if ! printf '%s\n' "$SG_ALLOWED_LINES" | grep -q ':'; then
				SG_ALLOWED_LINES="$SG_ALLOWED_LINES
::/0"
				log "split-tunnel: region-exclude list is IPv4-only — appended ::/0 to stop an IPv6 leak."
			fi
			log "split-tunnel: AllowedIPs from region-exclude file $AWG_REGION_EXCLUDE_FILE (Selective Growth)."
			return 0
		fi
		warn "region-exclude file $AWG_REGION_EXCLUDE_FILE yielded no usable CIDRs — falling back to the safe narrow default."
	fi
	v4net="$(printf '%s' "$AWG_TUNNEL_V4" | sed -E 's#\.[0-9]+/[0-9]+$#.0/24#')"
	SG_ALLOWED_LINES="$v4net"
	if [ "$has_v6" -eq 1 ]; then SG_ALLOWED_LINES="$SG_ALLOWED_LINES
${AWG_PEER_BASE_V6}/64"; fi
	warn "no region-exclude list configured (AWG_REGION_EXCLUDE_FILE unset/empty) — emitting a SAFE NARROW client (tunnel ranges only). It will NOT carry out-of-region impaired-path traffic until you supply a region-exclude AllowedIPs file. Intentional: we never silently full-tunnel."
	return 0
}

# sg_allowed_join -> echo SG_ALLOWED_LINES as 'a, b, c' (pure bash; no paste dependency).
sg_allowed_join() {
	local out="" line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ -z "$out" ]; then out="$line"; else out="$out, $line"; fi
	done < <(printf '%s\n' "$SG_ALLOWED_LINES")
	printf '%s' "$out"
}

# render_awg0 — FIRST-TIME render of the AmneziaWG server config (awg0.conf) + one [Peer] per client,
# plus a ready-to-import client config per identity. Mirrors the audited amneziawg Ansible role
# (templates/awg0.conf.j2 + defaults). The CALLER invokes this ONLY when awg0.conf is ABSENT, so a
# live/hand-tuned config (a node already in service) is NEVER clobbered. Per-client awg keypairs are
# generated once (0600) and reused. The node is v4-only unless it has a global IPv6 address, in which
# case it is dual-stack with NAT66 — matching the live fleet. No custom crypto: keys come only from
# awg genkey|pubkey|genpsk (ADR-0002).
render_awg0() {
	local out="$1"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would render $out + per-client AmneziaWG configs"; return 0; fi
	local awg_state="$STATE_DIR/awg" clients_dir
	clients_dir="$awg_state/clients"
	run install -d -m 0700 "$clients_dir"
	local spriv spub port wan has_v6 addr postup postdown
	spriv="$(cat "$awg_state/private.key")"
	spub="$(cat "$awg_state/public.key")"
	port="$(cat "$STATE_DIR/awg.port" 2>/dev/null || echo 51820)"
	wan="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
	[ -n "$wan" ] || { warn "could not detect the WAN interface; using 'eth0' in awg0.conf — verify it."; wan="eth0"; }
	has_v6=0; ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' && has_v6=1
	if [ "$has_v6" -eq 1 ]; then
		addr="$AWG_TUNNEL_V4, $AWG_TUNNEL_V6"
		postup="sysctl -w net.ipv4.ip_forward=1; sysctl -w net.ipv6.conf.all.forwarding=1; iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $wan -j MASQUERADE; ip6tables -t nat -A POSTROUTING -o $wan -j MASQUERADE"
		postdown="iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $wan -j MASQUERADE; ip6tables -t nat -D POSTROUTING -o $wan -j MASQUERADE"
	else
		addr="$AWG_TUNNEL_V4"
		postup="sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $wan -j MASQUERADE"
		postdown="iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $wan -j MASQUERADE"
	fi
	( umask 077; {
		printf '[Interface]\n'
		printf 'PrivateKey = %s\n' "$spriv"
		printf 'Address = %s\n' "$addr"
		printf 'ListenPort = %s\n' "$port"
		printf 'MTU = %s\n' "$AWG_MTU"
		printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2"
		printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
		printf 'PostUp = %s\n' "$postup"
		printf 'PostDown = %s\n' "$postdown"
	} > "$out" )
	# One [Peer] per client; generate the client's keypair+psk once and emit a ready client config.
	local node_addr; node_addr="$(resolve_node_address 2>/dev/null || printf '%s' "$NODE_ADDRESS_PLACEHOLDER")"
	local n=2 name cpub cpriv cpsk cv6 client_allowed client_dns
	for name in $CLIENT_NAMES; do
		[ -f "$clients_dir/$name.private" ] || ( umask 077; awg genkey >"$clients_dir/$name.private" )
		cpriv="$(cat "$clients_dir/$name.private")"
		cpub="$(awg pubkey <"$clients_dir/$name.private")"
		[ -f "$clients_dir/$name.psk" ] || ( umask 077; awg genpsk >"$clients_dir/$name.psk" )
		cpsk="$(cat "$clients_dir/$name.psk")"
		if [ "$has_v6" -eq 1 ]; then
			cv6=", ${AWG_PEER_BASE_V6}${n}/128"; client_dns="1.1.1.1, 2606:4700:4700::1111"
		else
			cv6=""; client_dns="1.1.1.1"
		fi
		# Selective Growth (VIS-0009/ADR-0027): the client tunnel carries ONLY impaired-path traffic by default.
		compute_client_allowed "$has_v6" || die "AmneziaWG client AllowedIPs unresolved — set AWG_FULL_TUNNEL_OPTOUT=1 to deliberately full-tunnel, or supply AWG_REGION_EXCLUDE_FILE."
		client_allowed="$(sg_allowed_join)"
		{
			printf '\n[Peer]\n# name = %s\n' "$name"
			printf 'PublicKey = %s\n' "$cpub"
			printf 'PresharedKey = %s\n' "$cpsk"
			printf 'AllowedIPs = %s.%s/32%s\n' "$AWG_PEER_BASE_V4" "$n" "$cv6"
		} >> "$out"
		( umask 077; {
			printf '[Interface]\n'
			printf 'PrivateKey = %s\n' "$cpriv"
			printf 'Address = %s.%s/32%s\n' "$AWG_PEER_BASE_V4" "$n" "$cv6"
			printf 'DNS = %s\n' "$client_dns"
			printf 'MTU = %s\n' "$AWG_MTU"
			printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX" "$AWG_S1" "$AWG_S2"
			printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
			printf '\n[Peer]\n'
			printf 'PublicKey = %s\n' "$spub"
			printf 'PresharedKey = %s\n' "$cpsk"
			printf 'Endpoint = %s:%s\n' "$node_addr" "$port"
			[ -n "$SG_MARKER" ] && printf '%s\n' "$SG_MARKER"
			printf 'AllowedIPs = %s\n' "$client_allowed"
			printf 'PersistentKeepalive = 25\n'
		} > "$clients_dir/$name.conf" )
		run chmod 0600 "$clients_dir/$name.conf"
		n=$((n + 1))
	done
	run chmod 0600 "$out"
	log "rendered $out + $(set -- $CLIENT_NAMES; printf '%s' "$#") AmneziaWG client config(s) under $clients_dir (0600, local — hand off out-of-band, like subscriptions)."
}

# ---------------------------------------------------------------------------
# AmneziaWG userspace path (amneziawg-go, kernel-independent). Built from source; brought up via
# awg-quick@ forcing the userspace implementation. Keys from awg genkey|pubkey|genpsk (ADR-0002).
# Out-of-band of the sing-box render (AmneziaWG is NOT a sing-box inbound).
# ---------------------------------------------------------------------------
# install_awg_tools — build + install the AmneziaWG userspace tools from pinned source when absent, so a
# fresh-VPS bootstrap brings up the second transport family with no manual fixups (Audit-0004 D4 / F-006).
# No upstream prebuilt amneziawg-go release exists, so this builds from source (apt golang-go +
# build-essential). Idempotent: a no-op when awg/awg-quick/amneziawg-go are already present. Also renders
# the custom awg-quick@.service that forces the userspace implementation (the kernel module is not used).
# flow_bootstrap-only (called from setup_amneziawg, which the timer never runs).
install_awg_tools() {
	if have awg && have awg-quick && have amneziawg-go; then
		log "AmneziaWG userspace tools already present; skipping build."
		return 0
	fi
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then
		log "[dry-run] would apt-get install golang-go build-essential, build amneziawg-go $AWG_GO_TAG + amneziawg-tools $AWG_TOOLS_TAG from source, install them, and render the userspace awg-quick@ unit."
		return 0
	fi
	have apt-get || die "AmneziaWG tools absent and no apt-get to bootstrap the build toolchain — install golang-go + build-essential + the awg tools by hand, or pass --no-amneziawg."
	log "building AmneziaWG userspace tools from pinned source (amneziawg-go $AWG_GO_TAG, amneziawg-tools $AWG_TOOLS_TAG)"
	env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go build-essential || die "failed to install golang-go + build-essential for the AmneziaWG build."
	local build; build="$(mktemp -d)" || die "mktemp failed for the AmneziaWG build."
	if ! have amneziawg-go; then
		git clone --depth 1 -b "$AWG_GO_TAG" "$AWG_GO_REPO" "$build/awg-go" || die "amneziawg-go clone ($AWG_GO_TAG) failed."
		( cd "$build/awg-go" && go build -trimpath -o amneziawg-go . ) || die "amneziawg-go build failed (check the Go toolchain)."
		install -m 0755 "$build/awg-go/amneziawg-go" "$AWG_BIN_DIR/amneziawg-go" || die "amneziawg-go install failed."
		log "built + installed amneziawg-go -> $AWG_BIN_DIR/amneziawg-go"
	fi
	if ! have awg || ! have awg-quick; then
		git clone --depth 1 -b "$AWG_TOOLS_TAG" "$AWG_TOOLS_REPO" "$build/awg-tools" || die "amneziawg-tools clone ($AWG_TOOLS_TAG) failed."
		make -C "$build/awg-tools/src" >/dev/null || die "amneziawg-tools build failed."
		make -C "$build/awg-tools/src" install >/dev/null || die "amneziawg-tools install failed."
		log "built + installed awg + awg-quick (amneziawg-tools $AWG_TOOLS_TAG)"
	fi
	rm -rf "$build" 2>/dev/null || true
	# Custom awg-quick@ unit forcing the userspace implementation (the kernel module is never used).
	local unit="/etc/systemd/system/awg-quick@.service"
	if [ ! -f "$unit" ]; then
		printf '%s\n' \
			'[Unit]' \
			'Description=AmneziaWG (userspace) via awg-quick for %i' \
			'After=network-online.target nss-lookup.target' \
			'Wants=network-online.target' \
			'' \
			'[Service]' \
			'Type=oneshot' \
			'RemainAfterExit=yes' \
			"Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=$AWG_BIN_DIR/amneziawg-go" \
			'ExecStart=/usr/bin/awg-quick up %i' \
			'ExecStop=/usr/bin/awg-quick down %i' \
			'' \
			'[Install]' \
			'WantedBy=multi-user.target' >"$unit"
		systemctl daemon-reload 2>/dev/null || true
		log "rendered custom awg-quick@.service (forces userspace amneziawg-go)."
	fi
}

setup_amneziawg() {
	[ "$DO_AMNEZIAWG" -eq 1 ] || { log "AmneziaWG step skipped (--no-amneziawg)."; return 0; }
	log "setting up the userspace AmneziaWG path (amneziawg-go)"
	need_root
	install_awg_tools
	if ! have awg || ! have awg-quick || ! have amneziawg-go; then
		warn "AmneziaWG userspace tools not all present. Build them from source (kernel-independent):"
		warn "  $AWG_GO_REPO        (amneziawg-go: the userspace implementation)"
		warn "  $AWG_TOOLS_REPO     (awg / awg-quick)"
		warn "Install them under $AWG_BIN_DIR and ensure awg-quick@ forces WG_QUICK_USERSPACE_IMPLEMENTATION."
		# Fail-closed (Audit-0004 F-006): AmneziaWG/UDP is the Phase-0 SECOND transport family
		# (ADR-0020 §5). Silently completing with only the REALITY family leaves the node one block away
		# from total loss — the exact failure D2 exists to prevent. Refuse, unless the operator opted out.
		die "AmneziaWG tools missing — refusing to report bootstrap complete with a single transport family. Install the tools above and re-run, or pass --no-amneziawg to deliberately ship a one-family node."
	fi
	# Identity: per-node keypair (+ optional psk). Generated once, kept local.
	local awg_state="$STATE_DIR/awg"
	run install -d -m 0700 "$awg_state"
	if [ ! -f "$awg_state/private.key" ] && [ "$DRY_RUN" -eq 0 ]; then
		( umask 077; awg genkey >"$awg_state/private.key" )
		awg pubkey <"$awg_state/private.key" >"$awg_state/public.key"
		awg genpsk >"$awg_state/preshared.key" 2>/dev/null || true
		log "generated AmneziaWG per-node keypair (local, 0700 dir)."
	fi
	# The actual listen port is an operator/runtime value (PORTS.md canon is 51820/udp). We record it
	# locally so the firewall step can open it; we do not hardcode a port into any committed file.
	[ -f "$STATE_DIR/awg.port" ] || { [ "$DRY_RUN" -eq 0 ] && printf '51820\n' >"$STATE_DIR/awg.port"; }
	# Render awg0.conf ONLY if absent — a live/hand-tuned config is never clobbered. The timer-driven
	# --update path (flow_update) NEVER calls setup_amneziawg (only flow_bootstrap does), so this render
	# cannot fire on an auto-pull; it runs only on an explicit bootstrap of a node whose awg0.conf does
	# not yet exist. Rotation/edits of an existing config are a deliberate manual action.
	local awg_conf_dir="/etc/amnezia/amneziawg" awg_conf
	awg_conf="$awg_conf_dir/awg0.conf"
	run install -d -m 0700 "$awg_conf_dir"
	if [ -f "$awg_conf" ]; then
		log "awg0.conf already present — leaving it untouched (idempotent; never clobber a live config)."
	else
		render_awg0 "$awg_conf"
	fi
	run systemctl enable awg-quick@awg0 2>/dev/null || warn "could not enable awg-quick@awg0."
	if [ "$DRY_RUN" -eq 0 ] && [ -f "$awg_conf" ] && ! systemctl is-active --quiet awg-quick@awg0; then
		run systemctl start awg-quick@awg0 2>/dev/null || true
	fi
	# Fail-closed (Audit-0004 F-006): the second family MUST be active before bootstrap reports success.
	if [ "$DRY_RUN" -eq 0 ] && ! systemctl is-active --quiet awg-quick@awg0; then
		die "awg-quick@awg0 is not active — the AmneziaWG/UDP second family failed to come up. Inspect 'journalctl -u awg-quick@awg0' (is amneziawg-go on PATH and the unit forcing WG_QUICK_USERSPACE_IMPLEMENTATION?). Fix and re-run, or --no-amneziawg to opt out."
	fi
}

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

# flow_disable_two_hop — C21 documented remove-two-hop path: delete the node-local two_hop.json overlay,
# regenerate params WITHOUT it, re-render + validate the server config fail-closed, promote + reload, and
# re-render the served bundle. This is the supported way to turn two-hop OFF — no manual file surgery, and
# every promotion path (server config + served bundle) is refreshed so nothing keeps a stale unscoped
# egress. Idempotent: if no overlay is present, it reports so and exits 0 (nothing to disable).
flow_disable_two_hop() {
	log "=== disable two-hop egress overlay (remove + re-render + reload) ==="
	need_root
	if [ ! -f "$STATE_DIR/two_hop.json" ]; then
		log "no two_hop.json present at $STATE_DIR — two-hop is already disabled (nothing to do)."
		return 0
	fi
	[ -f "$IDENTITY_SECRETS" ] || die "no local identity; cannot re-render after disabling two-hop (bootstrap first)."
	run rm -f "$STATE_DIR/two_hop.json"
	log "removed the node-local two_hop overlay ($STATE_DIR/two_hop.json)."
	# Regenerate params WITHOUT the overlay (write_params no longer finds two_hop.json -> no .two_hop key).
	write_params
	local candidate="$STATE_DIR/config.candidate.json"
	render_candidate "$candidate"
	if ! validate_config "$candidate"; then
		rm -f "$candidate" 2>/dev/null || true
		die "candidate failed 'sing-box check' after disabling two-hop (fail-closed; nothing promoted)."
	fi
	promote_config "$candidate"
	rm -f "$candidate" 2>/dev/null || true
	install_singbox_unit
	if apply_singbox && verify_post_apply; then
		# Re-render the served bundle so the served distribution reflects the now-two-hop-free config.
		render_serve_bundle
		log "two-hop disabled; config re-rendered + sing-box reloaded + served bundle refreshed."
	else
		warn "post-apply verification failed after disabling two-hop; rolling back."
		rollback_config
		apply_singbox || true
		die "disable-two-hop rolled back (fail-closed) — the prior config is restored."
	fi
}

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
