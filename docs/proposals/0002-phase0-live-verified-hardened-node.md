<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Refactoring / Change Proposal — Phase 0: scaffold → live, verified, hardened single node

> **Document type.** Refactoring / Change Proposal. Structure matches
> [../refactoring.md](../refactoring.md) and
> [../templates/refactoring-proposal.md](../templates/refactoring-proposal.md).
> This RP takes the landed Phase 0 scaffold (RP-0001) to a live, verified, hardened
> **single** node on a freshly provisioned VDS, ending exactly at the Phase 0
> Definition of Done. It pulls **no** Phase 1+ mesh, migration, or distribution
> work forward.

---

## Metadata
- **ID:** RP-0002
- **Date:** 2026-06-12
- **Author:** mindicator & silicon bags quartet
- **Status:** draft
- **Phase:** Phase 0 (single deploy-ready, multi-protocol node)
- **Related documents:**
  [RP-0001](0001-bootstrap-phase-0-node.md) (scaffold this builds on);
  [ADR-0010](../adr/0010-phase0-transport-set.md) (Phase 0 transport set);
  [ADR-0002](../adr/0002-no-custom-cryptography.md) (no custom cryptography);
  [ADR-0012](../adr/0012-go-primary-control-plane-language.md) (Go as the primary control-plane language);
  [ROADMAP.md](../ROADMAP.md) (Phase 0 DoD, lines 82–97);
  [THREAT-MODEL.md](../THREAT-MODEL.md);
  [SECURITY.md](../../SECURITY.md);
  [dependency-policy.md](../dependency-policy.md);
  [docs/runbooks/deploy-node.md](../runbooks/deploy-node.md).

## 1. Title
Bring the Phase 0 multi-protocol scaffold up on a real VDS and verify, harden, and
document it until every Phase 0 Definition-of-Done item is checkably true on a live node.

## 2. Reason
RP-0001 landed a deploy-ready scaffold on `main` but its own acceptance criteria
([0001-bootstrap-phase-0-node.md](0001-bootstrap-phase-0-node.md) §7) are all still
unchecked `[ ]`: "live deployment and DoD verification pending an operator-provided
server." The Phase 0 DoD ([ROADMAP.md](../ROADMAP.md) lines 82–91) is defined entirely
in terms of *observed behaviour on a running node* — config retrieved over a restrictive
link, two transports reachable at once, active probing returning a donor response,
one-command deploy, live credential revocation, no excluded legacy transport present.
None of that can be asserted from the offline conformance suite alone, which validates
*intent and shape* but never touches a running node.

The operator is about to buy a VDS to test on. Before that, the work-on-paper has to be
turned into an ordered, verifiable bring-up plan, because reading the scaffold surfaced
concrete defects that will silently break a first live deploy:

- **Control↔Ansible CLI contract break.** `roles/singbox/tasks/main.yml` calls
  `myceliumctl render-server --input …` and a non-existent `render-client … --out-dir …`;
  the real tool exposes `render-server --params/--state/--template/--out` and
  `subscription --params/--state/--out`. Both tasks use `failed_when: false`, so they
  silently no-op and the role *always* falls back to Jinja/inline-jq paths. The tool is
  shipped to the node but never actually drives a live render.
- **Per-protocol auth mismatches.** SS-2022 password format and TUIC password-vs-UUID
  diverge across the Jinja template, the jq fallback, and the standalone tool — at least
  one client/server pair will fail to authenticate without reconciliation.
- **No genuine TLS cert path for the QUIC/Trojan trio.** Hysteria2/TUIC/Trojan present a
  real leaf cert for the node's own hostname, but nothing in the production shape issues
  it (Caddy ACME only runs in the forbidden standalone shape B).
- **Observability node-side surface missing.** The `dataplane_stats` (`:9550`) exporter is
  never installed, the role-rendered config has no `clash_api` block, and the
  `SingBoxDown` textfile gauge is never produced — two of four Prometheus jobs cannot
  succeed on a real node.
- **The one live verification step is mis-wired.** `cover_site_probe.sh` parses
  `--node/--donor`, but the deploy runbook invokes it positionally — the documented
  active-probing check breaks on first use.
- **Hardening claims outrun code.** SSH is only UFW-rate-limited (no managed `sshd_config`),
  and the no-logs/RAM-only posture is a stated target, not yet an enforced invariant.

Left as-is, the project looks "done" and is not deployable. This RP exists to close those
gaps and produce the live, verified, hardened node that the DoD demands — and nothing more.

## 3. Scope
- **Layers:** data plane (the 9 Phase 0 transports), infra (provisioning + deploy),
  observability (health signals), and the thin control/identity surface that renders
  per-node configs and revokes credentials. **No** routing, discovery, coordinator, or
  carrier/spore layer.
- **Components:** `infra` (Terraform + Ansible), `singbox` data-plane role, `amneziawg`
  role, `cover` site, `identity`/`myceliumctl` render+revoke surface, `observability`
  stack, the offline + post-deploy conformance suite, and the deploy/rollback runbooks.
- **Contracts:** the `myceliumctl` CLI contract (must converge with the Ansible role);
  the config-distribution/subscription format consumed by off-the-shelf clients
  (sing-box / Clash-Meta); the per-protocol `group_vars` toggle names; the canonical
  port map; the observability metric/target schema. **No** new wire protocol or
  schema is invented — only existing contracts are reconciled and exercised live.
- **Storage / state:** node-local state dir (`/var/lib/mycelium`, root-only), `identity.json`
  (0600), REALITY private key + client UUIDs (generated on the node, reused on re-run),
  genuine TLS cert/key (gitignored on node), Caddy cover state repointed to gitignored
  paths. No user PII is stored anywhere.
- **Flows:** one-command deploy-from-zero; per-protocol bring-up under systemd;
  cover-site / donor handshake; credential issue/revoke without redeploy; PII-safe
  health signalling; post-deploy active-probe + per-protocol reachability + anti-DPI
  smoke verification; rollback by teardown/redeploy.
- **Schemas / formats:** no new format. Reconcile the SS-2022/TUIC credential
  conventions and converge the two divergent sing-box templates so what `selftest.sh`
  validates is what gets deployed.

### 3.1. Component participation table (mandatory)

| Component | Role in this RP | Status | External tech | Why not existing tool |
|---|---|---|---|---|
| `infra/terraform` | Stands up one VDS + firewall + SSH key; outputs the node IPv4 | active | Terraform + hcloud | Provider-standard provisioning; no in-house cloud orchestration. |
| `infra/ansible` (`hardening`) | UFW default-deny, rate-limited SSH, sysctl, unattended-upgrades; **adds** managed `sshd_config` + journald volatile posture | active | Ansible + system shell | OS/host hardening is configuration, not custom code. |
| `singbox` role + `nodes/dataplane/singbox` | Renders & runs the 8 sing-box inbounds under a sandboxed systemd unit; converged to one canonical template | active | sing-box | Transport engine; ADR-0002 forbids in-house transport/crypto. |
| `vless-reality` (Xray) template | Optional alternative TLS engine for the VLESS-REALITY path (incl. true XHTTP if required) | passive | Xray-core | Reference engine; chosen per node, not run alongside sing-box. |
| `amneziawg` role | Runs the separate UDP path; opens its own UDP port in the host firewall | active | AmneziaWG | Obfuscated WireGuard engine; key material only from `awg gen*`. |
| `cover` (`nodes/cover`) | Benign origin for handshake-less hits; reconciles sing-box↔origin fallback wiring | active | Caddy | Web server; no custom HTTP stack. |
| `identity` / `myceliumctl` | Generates key material via sanctioned generators, renders per-node config + subscription, revokes a credential without redeploy; CLI contract converged with the role | active | sing-box / xray / openssl / awg | Thin orchestration over sanctioned generators only (ADR-0002); no byte invention. |
| `observability` | Installs the node-side stats exporter + textfile gauge; PII-safe metrics, alerts, blackbox probes | active | Prometheus / Alertmanager / blackbox / node_exporter | Standard monitoring stack; no custom telemetry pipeline. |
| `tests/conformance` | Offline 9-gate suite + post-deploy live gates (cover-site, per-protocol reachability, anti-DPI smoke, revoke/recovery) | active / test-only | system shell / openssl | Verification harness; no third-party tool fits the bespoke checks. |
| `control-agent` skeleton (`myceliumd`/`myceliumctl` in Go) | W7: typed config model + health + thin CLI parity (the spine) | active | Go ([ADR-0012](../adr/0012-go-primary-control-plane-language.md)) | Establishes the compiled spine; the interference detector / auto-rotation logic stays deferred to Phase 2. |
| `coordinator` (network registry / rerouting) | Not built here | deferred | none | Activates in a later RP (Phase 3); inert in Phase 0. |

### 3.2. Blast-radius cap
> One RP = one manageable step.

This RP **exceeds** the single-step cap and is therefore declared **multi-phase**
(seven ordered workstreams W1–W7 in §5). The justification is that "go live" is a single
*responsibility* (turn the existing scaffold from inert to running-and-verified) that
cannot be cut smaller without leaving a node that is provisioned but unreachable,
reachable but unverified, or verified but undocumented for rollback — none of which is a
DoD-meeting deliverable. Crucially, **no responsibility boundary moves between
components, no layer changes behaviour, and no config-distribution surface changes
shape** — the work reconciles and exercises existing contracts, it does not redraw them.

- **Responsibility boundaries affected:** 0 (boundaries unchanged; contracts reconciled).
- **Layers affected (behaviour):** 0 new behaviours; existing layers brought from inert to live.
- **Config-distribution surfaces affected:** 0 new surfaces (the existing subscription
  contract is fixed to render correctly, not changed in shape).
- **Files in diff (estimate):** ~35–60 (role tasks/templates, exporter unit, runbooks,
  conformance gates, CHANGELOGs, ADR if engine/cert decisions are anchored, plus the W7 Go
  control-agent skeleton: `cmd/`, `internal/`, `go.mod`, CI).
- **New code in W7:** the Go control-agent spine
  ([ADR-0012](../adr/0012-go-primary-control-plane-language.md)) re-implements the *existing*
  thin operator surface (render / identity / health) at contract parity — it adds no
  client-facing contract and no adaptation behaviour (detector / rotation stay deferred to
  Phase 2).

- [ ] Within cap — single-step RP.
- [x] Exceeds cap → **declared multi-phase** (workstreams W1–W7 below). No client-facing
  contract, layer-behaviour, or distribution-surface shift; ordered so master stays green
  between workstreams (each ends on its own DoD with offline gates passing).

  Phase breakdown: W1 provision+harden → W2 per-protocol live bring-up + key generation →
  W3 cover-site/REALITY donor → W4 observability/health → W5 post-deploy conformance &
  anti-DPI smoke → W6 runbooks/rollback/docs → W7 Go control-agent skeleton (the spine,
  [ADR-0012](../adr/0012-go-primary-control-plane-language.md)). W1 is a prerequisite for all
  others; W2–W4 proceed against the live node; W5 gates exposure; W6 lands the operational
  record; W7 stands up the compiled spine **after** the node is live and verified ("spine
  early, glue stays shell").

## 4. Current state
The scaffold is structurally complete and security-conscious but entirely **inert** —
every config is sentinel-only by design, nothing has real values, and no node exists.
Specifically:

- **Data plane.** Nine Phase 0 transports exist as templates: eight sing-box inbounds in
  `nodes/dataplane/singbox/server.template.json` (vless_reality_vision tcp/443,
  vless_reality_grpc tcp/8443, vless_reality_xhttp tcp/2096, hysteria2 udp/8444,
  tuic udp/8445, shadowsocks2022 tcp+udp/8388, shadowtls tcp/8446, trojan tcp/8447),
  plus the optional Xray-only VLESS-REALITY engine in
  `nodes/dataplane/vless-reality/server.template.json`, plus AmneziaWG udp/51820 as a
  separate role (`nodes/dataplane/amneziawg/awg0.conf.template`). Every key/secret is a
  `SENTINEL_*` placeholder; all `users: []` arrays are empty. Caveats: the xhttp inbound
  is a sing-box HTTP-transport *substitute*, not true XHTTP (XHTTP is Xray-only); the
  sing-box REALITY inbounds have **no `fallbacks`/origin wiring**, so the cover origin on
  `127.0.0.1:8080` is unreferenced by sing-box; and there is **no mechanism that issues
  the genuine TLS cert** the Hysteria2/TUIC/Trojan inbounds require.
- **Control / render.** `myceliumctl` works in isolation (`reality-keys`, `identity
  add|revoke|list`, `render-server`, `subscription`; all key material via sanctioned
  generators; offline `selftest.sh` is green), but the Ansible singbox role calls a
  *different, non-existent* CLI contract and silently falls back, so the tool never
  renders on a node. The role's Jinja template and the canonical jq template have
  materially different shapes (clash_api present/absent, obfs/masquerade present/absent,
  xhttp `type` differs), and SS-2022/TUIC credential conventions diverge across the three
  code paths.
- **Infra.** Terraform stands up one Hetzner server + firewall (22/tcp tightenable,
  443/tcp, opt-in extra TCP/UDP ports) and outputs the IPv4. `bootstrap.sh` is a
  fail-closed entrypoint that refuses on un-replaced placeholders, but its post-run
  summary scans only `*.txt` (real subscriptions are `*.singbox.json`) and still names a
  stale "xray role." AmneziaWG UDP host-firewall opening must be confirmed in that role
  (the `hardening` role opens only SSH + `listen_port`).
- **Observability.** The control-host stack is well-designed and explicitly PII-safe
  (node_exporter loopback-only, aggregate counters, cover log `output discard`), but the
  node side of the contract is missing: no `:9550` `dataplane_stats` exporter is
  installed, the role-rendered config has no `clash_api` block, and no textfile collector
  produces `mycelium_dataplane_unit_active` — so `DataPlaneDown`/`SingBoxDown` cannot
  function on a real node.
- **Verification.** The offline suite (`tests/run.sh`) runs nine static gates
  (`check_headers`, `check_ppn_wording`, `no_contact_leak`, `no_custom_crypto`,
  `no_legacy_transport`, `validate_configs`, `per_protocol_toggle`, `phase0_port_canon`,
  `control/selftest.sh`). The only live gate, `tests/conformance/cover_site_probe.sh`, is
  excluded from `run.sh` and is invoked incorrectly (positional args) in
  `docs/runbooks/deploy-node.md`. There is no per-protocol reachability gate, no
  anti-DPI/first-packet smoke check, and no automated revoke/recovery assertion.
- **Hardening.** The systemd sandbox and UFW posture are strong, but SSH has no managed
  `sshd_config` and the no-logs/RAM-only posture is a target in `SECURITY.md §4.2`, not an
  enforced state (journald writes to disk).

## 5. Target state
A single VDS running the Phase 0 data plane with at least two independent transport shapes
live at once, presenting a genuine donor response to active probing, deployed from zero in
one command, with one credential revocable without redeploy, no excluded legacy transport
present, PII-safe health signalling, and a fail-closed verification gate that refuses to
hand out subscriptions if indistinguishability checks are red — with deploy and rollback
runbooks that match the code. Effect on the four template axes:

- **Indistinguishability.** The primary REALITY path returns the donor's real leaf cert and
  (newly verified) a donor-matching post-handshake message sequence; the cover origin
  serves a benign, link-clean static page; active probing of any non-enabled port gets no
  answer and no banner. The deploy gate blocks exposure on a red probe. (Threat-model rows
  *Signature-based DPI*, *Active probing*.)
- **Survivability / path redundancy.** Two or more transport shapes are reachable
  simultaneously and per-protocol `group_vars` toggling removes exactly one inbound while
  the rest keep working — the Phase 0 form of path redundancy. (Single IP/AS remains a
  single blocking point — explicitly a Phase 1/2 concern, see Non-goals.)
- **Adaptation speed.** Out of Phase 0 scope as automated recovery (the interference
  detector / auto-rotation is `deferred`). What this RP delivers is the *manual* recovery
  primitives — revoke-without-redeploy, idempotent re-deploy, `Restart=on-failure`, and a
  documented key/donor rotation drill — verified to actually take effect.
- **Control-plane network persistence.** Out of Phase 0 scope (no coordinator/registry).
  The thin control surface here is node-local render + revoke; nothing depends on a
  network-wide control plane, and nothing introduces a centralisation dependency.

The plan is organised as seven ordered workstreams.

---

### W1 — VDS provisioning & base hardening
**Goal.** A reachable, hardened, key-only host with exactly the intended ports exposed,
deployable from zero with one command.

**Steps.**
1. Provision one VDS via `infra/terraform` (or bring-your-own-VPS via Ansible as the
   primary path); capture the `server_ipv4` output. Select an IP on an AS with no
   known-tainted reputation; keep 1–2 fresh IPs in reserve (operator doctrine).
2. Run `scripts/bootstrap.sh`; confirm it refuses on any un-replaced placeholder /
   `REPLACE_WITH_SHA256` (fail-closed entrypoint).
3. Add a managed `sshd_config` drop-in in the `hardening` role enforcing
   `PasswordAuthentication no`, `PubkeyAuthentication yes`,
   `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password` (or a sudo user
   + `PermitRootLogin no`), `MaxAuthTries`, modern Ciphers/KEX/MACs, and
   `AllowUsers`/`AllowGroups` — making key-only the enforced end state, not a comment.
4. Add the no-logs/RAM-only posture as a deploy option: journald `Storage=volatile` (or
   aggressive `MaxRetentionSec`/`MaxFileSec`), confirm no transport writes an access log.
5. Verify the `amneziawg` role opens its own UDP port in the host firewall (the
   `hardening` role opens only SSH + `listen_port`); add the rule if missing.
6. Verify supply-chain integrity: the live install path must verify
   sing-box/xray/AmneziaWG/Caddy artifact hashes against the pinned versions+checksums
   (`dependency-policy.md`) and fail closed on mismatch.

**Definition of Done.** Host reachable over SSH **only** with a key; UFW default-deny with
only SSH + enabled-protocol ports (incl. AmneziaWG UDP) open; node_exporter/cover bind
loopback only; one-command deploy succeeds from zero; artifact hashes verified.

**Verification.**
- `ssh -o PasswordAuthentication=no -o PubkeyAuthentication=no <node>` is refused;
  key-based login succeeds.
- On the node: `sudo ufw status verbose` shows default deny inbound and only the intended
  ports; `sudo ss -tulpn` shows node_exporter/cover on `127.0.0.1` only.
- `sshd -T | grep -E 'passwordauthentication|permitrootlogin|pubkeyauthentication'`
  matches the enforced values.
- `systemctl show systemd-journald -p Storage` (or retention) reflects the chosen posture.
- A clean re-run of the one-command deploy is idempotent (no spurious key rotation).

**Dependencies / ordering.** Prerequisite for W2–W6.

**Risks + mitigations.** Locking yourself out via SSH hardening → keep a console/recovery
path open and verify key login *before* disabling password auth. Provider lock-in
(Terraform is Hetzner-only) → acceptable for Phase 0; AS-diversity is a Phase 1 concern
(Non-goal). **Threat-model:** *Operator coercion* (no-logs/RAM posture = "what is not
collected cannot be compelled"); *Active probing* / *Node compromise* (minimal exposed
surface; hardened host).

---

### W2 — Per-protocol live bring-up + sanctioned key generation
**Goal.** Each enabled transport authenticates a real off-the-shelf client end-to-end,
with all key material from sanctioned generators only.

**Steps.**
1. **Reconcile the `myceliumctl` ↔ Ansible CLI contract** (the highest-priority gap).
   Pick one and implement it: either rewrite `roles/singbox/tasks/main.yml` to build a
   params/state file and call the real `render-server --params/--state/--template/--out`
   and `subscription --params/--state/--out`, **or** grow `myceliumctl` the
   `--input`/`render-client … --out-dir` contract the role expects. Remove the
   `failed_when: false` masking so a render failure is loud, not a silent fallback.
2. **Converge the two sing-box templates** so the role renders the same canonical template
   `selftest.sh` validates (clash_api block, obfs/masquerade, xhttp `type`). Eliminate the
   "dead convenience" copy.
3. **Reconcile credential conventions:** one SS-2022 password format and one TUIC
   password-vs-UUID convention across the Jinja template, the jq fallback, and the
   standalone tool. Make client-TLS `insecure: true` for self-signed hy2/tuic/trojan a
   conscious, documented choice (W3 may replace it with a genuine cert), not a silent
   default.
4. **Generate all key material via sanctioned generators only** (ADR-0002): REALITY X25519
   keypair (`sing-box generate reality-keypair` / `xray x25519`); short_id
   (`openssl rand -hex 8`); client UUIDs (`sing-box generate uuid` / `xray uuid`);
   Salamander obfs pw (`openssl rand -base64 24`); SS-2022/ShadowTLS-inner PSK
   (`openssl rand -base64 32`); Clash-API secret (`openssl rand -hex 16`); AmneziaWG keys
   (`awg genkey | awg pubkey`, optional `awg genpsk`). Keys are generated **on the node**,
   stored 0700 root-only, Ansible tasks `no_log: true`; only the REALITY **public** key +
   rendered subscription leave the node.
5. **Capture the REALITY public-key handoff (Gap C):** confirm the render/identity layer
   surfaces the public key (+ short_id, donor SNI, UUID, flow) into the client
   subscription — a usable node depends on it.
6. **Reconcile registry/doc inconsistencies (Gap E) before wiring firewall/group_vars:**
   pick one SS-2022 toggle name (`enable_ss2022` vs `enable_shadowsocks_2022`); reconcile
   the ShadowTLS port (PORTS.md `8446` is source of truth vs protocols.md `8843`); confirm
   Trojan's in/out-of-scope status for the DoD; align xhttp engine decision (accept the
   sing-box HTTP substitute, or run Xray for true XHTTP, Gap D).
7. Fill the AmneziaWG obfuscation knobs respecting `Jmin<Jmax`, distinct `H1..H4`,
   `S1+56≠S2`; discover `WAN_IF` via `ip route show default`; choose RFC1918/ULA tunnel
   ranges; render `[Peer]` blocks per client.

**Definition of Done.** At least the primary VLESS-REALITY:443 path **plus one more**
transport authenticate a real sing-box / Clash-Meta client end-to-end; `myceliumctl`
actually renders on the node (not a fallback); per-protocol `group_vars` toggling
adds/removes exactly the intended inbound; no excluded legacy transport is present.

**Verification.**
- Offline: `tests/run.sh` green (incl. `no_custom_crypto`, `no_legacy_transport`,
  `per_protocol_toggle`, `phase0_port_canon`, `control/selftest.sh`).
- On the node: `sing-box check -c <config>` passes; for each enabled protocol an
  off-the-shelf client connects and reaches the open internet (manual smoke per protocol;
  automated in W5).
- A live `myceliumctl render-server`/`subscription` run on the node produces the deployed
  config (verify the role no longer silently falls back).
- `group_vars` flip of one `enable_*` toggle → re-run → that inbound's port stops
  answering while the others keep working.

**Dependencies / ordering.** After W1. W2.1 (CLI contract) blocks W2.3/W2.5 and W4. The
genuine-cert work (W3) unblocks dropping `insecure: true` for hy2/tuic/trojan.

**Risks + mitigations.** Credential-convention mismatch → live per-protocol connect test
is the gate; do not mark the protocol done on render success alone. Engine choice for
xhttp → decide explicitly and record in the ADR; do not ship a substitute as "true
XHTTP." **Threat-model:** ADR-0002 / *no custom cryptography* (sanctioned generators
only); *Node compromise* (keys on-node, root-only, public-only egress, forward secrecy
from the transports); *Knowledge minimisation* (empty `users:[]` until issued; no user
attribution).

---

### W3 — Cover site / REALITY donor
**Goal.** Active probing of the node returns a genuine donor-shaped response; a casual
visitor to the node's own IP sees a benign, link-clean page.

**Steps.**
1. **Select the REALITY donor (operator TODO, no safe default):** a real, popular,
   always-up external site serving TLS 1.3 **and** HTTP/2, **not** on your own
   provider/AS and not a CDN edge you also use, low-latency to the node. Verify with
   `openssl s_client -connect host:443 -alpn h2 -tls1_3` showing `ALPN protocol: h2`. Set
   `SENTINEL_DONOR_SNI`/`SENTINEL_DONOR_HOST` (and the ShadowTLS outer handshake host).
2. **Donor-fidelity vetting (new pre-deploy step):** characterise the real donor's TLS 1.3
   post-handshake behaviour (NewSessionTicket count/lengths, ALPN, cert chain) so the
   operator picks a donor whose behaviour the node can reproduce. Prefer donors that send
   *no* post-handshake tickets where possible (immune to the NewSessionTicket
   distinguisher).
3. **Resolve the sing-box ↔ cover fallback (Gap A):** decide whether the Phase 0
   "probe sees a benign page" criterion is met by REALITY donor-relay alone on sing-box,
   or whether a fallback inbound to `127.0.0.1:8080` must be added. If sing-box is the
   chosen engine, either wire the fallback or document that donor-relay is the accepted
   mechanism and Caddy's `127.0.0.1:8080` origin is intentionally unreferenced.
4. **Establish the genuine TLS cert path (Gap B)** for Hysteria2/TUIC/Trojan: issue a real
   leaf cert for the node's own hostname via ACME DNS-01, or a :80 challenge completed
   *before* the data plane binds :443 — never the forbidden Caddy standalone shape B on a
   data-plane box. Cert/key gitignored on node; wire the three inbounds'
   `SENTINEL_TLS_*` paths.
5. **Bring up the cover site:** customise `nodes/cover/site/index.html` to neutral content
   consistent with the donor; **remove the broken links** it ships (`/notes/`, `/photos/`
   404 → a tell); keep it static, no project/network wording, no forms/admin/API. In the
   `Caddyfile`, replace `admin@example.com` via a gitignored override, repoint
   `root`/`log` to gitignored state paths, keep `output discard`, pin Caddy ≥ v2.10.2,
   `caddy validate --config ./Caddyfile`.

**Definition of Done.** Active probing of `<node>:443` with the donor SNI returns the
donor's real leaf cert and a benign donor-shaped HTTP response; the genuine cert exists and
is presented by hy2/tuic/trojan; the cover origin page is benign and link-clean; no
extraneous port or banner answers.

**Verification.**
- `tests/conformance/cover_site_probe.sh --node <node> --donor <donor> [--port 443]
  [--sni <sni>]` passes: TLS handshake completes, leaf Subject/SAN matches the donor,
  best-effort plain-HTTPS GET returns a benign donor-shaped status.
- `openssl s_client -connect <node>:443 -servername <donor>` shows the donor cert chain.
- For hy2/tuic/trojan: the presented cert is the genuine node-hostname cert, not a
  self-signed placeholder.
- `curl -skI https://<node>/` (direct IP) returns the benign cover page with no
  project/network wording and **no 404s** for linked paths.

**Dependencies / ordering.** Donor selection (W3.1) precedes W2 REALITY render values; the
genuine-cert path (W3.4) unblocks dropping `insecure: true` in W2.3.

**Risks + mitigations.** Bad donor choice (your-AS / no h2 / unreliable) → enforce the
checklist and the `s_client` ALPN check; vet post-handshake fidelity before deploy. Cover
page tells (broken links, non-static, project wording) → static + link-clean + neutral, no
forms. **Threat-model:** *Active probing* (donor response, no extraneous ports/banners);
*Signature-based DPI* (REALITY/Vision donor fidelity); *Operator coercion* (`output
discard`, no client PII in cover logs).

---

### W4 — Observability + health signals (PII-safe)
**Goal.** A PII-safe health surface where the four Prometheus jobs can actually succeed on
a real node, with no per-user data anywhere.

**Steps.**
1. **Add the node-side `clash_api` block** to the role's rendered config (or switch the
   role to the canonical template per W2.2) so a `127.0.0.1:9090` stats surface exists; set
   `SENTINEL_CLASH_API_SECRET` (`openssl rand -hex 16`) so it is authenticated.
2. **Install the `dataplane_stats` exporter** on `127.0.0.1:9550` reading the clash_api and
   re-exposing aggregate counters only — **or**, if that is too much for Phase 0, remove
   the `dataplane_stats` job and `DataPlaneDown` alert from scope. Decide explicitly; do
   not leave a permanently-dead job.
3. **Wire the node_exporter textfile collector** (`--collector.textfile.directory=…` in
   `node_exporter.service.j2`) + a small unit/timer writing
   `mycelium_dataplane_unit_active{engine="singbox"}` so `SingBoxDown` can fire correctly
   — or drop the alert.
4. **Keep the PII-safe invariants** (verify, don't rebuild): node_exporter binds
   `127.0.0.1:9100` and is never firewall-opened; only inbound/aggregate counters, never
   per-user; blackbox probes are unauthenticated and never open a tunnel; cover log
   discards.
5. **Optional Phase 0 measurement add (single-node, no mesh):** add a throttling-aware
   health signal — TLS-handshake completion time as a goodput proxy with a per-node
   baseline, flagging ~10x degradation — and layer CUSUM/EWMA + RFD-style hysteresis on
   the flat `HighHandshakeFailureRate` rule to give the operator a false-positive story.
   This is an *observability* addition only; it does **not** trigger any automated
   rotation (that is `deferred`).

**Definition of Done.** All four Prometheus jobs (`node_exporter`, `dataplane_stats` —
unless explicitly dropped, `blackbox_handshake`, `blackbox_tcp`) succeed against the live
node; `SingBoxDown`/`DataPlaneDown` reflect real state; no per-user/PII metric exists.

**Verification.**
- Through the SSH tunnel: `curl -s 127.0.0.1:9100/metrics` and `127.0.0.1:9550/metrics`
  return aggregate metrics; `127.0.0.1:9090` answers with the clash_api secret.
- `promtool check rules observability/prometheus/rules.yml` passes; in Prometheus all
  four targets are `up`.
- Grep the exporter output: no client IPs, destinations, or identity attribution.
- Stop sing-box → `SingBoxDown`/`DataPlaneDown` fire; restart → clear.

**Dependencies / ordering.** After W2 (needs the rendered config + clash_api). Independent
of W3.

**Risks + mitigations.** Re-introducing PII via a too-chatty exporter → assert
aggregate-only and grep for PII in the metric output as a gate. Permanently-dead jobs
masquerading as "observability up" → either install the surface or remove the job; no dead
alerts. **Threat-model:** *Operator coercion* / *Knowledge minimisation* (aggregate-only,
loopback-only, no per-user data — the no-logs posture is the coercion defence); *Node
compromise* (no client attribution to exfiltrate).

---

### W5 — Post-deploy conformance & anti-DPI / indistinguishability smoke verification
**Goal.** A fail-closed verification gate that proves the live node meets the DoD before it
is handed any subscriptions.

**Steps.**
1. **Fix the `cover_site_probe.sh` runbook invocation** (positional args → `--node/--donor`
   flags) in `docs/runbooks/deploy-node.md` §6 so the documented active-probe step works
   on first use.
2. **Per-protocol reachability gate (new):** for each `enable_*: true` protocol confirm the
   port answers with the expected handshake shape — TCP-connect + TLS for TCP transports,
   a QUIC/UDP liveness probe for Hysteria2/TUIC, an AmneziaWG handshake check for the UDP
   path. Reuse the observability split (`mycelium_tcp_connect` vs
   `mycelium_tls_handshake`) to separate AS-blocking from handshake interference.
3. **Anti-DPI / first-packet smoke checks (new):**
   - *First-packet entropy/printable audit* — capture the node's first client→server bytes
     and confirm they would not be classed as fully-encrypted (set-bits-per-byte outside
     the ~3.4–4.6 band, or a TLS-record/printable prefix present). Passes by construction
     for the REALITY path; the real guardrail is for any other enabled transport and
     against config drift. Can run statically on a captured handshake (extends the offline
     suite) and live.
   - *Length-preserving check* — confirm no transport adds tell-tale fixed byte offsets to
     mimicked framing.
   - *No extraneous ports/banners* — confirm only enabled-protocol ports answer and nothing
     leaks a tunnel banner.
4. **REALITY post-handshake fidelity assertion (new):** confirm the node's post-handshake
   message sequence (NewSessionTicket count/lengths) matches the donor characterised in
   W3.2 — closes the most current real-world distinguisher against the primary transport.
5. **Revoke / recovery assertions (new):** assert that `myceliumctl identity revoke`
   actually stops the revoked UUID from authenticating while others keep working; that a
   re-deploy is idempotent (keys reused, not rotated); and that `Restart=on-failure`
   recovers a killed service.
6. **Wire the gate fail-closed into bootstrap:** a node that fails the active-probe /
   anti-DPI smoke checks must **not** be handed subscriptions. Today the runbook only
   *recommends* the probe; make a red probe block exposure.

**Definition of Done.** Every Phase 0 DoD item is checkably true on the live node:
config retrieved over a restrictive link → open internet over an enabled transport;
≥2 transports reachable at once with single-toggle removal working; active probing returns
a genuine donor response; one-command deploy + credential revoke without redeploy; no
excluded legacy transport present. The deploy gate refuses exposure on a red probe.

**Verification.**
- `tests/run.sh` green (all offline gates).
- `tests/conformance/cover_site_probe.sh --node … --donor …` green (now correctly invoked).
- Per-protocol reachability gate green for every enabled transport; anti-DPI first-packet
  audit reports exempt (not blockable) for each enabled transport; no extraneous
  port/banner answers.
- REALITY post-handshake sequence matches the vetted donor.
- Revoke test: revoked UUID is rejected, a peer UUID still authenticates; killed service
  restarts; second deploy run changes nothing (idempotent).
- The DoD "two transports at once + single-toggle removal" demonstrated live.

**Dependencies / ordering.** After W2/W3/W4. This is the exposure gate — nothing is handed
to a user until W5 is green.

**Risks + mitigations.** Probe false-confidence (cert matches but post-handshake differs)
→ add the W5.4 fidelity assertion, don't rely on cert identity alone. Self-probes must
target only benign/operator-controlled endpoints and look like ordinary handshakes — never
user-chosen destinations. **Threat-model:** *Active probing* and *Signature-based DPI* /
*ML-based flow classification* (first-packet + post-handshake + length checks);
*Knowledge minimisation* (revoke verified; no user data logged by the probes).

---

### W6 — Ops runbook, rollback, and docs/CHANGELOG updates
**Goal.** The operational record matches the code, and the node is reversible fast.

**Steps.**
1. Update `docs/runbooks/deploy-node.md` end-to-end to the corrected, ordered procedure
   (W1→W5), including the fixed `cover_site_probe.sh` invocation and the per-protocol /
   anti-DPI / revoke verification steps as numbered checks.
2. Author a **key/donor rotation drill** runbook (neutral wording): rotate REALITY keypair
   / short_ids / client UUIDs and the donor/cover, entirely on the sanctioned generators
   (no new crypto), with a fail-closed note that rotation must not silently downgrade
   indistinguishability. Replace the current "delete the state file and re-run" comment.
3. Fix `scripts/bootstrap.sh`: subscription-summary glob (`*.txt` → also include
   `*.singbox.json`) and the stale "xray role" wording.
4. Document the **rollback / teardown**: how to tear down and redeploy fast (a persistent
   private network — downtime means people without access), what to preserve (state dir,
   reserve IPs/ASes), and fail-closed behaviour during rollback (no silent security bypass,
   no exposure of an unverified node).
5. Land the documentation changes enumerated in §8 (CHANGELOG/version bumps in the same
   commit as each touched component; ADR if engine/cert/observability-scope decisions are
   architecturally significant; update RP-0001 §7 / ROADMAP DoD checkboxes only after W5
   proves them).

**Definition of Done.** The deploy runbook reproduces a green W1→W5 from zero on a fresh
VDS by a second operator; a rotation drill and a rollback procedure exist and are tested;
all touched components have CHANGELOG entries + version bumps; bootstrap summary reports
real subscription files.

**Verification.**
- A dry second run from the runbook on a fresh VDS reaches a green W5 with no undocumented
  steps.
- Rotation drill executed once: keys/donor rotated via sanctioned generators, node still
  passes W5, indistinguishability not downgraded.
- Rollback drill: teardown + redeploy completes within the documented time; reserve IP/AS
  available.
- `git log` shows version bumps + CHANGELOG entries co-located with code; commit subjects
  are type-prefixed with a `Refs: RP-0002` trailer (development.md §6.2).

**Dependencies / ordering.** Last; consumes the verified node from W5. The ROADMAP/RP-0001
DoD checkboxes are flipped only after W5 is green.

**Risks + mitigations.** Doc drift (runbook says X, code does Y) → the second-operator dry
run is the gate. Rotation silently weakening indistinguishability → fail-closed note +
re-run W5 after any rotation. **Threat-model:** *Operator coercion* (rollback preserves the
no-logs posture; no data to compel); *Active probing* (rollback never exposes an unverified
node — fail-closed).

---

### W7 — Go control-agent skeleton (the spine)
**Goal.** With the node live and verified (W1–W6), stand up the compiled control-agent
**spine** in Go ([ADR-0012](../adr/0012-go-primary-control-plane-language.md)) so the hard
construction exists from the start and shell is permanently demoted to deploy glue + CI gates.
This workstream builds a **skeleton only** — it ports the existing thin operator surface to a
typed binary and adds health; it does **not** add the interference detector or auto-rotation
(those remain deferred to Phase 2).

**Steps.**
- Initialise the Go module and the package layout from ADR-0012: `cmd/myceliumctl`,
  `cmd/myceliumd`, `internal/engine` (sing-box adapter first), `internal/state`,
  `internal/observability`, `internal/spec` (typed config / identity / health schemas).
- `myceliumctl` (Go) reaches **contract parity** with the shell tool for the Phase 0 surface:
  `reality-keys`, `identity add|revoke|list`, `render-server`, `subscription`. Key material is
  still produced ONLY by the sanctioned `sing-box` / `xray` / `openssl` / `awg` generators
  (ADR-0002); the binary invents no bytes.
- `myceliumd` (Go) runs as a long-running, sandboxed systemd unit doing only the Phase-0-safe
  jobs: read node state, supervise the engine unit, expose a **PII-safe** health/readiness
  endpoint and the `dataplane_stats` / textfile signals W4 defined (typed, replacing the shell
  exporter), and reload on config change. No policy/rotation logic yet (inert interfaces only).
- Establish the Go quality bar from ADR-0012: `gofmt` / `golangci-lint`; build & test with the
  **race detector** (`go test -race ./...`); `context.Context` throughout; bounded worker pools;
  `internal/spec` carries strict, versioned schemas with vectors under `test-vectors/`.
- Add the conformance check from ADR-0012's Compliance section: stateful control logic must live
  in the Go module, not in shell (deploy glue excepted). Wire `go vet` / `-race` / tests into CI.
- Migrate the Ansible roles to drive the Go `myceliumctl` for render/identity once parity is
  proven (resolving the W2 CLI-contract reconciliation in the compiled tool); keep the shell tool
  only until the binary is the default.

**Definition of Done.** A single static `myceliumctl` binary renders a node config +
subscription and revokes a credential at parity with the shell tool (W5 still green when the node
is deployed from the Go-rendered config); `myceliumd` runs under systemd and serves the PII-safe
health + `dataplane_stats` signals that W4's Prometheus jobs consume; `go test -race ./...` is
green in CI; the "stateful-logic-not-in-shell" gate passes; the package layout and quality bar
match ADR-0012. **No** detector or auto-rotation logic is present.

**Verification.**
- `go build ./...` and `go test -race ./...` green in CI; `golangci-lint` clean.
- A node deployed from the **Go**-rendered `server.json` + subscription passes the full W5 live
  suite (parity with the shell render).
- `myceliumctl identity revoke <id>` on the Go tool removes access without redeploy (re-run of
  the W5 revoke/recovery assertion).
- `myceliumd` `/healthz` returns PII-safe readiness; the W4 `dataplane_stats` job scrapes the Go
  exporter; a `no_pii`-style review of every emitted field passes.
- The ADR-0012 compliance gate flags zero detector/rotation keywords in shell (deploy glue
  excepted).

**Dependencies / ordering.** Last; runs **after** W5 has verified the live node and W6 has landed
the operational record ("spine early, glue stays shell" — the shell+Ansible bring-up proves the
node first, then the spine is compiled). Supersedes the shell `myceliumctl` incrementally; the
shell tool is retained until the binary is the default.

**Risks + mitigations.** Scope creep into Phase-2 adaptation → W7 is a skeleton by definition;
detector/rotation are out of scope and gated by the compliance check. Go-render drifting from the
shell render → parity is proven by re-running the full W5 suite against the Go-rendered config
before the shell tool is retired. New toolchain in CI → pin the Go version in `go.mod`; `-race`
and lint are required gates. **Threat-model:** *Operator coercion* (the Go health surface stays
PII-safe and no-logs — it adds no data to compel); *Active probing* (the spine changes no exposed
transport surface; W5 re-verifies indistinguishability after the migration).

---

## 6. Risks
- **Compatibility.** No existing clients or nodes to break (RP-0001 never went live), so
  the schema/credential reconciliations carry no parallel-release burden. The one real
  compatibility concern is internal: the converged sing-box template and reconciled
  SS-2022/TUIC conventions must be applied across the role, the jq fallback, and the
  standalone tool together, or a client/server pair silently fails to authenticate — gated
  by the W2/W5 live connect tests.
- **User security (requirement №1).** This RP must not introduce de-anonymisation, logging,
  PII in telemetry, or correlation. Concrete watch-items: the observability exporter must
  stay aggregate-only and loopback-only (W4); `insecure: true` on client TLS for
  hy2/tuic/trojan is a self-safety smell that W3's genuine cert is meant to retire — keep
  it a conscious, documented interim, never a silent default; no transport may write an
  access log. The no-logs/RAM-only posture (W1) is the coercion-resistance measure.
- **Indistinguishability / probe surface.** Breadth (9 transports) enlarges the attack
  surface; per-protocol toggling is the operator's lever (keep only what is needed enabled).
  Donor choice and the cover page are the dominant indistinguishability risks — mitigated
  by the W3 donor checklist + fidelity vetting and the W5 first-packet/post-handshake/length
  checks. The xhttp substitute must not be presented as true XHTTP.
- **Loss of observability/measurements.** If the `dataplane_stats`/`SingBoxDown` surfaces
  are dropped rather than installed (a W4 option), the operator loses those signals —
  acceptable for a single test node only if explicitly chosen and the dead jobs/alerts are
  removed, not left red.
- **Temporary degradation.** Bring-up is on a fresh node with no users, so there is no live
  traffic to degrade. Re-runs reuse key material (no accidental rotation), so iterating is
  safe.
- **Flapping / false migrations.** No auto-rotation exists in Phase 0, so there is no
  false-migration risk to manage; the optional W4.5 hysteresis is purely to give the
  operator a calmer manual signal, not to act.
- **Rollback risk.** Low — teardown/redeploy the node; no existing clients to break
  (carried over from RP-0001 §6). The discipline is fail-closed: never expose a node that
  has not passed W5.
- **Impact on decentralisation.** None — the control surface is node-local render + revoke;
  no coordinator/registry dependency is introduced, so no hidden centralisation.

## 7. Acceptance Criteria
- [ ] A user on a restrictive network connection retrieves the config endpoint and reaches
  the open internet over an enabled transport (live, end-to-end).
- [ ] At least two independent transport shapes are reachable at once; disabling one in
  `group_vars` removes only that inbound and leaves the others working.
- [ ] Active probing of the server returns a genuine donor-site response, not a suspicious
  one.
- [ ] Node is deployed from zero with a single command; a client credential is revoked
  without reinstalling the node (revoke-takes-effect verified live).
- [ ] No excluded legacy transport (VMess, plain Shadowsocks, plain WireGuard, OpenVPN,
  L2TP/IPsec, PPTP, SSTP, IKEv2) is present on the node (ADR-0010).
- [ ] Off-the-shelf clients (sing-box / Clash-Meta) connect using the standard endpoint
  parameters, on the primary path **and** at least one more transport.
- [ ] Conformance green: `no_custom_crypto`, `cover_site_probe` (correctly invoked),
  plus the offline 9-gate `tests/run.sh` (`check_headers`, `check_ppn_wording`,
  `no_contact_leak`, `no_legacy_transport`, `validate_configs`, `per_protocol_toggle`,
  `phase0_port_canon`, `control/selftest.sh`).
- [ ] PII-safety holds: no client IPs/destinations/identity attribution in any metric or
  log; node_exporter loopback-only; cover log discards.
- [ ] Per-protocol post-deploy reachability gate green for every enabled transport;
  anti-DPI first-packet audit reports each enabled transport as exempt (not blockable);
  no extraneous ports/banners answer.
- [ ] REALITY post-handshake sequence matches the vetted donor (W3.2/W5.4).
- [ ] Recovery verified: revoked UUID rejected while peers authenticate; `Restart=on-failure`
  recovers a killed service; re-deploy is idempotent.
- [ ] Survivability/recovery not degraded: handshake success rate healthy; the two
  available manual-recovery primitives (revoke, idempotent re-deploy) work.

> netsim/netem adversary scenarios (`rst_injection`, `as_blackhole`, `udp_drop`) exercise
> the *detector/rotation* response, which is `deferred` to a later phase. Phase 0's live
> adversary check is `active_probe` (the cover-site / anti-DPI gates above); the netem
> block→recover scenarios are explicitly out of scope here (see Non-goals).

### Non-goals (deferred to later phases — not in this RP)
- **Multi-node / network** — a second node, network registry, coordinator, cross-node config
  distribution (Phase 3).
- **Interference detector & auto-rotation logic** — the detector and automated recovery on a
  blocking event; the single IP/AS remains a single point of blockage by design (Phase 2). Only
  the *manual* recovery primitives are in scope. (The Go control-agent **skeleton/spine** that
  will later host this logic *is* in scope — W7,
  [ADR-0012](../adr/0012-go-primary-control-plane-language.md); the adaptation logic is not.)
- **AS-diversity provisioning** — a second cloud-provider Terraform example (Phase 1).
- **Carrier-agnostic spores, DHT, trust gradients, learning federation, autonomous cord
  promotion** — must not run in Phases 0–2 (ROADMAP scope discipline, MYC-F006); only
  inert data models/interfaces are permitted.
- **Client application / client-facing UX** — QR codes, subscription UI, per-client
  failover as a client feature, the client app itself (RP-0001 §3 out-of-scope, unchanged).
- **netem block→recover scenarios** (`rst_injection`/`as_blackhole`/`udp_drop`) as
  pass/fail gates — they validate Phase 2 rotation behaviour.

## 8. Documentation changes
- [ ] [../runbooks/deploy-node.md](../runbooks/deploy-node.md) — corrected end-to-end W1→W5
  procedure; fixed `cover_site_probe.sh` invocation; per-protocol / anti-DPI / revoke
  verification steps; donor-vetting step.
- [ ] `docs/runbooks/rotate-keys.md` (new) and updates to `rotate-ip-as.md` — neutral
  key/donor rotation drill on sanctioned generators, fail-closed against silent
  indistinguishability downgrade.
- [ ] [../THREAT-MODEL.md](../THREAT-MODEL.md) — note the live first-packet/post-handshake
  anti-DPI checks under *Active probing* / *Signature-based DPI*; confirm the no-logs/RAM
  posture under *Operator coercion* / *Knowledge minimisation*.
- [ ] [../ROADMAP.md](../ROADMAP.md) — flip Phase 0 DoD from pending to met (only after W5
  green); record that automated migration/rotation remains Phase 2.
- [ ] [0001-bootstrap-phase-0-node.md](0001-bootstrap-phase-0-node.md) §7 — check the
  acceptance boxes once verified live; mark RP-0001 superseded/extended by RP-0002 for the
  live-DoD portion.
- [ ] `docs/adr/NNNN-*.md` (new ADR if architecturally significant) — anchor the engine
  choice for xhttp (sing-box HTTP substitute vs Xray true XHTTP), the genuine-cert
  issuance path (Gap B), and the observability node-side scope decision (install vs drop
  `dataplane_stats`/`SingBoxDown`).
- [ ] Contract/registry reconciliation — `PORTS.md`, `protocols.md`: one SS-2022 toggle
  name, one ShadowTLS port, Trojan scope confirmed; the converged sing-box template;
  the reconciled `myceliumctl` CLI contract.
- [ ] Component README/CHANGELOG + version bump (same commit) for each touched component:
  `infra` (hardening/SSH/journald/firewall), `singbox` role, `amneziawg` role, `cover`,
  `control`/`myceliumctl`, `observability`, `tests/conformance`.
- [ ] `scripts/bootstrap.sh` — corrected subscription glob and removed stale "xray role"
  wording (and any related operator-facing doc).

## 9. Migration Strategy
There is no running system to migrate — this is a first bring-up — so "migration" means
**ordered rollout on one fresh node** with green gates between workstreams:

- **Stages.** W1 (provision + harden) → W2 (per-protocol bring-up + keys) → W3
  (cover/donor + genuine cert) → W4 (observability) → W5 (post-deploy conformance + the
  exposure gate) → W6 (runbooks/rollback/docs). W1 is a hard prerequisite; W2–W4 run
  against the live node; **no subscriptions are handed out until W5 is green** (fail-closed
  cutover).
- **Parallel coexistence.** None required — no old clients/nodes/contracts exist. Internal
  contract reconciliations (CLI, templates, credential conventions) are applied atomically
  per component with their CHANGELOG/version bump, validated by `selftest.sh` offline
  before the live run.
- **Final cutover.** The moment W5 passes and the deploy gate goes green, the node is
  exposed and the first subscription is issued. The DoD checkboxes (ROADMAP, RP-0001 §7)
  are flipped only at this point.
- **Old-version nodes during transition.** N/A — single fresh node.
- **Dependencies (rollout order).** node host (W1) → key generation + render on node (W2)
  → donor/cover/cert (W3) → observability surface (W4) → verification gate (W5) → clients
  (subscriptions issued only post-W5).

## 10. Rollback / Fallback
- **How to roll back, and how fast.** Rollback is teardown + redeploy of the single node
  (RP-0001 §6: rollback risk low). Because there are no existing clients, the operator can
  destroy and re-provision quickly; the runbook (W6) documents a target teardown→redeploy
  time. If only a config is bad, re-run the one-command deploy (idempotent, keys reused) to
  reconcile.
- **Data/keys/IPs to preserve.** Preserve the node state dir (`/var/lib/mycelium`,
  `identity.json`, REALITY private key + client UUIDs, genuine TLS cert/key) if the node is
  being re-deployed rather than abandoned; preserve the 1–2 reserve fresh IPs in different
  ASes; never commit any of this to the repo (gitignored, on-node only).
- **Contract/config versions kept in parallel.** None — single node, single engine choice
  (sing-box primary or Xray alternative, not both); no parallel contract release is
  needed.
- **Fail-closed behaviour during rollback.** No silent security bypass: a node that fails
  W5 (cover-site / anti-DPI / per-protocol reachability) is **never** handed subscriptions;
  rollback never disables the no-logs posture or downgrades indistinguishability to "get
  something working." If a rotation or redeploy cannot be verified green, the safe state is
  *not exposed*, not *exposed-but-unverified*. This honours requirement №1 (operator/user
  safety first) and the *Operator coercion* posture (nothing collected to compel even
  mid-rollback).
