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
MODE="bootstrap"            # bootstrap | update | ack
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
# Generators — WRAPPERS ONLY around audited tools (ADR-0002). Not one byte of key
# material is produced by this script. Prefer the sing-box-native generators; fall
# back to openssl for random secrets. UUIDs come from sing-box.
# ---------------------------------------------------------------------------
gen_reality_keypair() {
	# Echo "PRIV<TAB>PUB" from "sing-box generate reality-keypair".
	have "$SINGBOX_BIN" || die "sing-box not installed yet; cannot generate REALITY keypair."
	local out priv pub
	out="$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)" \
		|| die "'sing-box generate reality-keypair' failed."
	priv="$(printf '%s\n' "$out" | sed -n 's/^[Pp]rivate[Kk]ey:[[:space:]]*//p; s/^[Pp]rivate [Kk]ey:[[:space:]]*//p' | head -n1 | tr -d '[:space:]')"
	pub="$(printf '%s\n' "$out"  | sed -n 's/^[Pp]ublic[Kk]ey:[[:space:]]*//p;  s/^[Pp]ublic [Kk]ey:[[:space:]]*//p'  | head -n1 | tr -d '[:space:]')"
	[ -n "$priv" ] && [ -n "$pub" ] || die "could not parse REALITY keypair output."
	printf '%s\t%s\n' "$priv" "$pub"
}

gen_uuid() {
	if have "$SINGBOX_BIN"; then
		"$SINGBOX_BIN" generate uuid 2>/dev/null | tr -d '[:space:]' && return 0
	fi
	# openssl is the sanctioned fallback for randomness; format it as a UUID shape.
	have openssl || die "no UUID source (need sing-box or openssl)."
	local h
	h="$(openssl rand -hex 16 2>/dev/null | tr -d '[:space:]')"
	[ -n "$h" ] || die "'openssl rand' produced no output."
	printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

gen_secret_b64() {
	# 32 random bytes, base64 — suitable for an SS-2022 PSK and protocol passwords.
	if have "$SINGBOX_BIN"; then
		"$SINGBOX_BIN" generate rand --base64 32 2>/dev/null | tr -d '[:space:]' && return 0
	fi
	have openssl || die "no random source (need sing-box or openssl)."
	openssl rand -base64 32 2>/dev/null | tr -d '[:space:]'
}

gen_shortid() {
	# 8 random bytes -> 16 hex chars (a common REALITY shortId length).
	have openssl || die "openssl required for REALITY shortIds."
	openssl rand -hex 8 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Donor SNI selection (RANDOM per node from the committed candidate list) + runtime verify.
# Public hostnames only; the chosen value is stored in LOCAL identity state, never committed.
# ---------------------------------------------------------------------------
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
# Host hardening (idempotent, fail-closed, with an anti-lockout guard on sshd).
# ---------------------------------------------------------------------------
harden_journald() {
	log "configuring journald (volatile storage)"
	need_root
	local dropin="/etc/systemd/journald.conf.d/10-mycelium-volatile.conf"
	run mkdir -p "$(dirname "$dropin")"
	if [ "$DRY_RUN" -eq 0 ]; then
		cat >"$dropin" <<'CONF'
# Managed by Mycelium node-bootstrap. Volatile journald: logs live in RAM and do not persist
# across reboots (less on-disk forensic residue; smaller writable footprint).
[Journal]
Storage=volatile
RuntimeMaxUse=64M
ForwardToSyslog=no
CONF
	fi
	# The no-logs posture must actually HOLD, not merely be configured: a persistent /var/log/journal
	# overrides Storage=volatile, so remove it — RAM-only, no on-disk forensic residue (SECURITY.md).
	[ "$DRY_RUN" -eq 0 ] && [ -d /var/log/journal ] && run rm -rf /var/log/journal
	# FAIL-CLOSED: a failed restart or a journal that is not actually volatile must abort the bootstrap,
	# not warn-and-continue — the claimed no-logs posture cannot be allowed to silently not hold.
	if ! run systemctl restart systemd-journald; then
		die "journald failed to restart after the volatile drop-in (fail-closed): inspect $dropin"
	fi
	if [ "$DRY_RUN" -eq 0 ]; then
		systemctl is-active --quiet systemd-journald || die "systemd-journald not active after restart (fail-closed)."
		[ -d /var/log/journal ] && die "persistent /var/log/journal remains — volatile journald not in effect (fail-closed)."
		log "journald is volatile (RAM-only); no persistent journal directory."
	fi
}

harden_sshd() {
	log "hardening sshd (key-only) with an anti-lockout guard"
	need_root
	# ANTI-LOCKOUT: only switch to key-only auth AFTER confirming at least one authorized key
	# exists for a login account. Otherwise we would lock the operator out — fail-closed by NOT
	# applying the change. We enumerate EVERY real account home from getent passwd (not just
	# /root + /home/*), so users with non-standard home dirs are covered, and we also honor an
	# AuthorizedKeysFile override from the effective sshd config.
	local has_key=0 akf home akpath
	# Resolve the configured AuthorizedKeysFile pattern(s); default to the standard locations.
	akf="$(sshd -T 2>/dev/null | sed -n 's/^authorizedkeysfile[[:space:]]*//p' | head -n1)"
	[ -n "$akf" ] || akf=".ssh/authorized_keys .ssh/authorized_keys2"
	# Candidate homes: root + every account that has a real home directory.
	while IFS=: read -r _u _p _uid _gid _gecos home _shell; do
		[ -n "${home:-}" ] || continue
		[ -d "$home" ] || continue
		local f
		for f in $akf; do
			case "$f" in
				/*) akpath="$f" ;;                 # absolute pattern: use as-is
				*)  akpath="$home/$f" ;;           # relative pattern: anchored at the home dir
			esac
			# %u/%h tokens in the pattern -> resolve to this account.
			akpath="${akpath//%h/$home}"
			akpath="${akpath//%u/$_u}"
			[ -f "$akpath" ] || continue
			if grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-|sk-)' "$akpath" 2>/dev/null; then
				has_key=1; break 2
			fi
		done
	done < <(getent passwd 2>/dev/null || true)
	if [ "$has_key" -ne 1 ]; then
		warn "no authorized SSH key found in any account — REFUSING to disable password auth"
		warn "(anti-lockout guard). Add your public key first, then re-run."
		return 0
	fi
	local dropin="/etc/ssh/sshd_config.d/10-mycelium.conf"
	run mkdir -p "$(dirname "$dropin")"
	if [ "$DRY_RUN" -eq 0 ]; then
		cat >"$dropin" <<'CONF'
# Managed by Mycelium node-bootstrap. Key-only SSH: no passwords, no challenge-response, no root
# password login. An authorized key was confirmed present before this was applied (anti-lockout).
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM yes
CONF
	fi
	# Validate the config BEFORE reloading; a broken sshd config must never take down access.
	if [ "$DRY_RUN" -eq 0 ]; then
		sshd -t 2>/dev/null || { warn "sshd -t failed; reverting drop-in (fail-closed)."; rm -f "$dropin"; return 0; }
	fi
	run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null \
		|| warn "could not reload sshd (continuing)."
}

harden_ufw() {
	log "configuring the host firewall (ufw) for the enabled canonical ports"
	need_root
	have ufw || { warn "ufw not installed; skipping firewall step (install ufw to enable)."; return 0; }
	# Default deny inbound; allow SSH first (anti-lockout) then ONLY the enabled protocols' ports.
	run ufw --force default deny incoming
	run ufw --force default allow outgoing
	# ANTI-LOCKOUT: never assume port 22. Open EXACTLY the port(s) the running sshd actually listens
	# on (parsed from the effective config), so enabling ufw cannot cut the live session even when
	# the operator runs sshd on a non-standard port.
	local ssh_ports sp opened_ssh=0
	ssh_ports="$(sshd -T 2>/dev/null | sed -n 's/^port[[:space:]]*//p' | sort -u)"
	if [ -n "$ssh_ports" ]; then
		for sp in $ssh_ports; do
			[ -n "$sp" ] || continue
			run ufw allow "$sp/tcp" && opened_ssh=1
			log "allowed the live sshd port $sp/tcp before enabling the firewall (anti-lockout)."
		done
	fi
	if [ "$opened_ssh" -ne 1 ]; then
		# Could not determine the sshd port (sshd -T unavailable): fall back to the standard profile,
		# but warn loudly — a non-standard live port could be cut.
		warn "could not detect the live sshd port; falling back to OpenSSH/22. If sshd runs on a"
		warn "non-standard port, allow it manually BEFORE 'ufw enable' to avoid a lockout."
		run ufw allow OpenSSH 2>/dev/null || run ufw allow 22/tcp
	fi
	# Canonical ports come from the rendered config (the single source of truth at runtime). We
	# read the live config's listen_port set so the firewall opens EXACTLY what is enabled.
	local enabled_tcp enabled_udp
	enabled_tcp=""; enabled_udp=""
	if [ -f "$SINGBOX_CONFIG" ] && have jq; then
		enabled_tcp="$(jq -r '
			[.inbounds[]? | select(.listen_port != null)
			 | select(.type=="vless" or .type=="trojan" or .type=="shadowtls"
			          or (.type=="shadowsocks" and (.listen|test("127\\.0\\.0\\.1")|not)))
			 | .listen_port] | unique | .[]' "$SINGBOX_CONFIG" 2>/dev/null | tr '\n' ' ')"
		enabled_udp="$(jq -r '
			[.inbounds[]? | select(.listen_port != null)
			 | select(.type=="hysteria2" or .type=="tuic") | .listen_port] | unique | .[]' \
			"$SINGBOX_CONFIG" 2>/dev/null | tr '\n' ' ')"
		# Shadowsocks-2022 opens BOTH tcp and udp on its port.
		local ss_port
		ss_port="$(jq -r '.inbounds[]? | select(.tag=="shadowsocks-in") | .listen_port // empty' "$SINGBOX_CONFIG" 2>/dev/null)"
		[ -n "$ss_port" ] && enabled_udp="$enabled_udp $ss_port"
	fi
	local p
	for p in $enabled_tcp; do run ufw allow "$p/tcp"; done
	for p in $enabled_udp; do run ufw allow "$p/udp"; done
	# AmneziaWG UDP port (its conventional canon port; the actual value is operator/runtime).
	if [ "$DO_AMNEZIAWG" -eq 1 ] && [ -f "$STATE_DIR/awg.port" ]; then
		run ufw allow "$(cat "$STATE_DIR/awg.port")/udp"
	fi
	run ufw --force enable
}

# ---------------------------------------------------------------------------
# Install a PINNED, checksum-verified sing-box (GitHub release). Idempotent: skips if the
# pinned version is already installed.
# ---------------------------------------------------------------------------
install_singbox() {
	log "ensuring sing-box is installed (pinned + checksum-verified)"
	need_root
	if have "$SINGBOX_BIN"; then
		local cur
		cur="$("$SINGBOX_BIN" version 2>/dev/null | sed -n 's/.*version[[:space:]]*//p' | head -n1)"
		if [ -n "$SINGBOX_VERSION" ] && printf '%s' "$cur" | grep -q "${SINGBOX_VERSION#v}"; then
			log "sing-box ${SINGBOX_VERSION} already installed; skipping."
			ensure_singbox_user
			return 0
		fi
	fi
	[ -n "$SINGBOX_VERSION" ] || die "--singbox-version is required to install sing-box (fail-closed pin)."
	[ -n "$SINGBOX_SHA256" ]  || die "--singbox-sha256 is required to install sing-box (fail-closed pin)."
	have curl || have wget || die "need curl or wget to download sing-box."
	have tar  || die "need tar to unpack the sing-box release."

	# Map machine arch -> the release archive arch token.
	local march arch
	march="$(uname -m)"
	case "$march" in
		x86_64|amd64) arch="amd64" ;;
		aarch64|arm64) arch="arm64" ;;
		armv7l) arch="armv7" ;;
		*) die "unsupported architecture for the sing-box release: $march" ;;
	esac
	local ver="${SINGBOX_VERSION#v}"
	local archive="sing-box-${ver}-linux-${arch}.tar.gz"
	local url="$SINGBOX_DL_BASE/${SINGBOX_VERSION}/${archive}"
	local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

	log "downloading $url"
	if have curl; then
		run curl -fsSL "$url" -o "$tmp/$archive" || die "download failed: $url"
	else
		run wget -qO "$tmp/$archive" "$url" || die "download failed: $url"
	fi

	# FAIL-CLOSED checksum verification against the operator-supplied pin.
	if [ "$DRY_RUN" -eq 0 ]; then
		local got
		if have sha256sum; then
			got="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
		else
			got="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"
		fi
		[ "$got" = "$SINGBOX_SHA256" ] \
			|| die "sing-box checksum MISMATCH (got $got, expected $SINGBOX_SHA256) — refusing to install."
		log "checksum verified: $got"
	fi

	run tar -xzf "$tmp/$archive" -C "$tmp"
	local extracted="$tmp/sing-box-${ver}-linux-${arch}/sing-box"
	[ "$DRY_RUN" -eq 1 ] || [ -f "$extracted" ] || die "release layout unexpected: $extracted not found."
	run install -m 0755 "$extracted" "$SINGBOX_BIN"
	log "installed sing-box to $SINGBOX_BIN"
	ensure_singbox_user
}

ensure_singbox_user() {
	# Create the unprivileged system user/group + canonical dirs idempotently.
	need_root
	if ! getent group "$SINGBOX_RUN_GROUP" >/dev/null 2>&1; then
		run groupadd --system "$SINGBOX_RUN_GROUP"
	fi
	if ! id "$SINGBOX_RUN_USER" >/dev/null 2>&1; then
		run useradd --system --gid "$SINGBOX_RUN_GROUP" --no-create-home \
			--shell /usr/sbin/nologin "$SINGBOX_RUN_USER"
	fi
	run install -d -m 0755 "$SINGBOX_ETC"
	run install -d -m 0710 -o root -g "$SINGBOX_RUN_GROUP" "$STATE_DIR"
	run install -d -m 0750 -o root -g "$SINGBOX_RUN_GROUP" "$TLS_DIR"
	run install -d -m 0750 -o "$SINGBOX_RUN_USER" -g "$SINGBOX_RUN_GROUP" "$STATE_DIR/run"
}

# ---------------------------------------------------------------------------
# Per-node identity (generated LOCALLY, once; converged on re-run). Secrets land 0600 in
# STATE_DIR and NEVER leave the node. The identities.json client list is consumed by the
# renderer; identity.json holds the REALITY keypair, per-protocol secrets, and chosen donor.
# ---------------------------------------------------------------------------
ensure_identity() {
	log "ensuring per-node identity exists (generated locally if absent)"
	need_root
	have jq || die "jq required for identity management."
	ensure_singbox_user

	# 1) Client identity list (names -> uuids), via myceliumctl (sing-box/openssl-backed).
	if [ ! -f "$IDENTITIES_JSON" ]; then
		if [ "$DRY_RUN" -eq 0 ]; then
			printf '{"version":1,"clients":[]}\n' >"$IDENTITIES_JSON"
			chmod 0600 "$IDENTITIES_JSON"
		fi
	fi
	local name
	for name in $CLIENT_NAMES; do
		if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] ensure client identity: $name"; continue; fi
		if jq -e --arg n "$name" 'any(.clients[]?; .name==$n)' "$IDENTITIES_JSON" >/dev/null 2>&1; then
			log "client '$name' already present."
		else
			local uuid created tmp
			uuid="$(gen_uuid)"; created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			tmp="$(mktemp "${STATE_DIR}/.id.XXXXXX")"
			jq --arg n "$name" --arg i "$uuid" --arg c "$created" \
				'.clients += [{name:$n,id:$i,created:$c}]' "$IDENTITIES_JSON" >"$tmp"
			mv -f "$tmp" "$IDENTITIES_JSON"; chmod 0600 "$IDENTITIES_JSON"
			log "issued client identity '$name'."
		fi
	done

	# 2) Node-level secrets + REALITY keypair + donor (once).
	if [ -f "$IDENTITY_SECRETS" ]; then
		log "node secrets already present at $IDENTITY_SECRETS; keeping them."
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would generate REALITY keypair, secrets, donor, cert"; return 0; fi

	local kp priv pub sid donor
	kp="$(gen_reality_keypair)"; priv="${kp%%	*}"; pub="${kp##*	}"
	sid="$(gen_shortid)"
	donor="$(pick_donor)"
	log "selected + verified donor SNI (stored locally; never committed)."

	local ss_pw tj_pw hy_pw st_pw clash_pw
	ss_pw="$(gen_secret_b64)"; tj_pw="$(gen_secret_b64)"
	hy_pw="$(gen_secret_b64)"; st_pw="$(gen_secret_b64)"
	# clash_api Bearer secret (loopback /connections auth, defence-in-depth — ADR-0014/Audit-0004 F-003).
	# Generated ONCE here at bootstrap; never regenerated on update (the secrets block is kept if present
	# above), so the live render stays stable. Legacy nodes whose identity predates this field render
	# clash_api WITHOUT a secret (byte-identical to today) — see write_params + render_singbox.
	clash_pw="$(gen_secret_b64)"

	# Per-node SELF-SIGNED cert (CN = donor) for the TLS-cert protocols (HY2/TUIC/Trojan). ADR-0014:
	# certless REALITY/AmneziaWG per-node keypairs; HY2/TUIC use a per-node self-signed cert + a
	# client sha256 pin. openssl (audited) issues it; the key never leaves the node.
	ensure_self_signed_cert "$donor"

	local tmp
	tmp="$(mktemp "${STATE_DIR}/.secrets.XXXXXX")"
	jq -n \
		--arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg donor "$donor" \
		--arg ss "$ss_pw" --arg tj "$tj_pw" --arg hy "$hy_pw" --arg st "$st_pw" \
		--arg clash "$clash_pw" \
		--arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
			version: 1, created: $created,
			reality: { private_key: $priv, public_key: $pub, short_id: $sid },
			donor:   { host: $donor, sni: $donor },
			secrets: { ss_password: $ss, trojan_password: $tj, hysteria2_password: $hy, shadowtls_password: $st, clash_secret: $clash }
		}' >"$tmp"
	mv -f "$tmp" "$IDENTITY_SECRETS"; chmod 0600 "$IDENTITY_SECRETS"
	log "wrote node secrets (0600): $IDENTITY_SECRETS"
}

ensure_self_signed_cert() {
	# ensure_self_signed_cert CN — per-node self-signed cert + key under TLS_DIR (ADR-0014).
	local cn="$1"
	have openssl || die "openssl required to issue the per-node self-signed cert."
	[ -f "$TLS_DIR/fullchain.pem" ] && [ -f "$TLS_DIR/privkey.pem" ] && { log "self-signed cert already present."; return 0; }
	log "issuing per-node self-signed cert (CN=donor) via openssl"
	run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout "$TLS_DIR/privkey.pem" -out "$TLS_DIR/fullchain.pem" \
		-days 3650 -nodes -subj "/CN=$cn" >/dev/null 2>&1 \
		|| die "openssl self-signed cert generation failed."
	# Publish the client sha256 pin (public; clients verify against it).
	if [ "$DRY_RUN" -eq 0 ]; then
		openssl x509 -in "$TLS_DIR/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null \
			| sed 's/.*=//' >"$STATE_DIR/cert.sha256.txt" || true
	fi
	run chown -R "root:$SINGBOX_RUN_GROUP" "$TLS_DIR"
	run chmod 0640 "$TLS_DIR/privkey.pem"
	run chmod 0644 "$TLS_DIR/fullchain.pem"
}

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
			# HY2/TUIC default OFF: need a client cert pin the renderer does not yet emit (ADR-0014).
			hysteria2_enabled:            false, hysteria2_port:            8444,
			tuic_enabled:                 false, tuic_port:                 8445,
			shadowsocks_enabled:          false, shadowsocks_port:          8388,
			shadowtls_enabled:            false, shadowtls_port:            8446,
			trojan_enabled:               false, trojan_port:               8447
		}' >"$tmp"
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
# systemd service install + (re)start / reload.
# ---------------------------------------------------------------------------
install_singbox_unit() {
	log "installing the sing-box systemd unit"
	need_root
	local unit="/etc/systemd/system/sing-box.service"
	if [ "$DRY_RUN" -eq 0 ]; then
		# Mirror the hardened unit conventions in infra/ansible/roles/singbox/templates/singbox.service.j2.
		# The two unit sources are kept in lockstep — especially RestrictAddressFamilies incl. AF_NETLINK
		# — by tests/conformance/unit_netlink_parity.sh; change BOTH together (Audit-0004 F-001/F-017).
		cat >"$unit" <<UNIT
[Unit]
Description=Mycelium sing-box data plane (multi-protocol; PRIMARY engine)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SINGBOX_RUN_USER
Group=$SINGBOX_RUN_GROUP
ExecStartPre=$SINGBOX_BIN check -c $SINGBOX_CONFIG
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONFIG -D $STATE_DIR/run
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=$SINGBOX_ETC
ReadWritePaths=$STATE_DIR/run
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
PrivateDevices=true
DevicePolicy=closed
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RemoveIPC=true
KeyringMode=private
UMask=0077
# AF_NETLINK is REQUIRED: sing-box subscribes to route/interface updates via rtnetlink at startup;
# without it sing-box FATALs ("subscribe route updates: address family not supported by protocol")
# and the service crash-loops. (node_exporter, by contrast, needs no netlink — see its unit below.)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete

[Install]
WantedBy=multi-user.target
UNIT
	fi
	run systemctl daemon-reload
}

restart_singbox() { need_root; run systemctl enable --now sing-box 2>/dev/null || true; run systemctl restart sing-box; }

# apply_singbox — make the running service pick up a new config. sing-box is Type=simple with NO
# ExecReload, so there is no real "reload": applying a config IS a restart (it briefly drops live
# connections). We do not pretend otherwise. Returns the restart's own status so callers can
# distinguish a failed restart from a failed post-check.
apply_singbox()   { need_root; run systemctl enable sing-box 2>/dev/null || true; run systemctl restart sing-box; }

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
			cv6=", ${AWG_PEER_BASE_V6}${n}/128"; client_allowed="0.0.0.0/0, ::/0"; client_dns="1.1.1.1, 2606:4700:4700::1111"
		else
			cv6=""; client_allowed="0.0.0.0/0"; client_dns="1.1.1.1"
		fi
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
setup_amneziawg() {
	[ "$DO_AMNEZIAWG" -eq 1 ] || { log "AmneziaWG step skipped (--no-amneziawg)."; return 0; }
	log "setting up the userspace AmneziaWG path (amneziawg-go)"
	need_root
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
# Tooling install: copy control/ tooling to TOOLING_DIR so myceliumctl is self-locating on-node.
# ---------------------------------------------------------------------------
install_tooling() {
	log "installing control tooling to $TOOLING_DIR"
	need_root
	run install -d -m 0755 "$TOOLING_DIR"
	# Source the control/ tooling from ARTIFACT_ROOT (the real checkout), NOT REPO_ROOT: after the
	# update re-exec REPO_ROOT points at the tmp copy's parent, which has no control/ tree.
	run cp -a "$ARTIFACT_ROOT/control" "$TOOLING_DIR/" 2>/dev/null || run cp -aR "$ARTIFACT_ROOT/control" "$TOOLING_DIR/"
	# Re-point MYCTL at the installed copy if it now exists. Guard the trailing status: a missing
	# installed copy (e.g. under --dry-run, where the cp above is a no-op) must NOT make this function
	# return non-zero and trip `set -e` in the caller — we simply keep the existing MYCTL fallback.
	if [ -x "$TOOLING_DIR/control/myceliumctl" ]; then
		MYCTL="$TOOLING_DIR/control/myceliumctl"
	fi
	return 0
}

# ===========================================================================
# Mode flows.
# ===========================================================================

flow_bootstrap() {
	log "=== bootstrap / converge ==="
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
case "$MODE" in
	bootstrap) flow_bootstrap ;;
	update)    flow_update ;;
	ack)       flow_ack ;;
	*) die "unknown mode: $MODE" ;;
esac
exit 0
