#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# bootstrap.sh — one-command operator entrypoint to bring up a Phase 0 node.
# Author: mindicator & silicon bags quartet.
#
# WHAT IT DOES (the Ansible path)
#   1. Validates prerequisites on the control host (ansible-playbook, ssh; jq for the summary).
#   2. Confirms the operator has prepared the (gitignored) inventory.ini and group_vars/all.yml,
#      and that the fail-closed checksum/host placeholders have actually been filled in.
#   3. Runs:  ansible-playbook -i infra/ansible/inventory.ini infra/ansible/playbook.yml
#      (executed from infra/ansible/ so ansible.cfg, roles_path and group_vars resolve).
#   4. Prints where the client subscriptions and the REALITY public key were fetched.
#
# FAIL-CLOSED: every precondition that is not met aborts with a clear, actionable message and a
# non-zero exit. The script never silently proceeds with placeholder or missing configuration.
#
# WORDING: the node provides a persistent private network; framing is neutral throughout.
#
# USAGE
#   scripts/bootstrap.sh [--yes] [--check] [--tags TAGS] [-- <extra ansible-playbook args>]
#     --yes      non-interactive: do not prompt before applying changes.
#     --check    pass --check --diff to ansible-playbook (dry run; changes nothing).
#     --tags T   limit the playbook to the given role tags (e.g. xray).
#     --         forward any remaining arguments verbatim to ansible-playbook.
#
# MANUAL (NO-ANSIBLE) PATH — documented at the bottom of this file (see "MANUAL PATH").
#
# Exit: 0 = deployment ran (or dry-run) successfully, non-zero = a precondition failed or the
#       playbook failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the repo and the Ansible directory regardless of the caller's CWD.
# ---------------------------------------------------------------------------
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/infra/ansible"
INVENTORY="$ANSIBLE_DIR/inventory.ini"
GROUP_VARS="$ANSIBLE_DIR/group_vars/all.yml"
PLAYBOOK="$ANSIBLE_DIR/playbook.yml"
OUT_SUBS="$ANSIBLE_DIR/out/subscriptions"
OUT_PUBKEY_DIR="$ANSIBLE_DIR/out"

log()  { printf 'bootstrap: %s\n' "$*"; }
warn() { printf 'bootstrap: warning: %s\n' "$*" >&2; }
die()  { printf 'bootstrap: error: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'USAGE'
bootstrap.sh — one-command operator entrypoint to bring up a Mycelium Phase 0 node.

Validates control-host prerequisites and the gitignored inventory.ini / group_vars/all.yml
(fail-closed on placeholders), then runs:
  ansible-playbook -i infra/ansible/inventory.ini infra/ansible/playbook.yml
and prints where the client subscriptions were fetched.

Usage:
  scripts/bootstrap.sh [--yes] [--check] [--tags TAGS] [-- <extra ansible-playbook args>]

  --yes      non-interactive: do not prompt before applying changes.
  --check    pass --check --diff to ansible-playbook (dry run; changes nothing).
  --tags T   limit the playbook to the given role tags (e.g. xray).
  --         forward any remaining arguments verbatim to ansible-playbook.

A MANUAL (no-Ansible) path is documented at the bottom of this script.
USAGE
}

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------
assume_yes=0
do_check=0
tags=""
extra_args=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--yes|-y) assume_yes=1; shift ;;
		--check|--dry-run) do_check=1; shift ;;
		--tags) tags="${2:?--tags needs a value}"; shift 2 ;;
		--) shift; extra_args=("$@"); break ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (run with --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# 1. Prerequisites on the control host (fail-closed).
# ---------------------------------------------------------------------------
log "checking control-host prerequisites"

command -v ansible-playbook >/dev/null 2>&1 \
	|| die "ansible-playbook not found. Install ansible-core (>= 2.15) and the pinned collections:
        ansible-galaxy collection install -r $ANSIBLE_DIR/requirements.yml"

command -v ssh >/dev/null 2>&1 \
	|| die "ssh client not found on PATH (needed to reach the node)."

if ! command -v jq >/dev/null 2>&1; then
	warn "jq not found — deployment will still run, but the post-run subscription summary is reduced."
fi

[ -f "$PLAYBOOK" ] || die "playbook not found: $PLAYBOOK (are you in the right repo?)"

# ---------------------------------------------------------------------------
# 2. Confirm the operator-provided, gitignored config is present and FILLED IN.
# ---------------------------------------------------------------------------
log "verifying operator configuration"

if [ ! -f "$INVENTORY" ]; then
	die "inventory not found: $INVENTORY
        Create it from the example (it is gitignored):
          cp $ANSIBLE_DIR/inventory.ini.example $INVENTORY
          \$EDITOR $INVENTORY    # replace NODE_PUBLIC_IP with the node's real address"
fi
if grep -q 'NODE_PUBLIC_IP' "$INVENTORY"; then
	die "inventory still contains the placeholder NODE_PUBLIC_IP: $INVENTORY
        Replace it with the node's real reachability address before deploying (fail-closed)."
fi

if [ ! -f "$GROUP_VARS" ]; then
	die "group_vars not found: $GROUP_VARS
        Create it from the example (it is gitignored):
          cp $ANSIBLE_DIR/group_vars/all.yml.example $GROUP_VARS
          \$EDITOR $GROUP_VARS   # set donor_host/donor_sni, node_address, client_names, checksums"
fi

# Fail-closed on the deliberately-invalid checksum placeholders (the roles also assert this, but
# we catch it early with a clearer message so a long run does not abort midway).
if grep -q 'REPLACE_WITH_SHA256' "$GROUP_VARS"; then
	die "group_vars still has REPLACE_WITH_SHA256 placeholder(s): $GROUP_VARS
        Record the real upstream SHA256 checksums (pin by version AND hash) before deploying:
          xray:          <release>/Xray-linux-64.zip.dgst
          node_exporter: <release>/sha256sums.txt
        See $ANSIBLE_DIR/README.md §'Record the upstream checksums'."
fi

# Sanity: warn (not fail) on left-over example donor / node placeholders.
for ph in 'donor.example.com' 'NODE_PUBLIC_IP'; do
	if grep -q "$ph" "$GROUP_VARS"; then
		warn "group_vars still references the example value '$ph' — confirm this is intentional."
	fi
done

# ---------------------------------------------------------------------------
# 3. Confirm and run the playbook.
# ---------------------------------------------------------------------------
pb_args=(-i "$INVENTORY" "$PLAYBOOK")
[ -n "$tags" ] && pb_args+=(--tags "$tags")
[ "$do_check" -eq 1 ] && pb_args+=(--check --diff)
[ "${#extra_args[@]}" -gt 0 ] && pb_args+=("${extra_args[@]}")

printf '\n'
log "ready to deploy a Phase 0 node:"
log "  cd $ANSIBLE_DIR && ansible-playbook ${pb_args[*]}"
if [ "$do_check" -eq 1 ]; then
	log "  (dry run: --check --diff — nothing will be changed on the node)"
fi
printf '\n'

if [ "$assume_yes" -ne 1 ] && [ "$do_check" -ne 1 ]; then
	if [ -t 0 ]; then
		printf 'bootstrap: proceed with deployment? [y/N] '
		read -r reply
		case "$reply" in
			y|Y|yes|YES) ;;
			*) die "aborted by operator (no changes made)." ;;
		esac
	else
		die "refusing to deploy non-interactively without --yes (fail-closed). Re-run with --yes."
	fi
fi

log "running ansible-playbook (from $ANSIBLE_DIR)"
# Run from the Ansible dir so ansible.cfg / roles_path / group_vars resolve as designed.
( cd "$ANSIBLE_DIR" && ansible-playbook "${pb_args[@]}" ) \
	|| die "ansible-playbook failed. The deploy is fail-closed: nothing partial is served to
        clients without a valid config. Review the output above, fix, and re-run."

# ---------------------------------------------------------------------------
# 4. Report where the client subscriptions were fetched.
# ---------------------------------------------------------------------------
printf '\n'
if [ "$do_check" -eq 1 ]; then
	log "dry run complete — no artefacts were fetched (re-run without --check to deploy)."
	exit 0
fi

log "deployment complete. Fetched operator artefacts (gitignored):"

if [ -d "$OUT_SUBS" ]; then
	log "  client subscriptions: $OUT_SUBS/<host>/<client>.txt"
	# List what is actually present, per host.
	found=0
	while IFS= read -r -d '' sub; do
		log "    - ${sub#"$REPO_ROOT"/}"
		found=1
	done < <(find "$OUT_SUBS" -type f -name '*.txt' -print0 2>/dev/null)
	[ "$found" -eq 1 ] || warn "no subscription files found under $OUT_SUBS yet — check the playbook output."
else
	warn "subscriptions directory not found: $OUT_SUBS
        Expected the xray role to fetch them here. Review the playbook output above."
fi

if ls "$OUT_PUBKEY_DIR"/*reality_public_key.txt >/dev/null 2>&1; then
	for pk in "$OUT_PUBKEY_DIR"/*reality_public_key.txt; do
		log "  REALITY public key:   ${pk#"$REPO_ROOT"/}"
	done
else
	warn "REALITY public key file not found under $OUT_PUBKEY_DIR."
fi

printf '\n'
log "Hand each client their subscription over a channel reachable from a heavily restricted"
log "network. The REALITY private key and client UUIDs remain ONLY on the node (root 0600)."
exit 0

# ===========================================================================
# MANUAL PATH (no Ansible) — for a single node configured by hand.
# ===========================================================================
# If you cannot run Ansible, provision the node manually. All crypto comes from audited tools
# (xray / openssl) — never hand-rolled (ADR-0002). On a fresh Debian/Ubuntu VPS:
#
#   1. Install a PINNED, checksum-verified Xray-core (>= v26.2.4) to /usr/local/bin/xray.
#      Verify the SHA256 against the upstream release manifest BEFORE installing (fail-closed).
#
#   2. Generate identity material ON the node (these are the ONLY sanctioned generators):
#        xray x25519                 # REALITY private/public keypair
#        xray uuid                   # one UUID per client
#        openssl rand -hex 8         # one or more REALITY shortIds
#      The private key and UUIDs NEVER leave the node.
#
#   3. Render the server config from the repo template using the control tooling:
#        control/myceliumctl reality-keys --shortids 3      # or reuse step 2's values
#        control/myceliumctl identity add --name alice
#        control/myceliumctl render-server \
#          --template nodes/dataplane/vless-reality/server.template.json \
#          --params control/params.example.json \
#          --out /usr/local/etc/xray/config.json
#      (See control/README.md for the params schema. Outputs land in gitignored paths.)
#
#   4. Validate and run:
#        xray run -test -config /usr/local/etc/xray/config.json
#        systemctl enable --now xray        # using the unit from infra/ansible/roles/xray
#
#   5. Stand up the cover so active probing receives a genuine donor response. In production the
#      data plane owns :443 and REALITY's "dest" forwards probes to a real EXTERNAL donor; the
#      Caddy site in nodes/cover/ is an optional self-hosted donor target (see nodes/cover/README).
#
#   6. Emit per-client subscriptions and distribute ONLY those + the REALITY PUBLIC key:
#        control/myceliumctl subscription \
#          --params control/params.example.json --out ./out
#
#   7. Verify the node answers an active probe as the donor (requires the live node):
#        tests/conformance/cover_site_probe.sh --node <NODE> --donor <DONOR>
#
# Either path yields the same result: standard VLESS+REALITY endpoints consumed by off-the-shelf
# clients (sing-box, Clash-Meta), with no secrets committed to the repository.
