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

// assemblePlanInput folds one reach snapshot through the assembler and marshals the resulting
// rotate.PlanInput as indented JSON (ready for `myceliumctl rotate-plan`). It is the pure, testable
// core of the daemon's measure tick — no I/O of its own; the caller supplies the snapshot, active
// ref, state and clock.
func assemblePlanInput(asm *measure.Assembler, snap []spec.TransportHealth, activeRef string, state spec.RotationState, now time.Time) ([]byte, error) {
	pi, err := asm.Tick(snap, activeRef, state, now)
	if err != nil {
		return nil, err
	}
	out, err := json.MarshalIndent(pi, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("measure: marshal plan input: %w", err)
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
		out, err := assemblePlanInput(asm, snap, cur.ActiveRef, loadRotationState(cur.StatePath), now)
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
