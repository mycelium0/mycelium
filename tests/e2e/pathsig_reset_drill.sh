#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# pathsig_reset_drill.sh — RP-0014 chunk B 1c: the on-node end-to-end drill that proves the WHOLE
# path-signal chain live — a served-side inbound-RST spike -> the passive nft observer counts it ->
# the marker flips reset:[<class>] -> the measure daemon folds it -> the served rotate.PlanInput's
# ACTIVE verdict becomes blocked/connection-reset.
# Author: mindicator & silicon bags quartet.
#
# WHAT IT DOES (and does NOT do)
#   Runs ON a node whose MEASURE plane is armed (`node-bootstrap.sh --measure-enable`, which installs the
#   passive nft counters + starts mycelium-measure.service). It generates a burst of abortive (SO_LINGER=0)
#   TCP closes to the ACTIVE member's served port — each sends one inbound RST the observer's input-hook
#   counter catches — runs the observer probe to publish a fresh marker generation, and repeats across
#   several generations. It then polls the daemon's rotate.PlanInput until the active verdict is
#   blocked/connection-reset. It NEVER edits the served config, the params, the running engine, or the
#   firewall — the only durable effect is transient counter increments + a self-expiring marker, and the RST
#   burst is just closed connections; when it stops, the detector's own hysteresis returns the verdict to
#   clean. It quiesces the production mycelium-pathsig.timer for its duration (so a scheduled probe cannot
#   reset the daemon's generation streak mid-drill) and restores it on exit.
#
#   ONE caveat: driving the active verdict to blocked/connection-reset is exactly what a live rotate loop
#   consumes, so on a node whose rotate APPLY loop is ARMED ($STATE_DIR/rotate-live.enabled) this drill could
#   trigger a real rotation. It therefore REFUSES to run on an armed node unless PATHSIG_DRILL_ALLOW_ARMED=1.
#   On an un-armed node (the default posture) it is a pure diagnostic with no cleanup step.
#
# WHY THE GENERATION SPACING MATTERS
#   The daemon faults a class only after it READS reset:[<class>] across >= path_min_reset_generations
#   (default 2) DISTINCT marker generations (observed_at values), on its OWN tick cadence (tick_ms, default
#   30s). If the marker were rewritten faster than the daemon ticks, the daemon would read a single
#   generation and never fault. So this drill SPACES generations by > one daemon tick (--gen-gap), so each
#   generation is read before the next overwrites it. Total wall clock ~= generations * gen-gap + the
#   detector flip-confirmation streak — single-digit minutes by design.
#
# NOT A CI GATE. It moves real packets and needs an armed node; the offline gate that proves the observer
# is passive/node-local/payload-free is tests/conformance/pathsig_passive_observer.sh, and the node-free
# proof of the daemon fold is TestPathSignalMarkerDrivesBlockedReset (cmd/myceliumd). This closes the loop
# live.
#
# Exit: 0 = the active verdict reached blocked/connection-reset; 1 = it did not within --timeout;
#       2 = usage/env error.

set -uo pipefail

usage() {
	cat <<'USAGE'
pathsig_reset_drill.sh — on-node end-to-end drill for the path-signal chain (RP-0014 chunk B 1c).

Usage (run as root, ON an armed node):
  pathsig_reset_drill.sh --port PORT [options]

  --port PORT        the ACTIVE member's served TCP port to spike (required; a reality/ws-tls/shadowtls/
                     trojan port — a UDP family (hy2/tuic/awg) has no TCP RST and cannot be drilled).
  --target ADDR      where to send the RST burst (default 127.0.0.1; use the node's public IP to mirror a
                     real off-node client if loopback RSTs are filtered on this host).
  --count N          RSTs per generation (default 15; must clear the observer's absolute floor of 5).
  --generations N    distinct marker generations to drive (default 3; must exceed path_min_reset_generations).
  --gen-gap SEC      seconds between generations (default 35; must exceed the daemon tick_ms/1000, ~30s).
  --timeout SEC      max wait for the active verdict to flip after the last generation (default 120).
  --checkout DIR     the deployed checkout / artifact root (default /opt/mycelium) — locates node-bootstrap.sh.
  --state-dir DIR    the node state dir (default /var/lib/mycelium) — holds the marker + the PlanInput.
  --tooling-dir DIR  the tooling dir (default /usr/local/lib/mycelium) — passed through to the observer probe.
  --plan PATH        the rotate.PlanInput to read (default STATE_DIR/rotate_plan_input.json).

  The observer marker is always STATE_DIR/path_signal.json — the fixed path the probe + daemon share.

Requires root, nft (armed observer table), python3 (RST generator), jq. Exit: 0 flipped, 1 not, 2 env.
USAGE
}

port=""; target="127.0.0.1"; count=15; generations=3; gen_gap=35; timeout_s=120
checkout="/opt/mycelium"; state_dir="/var/lib/mycelium"; tooling_dir="/usr/local/lib/mycelium"
plan=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--port)        port="${2:?--port needs a value}"; shift 2 ;;
		--target)      target="${2:?--target needs a value}"; shift 2 ;;
		--count)       count="${2:?--count needs a value}"; shift 2 ;;
		--generations) generations="${2:?--generations needs a value}"; shift 2 ;;
		--gen-gap)     gen_gap="${2:?--gen-gap needs a value}"; shift 2 ;;
		--timeout)     timeout_s="${2:?--timeout needs a value}"; shift 2 ;;
		--checkout)    checkout="${2:?--checkout needs a value}"; shift 2 ;;
		--state-dir)   state_dir="${2:?--state-dir needs a value}"; shift 2 ;;
		--tooling-dir) tooling_dir="${2:?--tooling-dir needs a value}"; shift 2 ;;
		--plan)        plan="${2:?--plan needs a value}"; shift 2 ;;
		-h|--help)     usage; exit 0 ;;
		*) printf 'pathsig_reset_drill: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

plan="${plan:-$state_dir/rotate_plan_input.json}"
marker="$state_dir/path_signal.json"   # fixed: the observer probe + the daemon config both use this path
nb="$checkout/scripts/node-bootstrap.sh"

die() { printf 'pathsig_reset_drill: %s\n' "$1" >&2; exit 2; }
[ -n "$port" ] || die "--port is required"
# Every count/size argument must be a positive integer (a bad value would fail late or misbehave mid-run).
for pair in "port:$port" "count:$count" "generations:$generations" "gen-gap:$gen_gap" "timeout:$timeout_s"; do
	name="${pair%%:*}"; val="${pair#*:}"
	case "$val" in ''|*[!0-9]*) die "--$name must be a positive integer (got '$val')" ;; esac
	[ "$val" -gt 0 ] || die "--$name must be > 0 (got '$val')"
done
[ "$port" -le 65535 ] || die "--port must be a valid TCP port (1-65535), got '$port'"
[ "$(id -u)" = "0" ] || die "must run as root (nft + raw socket close)"
command -v nft     >/dev/null 2>&1 || die "nft is required (the observer table is nft)"
command -v jq      >/dev/null 2>&1 || die "jq is required (reads the PlanInput / marker)"
command -v python3 >/dev/null 2>&1 || die "python3 is required (the SO_LINGER=0 RST generator)"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required (to quiesce the pathsig timer during the drill)"
nft list table inet mycelium_measure >/dev/null 2>&1 || die "the observer table 'inet mycelium_measure' is not armed — run: node-bootstrap.sh --measure-enable"
[ -f "$nb" ] || die "node-bootstrap.sh not found at $nb (pass --checkout)"
[ -f "$plan" ] || die "the PlanInput is not present at $plan — is mycelium-measure.service running? (node-bootstrap.sh --measure-enable)"

# SAFETY: if the node's rotate APPLY loop is armed, driving the active verdict to blocked/connection-reset
# can trigger a REAL rotation (that is the fold's whole purpose). Refuse by default so the drill is a
# no-side-effect diagnostic; the operator can override once they accept a rotation may fire.
if [ -f "$state_dir/rotate-live.enabled" ] && [ "${PATHSIG_DRILL_ALLOW_ARMED:-0}" != "1" ]; then
	die "the rotate apply loop is ARMED ($state_dir/rotate-live.enabled present) — driving blocked/connection-reset may fire a real rotation. Disarm ('node-bootstrap.sh --rotate-disarm') or re-run with PATHSIG_DRILL_ALLOW_ARMED=1 to accept it."
fi

# The drill must be the SOLE writer of the observer baseline + marker while it runs — otherwise the
# production mycelium-pathsig.timer firing between generations writes its own (likely reset:[]) generation,
# resetting the daemon's per-class streak and causing an intermittent false FAIL. Quiesce the timer for the
# duration and ALWAYS restore its prior state on exit (even on interrupt/failure).
timer_was_active=0
if systemctl is-active --quiet mycelium-pathsig.timer 2>/dev/null; then timer_was_active=1; fi
restore_timer() { [ "$timer_was_active" = 1 ] && systemctl start mycelium-pathsig.timer >/dev/null 2>&1 || true; }
# EXIT restores on every normal/failed exit. The signal traps must ALSO exit: a handler that merely restores
# and returns would restart the timer while the drill kept running — reintroducing exactly the mid-drill
# generation race the quiescing exists to prevent (and making Ctrl-C unable to abort the run).
trap restore_timer EXIT
trap 'restore_timer; exit 130' INT TERM HUP
[ "$timer_was_active" = 1 ] && { systemctl stop mycelium-pathsig.timer >/dev/null 2>&1 || true; printf '   quiesced mycelium-pathsig.timer for the drill (restored on exit)\n'; }

# The active member the daemon currently ranks as incumbent — its verdict is what we assert flips.
active_proto="$(jq -r '.active.proto // empty' "$plan" 2>/dev/null || true)"
[ -n "$active_proto" ] || die "could not read .active.proto from $plan (is it a valid PlanInput?)"
active_state0="$(jq -r '.active_verdict.state // "?"' "$plan" 2>/dev/null || echo '?')"
printf '== pathsig reset drill — active member %s on %s:%s ==\n' "$active_proto" "$target" "$port"
printf '   start: active_verdict.state=%s  generations=%s  gap=%ss  count=%s/gen  timeout=%ss\n' \
	"$active_state0" "$generations" "$gen_gap" "$count" "$timeout_s"

# --- the RST generator: `count` abortive (SO_LINGER=0) TCP closes -> `count` inbound RSTs to the port.
rst_burst() {
	python3 - "$target" "$port" "$count" <<'PY'
import socket, struct, sys
host, port, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
linger = struct.pack('ii', 1, 0)  # SO_LINGER on, timeout 0 -> abortive close sends RST
ok = 0
for _ in range(n):
    try:
        s = socket.create_connection((host, port), timeout=2)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger)
        s.close()  # RST to (host, port): the served-port input-hook counter catches it
        ok += 1
    except OSError:
        pass
print(ok)
PY
}

# --- run the observer probe once to publish a fresh marker generation (distinct observed_at).
probe() { bash "$nb" --pathsig-probe --checkout "$checkout" --state-dir "$state_dir" --tooling-dir "$tooling_dir" >/dev/null 2>&1 || true; }

# Baseline the observer so the first real generation deltas cleanly.
probe
printf '   baselined observer; driving %s generation(s)...\n' "$generations"

reset_seen=0
g=1
while [ "$g" -le "$generations" ]; do
	sent="$(rst_burst 2>/dev/null || echo 0)"
	probe
	rc="$(jq -r '.reset // [] | join(",")' "$marker" 2>/dev/null || echo '')"
	printf '   gen %s/%s: sent %s RST(s) -> marker reset:[%s]\n' "$g" "$generations" "$sent" "$rc"
	case ",$rc," in *",$active_proto,"*) reset_seen=1 ;; esac
	[ "$g" -lt "$generations" ] && sleep "$gen_gap"
	g=$((g + 1))
done

if [ "$reset_seen" -ne 1 ]; then
	printf 'FAIL: the observer never flagged the active class %s in reset:[...] — no RSTs reached the counter (wrong --port/--target, or the port is UDP?).\n' "$active_proto" >&2
	exit 1
fi

# Poll the PlanInput until the active verdict is blocked/connection-reset (the daemon needs >= gen gate +
# the detector flip-confirmation streak, both crossed by the generations above once its ticks read them).
printf '   observer flagged %s; polling the PlanInput for the daemon fold (<=%ss)...\n' "$active_proto" "$timeout_s"
deadline=$(( $(date +%s) + timeout_s ))
final_state="?"; final_reason="?"
while [ "$(date +%s)" -le "$deadline" ]; do
	final_state="$(jq -r '.active_verdict.state // "?"' "$plan" 2>/dev/null || echo '?')"
	final_reason="$(jq -r '.active_verdict.reason // "?"' "$plan" 2>/dev/null || echo '?')"
	if [ "$final_state" = "blocked" ] && [ "$final_reason" = "connection-reset" ]; then
		break
	fi
	sleep 3
done

printf '\n-- Result --\n'
result_json="$(jq -nc \
	--arg proto "$active_proto" --arg tgt "$target" --argjson port "$port" \
	--argjson gens "$generations" --arg state "$final_state" --arg reason "$final_reason" \
	--argjson pass "$([ "$final_state" = blocked ] && [ "$final_reason" = connection-reset ] && echo true || echo false)" \
	'{active_proto:$proto, target:$tgt, port:$port, generations:$gens, plan_state:$state, plan_reason:$reason, pass:$pass}')"
printf '%s\n' "$result_json"

if [ "$final_state" = "blocked" ] && [ "$final_reason" = "connection-reset" ]; then
	printf 'PASS: the served-side RST spike drove the daemon verdict for %s to blocked/connection-reset (observer -> marker -> daemon fold, end to end).\n' "$active_proto"
	exit 0
fi
printf 'FAIL: the active verdict did not reach blocked/connection-reset within %ss (got %s/%s). The observer flagged the class; check path_min_reset_generations vs --generations, tick_ms vs --gen-gap, and that mycelium-measure.service is reading %s.\n' \
	"$timeout_s" "$final_state" "$final_reason" "$marker" >&2
exit 1
