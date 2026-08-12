#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# revoke_guarantee_is_earned.sh — conformance: `--revoke` never claims a person was removed from a family
# it cannot remove them from.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Measured on a live node (Audit-0012): two clients' emitted subscriptions are BYTE-IDENTICAL on
#   hysteria2, shadowsocks and shadowtls. Those families — and trojan — build their user list as
#   `(.password // $pw)` in control/lib/render_singbox.sh, where `$pw` is ONE node-wide secret. TUIC does
#   not: it uses `(.password // .id)`, falling back to that client's own UUID, and the vless families key
#   on the UUID directly.
#
#   So dropping a UUID retires a person on some families and not others — and `flow_revoke` logged
#   "the client's UUID is gone from every inbound on BOTH engines". Literally true. Read as "this person
#   no longer has access." That is development.md §2.2 item 12: a conclusion the evidence does not carry,
#   printed as a result. The AmneziaWG half of the same verb already refuses to do this — its header
#   reads "THE GUARANTEE IS EARNED, NOT PRINTED" — and this gate holds the sing-box half to it.
#
#   ADR-0040 §2.1 decides the real fix (per-person credentials). Until that RP lands, the honest
#   behaviour is a refusal, and this gate is what keeps the refusal from quietly disappearing.
#
# WHAT IT CHECKS, by DRIVING the shipped predicate against the shipped registry
#   1. The registry DECLARES which families share a node-wide secret, and declares exactly the four the
#      renderer builds that way — not three, not five, and not tuic.
#   2. The predicate flow_revoke uses names only families that are BOTH shared-secret AND served. A node
#      serving only UUID-keyed families gets the clean guarantee; that is the default profile, and a gate
#      that failed it would be refusing on a node with nothing to refuse about.
#   3. The refusal exists in flow_revoke, is fail-closed (non-zero), names the families and the person,
#      and drops a REVOKE_INCOMPLETE marker — the same evidence trail awg-revoke leaves.
#   4. No document still claims revocation removes a person outright.
#
# OFFLINE. No root, no network, no node. Exit: 0 = the guarantee is earned; 1 = it is printed.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'revoke_guarantee_is_earned: cannot resolve repo root\n' >&2; exit 2; }
VOCAB="$REPO_ROOT/control/vocab.json"
ENTRY="$REPO_ROOT/scripts/node-bootstrap.sh"
RENDER="$REPO_ROOT/control/lib/render_singbox.sh"
for f in "$VOCAB" "$ENTRY" "$RENDER"; do
	[ -f "$f" ] || { printf 'revoke_guarantee_is_earned: missing %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf '  SKIP  jq unavailable; the predicate cannot be driven.\nPASS (skipped)\n'; exit 0; }

fail=0
ok()    { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== a revoke that cannot remove someone does not say it did ==\n\n'

# ---------------------------------------------------------------------------------------------------
# 1. THE REGISTRY DECLARES IT, and declares the set the renderer actually builds that way.
#
# Derived from the renderer rather than restated: a family whose users line contains `// $pw` shares a
# node-wide secret; one with `// .id` does not. If someone changes the renderer, this row moves with it.
# ---------------------------------------------------------------------------------------------------
declared="$(jq -r '[.protos[] | select(.shared_secret_auth == true) | .proto] | sort | join(" ")' "$VOCAB")"
[ -n "$declared" ] \
	&& ok "the registry declares the shared-secret families: $declared" \
	|| badln "no proto carries shared_secret_auth. The predicate flow_revoke uses reads this field; with none set it never refuses, and the guarantee is printed again on every node."

renderer_shared=""
for p in hysteria2 shadowsocks shadowtls trojan tuic; do
	var="$(printf '%s' "$p" | sed 's/shadowsocks/ss/; s/shadowtls/shadowtls/')"
	if grep -qE "users_[a-z0-9]+=.*--arg pw \"\\\$${var}_password\"" "$RENDER" 2>/dev/null; then
		renderer_shared="$renderer_shared $p"
	fi
done
renderer_shared="$(printf '%s' "$renderer_shared" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$renderer_shared" ]; then
	printf '  SKIP  could not derive the shared-secret set from the renderer (its user-list shape changed); the declaration is unchecked against it.\n'
elif [ "$renderer_shared" = "$declared" ]; then
	ok "and that is exactly the set the renderer builds with a node-wide \$pw"
else
	badln "the registry declares '$declared' but the renderer builds '$renderer_shared' with a node-wide secret. One of them is wrong, and whichever it is, --revoke is refusing about the wrong families — either refusing where it need not, or printing the guarantee where it must not."
fi

printf '%s' "$declared" | grep -qw tuic \
	&& badln "tuic is declared shared-secret, but its renderer line is \`(.password // .id)\` — it falls back to the client's OWN UUID, so revoking the UUID does retire that person. Refusing on tuic would make the refusal wrong and train operators to ignore it." \
	|| ok "and tuic is NOT in it — its password falls back to the client's own UUID"

# ---------------------------------------------------------------------------------------------------
# 2. THE PREDICATE. Driven with the same jq flow_revoke runs, against the shipped registry.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the predicate names served shared-secret families, and only those --\n'
W="$(mktemp -d "${TMPDIR:-/tmp}/myc.rev.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

predicate() { # predicate <params.json> -> the space-joined proto list
	jq -r --slurpfile p "$1" \
		'[.protos[] | select(.shared_secret_auth == true)
		   | select(.enable_key != "" and ($p[0][.enable_key] == true))
		   | .proto] | join(" ")' "$VOCAB" 2>/dev/null
}

# The default profile: REALITY only. Nothing to refuse about, and a gate that refused here would be
# blocking the one profile the project ships by default.
jq -n '{"vless_reality_vision_enabled": true, "vless_reality_grpc_enabled": true}' >"$W/default.json"
got="$(predicate "$W/default.json")"
[ -z "$got" ] \
	&& ok "the default profile (REALITY only) is clean — the guarantee is printed, correctly" \
	|| badln "the default profile was flagged as shared-secret ('$got'). Refusing there is a false alarm on the profile every node ships with, and a refusal that is usually wrong is one operators learn to ignore."

# One shared-secret family on.
first="$(printf '%s' "$declared" | awk '{print $1}')"
fkey="$(jq -r --arg p "$first" '.protos[] | select(.proto == $p) | .enable_key' "$VOCAB")"
jq -n --arg k "$fkey" '{($k): true, "vless_reality_vision_enabled": true}' >"$W/one.json"
got="$(predicate "$W/one.json")"
[ "$got" = "$first" ] \
	&& ok "serving $first alone names exactly it" \
	|| badln "with only $first enabled the predicate returned '$got'. If it is empty the refusal never fires and the guarantee is printed for a person who still has access."

# Enabled-vs-served: a shared-secret family present in the registry but DISABLED must not be named.
jq -n --arg k "$fkey" '{($k): false, "vless_reality_vision_enabled": true}' >"$W/off.json"
got="$(predicate "$W/off.json")"
[ -z "$got" ] \
	&& ok "and a shared-secret family that is NOT served is not named" \
	|| badln "a disabled family ('$got') was named. The refusal must be about what this node serves, not about what the registry knows."

# ---------------------------------------------------------------------------------------------------
# 3. THE REFUSAL ITSELF — present, fail-closed, and leaving the same evidence awg-revoke leaves.
# ---------------------------------------------------------------------------------------------------
printf '\n-- the refusal is fail-closed and says what is true --\n'
body="$(sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' "$ENTRY")"
flow="$(printf '%s' "$body" | awk '/^flow_revoke\(\)/,/^}/')"

printf '%s' "$flow" | grep -q 'shared_secret_auth' \
	&& ok "flow_revoke reads the Go-owned registry rather than restating the family list (ADR-0038)" \
	|| badln "flow_revoke no longer reads .protos[].shared_secret_auth. A hand-kept list here drifts from the renderer the moment a family is added — which is exactly how this defect stayed invisible."
printf '%s' "$flow" | grep -qE 'return 1' \
	&& ok "and exits non-zero when it cannot make the claim" \
	|| badln "flow_revoke has no non-zero exit on the shared-secret path. An operator scripting a revoke would read success."
printf '%s' "$flow" | grep -q 'REVOKE_INCOMPLETE' \
	&& ok "and leaves a REVOKE_INCOMPLETE marker, the same evidence trail awg-revoke leaves" \
	|| badln "no REVOKE_INCOMPLETE marker is written. The warning scrolls past; the marker is what is still there tomorrow."
printf '%s' "$flow" | grep -q 'STILL ADMITTED' \
	&& ok "and names the person as still admitted, not merely 'partially revoked'" \
	|| badln "the refusal does not say the person is still admitted. 'Partial' is read as 'mostly done'; the operator needs the fact that this human still has access."

# ---------------------------------------------------------------------------------------------------
# 4. NO DOCUMENT STILL CLAIMS OTHERWISE. The sentence is the defect; a gate that only fixed the code
#    would leave four documents teaching the opposite.
# ---------------------------------------------------------------------------------------------------
printf '\n-- and nothing in the tree still promises a clean revoke --\n'
if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	printf '  SKIP  not a git checkout; the document sweep did not run.\n'
else
	# SENTENCE-AWARE, the shape no_operated_network_claim.sh already uses here. A correction has to be
	# able to QUOTE the sentence it is correcting — "this page previously said X, which was true of the
	# UUID and false of the person" is the most useful form of the fix, and a bare grep flags it as the
	# defect it is removing. So: flag the phrase only when its sentence carries no retraction marker.
	hits="$(git -C "$REPO_ROOT" grep -hniE 'no longer accepts that identity|revocation without redeploying' -- '*.md' 2>/dev/null \
		| grep -viE 'previously said|used to say|was true of|rescored|no longer true|Audit-0012|ADR-0040' \
		| head -5)"
	hits="$(git -C "$REPO_ROOT" grep -lniE 'no longer accepts that identity|revocation without redeploying' -- '*.md' 2>/dev/null \
		| while IFS= read -r f; do
			grep -iE 'no longer accepts that identity|revocation without redeploying' "$REPO_ROOT/$f" \
				| grep -qviE 'previously said|used to say|was true of|rescored|no longer true|Audit-0012|ADR-0040' && printf '%s\n' "$f"
		  done | head -5)"
	if [ -z "$hits" ]; then
		ok "no document claims the node stops accepting a revoked identity outright"
	else
		badln "these still promise a clean revoke: $(printf '%s' "$hits" | tr '\n' ' '). The code refusing while the documents promise is worse than either alone — the operator trusts the document and reads the refusal as a bug."
	fi
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: revoke can still claim a removal it has not made.\n' >&2
	exit 1
fi
printf 'PASS: the guarantee is earned — refused where it cannot be established, printed where it can.\n'
exit 0
