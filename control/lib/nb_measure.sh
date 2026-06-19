# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_measure.sh — RP-0010 Plane-1 (MEASURE) node-side deploy. Enable/disable the mycelium-measure
# daemon (myceliumd) that folds the node-local reach snapshot into a rotate.PlanInput.
# Author: mindicator & silicon bags quartet.
#
# The daemon is strictly ADVISORY: it assembles + serves (and atomically writes) a rotate.PlanInput;
# it NEVER actuates — the RP-0012 rotation loop, separately and triple-gated, is the only actuator.
# install_spine builds the myceliumd binary (always, inert); this lib only manages the service.
#
# SHIPS DISABLED (the C4c-2 pattern): mycelium-measure.service is WRITTEN + ENABLED only by
# --measure-enable, NEVER by flow_bootstrap / flow_update / install_tooling / install_spine. The unit
# does not even exist on a stock node, so an auto-pull can never start the plane; arming is a per-node
# operator act (like --rotate-arm / --rotate-enable-loop). Revert with --measure-disable.
#
# The daemon runs under systemd Type=notify with WatchdogSec (myceliumd sends sd_notify READY=1 once
# the listener is bound + the monitors are up, and pings the watchdog) — systemd owns liveness, not a
# hand-rolled supervisor (ADR-0031 reuse).

MEASURE_LISTEN="${MEASURE_LISTEN:-127.0.0.1:9551}"
MEASURE_WATCHDOG_SEC="${MEASURE_WATCHDOG_SEC:-120}"

_measure_unit() { printf '%s' "/etc/systemd/system/mycelium-measure.service"; }
_measure_reach_cfg()   { printf '%s' "$STATE_DIR/reach.config.json"; }
_measure_cfg()         { printf '%s' "$STATE_DIR/measure.config.json"; }

# measure_enable (--measure-enable) — write + enable mycelium-measure.service. Fail-closed: requires the
# myceliumd binary AND both node-local configs present (a missing config would make the daemon fail to
# start; refuse loudly instead).
measure_enable() {
	need_root
	local bin="$TOOLING_DIR/bin/myceliumd" reach_cfg measure_cfg unit
	reach_cfg="$(_measure_reach_cfg)"; measure_cfg="$(_measure_cfg)"; unit="$(_measure_unit)"
	[ -x "$bin" ] || die "measure: $bin is not present (the Go daemon was not built — is the Go toolchain on this node? install_spine builds it where 'go' exists)."
	[ -f "$reach_cfg" ]   || die "measure: $reach_cfg missing — generate the node-local reachability config first (the MEASURE plane folds its snapshot)."
	[ -f "$measure_cfg" ] || die "measure: $measure_cfg missing — generate the node-local measure config first (it names the members + the active ref + the output path)."
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would install + enable mycelium-measure.service (advisory daemon on $MEASURE_LISTEN)"; return 0; fi
	cat >"$unit" <<UNIT
[Unit]
Description=Mycelium MEASURE plane (RP-0010 Plane 1) — node-local reach->detect->tune->PlanInput (advisory)
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=notify
WatchdogSec=${MEASURE_WATCHDOG_SEC}
ExecStart=${bin} --listen ${MEASURE_LISTEN} --reachability-config ${reach_cfg} --measure-config ${measure_cfg}
Restart=on-failure
RestartSec=10
TimeoutStartSec=30
Nice=10
IOSchedulingClass=idle
# Advisory: assembles + serves + atomically writes a rotate.PlanInput; it NEVER actuates a rotation
# (the gated RP-0012 loop is the only actuator). Loopback-only listen, no PII emitted.

[Install]
WantedBy=multi-user.target
UNIT
	run systemctl daemon-reload
	run systemctl enable --now mycelium-measure.service || die "measure: could not enable mycelium-measure.service (fail-closed)."
	log "measure: mycelium-measure.service ENABLED — this node now assembles a node-local rotate.PlanInput (ADVISORY; it does NOT rotate). Disable with '$0 --measure-disable'."
}

# measure_disable (--measure-disable) — disable + remove the unit (revert to no MEASURE daemon).
measure_disable() {
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would disable + remove mycelium-measure.service"; return 0; fi
	run systemctl disable --now mycelium-measure.service 2>/dev/null || true
	rm -f "$(_measure_unit)"
	run systemctl daemon-reload
	log "measure: mycelium-measure.service DISABLED + removed; the node no longer assembles a PlanInput."
}
