#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# release_runbook_executes.sh — conformance: the release runbook's commands can actually run, and the
# key file it tells you to create is one the verifier can use.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Audit-0012 measured three separate ways the release lane cannot be executed as written, and all
#   three sit on the steps added to close Audit-0011 #15 — *the signed bytes are the published bytes*.
#   The lane has never run, so every step in it was a hypothesis:
#
#     B3  Steps 4-7 `cd /tmp/rel` and never return. From there `gh release download` fails with
#         "failed to run git: fatal: not a git repository" and never reaches GitHub, because no --repo
#         is passed. `gh release upload` the same. The verifier is invoked by a relative path that no
#         longer resolves.
#     B4  The command that CREATES allowed_signers used `git log -1 --format=%GS` for the principal.
#         %GS prints a principal only once an allowed_signers already exists containing that key — so
#         the command written to create the file required the file. Reproduced from an empty repository:
#         the line came out with a leading space and no principal, `awk 'NF{print $1; exit}'` yielded
#         `ssh-ed25519` (the key TYPE), and the commit verified as `U`.
#     B5  `verify-release.sh` cd's into the directory it is checking BEFORE testing --allowed-signers,
#         so a relative key path — the shape both documents prescribe — resolved against the wrong
#         directory and was "not found". The obvious recovery is to drop the flag, which falls back to
#         integrity-only: the one mode this project says cannot tell a substituted release from a
#         genuine one. The failure pushed the user toward the weaker check.
#
# WHAT IT CHECKS, by RUNNING the shapes rather than reading them
#   1. Every `gh` call in the runbook carries --repo, and the steps that leave the repository use
#      absolute paths.
#   2. The allowed_signers recipe, executed verbatim in a throwaway repo with a real signed commit,
#      produces a file whose first field is a principal (not a key type) and against which the commit
#      verifies as `G`.
#   3. verify-release.sh accepts a RELATIVE --allowed-signers from a caller whose cwd is not $DIR.
#
# OFFLINE except for git/ssh-keygen, which are local. No network, no node.
# Exit: 0 = the runbook runs; 1 = a step in it cannot.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'release_runbook_executes: cannot resolve repo root\n' >&2; exit 2; }
RUNBOOK="$REPO_ROOT/docs/RELEASING.md"
VERIFY="$REPO_ROOT/scripts/verify-release.sh"
for f in "$RUNBOOK" "$VERIFY"; do
	[ -f "$f" ] || { printf 'release_runbook_executes: missing %s\n' "$f" >&2; exit 2; }
done

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== the release runbook can be executed as written ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1. `gh` OUTSIDE THE REPOSITORY. Every gh call must name the repo; gh resolves it from git otherwise,
#    and steps 4-7 deliberately work from a download directory.
# ---------------------------------------------------------------------------------------------------
printf -- '-- every gh call names its repo --\n'
naked="$(grep -nE '^[^#]*\bgh (release|api|pr) ' "$RUNBOOK" | grep -v -- '--repo' | head -5)"
if [ -z "$naked" ]; then
	ok "every gh invocation in the runbook passes --repo"
else
	badln "these gh calls have no --repo: $(printf '%s' "$naked" | tr '\n' '|' | cut -c1-200). Run from the download directory — which is where the runbook puts you — gh cannot resolve the repository from git and fails before it reaches GitHub. Measured: 'failed to run git: fatal: not a git repository', rc=1."
fi

# The steps that leave the repo must not depend on relative paths back into it. $OLDPWD is one `cd`
# away from being wrong; a named variable is not.
if grep -qE '\$OLDPWD/dist' "$RUNBOOK"; then
	badln "the runbook still reaches back into the checkout via \$OLDPWD. That survives exactly one cd; a second one silently compares the wrong file, and step 5 is the byte-equality check the whole reorder exists for."
else
	ok "and the byte-equality step reaches the checkout by an explicit path, not \$OLDPWD"
fi

# ---------------------------------------------------------------------------------------------------
# 2. THE KEY RECIPE, EXECUTED. This is the command that closes the project's only deferred blocker.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the allowed_signers recipe produces a file that works --\n'
if ! command -v git >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
	printf '  SKIP  git or ssh-keygen unavailable; the recipe was not executed.\n'
else
	# The line that creates allowed_signers, and the principal it uses. Extracted with awk on a fixed
	# delimiter rather than a regex full of escaped quotes — the first draft of this row was a nest of
	# backslashes that would not even parse.
	recipe="$(grep -F 'allowed_signers' "$RUNBOOK" | grep -F 'printf' | head -1)"
	principal="$(printf '%s' "$recipe" | tr '\042' '\n' | sed -n 2p)"
	case "$principal" in
		*'git log'*|*'%GS'*)
			badln "the recipe still derives the principal from git (%GS). Measured from an empty repository: %GS is EMPTY until an allowed_signers already contains that key, so the command written to create the file requires the file. The result has a leading space, no principal, and the commit verifies as U." ;;
		"")
			badln "could not find the allowed_signers recipe in $RUNBOOK — if it was reworded, this row is testing nothing and must be updated with it." ;;
		*)
			ok "the principal is a literal ('$principal'), not derived from a file that does not exist yet"

			# Now RUN it. A recipe that reads correctly and produces an unusable file is the defect.
			W="$(mktemp -d "${TMPDIR:-/tmp}/myc.rb.XXXXXX")" || exit 2
			(
				cd "$W" || exit 2
				git init -q -b main >/dev/null 2>&1
				git config user.email t@invalid; git config user.name t
				ssh-keygen -q -t ed25519 -N '' -f k >/dev/null 2>&1
				git config gpg.format ssh
				git config user.signingkey "$W/k.pub"
				git config commit.gpgsign true
				echo x > f && git add f && git commit -q -m t >/dev/null 2>&1
				printf '%s %s\n' "$principal" "$(cut -d' ' -f1,2 k.pub)" > allowed_signers
				printf '%s|%s\n' \
					"$(awk 'NF{print $1; exit}' allowed_signers)" \
					"$(git -c gpg.ssh.allowedSignersFile=allowed_signers log -1 --format=%G? 2>/dev/null)" \
					> result
			) >/dev/null 2>&1
			res="$(cat "$W/result" 2>/dev/null)"
			rm -rf "$W"
			got_principal="${res%%|*}"; got_verify="${res##*|}"
			[ "$got_principal" = "$principal" ] \
				&& ok "and \`awk 'NF{print \$1; exit}'\` — what the runbook feeds --signer — yields that principal" \
				|| badln "the recipe's file gives --signer '$got_principal' instead of '$principal'. If it is a key type, this is B4 returning: the principal field is empty and awk reads the next token."
			[ "$got_verify" = "G" ] \
				&& ok "and a real signed commit verifies against the file as G" \
				|| badln "a commit signed by that key verifies as '${got_verify:-?}', not G. The file does not authenticate anything, and release.yml refuses to publish without one that does."
			;;
	esac
fi

# ---------------------------------------------------------------------------------------------------
# 3. A RELATIVE KEY PATH, from a cwd that is not $DIR — the shape both documents prescribe.
# ---------------------------------------------------------------------------------------------------
printf '\n-- verify-release accepts the key path the documents tell you to pass --\n'
if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v shasum >/dev/null 2>&1; then
	printf '  SKIP  ssh-keygen or shasum unavailable; the verifier was not driven.\n'
else
	W="$(mktemp -d "${TMPDIR:-/tmp}/myc.vr.XXXXXX")" || exit 2
	out="$(
		cd "$W" || exit 2
		mkdir -p rel && printf 'x\n' > rel/f
		( cd rel && shasum -a 256 f > SHA256SUMS )
		ssh-keygen -q -t ed25519 -N '' -f k >/dev/null 2>&1
		printf 'me@invalid %s\n' "$(cut -d' ' -f1,2 k.pub)" > allowed_signers
		( cd rel && ssh-keygen -Y sign -q -f ../k -n file SHA256SUMS >/dev/null 2>&1 )
		# DIR is rel; the key path is RELATIVE and lives in the cwd of the CALLER, not in DIR.
		bash "$VERIFY" rel --allowed-signers allowed_signers --signer me@invalid 2>&1 | tail -1
	)"
	rm -rf "$W"
	case "$out" in
		*"OK — integrity AND authenticity verified"*)
			ok "a relative --allowed-signers from outside \$DIR resolves and authenticity is verified" ;;
		*"--allowed-signers file not found"*)
			badln "a relative key path is still resolved against \$DIR: '$out'. That is the shape docs/RELEASING.md step 7 and QUICKSTART step 1 both prescribe, so a maintainer or downloader who did everything right is told the file is missing — and the obvious recovery is to drop the flag and fall back to integrity-only, the one mode that cannot distinguish a substituted release." ;;
		*)
			badln "the verifier neither verified nor reported a missing key: '$out'. Whatever it did, the documented shape does not work." ;;
	esac
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: a step in the release runbook cannot be executed as written.\n' >&2
	exit 1
fi
printf 'PASS: the runbook runs, the key recipe produces a usable file, and the documented verify shape works.\n'
exit 0
