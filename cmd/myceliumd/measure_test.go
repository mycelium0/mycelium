// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package main

import (
	"encoding/json"
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
	out, err := assemblePlanInput(asm, snap, "ref-a", spec.RotationState{}, t0, nil)
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
	if _, err := assemblePlanInput(asm, nil, "no-such-ref", spec.RotationState{}, t0, nil); err == nil {
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
