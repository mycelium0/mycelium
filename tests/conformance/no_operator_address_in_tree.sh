#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_operator_address_in_tree.sh — conformance: no tracked file carries a routable IP address that could
# belong to somebody's node. Every IPv4 literal in this repository is a documentation range, an IETF
# special-purpose assignment, or a well-known public resolver.
# Author: mindicator & silicon bags quartet.
#
# WHY THIS GATE EXISTS
#   Audit-0011 recorded, as a finding in the project's favour, that "every IPv4 literal in the tree is a
#   public well-known or an IETF assignment" and that "the artifact carries no operator identity".
#   Both sentences were true when written, and NOTHING ENFORCED EITHER OF THEM.
#
#   Four days later a real operator node address was committed to this public repository, twice, in two
#   tracked files — inside comments explaining a defect, quoting the measured output of
#   `ip -o -4 addr show scope global` verbatim because the measurement was the evidence. It survived
#   review, a 100-gate suite, gitleaks, and check_ppn_wording, because every one of those looks for
#   secrets, framing or contact details, and a node's public address is none of those things. It is
#   simply an operator's infrastructure, published.
#
#   The property the audit asserted is exactly the property a gate can hold, so it holds it now. This is
#   also the reason the redaction used 203.0.113.9 rather than deleting the line: the measurement is the
#   whole argument for that code, and an example from TEST-NET-3 makes the same argument with nothing
#   real in it.
#
# WHAT IT CHECKS
#   Every IPv4 literal in every tracked file must fall in an allowed set. The allow-list is small and
#   deliberate — documentation ranges (RFC 5737), the IETF special-purpose registry blocks this project
#   legitimately names in engine blocklists (RFC 6890), private/loopback/link-local/CGNAT/multicast, and
#   an explicit handful of well-known public resolvers. Anything else is a routable address that belongs
#   to someone, and the gate cannot tell whose — which is the point: it does not need to know the
#   operator's addresses to refuse a class that must never appear.
#
#   IPv6 is checked for global unicast (2000::/3) by the same rule.
#
# OFFLINE. No root, no network. Exit: 0 = no routable third-party address in the tree; 1 = one is present.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MYC_REPO_ROOT:-$(cd -P "$HERE/../.." 2>/dev/null && pwd)}"
[ -n "$REPO_ROOT" ] || { printf 'no_operator_address_in_tree: cannot resolve repo root\n' >&2; exit 2; }

printf '== no routable third-party address in any tracked file ==\n'
printf 'repo: %s\n\n' "$REPO_ROOT"

if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	printf '  SKIP  not a git checkout (release tarball); the tracked-file set cannot be enumerated.\n'
	printf 'PASS (skipped)\n'
	exit 0
fi

# ---------------------------------------------------------------------------------------------------
# THE ALLOW-LIST. Anything not matched here is a routable address belonging to a real party.
#
#   RFC 5737 documentation      192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
#   RFC 1918 private            10/8, 172.16/12, 192.168/16
#   loopback / link-local       127/8, 169.254/16
#   CGNAT (RFC 6598)            100.64/10
#   benchmarking (RFC 2544)     198.18/15
#   IETF protocol assignments   192.0.0/24, 192.88.99/24 (named in engine blocklists)
#   multicast + reserved        224-239/4, 240/4, 0/8, 255.255.255.255
#   well-known public resolvers 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9, 208.67.222.222
#
# The resolver entries are the only genuinely routable addresses permitted, they are enumerated one by
# one rather than by prefix, and each is an anycast service address that identifies no operator.
allowed_v4() {
	case "$1" in
		192.0.2.*|198.51.100.*|203.0.113.*)                          return 0 ;;
		10.*|192.168.*)                                              return 0 ;;
		172.1[6-9].*|172.2[0-9].*|172.3[01].*)                       return 0 ;;
		127.*|169.254.*)                                             return 0 ;;
		100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
		198.18.*|198.19.*)                                           return 0 ;;
		192.0.0.*|192.88.99.*)                                       return 0 ;;
		22[4-9].*|23[0-9].*|240.*|0.*|255.255.255.255)               return 0 ;;
		1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9|208.67.222.222)      return 0 ;;
	esac
	return 1
}

# A dotted quad whose every octet is 0-255. The looser \b([0-9]{1,3}\.){3}[0-9]{1,3}\b matches version
# strings and SHA fragments and produces noise that gets the gate ignored.
V4RE='\b((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b'

fail=0
found=0
checked=0

# `git ls-files -z` + a NUL loop: a path with a space would otherwise silently drop out of the scan,
# and a scan that skips files is worse than none because it reports clean.
while IFS= read -r -d '' rel; do
	f="$REPO_ROOT/$rel"
	[ -f "$f" ] || continue
	# -I skips binaries; a match inside one is not readable evidence anyway.
	hits="$(grep -IoE "$V4RE" "$f" 2>/dev/null | sort -u)" || continue
	[ -n "$hits" ] || continue
	while IFS= read -r ip; do
		[ -n "$ip" ] || continue
		checked=$((checked + 1))
		if ! allowed_v4 "$ip"; then
			found=$((found + 1))
			[ "$found" -le 10 ] && printf '  FAIL  %s carries the routable address %s\n' "$rel" "$ip"
			fail=1
		fi
	done <<EOF
$hits
EOF
done < <(git -C "$REPO_ROOT" ls-files -z)

# IPv6 global unicast (2000::/3). Three traps, every one of them hit by a draft of this block, and the
# last two visible only on Linux — BSD and GNU grep disagree on `\b` here, so a macOS-only run reported
# clean while the node reported the same tree dirty:
#   * `2000:3000` is a hysteria2 hop PORT RANGE, not an address.
#   * `2000:3000:4000` is a MALFORMED port range from a negative-test value table
#     (params_validation_single_owner.sh) — three colon groups, so "has two colons" does not exclude it.
#   * greedy matching produced truncated prefixes (`2606:4700:4700::`) that an exact-match allow-list of
#     full resolver addresses could never contain, so a legitimate literal failed as an unknown one.
# The discriminator that survives all three: a real IPv6 literal contains `::` OR has at least six
# groups. Port ranges have neither. Allow-listing is by PREFIX so a truncation matches too.
# The optional /NN is CAPTURED, not ignored: `2000::/3` is the range itself — named in engine blocklists
# and in the probe's own filter — and stripping the suffix turns a declared range into what looks like a
# host address. A literal with a prefix length is a range and is never somebody's node.
v6raw="$(git -C "$REPO_ROOT" grep -IhoE '\b[23][0-9a-fA-F]{3}:[0-9a-fA-F:]*[0-9a-fA-F:](/[0-9]{1,3})?' -- . 2>/dev/null | sort -u)"
v6hits="$(printf '%s\n' "$v6raw" \
	| grep -v '/' \
	| awk '/::/ { print; next } { n = gsub(/:/, ":"); if (n >= 5) print }' \
	| grep -vE '^(2001:0?db8|2001:DB8)' \
	| grep -vE '^(2606:4700:4700|2001:4860:4860|2620:fe|2620:119:35|2a00:1098|2a01:4f8)' \
	| head -5)"
if [ -n "$v6hits" ]; then
	printf '  FAIL  these are global-unicast IPv6 literals (2000::/3) that are neither the documentation prefix 2001:db8::/32 nor a named public resolver: %s\n' "$(printf '%s' "$v6hits" | tr '\n' ' ')"
	fail=1
fi

# NON-VACUITY. A scan that examined nothing reports clean, and this gate exists precisely because a
# clean report was believed. Assert it saw a plausible number of literals.
if [ "$checked" -lt 20 ]; then
	printf '  FAIL  only %d IPv4 literal(s) were examined across the whole tree. This tree is known to contain dozens (engine blocklists alone); the scan is not reaching files, so a clean result here means nothing.\n' "$checked"
	fail=1
fi

printf '\n-- Result --\n'
printf 'examined %d IPv4 literal(s) across %s tracked file(s).\n' \
	"$checked" "$(git -C "$REPO_ROOT" ls-files | wc -l | tr -d ' ')"
if [ "$fail" -ne 0 ]; then
	[ "$found" -gt 10 ] && printf '  ...and %d more.\n' "$((found - 10))"
	printf 'FAIL: a routable address that belongs to some real party is committed to this repository.\n' >&2
	printf 'If it is a measurement you need to keep as evidence, substitute a documentation address (RFC 5737: 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) — the example makes the same argument with nothing real in it.\n' >&2
	exit 1
fi
printf 'PASS: every IPv4 literal is a documentation range, an IETF assignment, or a named public resolver.\n'
exit 0
