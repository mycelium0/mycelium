# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_observability.sh — node-bootstrap library: node-local metrics wiring — a pinned, checksum-verified
# node_exporter bound to loopback (install_node_exporter), its hardened systemd unit
# (render_node_exporter_unit), the tiny data-plane unit-active textfile metric generator + timer
# (write_dataplane_metrics_generator), and the setup orchestration (setup_observability).
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: stand up node-local observability (Phase 0) — a PINNED, checksum-verified
# node_exporter bound to loopback (the host firewall opens NO port for it; Prometheus scrapes it over an
# SSH tunnel), plus a tiny textfile metric mycelium_dataplane_unit_active{engine="singbox"} so the
# SingBoxDown alert can fire. Pure measurement; no PII (host metrics + a 0/1 unit-state gauge). Mirrors
# the observability Ansible role + group_vars (the SHA256 values are PUBLIC release checksums). flow_update
# never calls this — only flow_bootstrap does.
# CLASSIFICATION: OS-glue (metrics wiring) — package/unit/systemd plumbing, correctly bash; not an
# RP-0008 Go-migration candidate. This file is meant to be SOURCED into scripts/node-bootstrap.sh, never
# executed directly; it defines functions + their dedicated NODE_EXPORTER_* constants only and relies on
# the entrypoint's shared globals (DO_OBSERVABILITY — the arg-parse --no-observability flag, set + propagated
# through the --update re-exec by the orchestrator — and DRY_RUN) and helpers (log/warn/die/have/run/
# need_root) being defined at call time. flow_bootstrap calls setup_observability; that call resolves at
# runtime from the shared sourced scope. Behaviour is byte-identical to the inline definitions it replaced.
#
# NOTE — the node_exporter unit's RestrictAddressFamilies (AF_INET AF_INET6 AF_UNIX, no AF_NETLINK) is a
# loopback-only host-metric reader, correctly distinct from the sing-box/xray engine units that
# tests/conformance/unit_netlink_parity.sh requires AF_NETLINK on; this lib is deliberately NOT in that
# gate's engine-unit source list.

# node_exporter (host metrics) — pinned public release, loopback-only (scraped over an SSH tunnel, the
# host firewall opens NO port for it). Plus a tiny textfile metric mycelium_dataplane_unit_active so the
# SingBoxDown alert can fire. Pins + layout mirror infra/ansible/roles/observability + group_vars; the
# SHA256 values are PUBLIC release checksums (committable). These constants are dedicated to this path
# (used ONLY by the functions below); dependency_policy.sh reads NODE_EXPORTER_VERSION from this lib.
NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_DL_BASE="https://github.com/prometheus/node_exporter/releases/download"
NODE_EXPORTER_SHA256_amd64="6809dd0b3ec45fd6e992c19071d6b5253aed3ead7bf0686885a51d85c6643c66"
NODE_EXPORTER_SHA256_arm64="627382b9723c642411c33f48861134ebe893e70a63bcc8b3fc0619cd0bfac4be"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"
NODE_EXPORTER_LISTEN="127.0.0.1:9100"
NODE_EXPORTER_TEXTFILE_DIR="/var/lib/node_exporter/textfile"

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

# record_converge_ok — stamp a successful unattended converge and publish it, from the code that OWNS
# the fact (Audit-0009 X1). Best-effort: never fails the caller.
#
# WHY NOT THE DATAPLANE GENERATOR. The first attempt put this metric in the generator heredoc, and it
# would never have reached a single existing node: that script is written by setup_observability, which
# runs in flow_bootstrap ONLY. Verified on the canary — the installed generator was still the copy written
# at bootstrap on 2026-06-13. That is exactly the defect AC1 names (a control-plane artifact written once
# by its verb and never reconciled), and the fix walked straight into it. Writing the metric where the
# fact is produced needs no generator refresh and works on every node from the first tick.
#
# Same shape as record_bundle_served_age (nb_serve_bundle.sh) — a per-concern .prom owned by its producer.
# It lands in the directory node_exporter is actually pointed at, with a fallback to STATE_DIR when that
# directory does not exist, so a node without the exporter still keeps the stamp the on-node drill reads.
# Loopback-only exporter, no new surface, no central collector (ADR-0021).
# record_l7_verdict MARKER — export the L7 liveness verdict the probe just computed, from the code that
# OWNS it. Best-effort; never fails the caller.
#
# THE GAP THIS CLOSES (Audit-0009 V3). The client-dead verdict is computed continuously — the l7probe timer
# writes $STATE_DIR/l7_selftest.json every couple of minutes — and NOTHING read it. Observability exported
# a single `mycelium_dataplane_unit_active` gauge, which stays 1 while the node serves a config no client
# can use; the nearest Prometheus alert keys on blackbox OUTER-TLS probe_success, which succeeds against
# any bound listener. So the one signal that can tell a serving node from a bound-but-dead one existed only
# in a local JSON file nobody read, and a bad push accepted identically on every node inside one 15-minute
# window left every node's emitted signal green.
#
# WRITTEN BY THE PROBE, NOT BY THE GENERATOR. The dataplane generator is written once by
# setup_observability at bootstrap and never reconciled, so a metric added there would never reach an
# existing node — the exact trap the X1 fix walked into and had to be moved out of. This runs wherever the
# probe runs.
#
# LABELS: only closed-vocab MEASURE class refs (`vless-reality-vision`, `shadowsocks`, …) — the same
# category as the existing engine="singbox" label, and never a client, address or peer.
record_l7_verdict() {
	local marker="${1:-}"
	[ "${DRY_RUN:-0}" -eq 1 ] && return 0
	[ -n "$marker" ] && [ -f "$marker" ] || return 0
	have jq || return 0
	local dir out ts checked ndead nunknown
	dir="${NODE_EXPORTER_TEXTFILE_DIR:-}"; [ -n "$dir" ] && [ -d "$dir" ] || dir="$STATE_DIR"
	out="$dir/mycelium_l7.prom"
	ts="$(date +%s 2>/dev/null)" || return 0
	checked="$(jq -r '.checked // 0'          "$marker" 2>/dev/null || printf 0)"
	ndead="$(jq -r '(.dead // [])    | length' "$marker" 2>/dev/null || printf 0)"
	nunknown="$(jq -r '(.unknown // []) | length' "$marker" 2>/dev/null || printf 0)"
	{
		printf '# HELP mycelium_l7_last_observation_timestamp_seconds Unix time of the last L7 liveness observation.\n'
		printf '# TYPE mycelium_l7_last_observation_timestamp_seconds gauge\n'
		printf 'mycelium_l7_last_observation_timestamp_seconds %s\n' "$ts"
		printf '# HELP mycelium_l7_checked Served transport classes the last L7 observation looked at.\n'
		printf '# TYPE mycelium_l7_checked gauge\n'
		printf 'mycelium_l7_checked %s\n' "${checked:-0}"
		printf '# HELP mycelium_l7_dead Served transport classes a real client could NOT handshake (positive evidence).\n'
		printf '# TYPE mycelium_l7_dead gauge\n'
		printf 'mycelium_l7_dead %s\n' "${ndead:-0}"
		# Unknown is exported SEPARATELY and never folded into dead: "we could not tell" must not read as
		# either a fault or an all-clear (Audit-0009 B1). An operator watching coverage watches this.
		printf '# HELP mycelium_l7_unknown Served transport classes the last observation could not judge.\n'
		printf '# TYPE mycelium_l7_unknown gauge\n'
		printf 'mycelium_l7_unknown %s\n' "${nunknown:-0}"
		printf '# HELP mycelium_l7_transport_dead 1 for a served class the last observation found client-dead.\n'
		printf '# TYPE mycelium_l7_transport_dead gauge\n'
		jq -r '(.dead // [])[] | "mycelium_l7_transport_dead{ref=\"" + . + "\"} 1"' "$marker" 2>/dev/null || true
	} >"$out.tmp" 2>/dev/null && { chmod 0644 "$out.tmp" 2>/dev/null || true; mv -f "$out.tmp" "$out" 2>/dev/null || true; }
	rm -f "$out.tmp" 2>/dev/null || true
	return 0
}

record_converge_ok() {
	[ "${DRY_RUN:-0}" -eq 1 ] && return 0
	local now dir out
	now="$(date +%s 2>/dev/null)" || return 0
	case "$now" in ''|*[!0-9]*) return 0 ;; esac
	printf '%s\n' "$now" > "$STATE_DIR/last_converge_ok" 2>/dev/null || true
	dir="$NODE_EXPORTER_TEXTFILE_DIR"; [ -d "$dir" ] || dir="$STATE_DIR"
	out="$dir/mycelium_update.prom"
	{
		printf '# HELP mycelium_update_last_success_timestamp_seconds Unix time of the last successful unattended converge; 0 = never.\n'
		printf '# TYPE mycelium_update_last_success_timestamp_seconds gauge\n'
		printf 'mycelium_update_last_success_timestamp_seconds %s\n' "$now"
	} >"$out.tmp" 2>/dev/null && { chmod 0644 "$out.tmp" 2>/dev/null || true; mv -f "$out.tmp" "$out" 2>/dev/null || true; }
	rm -f "$out.tmp" 2>/dev/null || true
	return 0
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
	# SEED THE MONOTONIC ANCHOR (Audit-0009 D1) — see the note on mycelium-rotate.timer. OnUnitActiveSec=
	# schedules relative to the last time the SERVICE was active, and this 15s cadence has no OnCalendar=
	# expression, so the seeded-anchor form is the one available here. Without it the timer carries the
	# same never-fires exposure the update timer actually landed in — and a frozen exporter gauge is
	# indistinguishable from a healthy one. After the enable, so the unit is loaded.
	run systemctl start mycelium-dataplane-metrics.service 2>/dev/null || true
	log "node_exporter on $NODE_EXPORTER_LISTEN (loopback) + mycelium_dataplane_unit_active active."
}
