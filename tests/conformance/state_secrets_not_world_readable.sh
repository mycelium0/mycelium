#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# state_secrets_not_world_readable.sh — conformance: nothing write_params leaves in the state dir is
# readable by a co-resident unprivileged account, and a run that dies mid-way does not leave a copy of
# every secret behind. EXECUTED against a throwaway node root.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE
#   Found on ALL THREE live nodes, dated 26-27 July and still present weeks later: a
#   `/var/lib/mycelium/.params.XXXXXX` file, mode 0644, containing a complete params set — the REALITY
#   private key, every transport password, every client UUID. `node_exporter` is a real unprivileged
#   local account on those hosts, so it was readable by a principal that should never see any of it.
#
#   Two independent mistakes had to line up, which is why nothing caught it:
#     * `mktemp` creates 0600, but write_params hands the temp to helpers that rewrite it as
#       `jq ... > "$tmp.np"` followed by `mv -f`. A SHELL REDIRECTION creates its file under the
#       umask — 0644 on these hosts — and the `mv` replaces the inode, so mktemp's 0600 is gone after
#       the first rewrite. The mode of the finished params.json was always right (`chmod 0600` at the
#       end), so every check anyone thought to run looked fine.
#     * write_params has no trap, and three of those helpers `die` on malformed input. A death between
#       mktemp and the final `mv` abandons the temp — at 0644 — forever, because nothing sweeps it.
#
#   The finished file being correct is exactly what made this invisible. So this gate does not look at
#   params.json; it looks at what is left AROUND it, and at the mode of every intermediate.
#
# WHAT IT CHECKS, by running the real write_params over tests/lab/fakenode.sh
#   1. A normal run leaves NO `.params.*` temp behind, and params.json is 0600.
#   2. Nothing write_params writes into the state dir is group- or world-readable.
#   3. A run that DIES mid-way leaves nothing world-readable — the abandoned temp, if any, is 0600.
#   4. The NEXT run sweeps whatever the dead one left, so a leftover cannot outlive one converge
#      (15 minutes on an armed node) even if it escapes 1-3.
#
# OFFLINE. No root. Nothing outside its own mktemp root (fakenode_init refuses otherwise).
# Exit: 0 = no secret is exposed, 1 = a violation, 2 = usage/env error.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'state_secrets_not_world_readable: cannot resolve repo root\n' >&2; exit 2; }
LIB="$REPO_ROOT/control/lib/nb_render_params.sh"
FIXTURE="$REPO_ROOT/tests/lab/fakenode.sh"
for f in "$LIB" "$FIXTURE"; do
	[ -f "$f" ] || { printf 'state_secrets_not_world_readable: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf '  skip  jq is required to run write_params\n'; exit 0; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== state-dir secrets: nothing left world-readable, nothing left behind ==\n'

# shellcheck source=/dev/null
. "$FIXTURE" || { printf 'FAIL: could not source the fakenode fixture\n' >&2; exit 2; }

# GNU FIRST, and the order is load-bearing: on GNU coreutils `stat -f` means "file SYSTEM status" and
# SUCCEEDS, printing block counts, so a `stat -f %Lp || stat -c %a` chain never reaches the fallback and
# returns a paragraph of filesystem stats where a mode should be. `stat -c` is simply rejected by BSD
# stat, so trying it first degrades correctly on both.
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
# Every regular file under the state dir whose mode grants group or other ANY bit.
loose_files() {
	find "$STATE_DIR" -type f 2>/dev/null | while IFS= read -r f; do
		m="$(mode_of "$f")"; [ -n "$m" ] || continue
		case "$m" in
			*[1-7][1-7]|*[1-7]0|*0[1-7]) printf '%s(%s) ' "$(basename "$f")" "$m" ;;
		esac
	done
}

seed_identity() {
	mkdir -p "$FAKENODE_ROOT/tls"
	TLS_DIR="$FAKENODE_ROOT/tls"
	IDENTITY_SECRETS="$STATE_DIR/identity.secrets"
	NODE_ADDRESS="203.0.113.9"
	NODE_ADDRESS_PLACEHOLDER="node.example.invalid"
	MYC_VOCAB="$REPO_ROOT/control/vocab.json"
	cat >"$IDENTITY_SECRETS" <<-EOF
		REALITY_PRIVATE_KEY=SECRET-reality-private
		REALITY_PUBLIC_KEY=pub
		REALITY_SHORT_ID=ccdd
		DONOR_SNI=www.apple.com
		SS_PASSWORD=SECRET-ss
		TROJAN_PASSWORD=SECRET-tj
		HYSTERIA2_PASSWORD=SECRET-hy
		SHADOWTLS_PASSWORD=SECRET-st
		CLASH_SECRET=SECRET-clash
	EOF
	chmod 0600 "$IDENTITY_SECRETS"
}

# --- 1/2. the ordinary run --------------------------------------------------------------------------
( set -u
  fail=0
  fakenode_init
  seed_identity
  # shellcheck source=/dev/null
  . "$LIB"
  write_params >/dev/null 2>&1 || { badln "write_params failed in the fixture — the rows below would prove nothing"; exit "$fail"; }

  leftovers="$(ls "$STATE_DIR"/.params.* 2>/dev/null | tr '\n' ' ')"
  [ -z "$leftovers" ] \
	  && ok "normal run: no .params.* temp is left in the state dir" \
	  || badln "normal run left a temp behind: $leftovers — it holds the REALITY private key and every transport password"

  m="$(mode_of "$PARAMS_JSON")"
  [ "$m" = "600" ] \
	  && ok "params.json is 0600" \
	  || badln "params.json is $m, expected 600"

  loose="$(loose_files)"
  [ -z "$loose" ] \
	  && ok "no file write_params leaves in the state dir is group- or world-readable" \
	  || badln "group/world-readable file(s) in the state dir: $loose — a co-resident unprivileged account (node_exporter runs as one on every live node) can read these"
  exit "$fail"
) || fail=1

# --- 3. THE MODE OF EVERY INTERMEDIATE, observed while the run is happening -------------------------
#
# The finished params.json is chmod'ed 0600 at the end, so looking at the result proves nothing about the
# temps — which is precisely why the live 0644 leftover went unseen for weeks. So watch the renames: a
# stub `mv` records the mode of each `.params.*` source before handing it to the real tool. Those are the
# files a dead run abandons, and their mode is the mode it abandons them at.
( set -u
  fail=0
  fakenode_init
  seed_identity
  # A node descriptor, so apply_node_profile actually REWRITES the temp. Without one it returns early,
  # only the original mktemp'd file (still 0600) reaches a rename, and this row silently tests nothing —
  # it passed against a build with the umask removed until this line existed.
  ( umask 077; printf '{"transports":["vless-reality-vision"],"reachable":true}\n' >"$STATE_DIR/node.config.json" )
  cat >"$STUBDIR/mv" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
	case "$a" in
		*/.params.*) [ -f "$a" ] && printf '%s\n' "$(stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a" 2>/dev/null)" >>"${FAKENODE_ROOT:?}/modes.log" ;;
	esac
done
exec /bin/mv "$@"
STUB
  chmod +x "$STUBDIR/mv"
  # shellcheck source=/dev/null
  . "$LIB"
  write_params >/dev/null 2>&1 || true
  modes="$(sort -u "$FAKENODE_ROOT/modes.log" 2>/dev/null | tr '\n' ' ')"
  if [ -z "$modes" ]; then
	  badln "no .params.* intermediate was observed at all — the run did not reach the temp, so this row proves nothing; re-confirm the gate"
  else
	  bad=""
	  for m in $modes; do case "$m" in 600|0600) ;; *) bad="$bad $m" ;; esac; done
	  [ -z "$bad" ] \
		  && ok "every .params.* intermediate is 0600 while it exists (observed modes: $modes)" \
		  || badln "an intermediate params file exists at mode(s):$bad. mktemp makes it 0600, but a helper that rewrites it as \`jq ... > \"\$tmp.np\"\` + \`mv -f\` replaces the inode with one created under the UMASK. If the run then dies, that is the mode the abandoned copy of every node secret keeps — which is exactly what was found, at 0644, on all three live nodes. Set umask 077 for the body of write_params."
  fi
  exit "$fail"
) || fail=1

# --- 4. A STALE TEMP MUST NOT SURVIVE THE NEXT RUN ---------------------------------------------------
# Planted rather than provoked: what matters is that a leftover from ANY cause cannot outlive one
# converge, and a planted file tests that without depending on which helper happened to die.
( set -u
  fail=0
  fakenode_init
  seed_identity
  printf '{"reality_private_key":"SECRET-from-a-dead-run"}\n' >"$STATE_DIR/.params.stale00"
  chmod 0644 "$STATE_DIR/.params.stale00"
  # shellcheck source=/dev/null
  . "$LIB"
  write_params >/dev/null 2>&1 || true
  if [ -e "$STATE_DIR/.params.stale00" ]; then
	  badln "a stale .params.* left by an earlier dead run SURVIVED a successful write_params (mode $(mode_of "$STATE_DIR/.params.stale00")). With no trap and no sweep, an abandoned copy of every node secret lives until a human notices — on the live nodes that took several weeks. Sweep \$STATE_DIR/.params.* at the top of write_params."
  else
	  ok "a stale .params.* from an earlier run is swept (a leftover cannot outlive one converge)"
  fi
  exit "$fail"
) || fail=1

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: write_params can leave a readable copy of every node secret in the state dir.\n' >&2
	exit 1
fi
printf 'PASS: no state-dir secret is group/world-readable, and no abandoned params copy survives a converge.\n'
exit 0
