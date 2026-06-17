#!/usr/bin/env bash
# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# run.sh — run all OFFLINE conformance checks and report a summary.
# Author: mindicator & silicon bags quartet.
#
# Runs the gates that need NO live node and NO network:
#   * check_headers.sh        — every commentable file carries the AGPL SPDX header
#   * check_ppn_wording.sh    — neutral PPN vocabulary only (no loaded framing)
#   * no_contact_leak.sh      — no personal email / contact details in tracked files
#   * no_custom_crypto.sh     — no hand-rolled cryptography (ADR-0002)
#   * validate_configs.sh     — JSON valid (jq); YAML/xray checks run if their tools are present
#   * no_legacy_transport.sh  — disabled-legacy transports are never configured as inbounds
#   * no_insecure_tls.sh      — TLS verification is never disabled (no insecure/allowInsecure/
#                               skip-cert-verify = true) in the deployable config surface (ADR-0014)
#   * no_operated_network_claim.sh — no AFFIRMATIVE "operates a public network" claim; the negated
#                               separation statement ("does not operate a public network") is allowed
#   * per_protocol_toggle.sh  — every protocol is enable_*-gated; only vless_reality_vision default-on
#   * transport_family_independence.sh — >=2 INDEPENDENT transport families are available + wired so
#                               the Phase-0 D2 bar is achievable (ADR-0020 §5); every toggle classified
#   * no_dataplane_pii.sh      — the cmd/dataplane-stats exporter exports only allowlisted aggregate,
#                               label-free metrics and never decodes per-connection metadata (no PII)
#   * phase0_port_canon.sh    — the canonical per-protocol port map is consistent everywhere
#   * node_update_artifact_root.sh — the --update re-exec path resolves canonical artifacts from the
#                                    real checkout (CHECKOUT_DIR/ARTIFACT_ROOT), not the tmp re-exec dir
#   * unit_netlink_parity.sh  — every sing-box/xray unit-producing source (bash bootstrap + Ansible
#                               templates) grants AF_NETLINK so no deploy path crash-loops (Audit-0004 F-001)
#   * live_artifact_posture.sh — assertions on the DEPLOYED artifacts: clash_api loopback-only + the
#                               live default-on transport set == documented Variant A (Audit-0004 F-002/F-004)
#   * active_probe_owncert.sh — every genuine single-TLS XHTTP inbound (own cert, no reality) serves
#                               its OWN cert, avoids the 8443 mobile tell, and stays distinct from the
#                               REALITY-XHTTP (TLS-in-TLS) inbound — probe-safe (RP-0007-a §AC-a3)
#   * sub_channel_not_single_point.sh — the subscription/bundle delivery channel is never a single
#                               point of block: no committed config pins a lone hardcoded sub URL, the
#                               bundle spans >=2 independent transport families, and the served-bundle
#                               listen binds loopback-only (RP-0007-b)
#   * node_two_hop_failclosed.sh — node-bootstrap.sh wires the two-hop / operator-toggle / served-bundle
#                               fail-closed behaviours (audit C17/C18/C19/C21/C25)
#   * no_new_control_decisions_in_bash.sh — scripts/node-bootstrap.sh stays orchestration-only after the
#                               RP-0009 decomposition: every function it defines is a helper/flow_*/verify_*,
#                               it still sources its control/lib/nb_*.sh modules, and no control-logic
#                               function is re-inlined ("no new control-decisions-in-bash", RP-0008/RP-0009)
#   * bundle_go_roundtrip.sh  — a shell-rendered bundle round-trips through the authoritative Go
#                               validator (myceliumctl validate-bundle); RP-0008 P1 / audit C11. SKIPs
#                               where no Go toolchain is present (jq-only host/CI lane)
#   * spine_binary_build.sh   — the Go control binary (cmd/myceliumctl -> myceliumctl-go) that node-bootstrap
#                               install_spine compiles onto nodes BUILDS + INSTALLS + RUNS with the production
#                               env, and the source-rev stamp + dependency-free-module invariants hold;
#                               RP-0008 P3. SKIPs where no Go toolchain is present (jq-only host/CI lane)
#   * engine_load_check.sh    — a representative sing-box server config, shell-rendered, actually LOADS
#                               in the engine (`sing-box check`), and enabling vless-xhttp-tls (xhttp is
#                               Xray-core only) is REFUSED fail-closed. SKIPs the load half where no
#                               sing-box binary is present (jq-only host/CI lane); the guard half runs
#   * vocab_single_source.sh  — the proto->class table + closed transport/region/health vocab is owned in
#                               Go (internal/spec) and control/vocab.json is in sync with `myceliumctl
#                               vocab`; RP-0008 P2. Internal-consistency checks always run; the Go regen
#                               diff SKIPs where no Go toolchain is present (jq-only host/CI lane)
#   * detector_state_closed_vocab.sh — the Phase-2 connectivity-state detector schema (RP-0010 Plane 2)
#                               keeps its CLOSED vocabulary {clean/throttled/blocked/shutdown}, its
#                               AdvisoryHealth() projection stays LOSSY (impaired states collapse to one
#                               advisory value), and NO transmitted artifact embeds the fine ConnState —
#                               only the coarse advisory HealthValue is emittable (ADR-0030). OFFLINE
#   * detector_pure_no_probe.sh — the Phase-2 classifier (internal/detect, RP-0010 Plane 2) is PURE and
#                               adds no new probing surface (AC-6): its non-test sources import no
#                               net*/os*/syscall package and no internal/reach, and they consume the
#                               typed internal/spec signal. OFFLINE (reads import blocks, no toolchain)
#   * tuner_pure_advisory.sh  — the Phase-2 self-tuner (internal/tune, RP-0010 Plane 3) is a PURE
#                               scoring layer that never actuates (AC-4): its non-test sources import
#                               no net*/os*/syscall package and no internal/reach|detect, and consume
#                               the typed internal/spec Verdict/DecayPolicy. OFFLINE
#   * control/selftest.sh     — myceliumctl render/identity self-test (bash + jq, no network)
#
# DELIBERATELY EXCLUDED: cover_site_probe.sh — it is a POST-DEPLOY gate that requires a live
# node, so it is not part of the offline suite. Run it by hand against a deployed node:
#   tests/conformance/cover_site_probe.sh --node NODE --donor DONOR
#
# Exit: 0 = every offline gate passed, 1 = at least one gate failed.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/.." && pwd)"

# Ordered list of offline gates. Each entry is a path relative to the repo root, so gates that live
# outside tests/conformance/ (e.g. control/selftest.sh) run from their real location.
GATES=(
	"tests/conformance/check_headers.sh"
	"tests/conformance/check_ppn_wording.sh"
	"tests/conformance/no_contact_leak.sh"
	"tests/conformance/no_custom_crypto.sh"
	"tests/conformance/validate_configs.sh"
	"tests/conformance/no_legacy_transport.sh"
	"tests/conformance/no_insecure_tls.sh"
	"tests/conformance/no_operated_network_claim.sh"
	"tests/conformance/per_protocol_toggle.sh"
	"tests/conformance/no_full_tunnel_default.sh"
	"tests/conformance/transport_family_independence.sh"
	"tests/conformance/no_dataplane_pii.sh"
	"tests/conformance/phase0_port_canon.sh"
	"tests/conformance/node_update_artifact_root.sh"
	"tests/conformance/unit_netlink_parity.sh"
	"tests/conformance/live_artifact_posture.sh"
	"tests/conformance/dependency_policy.sh"
	"tests/conformance/bundle_region_closed_vocab.sh"
	"tests/conformance/bundle_go_roundtrip.sh"
	"tests/conformance/spine_binary_build.sh"
	"tests/conformance/engine_load_check.sh"
	"tests/conformance/active_probe_owncert.sh"
	"tests/conformance/sub_channel_not_single_point.sh"
	"tests/conformance/node_two_hop_failclosed.sh"
	"tests/conformance/no_new_control_decisions_in_bash.sh"
	"tests/conformance/no_reserved_jq_vars.sh"
	"tests/conformance/vocab_single_source.sh"
	"tests/conformance/detector_state_closed_vocab.sh"
	"tests/conformance/detector_pure_no_probe.sh"
	"tests/conformance/tuner_pure_advisory.sh"
	"control/selftest.sh"
)

pass=0
fail=0
declare -a RESULTS=()

printf '########################################\n'
printf '# Mycelium offline conformance suite\n'
printf '########################################\n'

for g in "${GATES[@]}"; do
	gate="$REPO_ROOT/$g"
	printf '\n========================================\n'
	printf '>> %s\n' "$g"
	printf '========================================\n'
	if [ ! -f "$gate" ]; then
		printf 'run.sh: gate not found: %s\n' "$gate" >&2
		RESULTS+=("MISSING  $g")
		fail=$((fail + 1))
		continue
	fi
	# Run via bash so an un-chmod'd gate still executes.
	if bash "$gate"; then
		RESULTS+=("PASS     $g")
		pass=$((pass + 1))
	else
		RESULTS+=("FAIL     $g")
		fail=$((fail + 1))
	fi
done

printf '\n########################################\n'
printf '# Summary\n'
printf '########################################\n'
for r in "${RESULTS[@]}"; do
	printf '  %s\n' "$r"
done
printf '\n  total: %d   passed: %d   failed: %d\n' "$((pass + fail))" "$pass" "$fail"

if [ "$fail" -ne 0 ]; then
	printf '\nrun.sh: OFFLINE SUITE FAILED (%d gate(s)).\n' "$fail" >&2
	exit 1
fi
printf '\nrun.sh: all offline gates passed.\n'
exit 0
