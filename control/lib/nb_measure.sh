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
# Self-drive CADENCE defaults — tuned so an armed node recovers within single-digit minutes (the Phase-2
# DoD-1 bar): detection over a 2-min reach window (15s own-listener probes) + a 30s assemble tick, with
# the rotate loop checking every 90s. These trade a little anti-flap headroom for recovery speed; an
# operator can widen them per environment. tick_ms MUST stay >= the probe interval (the daemon fail-closes
# otherwise). The planner's own anti-flap (flip_confirmations=3) + the 30-min post-rotation cooldown still
# bound how often a node actually actuates, regardless of how fast it CHECKS.
MEASURE_TICK_MS="${MEASURE_TICK_MS:-30000}"
MEASURE_REACH_WINDOW_MS="${MEASURE_REACH_WINDOW_MS:-120000}"
MEASURE_REACH_PROBE_MS="${MEASURE_REACH_PROBE_MS:-15000}"
MEASURE_REACH_TIMEOUT_MS="${MEASURE_REACH_TIMEOUT_MS:-3000}"
# L7 own-cert/cover-path liveness probe (RP-0010 AC-6 clarification): the daemon honors a marker up to
# MAX_AGE old (a few probe-intervals, so a FRESH dead marker faults but a STOPPED probe self-expires to
# healthy — fail-safe); the probe itself runs OUT of the daemon on a budgeted+jittered oneshot timer
# (INTERVAL +/- JITTER), a slower cadence than the 30s tick — the expensive, bounded hyphal probe, never
# every tick. It closes the reach L4-only blind spot (a bound listener that is client-DEAD at L7).
# Cadence tuned 2026-07-04 for single-digit-minute L7 recovery: a client-DEAD-at-L7 transport faults only
# after MEASURE_L7_MIN_DEAD_GEN (below) DISTINCT dead generations, so L7 recovery ~= MIN_DEAD_GEN x INTERVAL
# + the detect/rotate streak. At 120s +/- 45s (was 300 +/- 120) two generations land in ~4-5min; a live
# drill on a node measured ~8min end-to-end recovery (single-digit) — the planner anti-flap
# (flip_confirmations x the ~90s rotate-loop cadence, NOT the probe interval) now bounds the tail.
# The probe is node-local (loopback own-cert + own-dest REALITY steal, no third-party beacon —
# ADR-0036), so the tighter cadence costs only local CPU, not reachability surface. MAX_AGE stays >= 2x the
# worst-case probe gap (INTERVAL+JITTER) — the S3 cross-check below warns if that is ever violated.
MEASURE_L7_MAX_AGE_MS="${MEASURE_L7_MAX_AGE_MS:-420000}"
MEASURE_L7_INTERVAL_SEC="${MEASURE_L7_INTERVAL_SEC:-120}"
MEASURE_L7_JITTER_SEC="${MEASURE_L7_JITTER_SEC:-45}"
# Marker-replay hardening (Audit-0007 S2): the daemon faults a member only after it reads DEAD across
# >= this many DISTINCT probe generations, so one dead run replayed across ~tick-interval reads cannot
# satisfy the tick-based anti-flap on its own. Default 2 (operator decision 2026-07-03); set 1 to restore
# the pre-gate fault-on-first-generation behaviour.
MEASURE_L7_MIN_DEAD_GEN="${MEASURE_L7_MIN_DEAD_GEN:-2}"
# RP-0014 chunk B path-signal marker freshness + replay hardening. The pathsig observer runs on the SAME
# budgeted+jittered cadence as the L7 probe (MEASURE_L7_INTERVAL_SEC +/- MEASURE_L7_JITTER_SEC), so its
# marker ages exactly like the L7 one: MAX_AGE defaults to the L7 value (>= 2x the worst-case observer gap,
# so a fresh reset faults but a stopped observer self-expires to healthy — fail-safe). MIN_RESET_GEN mirrors
# MIN_DEAD_GEN: a class faults ConnectReset only after it reads RESET across this many DISTINCT observer
# generations, so a one-off RST spike (or a replayed marker) cannot fault on its own. Set 1 to fault on the
# first reset generation.
MEASURE_PATH_MAX_AGE_MS="${MEASURE_PATH_MAX_AGE_MS:-$MEASURE_L7_MAX_AGE_MS}"
MEASURE_PATH_MIN_RESET_GEN="${MEASURE_PATH_MIN_RESET_GEN:-2}"

_measure_unit() { printf '%s' "/etc/systemd/system/mycelium-measure.service"; }
_l7probe_service_unit() { printf '%s' "/etc/systemd/system/mycelium-l7probe.service"; }
_l7probe_timer_unit()   { printf '%s' "/etc/systemd/system/mycelium-l7probe.timer"; }
_pathsig_service_unit() { printf '%s' "/etc/systemd/system/mycelium-pathsig.service"; }
_pathsig_timer_unit()   { printf '%s' "/etc/systemd/system/mycelium-pathsig.timer"; }
_measure_reach_cfg()   { printf '%s' "$STATE_DIR/reach.config.json"; }
_measure_cfg()         { printf '%s' "$STATE_DIR/measure.config.json"; }
_measure_pathsig_marker() { printf '%s' "$STATE_DIR/path_signal.json"; }
_measure_l7_marker()   { printf '%s' "$STATE_DIR/l7_selftest.json"; }
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
	# L7 cadence cross-check (Audit-0007 S3): the daemon folds a marker only while it is younger than
	# MAX_AGE; the probe refreshes it every INTERVAL +/- JITTER. If MAX_AGE is shorter than the worst-case
	# gap between two probe completions, a marker can expire BEFORE the next one lands -> the L7 signal
	# intermittently drops to "healthy" even while a transport is dead. Advisory probe -> warn, not fatal.
	local _l7_gap_ms=$(( (MEASURE_L7_INTERVAL_SEC + MEASURE_L7_JITTER_SEC) * 1000 ))
	if [ "$MEASURE_L7_MAX_AGE_MS" -lt "$_l7_gap_ms" ]; then
		warn "measure: MEASURE_L7_MAX_AGE_MS=$MEASURE_L7_MAX_AGE_MS is SHORTER than the worst-case probe gap ${_l7_gap_ms}ms (interval ${MEASURE_L7_INTERVAL_SEC}s + jitter ${MEASURE_L7_JITTER_SEC}s): the L7 marker can go stale between probes, so L7 liveness will intermittently fold as healthy. Raise MAX_AGE (>= 2x the gap recommended) or lower the interval/jitter."
	fi
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would write $reach_cfg + $measure_cfg ($n member(s), active=$active)"; return 0; fi
	run install -d -m 0755 "$STATE_DIR"
	# reach: own-listener TCP probe per member (window 2m, probe 15s, timeout 3s — tuned defaults, env-overridable).
	printf '%s' "$members" | jq \
		--argjson win "$MEASURE_REACH_WINDOW_MS" --argjson probe "$MEASURE_REACH_PROBE_MS" --argjson tmo "$MEASURE_REACH_TIMEOUT_MS" '{
		version: 1, window_ms: $win,
		targets: [ .[] | { ref: .ref, method: "tcp", address: ("127.0.0.1:" + (.port|tostring)), interval_ms: $probe, timeout_ms: $tmo } ]
	}' >"$reach_cfg.tmp" && mv -f "$reach_cfg.tmp" "$reach_cfg"
	# measure: members + active incumbent + the rotation policy (reuse rotate_limits.json if present so
	# the daemon's PlanInput limits match the rotate loop's; else the documented defaults). tick 30s >=
	# the 15s probe interval (the daemon refuses to start if a tick would outpace the probes).
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
		--arg l7path "$(_measure_l7_marker)" \
		--argjson l7age "$MEASURE_L7_MAX_AGE_MS" \
		--argjson l7gen "$MEASURE_L7_MIN_DEAD_GEN" \
		--arg pathpath "$(_measure_pathsig_marker)" \
		--argjson pathage "$MEASURE_PATH_MAX_AGE_MS" \
		--argjson pathgen "$MEASURE_PATH_MIN_RESET_GEN" \
		--argjson limits "$limits" \
		--argjson tick "$MEASURE_TICK_MS" '{
		version: 1, tick_ms: $tick, active_ref: $active,
		output_path: $out, state_path: $state, limits: $limits,
		l7_liveness_path: $l7path, l7_max_age_ms: $l7age, l7_min_dead_generations: $l7gen,
		path_signal_path: $pathpath, path_max_age_ms: $pathage, path_min_reset_generations: $pathgen,
		members: [ .[] | { ref: .ref, proto: .proto, action: "promote-sibling", from_port: .port, to_port: 0 } ]
	}' >"$measure_cfg.tmp" && mv -f "$measure_cfg.tmp" "$measure_cfg"
	log "measure: wrote $reach_cfg + $measure_cfg ($n member(s), active=$active; reach probes own listeners — node-local, not client-vantage)."
}

# ---------------------------------------------------------------------------
# RP-0014 chunk B (increment 1) — passive path-level served-flow interference observer (ConnectReset).
# A dedicated ADDITIVE nft table (input hook, priority BELOW ufw, `policy accept` -> it NEVER drops, only
# falls through to the real firewall) carries a per-served-TCP-port RST + SYN *counter*. measure_pathsig_probe
# reads the counter deltas over a budgeted+jittered window and sets ConnectReset (in a node-local marker the
# measure daemon folds into DetectorSignal, mirroring the L7 marker) for a served class whose inbound-RST
# rate is a high fraction of its new-connection rate. Pure by-product (AC-6): no drop, no payload, no per-peer
# identity retained — only per-class RST/SYN counts. UDP families (QUIC/AmneziaWG) have no TCP RST and are not
# observed. Fail-safe: absent nft/jq/table/baseline -> no signal (never fabricates a block). ADR-0036 boundary:
# watching the node's OWN served traffic passively is a by-product, not a new client-vantage probe.
# ---------------------------------------------------------------------------
PATHSIG_NFT_TABLE="inet mycelium_measure"

# _pathsig_tcp_ports — the served client-facing TCP listener ports from the live sing-box config (reality
# vless / ws-tls vless / shadowtls / trojan). Excludes the UDP families (hy2/tuic) and the internal loopback
# shadowsocks detour (which listens on 127.0.0.1, not `::`/0.0.0.0).
_pathsig_tcp_ports() {
	[ -f "$SINGBOX_CONFIG" ] || return 0
	jq -r '.inbounds[]? | select((.type=="vless" or .type=="shadowtls" or .type=="trojan") and (.listen_port!=null) and ((.listen // "::")|test("^(::|0\\.0\\.0\\.0)$"))) | .listen_port' \
		"$SINGBOX_CONFIG" 2>/dev/null | sort -un
}

# pathsig_nft_apply — install the passive per-port RST/SYN counters (idempotent: delete + recreate). No-op
# (fail-safe) if nft/jq/config absent or there are no served TCP ports.
pathsig_nft_apply() {
	have nft && have jq || return 0
	need_root
	local ports p; ports="$(_pathsig_tcp_ports)" || ports=""   # a malformed config must fold to skip, not abort measure-enable
	[ -n "$ports" ] || { log "path-signal: no served TCP ports to observe; skipping nft counters."; return 0; }
	nft delete table $PATHSIG_NFT_TABLE 2>/dev/null || true
	{
		echo "table $PATHSIG_NFT_TABLE {"
		for p in $ports; do printf '  counter rst_%s {}\n  counter syn_%s {}\n' "$p" "$p"; done
		echo "  chain input {"
		echo "    type filter hook input priority filter - 10; policy accept;"
		for p in $ports; do
			printf '    tcp dport %s tcp flags & (rst) == rst counter name "rst_%s"\n' "$p" "$p"
			printf '    tcp dport %s tcp flags & (fin|syn|rst|ack) == syn counter name "syn_%s"\n' "$p" "$p"
		done
		echo "  }"
		echo "}"
	} | nft -f - 2>/dev/null \
		|| { warn "path-signal: could not install the nft observer counters (fail-safe: no path signal)."; return 0; }
	rm -f "$STATE_DIR/pathsig_counters.json" 2>/dev/null || true   # reset the baseline so the first read does not delta a stale snapshot
	log "path-signal: installed passive nft RST/SYN counters for served TCP port(s): $(printf '%s ' $ports)."
}

# pathsig_nft_remove — delete the observer table + baseline (idempotent).
pathsig_nft_remove() {
	have nft || return 0
	nft delete table $PATHSIG_NFT_TABLE 2>/dev/null || true
	rm -f "$STATE_DIR/pathsig_counters.json" 2>/dev/null || true
}

# measure_pathsig_probe [MARKER] — read the RST/SYN counter deltas since the last window, threshold, and write
# the ConnectReset marker (default $STATE_DIR/path_signal.json = {observed_at, checked, reset:[REFS]}). A ref
# in `reset` names a served class whose inbound-RST rate this window was >= PATHSIG_RST_FLOOR (absolute, to
# ignore low-traffic noise) AND >= PATHSIG_RST_RATIO_NUM/DEN of its new-connection rate. The first read after
# (re)arm only baselines (no delta yet). Counter reset (a table reload) clamps the delta to 0 -> no false
# signal. Fail-safe: absent table/jq -> no marker.
measure_pathsig_probe() {
	have nft && have jq || return 0
	nft list table $PATHSIG_NFT_TABLE >/dev/null 2>&1 || return 0   # observer not armed -> skip
	local marker="${1:-$STATE_DIR/path_signal.json}" statef="$STATE_DIR/pathsig_counters.json"
	local cur; cur="$(nft -j list counters table $PATHSIG_NFT_TABLE 2>/dev/null \
		| jq -c '[.nftables[].counter? | select(.name != null) | {(.name): .packets}] | add // {}')" || return 0
	[ -n "$cur" ] && [ "$cur" != "null" ] && [ "$cur" != "{}" ] || return 0
	local portmap; portmap="$(jq -c '[.inbounds[]? | select((.type=="vless" or .type=="shadowtls" or .type=="trojan") and (.listen_port!=null)) | {(.listen_port|tostring): (.tag|sub("-in$";""))}] | add // {}' "$SINGBOX_CONFIG" 2>/dev/null)" || portmap="{}"
	local last="{}"; [ -f "$statef" ] && last="$(cat "$statef" 2>/dev/null || echo '{}')"
	( umask 077; printf '%s\n' "$cur" >"$statef.tmp" ) 2>/dev/null && mv -f "$statef.tmp" "$statef" 2>/dev/null || true
	local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if [ "$last" = "{}" ]; then
		printf '{"observed_at":"%s","checked":0,"reset":[]}\n' "$ts" >"$marker.tmp" 2>/dev/null && mv -f "$marker.tmp" "$marker" 2>/dev/null || true
		return 0   # first read after (re)arm: baseline only
	fi
	local reset; reset="$(jq -nc \
		--argjson cur "$cur" --argjson last "$last" --argjson pm "$portmap" \
		--argjson floor "${PATHSIG_RST_FLOOR:-5}" --argjson rnum "${PATHSIG_RST_RATIO_NUM:-1}" --argjson rden "${PATHSIG_RST_RATIO_DEN:-2}" '
		[ $cur | keys[] | select(startswith("rst_")) | ltrimstr("rst_") ]
		| map(. as $port
			| (($cur["rst_"+$port] // 0) - ($last["rst_"+$port] // 0) | if . < 0 then 0 else . end) as $rd
			| (($cur["syn_"+$port] // 0) - ($last["syn_"+$port] // 0) | if . < 0 then 0 else . end) as $sd
			| select($sd > 0 and $rd >= $floor and ($rd * $rden) >= ($rnum * $sd))
			| ($pm[$port] // empty))
		| unique')" || reset=""
	[ -n "$reset" ] || reset="[]"
	local n; n="$(printf '%s' "$cur" | jq '[keys[]|select(startswith("rst_"))]|length' 2>/dev/null || echo 0)"
	printf '{"observed_at":"%s","checked":%s,"reset":%s}\n' "$ts" "${n:-0}" "$reset" >"$marker.tmp" 2>/dev/null \
		&& mv -f "$marker.tmp" "$marker" 2>/dev/null || true
	if [ "$reset" != "[]" ]; then
		warn "path-signal: inbound-RST rate on served class(es) $(printf '%s' "$reset" | jq -r 'join(",")' 2>/dev/null || printf '%s' "$reset") exceeds the threshold — possible on-path connection-reset interference on real client flows."
		return 1
	fi
	log "path-signal: inbound-RST rates within threshold across all $n observed served TCP class(es)."
	return 0
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
	# Retire a legacy reach-only myceliumd.service (the RP-0010 C5c deploy seam) before enabling this
	# reach+measure superset. The legacy unit binds the SAME loopback endpoint ($MEASURE_LISTEN), so
	# leaving it active makes mycelium-measure.service fail-closed on 'address already in use' and the arm
	# path silently never starts the plane. mycelium-measure.service is a strict superset (it folds the
	# reach snapshot AND assembles the PlanInput), so retiring the superseded unit is safe + idempotent.
	if systemctl cat myceliumd.service >/dev/null 2>&1; then
		log "measure: retiring the legacy myceliumd.service (superseded by mycelium-measure.service; frees $MEASURE_LISTEN)."
		run systemctl disable --now myceliumd.service 2>/dev/null || true
	fi
	run systemctl daemon-reload
	run systemctl enable --now mycelium-measure.service || die "measure: could not enable mycelium-measure.service (fail-closed)."
	log "measure: mycelium-measure.service ENABLED — this node now assembles a node-local rotate.PlanInput (ADVISORY; it does NOT rotate). Disable with '$0 --measure-disable'."

	# L7 liveness probe (RP-0010 AC-6): a budgeted + jittered ONESHOT timer runs '--l7-probe' OUT of the
	# daemon, writing the marker the measure loop folds into DetectorSignal.ActiveProbeOK — closing the
	# reach L4-only blind spot (a bound listener that is client-DEAD at L7, e.g. a broken REALITY dest).
	# Armed alongside the measure plane (both are the explicit --measure-enable); removed by --measure-disable.
	cat >"$(_l7probe_service_unit)" <<UNIT
[Unit]
Description=Mycelium MEASURE L7 liveness probe (RP-0010 AC-6) — node-local own-cert/cover-path handshake
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NB_SELF --l7-probe --checkout $CHECKOUT_DIR --state-dir $STATE_DIR --tooling-dir $TOOLING_DIR
Nice=10
IOSchedulingClass=idle
UNIT
	cat >"$(_l7probe_timer_unit)" <<UNIT
[Unit]
Description=Mycelium MEASURE L7 liveness probe cadence (budgeted + jittered hyphal probe)

[Timer]
OnBootSec=${MEASURE_L7_INTERVAL_SEC}
OnUnitActiveSec=${MEASURE_L7_INTERVAL_SEC}
RandomizedDelaySec=${MEASURE_L7_JITTER_SEC}

[Install]
WantedBy=timers.target
UNIT
	run systemctl daemon-reload
	run systemctl enable --now mycelium-l7probe.timer || die "measure: could not enable mycelium-l7probe.timer (fail-closed)."
	run systemctl start mycelium-l7probe.service 2>/dev/null || true  # seed the marker now so the daemon has an L7 signal before the first timer fire
	log "measure: mycelium-l7probe.timer ENABLED (~every ${MEASURE_L7_INTERVAL_SEC}s +/-${MEASURE_L7_JITTER_SEC}s jitter) — folds L7 own-cert/cover-path liveness into detection."

	# RP-0014 chunk B: passive path-level served-flow observer — install the nft RST/SYN counters + a
	# budgeted+jittered ONESHOT timer running '--pathsig-probe', writing the ConnectReset marker the measure
	# loop folds into DetectorSignal (mirrors the L7 probe). Armed alongside the measure plane; the nft table
	# is additive (policy accept -> never drops), removed by --measure-disable.
	pathsig_nft_apply
	cat >"$(_pathsig_service_unit)" <<UNIT
[Unit]
Description=Mycelium MEASURE path-level served-flow observer (RP-0014 chunk B) — passive nft RST-rate signal
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NB_SELF --pathsig-probe --checkout $CHECKOUT_DIR --state-dir $STATE_DIR --tooling-dir $TOOLING_DIR
Nice=10
IOSchedulingClass=idle
UNIT
	cat >"$(_pathsig_timer_unit)" <<UNIT
[Unit]
Description=Mycelium MEASURE path-signal observer cadence (budgeted + jittered)

[Timer]
OnBootSec=${MEASURE_L7_INTERVAL_SEC}
OnUnitActiveSec=${MEASURE_L7_INTERVAL_SEC}
RandomizedDelaySec=${MEASURE_L7_JITTER_SEC}

[Install]
WantedBy=timers.target
UNIT
	run systemctl daemon-reload
	run systemctl enable --now mycelium-pathsig.timer || die "measure: could not enable mycelium-pathsig.timer (fail-closed)."
	run systemctl start mycelium-pathsig.service 2>/dev/null || true  # seed the observer baseline now
	log "measure: mycelium-pathsig.timer ENABLED (~every ${MEASURE_L7_INTERVAL_SEC}s +/-${MEASURE_L7_JITTER_SEC}s jitter) — folds the passive served-flow RST-rate signal (ConnectReset) into detection."
}

MEASURE_PLAN_MAX_STALE_SEC="${MEASURE_PLAN_MAX_STALE_SEC:-180}"

# refresh_rotate_plan_from_daemon — bridge the MEASURE daemon's output into the GATED rotation loop
# (RP-0010 C5c-3). If the daemon has written a FRESH rotate.PlanInput, run `myceliumctl rotate-plan` on
# it to produce the RotationPlan flow_rotate consumes — so the loop self-drives off the measured signal.
# A STALE PlanInput (its `.now` older than MEASURE_PLAN_MAX_STALE_SEC, or unparseable) is REFUSED: the
# daemon may be dead/hung, and across failing ticks it FREEZES the file at the last good tick, so a
# frozen plan must never be applied as if current. No daemon PlanInput -> no-op (the operator-supplied
# plan path is unchanged). This NEVER actuates — it only PRODUCES the plan; flow_rotate's triple gate
# (dry-run default + --apply-rotation + DRY_RUN=0 + arm sentinel) remains the only actuator.
refresh_rotate_plan_from_daemon() {
	local pi spine plan pi_now pi_epoch now_epoch age
	pi="$STATE_DIR/rotate_plan_input.json"
	plan="${ROTATE_PLAN:-$STATE_DIR/rotate_plan.json}"
	spine="${SPINE_BIN:-$TOOLING_DIR/bin/myceliumctl-go}"
	[ -f "$pi" ] || return 0
	[ -x "$spine" ] || { warn "rotation: $spine absent — cannot consume the MEASURE PlanInput (no self-drive this tick)."; return 0; }
	pi_now="$(jq -r '.now // empty' "$pi" 2>/dev/null)"
	pi_epoch="$(date -u -d "$pi_now" +%s 2>/dev/null || echo 0)"
	now_epoch="$(date -u +%s)"
	age=$(( now_epoch - pi_epoch ))
	if [ -z "$pi_now" ] || [ "$pi_epoch" -eq 0 ] || [ "$age" -lt 0 ] || [ "$age" -gt "$MEASURE_PLAN_MAX_STALE_SEC" ]; then
		warn "rotation: the MEASURE PlanInput at $pi is STALE or unparseable (now='$pi_now', age=${age}s > ${MEASURE_PLAN_MAX_STALE_SEC}s) — REFUSING to self-drive off it (is mycelium-measure.service healthy?)."
		return 0
	fi
	if ( "$spine" rotate-plan "$pi" >"$plan.tmp" 2>/dev/null ) && jq -e . "$plan.tmp" >/dev/null 2>&1; then
		mv -f "$plan.tmp" "$plan"
		log "rotation: refreshed $plan from the MEASURE daemon PlanInput (self-driven; age ${age}s, act=$(jq -r '.act // false' "$plan"))."
	else
		rm -f "$plan.tmp"
		warn "rotation: rotate-plan on the MEASURE PlanInput failed — keeping the existing $plan (if any)."
	fi
}

# measure_disable (--measure-disable) — disable + remove the unit (revert to no MEASURE daemon).
measure_disable() {
	need_root
	if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would disable + remove mycelium-measure.service + mycelium-l7probe.timer"; return 0; fi
	run systemctl disable --now mycelium-l7probe.timer 2>/dev/null || true
	run systemctl disable --now mycelium-pathsig.timer 2>/dev/null || true
	run systemctl disable --now mycelium-measure.service 2>/dev/null || true
	rm -f "$(_l7probe_timer_unit)" "$(_l7probe_service_unit)" "$(_pathsig_timer_unit)" "$(_pathsig_service_unit)" "$(_measure_unit)"
	pathsig_nft_remove   # remove the passive observer nft table + baseline (RP-0014 chunk B)
	run systemctl daemon-reload
	log "measure: mycelium-measure.service + mycelium-l7probe.timer + mycelium-pathsig.timer DISABLED + removed; the node no longer assembles a PlanInput or observes L7/path-level signals."
}
