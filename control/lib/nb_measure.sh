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
_measure_vocab()       { printf '%s' "${MYC_VOCAB:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/vocab.json}"; }

# generate_measure_configs (--measure-configure) — write the node-local reach + measure configs from
# params.json + the closed registry (control/vocab.json), 1:1 REF-MATCHED. Each ENABLED sing-box
# transport member becomes (a) a reach target that probes its OWN listener (127.0.0.1:<port>) and (b) a
# measure member. The own-listener probe is a NODE-LOCAL signal: it detects a down / unbound /
# misrendered inbound, NOT a client-side block (the operator's clean vantage cannot see that — the
# documented Plane-1 limit; client-side detection is a later edge-reporting plane). The first enabled
# member (registry priority order) is the active incumbent. enable_key/port_key come from the registry,
# never a bash convention (§2.2 #8). Fail-closed: needs params + >=1 enabled member.
generate_measure_configs() {
	need_root
	local vocab params members n active reach_cfg measure_cfg
	vocab="$(_measure_vocab)"; reach_cfg="$(_measure_reach_cfg)"; measure_cfg="$(_measure_cfg)"
	[ -f "$PARAMS_JSON" ] || die "measure: params.json missing ($PARAMS_JSON) — bootstrap/render first."
	[ -f "$vocab" ]       || die "measure: registry vocab.json missing ($vocab)."
	params="$(jq -c . "$PARAMS_JSON" 2>/dev/null)" || die "measure: $PARAMS_JSON is not valid JSON."
	# Enabled sing-box members in registry priority order: [{ref,proto,port}] (params port override -> default).
	members="$(jq -n --argjson params "$params" --slurpfile v "$vocab" '
		[ $v[0].protos[]
		  | select(.engine == "sing-box")
		  | select($params[.enable_key] == true)
		  | { ref: .proto, proto: .proto, port: ($params[.port_key] // .default_port) } ]' 2>/dev/null)" \
		|| die "measure: failed to enumerate enabled members from params/vocab."
	n="$(printf '%s' "$members" | jq 'length' 2>/dev/null || echo 0)"
	[ "$n" -ge 1 ] || die "measure: no enabled sing-box transports in params — nothing to measure (enable at least one <proto>_enabled)."
	active="$(printf '%s' "$members" | jq -r '.[0].ref')"
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would write $reach_cfg + $measure_cfg ($n member(s), active=$active)"; return 0; fi
	run install -d -m 0755 "$STATE_DIR"
	# reach: own-listener TCP probe per member (window 10m, probe 30s, timeout 5s).
	printf '%s' "$members" | jq '{
		version: 1, window_ms: 600000,
		targets: [ .[] | { ref: .ref, method: "tcp", address: ("127.0.0.1:" + (.port|tostring)), interval_ms: 30000, timeout_ms: 5000 } ]
	}' >"$reach_cfg.tmp" && mv -f "$reach_cfg.tmp" "$reach_cfg"
	# measure: members + active incumbent + the rotation policy (reuse rotate_limits.json if present so
	# the daemon's PlanInput limits match the rotate loop's; else the documented defaults). tick 60s >=
	# the 30s probe interval (the daemon refuses to start if a tick would outpace the probes).
	local limits
	if [ -f "$STATE_DIR/rotate_limits.json" ] && jq -e . "$STATE_DIR/rotate_limits.json" >/dev/null 2>&1; then
		limits="$(jq -c . "$STATE_DIR/rotate_limits.json")"
	else
		limits='{"flip_confirmations":3,"min_weight_margin":0.1,"min_interval_ns":1800000000000,"window_ns":3600000000000,"max_per_window":2,"max_rollbacks_per_window":1,"cooldown_after_rollback_ns":3600000000000}'
	fi
	printf '%s' "$members" | jq \
		--arg active "$active" \
		--arg out "$STATE_DIR/rotate_plan_input.json" \
		--arg state "$STATE_DIR/rotate_state.json" \
		--argjson limits "$limits" '{
		version: 1, tick_ms: 60000, active_ref: $active,
		output_path: $out, state_path: $state, limits: $limits,
		members: [ .[] | { ref: .ref, proto: .proto, action: "promote-sibling", from_port: .port, to_port: 0 } ]
	}' >"$measure_cfg.tmp" && mv -f "$measure_cfg.tmp" "$measure_cfg"
	log "measure: wrote $reach_cfg + $measure_cfg ($n member(s), active=$active; reach probes own listeners — node-local, not client-vantage)."
}

# measure_enable (--measure-enable) — write + enable mycelium-measure.service. Fail-closed: requires the
# myceliumd binary AND both node-local configs present (a missing config would make the daemon fail to
# start; refuse loudly instead).
measure_enable() {
	need_root
	local bin="$TOOLING_DIR/bin/myceliumd" reach_cfg measure_cfg unit
	reach_cfg="$(_measure_reach_cfg)"; measure_cfg="$(_measure_cfg)"; unit="$(_measure_unit)"
	[ -x "$bin" ] || die "measure: $bin is not present (the Go daemon was not built — is the Go toolchain on this node? install_spine builds it where 'go' exists)."
	# Regenerate the node-local configs from the CURRENT params/registry, so --measure-enable always
	# reflects this node's actual enabled transports (and a later params change + re-enable re-derives).
	generate_measure_configs
	[ -f "$reach_cfg" ]   || die "measure: $reach_cfg missing — config generation failed (the MEASURE plane folds its snapshot)."
	[ -f "$measure_cfg" ] || die "measure: $measure_cfg missing — config generation failed (it names the members + the active ref + the output path)."
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
