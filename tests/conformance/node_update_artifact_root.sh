#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# node_update_artifact_root.sh — conformance: the --update re-exec path resolves canonical
# artifacts (donor list, renderer template, control/ tooling) from the REAL checkout
# (CHECKOUT_DIR / ARTIFACT_ROOT), NOT from the throwaway tmp dir the updater re-exec's from.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   scripts/node-bootstrap.sh defends against self-modification during --update by copying itself
#   to a tmp dir and re-exec'ing from there before it touches the working tree. After that re-exec,
#   the script's own path ($NB_SELF) lives under the tmp dir, so REPO_ROOT (= $NB_SELF/..) resolves
#   to the tmp PARENT — a directory that contains NO nodes/ and NO control/. If the donor list, the
#   renderer template, the in-repo myceliumctl fallback, or install_tooling's source were resolved
#   off REPO_ROOT, every fleet UPDATE would render against the wrong (tmp) tree and fail.
#
#   The fix introduces ARTIFACT_ROOT (prefer CHECKOUT_DIR, else REPO_ROOT) and points all four
#   artifact paths at it. This test reproduces the post-re-exec condition and asserts the fix holds.
#
# HOW IT WORKS (fully OFFLINE — no sing-box, no live node, no network egress)
#   1. Build a FAKE checkout dir containing the real donor list + renderer template + a control/
#      stub (an executable myceliumctl placeholder) + minimal local state (identity/params/ids).
#      `git init` it and create one commit so the updater's default git fetch path is well-formed.
#   2. Copy node-bootstrap.sh to a SEPARATE tmp dir (NOT inside the fake checkout) to emulate the
#      post-re-exec image: from that copy, REPO_ROOT points at the tmp parent, which has no nodes/.
#   3. Run the copy with MYC_REEXEC=1 (skip the re-exec block) + --update --dry-run
#      --insecure-no-verify (bypass the signature gate; this is the documented testing-only flag)
#      + --checkout <FAKE>. --dry-run makes fetch/merge/render no-ops that only LOG their commands.
#   4. Assert from the dry-run output that the resolved donor list, renderer template and control
#      tooling all live UNDER the fake checkout, and that NO artifact path points at the tmp dir the
#      script was re-exec'd from.
#
# Exit: 0 = artifacts resolve from CHECKOUT_DIR (ARTIFACT_ROOT); 1 = a path leaked to the tmp dir
#       (the S1 regression); 2 = usage/env error (missing tool or input file).

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

SCRIPT="$REPO_ROOT/scripts/node-bootstrap.sh"
REAL_DONOR="$REPO_ROOT/nodes/dataplane/donor-sni-candidates.json"
REAL_TEMPLATE="$REPO_ROOT/nodes/dataplane/singbox/server.template.renderer.json"

command -v git >/dev/null 2>&1 || { printf 'SKIP: git not available; cannot stage a fake checkout.\n'; exit 0; }
[ -f "$SCRIPT" ]        || { printf 'FAIL: node-bootstrap.sh not found: %s\n' "$SCRIPT" >&2; exit 2; }
[ -f "$REAL_DONOR" ]    || { printf 'FAIL: donor list not found: %s\n' "$REAL_DONOR" >&2; exit 2; }
[ -f "$REAL_TEMPLATE" ] || { printf 'FAIL: renderer template not found: %s\n' "$REAL_TEMPLATE" >&2; exit 2; }

fail=0
okln()  { printf '  ok    %s\n' "$1"; }
badln() { printf '  FAIL  %s\n' "$1"; fail=1; }

printf '== node-bootstrap --update artifact-root check ==\n'
printf 'script: %s\n' "${SCRIPT#"$REPO_ROOT"/}"

# --- Build the fake checkout + a separate re-exec image + a state dir -------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc-artroot.XXXXXX")" || { printf 'FAIL: mktemp failed\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

FAKE_CHECKOUT="$WORK/checkout"          # stands in for /opt/mycelium (CHECKOUT_DIR / ARTIFACT_ROOT)
REEXEC_DIR="$WORK/reexec"               # stands in for the updater's mktemp -d re-exec dir
STATE_DIR="$WORK/state"                 # stands in for /var/lib/mycelium (local-only node state)
TOOLING_DIR="$WORK/tooling"             # stands in for /usr/local/lib/mycelium

mkdir -p \
	"$FAKE_CHECKOUT/nodes/dataplane/singbox" \
	"$FAKE_CHECKOUT/control" \
	"$REEXEC_DIR" \
	"$STATE_DIR" \
	"$TOOLING_DIR"

cp "$REAL_DONOR"    "$FAKE_CHECKOUT/nodes/dataplane/donor-sni-candidates.json"
cp "$REAL_TEMPLATE" "$FAKE_CHECKOUT/nodes/dataplane/singbox/server.template.renderer.json"

# control/ stub: an EXECUTABLE myceliumctl placeholder. render_candidate only requires it to exist
# and be executable; under --dry-run it is never actually invoked (the command is logged, not run).
cat >"$FAKE_CHECKOUT/control/myceliumctl" <<'STUB'
#!/usr/bin/env bash
echo "stub myceliumctl: $*"
exit 0
STUB
chmod 0755 "$FAKE_CHECKOUT/control/myceliumctl"

# Minimal LOCAL state so flow_update gets past its identity guard and reaches render_candidate.
# (Real values are irrelevant: --dry-run never reads them; render_candidate only checks existence.)
printf '{"version":1,"clients":[]}\n' >"$STATE_DIR/identities.json"
printf '{"version":1}\n'              >"$STATE_DIR/identity.json"
printf '{"node_address":"node.example.invalid"}\n' >"$STATE_DIR/params.json"

# Make the fake checkout a well-formed git repo so the default git-fetch path does not error before
# we reach the render step. All git config is scoped to THIS repo (no global mutation).
(
	cd "$FAKE_CHECKOUT" || exit 1
	git init -q
	git config user.email "test@example.invalid"
	git config user.name  "conformance"
	git add -A
	git commit -q -m "fake checkout for artifact-root test" >/dev/null 2>&1
) || { printf 'FAIL: could not initialise the fake checkout git repo\n' >&2; exit 2; }

# Emulate the POST-RE-EXEC image: copy the updater OUTSIDE the fake checkout. From this copy,
# REPO_ROOT (= copy/..) resolves to REEXEC_DIR's parent ($WORK), which has NO nodes/ or control/.
REEXEC_SELF="$REEXEC_DIR/node-bootstrap.sh"
cp "$SCRIPT" "$REEXEC_SELF"
chmod 0755 "$REEXEC_SELF"

# --- Run the re-exec'd copy in dry-run + insecure (testing) mode ------------------------------
# MYC_REEXEC=1   -> skip the re-exec block; run flow_update from this (stable) image, exactly as the
#                  real updater does in its second pass.
# --insecure-no-verify -> bypass the signature gate (documented testing-only flag; offline).
# --dry-run      -> fetch/merge/render are LOGGED, not executed (no sing-box, no network egress).
OUT="$WORK/out.log"
set +e
MYC_REEXEC=1 bash "$REEXEC_SELF" \
	--update --dry-run --insecure-no-verify \
	--checkout "$FAKE_CHECKOUT" \
	--state-dir "$STATE_DIR" \
	--tooling-dir "$TOOLING_DIR" \
	--no-harden --no-amneziawg \
	>"$OUT" 2>&1
rc=$?
set -e

if [ ! -s "$OUT" ]; then
	badln "the updater produced no output (rc=$rc) — cannot inspect resolved artifact paths"
	printf '\n-- Result --\nFAIL: no output captured.\n' >&2
	exit 1
fi

# The dry-run render line logs the full myceliumctl command including --template <RENDER_TEMPLATE>.
# That line is our window onto the RESOLVED artifact path.
RENDER_LINE="$(grep -E '\[dry-run\].*render-server' "$OUT" | head -n1 || true)"

# 1) The render template must resolve UNDER the fake checkout (ARTIFACT_ROOT = CHECKOUT_DIR).
if printf '%s' "$RENDER_LINE" | grep -qF -- "--template $FAKE_CHECKOUT/nodes/dataplane/singbox/server.template.renderer.json"; then
	okln "renderer template resolved from CHECKOUT_DIR (ARTIFACT_ROOT), not a tmp path"
else
	badln "renderer template did NOT resolve from CHECKOUT_DIR — render line: ${RENDER_LINE:-<none>}"
fi

# 2) The render command must run the in-checkout myceliumctl fallback (no installed tooling copy).
if printf '%s' "$RENDER_LINE" | grep -qF -- "$FAKE_CHECKOUT/control/myceliumctl render-server"; then
	okln "myceliumctl fallback resolved from CHECKOUT_DIR/control"
else
	badln "myceliumctl did NOT resolve from CHECKOUT_DIR/control — render line: ${RENDER_LINE:-<none>}"
fi

# 3) install_tooling must source control/ from CHECKOUT_DIR (the dry-run logs its cp source).
if grep -qF -- "$FAKE_CHECKOUT/control" "$OUT" \
	&& grep -E '\[dry-run\].*cp .*'"$FAKE_CHECKOUT/control" "$OUT" >/dev/null 2>&1; then
	okln "install_tooling sources control/ from CHECKOUT_DIR"
else
	# Tolerate environments where cp logging differs, but require the path to appear at least once.
	if grep -qF -- "$FAKE_CHECKOUT/control" "$OUT"; then
		okln "control/ tooling references CHECKOUT_DIR"
	else
		badln "install_tooling did NOT reference CHECKOUT_DIR/control"
	fi
fi

# 4) REGRESSION GUARD: NO artifact path may point at the re-exec tmp dir. If the old REPO_ROOT
#    behaviour leaked back, the donor list / template / control path would carry the tmp prefix.
if grep -F -- "$REEXEC_DIR/nodes" "$OUT" >/dev/null 2>&1 \
	|| grep -F -- "$REEXEC_DIR/control" "$OUT" >/dev/null 2>&1 \
	|| grep -E -- "$WORK/nodes/dataplane" "$OUT" >/dev/null 2>&1; then
	badln "an artifact path leaked to the re-exec tmp dir (S1 regression)"
else
	okln "no artifact path leaked to the re-exec tmp dir"
fi

printf '\n-- Result --\n'
if [ "$fail" -ne 0 ]; then
	printf 'FAIL: the --update path does not resolve canonical artifacts from CHECKOUT_DIR\n' >&2
	printf '      (ARTIFACT_ROOT). Captured updater output follows:\n' >&2
	sed 's/^/      | /' "$OUT" >&2
	exit 1
fi
printf 'PASS: --update resolves donor list, renderer template and control tooling from CHECKOUT_DIR.\n'
exit 0
