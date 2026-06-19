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
# time. NB: ARTIFACT_ROOT (not REPO_ROOT) is the canonical source for install_tooling AND install_spine
# — after the --update re-exec REPO_ROOT points at a tmp copy's parent that has no control/ or go.mod/cmd
# tree. install_spine additionally builds the Go spine binary onto disk: $TOOLING_DIR/bin/myceliumctl-go
# (the compiled control CLI, inert in RP-0008 P3 chunk 1) + $TOOLING_DIR/.gocache (a node-local build
# cache). Behaviour of the pre-existing functions is byte-identical to the inline definitions it replaced.

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

# node_needs_xray — true iff params enables any xray-ENGINE transport. Reads the closed registry
# (control/vocab.json) for the engine map + the enable_key (single source, never a bash convention —
# §2.2 #8). This GATES install_xray + the xray unit: default-off => no xray on a stock node (the
# ADR-0032 per-protocol opt-in; the only xray-engine proto today is vless-xhttp-tls).
node_needs_xray() {
	local vocab; vocab="${MYC_VOCAB:-${ARTIFACT_ROOT:-${REPO_ROOT:-.}}/control/vocab.json}"
	[ -f "$vocab" ] && [ -f "$PARAMS_JSON" ] || return 1
	have jq || return 1
	local n
	n="$(jq -r --slurpfile p "$PARAMS_JSON" \
		'[ .protos[] | select(.engine == "xray") | select($p[0][.enable_key] == true) ] | length' \
		"$vocab" 2>/dev/null || echo 0)"
	[ "${n:-0}" -ge 1 ]
}

# install_xray — install xray-core, pinned + checksum-verified (ADR-0032 dual-engine; the peer of
# install_singbox). Called ONLY when node_needs_xray (an xray-engine transport is enabled), so a stock
# node installs no xray. Xray ships a .zip (not a tar.gz) whose root holds the `xray` binary. Fail-closed
# pins (--xray-version / --xray-sha256), honouring the ADR-0028 currency floor (>= v26.3.27). Idempotent.
install_xray() {
	log "ensuring xray-core is installed (pinned + checksum-verified) — an xray-engine transport is enabled"
	need_root
	if have "$XRAY_BIN"; then
		local cur
		cur="$("$XRAY_BIN" version 2>/dev/null | sed -n 's/^Xray[[:space:]]*//p' | awk '{print $1}' | head -n1)"
		if [ -n "$XRAY_VERSION" ] && printf '%s' "$cur" | grep -q "${XRAY_VERSION#v}"; then
			log "xray ${XRAY_VERSION} already installed; skipping."
			return 0
		fi
	fi
	[ -n "$XRAY_VERSION" ] || die "--xray-version is required to install xray (an xray-engine transport is enabled; fail-closed pin)."
	[ -n "$XRAY_SHA256" ]  || die "--xray-sha256 is required to install xray (fail-closed pin)."
	have curl || have wget || die "need curl or wget to download xray."
	have unzip || die "need unzip to unpack the xray release (Xray ships a .zip)."

	# Map machine arch -> the xray release archive arch token (note: distinct from sing-box's tokens).
	local march arch
	march="$(uname -m)"
	case "$march" in
		x86_64|amd64) arch="64" ;;
		aarch64|arm64) arch="arm64-v8a" ;;
		armv7l) arch="arm32-v7a" ;;
		*) die "unsupported architecture for the xray release: $march" ;;
	esac
	local archive="Xray-linux-${arch}.zip"
	local url="$XRAY_DL_BASE/${XRAY_VERSION}/${archive}"
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
		[ "$got" = "$XRAY_SHA256" ] \
			|| die "xray checksum MISMATCH (got $got, expected $XRAY_SHA256) — refusing to install."
		log "checksum verified: $got"
	fi

	run unzip -o -q "$tmp/$archive" xray -d "$tmp"
	[ "$DRY_RUN" -eq 1 ] || [ -f "$tmp/xray" ] || die "release layout unexpected: the xray binary is not at the root of $archive."
	run install -m 0755 "$tmp/xray" "$XRAY_BIN"
	log "installed xray to $XRAY_BIN"
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

# apply_singbox — the flow-level apply primitive the update/revoke paths call to make the running
# service pick up a new config. sing-box is Type=simple with NO ExecReload, so there is no real
# "reload": applying a config IS a restart (it briefly drops live connections). We do not pretend
# otherwise. Returns the restart's own status so callers can distinguish a failed restart from a
# failed post-check. (RP-0009 C5: moved here next to restart_singbox so the entrypoint is
# orchestration-only.)
apply_singbox() { need_root; run systemctl enable sing-box 2>/dev/null || true; run systemctl restart sing-box; }

# install_xray_unit — the hardened xray.service for the OPTIONAL secondary engine (ADR-0032 dual-engine).
# Peer of install_singbox_unit; kept in lockstep with infra/ansible/roles/xray/templates/xray.service.j2
# (the AF_NETLINK directive is pinned by tests/conformance/unit_netlink_parity.sh — change BOTH together).
# Two differences from the sing-box unit: (1) ExecStartPre runs `xray run -test` so a config xray cannot
# parse FAILS THE START rather than crash-looping (fail-closed start, the unit-level peer of the pre-promote
# validate_xray_config gate); (2) xray writes nothing at runtime, so there is no -D run dir and no
# ReadWritePaths. Installs the unit DISABLED (daemon-reload only); apply_xray is what enables+starts it,
# and that is reached only under the node_needs_xray guard.
install_xray_unit() {
	log "installing the xray systemd unit (optional secondary engine)"
	need_root
	local unit="/etc/systemd/system/xray.service"
	if [ "$DRY_RUN" -eq 0 ]; then
		cat >"$unit" <<UNIT
[Unit]
Description=Mycelium Xray data plane (vless-xhttp-tls; OPTIONAL secondary engine)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$XRAY_RUN_USER
Group=$XRAY_RUN_GROUP
ExecStartPre=$XRAY_BIN run -test -config $XRAY_CONFIG
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=$XRAY_ETC
ReadWritePaths=
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
# AF_NETLINK is REQUIRED: xray subscribes to route/interface updates via rtnetlink at startup; without it
# xray FATALs and the service crash-loops. Keep in lockstep with the sing-box unit (unit_netlink_parity.sh).
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

restart_xray() { need_root; run systemctl enable --now xray 2>/dev/null || true; run systemctl restart xray; }

# apply_xray — the flow-level apply primitive for the xray engine (peer of apply_singbox). xray is
# Type=simple with no live reload of a new config file, so applying a config IS a restart. The unit's
# ExecStartPre `xray run -test` re-validates at start, so a bad config refuses to start (fail-closed).
apply_xray() { need_root; run systemctl enable xray 2>/dev/null || true; run systemctl restart xray; }

install_tooling() {
	log "installing control tooling to $TOOLING_DIR"
	need_root
	run install -d -m 0755 "$TOOLING_DIR"
	# Source the control/ tooling from ARTIFACT_ROOT (the real checkout), NOT REPO_ROOT: after the
	# update re-exec REPO_ROOT points at the tmp copy's parent, which has no control/ tree.
	run cp -a "$ARTIFACT_ROOT/control" "$TOOLING_DIR/" 2>/dev/null || run cp -aR "$ARTIFACT_ROOT/control" "$TOOLING_DIR/"
	# Build + install the (inert) Go control-plane binary alongside the shell tooling. This is the one
	# function both flow_bootstrap and flow_update already call, so the spine binary tracks every
	# deployed rev. install_spine is non-fatal by design (RP-0008 P3 chunk 1): a missing toolchain or a
	# failed build must never break a working update over a binary nothing yet depends on.
	install_spine
	# Re-point MYCTL at the installed copy if it now exists. Guard the trailing status: a missing
	# installed copy (e.g. under --dry-run, where the cp above is a no-op) must NOT make this function
	# return non-zero and trip `set -e` in the caller — we simply keep the existing MYCTL fallback.
	# NB (RP-0008 P3 chunk 1): MYCTL stays the SHELL tool. The compiled myceliumctl-go is installed but
	# non-load-bearing; a later strangler chunk adds it as an additive render path once gated equivalent.
	if [ -x "$TOOLING_DIR/control/myceliumctl" ]; then
		MYCTL="$TOOLING_DIR/control/myceliumctl"
	fi
	return 0
}

# install_spine — build + install the Go control-plane binary (myceliumctl-go, from cmd/myceliumctl) out
# of the JUST-FETCHED source into $TOOLING_DIR/bin, so the ADR-0012 Go spine is render-time-resident for
# the RP-0008 P3 strangler. INERT in chunk 1: nothing resolves to it for rendering yet (MYCTL stays the
# shell tool), so a missing toolchain or a failed build only WARNs — the shell control tool, copied by
# install_tooling just above, stays authoritative (RP-0008 strangler doctrine: any Go failure degrades TO
# the shell, never bricks the deployed --update path; this deliberately DIVERGES from install_awg_tools'
# die, which has no fallback). Idempotent: skips when the installed binary already self-reports the
# deployed source rev (stamped via -ldflags -X spec.SourceRev), so a node never serves a STALE binary
# after an --update yet does not rebuild needlessly. Called from install_tooling -> runs on BOTH bootstrap
# and --update. Offline: the module has ZERO external deps, so GOPROXY/GOSUMDB are pinned off as a hard
# guard (an accidental fetch fails fast instead of hanging where outbound network is unavailable). The Go toolchain is a base dep on
# bootstrap; the timer-driven update never runs install_base_deps, so `have go` must gate the build.
install_spine() {
	have go || { warn "Go toolchain absent; skipping the (inert) myceliumctl-go build — the shell control tool remains authoritative."; return 0; }
	need_root
	local rev cur
	rev="$(git -C "$ARTIFACT_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
	run install -d -m 0755 "$TOOLING_DIR/bin"
	# The timer-driven --update runs under systemd with an EMPTY environment (Environment=, no HOME). `go
	# build` needs HOME to resolve its default GOPATH / GOENV; without it, internal-package import
	# resolution fails with an empty-path error ("could not import internal/rotate: open : no such file")
	# and the spine silently never rebuilt (the warn-not-die fallback masked it). Pin a node-local HOME +
	# GOPATH so the build is independent of the (absent) service environment.
	run install -d -m 0700 "$TOOLING_DIR/.gohome"
	# Build BOTH Go binaries from the fetched source: the control CLI (myceliumctl-go — the RP-0008
	# strangler, shell tool stays authoritative) and the daemon (myceliumd — the RP-0010 MEASURE-plane
	# host). BOTH are inert on a stock node: myceliumd RUNS only when an operator enables
	# mycelium-measure.service (RP-0010 C5c — the unit ships disabled, written only by --measure-enable),
	# so building it always is harmless. A missing toolchain / failed build WARNs, never dies (strangler
	# doctrine: degrade to the shell, never brick the --update path).
	local entry name pkg bin
	for entry in "myceliumctl-go:./cmd/myceliumctl" "myceliumd:./cmd/myceliumd"; do
		name="${entry%%:*}"; pkg="${entry##*:}"; bin="$TOOLING_DIR/bin/$name"
		# Idempotency: skip only when a PRESENT binary self-reports the deployed rev (existence test
		# first; the version call may fail). rev=unknown (tarball deploy) -> never matches -> rebuild (safe).
		if [ "$rev" != unknown ] && [ -x "$bin" ]; then
			cur="$("$bin" version 2>/dev/null)" || true
			if printf '%s' "$cur" | grep -qF "$rev"; then
				log "$name already built from rev $rev; skipping."
				continue
			fi
		fi
		if [ "$DRY_RUN" -eq 1 ]; then
			log "[dry-run] would build + install $name: go build -o $bin $pkg (rev $rev)."
			continue
		fi
		# `if ( ... ); then` neutralises set -e for the build subshell, so a failure lands in the warn
		# branch instead of aborting the update. CGO_ENABLED=0 -> static pure-Go binary (no libc/gcc
		# surprises across node distros); -trimpath strips the checkout path (reproducibility + no-PII);
		# GOCACHE is a stable node-local cache so repeated updates are fast incremental rebuilds.
		if ( cd "$ARTIFACT_ROOT" && HOME="$TOOLING_DIR/.gohome" GOPATH="$TOOLING_DIR/.gopath" \
				GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off CGO_ENABLED=0 GOCACHE="$TOOLING_DIR/.gocache" \
				go build -trimpath -ldflags "-buildid= -X github.com/mycelium0/mycelium/internal/spec.SourceRev=$rev" \
				-o "$bin" "$pkg" ); then
			log "built + installed $name -> $bin (rev $rev; inert until enabled, shell tool stays authoritative)"
		else
			warn "$name build failed (rev $rev); the node continues on the shell control tool (the binary is inert)."
		fi
	done
	return 0
}

# install_base_deps — ensure the OS packages a from-zero node needs are present so a fresh-VPS
# bootstrap needs no manual fixups (Audit-0004 D4): git (fetch/verify), jq (identity/params/render),
# iptables (AmneziaWG PostUp NAT), ufw (host firewall), curl/ca-certificates/tar/unzip
# (download + unpack), and golang-go (the Go toolchain that compiles the control-plane spine binary —
# RP-0008 P3; install_spine builds from it on bootstrap). Idempotent — apt-get install is a no-op for
# already-present packages. flow_bootstrap-only (never the timer; that is why install_spine still
# `have go`-gates on the update path). apt-based hosts only; elsewhere it warns and the per-step
# `have X || die` guards downstream still fail closed.
install_base_deps() {
	need_root
	if ! have apt-get; then
		warn "no apt-get on this host — install 'git jq iptables ufw curl ca-certificates tar unzip golang-go' by hand; the per-step guards fail closed if any are missing."
		return 0
	fi
	log "ensuring base packages (git jq iptables ufw curl ca-certificates tar unzip golang-go)"
	run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; installing against cached lists."
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git jq iptables ufw curl ca-certificates tar unzip golang-go \
		|| die "base package install failed — install git/jq/iptables/ufw/curl/ca-certificates/tar/unzip/golang-go and re-run."
}
