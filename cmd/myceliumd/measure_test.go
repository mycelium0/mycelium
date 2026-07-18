// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/mycelium0/mycelium/internal/reach"
	"github.com/mycelium0/mycelium/internal/rotate"
	"github.com/mycelium0/mycelium/internal/spec"
)

// reachCfg builds a minimal reach.Config carrying only the ref→intervalMS pairs validateAgainstReach
// reads (it ignores method/address).
func reachCfg(refIntervalMS map[string]int) *reach.Config {
	c := &reach.Config{}
	for ref, iv := range refIntervalMS {
		c.Targets = append(c.Targets, reach.Target{Ref: ref, IntervalMS: iv})
	}
	return c
}

func TestValidateAgainstReach(t *testing.T) {
	good := reachCfg(map[string]int{"ref-a": 5000, "ref-b": 5000})
	if err := goodMeasureConfig().validateAgainstReach(good); err != nil {
		t.Fatalf("good config rejected: %v", err)
	}
	// active_ref not a member.
	c := goodMeasureConfig()
	c.ActiveRef = "nope"
	if err := c.validateAgainstReach(good); err == nil {
		t.Error("active_ref not a member: want error")
	}
	// a member with no matching reach target (would never be measured).
	if err := goodMeasureConfig().validateAgainstReach(reachCfg(map[string]int{"ref-a": 5000})); err == nil {
		t.Error("member ref-b has no reach target: want error")
	}
	// tick_ms below the slowest member probe interval (re-folds the same window).
	c = goodMeasureConfig()
	c.TickMS = 1000
	if err := c.validateAgainstReach(reachCfg(map[string]int{"ref-a": 5000, "ref-b": 5000})); err == nil {
		t.Error("tick_ms below probe interval: want error")
	}
}

func TestPlanInputHolderFreshness(t *testing.T) {
	h := &planInputHolder{}
	// Before any tick: nil raw, empty error.
	if raw, _, le := h.snapshot(); raw != nil || le != "" {
		t.Errorf("fresh holder: raw=%v lastErr=%q, want nil/empty", raw, le)
	}
	h.set([]byte(`{"x":1}`), t0)
	if raw, at, le := h.snapshot(); string(raw) != `{"x":1}` || !at.Equal(t0) || le != "" {
		t.Errorf("after set: raw=%s at=%v le=%q", raw, at, le)
	}
	// A failing tick records the error + tick time but does NOT discard the last good raw.
	h.setErr("boom", t0.Add(time.Minute))
	if raw, at, le := h.snapshot(); string(raw) != `{"x":1}` || le != "boom" || !at.Equal(t0.Add(time.Minute)) {
		t.Errorf("after setErr: raw=%s at=%v le=%q — want last-good raw kept + error surfaced", raw, at, le)
	}
}

var t0 = time.Date(2026, 6, 19, 12, 0, 0, 0, time.UTC)

func goodMeasureConfig() *measureConfig {
	return &measureConfig{
		Version:    measureConfigVersion,
		TickMS:     60000,
		ActiveRef:  "ref-a",
		OutputPath: "/var/lib/mycelium/rotate_plan_input.json",
		Limits:     rotate.DefaultRotationLimits(),
		Members: []measureMember{
			{Ref: "ref-a", Proto: "vless-reality-vision", Action: "promote-sibling"},
			{Ref: "ref-b", Proto: "vless-reality-grpc", Action: "promote-sibling"},
		},
	}
}

func health(ref string, succ, fail int, end time.Time) spec.TransportHealth {
	return spec.TransportHealth{TransportRef: ref, Successes: succ, Failures: fail, WindowStart: end.Add(-time.Minute), WindowEnd: end}
}

func TestMeasureConfigValidate(t *testing.T) {
	if err := goodMeasureConfig().Validate(); err != nil {
		t.Fatalf("good config rejected: %v", err)
	}
	bad := []struct {
		name string
		mut  func(*measureConfig)
	}{
		{"bad version", func(c *measureConfig) { c.Version = 99 }},
		{"zero tick", func(c *measureConfig) { c.TickMS = 0 }},
		{"empty output", func(c *measureConfig) { c.OutputPath = "" }},
		{"empty active", func(c *measureConfig) { c.ActiveRef = "" }},
		{"l7 path without age", func(c *measureConfig) { c.L7LivenessPath = "/x"; c.L7MaxAgeMS = 0 }},
		{"path signal without age", func(c *measureConfig) { c.PathSignalPath = "/x"; c.PathMaxAgeMS = 0 }},
	}
	for _, b := range bad {
		c := goodMeasureConfig()
		b.mut(c)
		if err := c.Validate(); err == nil {
			t.Errorf("%s: Validate accepted, want error", b.name)
		}
	}
}

func TestBuildAssemblerFailClosed(t *testing.T) {
	// A good config builds.
	if _, err := goodMeasureConfig().buildAssembler(t0); err != nil {
		t.Fatalf("good config: buildAssembler: %v", err)
	}
	// An unknown proto is refused by measure.New.
	c := goodMeasureConfig()
	c.Members[1].Proto = "not-a-proto"
	if _, err := c.buildAssembler(t0); err == nil {
		t.Error("buildAssembler accepted an unknown proto, want fail-closed error")
	}
}

func TestAssemblePlanInputGolden(t *testing.T) {
	asm, err := goodMeasureConfig().buildAssembler(t0)
	if err != nil {
		t.Fatalf("buildAssembler: %v", err)
	}
	// Active failing (zero successes -> impaired), candidate clean.
	snap := []spec.TransportHealth{health("ref-a", 0, 6, t0), health("ref-b", 6, 0, t0)}
	out, err := assemblePlanInput(asm, snap, "ref-a", spec.RotationState{}, t0, nil, nil)
	if err != nil {
		t.Fatalf("assemblePlanInput: %v", err)
	}
	var pi rotate.PlanInput
	if err := json.Unmarshal(out, &pi); err != nil {
		t.Fatalf("output is not PlanInput JSON: %v\n%s", err, out)
	}
	if pi.Active.Proto != "vless-reality-vision" {
		t.Errorf("active proto = %q, want vless-reality-vision", pi.Active.Proto)
	}
	if pi.ActiveVerdict.State == spec.ConnStateClean || pi.ActiveVerdict.State == spec.ConnStateUnknown {
		t.Errorf("active verdict = %q, want impaired", pi.ActiveVerdict.State)
	}
	if len(pi.Ranked) != 1 || pi.Ranked[0].Proto != "vless-reality-grpc" {
		t.Errorf("ranked = %+v, want the grpc sibling", pi.Ranked)
	}
	// The assembled input must be accepted by the planner (closes the loop).
	if _, err := rotate.Plan(pi); err != nil {
		t.Errorf("planner rejected the assembled input: %v", err)
	}
}

func TestAssemblePlanInputFailClosed(t *testing.T) {
	asm, err := goodMeasureConfig().buildAssembler(t0)
	if err != nil {
		t.Fatalf("buildAssembler: %v", err)
	}
	if _, err := assemblePlanInput(asm, nil, "no-such-ref", spec.RotationState{}, t0, nil, nil); err == nil {
		t.Error("assemblePlanInput accepted an unknown active ref, want error")
	}
}

// TestLoadL7Liveness proves the fail-safe reader: only a FRESH, well-formed marker naming dead refs
// faults them; an absent/stale/malformed/unstamped marker or an empty dead set yields nil (no L7
// signal), so a probe outage never spuriously rotates a healthy transport.
func TestLoadL7Liveness(t *testing.T) {
	dir := t.TempDir()
	now := t0
	maxAge := 5 * time.Minute
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	fresh := now.Add(-time.Minute).UTC().Format(time.RFC3339Nano)
	stale := now.Add(-10 * time.Minute).UTC().Format(time.RFC3339Nano)

	if m := loadL7Liveness("", now, maxAge); m != nil {
		t.Errorf("empty path: got %v, want nil", m)
	}
	if m := loadL7Liveness(write("absent-guard.json", "{}"), now, 0); m != nil {
		t.Errorf("non-positive maxAge: got %v, want nil", m)
	}
	if m := loadL7Liveness(filepath.Join(dir, "does-not-exist.json"), now, maxAge); m != nil {
		t.Errorf("missing file: got %v, want nil", m)
	}
	if m := loadL7Liveness(write("bad.json", "{not json"), now, maxAge); m != nil {
		t.Errorf("malformed: got %v, want nil", m)
	}
	if m := loadL7Liveness(write("unstamped.json", `{"dead":["vless-reality-vision"]}`), now, maxAge); m != nil {
		t.Errorf("unstamped (zero observed_at): got %v, want nil", m)
	}
	if m := loadL7Liveness(write("stale.json", `{"observed_at":"`+stale+`","dead":["vless-reality-vision"]}`), now, maxAge); m != nil {
		t.Errorf("stale marker: got %v, want nil", m)
	}
	if m := loadL7Liveness(write("clean.json", `{"observed_at":"`+fresh+`","checked":2,"dead":[]}`), now, maxAge); m != nil {
		t.Errorf("fresh but no dead: got %v, want nil", m)
	}
	// Fresh + dead: the one dead ref faults (false); extra fields (checked) are ignored.
	m := loadL7Liveness(write("dead.json", `{"observed_at":"`+fresh+`","checked":2,"dead":["vless-reality-vision"]}`), now, maxAge)
	if len(m) != 1 || m["vless-reality-vision"] != false {
		t.Errorf("fresh dead marker: got %v, want {vless-reality-vision:false}", m)
	}
}

func TestEffectiveL7MinGenerations(t *testing.T) {
	for _, c := range []struct{ in, want int }{{0, 2}, {-3, 2}, {1, 1}, {2, 2}, {5, 5}} {
		if got := effectiveL7MinGenerations(c.in); got != c.want {
			t.Errorf("effectiveL7MinGenerations(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

// TestL7GenerationGate covers the marker-replay hardening (Audit-0007 S2): a member faults only after it
// reads DEAD across >= N DISTINCT observed_at generations; replay of one generation, a fresh-clean
// generation, or an absent/stale marker never advance (or reset) the streak.
func TestL7GenerationGate(t *testing.T) {
	g0 := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	gen := func(i int) time.Time { return g0.Add(time.Duration(i) * time.Minute) }
	faulted := func(out map[string]bool, ref string) bool { _, ok := out[ref]; return ok }

	t.Run("one generation does not fault at N=2", func(t *testing.T) {
		g := newL7GenerationGate(2)
		if out := g.fold([]string{"a"}, gen(1), true); faulted(out, "a") {
			t.Fatalf("one dead generation must not fault at N=2: %+v", out)
		}
	})

	t.Run("replay of the same generation never advances", func(t *testing.T) {
		g := newL7GenerationGate(2)
		for i := 0; i < 5; i++ {
			if out := g.fold([]string{"a"}, gen(1), true); faulted(out, "a") { // SAME observedAt each read
				t.Fatalf("replay of one generation must not fault (read %d): %+v", i, out)
			}
		}
	})

	t.Run("two distinct generations fault at N=2 (ref->false)", func(t *testing.T) {
		g := newL7GenerationGate(2)
		g.fold([]string{"a"}, gen(1), true)
		out := g.fold([]string{"a"}, gen(2), true)
		if v, ok := out["a"]; !ok || v != false {
			t.Fatalf("two distinct dead generations must fault ref->false: %+v", out)
		}
	})

	t.Run("a fresh-clean generation resets the streak", func(t *testing.T) {
		g := newL7GenerationGate(2)
		g.fold([]string{"a"}, gen(1), true) // a streak 1
		g.fold([]string{"b"}, gen(2), true) // a absent in a fresh marker -> a resets
		if out := g.fold([]string{"a"}, gen(3), true); faulted(out, "a") {
			t.Fatalf("a fresh-clean generation must reset a's streak: %+v", out)
		}
	})

	t.Run("an absent/stale marker resets even a faulted ref", func(t *testing.T) {
		g := newL7GenerationGate(2)
		g.fold([]string{"a"}, gen(1), true)
		if out := g.fold([]string{"a"}, gen(2), true); !faulted(out, "a") {
			t.Fatalf("precondition: a should be faulted after 2 distinct generations")
		}
		g.fold(nil, time.Time{}, false) // no fresh marker -> reset all (fail-safe)
		if out := g.fold([]string{"a"}, gen(3), true); faulted(out, "a") {
			t.Fatalf("an absent marker must reset the streak: %+v", out)
		}
	})

	t.Run("refs are tracked independently", func(t *testing.T) {
		g := newL7GenerationGate(2)
		g.fold([]string{"a", "b"}, gen(1), true)
		out := g.fold([]string{"a"}, gen(2), true) // a: 2 distinct gens -> faulted; b: dropped -> reset
		if !faulted(out, "a") {
			t.Fatalf("a across 2 generations must fault: %+v", out)
		}
		if faulted(out, "b") {
			t.Fatalf("b (dropped this generation) must not fault: %+v", out)
		}
	})

	t.Run("N=1 restores fault-on-first-generation", func(t *testing.T) {
		g := newL7GenerationGate(1)
		if out := g.fold([]string{"a"}, gen(1), true); !faulted(out, "a") {
			t.Fatalf("N=1 must fault on the first dead generation: %+v", out)
		}
	})
}

func TestLoadMeasureConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "measure.config.json")
	raw, _ := json.Marshal(goodMeasureConfig())
	if err := os.WriteFile(p, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := loadMeasureConfig(p)
	if err != nil {
		t.Fatalf("loadMeasureConfig: %v", err)
	}
	if c.ActiveRef != "ref-a" || len(c.Members) != 2 {
		t.Errorf("round-trip lost fields: %+v", c)
	}
	// A malformed file is an error, not a silent skip.
	if err := os.WriteFile(p, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadMeasureConfig(p); err == nil {
		t.Error("loadMeasureConfig accepted malformed JSON, want error")
	}
	if _, err := loadMeasureConfig(filepath.Join(dir, "absent.json")); err == nil {
		t.Error("loadMeasureConfig accepted a missing file, want error")
	}
}

func TestAtomicWriteFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "out.json")
	if err := atomicWriteFile(p, []byte(`{"ok":true}`)); err != nil {
		t.Fatalf("atomicWriteFile: %v", err)
	}
	got, err := os.ReadFile(p)
	if err != nil || string(got) != `{"ok":true}` {
		t.Errorf("read back = %q err=%v", got, err)
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Error("temp file left behind after atomic write")
	}
}

func TestFilterToMembers(t *testing.T) {
	members := map[string]bool{"a": true, "b": true}
	snap := []spec.TransportHealth{health("a", 1, 0, t0), health("x", 1, 0, t0), health("b", 1, 0, t0)}
	kept, dropped := filterToMembers(snap, members)
	if dropped != 1 {
		t.Errorf("dropped = %d, want 1 (the non-member 'x')", dropped)
	}
	if len(kept) != 2 {
		t.Fatalf("kept = %d, want 2", len(kept))
	}
	for _, h := range kept {
		if !members[h.TransportRef] {
			t.Errorf("kept a non-member ref %q", h.TransportRef)
		}
	}
	// The input slice must not be mutated (kept must not alias snap's backing array).
	if snap[1].TransportRef != "x" {
		t.Error("filterToMembers mutated the input snapshot")
	}
}

// TestGateToResetMap locks the value-convention flip between the shared generation gate (which emits
// ref->FALSE, the L7 "dead" convention the activeProbe map reads) and measure.Tick's connectReset map
// (which reads ref->TRUE as "reset"). Without this flip the whole chunk-B path fold is a silent no-op, so
// this test is the guard against that regression.
func TestGateToResetMap(t *testing.T) {
	if m := gateToResetMap(nil); m != nil {
		t.Errorf("nil faulted set: got %v, want nil (folds as no path signal)", m)
	}
	if m := gateToResetMap(map[string]bool{}); m != nil {
		t.Errorf("empty faulted set: got %v, want nil", m)
	}
	// The gate hands us ref->false (its L7 convention); the remap must emit ref->TRUE for connectReset.
	in := map[string]bool{"ref-a": false, "ref-b": false}
	out := gateToResetMap(in)
	if len(out) != 2 {
		t.Fatalf("remap size = %d, want 2", len(out))
	}
	for _, ref := range []string{"ref-a", "ref-b"} {
		if v, ok := out[ref]; !ok || v != true {
			t.Errorf("remap[%q] = (%v, present=%v), want (true, true)", ref, v, ok)
		}
	}
}

// TestReadPathMarker mirrors the L7 fail-safe reader for the chunk-B path-signal marker: only a FRESH,
// well-formed marker naming reset refs yields present=true; an absent/stale/malformed/unstamped marker or
// an empty reset set yields (nil, zero, false) — a passive-observer outage never spuriously faults a
// healthy transport.
func TestReadPathMarker(t *testing.T) {
	dir := t.TempDir()
	now := t0
	maxAge := 5 * time.Minute
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	fresh := now.Add(-time.Minute).UTC().Format(time.RFC3339Nano)
	stale := now.Add(-10 * time.Minute).UTC().Format(time.RFC3339Nano)

	none := func(name string, reset []string, present bool) {
		if present || reset != nil {
			t.Errorf("%s: got reset=%v present=%v, want nil/false", name, reset, present)
		}
	}
	r, _, p := readPathMarker("", now, maxAge)
	none("empty path", r, p)
	r, _, p = readPathMarker(write("age0.json", "{}"), now, 0)
	none("non-positive maxAge", r, p)
	r, _, p = readPathMarker(filepath.Join(dir, "missing.json"), now, maxAge)
	none("missing file", r, p)
	r, _, p = readPathMarker(write("bad.json", "{not json"), now, maxAge)
	none("malformed", r, p)
	r, _, p = readPathMarker(write("unstamped.json", `{"reset":["ref-a"]}`), now, maxAge)
	none("unstamped", r, p)
	r, _, p = readPathMarker(write("stale.json", `{"observed_at":"`+stale+`","reset":["ref-a"]}`), now, maxAge)
	none("stale", r, p)
	r, _, p = readPathMarker(write("empty.json", `{"observed_at":"`+fresh+`","reset":[]}`), now, maxAge)
	none("fresh but empty reset", r, p)

	// Fresh + non-empty reset: present, and blank refs are filtered out.
	r, at, p := readPathMarker(write("reset.json", `{"observed_at":"`+fresh+`","reset":["ref-a","","ref-b"]}`), now, maxAge)
	if !p || len(r) != 2 || r[0] != "ref-a" || r[1] != "ref-b" {
		t.Errorf("fresh reset marker: reset=%v present=%v, want [ref-a ref-b]/true", r, p)
	}
	if at.IsZero() {
		t.Error("fresh reset marker: observedAt must be stamped")
	}
}

// TestAssemblePlanInputPathReset proves the chunk-B connectReset map reaches the assembled PlanInput: a
// candidate flagged reset is surfaced as PathReset=true (so the planner excludes it from the pool), while
// the unset active stays eligible. Deterministic in one tick (the flag is not gated by detector hysteresis).
func TestAssemblePlanInputPathReset(t *testing.T) {
	asm, err := goodMeasureConfig().buildAssembler(t0)
	if err != nil {
		t.Fatalf("buildAssembler: %v", err)
	}
	snap := []spec.TransportHealth{health("ref-a", 6, 0, t0), health("ref-b", 6, 0, t0)}
	// ref-b (the candidate sibling) is flagged reset by the path observer.
	out, err := assemblePlanInput(asm, snap, "ref-a", spec.RotationState{}, t0, nil, map[string]bool{"ref-b": true})
	if err != nil {
		t.Fatalf("assemblePlanInput: %v", err)
	}
	var pi rotate.PlanInput
	if err := json.Unmarshal(out, &pi); err != nil {
		t.Fatalf("output is not PlanInput JSON: %v\n%s", err, out)
	}
	if len(pi.Ranked) != 1 || pi.Ranked[0].Proto != "vless-reality-grpc" {
		t.Fatalf("ranked = %+v, want the grpc sibling", pi.Ranked)
	}
	if !pi.Ranked[0].PathReset {
		t.Error("candidate flagged in the connectReset map must carry PathReset=true in the assembled input")
	}
	if pi.Active.PathReset {
		t.Error("the unset active must not carry PathReset")
	}
}

// TestPathSignalMarkerDrivesBlockedReset is the daemon-level integration proof for RP-0014 chunk B 1c:
// a path_signal.json marker in the OBSERVER's exact on-disk format ({observed_at, checked, reset:[refs]}),
// whose reset ref is a production proto id, drives the full daemon composition — readPathMarker -> the
// generation gate -> gateToResetMap -> assemblePlanInput — to a blocked/connection-reset verdict on the
// active member once the class is flagged across >= path_min_reset_generations DISTINCT generations. It
// pins the REF SEAM the fold depends on: nb_measure sets the member ref to the proto, and the observer
// writes reset refs as the sing-box tag minus "-in" (== the proto), so a live marker actually matches the
// member the daemon folds (an off-by-one in either naming would make the fold a silent live no-op). This
// is the node-free half of the 1c e2e; the observer -> marker half was validated live in increment 1a.
func TestPathSignalMarkerDrivesBlockedReset(t *testing.T) {
	dir := t.TempDir()
	// Production-faithful config: the member ref IS the proto id (nb_measure emits `ref: .proto`), so the
	// marker's reset ref (the observer's tag-minus-"-in" == proto) keys the exact member the daemon folds.
	cfg := goodMeasureConfig()
	cfg.Members = []measureMember{
		{Ref: "vless-reality-vision", Proto: "vless-reality-vision", Action: "promote-sibling"},
		{Ref: "vless-reality-grpc", Proto: "vless-reality-grpc", Action: "promote-sibling"},
	}
	cfg.ActiveRef = "vless-reality-vision"
	cfg.PathMinResetGenerations = 2
	// Point the daemon composition at a real marker file with the daemon's own freshness window.
	marker := filepath.Join(dir, "path_signal.json")
	cfg.PathSignalPath = marker
	cfg.PathMaxAgeMS = 5 * 60 * 1000 // 5 min
	asm, err := cfg.buildAssembler(t0)
	if err != nil {
		t.Fatalf("buildAssembler: %v", err)
	}

	// The daemon holds ONE path gate (and one L7 gate) across ticks (like runMeasure); the per-ref
	// distinct-generation streak is what makes a single RST spike (one generation) harmless.
	l7gate := newL7GenerationGate(effectiveL7MinGenerations(cfg.L7MinDeadGenerations))
	pathgate := newL7GenerationGate(effectiveL7MinGenerations(cfg.PathMinResetGenerations))

	// writeMarker emits the OBSERVER's exact format. resetBody is the raw JSON array body (e.g.
	// `"vless-reality-vision"`), empty for a clean generation.
	writeMarker := func(observedAt time.Time, resetBody string) {
		body := fmt.Sprintf(`{"observed_at":"%s","checked":2,"reset":[%s]}`, observedAt.UTC().Format(time.RFC3339Nano), resetBody)
		if err := os.WriteFile(marker, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// tick drives the daemon's REAL per-tick composition (assembleTick — the same function runMeasure calls),
	// so this test exercises the actual marker-read -> gate -> gateToResetMap -> assemble wiring, not a copy.
	tick := func(now time.Time) (spec.ConnState, spec.DetectReason) {
		snap := []spec.TransportHealth{
			health("vless-reality-vision", 6, 0, now), // L4 reach HEALTHY for both — only the path signal faults
			health("vless-reality-grpc", 6, 0, now),
		}
		out, err := assembleTick(asm, snap, cfg, now, spec.RotationState{}, l7gate, pathgate)
		if err != nil {
			t.Fatalf("assembleTick: %v", err)
		}
		var pi rotate.PlanInput
		if err := json.Unmarshal(out, &pi); err != nil {
			t.Fatalf("unmarshal PlanInput: %v", err)
		}
		return pi.ActiveVerdict.State, pi.ActiveVerdict.Reason
	}

	// Each generation the observer flags the ACTIVE class reset, with a fresh observed_at. The fault must NOT
	// appear before generation 2: generation 0 leaves the gate at streak 1 (below path_min_reset_generations
	// 2), and generation 1 is the first generation the gate faults — but that is only the FIRST blocked
	// observation, which the detector's FlipConfirmations (2) has not yet confirmed. Only from generation 2
	// on (gate satisfied AND the flip confirmed) is the active verdict blocked/connection-reset.
	var state spec.ConnState
	var reason spec.DetectReason
	for i := 0; i < 6; i++ {
		now := t0.Add(time.Duration(i) * time.Minute)
		writeMarker(now, `"vless-reality-vision"`)
		state, reason = tick(now)
		if i <= 1 && state == spec.ConnStateBlocked {
			t.Fatalf("generation %d must not yet fault (>= 2 distinct reset generations AND >= 2 flip confirmations are required): got %v", i, state)
		}
	}
	if state != spec.ConnStateBlocked || reason != spec.ReasonConnectionReset {
		t.Fatalf("after sustained path-reset generations, active verdict = (%v, %v), want (blocked, connection-reset) — the observer->marker->daemon fold is not reaching the classifier", state, reason)
	}

	// Once the observer stops flagging the class (a fresh clean marker with reset:[]), readPathMarker
	// returns not-present and the gate resets — the daemon fold no longer asserts ConnectReset (the fault is
	// not latched at the fold; the detector's own hysteresis governs the verdict's return to clean).
	clean := t0.Add(10 * time.Minute)
	writeMarker(clean, ``)
	rReset, rObserved, rPresent := readPathMarker(marker, clean, 5*time.Minute)
	if pr := gateToResetMap(pathgate.fold(rReset, rObserved, rPresent)); len(pr) != 0 {
		t.Fatalf("a clean marker (reset:[]) must clear the path signal at the fold, got %v", pr)
	}
}

func TestLoadRotationState(t *testing.T) {
	// Empty path / missing file / malformed -> zero state (safe default), never an error.
	if st := loadRotationState(""); st != (spec.RotationState{}) {
		t.Errorf("empty path: got %+v, want zero", st)
	}
	if st := loadRotationState(filepath.Join(t.TempDir(), "absent.json")); st != (spec.RotationState{}) {
		t.Errorf("missing file: got %+v, want zero", st)
	}
	dir := t.TempDir()
	p := filepath.Join(dir, "state.json")
	_ = os.WriteFile(p, []byte(`{"impaired_streak":2}`), 0o600)
	if st := loadRotationState(p); st.ImpairedStreak != 2 {
		t.Errorf("loaded state ImpairedStreak = %d, want 2", st.ImpairedStreak)
	}
}
