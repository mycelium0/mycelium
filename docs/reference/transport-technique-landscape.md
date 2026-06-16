<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Reference: Transport & Technique Landscape

> **Document type.** Living reference (evidence annex). This is the **rationale and watch-list
> annex to [ADR-0010](../adr/0010-phase0-transport-set.md)** — the transport-set *decision*. ADR-0010
> holds the bound decision; this document holds the **evidence**, the per-technique classification, and
> the **watch-list** that feeds future decisions. It does not itself bind anything: it informs ADR
> amendments and the dependency-policy version pins.
>
> **last-verified: 2026-06-16** (2026-06-16: corrected the Hysteria2+Salamander HAVE claim against the
> code — Salamander obfs is design-spec'd but not wired, Audit-0005 C02. Prior full sweep 2026-06-14.)
> (single doc-level verification date; per-row `Source` columns cite the
> primary upstream reference). Refresh cadence: **(a)** re-check every WATCH trigger on **each engine-pin
> bump** in the dependency policy; **(b)** a **quarterly source sweep** of the public technique-tracking
> forums and reachability-measurement reports cited below. Each refresh updates this date.

## Metadata

- **Layer(s):** data plane (transport); informs control plane (config render, dependency pins)
- **Phase:** evidence for Phase 0 currency work and Phase 1–2 inert schema; routing/topology items
  deferred to Phase 3+ per ADR-0027 / VIS-0009
- **Related:** [ADR-0010](../adr/0010-phase0-transport-set.md) (the decision this annexes),
  [ADR-0002](../adr/0002-no-custom-cryptography.md) (no custom crypto),
  [ADR-0016](../adr/0016-software-releases-not-an-operated-network.md) (software, not an operated network;
  the Canonical Rule "not a universal bypass substrate"),
  [ADR-0022](../adr/0022-two-port-reality-default.md) (two-port REALITY, default-off legs),
  [ADR-0026](../adr/0026-anastomosis-bridges-and-safe-defaults.md) (closed-by-default),
  [ADR-0027](../adr/0027-selective-growth-and-in-region-ingress.md) + VIS-0009 (Selective Growth;
  in-region ingress; node-hop egress), VIS-0007 (fungi-served subscription)

---

## 1. Executive read

Mycelium is at the frontier on the transport **set**, but trailing on **maintenance currency** and on
two structural problems that no transport fixes.

The Phase-0 set already contains every distinct, currently-effective **shape** a frontier service
deploys — REALITY+Vision, REALITY+gRPC, REALITY+XHTTP, genuine-TLS XHTTP, WS+TLS, Hysteria2 (bare; Salamander obfs
design-spec'd but **not yet wired** — Audit-0005 C02), TUIC, AmneziaWG, ShadowTLS — so the universality
test is **substantially passed** on shape breadth (engine gaps: MASQUE; and the Salamander QUIC-obfs wiring). Consistent with the Canonical Rule (ADR-0016), this is breadth of indistinguishable shapes, **not
a universal bypass substrate**.

The honest weaknesses are:

- **(a) Operational currency.** uTLS CVE pins, REALITY post-quantum / post-handshake patches, and
  AmneziaWG 2.0 are shipped upstream and we are behind on adopting them. These are now **load-bearing for
  indistinguishability**, not optional polish.
- **(b) Engine asymmetry.** The strongest 2025–26 hardening (post-quantum REALITY, post-handshake mimicry,
  VLESS-Encryption, AmneziaWG 2.0) lives in the Xray / userspace-awg engines — **not** in sing-box (our
  primary). This is the single most-repeated finding and it validates ADR-0010's engine-diversity escape
  hatch.
- **(c) Two unsolved exposures we must not pretend to have beaten.** The cross-layer RTT fingerprint
  (NDSS'25 class — defeats all content obfuscation, protocol-agnostic) and the destination-AS download
  throughput throttle are answered **only at the routing/topology layer** (ADR-0027), **never claimed
  beaten at the transport layer**.

We are **not** behind on protocol breadth. We are behind on version hygiene, and we have
correctly-identified-but-unclosed gaps in **distribution resilience** (subscription-fetch over the tunnel)
and **timing defense**.

---

## 2. HAVE — already covered

These shapes are in the Phase-0 set today and remain effective in 2026. "Effective in-region / out-of-region"
follows the ADR-0027 topology split (in-region ingress; out-of-region carried node-to-node).

| Technique | Our form | Still effective 2026? | Conf. | Source |
|---|---|---|---|---|
| VLESS + REALITY + XTLS-Vision | ADR-0010 #1, TCP/443, sing-box-served | **Yes, in-region.** Out-of-region degraded (lab handshake break patched upstream; out-of-region connection-policing). Treat as in-region ingress (ADR-0027). | High | github.com/XTLS/Xray-core |
| VLESS + REALITY + gRPC | ADR-0010 #2, TCP/8443 | Yes, as an independent TLS-family fallback. | High | github.com/XTLS/REALITY |
| VLESS + REALITY + XHTTP (stream-up / stream-one / packet-up) | ADR-0010 #3, Xray | Yes — strongest HTTP-framed shape; the up/down split targets the Sept-2025 single-connection TLS-in-TLS classifier. | High | github.com/XTLS/Xray-core/discussions/4113 |
| VLESS + XHTTP over genuine single-layer TLS (real cert, non-REALITY) | Current set (RP-0007-a); HAVE-the-design for the naive-client and the standards-track web-tunnel / HTTPT patterns | Yes — the doctrine-clean answer to TLS-in-TLS; CDN-frontable. **Not yet in the ADR-0010 table — doc gap.** | High | github.com/net4people/bbs/issues/318 |
| VLESS + WebSocket + TLS (CDN-frontable) | Current set; covers the domain-fronting-successor role + the Outline SS-over-WS pattern | Yes, as the broadest-compatibility CDN fallback. **Not yet in the ADR-0010 table — doc gap.** | High | github.com/XTLS/Xray-core |
| Hysteria2 (bare) — Salamander obfs + H3 masquerade DESIGN-spec'd, **not yet wired** | ADR-0010 #4, sing-box; default-off per ADR-0022. Bare Hysteria2 (TLS + h3) is HAVE. The Salamander+masquerade design exists in ADR-0010 but is **NOT in the deployed render path**: `render_singbox.sh` has no obfs logic, and the placeholder-bearing `server.template.json` was inert (tags never matched) and was removed when the renderer template became canonical (Audit-0005 C02). | Bare: yes where UDP survives. Salamander (which removes the parseable SNI): **a pre-enablement GAP**, must be wired before the QUIC leg is enabled in a hostile-QUIC network. | High | github.com/apernet/hysteria |
| TUIC v5 (QUIC) | ADR-0010 #5, sing-box; default-off | Yes — QUIC fingerprint diversity. | High | github.com/EAimTY/tuic |
| AmneziaWG (Jc/Jmin/Jmax, S1–S2, H1–H4) | ADR-0010 #9, separate userspace awg service | **Yes — current survivor.** Obfuscated UDP lives where TCP-TLS dies (matches field observation). | High | github.com/amnezia-vpn/amneziawg-go |
| ShadowTLS v3 (wrapping SS-2022) | ADR-0010 #7, default-OFF per ADR-0022 | Wounded (active-probe differential); keep OFF as a diversity leg, do not promote. | Med | github.com/ihciah/shadow-tls |
| Trojan / Shadowsocks-2022 (bare) | ADR-0010 #8 / #6, optional fallbacks | Weak alone; correct as independent-failure-mode fallbacks. | Med | github.com/shadowsocks/shadowsocks-rust |
| uTLS fingerprint mimicry | Implicit via REALITY (both engines bundle a uTLS fork) | Mechanism HAVE; **currency is the gap** — see ADOPT #1. | High | github.com/refraction-networking/utls |
| QUIC Initial SNI-slicing (client-side) | Transitive via the QUIC library default-on (sing-box 1.12+ / Xray pins) | Yes, inherited by version-pinning. | Med-High | github.com/quic-go/quic-go |
| Remote-profile auto-update loop + `profile-update-interval` | RP-0007-b; VIS-0007 | Yes — universal, mandated in the sing-box client spec. | High | sing-box.sagernet.org |
| Client-side multi-sub merge + urltest / least-ping failover | RP-0007-c/d; `myceliumctl aggregate` (local merged profile) | Yes — the authoritative, decentralization-preserving failover signal. | High | sing-box.sagernet.org |
| Per-client config negotiation (UA / `x-device-os`) | VIS-0007; RP-0007 per-engine render | Yes — standard panel capability. | High | github.com/XTLS/Xray-core |
| Heterogeneous out-of-band bootstrap (messenger / email / QR / mirrors) | ADR-0011 carriers + VIS-0007; Inoculum (RP-0005) | Yes — distribution-system lineage; keep the heterogeneity. | High | gitlab.torproject.org/tpo/rdsys |
| XHTTP gRPC-header / SSE masquerade | Internal mode of XHTTP (HAVE) | Yes. | High | github.com/XTLS/Xray-core/discussions/4113 |

---

## 3. ADOPT — current, fits doctrine, take now

Ranked by leverage. "Effort" = implementation / doc cost. "Phase" follows ADR-0013 discipline: 0 =
version-pin / inert knob hardening; 1 = config-render seam; 2 = inert schema only.

| # | Technique | What it buys | Engine | Phase | Verdict | Effort | Source |
|---|---|---|---|---|---|---|---|
| 1 | **uTLS currency + selectable fingerprint** (pin ≥ 1.8.2-equiv; per-environment fingerprint knob; prefer Firefox / randomized; **never the Chrome-PQ profile with REALITY**) | Closes the 2026 uTLS CVEs; keeps the handshake inside the real-browser post-quantum population; dodges the mid-2026 browser-fingerprint freeze (Firefox / Edge profiles pass, Chrome / Safari profiles flagged) | both | 0 (pin + inert knob) / 3 (adaptive) | **adopt** | Low | github.com/refraction-networking/utls |
| 2 | **REALITY post-quantum handshake** (X25519MLKEM768 + optional ML-DSA-65) — pin a PQ-capable donor (cert > 3500 B; verify with `xray tls ping`) | Stays inside the ~57%-and-rising browser X25519MLKEM768 population (a passive-detection signal); PQ MITM / harvest-now-decrypt-later resistance | **Xray** (sing-box lacks it; gated-off there) | 0 hardening | **adopt** | Low-Med | github.com/XTLS/Xray-core |
| 3 | **REALITY post-handshake mimicry** (NewSessionTicket conformance) — pin Xray ≥ v26.3.27 (min v25.6.8); add a conformance probe | Closes the active-probe differential against OpenSSL-backed donors | **Xray** (sing-box **not** patched — record as an engine gap) | 0 dependency-policy | **adopt** | Low | github.com/XTLS/Xray-core |
| 4 | **AmneziaWG 2.0** (H1–H4 ranged, S3–S4, per-packet padding; **retain** the I1–I5 controlled-packet-signature from 1.5; do **NOT** spec itime / J1–J3 — removed upstream) | Per-packet randomization beats the static-parameter fingerprinting that got AmneziaWG v1 detected | **awg** (separate userspace service; sing-box rejected AWG 2.0 — the split is now permanent) | 0/1 transport hardening | **adopt** | Med (rollout: not 1.x-compatible) | github.com/amnezia-vpn/amneziawg-go |
| 5 | **Donor / destination-selection + engine-pin hygiene** (re-scoped: pin the patched engine and verify the probe runs, not manual ticket-matching) | Hardens the HAVE'd REALITY shapes; verifies the unix-socket probe-skip trap | Xray-primary; sing-box parity unverified | 0/1 ops checklist | **adopt** (re-scoped) | Low | github.com/XTLS/Xray-core/issues/5675 |
| 6 | **XTLS announce + profile-title + support-url headers** (de-facto, not ratified; **skip** the subscription-userinfo quota — it is PII) | The honest off-the-shelf "your link is rotating / update now" operator→user signal; fills the VIS-0007 sub-hour rotation gap | client-side (common subscription clients) | 1 (RP-0007-b) | **adopt** | Low | github.com/XTLS/Xray-core |
| 7 | **Distribute a coarse / neutral split-tunnel routing profile** (region buckets only; **never** named-resource / block-list rules per RP-0005 §5.4) | Pushes the ADR-0027 Selective-Growth policy to clients automatically; add a `routing_profile_neutral` conformance gate | client routing (Xray / sing-box) | 1 (RP-0007 seam) | **adopt** (narrowed) | Med | github.com/XTLS/Xray-core |
| 8 | **TLS-fragment advisory field** in the bundle / Inoculum `transport_profiles` (operator-tunable; document as SNI-DPI-only, **orthogonal** to the throughput-throttle finding) | A cheap, complementary SNI-DPI layer; per-network tuning | sing-box 1.12+ / Xray | 1 | **adopt** (narrow, low-pri) | Low | sing-box.sagernet.org |
| 9 | **XHTTP asymmetric `downloadSettings`** (download leg constrained to a Mycelium node, **never** a TLS-terminating CDN front per ADR-0027) | An up/down flow-symmetry break; an **instrument** of the ADR-0027 in-region-ingress / node-egress topology — **not** an independent throttle cure | **Xray only** (sing-box never) | 2 inert schema | **adopt** (downgraded by verdict to PARTIAL / track-leaning) | Med | github.com/XTLS/Xray-core/discussions/4113 |

> **Verdict note on #9.** The adversarial verdict is *watch*, because its headline claim ("beats the
> ~16 KB throughput throttle") re-proposes an ADR-0027-rejected option **unless** it is tied to
> in-region / node-to-node legs. It is listed here at the boundary; for strict verdict-purity it belongs
> in WATCH. It is kept as a Phase-2 **inert-schema** adopt because the schema work is doctrine-clean and
> the topology binding is exactly ADR-0027. The destination-AS throughput throttle is **not** claimed
> beaten at the transport layer.

---

## 4. WATCH — current and doctrine-compatible, but not adopt-now

| Technique | Why watch (not adopt) | Re-evaluate trigger | Source |
|---|---|---|---|
| **MASQUE / CONNECT-UDP** | **The one true engine gap.** No proxy-grade implementation in sing-box (issue open) or Xray (closed not-planned); deployed MASQUE services are already SNI-blocked in high-pressure environments. | sing-box / Xray ships it **and** QUIC-SNI hardening lands. Any adoption must be **node-to-node only** (ADR-0027). | datatracker.ietf.org/doc/rfc9298 |
| **VLESS Encryption (mlkem768x25519plus)** | Not a reach technique (author: "not for wall-crossing"); Xray-only (sing-box issue deleted). Marginal value only on the CDN / XHTTP path. | sing-box parity **and** a concrete CDN-MITM threat. Scope to XHTTP / WS Xray paths, **not** REALITY shapes. | github.com/XTLS/Xray-core/discussions/4825 |
| **anytls** | Dynamic padding is real, but the endpoint is probeable (no REALITY); deterministic 7-byte header / opcodes / heartbeat. anytls+REALITY is incidental; one major client declined it. | anytls+REALITY becomes first-class via an author PR **and** the header / SETTINGS are de-fingerprinted. | github.com/net4people/bbs/issues/528 |
| **QUIC-Initial SNI hardening (server-side)** | The client-side half is already HAVE; the only residue is server hygiene (high non-443 UDP destination-port + a real `server_name`). | A thin ADOPT for the two server-hygiene items in ADR-0010 (filed follow-up). | github.com/quic-go/quic-go |
| **Salamander / gecko QUIC obfs** | Contingent on a QUIC adoption that is already HAVE; the gecko variant is alpha-only (interop broken upstream). | Default-on attribute when QUIC legs are activated; gecko once stable. | github.com/apernet/hysteria |
| **ECH** | A block-trigger in some high-interference networks; redundant against REALITY; the 2026 GREASE-ECH CVE is a liability. Keep as a non-default per-route option on genuine-TLS CDN paths only. | Region measurements show ECH passes; never on REALITY, never default. | datatracker.ietf.org/doc/draft-ietf-tls-esni |
| **Fake-desync / TTL / TCP-seq injection** | Not in stable engines (the Xray PR is unmerged; sing-box refused); needs raw-socket privilege; shapes the in-region leg that should not need it; does not touch the throttle. **fitsDoctrine = false as written.** | The Xray PR merges a privilege-light mode to stable. Track-only. | github.com/XTLS/Xray-core/pulls |
| **SNI spoofing (sing-box spoof)** | 1.14-alpha-only; client-egress + raw-socket (outside ADR-0016 node scope); redundant with the REALITY donor-SNI. fitsDoctrine = false. | A stable release **and** an SNI-allowlist regime where the donor-SNI is insufficient. | github.com/SagerNet/sing-box |
| **Mux (Mux.Cool / smux / h2mux)** | Itself a fingerprint; rejected alongside Vision upstream; head-of-line blocking hurts lossy survivor paths. | Only as padding-aware sessions **inside** anytls, if anytls is ever adopted. Keep Vision un-muxed. | github.com/XTLS/Xray-core/issues/1567 |
| **Client-vendor provider rotation (new-domain / new-url / fallback-url)** | A server-pushed migration has the same reach-the-old-origin weakness as the 301/308 redirect (VIS-0007); a Provider-ID is a centralized third-party registry. **fitsDoctrine = false.** | `fallback-url` may *ride* a doctrine-correct ≥ 2-origin design, for that client's users only. | (vendor docs) |
| **Subscription-fetch-over-tunnel** | The biggest **unsolved** distribution gap. No client guarantees it; the ADR-0027 split-tunnel makes incidental tunneling *less* likely. | Keep best-effort + open research; do **not** make it an acceptance line (RP-0007 AC-b4 is correct). | github.com/net4people/bbs |
| **Auto-CDN / clean-IP rotation** | Props up the most-throttled path; the tooling is bound to one CDN, but our last-resort slot is on a different edge. | Only the *pattern* (rotating a clean edge IP) when the non-default last-resort slot activates, post-Phase-1. | (CDN tooling) |
| **Shadowsocks-2022-over-WS+TLS+CDN** | Survival is carrier-derived (we HAVE VLESS+WS+TLS+CDN); the SS-2022 inner layer adds no reach value. | Only if interop with an SS-family client becomes a goal. | github.com/shadowsocks/shadowsocks-rust |
| **Cross-layer RTT de-correlation** | **UNCLEAR — no deployable defense exists.** Defeats all content obfuscation; protocol-agnostic (NDSS'25 class). | Record as a known residual exposure; prefer the direct-splice Vision / single-hop path; revisit when a vetted pluggable-transport defense ships. **Do not over-claim that the set defeats ML classifiers.** | gfw.report |
| **Empty / omitted-SNI (browser-fingerprint-freeze dodge)** | Conflicts with REALITY (which needs a real SNI); fragile. | An L0-sensing input → prefer a UDP / no-SNI leg; not a standing default. | github.com/net4people/bbs |

---

## 5. SKIP — deliberately not adopted

| Technique | Doctrine reason | Source |
|---|---|---|
| VMess | Forbidden by ADR-0010; TLS-in-TLS + high passive-detection rate — dominated by VLESS on every axis. | github.com/XTLS/Xray-core |
| WireGuard (plain) | Forbidden by ADR-0010; fingerprintable handshake — retained only via AmneziaWG, never bare. | github.com/amnezia-vpn/amneziawg-go |
| juicity | Same QUIC failure class as TUIC (HAVE); adds engine surface, no distinct failure mode. | github.com/juicity/juicity |
| httpupgrade | Same CDN / HTTP niche as WS + XHTTP (both HAVE); being retired upstream under XHTTP — a dominated surface. | github.com/XTLS/Xray-core |
| naive-client (the *engine*) | The Chromium / network-stack benefit is client-side; a server inbound confers nothing; the design is HAVE via RP-0007-a. | github.com/klzgrad/naiveproxy |
| meek / classic domain fronting / domain shadowing | Third-party TLS termination = user de-anonymization (ADR-0027); out-of-region CDN = the same destination-AS throttle (VIS-0009 §1b). | gitlab.torproject.org/tpo/pluggable-transports/meek |
| Snowflake | Needs a central broker + a volunteer-proxy commons; software, not an operated network (ADR-0016); DTLS-fingerprint treadmill. | gitlab.torproject.org/tpo/pluggable-transports/snowflake |
| Refraction / decoy-routing (station-on-path) | Requires on-path ISP / AS station cooperation that Mycelium operators structurally cannot have (ADR-0016). | refraction.network |
| obfs4 | High-entropy "look-like-nothing" is itself the tell (USENIX'23); our mimicry-over-randomization stance is the correct side. | gitlab.torproject.org/tpo/pluggable-transports/obfs4 |
| ECH-as-relay-feature | A property of a CDN-class TLS terminator, not a self-operated relay; REALITY solves SNI-hiding in-doctrine. | datatracker.ietf.org/doc/draft-ietf-tls-esni |
| Inter-packet timing / token-bucket pacing | Broken by 2025–26 traffic-analysis attacks at an unacceptable cost; orthogonal to the load-bearing RTT / TLS-in-TLS threats. | gfw.report |
| `x-hwid` / device-ID headers | A stable per-device identifier = user de-anonymization; software-not-a-paid-service has no device accounting (VIS-0007 S0). | github.com/XTLS/Xray-core |
| Centralized management panel as backend | The exact single-point-of-block / global-map / coercion anti-pattern VIS-0007 dissolves; steal only the per-node render. | (panel projects) |
| SIP008 (SS-specific subscription) | The network is VLESS+REALITY / AWG; the XTLS JSON + Clash export already meet the typed-subscription need. | github.com/shadowsocks/shadowsocks-org |
| Single-vendor soft-DRM link wrapping | Single-vendor soft-DRM + bespoke key wrapping (ADR-0002); the Inoculum signed-and-TTL'd bundle is the standard-primitive equivalent. | (vendor docs) |
| TCP-fragment + fake-TTL desync (as a node feature) | Client / endpoint behavior against local DPI; Mycelium is node software, not a client (ADR-0016). | github.com/XTLS/Xray-core |
| Hysteria2 "brutal" congestion control as anti-throttle | A custom congestion-control algorithm is the most legible behavioral fingerprint (FOCI'25, ~100% separability) → use BBR, not brutal. | github.com/apernet/hysteria |

---

## 6. Recommended next steps (priority order)

1. **Write a Phase-0 dependency-policy + conformance ADR/amendment** that pins uTLS ≥ 1.8.2-equiv,
   Xray ≥ v26.3.27 (post-handshake mimicry), and adds a **post-handshake conformance probe** plus a
   **uTLS-fingerprint-currency check** to the gate set. This single action covers ADOPT #1, #3, and #5 and
   is the highest-leverage hygiene work. *(Low effort, high impact.)*
2. **Amend ADR-0010** to **(a)** add the two missing-but-HAVE transports — genuine-TLS XHTTP and
   WS+TLS+CDN — to the decision table (close the doc gap), and **(b)** record the **engine-asymmetry
   escape-hatch** explicitly: post-quantum REALITY / post-handshake mimicry / VLESS-Encryption / AWG 2.0
   are Xray/awg-only, sing-box parity tracked. Add the QUIC server-port / `server_name` hygiene note.
3. **Enable post-quantum REALITY on the Xray path** (ADOPT #2): a donor-vetting checklist
   (X25519MLKEM768 + cert > 3500 B), off-by-default on sing-box until upstream parity. Track sing-box for
   ML-KEM ClientHello handling.
4. **Spec the AmneziaWG 2.0 upgrade** (ADOPT #4) as an ADR-0010 amendment + a dependency-pin bump +
   a controlled-packet-signature snapshot-currency note; correct the I1–I5 provenance (from 1.5, retained)
   and forbid itime / J1–J3.
5. **Reconcile VIS-0007** on the 301/308 redirect: the "refuted as a documented standard" wording is now
   **stale** — the XTLS standard mandates 301/308 as a MUST. Correct it to "documented but doctrinally
   insufficient as a sole resilience mechanism (single point of block)," then add the
   **announce / profile-title / support-url** signaling subset (ADOPT #6) to RP-0007-b.
   *(Flag: a live doc-vs-reality contradiction; not yet fixed in the tree.)*

---

## 7. Unverified / flagged for the maintainer

- **sing-box REALITY post-handshake-mimicry parity** — no changelog entry found; treat REALITY-via-sing-box
  as **PARTIAL** for the post-handshake active-probe differential until confirmed. Argues for serving
  REALITY via Xray where post-handshake conformance matters, or filing a sing-box upstream issue.
- **The VIS-0007 301/308 contradiction is real and unfixed** in the tree (confirmed at the cited lines).
- **Version provenance** (corrected against the survey): the REALITY post-handshake fix first landed in
  v25.6.8; VLESS-Encryption landed in v25.8.31.
- **The cross-layer RTT fingerprint and the destination-AS download throttle remain honestly unsolved at
  the transport layer.** Do not let the breadth of the set imply otherwise; both are answered (partially)
  only by the ADR-0027 topology plus transport diversity. Per the Canonical Rule (ADR-0016), Mycelium is
  **not a universal bypass substrate**.

