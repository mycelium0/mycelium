#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# no_custom_crypto.sh — conformance: no hand-rolled cryptography (ADR-0002).
# Author: mindicator & silicon bags quartet.
#
# POLICY (docs/adr/0002-no-custom-cryptography.md)
#   Mycelium uses ONLY audited, off-the-shelf cryptographic tooling. The complete set of
#   SANCTIONED generators (the ONLY ways key material may enter this tree) is:
#     * REALITY X25519 keypairs:  `sing-box generate reality-keypair`  (PRIMARY engine)
#                              OR `xray x25519`                        (optional engine)
#     * client identities (UUIDs): `sing-box generate uuid`           (PRIMARY engine)
#                              OR `xray uuid`                          (optional engine)
#     * random secrets / shortIds / PSKs: `sing-box generate rand`     (PRIMARY engine)
#                              OR `openssl rand` (e.g. `-hex N` / `-base64 N`)
#     * AmneziaWG keys (separate UDP path): `awg genkey` | `awg pubkey` | `awg genpsk`
#   No source in this tree may implement a cipher, a keystream, a MAC, a KDF, or a random
#   source used as key material. This gate FAILS (exit 1) when a source/script file appears
#   to roll its own crypto, and PASSES when crypto only enters via the sanctioned generators
#   above.
#
# HOW IT WORKS
#   Two pattern classes are scanned across CODE files (shell/template/IaC/source — NOT prose
#   docs, which legitimately *describe* crypto by name):
#
#   A) Hard fails — strong signals of hand-rolled crypto or misuse of openssl as a cipher:
#        * `openssl enc ...`                 — symmetric encryption with raw/operator keys
#        * `openssl dgst -hmac` / `-mac`     — hand-built MACs over our own data
#        * a function/var literally named or built as a custom cipher / keystream / sbox /
#          round-key / feistel / rotor schedule
#        * XOR used as a confidentiality mechanism (xor + key/cipher/encrypt nearby)
#        * `$RANDOM`, language `rand()`/`Math.random` feeding a key/secret/nonce/iv
#
#   B) Allowed (explicitly NOT flagged), so the audited path stays green — the sanctioned
#      generators are neutralised before scanning:
#        * `sing-box generate reality-keypair`, `sing-box generate uuid`,
#          `sing-box generate rand`                          (PRIMARY engine generators)
#        * `xray x25519`, `xray uuid`, `openssl rand`        (optional engine + openssl)
#        * `awg genkey`, `awg pubkey`, `awg genpsk`          (AmneziaWG built-ins)
#        * the word "crypto"/"cipher"/"AES"/"x25519" appearing in comments or docs as prose
#
# EXCLUSIONS: .git/, LICENSE, *.md and other docs (prose), *.json (no logic), and this
# conformance directory (it necessarily contains the patterns as search strings).
#
# Exit: 0 = clean, 1 = suspicious crypto implementation found, 2 = usage/env error.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"

# _ignored REL -> 0 if git would ignore this repo-relative path (local tooling/state,
# secrets, rendered runtime configs, the vault). Returns non-zero outside a git work-tree,
# so the gate still runs on a plain checkout or source tarball.
_ignored() { git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; }

fail=0
report() {
	# report FILE LINENO REASON TEXT
	printf '  SUSPECT  %s:%s  [%s]  %s\n' "$1" "$2" "$3" \
		"$(printf '%s' "$4" | sed 's/^[[:space:]]*//')"
	fail=1
}

# is_code_file PATH-REL -> 0 if we scan it for crypto implementation, 1 otherwise.
is_code_file() {
	local rel="$1" base
	base="$(basename "$rel")"
	case "$rel" in
		.git/*) return 1 ;;
		tests/conformance/*) return 1 ;;
	esac
	case "$base" in
		LICENSE|*.md|*.json|*.txt) return 1 ;;
	esac
	case "$base" in
		*.sh|*.bash|*.j2|*.tf|*.hcl|*.yml|*.yaml|*.cfg|*.ini|*.toml|*.conf|*.example|\
		*.py|*.go|*.rs|*.js|*.ts|*.c|*.h|*.cpp|*.java|Caddyfile)
			return 0 ;;
	esac
	# Extensionless shell scripts (shebang sniff).
	case "$base" in
		*.*) return 1 ;;
		*)
			if head -n1 "$REPO_ROOT/$rel" 2>/dev/null | grep -Eq '^#!.*\b(ba)?sh\b'; then
				return 0
			fi
			return 1
			;;
	esac
}

# strip_allowed FILE -> echo the file's lines with SANCTIONED / BENIGN tokens neutralised,
# numbered "LINENO:TEXT", so neither the audited path nor the project's own anti-crypto
# vocabulary trips the scanners below. Neutralised:
#   * the sanctioned generators:
#       - sing-box generate reality-keypair / uuid / rand   (PRIMARY engine)
#       - xray x25519 / xray uuid / openssl rand            (optional engine + openssl)
#       - awg genkey / awg pubkey / awg genpsk              (AmneziaWG built-ins)
#   * the project's policy phrasing:    "no custom crypto", "custom cryptography",
#     "no-custom-cryptography" (the ADR slug). These FORBID custom crypto — they do not do it.
strip_allowed() {
	# NOTE: BSD/macOS sed has no case-insensitive 's///I' flag, so we use explicit [Cc]
	# character classes to stay portable across BSD and GNU sed.
	grep -nIv '^$' "$1" 2>/dev/null \
		| sed -E \
			-e 's/sing-box[[:space:]]+generate[[:space:]]+reality-keypair//g' \
			-e 's/sing-box[[:space:]]+generate[[:space:]]+uuid//g' \
			-e 's/sing-box[[:space:]]+generate[[:space:]]+rand//g' \
			-e 's/xray[[:space:]]+x25519//g' \
			-e 's/xray[[:space:]]+uuid//g' \
			-e 's/[Oo]penssl[[:space:]]+rand//g' \
			-e 's/awg[[:space:]]+genkey//g' \
			-e 's/awg[[:space:]]+pubkey//g' \
			-e 's/awg[[:space:]]+genpsk//g' \
			-e 's/[Nn]o[_-]?[Cc]ustom[_-]?[Cc]rypto([Gg]raphy)?//g' \
			-e 's/[Cc]ustom[_-]?[Cc]ryptography//g' \
			-e 's/[Cc]ustom[[:space:]]+[Cc]ryptography//g' \
			-e 's/[Hh]and-?[Rr]olled[[:space:]]+[Cc]rypto([Gg]raphy)?//g'
}

printf '== no custom crypto check ==\n'
printf 'repo: %s\n' "$REPO_ROOT"

while IFS= read -r -d '' f; do
	rel="${f#"$REPO_ROOT"/}"
	_ignored "$rel" && continue
	is_code_file "$rel" || continue
	if grep -Iq . "$f" 2>/dev/null; then :; else continue; fi

	# Work on a sanctioned-stripped, line-numbered view of the file.
	scrubbed="$(strip_allowed "$f")"
	[ -n "$scrubbed" ] || continue

	# --- A1: openssl used as a CIPHER / hand-built MAC (rand was stripped above). -----------
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "openssl-as-cipher" "$text"
	done < <(printf '%s\n' "$scrubbed" | grep -inE 'openssl[[:space:]]+(enc|dgst[^|]*-(hmac|mac))' || true)

	# --- A2: hand-rolled primitive named in code (cipher/keystream/sbox/feistel/...). -------
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "primitive-impl" "$text"
	done < <(printf '%s\n' "$scrubbed" \
		| grep -inE '(keystream|s-?box|sbox|feistel|rotor|round[_-]?key|key[_-]?schedule|(custom|home[_-]?made|my)[_-]?(cipher|crypt|encrypt|aes|rc4|chacha))' \
		|| true)

	# --- A3: XOR used as a confidentiality mechanism (xor near key/cipher/encrypt). ---------
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "xor-as-crypto" "$text"
	done < <(printf '%s\n' "$scrubbed" \
		| grep -inE '\b(xor)\b' \
		| grep -iE 'key|cipher|crypt|encrypt|secret|stream' \
		|| true)

	# --- A4: weak/non-crypto randomness feeding key/secret/nonce/iv material. ---------------
	while IFS=: read -r lineno text; do
		[ -n "${lineno:-}" ] || continue
		report "$rel" "$lineno" "weak-random-as-key" "$text"
	done < <(printf '%s\n' "$scrubbed" \
		| grep -inE '(\$RANDOM|Math\.random|[^a-zA-Z_]rand\(\)|random\.random|secrets\.SystemRandom)' \
		| grep -iE 'key|secret|nonce|iv|token|password|seed' \
		|| true)

done < <(find "$REPO_ROOT" -type f -print0)

if [ "$fail" -ne 0 ]; then
	printf 'FAIL: source appears to implement or misuse cryptography. Crypto must come ONLY from the\n' >&2
	printf '      sanctioned generators (ADR-0002): "sing-box generate reality-keypair|uuid|rand",\n' >&2
	printf '      "xray x25519", "xray uuid", "openssl rand", and "awg genkey|pubkey|genpsk".\n' >&2
	exit 1
fi

printf 'PASS: no hand-rolled crypto; key material comes only from the sanctioned\n'
printf '      sing-box / xray / openssl / awg generators (ADR-0002).\n'
exit 0
