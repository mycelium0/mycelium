# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# nb_harden.sh — node-bootstrap library: host hardening (journald / sshd / ufw).
# Author: mindicator & silicon bags quartet.
#
# SINGLE RESPONSIBILITY: harden the HOST — volatile (RAM-only) journald, key-only sshd with an
# anti-lockout guard, and a default-deny ufw firewall that opens exactly the enabled canonical
# ports plus the live sshd port. CLASSIFICATION: OS-glue — it manipulates systemd drop-ins, sshd
# config, and the host firewall directly; idempotent and fail-closed. This file is meant to be
# SOURCED into scripts/node-bootstrap.sh, never executed directly; it defines functions only and
# relies on the entrypoint's shared globals (DRY_RUN, SINGBOX_CONFIG, DO_AMNEZIAWG, STATE_DIR) and
# helpers (log/warn/die/have/run/need_root) being defined at call time. Behaviour is byte-identical
# to the inline definitions it replaced.

harden_journald() {
	log "configuring journald (volatile storage)"
	need_root
	local dropin="/etc/systemd/journald.conf.d/10-mycelium-volatile.conf"
	run mkdir -p "$(dirname "$dropin")"
	if [ "$DRY_RUN" -eq 0 ]; then
		cat >"$dropin" <<'CONF'
# Managed by Mycelium node-bootstrap. Volatile journald: logs live in RAM and do not persist
# across reboots (less on-disk forensic residue; smaller writable footprint).
[Journal]
Storage=volatile
RuntimeMaxUse=64M
ForwardToSyslog=no
CONF
	fi
	# The no-logs posture must actually HOLD, not merely be configured: a persistent /var/log/journal
	# overrides Storage=volatile, so remove it — RAM-only, no on-disk forensic residue (SECURITY.md).
	[ "$DRY_RUN" -eq 0 ] && [ -d /var/log/journal ] && run rm -rf /var/log/journal
	# FAIL-CLOSED: a failed restart or a journal that is not actually volatile must abort the bootstrap,
	# not warn-and-continue — the claimed no-logs posture cannot be allowed to silently not hold.
	if ! run systemctl restart systemd-journald; then
		die "journald failed to restart after the volatile drop-in (fail-closed): inspect $dropin"
	fi
	if [ "$DRY_RUN" -eq 0 ]; then
		systemctl is-active --quiet systemd-journald || die "systemd-journald not active after restart (fail-closed)."
		[ -d /var/log/journal ] && die "persistent /var/log/journal remains — volatile journald not in effect (fail-closed)."
		log "journald is volatile (RAM-only); no persistent journal directory."
	fi
}

harden_sshd() {
	log "hardening sshd (key-only) with an anti-lockout guard"
	need_root
	# ANTI-LOCKOUT: only switch to key-only auth AFTER confirming at least one authorized key
	# exists for a login account. Otherwise we would lock the operator out — fail-closed by NOT
	# applying the change. We enumerate EVERY real account home from getent passwd (not just
	# /root + /home/*), so users with non-standard home dirs are covered, and we also honor an
	# AuthorizedKeysFile override from the effective sshd config.
	local has_key=0 akf home akpath
	# Resolve the configured AuthorizedKeysFile pattern(s); default to the standard locations.
	akf="$(sshd -T 2>/dev/null | sed -n 's/^authorizedkeysfile[[:space:]]*//p' | head -n1)"
	[ -n "$akf" ] || akf=".ssh/authorized_keys .ssh/authorized_keys2"
	# Candidate homes: root + every account that has a real home directory.
	while IFS=: read -r _u _p _uid _gid _gecos home _shell; do
		[ -n "${home:-}" ] || continue
		[ -d "$home" ] || continue
		local f
		for f in $akf; do
			case "$f" in
				/*) akpath="$f" ;;                 # absolute pattern: use as-is
				*)  akpath="$home/$f" ;;           # relative pattern: anchored at the home dir
			esac
			# %u/%h tokens in the pattern -> resolve to this account.
			akpath="${akpath//%h/$home}"
			akpath="${akpath//%u/$_u}"
			[ -f "$akpath" ] || continue
			if grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-|sk-)' "$akpath" 2>/dev/null; then
				has_key=1; break 2
			fi
		done
	done < <(getent passwd 2>/dev/null || true)
	if [ "$has_key" -ne 1 ]; then
		warn "no authorized SSH key found in any account — REFUSING to disable password auth"
		warn "(anti-lockout guard). Add your public key first, then re-run."
		return 0
	fi
	local dropin="/etc/ssh/sshd_config.d/10-mycelium.conf"
	run mkdir -p "$(dirname "$dropin")"
	if [ "$DRY_RUN" -eq 0 ]; then
		cat >"$dropin" <<'CONF'
# Managed by Mycelium node-bootstrap. Key-only SSH: no passwords, no challenge-response, no root
# password login. An authorized key was confirmed present before this was applied (anti-lockout).
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM yes
CONF
	fi
	# Validate the config BEFORE reloading; a broken sshd config must never take down access.
	if [ "$DRY_RUN" -eq 0 ]; then
		sshd -t 2>/dev/null || { warn "sshd -t failed; reverting drop-in (fail-closed)."; rm -f "$dropin"; return 0; }
	fi
	run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null \
		|| warn "could not reload sshd (continuing)."
}

harden_ufw() {
	log "configuring the host firewall (ufw) for the enabled canonical ports"
	need_root
	have ufw || { warn "ufw not installed; skipping firewall step (install ufw to enable)."; return 0; }
	# Default deny inbound; allow SSH first (anti-lockout) then ONLY the enabled protocols' ports.
	run ufw --force default deny incoming
	run ufw --force default allow outgoing
	# ANTI-LOCKOUT: never assume port 22. Open EXACTLY the port(s) the running sshd actually listens
	# on (parsed from the effective config), so enabling ufw cannot cut the live session even when
	# the operator runs sshd on a non-standard port.
	local ssh_ports sp opened_ssh=0
	ssh_ports="$(sshd -T 2>/dev/null | sed -n 's/^port[[:space:]]*//p' | sort -u)"
	if [ -n "$ssh_ports" ]; then
		for sp in $ssh_ports; do
			[ -n "$sp" ] || continue
			run ufw allow "$sp/tcp" && opened_ssh=1
			log "allowed the live sshd port $sp/tcp before enabling the firewall (anti-lockout)."
		done
	fi
	if [ "$opened_ssh" -ne 1 ]; then
		# Could not determine the sshd port (sshd -T unavailable): fall back to the standard profile,
		# but warn loudly — a non-standard live port could be cut.
		warn "could not detect the live sshd port; falling back to OpenSSH/22. If sshd runs on a"
		warn "non-standard port, allow it manually BEFORE 'ufw enable' to avoid a lockout."
		run ufw allow OpenSSH 2>/dev/null || run ufw allow 22/tcp
	fi
	# Canonical ports come from the rendered config (the single source of truth at runtime). We
	# read the live config's listen_port set so the firewall opens EXACTLY what is enabled.
	local enabled_tcp enabled_udp
	enabled_tcp=""; enabled_udp=""
	if [ -f "$SINGBOX_CONFIG" ] && have jq; then
		enabled_tcp="$(jq -r '
			[.inbounds[]? | select(.listen_port != null)
			 | select(.type=="vless" or .type=="trojan" or .type=="shadowtls"
			          or (.type=="shadowsocks" and (.listen|test("127\\.0\\.0\\.1")|not)))
			 | .listen_port] | unique | .[]' "$SINGBOX_CONFIG" 2>/dev/null | tr '\n' ' ')"
		enabled_udp="$(jq -r '
			[.inbounds[]? | select(.listen_port != null)
			 | select(.type=="hysteria2" or .type=="tuic") | .listen_port] | unique | .[]' \
			"$SINGBOX_CONFIG" 2>/dev/null | tr '\n' ' ')"
		# Shadowsocks-2022 opens BOTH tcp and udp on its port.
		local ss_port
		ss_port="$(jq -r '.inbounds[]? | select(.tag=="shadowsocks-in") | .listen_port // empty' "$SINGBOX_CONFIG" 2>/dev/null)"
		[ -n "$ss_port" ] && enabled_udp="$enabled_udp $ss_port"
	fi
	local p
	for p in $enabled_tcp; do run ufw allow "$p/tcp"; done
	for p in $enabled_udp; do run ufw allow "$p/udp"; done
	# ADR-0032 dual-engine: the xray engine serves from a SEPARATE config (XRAY_CONFIG), so its listen
	# ports are not in the sing-box config the loop above read. Open them too (xray inbounds key on
	# `.port`; the xhttp-tls family is TCP). A stock node has no XRAY_CONFIG, so this opens nothing.
	if [ -n "${XRAY_CONFIG:-}" ] && [ -f "$XRAY_CONFIG" ] && have jq; then
		local xray_tcp
		xray_tcp="$(jq -r '[.inbounds[]? | select(.port != null) | .port] | unique | .[]' "$XRAY_CONFIG" 2>/dev/null | tr '\n' ' ')"
		for p in $xray_tcp; do run ufw allow "$p/tcp"; done
	fi
	# AmneziaWG UDP port (its conventional canon port; the actual value is operator/runtime).
	if [ "$DO_AMNEZIAWG" -eq 1 ] && [ -f "$STATE_DIR/awg.port" ]; then
		run ufw allow "$(cat "$STATE_DIR/awg.port")/udp"
	fi
	run ufw --force enable
}
