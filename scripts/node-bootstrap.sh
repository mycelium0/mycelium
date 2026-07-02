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
#     --rotate         apply a rotation plan (RP-0012). DEFAULT = DRY-RUN: apply the plan's params delta
#                        to a temp copy, render + validate (sing-box check); promotes NOTHING. Plan path:
#                        ROTATE_PLAN (default $STATE_DIR/rotate_plan.json), from `myceliumctl rotate-plan`.
#     --rotate --apply-rotation
#                      LIVE apply (C4c) — persist the rotation via the operator-overrides overlay,
#                        re-render, then promote -> verify -> rollback-on-failure (reverting the overlay).
#                        Requires the node to be ARMED (--rotate-arm); on an un-armed node it falls back
#                        to dry-run. NEVER reached by flow_bootstrap/flow_update; the timer ships disabled.
#     --rotate-arm / --rotate-disarm
#                      place / remove the node-local live-rotation arm sentinel ($STATE_DIR/rotate-live.enabled,
#                        never committed). A node actuates a live rotation only while armed.
#     --rotate-enable-loop / --rotate-disable-loop
#                      install+enable / disable+remove the unattended mycelium-rotate.timer (RP-0012 C4c-2).
#                        SHIPS DISABLED — never installed by bootstrap/update; this is the explicit, revertible
#                        opt-in to autonomous rotation (taken after the RP-0012 §6 go/no-go). Still gated by
#                        --apply-rotation + the arm sentinel, so an un-armed node's ticks are dry-runs.
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

# ===========================================================================
# ORCHESTRATION ONLY (RP-0009). This entrypoint does arg-parse, the flow_* dispatchers
# (bootstrap/update/ack/revoke/disable-two-hop/rotate; the rotate-arm/disarm + rotate-enable/disable-loop helpers live in nb_rotate_apply),
# post-apply verify_*, and dispatch — nothing more. Every
# render/validate/policy/merge/install concern lives in a sourced control/lib/nb_*.sh module (resolved
# from $ARTIFACT_ROOT/control/lib so it survives the --update re-exec):
#   nb_identity      key/uuid/shortid/secret gen + ensure_identity
#   nb_donor         REALITY donor selection
#   nb_harden        host hardening (journald/sshd/ufw)
#   nb_install       package/engine install + systemd unit + restart/apply helpers
#   nb_render_params write_params + operator-override seed/merge (control-logic; RP-0008 candidate)
#   nb_serve_bundle  the served last-known-good bundle gate + staleness signal
#   nb_two_hop       assert_two_hop_shape + the --disable-two-hop path (routing policy)
#   nb_render_awg    AmneziaWG dialect/render + split-tunnel AllowedIPs + userspace setup
#   nb_update_apply  the signed-pull -> render -> validate -> promote -> rollback apply state machine
#   nb_rotate_apply  the --rotate executor seam (RP-0012: dry-run by default; gated live promote->verify->rollback under --apply-rotation + arm sentinel; rotate_arm/disarm; the disabled unattended mycelium-rotate.timer via rotate_enable/disable_loop)
#   nb_observability node_exporter + the dataplane-metrics generator
# The "no new control-decisions-in-bash" rule is enforced by tests/conformance/no_new_control_decisions_in_bash.sh.
# ===========================================================================

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
MODE="bootstrap"            # bootstrap | update | ack | revoke | disable-two-hop | node-apply | rotate | rotate-arm | rotate-disarm | rotate-enable-loop | rotate-disable-loop | measure-enable | measure-disable | measure-configure | l7-probe
REVOKE_NAME=""              # client NAME|ID to revoke (with --revoke): revoke + re-render + reload
STAGED=0
DRY_RUN=0
ROTATE_APPLY=0             # with --rotate: 0 = dry-run (default), 1 = LIVE apply (also requires the node arm sentinel)
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
XRAY_VERSION=""             # e.g. v26.3.27 — operator-pinned; required ONLY when an xray-engine transport is enabled (ADR-0032)
XRAY_SHA256=""              # expected archive SHA256 — operator-supplied; fail-closed
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

# Canonical on-node xray path + release source (ADR-0032 dual-engine; installed ONLY when an
# xray-engine transport is enabled). The tag + hash are operator pins (fail-closed); only the base URL
# is committed.
XRAY_BIN="/usr/local/bin/xray"
XRAY_DL_BASE="https://github.com/XTLS/Xray-core/releases/download"
# Xray engine service paths (ADR-0032 dual-engine; peers of SINGBOX_ETC/SINGBOX_CONFIG). The xray
# engine serves from its OWN config, separate from sing-box's, so the two engines never collide.
XRAY_ETC="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_ETC/config.json"
# Shared unprivileged runtime identity: xray runs as the SAME system user/group as sing-box so it can
# read the per-node TLS cert/key (0640 root:$SINGBOX_RUN_GROUP) the own-cert xhttp-tls family presents —
# no second user and no cert re-chown. (Defined here, after SINGBOX_RUN_USER/GROUP above.)
XRAY_RUN_USER="$SINGBOX_RUN_USER"
XRAY_RUN_GROUP="$SINGBOX_RUN_GROUP"

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

# node_exporter (host metrics) constants — the pinned NODE_EXPORTER_VERSION + the public release base/
# SHA256s + the loopback listen/bin/textfile paths moved to control/lib/nb_observability.sh (RP-0009 C4),
# together with the install/unit/metrics-generator/setup functions that are their sole users. They are
# sourced below; DO_OBSERVABILITY (the --no-observability arg-parse flag) stays here — it is set by
# arg-parse + propagated through the --update re-exec (orchestration), and setup_observability reads it at
# call time from the shared sourced scope. dependency_policy.sh reads NODE_EXPORTER_VERSION from that lib.

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
		--node-apply)      MODE="node-apply"; shift ;;
		--rotate)          MODE="rotate"; shift ;;
		--apply-rotation)  ROTATE_APPLY=1; shift ;;
		--rotate-arm)      MODE="rotate-arm"; shift ;;
		--rotate-disarm)   MODE="rotate-disarm"; shift ;;
		--rotate-enable-loop)  MODE="rotate-enable-loop"; shift ;;
		--rotate-disable-loop) MODE="rotate-disable-loop"; shift ;;
		--measure-enable)    MODE="measure-enable"; shift ;;
		--measure-disable)   MODE="measure-disable"; shift ;;
		--measure-configure) MODE="measure-configure"; shift ;;
		--l7-probe)          MODE="l7-probe"; shift ;;
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
		--xray-version)    XRAY_VERSION="${2:?--xray-version needs a value}"; shift 2 ;;
		--xray-sha256)     XRAY_SHA256="${2:?--xray-sha256 needs a value}"; shift 2 ;;
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
# C4 adds the apply state machine + observability: nb_update_apply (verify_signed_ref/myc_fetch_artifacts/
# render_candidate/validate_config/promote_config/rollback_config — the signed-pull / fail-closed render->
# validate->promote->rollback spine ADR-0015, CONTROL-LOGIC + the highest-value RP-0008 Go-migration
# earmark) and nb_observability (install_node_exporter/render_node_exporter_unit/
# write_dataplane_metrics_generator/setup_observability + the dedicated NODE_EXPORTER_* constants — OS-glue
# metrics wiring). The flow_* dispatchers (below) call myc_fetch_artifacts/render_candidate/validate_config/
# promote_config/rollback_config (flow_update/flow_ack/flow_revoke) and setup_observability (flow_bootstrap);
# those calls resolve at runtime in the shared sourced scope. The --update re-exec-from-immutable-copy guard
# stays in flow_update (orchestration); the libs are sourced HERE (before any flow), from the immutable
# re-exec'd copy too, so the apply state machine runs from a stable image.
# They define functions + their dedicated constants only; the constants reference STATE_DIR (already
# final after arg-parse, above) and the function bodies reference shared globals/helpers at call time.
NB_LIB_DIR="$ARTIFACT_ROOT/control/lib"
for _lib in nb_identity nb_donor nb_harden nb_engine_manifest nb_install nb_render_params nb_serve_bundle nb_front nb_two_hop nb_render_awg nb_update_apply nb_selftest nb_rotate_apply nb_measure nb_observability; do
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
# Xray engine render template + last-known-good (ADR-0032 dual-engine; peers of RENDER_TEMPLATE/
# LASTGOOD_CONFIG). Used only when node_needs_xray; a stock node never touches these.
XRAY_RENDER_TEMPLATE="$ARTIFACT_ROOT/nodes/dataplane/vless-xhttp-tls/xray.server.template.json"
XRAY_LASTGOOD_CONFIG="$STATE_DIR/xray.config.lastgood.json"
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
# The signed-pull / fail-closed apply state machine (ADR-0015) — the SUPPLY-CHAIN authenticity gate
# (verify_signed_ref) and the swappable fetch step (myc_fetch_artifacts, the ONLY place that knows HOW
# canonical artifacts arrive) moved to control/lib/nb_update_apply.sh (RP-0009 C4), sourced above, with
# the render->validate->promote->rollback primitives (render_candidate/validate_config/promote_config/
# rollback_config — below in the same lib). flow_update calls myc_fetch_artifacts; both verify_signed_ref
# and myc_fetch_artifacts reference the arg-parse-set fetch/repo vars (ALLOWED_SIGNERS/INSECURE_NO_VERIFY/
# REPO_URL/REPO_REF/CHECKOUT_DIR — left HERE, used widely) at call time from the shared sourced scope. The
# --update re-exec-from-immutable-copy guard stays in flow_update (orchestration), so fetch+render+validate+
# apply all still run from a stable image. This is CONTROL-LOGIC (the apply state machine), the highest-
# value RP-0008 Go-migration earmark. Behaviour is byte-identical to the inline definitions it replaced.
# ---------------------------------------------------------------------------

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
# The render->validate->promote->rollback config primitives — render_candidate (render the canonical
# config THROUGH the myceliumctl pipeline into a candidate; never promotes), validate_config (the fail-
# closed `sing-box check` gate the renderer does not run itself), promote_config (atomic live-config
# replace keeping a known-good backup), rollback_config (restore from last-known-good) — moved to
# control/lib/nb_update_apply.sh (RP-0009 C4), sourced above, alongside verify_signed_ref/
# myc_fetch_artifacts (the rest of the apply state machine). The flow_* dispatchers (below) call them on
# the bootstrap/update/ack/revoke paths; those calls resolve at call time from the shared sourced scope.
# LASTGOOD_CONFIG (read by promote/rollback) stays in the derived-state-paths block above — it is shared
# node-state alongside STAGED_CONFIG/ACK_MARKER, which the flows themselves use. CONTROL-LOGIC (the apply
# state machine), the highest-value RP-0008 Go-migration earmark.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Served distribution bundle (RP-0007-b) — render_serve_bundle + bundle_served_age_seconds +
# record_bundle_served_age moved to control/lib/nb_serve_bundle.sh (RP-0009 C2), together with the
# BUNDLE_DIR/BUNDLE_SERVED/BUNDLE_CANDIDATE/BUNDLE_SERVED_AGE_FILE served-path constants. They are
# sourced above; the flow_* dispatchers (below) call render_serve_bundle on every promotion path (C25).
# This is CONTROL-LOGIC (validation), earmarked for the RP-0008 Go migration (the authoritative
# internal/spec.Bundle.Validate round-trip).
# ---------------------------------------------------------------------------

# systemd service install + (re)start helpers — install_singbox_unit (the hardened sing-box unit),
# restart_singbox, AND apply_singbox (the flow-level apply primitive the update/revoke paths call) all
# live in control/lib/nb_install.sh, sourced above (RP-0009 C5). The unit's RestrictAddressFamilies
# incl. AF_NETLINK is kept in lockstep with the Ansible template by unit_netlink_parity.sh.

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
# Node-local observability (Phase 0) — a PINNED, checksum-verified node_exporter bound to loopback
# (install_node_exporter), its hardened unit (render_node_exporter_unit), the data-plane unit-active
# textfile metric generator + timer (write_dataplane_metrics_generator), and the setup orchestration
# (setup_observability) moved to control/lib/nb_observability.sh (RP-0009 C4), together with their
# dedicated NODE_EXPORTER_* constants (their sole users). They are sourced above; flow_bootstrap (below)
# calls setup_observability, resolved at call time from the shared sourced scope (the timer-driven
# flow_update NEVER does). DO_OBSERVABILITY stays in the entrypoint (arg-parse flag, propagated through
# the --update re-exec). OS-glue (metrics wiring); not an RP-0008 Go-migration candidate. The
# node_exporter unit is a loopback-only host-metric reader — correctly NOT in unit_netlink_parity.sh's
# engine-unit source list (no AF_NETLINK required). Behaviour is byte-identical to what it replaced.
# ---------------------------------------------------------------------------

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
	# ADR-0032 dual-engine: install xray-core ONLY when an xray-engine transport is enabled in the
	# just-written params (default-off => no xray on a stock node). This ensures the (pinned, checksum-
	# verified) binary is present; the xray CONFIG render + unit + apply follow after the primary engine
	# is up (the serve_xray block below).
	if node_needs_xray; then
		install_xray
	else
		log "no xray-engine transport enabled; skipping xray install (dual-engine opt-in, default-off)."
	fi
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
	# ADR-0032 dual-engine: bring up the OPTIONAL xray engine only when an xray-engine transport is
	# enabled — AFTER the primary sing-box engine is live. Same fail-closed spine as sing-box: render a
	# candidate, validate with `xray run -test`, promote with a known-good backup, then start (the unit's
	# ExecStartPre re-validates). A stock node skips this entirely (node_needs_xray false).
	if node_needs_xray; then
		local xray_candidate="$STATE_DIR/xray.config.candidate.json"
		render_xray_candidate "$xray_candidate"
		if ! validate_xray_config "$xray_candidate"; then
			rm -f "$xray_candidate" 2>/dev/null || true
			die "xray candidate failed 'xray run -test' on bootstrap (fail-closed). Fix params/template."
		fi
		promote_xray_config "$xray_candidate"
		rm -f "$xray_candidate" 2>/dev/null || true
		install_xray_unit
		restart_xray
	fi
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
		if [ -n "$XRAY_VERSION" ]; then reexec_args+=(--xray-version "$XRAY_VERSION"); fi
		if [ -n "$XRAY_SHA256" ]; then reexec_args+=(--xray-sha256 "$XRAY_SHA256"); fi
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
	# L7 ACCEPTANCE (advisory): a bound port is L4-only — it cannot distinguish a client-USABLE transport
	# from a client-DEAD one (a REALITY donor that breaks the handshake-steal, an expired/unreadable own
	# cert). verify_transports_l7 runs a REAL client handshake per client-facing transport from the
	# loopback. ADVISORY for now: a failure WARNs + records a marker but does NOT roll back — a transient
	# probe blip must never revert a healthy config; promotable to fail-closed once field-trusted.
	verify_transports_l7 || warn "post-apply L7 self-test flagged a client-dead transport (marker: $STATE_DIR/l7_selftest.json) — the listener is bound but a real client could not handshake."
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
		node-apply)      flow_node_apply ;;
		rotate)          flow_rotate ;;
		rotate-arm)      rotate_arm ;;
		rotate-disarm)   rotate_disarm ;;
		rotate-enable-loop)  rotate_enable_loop ;;
		rotate-disable-loop) rotate_disable_loop ;;
		measure-enable)    measure_enable ;;
		measure-disable)   measure_disable ;;
		measure-configure) generate_measure_configs ;;
		l7-probe)          measure_l7_probe ;;
		*) die "unknown mode: $MODE" ;;
	esac
fi
exit 0
