#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# selftest.sh — offline test harness for myceliumctl.
# Author: mindicator & silicon bags quartet.
#
# Runs with ONLY bash + jq present. It stubs `xray` (uuid / x25519) and `openssl`
# by prepending a stub directory to PATH, so no real cryptographic tooling — and
# no network — is needed. The stubs emit fixed, well-formed values; this exercises
# wiring, not key generation. Exits 0 on success, non-zero on the first failure.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$HERE/myceliumctl"
TEMPLATE="$HERE/testdata/server.template.json"
SB_TEMPLATE="$HERE/testdata/singbox.server.template.json"

PASS=0
FAIL=0

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '\n== %s ==\n' "$1"; }

# Hard requirement: jq must be present (the tool needs it; the test asserts JSON).
if ! command -v jq >/dev/null 2>&1; then
	printf 'selftest: jq is required to run this test\n' >&2
	exit 2
fi

# --- Scratch workspace (cleaned up on exit) --------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/myc.selftest.XXXXXX")"
STUBDIR="$WORK/stubbin"
STATE="$WORK/identities.json"
PARAMS="$WORK/params.json"
SERVER_OUT="$WORK/server.json"
SUBS_OUT="$WORK/subs"
SB_PARAMS="$WORK/params.singbox.json"
SB_SERVER_OUT="$WORK/server.singbox.json"
SB_SUBS_OUT="$WORK/subs.singbox"
mkdir -p "$STUBDIR" "$SUBS_OUT" "$SB_SUBS_OUT"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- Stubs for audited tools (so no real xray/openssl is needed) -----------
# `xray uuid` -> deterministic-but-distinct UUIDs (a counter file keeps them
# unique across calls); `xray x25519` -> fixed keypair in the real output shape.
cat >"$STUBDIR/xray" <<'STUB'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  uuid)
    ctr="${MYC_STUB_UUID_COUNTER:-/tmp/.myc_stub_uuid_ctr}"
    n=0
    if [ -f "$ctr" ]; then n="$(cat "$ctr")"; fi
    n=$((n + 1))
    printf '%s' "$n" > "$ctr"
    # 8-4-4-4-12 hex, last segment encodes the counter so each call differs.
    printf '00000000-0000-4000-8000-%012d\n' "$n"
    ;;
  x25519)
    printf 'Private key: cHJpdmF0ZS1rZXktc3R1Yi1iYXNlNjR1cmwtdmFsdWUtMDAx\n'
    printf 'Public key: cHVibGljLWtleS1zdHViLWJhc2U2NHVybC12YWx1ZS0wMDAwMQ\n'
    ;;
  *)
    printf 'xray stub: unsupported subcommand: %s\n' "${1:-}" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$STUBDIR/xray"

# `openssl rand -hex N` -> N bytes of fixed hex (2*N chars). Anything else is
# delegated to a real openssl if present, else refused.
cat >"$STUBDIR/openssl" <<'STUB'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "rand" ] && [ "${2:-}" = "-hex" ]; then
  bytes="${3:-8}"
  out=""
  i=0
  while [ "$i" -lt "$bytes" ]; do out="${out}ab"; i=$((i + 1)); done
  printf '%s\n' "$out"
  exit 0
fi
real="$(command -v -p openssl 2>/dev/null || true)"
if [ -n "$real" ] && [ "$real" != "$0" ]; then exec "$real" "$@"; fi
printf 'openssl stub: unsupported invocation\n' >&2
exit 64
STUB
chmod +x "$STUBDIR/openssl"

# Prepend stubs to PATH. Use a private counter file inside WORK.
export PATH="$STUBDIR:$PATH"
export MYC_STUB_UUID_COUNTER="$WORK/uuid.ctr"

note "Preflight"
[ -x "$CTL" ] && ok "myceliumctl is executable" || bad "myceliumctl is not executable"
command -v xray >/dev/null 2>&1 && ok "xray stub is on PATH" || bad "xray stub missing from PATH"

# ---------------------------------------------------------------------------
note "reality-keys (stubbed xray/openssl)"
# ---------------------------------------------------------------------------
RK_OUT="$("$CTL" reality-keys --shortids 2 2>/dev/null)"
printf '%s\n' "$RK_OUT" | grep -q '^REALITY_PRIVATE_KEY=cHJpdmF0' && ok "private key parsed" || bad "private key parse"
printf '%s\n' "$RK_OUT" | grep -q '^REALITY_PUBLIC_KEY=cHVibGlj'  && ok "public key parsed"  || bad "public key parse"
[ "$(printf '%s\n' "$RK_OUT" | grep -c '^REALITY_SHORT_ID_')" -eq 2 ] && ok "two shortIds emitted" || bad "shortId count"

# ---------------------------------------------------------------------------
note "identity add / list / revoke roundtrip"
# ---------------------------------------------------------------------------
"$CTL" identity add --name alice --state "$STATE" >/dev/null
"$CTL" identity add --name bob   --state "$STATE" >/dev/null
"$CTL" identity add --name carol --state "$STATE" >/dev/null

[ "$(jq '.clients | length' "$STATE")" -eq 3 ] && ok "three clients added" || bad "client count after add"
jq -e '.clients | all(.id | test("^[0-9a-f-]+$"))' "$STATE" >/dev/null && ok "all ids look like uuids" || bad "uuid shape"
jq -e '([.clients[].id] | unique | length) == 3' "$STATE" >/dev/null && ok "ids are unique" || bad "ids not unique"
jq -e '.clients | all(has("name") and has("id") and has("created"))' "$STATE" >/dev/null \
	&& ok "records have name/id/created" || bad "record fields"

# Duplicate name must be rejected.
if "$CTL" identity add --name alice --state "$STATE" >/dev/null 2>&1; then
	bad "duplicate name was NOT rejected"
else
	ok "duplicate name rejected"
fi

# list output contains the names.
LIST_OUT="$("$CTL" identity list --state "$STATE")"
printf '%s\n' "$LIST_OUT" | grep -q 'alice' && printf '%s\n' "$LIST_OUT" | grep -q 'carol' \
	&& ok "list shows clients" || bad "list missing clients"

# Revoke by name.
"$CTL" identity revoke bob --state "$STATE" >/dev/null 2>&1
[ "$(jq '.clients | length' "$STATE")" -eq 2 ] && ok "revoke by name removed one" || bad "revoke by name count"
jq -e 'all(.clients[]; .name != "bob")' "$STATE" >/dev/null && ok "bob is gone" || bad "bob still present"

# Revoke by id.
ALICE_ID="$(jq -r '.clients[] | select(.name=="alice") | .id' "$STATE")"
"$CTL" identity revoke "$ALICE_ID" --state "$STATE" >/dev/null 2>&1
[ "$(jq '.clients | length' "$STATE")" -eq 1 ] && ok "revoke by id removed one" || bad "revoke by id count"

# Revoking a non-existent selector must fail.
if "$CTL" identity revoke nobody-here --state "$STATE" >/dev/null 2>&1; then
	bad "revoking missing selector did NOT fail"
else
	ok "revoking missing selector fails"
fi

# Re-populate to two clients for the render/subscription stages.
"$CTL" identity add --name alice --state "$STATE" >/dev/null
[ "$(jq '.clients | length' "$STATE")" -eq 2 ] && ok "state repopulated to two clients" || bad "repopulate count"

# ---------------------------------------------------------------------------
note "params fixture (real keys substituted by stub reality-keys)"
# ---------------------------------------------------------------------------
PRIV="$(printf '%s\n' "$RK_OUT" | sed -n 's/^REALITY_PRIVATE_KEY=//p')"
PUB="$(printf '%s\n' "$RK_OUT" | sed -n 's/^REALITY_PUBLIC_KEY=//p')"
SID="$(printf '%s\n' "$RK_OUT" | grep '^REALITY_SHORT_ID_1=' | sed -n 's/^REALITY_SHORT_ID_1=//p')"

jq -n \
	--arg priv "$PRIV" --arg pub "$PUB" --arg sid "$SID" \
	'{
		node_address: "node.example.invalid",
		donor_host: "donor.example.invalid",
		donor_sni: "donor.example.invalid",
		listen_port: 443,
		dest: "donor.example.invalid:443",
		reality_private_key: $priv,
		reality_public_key: $pub,
		short_ids: [$sid]
	}' > "$PARAMS"
jq -e . "$PARAMS" >/dev/null && ok "params fixture is valid JSON" || bad "params fixture invalid"

# ---------------------------------------------------------------------------
note "render-server (xray engine) against the real template"
# ---------------------------------------------------------------------------
# The default engine is now sing-box, so the xray-engine stages pass --engine xray explicitly.
[ -f "$TEMPLATE" ] && ok "template fixture present" || bad "template fixture missing"
jq -e . "$TEMPLATE" >/dev/null && ok "template is valid JSON" || bad "template invalid JSON"

"$CTL" render-server --engine xray --template "$TEMPLATE" --params "$PARAMS" --state "$STATE" --out "$SERVER_OUT" 2>/dev/null

jq -e . "$SERVER_OUT" >/dev/null && ok "rendered server.json is valid JSON" || bad "rendered server.json invalid"

# Verify the jq-path edits landed.
jq -e --arg p "$PRIV" '.inbounds[0].streamSettings.realitySettings.privateKey == $p' "$SERVER_OUT" >/dev/null \
	&& ok "privateKey set by path" || bad "privateKey not set"
jq -e --arg s "$SID" '.inbounds[0].streamSettings.realitySettings.shortIds == [$s]' "$SERVER_OUT" >/dev/null \
	&& ok "shortIds set by path" || bad "shortIds not set"
jq -e '.inbounds[0].streamSettings.realitySettings.serverNames == ["donor.example.invalid"]' "$SERVER_OUT" >/dev/null \
	&& ok "serverNames set by path" || bad "serverNames not set"
jq -e '.inbounds[0].streamSettings.realitySettings.dest == "donor.example.invalid:443"' "$SERVER_OUT" >/dev/null \
	&& ok "dest set by path" || bad "dest not set"
jq -e '.inbounds[0].port == 443' "$SERVER_OUT" >/dev/null \
	&& ok "listen port set by path" || bad "port not set"
jq -e '.inbounds[0].settings.clients | length == 2' "$SERVER_OUT" >/dev/null \
	&& ok "two clients rendered into inbound" || bad "inbound client count"
jq -e '.inbounds[0].settings.clients | all(.flow == "xtls-rprx-vision")' "$SERVER_OUT" >/dev/null \
	&& ok "every client has xtls-rprx-vision flow" || bad "client flow"
jq -e '.inbounds[0].settings.clients | all(has("id") and has("email"))' "$SERVER_OUT" >/dev/null \
	&& ok "clients have id and email(label)" || bad "client id/email"
# The private key must NEVER be the placeholder after rendering.
jq -e '.inbounds[0].streamSettings.realitySettings.privateKey != "REALITY_PRIVATE_KEY_PLACEHOLDER"' "$SERVER_OUT" >/dev/null \
	&& ok "placeholder privateKey was replaced" || bad "placeholder leaked"

# ---------------------------------------------------------------------------
note "subscription (xray engine): sing-box JSON + Clash-Meta YAML per client"
# ---------------------------------------------------------------------------
# Explicit --engine xray: the default engine is now sing-box, and this stage asserts the
# single VLESS+REALITY+Vision outbound shape produced by the xray engine.
"$CTL" subscription --engine xray --params "$PARAMS" --state "$STATE" --out "$SUBS_OUT" 2>/dev/null

SB_COUNT="$(find "$SUBS_OUT" -name '*.singbox.json' | wc -l | tr -d '[:space:]')"
CL_COUNT="$(find "$SUBS_OUT" -name '*.clash.yaml' | wc -l | tr -d '[:space:]')"
[ "$SB_COUNT" -eq 2 ] && ok "two sing-box configs emitted" || bad "sing-box file count ($SB_COUNT)"
[ "$CL_COUNT" -eq 2 ] && ok "two clash configs emitted" || bad "clash file count ($CL_COUNT)"

# Validate every emitted sing-box JSON and its required fields.
SB_BAD=0
for f in "$SUBS_OUT"/*.singbox.json; do
	jq -e . "$f" >/dev/null 2>&1 || { SB_BAD=1; break; }
	jq -e '
		.outbounds[0].type == "vless"
		and (.outbounds[0].server | type == "string")
		and (.outbounds[0].server_port | type == "number")
		and (.outbounds[0].uuid | type == "string")
		and .outbounds[0].flow == "xtls-rprx-vision"
		and .outbounds[0].tls.enabled == true
		and (.outbounds[0].tls.server_name | type == "string")
		and .outbounds[0].tls.utls.enabled == true
		and .outbounds[0].tls.utls.fingerprint == "chrome"
		and .outbounds[0].tls.reality.enabled == true
		and (.outbounds[0].tls.reality.public_key | type == "string")
		and (.outbounds[0].tls.reality.short_id | type == "string")
	' "$f" >/dev/null 2>&1 || { SB_BAD=1; break; }
done
[ "$SB_BAD" -eq 0 ] && ok "all sing-box configs valid with required fields" || bad "sing-box config validation"

# The sing-box public_key must equal the params public key (NOT the private key).
SB_ONE="$(find "$SUBS_OUT" -name '*.singbox.json' | head -n1)"
jq -e --arg pub "$PUB" '.outbounds[0].tls.reality.public_key == $pub' "$SB_ONE" >/dev/null \
	&& ok "sing-box carries the REALITY public key" || bad "public key mismatch"
jq -e --arg priv "$PRIV" '.outbounds[0].tls.reality.public_key != $priv' "$SB_ONE" >/dev/null \
	&& ok "sing-box does NOT leak the private key" || bad "private key leaked to client"

# Clash YAML smoke checks (string grep — no YAML parser required).
CL_ONE="$(find "$SUBS_OUT" -name '*.clash.yaml' | head -n1)"
grep -q 'type: vless' "$CL_ONE" && ok "clash entry is vless" || bad "clash type"
grep -q 'flow: xtls-rprx-vision' "$CL_ONE" && ok "clash entry uses xtls-rprx-vision" || bad "clash flow"
grep -q 'client-fingerprint: chrome' "$CL_ONE" && ok "clash uses chrome fingerprint" || bad "clash fingerprint"
grep -q 'reality-opts:' "$CL_ONE" && ok "clash has reality-opts" || bad "clash reality-opts"
grep -q "public-key: \"$PUB\"" "$CL_ONE" && ok "clash carries the public key" || bad "clash public key"

# ===========================================================================
# sing-box ENGINE (PRIMARY): multi-protocol render + subscription
# ===========================================================================
# Same identity state (two clients) is reused. Protocol secrets are sentinel
# placeholders supplied via params (no real key material; the tool only places
# them by jq path). trojan is left DISABLED to prove per-protocol toggling.

note "sing-box params fixture (multi-protocol, trojan disabled)"
jq -n \
	--arg priv "$PRIV" --arg pub "$PUB" --arg sid "$SID" \
	'{
		engine: "singbox",
		node_address: "node.example.invalid",
		donor_host: "donor.example.invalid",
		donor_sni: "donor.example.invalid",
		reality_private_key: $priv,
		reality_public_key: $pub,
		short_ids: [$sid],
		tls_sni: "tls.example.invalid",
		tls_certificate_path: "/etc/mycelium/tls/fullchain.pem",
		tls_key_path: "/etc/mycelium/tls/privkey.pem",
		grpc_service_name: "selftest-grpc",
		xhttp_path: "/selftest",
		shadowtls_handshake_server: "donor.example.invalid",
		shadowtls_handshake_port: 443,
		ss_password: "SENTINEL_SS_PW_BASE64",
		trojan_password: "SENTINEL_TROJAN_PW",
		hysteria2_password: "SENTINEL_HY2_PW",
		shadowtls_password: "SENTINEL_STLS_PW",
		vless_reality_vision_enabled: true,  vless_reality_vision_port: 443,
		vless_reality_grpc_enabled: true,    vless_reality_grpc_port: 8443,
		vless_reality_xhttp_enabled: true,   vless_reality_xhttp_port: 2096,
		hysteria2_enabled: true,             hysteria2_port: 8444,
		tuic_enabled: true,                  tuic_port: 8445,
		shadowsocks_enabled: true,           shadowsocks_port: 8388,
		shadowtls_enabled: true,             shadowtls_port: 8446,
		trojan_enabled: false,               trojan_port: 8447
	}' > "$SB_PARAMS"
jq -e . "$SB_PARAMS" >/dev/null && ok "sing-box params fixture is valid JSON" || bad "sing-box params invalid"

# ---------------------------------------------------------------------------
note "sing-box template fixture"
# ---------------------------------------------------------------------------
[ -f "$SB_TEMPLATE" ] && ok "sing-box template fixture present" || bad "sing-box template missing"
jq -e . "$SB_TEMPLATE" >/dev/null && ok "sing-box template is valid JSON" || bad "sing-box template invalid JSON"
jq -e '.inbounds | length >= 8' "$SB_TEMPLATE" >/dev/null \
	&& ok "template declares an inbound per protocol" || bad "template inbound count"

# ---------------------------------------------------------------------------
note "render-server --engine singbox"
# ---------------------------------------------------------------------------
"$CTL" render-server --engine singbox --template "$SB_TEMPLATE" --params "$SB_PARAMS" \
	--state "$STATE" --out "$SB_SERVER_OUT" 2>/dev/null

jq -e . "$SB_SERVER_OUT" >/dev/null && ok "rendered sing-box server.json is valid JSON" || bad "sing-box server.json invalid"

# Enabled protocols present; disabled (trojan) pruned.
jq -e 'any(.inbounds[]; .tag == "vless-reality-vision-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "vless-reality-vision inbound present" || bad "vision inbound missing"
jq -e 'any(.inbounds[]; .tag == "vless-reality-grpc-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "vless-reality-grpc inbound present" || bad "grpc inbound missing"
jq -e 'any(.inbounds[]; .tag == "vless-reality-xhttp-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "vless-reality-xhttp inbound present" || bad "xhttp inbound missing"
jq -e 'any(.inbounds[]; .tag == "hysteria2-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "hysteria2 inbound present" || bad "hysteria2 inbound missing"
jq -e 'any(.inbounds[]; .tag == "tuic-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "tuic inbound present" || bad "tuic inbound missing"
jq -e 'any(.inbounds[]; .tag == "shadowsocks-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "shadowsocks inbound present" || bad "shadowsocks inbound missing"
jq -e 'any(.inbounds[]; .tag == "shadowtls-in") and any(.inbounds[]; .tag == "shadowtls-ss-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "shadowtls inbound + inner SS detour present" || bad "shadowtls pair missing"
jq -e 'all(.inbounds[]; .tag != "trojan-in")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "disabled trojan inbound pruned (per-protocol toggle works)" || bad "trojan not pruned"

# REALITY sentinels filled by jq path on the vision inbound.
jq -e --arg p "$PRIV" '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .tls.reality.private_key) == $p' "$SB_SERVER_OUT" >/dev/null \
	&& ok "reality private_key set by path" || bad "reality private_key not set"
jq -e --arg s "$SID" '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .tls.reality.short_id) == [$s]' "$SB_SERVER_OUT" >/dev/null \
	&& ok "reality short_id set by path" || bad "reality short_id not set"
jq -e '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .tls.server_name) == "donor.example.invalid"' "$SB_SERVER_OUT" >/dev/null \
	&& ok "reality server_name (donor SNI) set by path" || bad "reality server_name not set"
jq -e '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .tls.reality.handshake.server) == "donor.example.invalid"' "$SB_SERVER_OUT" >/dev/null \
	&& ok "reality handshake.server set by path" || bad "reality handshake.server not set"

# Transport-shaping sentinels for grpc/xhttp.
jq -e '(.inbounds[] | select(.tag=="vless-reality-grpc-in") | .transport.service_name) == "selftest-grpc"' "$SB_SERVER_OUT" >/dev/null \
	&& ok "grpc transport.service_name set by path" || bad "grpc service_name not set"
jq -e '(.inbounds[] | select(.tag=="vless-reality-xhttp-in") | .transport.path) == "/selftest"' "$SB_SERVER_OUT" >/dev/null \
	&& ok "xhttp transport.path set by path" || bad "xhttp path not set"

# Per-protocol user shapes from identity state.
jq -e '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .users | length) == 2' "$SB_SERVER_OUT" >/dev/null \
	&& ok "two vless users rendered" || bad "vless user count"
jq -e '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .users) | all(.flow == "xtls-rprx-vision")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "vision users carry xtls-rprx-vision flow" || bad "vision user flow"
jq -e '(.inbounds[] | select(.tag=="vless-reality-grpc-in") | .users) | all(.flow == "")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "grpc users carry empty flow (Vision is TCP-only)" || bad "grpc user flow"
jq -e '(.inbounds[] | select(.tag=="tuic-in") | .users) | all(has("uuid") and has("password"))' "$SB_SERVER_OUT" >/dev/null \
	&& ok "tuic users have uuid+password" || bad "tuic user shape"
jq -e '(.inbounds[] | select(.tag=="hysteria2-in") | .users) | all(.password == "SENTINEL_HY2_PW")' "$SB_SERVER_OUT" >/dev/null \
	&& ok "hysteria2 users carry the hysteria2 password" || bad "hysteria2 user password"

# Protocol secrets placed by path.
jq -e '(.inbounds[] | select(.tag=="shadowsocks-in") | .password) == "SENTINEL_SS_PW_BASE64"' "$SB_SERVER_OUT" >/dev/null \
	&& ok "shadowsocks password set by path" || bad "shadowsocks password not set"
jq -e '(.inbounds[] | select(.tag=="shadowtls-ss-in") | .password) == "SENTINEL_SS_PW_BASE64"' "$SB_SERVER_OUT" >/dev/null \
	&& ok "shadowtls inner SS password set by path" || bad "shadowtls inner SS password not set"

# No template sentinel may survive into the rendered config.
if grep -q 'SENTINEL_REALITY_PRIVATE_KEY\|SENTINEL_DONOR\|SENTINEL_SHORTID\|SENTINEL_TLS\|SENTINEL_GRPC\|SENTINEL_XHTTP' "$SB_SERVER_OUT"; then
	bad "a template sentinel leaked into rendered sing-box config"
else
	ok "no template sentinels remain in rendered sing-box config"
fi

# ---------------------------------------------------------------------------
note "subscription --engine singbox: client outbound per protocol + selector"
# ---------------------------------------------------------------------------
"$CTL" subscription --engine singbox --params "$SB_PARAMS" --state "$STATE" --out "$SB_SUBS_OUT" 2>/dev/null

SB_N="$(find "$SB_SUBS_OUT" -name '*.singbox.json' | wc -l | tr -d '[:space:]')"
CL_N="$(find "$SB_SUBS_OUT" -name '*.clash.yaml' | wc -l | tr -d '[:space:]')"
[ "$SB_N" -eq 2 ] && ok "two sing-box client configs emitted" || bad "sing-box client count ($SB_N)"
[ "$CL_N" -eq 2 ] && ok "two clash configs emitted" || bad "clash count ($CL_N)"

SB_CLIENT="$(find "$SB_SUBS_OUT" -name '*.singbox.json' | head -n1)"
jq -e . "$SB_CLIENT" >/dev/null && ok "sing-box client config is valid JSON" || bad "client config invalid JSON"

# One routable outbound per ENABLED protocol (7: vision/grpc/xhttp/hy2/tuic/ss/shadowtls;
# trojan disabled). Plus a hidden shadowtls-handshake detour, urltest, selector, direct, block.
for t in vless-reality-vision vless-reality-grpc vless-reality-xhttp hysteria2 tuic shadowsocks shadowtls; do
	jq -e --arg t "$t" 'any(.outbounds[]; .tag == $t)' "$SB_CLIENT" >/dev/null \
		|| { bad "client missing outbound: $t"; break; }
done
jq -e 'all(.outbounds[]; .tag != "trojan")' "$SB_CLIENT" >/dev/null \
	&& ok "disabled trojan absent from client outbounds" || bad "trojan present in client"
jq -e 'any(.outbounds[]; .type == "urltest" and .tag == "auto")' "$SB_CLIENT" >/dev/null \
	&& ok "client has a urltest outbound" || bad "no urltest outbound"
jq -e 'any(.outbounds[]; .type == "selector" and .tag == "mycelium")' "$SB_CLIENT" >/dev/null \
	&& ok "client has a selector outbound" || bad "no selector outbound"
# Priority order: vision first in both urltest and selector.
jq -e '(.outbounds[] | select(.type=="urltest") | .outbounds[0]) == "vless-reality-vision"' "$SB_CLIENT" >/dev/null \
	&& ok "urltest prefers vless-reality-vision first (priority order)" || bad "urltest priority order"
jq -e '(.outbounds[] | select(.type=="selector") | .outbounds[0]) == "auto"' "$SB_CLIENT" >/dev/null \
	&& ok "selector defaults through auto (urltest)" || bad "selector order"
# ShadowTLS: routable SS outbound detours to the hidden handshake outbound.
jq -e '(.outbounds[] | select(.tag=="shadowtls") | .type) == "shadowsocks" and (.outbounds[] | select(.tag=="shadowtls") | .detour) == "shadowtls-handshake"' "$SB_CLIENT" >/dev/null \
	&& ok "shadowtls routable SS outbound detours to handshake" || bad "shadowtls detour wiring"
jq -e 'any(.outbounds[]; .tag == "shadowtls-handshake" and .type == "shadowtls" and .version == 3)' "$SB_CLIENT" >/dev/null \
	&& ok "shadowtls v3 handshake outbound present" || bad "shadowtls handshake outbound missing"
# The handshake partner must NOT appear in the selector/urltest candidate lists.
jq -e '(.outbounds[] | select(.type=="urltest") | .outbounds) | index("shadowtls-handshake") == null' "$SB_CLIENT" >/dev/null \
	&& ok "handshake partner excluded from urltest candidates" || bad "handshake partner in urltest"

# Clients receive the REALITY PUBLIC key, never the private key.
jq -e --arg pub "$PUB" 'all(.outbounds[] | select(.tls.reality?); .tls.reality.public_key == $pub)' "$SB_CLIENT" >/dev/null \
	&& ok "reality outbounds carry the public key" || bad "client public key mismatch"
if grep -q "$PRIV" "$SB_CLIENT"; then
	bad "client config leaked the REALITY private key"
else
	ok "client config does NOT leak the private key"
fi

# Clash-Meta: supported protocols become proxies; xhttp/shadowtls are intentionally skipped.
CL_CLIENT="$(find "$SB_SUBS_OUT" -name '*.clash.yaml' | head -n1)"
grep -q 'type: vless' "$CL_CLIENT" && ok "clash has a vless proxy" || bad "clash vless missing"
grep -q 'type: hysteria2' "$CL_CLIENT" && ok "clash has a hysteria2 proxy" || bad "clash hysteria2 missing"
grep -q 'type: tuic' "$CL_CLIENT" && ok "clash has a tuic proxy" || bad "clash tuic missing"
grep -q 'type: ss' "$CL_CLIENT" && ok "clash has a shadowsocks proxy" || bad "clash ss missing"
grep -q 'name: "mycelium-auto"' "$CL_CLIENT" && grep -q 'type: url-test' "$CL_CLIENT" \
	&& ok "clash has a url-test proxy-group" || bad "clash url-test group missing"
grep -q 'name: "mycelium"' "$CL_CLIENT" && grep -q 'type: select' "$CL_CLIENT" \
	&& ok "clash has a select proxy-group" || bad "clash select group missing"
# Flow-list entries must be comma-separated (valid YAML flow sequence).
grep -Eq 'proxies: \[ "[^]]*", ' "$CL_CLIENT" \
	&& ok "clash proxy-group flow-list is comma-separated" || bad "clash flow-list comma separation"
if grep -q "$PRIV" "$CL_CLIENT"; then bad "clash leaked the private key"; else ok "clash does NOT leak the private key"; fi

# ---------------------------------------------------------------------------
note "engine default is now sing-box (project canon); explicit --engine xray still works"
# ---------------------------------------------------------------------------
# Default engine (no --engine flag) must now be sing-box: render-server with no --engine
# (against the sing-box template + sing-box params) must produce a sing-box config.
SB_DEFAULT_OUT="$WORK/server.singbox-default.json"
"$CTL" render-server --template "$SB_TEMPLATE" --params "$SB_PARAMS" --state "$STATE" --out "$SB_DEFAULT_OUT" 2>/dev/null
jq -e 'any(.inbounds[]; .tag == "vless-reality-vision-in")' "$SB_DEFAULT_OUT" >/dev/null \
	&& ok "default engine (no --engine) renders the sing-box config (singbox is default)" || bad "default singbox render broke"
jq -e --arg p "$PRIV" '(.inbounds[] | select(.tag=="vless-reality-vision-in") | .tls.reality.private_key) == $p' "$SB_DEFAULT_OUT" >/dev/null \
	&& ok "default singbox render fills the REALITY private_key by path" || bad "default singbox render regressed"
# Explicit --engine xray must STILL render the legacy Xray config unchanged.
XR_OUT="$WORK/server.xray-explicit.json"
"$CTL" render-server --engine xray --template "$TEMPLATE" --params "$PARAMS" --state "$STATE" --out "$XR_OUT" 2>/dev/null
jq -e '.inbounds[0].streamSettings.realitySettings.privateKey != null' "$XR_OUT" >/dev/null \
	&& ok "explicit --engine xray renders the legacy config" || bad "explicit xray render broke"
jq -e --arg p "$PRIV" '.inbounds[0].streamSettings.realitySettings.privateKey == $p' "$XR_OUT" >/dev/null \
	&& ok "explicit --engine xray fills privateKey (xray path intact)" || bad "explicit xray render regressed"
# Explicit --engine xray subscription still emits the single-protocol files.
XR_SUBS="$WORK/subs.xray"; mkdir -p "$XR_SUBS"
"$CTL" subscription --engine xray --params "$PARAMS" --state "$STATE" --out "$XR_SUBS" 2>/dev/null
[ "$(find "$XR_SUBS" -name '*.singbox.json' | wc -l | tr -d '[:space:]')" -eq 2 ] \
	&& ok "--engine xray subscription still works" || bad "--engine xray subscription broke"
# An unknown engine is rejected.
if "$CTL" render-server --engine bogus --params "$PARAMS" --state "$STATE" --out "$WORK/x.json" >/dev/null 2>&1; then
	bad "unknown --engine was NOT rejected"
else
	ok "unknown --engine is rejected"
fi

# ---------------------------------------------------------------------------
note "Summary"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
	printf 'selftest: FAILURES detected\n' >&2
	exit 1
fi
printf 'selftest: all checks passed\n'
exit 0
