<!--
Copyright © 2026 mindicator & silicon bags quartet.
SPDX-License-Identifier: AGPL-3.0-or-later
This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
later. See the LICENSE file in the repository root.
-->

# Research Note — `<short title>` (YYYY-MM-DD)

> **Document type.** Research note template. A dated input for **layer 2**
> (control plane, adaptation layer) and the **Measurements** cross-cutting track:
> feeds the network interference detector and the auto-rotation loop with facts rather than
> assumptions. This is an *input*, not a specification — hypotheses are framed as
> research tasks, not as ready-made production thresholds. The finished note is
> saved as `docs/research/YYYY-MM-DD-<slug>.md` (or `<period>-<slug>.md` for
> digests), slug in kebab-case.
>
> **Cadence.** By agreement of the Measurements track: periodically (e.g.
> quarterly) **or** immediately upon a major blocking event — a large-scale
> block of an entire transport/application class, a new detection family in
> large-scale DPI appliances, or a shift in the network restriction model
> (blacklist→allowlist, blocking→active attack).
>
> **What makes a note "real".** Every conclusion is tied to a source or
> measurement; observable fact, derived inference, and hypothesis (requires
> verification) are clearly separated. Without this it is an opinion, not a
> research note.
>
> **See also:** [vision.md](vision.md), [adr.md](adr.md),
> [refactoring-proposal.md](refactoring-proposal.md),
> [../THREAT-MODEL.md](../THREAT-MODEL.md), [../ARCHITECTURE.md](../ARCHITECTURE.md),
> [../ROADMAP.md](../ROADMAP.md).

---

## Metadata
- **Assembly date:** YYYY-MM-DD
- **Observation period:** <from — to> (individual sources may be older)
- **Author:** mindicator & silicon bags quartet
- **Region(s) / adversary:** <jurisdiction / specific AS / provider — described in
  jurisdiction-neutral terms; no country names>
- **Phase/layer relation:** Phase 0–5 / layer 2 / Measurements track
- **Previous note:** <link or "none — this is the baseline">
- **Related documents:** <Vision / ADR / RP / previous research / external source>

## 1. Question
Exactly what we are investigating, in one or two sentences. Why this matters
**now** and which architectural/detector assumption it may affect. If the trigger
is a blocking incident or wave, describe the trigger.

## 2. Method and sources
- **Method:** how data were obtained — own netsim/netem runs, active measurements
  from nodes, OONI-style measurements, consenting (anonymised) users, third-party
  reports/preprints, manual incident reproduction.
- **Sources:** list with dates/links; note reliability (primary measurement /
  secondary report / unverified claim).
- **Method limitations:** sample size, geographic coverage, possible bias, what
  the data **do not** cover. (Honesty about limitations is mandatory — without
  it the conclusion is overstated.)
- **Reproducibility:** which netsim scenario / command reproduces the observation
  (`rst_injection` / `as_blackhole` / `udp_drop` / `active_probe` / …).

## 3. Findings
> Distinguish: **[fact]** observable · **[inference]** interpretation · **[hypothesis]**
> requires verification.

- **[fact]** … (tied to a source/measurement from §2)
- **[inference]** …
- **[hypothesis]** …

Where numbers exist, present them in a table (handshake success rate, TTFB,
RST fraction, window-to-disconnect, detector precision/recall on labelled
incidents, etc.):

| Signal / metric | Observation | Where / when | Source |
|---|---|---|---|
| … | … | … | … |

## 4. Impact on the network interference detector
What changes in the channel diagnosis. Specifically, per state
`clean / throttled / DPI-blocked / shutdown`:
- new or refined signal (handshake timeout, RST injection, throughput collapse
  after connect, probe failure, loss/jitter);
- proposed threshold/weight adjustment — **as a hypothesis to verify**, not as a
  ready production threshold;
- false-positive / flapping risk and how to measure it (precision/recall on
  labelled incidents).

## 5. Impact on the auto-rotation loop and policy
What changes in the response to a blocking event and in the "what lives where"
policy:
- transport/port/SNI/donor priorities by region (VLESS+REALITY / gRPC /
  CDN-fronting / AmneziaWG / Hysteria2-TUIC);
- obfuscation parameters for A/B tuning (AmneziaWG junk, ClientHello /
  Reality-Vision padding, timings/sizes);
- IP/AS rotation strategy and "last resort" (CDN-fronting);
- impact on the network persistence of the control plane itself (config
  distribution).

## 6. Impact on the adversary model / documents
- Does [../THREAT-MODEL.md](../THREAT-MODEL.md) need updating (new network adversary
  capability, shifted attack/response surface)?
- Does [../ARCHITECTURE.md](../ARCHITECTURE.md) /
  [../ROADMAP.md](../ROADMAP.md) need updating (transport matrix, phase DoD)?
- Should an ADR/RP/Vision be created?

## 7. Open questions
- … (what remains unclear; what data/measurements are needed in the next period)
- … (hypotheses requiring a dedicated experiment or netsim scenario)

## 8. Recommended actions
- [ ] Research task: <gather data / run netsim scenario> — owner, deadline.
- [ ] ADR/RP if the finding is mature: `docs/adr/NNNN-...` / `docs/proposals/NNNN-...`.
- [ ] Update document(s) from §6 if required.
- [ ] Add label to incident dataset for detector evaluation (precision/recall).
