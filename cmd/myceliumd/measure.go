// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/mycelium0/mycelium/internal/detect"
	"github.com/mycelium0/mycelium/internal/measure"
	"github.com/mycelium0/mycelium/internal/reach"
	"github.com/mycelium0/mycelium/internal/spec"
	"github.com/mycelium0/mycelium/internal/tune"
)

// measureConfigVersion is the supported schema version of a measure config.
const measureConfigVersion = 1

// measureMember is one transport member in the measure config — the JSON face of measure.Member. It
// links the opaque reach ref (the join key onto the reachability snapshot) to the closed-registry
// proto and the promote move; class is derived from proto by internal/measure (the single source).
type measureMember struct {
	Ref      string `json:"ref"`
	Proto    string `json:"proto"`
	Action   string `json:"action"`
	FromPort int    `json:"from_port"`
	ToPort   int    `json:"to_port"`
}

// measureConfig is the node-local MEASURE-plane config (RP-0010 Plane 1). It names the transport
// members the node can rotate among, the currently-active member, the rotation policy, and where to
// emit the assembled rotate.PlanInput. It is loaded by myceliumd alongside the reachability config;
// the daemon folds each reach snapshot through internal/measure.Assembler and writes the PlanInput
// the gated rotation loop (RP-0012) consumes. Strictly advisory: producing this input never
// actuates.
type measureConfig struct {
	Version    int                 `json:"version"`              // schema version (measureConfigVersion)
	TickMS     int                 `json:"tick_ms"`              // how often to assemble (>= the reach probe interval)
	ActiveRef  string              `json:"active_ref"`           // the currently-active member (the incumbent), re-read each tick
	OutputPath string              `json:"output_path"`          // where the assembled PlanInput JSON is written (atomically)
	StatePath  string              `json:"state_path,omitempty"` // optional: the shared rotate_state.json (between-tick RotationState)
	Limits     spec.RotationLimits `json:"limits"`               // the rotation policy
	Members    []measureMember     `json:"members"`              // the closed transport set the node rotates among

	// L7LivenessPath (optional) points at the node-local own-cert/cover-path L7 liveness marker the
	// loopback own-keys probe writes ($STATE_DIR/l7_selftest.json). When set, the daemon folds it into
	// each tick's DetectorSignal.ActiveProbeOK so a bound-but-client-DEAD-at-L7 member (a broken REALITY
	// dest) faults blocked — the L4-only blind spot the loopback probe closes (RP-0010 AC-6 clarification).
	// It is fail-safe: an absent/stale/malformed marker yields no L7 signal (healthy), so a probe outage
	// never spuriously faults a member.
	L7LivenessPath string `json:"l7_liveness_path,omitempty"`
	// L7MaxAgeMS is the freshness window for that marker: a marker older than this (by its observed_at)
	// is ignored (fail-safe healthy). Required (> 0) when L7LivenessPath is set.
	L7MaxAgeMS int `json:"l7_max_age_ms,omitempty"`
	// L7MinDeadGenerations is the marker-replay hardening (Audit-0007 S2): a member must be named DEAD
	// across at least this many DISTINCT marker generations (distinct observed_at) before the daemon faults
	// it, so one dead probe run replayed across many ticks cannot satisfy the tick-based anti-flap on its
	// own. Unset (<= 0) defaults to defaultL7MinDeadGenerations (2); an explicit 1 restores the pre-gate
	// fault-on-first-generation behaviour.
	L7MinDeadGenerations int `json:"l7_min_dead_generations,omitempty"`

	// PathSignalPath (optional) points at the node-local PASSIVE path-level served-flow marker the nft
	// RST-rate observer writes ($STATE_DIR/path_signal.json = {reset:[refs]}, RP-0014 chunk B). When set, the
	// daemon folds it into each tick's DetectorSignal: a flagged member has ConnectReset set AND HandshakeOK
	// faulted (the loopback reach probe cannot see real client flows being reset), so detect.Classify reaches
	// its blocked/connection-reset branch and the member is pool-excluded (PathReset). Fail-safe: an
	// absent/stale/malformed marker yields no path signal (healthy), so an observer outage never faults a member.
	PathSignalPath string `json:"path_signal_path,omitempty"`
	// PathMaxAgeMS is the freshness window for that marker (fail-safe healthy past it). Required (> 0) when
	// PathSignalPath is set.
	PathMaxAgeMS int `json:"path_max_age_ms,omitempty"`
	// PathMinResetGenerations is the marker-replay + anti-flap hardening (mirrors L7MinDeadGenerations): a
	// member must be named RESET across at least this many DISTINCT marker generations before the daemon
	// faults it. Unset (<= 0) defaults to defaultL7MinDeadGenerations (2); an explicit 1 faults on the first.
	PathMinResetGenerations int `json:"path_min_reset_generations,omitempty"`
	// PathCollapseEnabled ARMS the PostConnectCollapse fold (RP-0014 chunk B increment 2). It ships DISARMED
	// (false): the observer writes the marker's `collapse` list in SHADOW (for observation), but the daemon
	// does NOT fold it into a rotation-driving verdict until an on-node drill validates the /proc parse and
	// the fire/silence behaviour. When false the daemon still READS collapse but treats it as always-empty.
	PathCollapseEnabled bool `json:"path_collapse_enabled,omitempty"`
	// PathCollapseMinGenerations mirrors PathMinResetGenerations for the collapse signal. Unset (<= 0)
	// defaults to defaultL7MinDeadGenerations (2). Only consulted when PathCollapseEnabled.
	PathCollapseMinGenerations int `json:"path_collapse_min_generations,omitempty"`

	// --- RP-0015 increment B: the client-fingerprint A/B plane (a PARALLEL scalar plane; the transport
	// member fields above are untouched). All fail-safe: absent/stale/malformed markers yield no fp signal.
	// FpProbePath (optional) points at the fp A/B marker measure_fp_ab_probe writes ($STATE_DIR/fp_probe.json
	// = {verdict, current_fingerprint, target_fingerprint, ...}). When set, the daemon folds it through a
	// generation gate keyed on the synthetic ref "client-fingerprint" (a fingerprint-specific verdict with a
	// STABLE (current,target) pair across >= FpMinGenerations distinct generations before it faults).
	FpProbePath string `json:"fp_probe_path,omitempty"`
	// FpMaxAgeMS is the freshness window for the fp marker (fail-safe: past it, no fp signal). Required (> 0)
	// when FpProbePath is set.
	FpMaxAgeMS int `json:"fp_max_age_ms,omitempty"`
	// FpMinGenerations is the marker-replay + anti-flap hardening for the fp signal (mirrors
	// L7MinDeadGenerations). Unset (<= 0) defaults to defaultL7MinDeadGenerations (2).
	FpMinGenerations int `json:"fp_min_generations,omitempty"`
	// FpRotateEnabled ARMS the fingerprint plane's PLAN-INPUT emission. It ships DISARMED (false): the daemon
	// STILL folds the fp marker through its generation gate every tick (shadow, so arming has no cold start),
	// but writes NO FingerprintPlanInput until an on-node drill validates the A/B + the gated actuation. When
	// false the fingerprint plane is observe-only — nothing downstream can rotate a preset.
	FpRotateEnabled bool `json:"fp_rotate_enabled,omitempty"`
	// FpPlanInputPath is where the assembled FingerprintPlanInput JSON is written (atomically) each tick when
	// FpRotateEnabled — the file `myceliumctl fingerprint-plan` reads. Unwritten while disarmed.
	FpPlanInputPath string `json:"fp_plan_input_path,omitempty"`
	// FpStatePath (optional) is the fingerprint plane's OWN rotate_fp_state.json (its RotationState between
	// ticks) — SEPARATE from StatePath so the fp rotation budget never contends with the transport budget.
	FpStatePath string `json:"fp_state_path,omitempty"`
}

// members converts the config rows to internal/measure.Member descriptors.
func (c *measureConfig) members() []measure.Member {
	out := make([]measure.Member, len(c.Members))
	for i, m := range c.Members {
		out[i] = measure.Member{
			Ref:      m.Ref,
			Proto:    m.Proto,
			Action:   spec.RotationAction(m.Action),
			FromPort: m.FromPort,
			ToPort:   m.ToPort,
		}
	}
	return out
}

// buildAssembler constructs the stateful MEASURE-plane assembler from the config's members and
// rotation policy, on the documented Phase-2 detector/tuner defaults. measure.New is fail-closed, so
// a bad proto/action/port or invalid limits surfaces here.
func (c *measureConfig) buildAssembler(now time.Time) (*measure.Assembler, error) {
	return measure.New(c.members(), c.Limits, detect.DefaultThresholds(), tune.DefaultParams(), now)
}

// validateAgainstReach cross-checks the measure config against the loaded reachability config — the
// two are coupled by ref and the daemon has both at startup, so the dangerous mismatches are caught
// fail-FAST (a fatal at boot) instead of fail-CLOSED-forever (a daemon that runs but silently never
// produces a usable, fresh PlanInput). It rejects:
//   - an active_ref that is not one of the members (the assembler would refuse every tick);
//   - a member whose ref has no matching reachability target — that member would NEVER be measured,
//     so its seeded-clean verdict would persist and a dead transport would never be rotated away from
//     (the asymmetric failure of the "no data ⇒ clean" rule);
//   - a tick_ms below the slowest member's probe interval — the tick would outpace the probes and
//     re-fold the SAME health window, advancing the detector's anti-flap count and reinforcing the
//     tuner without a fresh observation.
//
// Pure.
func (c *measureConfig) validateAgainstReach(rcfg *reach.Config) error {
	inMembers := false
	for _, m := range c.Members {
		if m.Ref == c.ActiveRef {
			inMembers = true
			break
		}
	}
	if !inMembers {
		return fmt.Errorf("measure config: active_ref %q is not one of the members", c.ActiveRef)
	}
	interval := make(map[string]int, len(rcfg.Targets))
	for i := range rcfg.Targets {
		interval[rcfg.Targets[i].Ref] = rcfg.Targets[i].IntervalMS
	}
	maxInterval := 0
	for _, m := range c.Members {
		iv, ok := interval[m.Ref]
		if !ok {
			return fmt.Errorf("measure config: member ref %q has no matching reachability target — it would never be measured (a dead member would never be rotated away from)", m.Ref)
		}
		if iv > maxInterval {
			maxInterval = iv
		}
	}
	if c.TickMS < maxInterval {
		return fmt.Errorf("measure config: tick_ms %d is below the slowest member probe interval %dms — a tick must not outpace probes, or the same window is re-folded", c.TickMS, maxInterval)
	}
	return nil
}

// Validate checks the daemon-facing fields are usable. The member set, protos, actions, ports and
// limits are validated (fail-closed) by measure.New when the assembler is built; this covers only
// what the daemon itself needs before then. Pure.
func (c *measureConfig) Validate() error {
	if c.Version != measureConfigVersion {
		return fmt.Errorf("measure config: unsupported version %d (want %d)", c.Version, measureConfigVersion)
	}
	if c.TickMS <= 0 {
		return fmt.Errorf("measure config: tick_ms must be > 0, got %d", c.TickMS)
	}
	if c.OutputPath == "" {
		return fmt.Errorf("measure config: output_path is required")
	}
	if c.ActiveRef == "" {
		return fmt.Errorf("measure config: active_ref is required")
	}
	if c.L7LivenessPath != "" && c.L7MaxAgeMS <= 0 {
		return fmt.Errorf("measure config: l7_max_age_ms must be > 0 when l7_liveness_path is set")
	}
	if c.PathSignalPath != "" && c.PathMaxAgeMS <= 0 {
		return fmt.Errorf("measure config: path_max_age_ms must be > 0 when path_signal_path is set")
	}
	return nil
}

// loadMeasureConfig reads and validates a measure config from path. A missing or malformed file is an
// error (the caller, having been given a path, fails fast). The file lives in a local, gitignored
// path by convention.
func loadMeasureConfig(path string) (*measureConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("measure: read config %s: %w", path, err)
	}
	var c measureConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("measure: parse config %s: %w", path, err)
	}
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("measure: invalid config %s: %w", path, err)
	}
	return &c, nil
}

// loadRotationState reads the shared between-tick RotationState (rotate_state.json) the gated rotation
// loop maintains. An empty path, a missing file, or a parse error yields the zero state — the planner
// then treats this tick as "no prior rotation memory", which is the safe default.
func loadRotationState(path string) spec.RotationState {
	if path == "" {
		return spec.RotationState{}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return spec.RotationState{}
	}
	var st spec.RotationState
	if json.Unmarshal(data, &st) != nil {
		return spec.RotationState{}
	}
	return st
}

// l7LivenessMarker is the node-local own-cert/cover-path L7 liveness marker (RP-0010 AC-6 clarification)
// the loopback own-keys probe writes. Dead lists the member refs whose L7 handshake failed on the last
// probe; ObservedAt stamps it for freshness. Extra fields the probe writes (e.g. a checked count) are
// ignored. Absent/stale/malformed -> no L7 signal, so a probe outage never faults a member.
type l7LivenessMarker struct {
	ObservedAt time.Time `json:"observed_at"`
	Dead       []string  `json:"dead"`
}

// readL7Marker reads the L7 liveness marker at path and returns the FRESH dead-ref list, the marker
// generation stamp (observed_at), and whether a fresh well-formed dead-naming marker was read at all. It
// is deliberately fail-safe — an empty path or non-positive maxAge, a missing/unreadable/malformed marker,
// an unstamped or stale marker (older than maxAge by observed_at), or an empty dead set all yield
// (nil, zero, false): no L7 signal. ONLY a fresh, well-formed marker naming dead refs is present==true.
func readL7Marker(path string, now time.Time, maxAge time.Duration) (dead []string, observedAt time.Time, present bool) {
	if path == "" || maxAge <= 0 {
		return nil, time.Time{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, time.Time{}, false
	}
	var m l7LivenessMarker
	if json.Unmarshal(data, &m) != nil {
		return nil, time.Time{}, false
	}
	if m.ObservedAt.IsZero() || now.Sub(m.ObservedAt) > maxAge {
		return nil, time.Time{}, false
	}
	for _, ref := range m.Dead {
		if ref != "" {
			dead = append(dead, ref)
		}
	}
	if len(dead) == 0 {
		return nil, time.Time{}, false
	}
	return dead, m.ObservedAt, true
}

// pathSignalMarker is the node-local PASSIVE path-level served-flow marker (RP-0014 chunk B) the nft
// observer writes. Reset lists the member refs whose served client flows are meeting RSTs above threshold
// this window (ConnectReset, increment 1); Collapse lists refs whose established served flows show the
// downstream send-queue-stall signature (PostConnectCollapse, increment 2); ObservedAt stamps it for
// freshness. Absent/stale/malformed -> no path signal.
type pathSignalMarker struct {
	ObservedAt time.Time `json:"observed_at"`
	Reset      []string  `json:"reset"`
	Collapse   []string  `json:"collapse"`
}

// readPathMarker returns the FRESH reset + collapse ref lists, the generation stamp, and present. present
// means a fresh, well-formed marker EXISTS — it is NOT gated on either list being non-empty, so a marker
// naming only a collapse (reset empty) is still delivered, and a fresh marker naming NOTHING is delivered
// with both lists empty (which the generation gates fold as "recovered", resetting their streaks). Fail-safe:
// empty path / non-positive maxAge / missing / unreadable / malformed / unstamped / stale all yield
// (nil, nil, zero, false) — no path signal (the gates then reset, never fabricating a fault).
func readPathMarker(path string, now time.Time, maxAge time.Duration) (reset, collapse []string, observedAt time.Time, present bool) {
	if path == "" || maxAge <= 0 {
		return nil, nil, time.Time{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, time.Time{}, false
	}
	var m pathSignalMarker
	if json.Unmarshal(data, &m) != nil {
		return nil, nil, time.Time{}, false
	}
	if m.ObservedAt.IsZero() || now.Sub(m.ObservedAt) > maxAge {
		return nil, nil, time.Time{}, false
	}
	for _, ref := range m.Reset {
		if ref != "" {
			reset = append(reset, ref)
		}
	}
	for _, ref := range m.Collapse {
		if ref != "" {
			collapse = append(collapse, ref)
		}
	}
	return reset, collapse, m.ObservedAt, true
}

// gateToResetMap remaps the generation gate's faulted SET into the convention measure.Tick's connectReset
// parameter expects. The gate (shared with the L7 liveness path) emits ref->FALSE — the "this member is
// dead" convention the activeProbe map reads — but connectReset reads ref->TRUE as "this member's served
// client flows are meeting RSTs". Without this flip the path fold is a silent no-op (Tick would read the
// faulted ref's value as false and fold no signal). Returns nil when nothing is faulted, which Tick folds
// as no path signal (identical to an unset map).
func gateToResetMap(faulted map[string]bool) map[string]bool {
	if len(faulted) == 0 {
		return nil
	}
	out := make(map[string]bool, len(faulted))
	for ref := range faulted {
		out[ref] = true
	}
	return out
}

// loadL7Liveness returns the SPARSE map of member ref -> false for every FRESH dead ref (an unset ref
// defaults to healthy in measure.Tick), UNGATED by generation count. It is the raw single-generation
// reader; the daemon applies l7GenerationGate on top so marker replay cannot fault on one probe run.
func loadL7Liveness(path string, now time.Time, maxAge time.Duration) map[string]bool {
	dead, _, present := readL7Marker(path, now, maxAge)
	if !present {
		return nil
	}
	out := make(map[string]bool, len(dead))
	for _, ref := range dead {
		out[ref] = false
	}
	return out
}

// defaultL7MinDeadGenerations is the fault threshold when the config leaves it unset (<= 0): a rotation
// requires the transport to read DEAD across at least this many DISTINCT probe generations. 2 (the
// operator decision, 2026-07-03) makes a rotation reflect sustained, not replayed, evidence; an explicit
// 1 in the config restores the pre-gate behaviour (fault on the first dead generation).
const defaultL7MinDeadGenerations = 2

func effectiveL7MinGenerations(configured int) int {
	if configured >= 1 {
		return configured
	}
	return defaultL7MinDeadGenerations
}

// l7GenerationGate hardens the L7 fault against marker REPLAY (Audit-0007 S2): the daemon re-reads the
// marker every tick, so a single DEAD probe generation would otherwise fault the detector on every tick
// until it ages out — satisfying the tick-based anti-flap from ONE probe run. The gate requires a member
// ref to be named DEAD across >= MinGenerations DISTINCT marker generations (distinct observed_at) before
// it faults, so a rotation reflects sustained, not replayed, evidence. A generation with the ref absent (a
// fresh-but-clean marker), or an absent/stale marker (no fresh evidence at all), resets that ref's streak.
// Stateful across ticks; NOT persisted (a daemon restart conservatively re-accumulates — fail-safe).
type l7GenerationGate struct {
	minGenerations int
	lastDead       map[string]time.Time // ref -> the last observed_at seen naming it dead
	streak         map[string]int       // ref -> consecutive DISTINCT dead generations
}

func newL7GenerationGate(minGenerations int) *l7GenerationGate {
	if minGenerations < 1 {
		minGenerations = 1
	}
	return &l7GenerationGate{
		minGenerations: minGenerations,
		lastDead:       make(map[string]time.Time),
		streak:         make(map[string]int),
	}
}

// fold advances the gate with one marker read (dead + observedAt + present, as readL7Marker returns) and
// returns the ref -> false map of members that have reached the >= MinGenerations threshold — the refs to
// actually fault (ActiveProbeOK=false). Refs below the threshold are absent from the map (healthy).
func (g *l7GenerationGate) fold(dead []string, observedAt time.Time, present bool) map[string]bool {
	if !present {
		// No fresh evidence this read: a dead streak is only meaningful while evidence keeps arriving, and
		// a stopped/expired probe must never keep a fault latched. Reset everything (fail-safe).
		g.lastDead = make(map[string]time.Time)
		g.streak = make(map[string]int)
		return map[string]bool{}
	}
	deadSet := make(map[string]bool, len(dead))
	for _, r := range dead {
		if r != "" {
			deadSet[r] = true
		}
	}
	// A FRESH marker that no longer names a ref dead means it recovered (or was never dead) -> reset it.
	for r := range g.streak {
		if !deadSet[r] {
			delete(g.streak, r)
			delete(g.lastDead, r)
		}
	}
	out := make(map[string]bool)
	for r := range deadSet {
		if last, seen := g.lastDead[r]; !seen || observedAt.After(last) {
			g.streak[r]++ // a NEW distinct dead generation
			g.lastDead[r] = observedAt
		}
		// observedAt == last -> a REPLAY of the same generation -> no increment.
		if g.streak[r] >= g.minGenerations {
			out[r] = false
		}
	}
	return out
}

// assemblePlanInput folds one reach snapshot through the assembler and marshals the resulting
// rotate.PlanInput as indented JSON (ready for `myceliumctl rotate-plan`). It is the pure, testable
// core of the daemon's measure tick — no I/O of its own; the caller supplies the snapshot, active ref,
// state, clock, and the node-local L7-liveness map (a member ref -> false for a fresh L7-dead member;
// a nil/unset map folds as healthy, the pre-L7 behaviour).
func assemblePlanInput(asm *measure.Assembler, snap []spec.TransportHealth, activeRef string, state spec.RotationState, now time.Time, activeProbe, connectReset, postConnectCollapse map[string]bool) ([]byte, error) {
	pi, err := asm.Tick(snap, activeRef, state, now, activeProbe, connectReset, postConnectCollapse)
	if err != nil {
		return nil, err
	}
	out, err := json.MarshalIndent(pi, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("measure: marshal plan input: %w", err)
	}
	return out, nil
}

// assembleTick is the daemon's per-tick fold composition, extracted so a test can drive the EXACT wiring
// the daemon runs (marker reads -> the generation gates -> assemblePlanInput), not a re-implementation.
// It reads this tick's node-local L7 liveness marker and the passive path-level marker (both RST and
// send-queue-stall lists), folds each THROUGH its own generation gate (a member must read DEAD/RESET/COLLAPSE
// across >= MinGenerations DISTINCT marker generations before it faults, so marker replay across ticks cannot
// satisfy the anti-flap from one probe run; an absent/stale marker resets that gate -> no fault, fail-safe),
// and assembles the PlanInput. The gates are the caller's (persisted across ticks); cfg supplies the marker
// paths + freshness windows. The collapse signal is DISARMED unless cfg.PathCollapseEnabled — the marker's
// collapse list is read (shadow) but not folded into a rotation-driving verdict until arming (increment 2).
func assembleTick(asm *measure.Assembler, snap []spec.TransportHealth, cfg *measureConfig, now time.Time, state spec.RotationState, l7gate, pathgate, collapsegate *l7GenerationGate) ([]byte, error) {
	dead, observedAt, present := readL7Marker(cfg.L7LivenessPath, now, time.Duration(cfg.L7MaxAgeMS)*time.Millisecond)
	l7 := l7gate.fold(dead, observedAt, present)
	rReset, rCollapse, rObserved, rPresent := readPathMarker(cfg.PathSignalPath, now, time.Duration(cfg.PathMaxAgeMS)*time.Millisecond)
	pathReset := gateToResetMap(pathgate.fold(rReset, rObserved, rPresent))
	// Collapse rides its own gate but only actuates when armed. When disarmed we STILL fold it through the
	// gate (so its streak state advances and shadow behaviour matches armed behaviour) but discard the result,
	// so arming later has no cold-start surprise; the map passed to Tick is nil -> no verdict/pool effect.
	collapseFaulted := collapsegate.fold(rCollapse, rObserved, rPresent)
	var pathCollapse map[string]bool
	if cfg.PathCollapseEnabled {
		pathCollapse = gateToResetMap(collapseFaulted) // ref->true convention, same as reset
	}
	return assemblePlanInput(asm, snap, cfg.ActiveRef, state, now, l7, pathReset, pathCollapse)
}

// fpProbeMarker is the node-local fingerprint A/B marker measure_fp_ab_probe writes (RP-0015 increment B).
// Verdict is one of the closed neutral tokens (fingerprint-specific / transport-wide / clean / cannot-judge);
// CurrentFingerprint is the preset the probe used; TargetFingerprint is the closed-vocab preset the A/B found
// ALIVE while the current read DEAD (set only for fingerprint-specific). Absent/stale/malformed -> no fp signal.
type fpProbeMarker struct {
	ObservedAt         time.Time `json:"observed_at"`
	CurrentFingerprint string    `json:"current_fingerprint"`
	Verdict            string    `json:"verdict"`
	TargetFingerprint  string    `json:"target_fingerprint"`
	SuspectRefs        []string  `json:"suspect_refs"`
}

// readFpMarker reads the fingerprint A/B marker and returns its verdict, current + target presets, the
// generation stamp, and present. Fail-safe exactly like readL7Marker/readPathMarker: empty path /
// non-positive maxAge / missing / unreadable / malformed / unstamped / stale all yield ("", "", "", zero,
// false) — no fp signal (the fp gate then resets, never fabricating a fault).
func readFpMarker(path string, now time.Time, maxAge time.Duration) (verdict, current, target string, observedAt time.Time, present bool) {
	if path == "" || maxAge <= 0 {
		return "", "", "", time.Time{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", "", "", time.Time{}, false
	}
	var m fpProbeMarker
	if json.Unmarshal(data, &m) != nil {
		return "", "", "", time.Time{}, false
	}
	if m.ObservedAt.IsZero() || now.Sub(m.ObservedAt) > maxAge {
		return "", "", "", time.Time{}, false
	}
	return m.Verdict, m.CurrentFingerprint, m.TargetFingerprint, m.ObservedAt, true
}

// fpGateRef is the synthetic ref the fingerprint plane folds through the (reused) l7GenerationGate — the
// client fingerprint is one node-wide scalar, so it is represented as a single ref rather than a member.
const fpGateRef = "client-fingerprint"

// foldFpGate advances the fingerprint generation gate with one fp-marker read and returns (target, faulted):
// it faults (names client-fingerprint dead) ONLY when the marker is fresh, the verdict is
// fingerprint-specific, and the SAME (current, target) pair recurs across >= MinGenerations DISTINCT marker
// generations. It REUSES l7GenerationGate for the distinct-observed_at replay hardening; the pair-stability
// is tracked in *lastPair here: a verdict change, a (current,target) change (a rotation happened, or an
// unstable target pick), or an absent/stale marker all reset the streak (fail-safe). transport-wide / clean /
// cannot-judge never fault, so the useless "rotate-the-preset-when-the-transport-is-blocked" case cannot
// reach the planner.
func foldFpGate(g *l7GenerationGate, lastPair *string, verdict, current, target string, observedAt time.Time, present bool) (string, bool) {
	faultInput := present && verdict == "fingerprint-specific" && target != "" && current != ""
	pairKey := ""
	if faultInput {
		pairKey = current + "\x00" + target
	}
	if pairKey != *lastPair {
		// The (current,target) pair changed or dropped — the accumulated streak is meaningless; hard-reset
		// the gate (present=false clears every streak; only fpGateRef is ever tracked here).
		g.fold(nil, time.Time{}, false)
	}
	*lastPair = pairKey
	var dead []string
	if faultInput {
		dead = []string{fpGateRef}
	}
	// present drives the gate's own reset: a fresh-but-non-faulting marker (dead empty) resets fpGateRef; an
	// absent/stale marker (present=false) resets everything. Only a fresh fault with a NEW distinct
	// observed_at advances the streak. The gate's ref->false convention means MEMBERSHIP (not the value,
	// which is always false) signals a fault, so test key presence.
	faulted := g.fold(dead, observedAt, present)
	if _, ok := faulted[fpGateRef]; faultInput && ok {
		return target, true
	}
	return "", false
}

// assembleFpTick is the fingerprint plane's per-tick fold, extracted (like assembleTick) so a test can drive
// the EXACT wiring the daemon runs (readFpMarker -> foldFpGate -> the FingerprintPlanInput) rather than a
// re-implementation. It ALWAYS folds the gate (shadow-advancing across ticks so arming has no cold start) and
// marshals the FingerprintPlanInput; the caller (runMeasure) writes it only when armed. The gate + lastPair
// are the caller's (persisted across ticks). state is the fingerprint plane's OWN RotationState.
func assembleFpTick(cfg *measureConfig, now time.Time, state spec.RotationState, fpgate *l7GenerationGate, lastPair *string) ([]byte, error) {
	verdict, current, target, observedAt, present := readFpMarker(cfg.FpProbePath, now, time.Duration(cfg.FpMaxAgeMS)*time.Millisecond)
	gatedTarget, faulted := foldFpGate(fpgate, lastPair, verdict, current, target, observedAt, present)
	in := spec.FingerprintPlanInput{
		Current: current,
		Target:  gatedTarget,
		Faulted: faulted,
		Limits:  cfg.Limits,
		State:   state,
		Now:     now,
	}
	out, err := json.MarshalIndent(in, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("measure: marshal fingerprint plan input: %w", err)
	}
	return out, nil
}

// filterToMembers keeps only the snapshot entries whose ref is a configured member, returning the
// kept slice and the count dropped. reach may probe context anchors the node does not rotate among;
// those are not folded (and measure.Tick would otherwise fail-close on them).
func filterToMembers(snap []spec.TransportHealth, members map[string]bool) (kept []spec.TransportHealth, dropped int) {
	kept = snap[:0:0]
	for _, h := range snap {
		if members[h.TransportRef] {
			kept = append(kept, h)
		} else {
			dropped++
		}
	}
	return kept, dropped
}

// atomicWriteFile writes data to path via a temp file + rename, so a reader (the rotation loop) never
// observes a half-written PlanInput.
func atomicWriteFile(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// planInputHolder serves the most recently assembled PlanInput on a loopback endpoint. The ticker
// writes; the HTTP handler reads.
type planInputHolder struct {
	mu      sync.Mutex
	latest  []byte
	tickAt  time.Time
	lastErr string
}

func (h *planInputHolder) set(b []byte, at time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.latest, h.tickAt, h.lastErr = b, at, ""
}

func (h *planInputHolder) setErr(err string, at time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.tickAt, h.lastErr = at, err
}

func (h *planInputHolder) snapshot() (raw []byte, at time.Time, lastErr string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.latest, h.tickAt, h.lastErr
}

// runMeasure is the MEASURE-plane tick loop. The assembler (its members and policy) is built ONCE so
// the per-member detector hysteresis and tuner pheromone persist across ticks; only the active ref,
// state and output paths are re-read each tick (a rotation that changes the incumbent is picked up
// without losing accumulated state). It is strictly advisory: it folds reach health into a
// rotate.PlanInput and writes/serves it, and never actuates a rotation.
func runMeasure(ctx context.Context, mon *reach.Monitor, cfgPath string, asm *measure.Assembler, initial *measureConfig, holder *planInputHolder) {
	ticker := time.NewTicker(time.Duration(initial.TickMS) * time.Millisecond)
	defer ticker.Stop()

	// The assembler folds ONLY the configured members. reach may legitimately probe more anchors than
	// the node rotates among (context probes), so the snapshot is filtered to member refs before the
	// fold — otherwise measure.Tick (which fail-closes on an unknown ref) would refuse every tick.
	memberRefs := make(map[string]bool, len(initial.Members))
	for _, m := range initial.Members {
		memberRefs[m.Ref] = true
	}

	// The L7 generation gate persists across ticks (like the assembler): its per-ref distinct-dead-
	// generation streaks are what make marker replay harmless. Its policy (MinGenerations) is fixed at
	// startup from initial, alongside the members/limits.
	l7gate := newL7GenerationGate(effectiveL7MinGenerations(initial.L7MinDeadGenerations))
	// The path-signal marker rides the SAME generation-gate logic (a member must read RESET across >= N
	// distinct marker generations before it faults, hardening against replay + a one-off RST spike).
	pathgate := newL7GenerationGate(effectiveL7MinGenerations(initial.PathMinResetGenerations))
	// The collapse signal (increment 2) rides its own generation gate. Its streak advances every tick (shadow)
	// so arming has no cold start, but assembleTick only folds its result into a verdict when armed.
	collapsegate := newL7GenerationGate(effectiveL7MinGenerations(initial.PathCollapseMinGenerations))
	// RP-0015 increment B: the fingerprint A/B plane's OWN generation gate + the (current,target) pair it
	// tracks for pair-stability, both persisted across ticks. Like the collapse gate it shadow-advances every
	// tick so arming has no cold start; the FingerprintPlanInput is WRITTEN only when FpRotateEnabled.
	fpgate := newL7GenerationGate(effectiveL7MinGenerations(initial.FpMinGenerations))
	var lastFpPair string

	tick := func() {
		// Re-read the config for the current active ref / paths; the assembler's members and limits are
		// fixed at startup, so a re-read that fails just keeps the last good values.
		cur := initial
		if c, err := loadMeasureConfig(cfgPath); err != nil {
			log.Printf("myceliumd: measure: re-reading %s failed, using last good config: %v", cfgPath, err)
		} else {
			cur = c
		}
		now := time.Now().UTC()
		snap, dropped := filterToMembers(mon.Snapshot(), memberRefs)
		if dropped > 0 {
			// A steady, correctly ref-matched deployment drops nothing; a non-zero count flags a
			// reach/measure ref mismatch the operator should reconcile.
			log.Printf("myceliumd: measure: dropped %d reach anchor(s) not in the member set (ref mismatch?)", dropped)
		}
		out, err := assembleTick(asm, snap, cur, now, loadRotationState(cur.StatePath), l7gate, pathgate, collapsegate)
		if err != nil {
			log.Printf("myceliumd: measure: assemble failed (no plan input written this tick): %v", err)
			holder.setErr(err.Error(), now)
			return
		}
		if err := atomicWriteFile(cur.OutputPath, out); err != nil {
			log.Printf("myceliumd: measure: writing %s failed: %v", cur.OutputPath, err)
			holder.setErr(err.Error(), now)
			return
		}
		holder.set(out, now)

		// RP-0015 increment B: the fingerprint A/B plane rides in parallel. The gate ALWAYS folds (shadow-
		// advances) so arming has no cold start; the FingerprintPlanInput is WRITTEN only when armed. A fold
		// or write failure is logged and never disturbs the transport plane already written above.
		fpOut, ferr := assembleFpTick(cur, now, loadRotationState(cur.FpStatePath), fpgate, &lastFpPair)
		if ferr != nil {
			log.Printf("myceliumd: measure: fingerprint fold failed (no plan input written this tick): %v", ferr)
		} else if cur.FpRotateEnabled && cur.FpPlanInputPath != "" {
			if err := atomicWriteFile(cur.FpPlanInputPath, fpOut); err != nil {
				log.Printf("myceliumd: measure: writing %s failed: %v", cur.FpPlanInputPath, err)
			}
		}
	}

	tick() // assemble once immediately so a PlanInput exists before the first interval elapses
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tick()
		}
	}
}
