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

# myc_firewall_singbox_ports <config> <tcp|udp> — PURE (no side effects): echo, one per line, the set of
# sing-box listen_ports the firewall should OPEN for the given transport family, EXCLUDING loopback-bound
# inbounds (reachable=false rebinds public inbounds to 127.0.0.1; the shadowtls detour is always loopback).
# `(.listen // "::")` keeps a MISSING listen treated as the public default "::" (so it is OPENED, matching
# pre-RP-0011 behaviour) instead of letting jq's test() hard-error on a null listen and abort the firewall
# step. Single source of truth for harden_ufw AND tests/conformance/reachable_firewall_loopback.sh.
myc_firewall_singbox_ports() {
	local cfg="$1" fam="${2:-tcp}"
	[ -f "$cfg" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	case "$fam" in
		tcp)
			jq -r '
				[.inbounds[]? | select(.listen_port != null)
				 | select(.type=="vless" or .type=="trojan" or .type=="shadowtls" or .type=="shadowsocks")
				 | select((.listen // "::")|test("127\\.0\\.0\\.1")|not)
				 | .listen_port] | unique | .[]' "$cfg" 2>/dev/null ;;
		udp)
			# hysteria2/tuic, plus shadowsocks-2022 which opens UDP too (each only when public-bound).
			jq -r '
				([.inbounds[]? | select(.listen_port != null)
				  | select(.type=="hysteria2" or .type=="tuic")
				  | select((.listen // "::")|test("127\\.0\\.0\\.1")|not)
				  | .listen_port]
				 + [.inbounds[]? | select(.tag=="shadowsocks-in")
				  | select((.listen // "::")|test("127\\.0\\.0\\.1")|not)
				  | .listen_port // empty]) | unique | .[]' "$cfg" 2>/dev/null ;;
		*) return 0 ;;
	esac
}

# myc_ufw_admitted_ports — PURE: read `ufw status` TEXT on STDIN, echo the `PORT/proto` tokens that text
# says are admitted from ANYWHERE. Stdin rather than an internal `ufw` call so the parser is fixture-
# testable offline. Rules: ALLOW and LIMIT both count (`ufw limit 22/tcp` is a normal way to provision
# SSH, and reading it as "not admitted" is the cry-wolf failure this check exists to avoid); "ALLOW" and
# "ALLOW IN" both, "ALLOW OUT"/"ALLOW FWD" never; a source-restricted rule is NOT public; a bare `8388`
# admits BOTH protocols so it emits both tokens; an app-profile name (OpenSSH) is not a port and is
# skipped; a DENY/REJECT cancels an ALLOW regardless of order (ufw is order-sensitive, this parser is
# not — over-reporting a block on an ADVISORY line is the safe direction).
# IPv4 ONLY: `(v6)` rows are SKIPPED, not stripped. A dual rule emits a v4 row too, so nothing is lost;
# stripping instead would let a v6-ONLY allow read as admitted and give a false all-clear on a
# v4-blocked port. Callers MUST invoke `ufw` under LC_ALL=C — its output is translated.
# KNOWN BLIND SPOTS, named in the warn text rather than hidden: interface-scoped rules (`443/tcp on
# eth0`), app-profile rows, and a blanket `Anywhere ALLOW Anywhere` all parse to nothing.
myc_ufw_admitted_ports() {
	LC_ALL=C awk '
		/\(v6\)/ { next }
		$2 != "ALLOW" && $2 != "LIMIT" && $2 != "DENY" && $2 != "REJECT" { next }
		{
			if ($3 == "IN")                      { from = $4 }
			else if ($3 == "OUT" || $3 == "FWD") { next }
			else                                 { from = $3 }
			if (from != "Anywhere") next
			if ($1 ~ /^[0-9]+$/)                 { t1 = $1 "/tcp"; t2 = $1 "/udp" }
			else if ($1 ~ /^[0-9]+\/(tcp|udp)$/) { t1 = $1;        t2 = "" }
			else next
			if ($2 == "ALLOW" || $2 == "LIMIT") { a[t1] = 1; if (t2 != "") a[t2] = 1 }
			else                                { b[t1] = 1; if (t2 != "") b[t2] = 1 }
		}
		END { for (t in a) if (!(t in b)) print t }
	' | LC_ALL=C sort -u || true
}

# myc_ufw_listening_ports <tcp|udp> — the NON-LOOPBACK listener view, one port per line. Loopback binds
# are excluded on purpose: under the unified node profile a non-reachable node rebinds public inbounds to
# 127.0.0.1, and a loopback listener must not read as holding a public port open.
#
# RC IS THE SIGNAL, NOT THE OUTPUT (Audit-0009 AG1). This used to return 0 with empty output whenever `ss`
# was absent or failed, so "I cannot see the listeners" was indistinguishable from "nothing is listening" —
# and the caller's orphan advisory reads that emptiness as proof a port is unused. On a node without `ss`,
# EVERY admitted port outside this invocation's served/keep sets would then be reported as an orphan to
# delete by hand, including ports held by live third-party services. That defeats the exact distinction the
# listener check exists to make, so:
#   rc 0 = a real listener view (possibly legitimately empty)
#   rc 2 = NO SIGNAL — ss missing, ss failed, or an unknown family. The caller must not report orphans.
myc_ufw_listening_ports() {
	local fam="$1" out="" rc=0
	have ss || return 2
	case "$fam" in
		tcp) out="$(ss -tlnH 2>/dev/null)" || rc=$? ;;
		udp) out="$(ss -ulnH 2>/dev/null)" || rc=$? ;;
		*)   return 2 ;;
	esac
	[ "$rc" -eq 0 ] || return 2
	printf '%s\n' "$out" | LC_ALL=C awk '
		{ a = $4; n = match(a, /:[0-9]+$/); if (n == 0) next
		  addr = substr(a, 1, n - 1); port = substr(a, n + 1)
		  if (addr ~ /^127\./ || addr == "[::1]" || addr == "::1" || addr ~ /^\[::ffff:127\./) next
		  print port }' | LC_ALL=C sort -u || true
}

# verify_ufw_exposure SERVED_TOKENS KEEP_TOKENS — READ-ONLY, WARN-ONLY, AND IT NEVER DELETES A RULE.
# Two questions that can only be answered on the node:
#   (b) SERVED BUT BLOCKED. verify_post_apply is firewall-blind at every layer (is-active + an ss bind
#       check + a loopback L7 probe), so a listener that is bound and ufw-BLOCKED reports "applied and
#       verified" while no client can reach it. That is a phantom fallback path — the worst kind, because
#       the planner counts it as viable.
#   (a) OPEN BUT NOT SERVED. harden_ufw is additive-only, so a transport moved to a new port leaves the
#       OLD port allowed forever. Reported only when NOTHING is listening on it, which is what separates
#       an orphan rule from a port some other service legitimately owns.
#
# WHY IT ONLY REPORTS. Deleting a ufw rule on a node reached by SSH, from a path that re-runs unattended
# every 15 minutes, is how all three nodes get locked out at once. Any deletion needs a trustworthy record
# of what this tool opened, and there is none — deriving "ours" from the live config is exactly wrong,
# since the rule to remove is by definition the one the config NO LONGER mentions. So the honest split is:
# this tool opens ports and tells you what it cannot justify; a human removes them. The parser's blind
# spots make that doubly right — a false "orphan" that merely prints costs nothing.
#
# AND WHY IT WARNS RATHER THAN FAILS. It runs inside the convergence tail; returning non-zero there would
# reach verify_post_apply and trigger a rollback plus a restart, on every node, on a cadence. A firewall
# observation must never be able to do that. Fail-SAFE throughout: no ufw, no ss, unreadable status, or an
# empty parse all yield NO REPORT rather than a false accusation.
verify_ufw_exposure() {
	local served="$1" keep="$2" admitted listen_tcp listen_udp t p fam blocked="" orphan="" unseen=""
	have ufw || return 0
	# NORMALISE TO SPACE-SEPARATED. myc_ufw_admitted_ports emits one token per LINE (it ends in sort -u),
	# and the membership tests below are `case " $list " in *" $tok "*)`, which matches only a token
	# surrounded by SPACES. Feeding the newline form to that test makes every element except the first and
	# last silently unmatchable — every served port then reads "NOT admitted". Caught on a live node, where
	# the report claimed all eight served ports were firewall-blocked on a node clients were reaching fine.
	# At the time nothing covered it: the change set that introduced this subsystem shipped no test for any
	# of its three functions, and the comment here pointed the next maintainer at a fixture that did not
	# exist (Audit-0009 L1). tests/conformance/ufw_exposure_report.sh now drives the parser AND this
	# comparison, with stubbed ufw/ss, and fails if the normalisation is removed.
	admitted="$(LC_ALL=C ufw status 2>/dev/null | myc_ufw_admitted_ports | tr '\n' ' ')" || admitted=""
	[ -n "$admitted" ] || { log "firewall exposure: ufw status yielded no parseable public rules; nothing reported (fail-safe)."; return 0; }
	# Per FAMILY, because they fail independently and suppressing both on one failure would throw away a
	# view we actually have.
	local seen_tcp=1 seen_udp=1
	listen_tcp="$(myc_ufw_listening_ports tcp)" || { seen_tcp=0; listen_tcp=""; }
	listen_udp="$(myc_ufw_listening_ports udp)" || { seen_udp=0; listen_udp=""; }

	# (b) served but not admitted.
	for t in $served; do
		case " $admitted " in *" $t "*) ;; *) blocked="$blocked $t" ;; esac
	done
	# (a) admitted, not served, not kept, and nothing listening on it.
	for t in $admitted; do
		case " $served " in *" $t "*) continue ;; esac
		case " $keep "   in *" $t "*) continue ;; esac
		p="${t%%/*}"; fam="${t##*/}"
		# NO LISTENER VIEW -> NO ACCUSATION (Audit-0009 AG1). "Nothing is listening" is the whole basis of
		# the orphan claim; without the view there is no basis, only an absence.
		if [ "$fam" = tcp ]; then
			[ "$seen_tcp" -eq 1 ] || { unseen="$unseen $t"; continue; }
			case " $(printf '%s ' $listen_tcp) " in *" $p "*) continue ;; esac
		else
			[ "$seen_udp" -eq 1 ] || { unseen="$unseen $t"; continue; }
			case " $(printf '%s ' $listen_udp) " in *" $p "*) continue ;; esac
		fi
		orphan="$orphan $t"
	done

	if [ -n "$blocked" ]; then
		warn "firewall exposure: served but NOT admitted by ufw:$blocked"
		warn "  A client cannot reach these. verify_post_apply cannot see it — it checks the service, the bind and a"
		warn "  LOOPBACK handshake, all of which pass on a firewall-blocked port, so this would otherwise read healthy."
	fi
	if [ -n "$orphan" ]; then
		# log, NOT warn, and ONE line. This runs inside the convergence tail on every unattended tick, so
		# a multi-line warn block would repeat every cadence on every node until a human acts — which is
		# how a real signal becomes noise people filter out, the same failure this check exists to avoid.
		# An orphan rule is a standing condition to review, not an incident: nothing is broken, one port
		# is open wider than justified. The BLOCKED case above is the one that warns, because that is an
		# outage nothing else can see.
		log "firewall exposure: admitted but not served and nothing listening:$orphan — harden_ufw only ADDS rules; nothing is removed automatically (a rule deletion from an unattended path is how a node locks itself out). Review with 'ufw status numbered' and delete by hand if intended."
	elif [ -z "$blocked" ] && [ -z "$unseen" ]; then
		log "firewall exposure: every served port is admitted, and no unexplained port is open."
	fi
	if [ -n "$unseen" ]; then
		# Say what was not established, rather than converting it into an accusation or an all-clear.
		log "firewall exposure: no listener view available (ss missing or failed), so nothing is claimed about:$unseen — these are admitted and outside this run's served/keep sets, but whether anything is listening on them could not be determined."
	fi
	[ -n "$blocked" ] && warn "  (advisory — the parser does not represent interface-scoped rules, app-profile rows such as OpenSSH, or IPv6-only rules.)"
	return 0
}

# harden_ufw — converge the host firewall onto the enabled canonical ports. ADDITIVE ONLY: it opens what
# the live config justifies and never removes anything (verify_ufw_exposure explains why deletion from an
# unattended path is off the table).
#
# IT ACTS ON A DELTA (Audit-0009 N1). This runs as root on the armed timer's 15-minute cadence, and it used
# to re-issue its entire sequence on every tick with no way to say whether anything had changed. Two
# consequences went unargued. First, a tick with nothing to converge was indistinguishable in the log from
# one that opened a port — the operator had no signal at all. Second, under `set -euo pipefail` a transient
# non-zero from ANY of those unconditional `ufw` calls aborted flow_update after an otherwise successful
# apply, turning a no-op tick into a red unit. Now the desired token set is compared against what ufw
# already admits, only the delta is issued, and an individual rule that fails to add is reported and
# survived rather than fatal — the tail's failure contract keeps its teeth for the one thing that really is
# a convergence failure, `ufw enable` itself.
#
# WHAT THIS MEANS FOR THE OPERATOR, stated because nothing else states it: while the update timer is armed,
# a served port CANNOT be contained with `ufw delete`. The rule is re-added within one cadence and
# verify_ufw_exposure then reports every served port admitted. To take a port out of service, remove the
# transport from the node profile (so it stops being served) or disarm the timer first — see
# docs/runbooks/node-bootstrap.md.
harden_ufw() {
	log "configuring the host firewall (ufw) for the enabled canonical ports"
	need_root
	have ufw || { warn "ufw not installed; skipping firewall step (install ufw to enable)."; return 0; }
	# What ufw admits from anywhere RIGHT NOW — the baseline the delta is computed against. The parser's
	# blind spots (interface-scoped, app-profile, v6-only) can only make a token look NOT-admitted, so the
	# worst case is re-issuing a rule ufw then skips as existing: the old behaviour, for that token only.
	local _now="" _added="" _softfail=""
	_now="$(LC_ALL=C ufw status 2>/dev/null | myc_ufw_admitted_ports | tr '\n' ' ')" || _now=""
	# ufw_allow TOKEN — issue `ufw allow` only if TOKEN is not already admitted; never fatal.
	# Nested on purpose: it reads harden_ufw's locals ($_now/$_added/$_softfail) by dynamic scope and has
	# no meaning outside this converge. Prefixed so it cannot be mistaken for a general helper.
	_harden_ufw_allow() {
		local tok="$1"
		case " $_now " in *" $tok "*) return 0 ;; esac
		if run ufw allow "$tok"; then _added="$_added $tok"; _now="$_now $tok"; return 0; fi
		warn "ufw allow $tok failed; leaving it to the next tick (not aborting an otherwise successful converge)."
		_softfail="$_softfail $tok"
		return 0
	}
	# Default deny inbound; allow SSH first (anti-lockout) then ONLY the enabled protocols' ports. The
	# defaults are read back rather than re-asserted: `ufw default` rewrites /etc/default/ufw and reloads.
	local _defaults; _defaults="$(LC_ALL=C ufw status verbose 2>/dev/null | sed -n 's/^Default: //p')"
	case "$_defaults" in
		*"deny (incoming)"*) : ;;
		*) run ufw --force default deny incoming || warn "could not set the inbound default to deny." ;;
	esac
	case "$_defaults" in
		*"allow (outgoing)"*) : ;;
		*) run ufw --force default allow outgoing || warn "could not set the outbound default to allow." ;;
	esac
	# ANTI-LOCKOUT: never assume port 22. Open EXACTLY the port(s) the running sshd actually listens
	# on (parsed from the effective config), so enabling ufw cannot cut the live session even when
	# the operator runs sshd on a non-standard port.
	local ssh_ports sp opened_ssh=0
	ssh_ports="$(sshd -T 2>/dev/null | sed -n 's/^port[[:space:]]*//p' | sort -u)"
	if [ -n "$ssh_ports" ]; then
		for sp in $ssh_ports; do
			[ -n "$sp" ] || continue
			# ANTI-LOCKOUT keeps its own accounting: opened_ssh must mean "this port is admitted", which is
			# true both when we just added it and when it was already there.
			_harden_ufw_allow "$sp/tcp"
			case " $_softfail " in *" $sp/tcp "*) ;; *) opened_ssh=1 ;; esac
			log "the live sshd port $sp/tcp is admitted before enabling the firewall (anti-lockout)."
		done
	fi
	if [ "$opened_ssh" -ne 1 ]; then
		# Could not determine the sshd port (sshd -T unavailable): fall back to the standard profile,
		# but warn loudly — a non-standard live port could be cut.
		warn "could not detect the live sshd port; falling back to OpenSSH/22. If sshd runs on a"
		warn "non-standard port, allow it manually BEFORE 'ufw enable' to avoid a lockout."
		run ufw allow OpenSSH 2>/dev/null || _harden_ufw_allow 22/tcp
	fi
	# Canonical ports come from the rendered config (the single source of truth at runtime). We
	# read the live config's listen_port set so the firewall opens EXACTLY what is enabled.
	# Canonical ports come from the rendered config (the single source of truth at runtime), via the pure
	# myc_firewall_singbox_ports helper. RP-0011 chunk D / ADR-0034 §3: a LOOPBACK-bound inbound
	# (reachable=false rebinds public inbounds to 127.0.0.1; the shadowtls detour is always loopback) is NOT
	# a public entry, so the helper EXCLUDES its port — across ALL types (the exclusion was previously only
	# on the shadowsocks branch). On a reachable=true node every public listen is "::", so this opens exactly
	# today's ports (no regression); reachable_firewall_loopback.sh pins both directions.
	local enabled_tcp enabled_udp
	enabled_tcp="$(myc_firewall_singbox_ports "$SINGBOX_CONFIG" tcp | tr '\n' ' ')"
	enabled_udp="$(myc_firewall_singbox_ports "$SINGBOX_CONFIG" udp | tr '\n' ' ')"
	local p
	# _served accumulates the exact token set this run justifies, built from the SAME loops that open the
	# rules, so the report can never disagree with what was actually allowed. Purely additive bookkeeping.
	local _served=""
	for p in $enabled_tcp; do _harden_ufw_allow "$p/tcp"; _served="$_served $p/tcp"; done
	for p in $enabled_udp; do _harden_ufw_allow "$p/udp"; _served="$_served $p/udp"; done
	# ADR-0032 dual-engine: the xray engine serves from a SEPARATE config (XRAY_CONFIG), so its listen
	# ports are not in the sing-box config the loop above read. Open them too (xray inbounds key on
	# `.port`; the xhttp-tls family is TCP). A stock node has no XRAY_CONFIG, so this opens nothing.
	if [ -n "${XRAY_CONFIG:-}" ] && [ -f "$XRAY_CONFIG" ] && have jq; then
		local xray_tcp
		xray_tcp="$(jq -r '[.inbounds[]? | select(.port != null) | .port] | unique | .[]' "$XRAY_CONFIG" 2>/dev/null | tr '\n' ' ')"
		for p in $xray_tcp; do _harden_ufw_allow "$p/tcp"; _served="$_served $p/tcp"; done
	fi
	# AmneziaWG UDP port (its conventional canon port; the actual value is operator/runtime).
	# Resolve the port from the LIVE config rather than trusting the marker, and do not require the marker
	# to exist: it was absent on one live node (so this branch never fired at all) and WRONG on two (it
	# held the canonical default while the tunnel ran elsewhere, so the firewall admitted a silent port
	# and not the real one).
	if [ "$DO_AMNEZIAWG" -eq 1 ] && command -v _awg_resolve_port >/dev/null 2>&1; then
		local awgp; awgp="$(_awg_resolve_port)"
		_harden_ufw_allow "$awgp/udp"
		_served="$_served $awgp/udp"
	fi
	# `ufw enable` is the one step that stays unconditional-and-fatal: everything above is a rule that can
	# wait a cadence, this is whether the firewall is running at all. Already-active is a no-op in ufw.
	if ! run ufw --force enable; then
		warn "'ufw --force enable' FAILED — the host firewall is not converged."
		return 1
	fi
	# SAY WHETHER ANYTHING CHANGED. A cadenced root step that logs the same lines on a no-op tick as on a
	# real one gives the operator nothing to notice.
	if [ -n "$_added" ]; then
		log "firewall: opened$_added (delta against the rules ufw already admitted)."
	else
		log "firewall: no rule changes needed (every justified port was already admitted)."
	fi
	[ -z "$_softfail" ] || warn "firewall: these rules could not be added this tick and will be retried on the next one:$_softfail"
	# Report-only exposure check. AFTER `ufw --force enable`, so it describes the state a client actually
	# meets. $ssh_ports is the keep-set: the anti-lockout rules above are ours and must never be reported
	# as unexplained. Under --dry-run nothing was opened, so a report would describe a fiction — skip it.
	if [ "${DRY_RUN:-0}" -eq 0 ]; then
		local _keep=""
		for p in $ssh_ports; do _keep="$_keep $p/tcp"; done
		[ -n "$_keep" ] || _keep=" 22/tcp"
		verify_ufw_exposure "$_served" "$_keep"
	fi
}
