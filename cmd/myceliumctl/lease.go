// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// lease.go — the WRITER for suppression leases: the one path by which the rotation loop may stop
// serving a member, and the reason a suppression has a term.
//
// WHY IT IS IN GO AND NOT IN THE SHELL. Every refusal below — the evidence/direction pairing, the
// carrying-traffic guard, the independent-family floor, the outstanding budget, the backoff — is a
// predicate. ADR-0038: Go owns the predicate and emits numbers; the shell compares and never re-derives.
// A shell writer would have been a second implementation of spec.LeaseSet.Grant that drifts from it, and
// the drift would be invisible because both would be "working".
//
// WHAT REPLACES WHAT. Before this, a demote wrote `<proto>_enabled=false` into the operator's overrides
// overlay: permanent, with no term, in the same field the operator uses for their own durable choices,
// so an operator repair and a stale loop reaction could disagree about one transport with neither owning
// the answer. That write is retired here. The lease lives in its own file, always expires, and reaping it
// IS the restore path.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mycelium0/mycelium/internal/spec"
)

// pathMarker is the passive observer's output ($STATE_DIR/path_signal.json). Only the two fields this
// writer needs are declared; the rest of the marker is none of its business.
type pathMarker struct {
	ObservedAt string   `json:"observed_at"`
	Carrying   []string `json:"carrying"`
	// CarryingObserved is what the observer can speak about AT ALL — the served TCP inbounds it has a
	// connection table for. A member outside this list is not "idle", it is UNSEEN, and the difference is
	// the whole guard: /proc/net/tcp has no row for hysteria2, tuic or AmneziaWG, so an absent UDP member
	// would otherwise read as empty and be suppressed with every one of its clients still on it.
	CarryingObserved []string `json:"carrying_observed"`
}

func cmdLease(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("lease: expected a subcommand (grant|release|reap|list)")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "grant":
		return cmdLeaseGrant(rest)
	case "release":
		return cmdLeaseRelease(rest)
	case "reap":
		return cmdLeaseReap(rest)
	case "list":
		return cmdLeaseList(rest)
	default:
		return fmt.Errorf("lease: unknown subcommand %q (grant|release|reap|list)", sub)
	}
}

// readLeases loads the lease set, treating an absent file as an empty set and a malformed one as fatal.
//
// Absent is legitimate — a node that has never suppressed anything has no file. Malformed is not: the
// file records which members the node is currently NOT serving, and rendering a served set that cannot
// be accounted for is how a suppression silently lapses or silently persists.
func readLeases(path string, lim spec.RotationLimits) (spec.LeaseSet, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return spec.LeaseSet{Version: spec.LeaseSetVersion}, nil
	}
	if err != nil {
		return spec.LeaseSet{}, fmt.Errorf("lease: read %s: %w", path, err)
	}
	var s spec.LeaseSet
	if err := json.Unmarshal(data, &s); err != nil {
		return spec.LeaseSet{}, fmt.Errorf("lease: %s is not a valid lease set: %w", path, err)
	}
	if err := s.Validate(lim); err != nil {
		return spec.LeaseSet{}, fmt.Errorf("lease: %s: %w", path, err)
	}
	return s, nil
}

// writeLeases persists atomically, 0600, through a UNIQUE temp name in the destination directory.
//
// The name carries the pid: two converges racing on one shared `.tmp` would have each truncated the
// other's half-written file and then renamed it into place, and the loser's rename wins — publishing a
// lease set neither process assembled. Same-directory keeps the rename atomic (a cross-filesystem rename
// is a copy, and a copy can be interrupted halfway).
func writeLeases(path string, s spec.LeaseSet, lim spec.RotationLimits) error {
	if err := s.Validate(lim); err != nil {
		return fmt.Errorf("lease: refusing to write an invalid lease set: %w", err)
	}
	out, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("lease: marshal: %w", err)
	}
	out = append(out, '\n')
	tmp := filepath.Join(filepath.Dir(path), fmt.Sprintf(".%s.%d.tmp", filepath.Base(path), os.Getpid()))
	if err := os.WriteFile(tmp, out, 0o600); err != nil {
		return fmt.Errorf("lease: write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("lease: install %s: %w", path, err)
	}
	return os.Chmod(path, 0o600)
}

// carryingTraffic answers ADR-0040 §2.4 for one member, and FAILS CLOSED in every uncertain case.
//
// It returns (carrying, why). A true with a reason naming the uncertainty is not a lesser answer than a
// true naming live sessions: both mean "this node may not take the member away", and the operator needs
// to know which one they are looking at.
//
// The closed direction here is the opposite of the loop's usual posture, and deliberately so. Fail-closed
// against serving something broken argues for suppressing; fail-closed against ending the working
// sessions of people whose situation the node cannot observe argues against it. When the node cannot see
// who is on a member, the second is the stronger claim — the harm is certain and immediate, while the
// fault is inferred from a signal that cannot see those users.
func carryingTraffic(markerPath, proto string, refFor map[string]string, now time.Time, maxAge time.Duration) (bool, string) {
	data, err := os.ReadFile(markerPath)
	if err != nil {
		return true, fmt.Sprintf("the passive observer has written no marker at %s, so this node cannot see whether anyone is on %s", markerPath, proto)
	}
	var m pathMarker
	if err := json.Unmarshal(data, &m); err != nil {
		return true, fmt.Sprintf("the observer marker %s is malformed (%v), and an unreadable answer is not a negative one", markerPath, err)
	}
	if m.ObservedAt == "" {
		return true, fmt.Sprintf("the observer marker %s carries no observation time", markerPath)
	}
	at, err := time.Parse(time.RFC3339, m.ObservedAt)
	if err != nil {
		return true, fmt.Sprintf("the observer marker %s has an unparseable observation time %q", markerPath, m.ObservedAt)
	}
	if maxAge > 0 && now.Sub(at) > maxAge {
		return true, fmt.Sprintf("the observer marker is %s old (max %s) — a stale count is a count of who WAS on %s", now.Sub(at).Round(time.Second), maxAge, proto)
	}
	// The observer speaks in node-local refs, the plan speaks in protos. refFor is the join, built from
	// the same measure config the observer's port map came from.
	ref, ok := refFor[proto]
	if !ok {
		return true, fmt.Sprintf("%s has no member ref in the measure config, so nothing joins it to the observer's counts", proto)
	}
	seen := false
	for _, r := range m.CarryingObserved {
		if r == ref {
			seen = true
			break
		}
	}
	if !seen {
		// The UDP case, and the one worth naming explicitly: hysteria2, tuic and AmneziaWG have no
		// connection table, so the observer is SILENT about them rather than reporting them idle.
		return true, fmt.Sprintf("%s is not something this node's connection-table observer can see (UDP families have no such table), so 'nobody is on it' is not an observation this node has made", proto)
	}
	for _, r := range m.Carrying {
		if r == ref {
			return true, fmt.Sprintf("%s has live client sessions right now", proto)
		}
	}
	return false, fmt.Sprintf("%s was observed with no live client session at %s", proto, at.UTC().Format(time.RFC3339))
}

// familiesAfter counts the independent block families the node would still SERVE if proto were
// suppressed on top of the leases already in force.
//
// Counted over families, never over protos: two REALITY members share one family, so a node serving only
// those two has ONE independent family and suppressing either leaves a client blocked on REALITY with
// nowhere to go. That is the RP-0013 floor, and it is the reason a wrongly-kept member costs less than a
// wrongly-removed one.
func familiesAfter(enabled []string, suppressed []string, proto string) (int, []string, error) {
	out := map[string]struct{}{}
	drop := map[string]struct{}{proto: {}}
	for _, p := range suppressed {
		drop[p] = struct{}{}
	}
	for _, p := range enabled {
		if _, gone := drop[p]; gone {
			continue
		}
		fam, ok := spec.BlockFamilyForProto(p)
		if !ok {
			return 0, nil, fmt.Errorf("lease: %q has no block family in the registry — refusing to count a family the renderer does not know", p)
		}
		out[fam] = struct{}{}
	}
	fams := make([]string, 0, len(out))
	for f := range out {
		fams = append(fams, f)
	}
	sort.Strings(fams)
	return len(fams), fams, nil
}

func cmdLeaseGrant(args []string) error {
	fs := flag.NewFlagSet("lease grant", flag.ContinueOnError)
	planPath := fs.String("plan", "", "the rotation plan whose .suppress proposal is being granted (required)")
	leasePath := fs.String("leases", "", "the lease set file to update (required)")
	limitsPath := fs.String("limits", "", "JSON RotationLimits (required; the same limits the planner ran under)")
	markerPath := fs.String("marker", "", "the passive observer marker ($STATE_DIR/path_signal.json) (required)")
	refsPath := fs.String("refs", "", "JSON {proto: ref} joining plan protos to observer refs (required)")
	enabledCSV := fs.String("enabled", "", "comma-separated protos this node currently serves (required)")
	maxAgeSec := fs.Int("marker-max-age-sec", 300, "how old the observer marker may be before it counts as no observation")
	nowStr := fs.String("now", "", "RFC3339 clock override (tests only; defaults to wall clock)")
	dryRun := fs.Bool("dry-run", false, "decide and report, write nothing")
	if err := fs.Parse(args); err != nil {
		return err
	}
	for name, v := range map[string]*string{"--plan": planPath, "--leases": leasePath, "--limits": limitsPath, "--marker": markerPath, "--refs": refsPath} {
		if *v == "" {
			return fmt.Errorf("lease grant: %s is required", name)
		}
	}
	if *enabledCSV == "" {
		return fmt.Errorf("lease grant: --enabled is required (an empty served set cannot be reasoned about)")
	}

	now := time.Now().UTC()
	if *nowStr != "" {
		t, err := time.Parse(time.RFC3339, *nowStr)
		if err != nil {
			return fmt.Errorf("lease grant: --now %q is not RFC3339: %w", *nowStr, err)
		}
		now = t.UTC()
	}

	var lim spec.RotationLimits
	lb, err := os.ReadFile(*limitsPath)
	if err != nil {
		return fmt.Errorf("lease grant: read limits %s: %w", *limitsPath, err)
	}
	if err := json.Unmarshal(lb, &lim); err != nil {
		return fmt.Errorf("lease grant: %s is not valid RotationLimits JSON: %w", *limitsPath, err)
	}
	if err := lim.Validate(); err != nil {
		return fmt.Errorf("lease grant: %w", err)
	}

	pb, err := os.ReadFile(*planPath)
	if err != nil {
		return fmt.Errorf("lease grant: read plan %s: %w", *planPath, err)
	}
	var plan spec.RotationPlan
	if err := json.Unmarshal(pb, &plan); err != nil {
		return fmt.Errorf("lease grant: %s is not a valid rotation plan: %w", *planPath, err)
	}
	if err := plan.Validate(); err != nil {
		return fmt.Errorf("lease grant: %s: %w", *planPath, err)
	}
	// THE SINGLE ENTRY POINT (development.md §2.2 item 4, S0). A suppression is a rotation actuation and
	// is reachable only through a plan the loop produced — with its hysteresis, its cooldown, its rate
	// limit and its rollback latch already spent. Granting from anything else would be the side door those
	// guards exist to close, so an operator with a hand-written plan is refused here rather than trusted.
	if !plan.Act {
		return fmt.Errorf("lease grant: the plan holds (%s) — a hold changes nothing and grants nothing", plan.Reason)
	}
	if plan.Suppress == nil {
		return fmt.Errorf("lease grant: the plan acts but proposes no suppression (action %q) — promoting a sibling adds a path and takes none away, so it needs no lease", plan.To.Action)
	}
	prop := *plan.Suppress

	rb, err := os.ReadFile(*refsPath)
	if err != nil {
		return fmt.Errorf("lease grant: read refs %s: %w", *refsPath, err)
	}
	refFor := map[string]string{}
	if err := json.Unmarshal(rb, &refFor); err != nil {
		return fmt.Errorf("lease grant: %s is not a valid {proto: ref} map: %w", *refsPath, err)
	}

	set, err := readLeases(*leasePath, lim)
	if err != nil {
		return err
	}
	// Reap first. An expired lease still sitting in the file would otherwise count against the outstanding
	// budget and make the node refuse a grant on the strength of a suppression that is no longer in force.
	set = set.Reap(now)

	enabled := []string{}
	for _, p := range strings.Split(*enabledCSV, ",") {
		if p = strings.TrimSpace(p); p != "" {
			enabled = append(enabled, p)
		}
	}
	nFam, fams, err := familiesAfter(enabled, set.Suppressed(now), prop.Proto)
	if err != nil {
		return err
	}

	carrying, why := carryingTraffic(*markerPath, prop.Proto, refFor, now, time.Duration(*maxAgeSec)*time.Second)

	// LastCount drives the backoff and must survive expiry, or a member failing every hour is suppressed
	// for the same short span forever. The file still holds the previous lease at this point only if it is
	// in force; a reaped one is gone, so the count is read from the pre-reap set.
	last := 0
	if pre, err := readLeases(*leasePath, lim); err == nil {
		for _, l := range pre.Leases {
			if l.Proto == prop.Proto {
				last = l.Count
			}
		}
	}

	req := spec.GrantRequest{
		Proto:                    prop.Proto,
		Direction:                prop.Direction,
		Evidence:                 prop.Evidence,
		History:                  spec.LeaseHistory{LastCount: last},
		CarryingTraffic:          carrying,
		IndependentFamiliesAfter: nFam,
	}
	next, err := set.Grant(req, now, lim)
	if err != nil {
		// A refusal is the normal, expected outcome and is reported as such — with the observation behind
		// it, so an operator reading the journal can tell "somebody is on it" from "this node cannot see".
		fmt.Fprintf(os.Stderr, "lease grant: REFUSED for %s: %v\n", prop.Proto, err)
		fmt.Fprintf(os.Stderr, "  traffic:  %s\n", why)
		fmt.Fprintf(os.Stderr, "  families: %d would remain (%s), floor %d\n", nFam, strings.Join(fams, " "), spec.IndependentFamilyFloor)
		return err
	}

	var granted spec.SuppressionLease
	for _, l := range next.Leases {
		if l.Proto == prop.Proto {
			granted = l
		}
	}
	if *dryRun {
		fmt.Printf("would suppress %s until %s (term %s, count %d, evidence %s/%s); %s\n",
			granted.Proto, granted.ExpiresAt.Format(time.RFC3339),
			granted.ExpiresAt.Sub(granted.Since), granted.Count, granted.Evidence, granted.Direction, why)
		return nil
	}
	if err := writeLeases(*leasePath, next, lim); err != nil {
		return err
	}
	fmt.Printf("suppressed %s until %s (term %s, count %d, evidence %s/%s); %s\n",
		granted.Proto, granted.ExpiresAt.Format(time.RFC3339),
		granted.ExpiresAt.Sub(granted.Since), granted.Count, granted.Evidence, granted.Direction, why)
	return nil
}

// cmdLeaseRelease is the OPERATOR's verb: overrule the loop now rather than waiting out a term you
// disagree with. It is deliberately not reachable from the planner.
func cmdLeaseRelease(args []string) error {
	fs := flag.NewFlagSet("lease release", flag.ContinueOnError)
	leasePath := fs.String("leases", "", "the lease set file to update (required)")
	limitsPath := fs.String("limits", "", "JSON RotationLimits (required)")
	proto := fs.String("proto", "", "the proto whose lease to withdraw (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *leasePath == "" || *limitsPath == "" || *proto == "" {
		return fmt.Errorf("lease release: --leases, --limits and --proto are required")
	}
	lim, err := readLimits(*limitsPath)
	if err != nil {
		return err
	}
	set, err := readLeases(*leasePath, lim)
	if err != nil {
		return err
	}
	before := len(set.Leases)
	next := set.Release(*proto)
	if len(next.Leases) == before {
		fmt.Printf("no lease for %s; nothing to release\n", *proto)
		return nil
	}
	if err := writeLeases(*leasePath, next, lim); err != nil {
		return err
	}
	fmt.Printf("released the suppression on %s; it returns to service on the next render\n", *proto)
	return nil
}

// cmdLeaseReap drops expired leases. Reaping is the whole restore path: the loop withdraws its claim and
// the member returns to whatever the operator asked for. Nothing here asserts it recovered.
func cmdLeaseReap(args []string) error {
	fs := flag.NewFlagSet("lease reap", flag.ContinueOnError)
	leasePath := fs.String("leases", "", "the lease set file to update (required)")
	limitsPath := fs.String("limits", "", "JSON RotationLimits (required)")
	nowStr := fs.String("now", "", "RFC3339 clock override (tests only)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *leasePath == "" || *limitsPath == "" {
		return fmt.Errorf("lease reap: --leases and --limits are required")
	}
	now := time.Now().UTC()
	if *nowStr != "" {
		t, err := time.Parse(time.RFC3339, *nowStr)
		if err != nil {
			return fmt.Errorf("lease reap: --now %q is not RFC3339: %w", *nowStr, err)
		}
		now = t.UTC()
	}
	lim, err := readLimits(*limitsPath)
	if err != nil {
		return err
	}
	set, err := readLeases(*leasePath, lim)
	if err != nil {
		return err
	}
	expired := set.Expired(now)
	if len(expired) == 0 {
		return nil
	}
	if err := writeLeases(*leasePath, set.Reap(now), lim); err != nil {
		return err
	}
	names := make([]string, 0, len(expired))
	for _, l := range expired {
		names = append(names, l.Proto)
	}
	fmt.Printf("reaped %s; their term ran out, which is not a claim that they recovered\n", strings.Join(names, " "))
	return nil
}

// cmdLeaseList prints the in-force set as the shell's single question: which protos are suppressed now.
func cmdLeaseList(args []string) error {
	fs := flag.NewFlagSet("lease list", flag.ContinueOnError)
	leasePath := fs.String("leases", "", "the lease set file to read (required)")
	limitsPath := fs.String("limits", "", "JSON RotationLimits (required)")
	nowStr := fs.String("now", "", "RFC3339 clock override (tests only)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *leasePath == "" || *limitsPath == "" {
		return fmt.Errorf("lease list: --leases and --limits are required")
	}
	now := time.Now().UTC()
	if *nowStr != "" {
		t, err := time.Parse(time.RFC3339, *nowStr)
		if err != nil {
			return fmt.Errorf("lease list: --now %q is not RFC3339: %w", *nowStr, err)
		}
		now = t.UTC()
	}
	lim, err := readLimits(*limitsPath)
	if err != nil {
		return err
	}
	set, err := readLeases(*leasePath, lim)
	if err != nil {
		return err
	}
	for _, p := range set.Suppressed(now) {
		fmt.Println(p)
	}
	return nil
}

func readLimits(path string) (spec.RotationLimits, error) {
	var lim spec.RotationLimits
	b, err := os.ReadFile(path)
	if err != nil {
		return lim, fmt.Errorf("lease: read limits %s: %w", path, err)
	}
	if err := json.Unmarshal(b, &lim); err != nil {
		return lim, fmt.Errorf("lease: %s is not valid RotationLimits JSON: %w", path, err)
	}
	if err := lim.Validate(); err != nil {
		return lim, fmt.Errorf("lease: %w", err)
	}
	return lim, nil
}
