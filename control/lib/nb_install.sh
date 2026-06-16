# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_install.sh — node-bootstrap library: package / engine install + service unit + control tooling.
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: install everything the data plane needs on the host — base OS packages, a
# PINNED + checksum-verified sing-box, the unprivileged sing-box system user + canonical dirs, the
# per-node self-signed cert, the hardened sing-box systemd unit (+ restart), and the control/
# tooling copy. CLASSIFICATION: OS-glue — apt/curl/tar/install/systemctl/openssl wiring; idempotent
# and fail-closed (pins are required). This file is meant to be SOURCED into
# scripts/node-bootstrap.sh, never executed directly; it defines functions only and relies on the
# entrypoint's shared globals (SINGBOX_BIN, SINGBOX_VERSION, SINGBOX_SHA256, SINGBOX_DL_BASE,
# SINGBOX_RUN_USER, SINGBOX_RUN_GROUP, SINGBOX_ETC, SINGBOX_CONFIG, STATE_DIR, TLS_DIR, TOOLING_DIR,
# ARTIFACT_ROOT, MYCTL, DRY_RUN) and helpers (log/warn/die/have/run/need_root) being defined at call
# time. NB: ARTIFACT_ROOT (not REPO_ROOT) is the canonical source for install_tooling — after the
# --update re-exec REPO_ROOT points at a tmp copy's parent that has no control/ tree.
# Behaviour is byte-identical to the inline definitions it replaced.

install_singbox() {
	log "ensuring sing-box is installed (pinned + checksum-verified)"
	need_root
	if have "$SINGBOX_BIN"; then
		local cur
		cur="$("$SINGBOX_BIN" version 2>/dev/null | sed -n 's/.*version[[:space:]]*//p' | head -n1)"
		if [ -n "$SINGBOX_VERSION" ] && printf '%s' "$cur" | grep -q "${SINGBOX_VERSION#v}"; then
			log "sing-box ${SINGBOX_VERSION} already installed; skipping."
			ensure_singbox_user
			return 0
		fi
	fi
	[ -n "$SINGBOX_VERSION" ] || die "--singbox-version is required to install sing-box (fail-closed pin)."
	[ -n "$SINGBOX_SHA256" ]  || die "--singbox-sha256 is required to install sing-box (fail-closed pin)."
	have curl || have wget || die "need curl or wget to download sing-box."
	have tar  || die "need tar to unpack the sing-box release."

	# Map machine arch -> the release archive arch token.
	local march arch
	march="$(uname -m)"
	case "$march" in
		x86_64|amd64) arch="amd64" ;;
		aarch64|arm64) arch="arm64" ;;
		armv7l) arch="armv7" ;;
		*) die "unsupported architecture for the sing-box release: $march" ;;
	esac
	local ver="${SINGBOX_VERSION#v}"
	local archive="sing-box-${ver}-linux-${arch}.tar.gz"
	local url="$SINGBOX_DL_BASE/${SINGBOX_VERSION}/${archive}"
	local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

	log "downloading $url"
	if have curl; then
		run curl -fsSL "$url" -o "$tmp/$archive" || die "download failed: $url"
	else
		run wget -qO "$tmp/$archive" "$url" || die "download failed: $url"
	fi

	# FAIL-CLOSED checksum verification against the operator-supplied pin.
	if [ "$DRY_RUN" -eq 0 ]; then
		local got
		if have sha256sum; then
			got="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
		else
			got="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"
		fi
		[ "$got" = "$SINGBOX_SHA256" ] \
			|| die "sing-box checksum MISMATCH (got $got, expected $SINGBOX_SHA256) — refusing to install."
		log "checksum verified: $got"
	fi

	run tar -xzf "$tmp/$archive" -C "$tmp"
	local extracted="$tmp/sing-box-${ver}-linux-${arch}/sing-box"
	[ "$DRY_RUN" -eq 1 ] || [ -f "$extracted" ] || die "release layout unexpected: $extracted not found."
	run install -m 0755 "$extracted" "$SINGBOX_BIN"
	log "installed sing-box to $SINGBOX_BIN"
	ensure_singbox_user
}

ensure_singbox_user() {
	# Create the unprivileged system user/group + canonical dirs idempotently.
	need_root
	if ! getent group "$SINGBOX_RUN_GROUP" >/dev/null 2>&1; then
		run groupadd --system "$SINGBOX_RUN_GROUP"
	fi
	if ! id "$SINGBOX_RUN_USER" >/dev/null 2>&1; then
		run useradd --system --gid "$SINGBOX_RUN_GROUP" --no-create-home \
			--shell /usr/sbin/nologin "$SINGBOX_RUN_USER"
	fi
	run install -d -m 0755 "$SINGBOX_ETC"
	run install -d -m 0710 -o root -g "$SINGBOX_RUN_GROUP" "$STATE_DIR"
	run install -d -m 0750 -o root -g "$SINGBOX_RUN_GROUP" "$TLS_DIR"
	run install -d -m 0750 -o "$SINGBOX_RUN_USER" -g "$SINGBOX_RUN_GROUP" "$STATE_DIR/run"
}

ensure_self_signed_cert() {
	# ensure_self_signed_cert CN — per-node self-signed cert + key under TLS_DIR (ADR-0014).
	local cn="$1"
	have openssl || die "openssl required to issue the per-node self-signed cert."
	[ -f "$TLS_DIR/fullchain.pem" ] && [ -f "$TLS_DIR/privkey.pem" ] && { log "self-signed cert already present."; return 0; }
	log "issuing per-node self-signed cert (CN=donor) via openssl"
	run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout "$TLS_DIR/privkey.pem" -out "$TLS_DIR/fullchain.pem" \
		-days 3650 -nodes -subj "/CN=$cn" >/dev/null 2>&1 \
		|| die "openssl self-signed cert generation failed."
	# Publish the client sha256 pin (public; clients verify against it).
	if [ "$DRY_RUN" -eq 0 ]; then
		openssl x509 -in "$TLS_DIR/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null \
			| sed 's/.*=//' >"$STATE_DIR/cert.sha256.txt" || true
	fi
	run chown -R "root:$SINGBOX_RUN_GROUP" "$TLS_DIR"
	run chmod 0640 "$TLS_DIR/privkey.pem"
	run chmod 0644 "$TLS_DIR/fullchain.pem"
}

install_singbox_unit() {
	log "installing the sing-box systemd unit"
	need_root
	local unit="/etc/systemd/system/sing-box.service"
	if [ "$DRY_RUN" -eq 0 ]; then
		# Mirror the hardened unit conventions in infra/ansible/roles/singbox/templates/singbox.service.j2.
		# The two unit sources are kept in lockstep — especially RestrictAddressFamilies incl. AF_NETLINK
		# — by tests/conformance/unit_netlink_parity.sh; change BOTH together (Audit-0004 F-001/F-017).
		cat >"$unit" <<UNIT
[Unit]
Description=Mycelium sing-box data plane (multi-protocol; PRIMARY engine)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SINGBOX_RUN_USER
Group=$SINGBOX_RUN_GROUP
ExecStartPre=$SINGBOX_BIN check -c $SINGBOX_CONFIG
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONFIG -D $STATE_DIR/run
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=$SINGBOX_ETC
ReadWritePaths=$STATE_DIR/run
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
PrivateDevices=true
DevicePolicy=closed
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RemoveIPC=true
KeyringMode=private
UMask=0077
# AF_NETLINK is REQUIRED: sing-box subscribes to route/interface updates via rtnetlink at startup;
# without it sing-box FATALs ("subscribe route updates: address family not supported by protocol")
# and the service crash-loops. (node_exporter, by contrast, needs no netlink — see its unit below.)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete

[Install]
WantedBy=multi-user.target
UNIT
	fi
	run systemctl daemon-reload
}

restart_singbox() { need_root; run systemctl enable --now sing-box 2>/dev/null || true; run systemctl restart sing-box; }

install_tooling() {
	log "installing control tooling to $TOOLING_DIR"
	need_root
	run install -d -m 0755 "$TOOLING_DIR"
	# Source the control/ tooling from ARTIFACT_ROOT (the real checkout), NOT REPO_ROOT: after the
	# update re-exec REPO_ROOT points at the tmp copy's parent, which has no control/ tree.
	run cp -a "$ARTIFACT_ROOT/control" "$TOOLING_DIR/" 2>/dev/null || run cp -aR "$ARTIFACT_ROOT/control" "$TOOLING_DIR/"
	# Re-point MYCTL at the installed copy if it now exists. Guard the trailing status: a missing
	# installed copy (e.g. under --dry-run, where the cp above is a no-op) must NOT make this function
	# return non-zero and trip `set -e` in the caller — we simply keep the existing MYCTL fallback.
	if [ -x "$TOOLING_DIR/control/myceliumctl" ]; then
		MYCTL="$TOOLING_DIR/control/myceliumctl"
	fi
	return 0
}

# install_base_deps — ensure the OS packages a from-zero node needs are present so a fresh-VPS
# bootstrap needs no manual fixups (Audit-0004 D4): git (fetch/verify), jq (identity/params/render),
# iptables (AmneziaWG PostUp NAT), ufw (host firewall), and curl/ca-certificates/tar/unzip
# (download + unpack). Idempotent — apt-get install is a no-op for already-present packages.
# flow_bootstrap-only (never the timer). apt-based hosts only; elsewhere it warns and the per-step
# `have X || die` guards downstream still fail closed.
install_base_deps() {
	need_root
	if ! have apt-get; then
		warn "no apt-get on this host — install 'git jq iptables ufw curl ca-certificates tar unzip' by hand; the per-step guards fail closed if any are missing."
		return 0
	fi
	log "ensuring base packages (git jq iptables ufw curl ca-certificates tar unzip)"
	run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; installing against cached lists."
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git jq iptables ufw curl ca-certificates tar unzip \
		|| die "base package install failed — install git/jq/iptables/ufw/curl/ca-certificates/tar/unzip and re-run."
}
