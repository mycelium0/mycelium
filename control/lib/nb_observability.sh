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
	log "node_exporter on $NODE_EXPORTER_LISTEN (loopback) + mycelium_dataplane_unit_active active."
}
