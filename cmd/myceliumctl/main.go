// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Command myceliumctl is the Phase 0 control CLI (the Go spine, ADR-0012) — the
// compiled successor to control/myceliumctl (shell). During the transition it
// implements the identity surface and reports parity gaps honestly; key material
// still comes only from the sanctioned generators (ADR-0002). It holds no
// network-state detector or auto-rotation logic (that is a Phase-2 deliverable).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"text/tabwriter"
	"time"

	"github.com/mindicator/mycelium/internal/identity"
	"github.com/mindicator/mycelium/internal/rotate"
	"github.com/mindicator/mycelium/internal/spec"
)

// defaultState matches the shell tool's default (control/state/identities.json).
const defaultState = "control/state/identities.json"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "myceliumctl: "+err.Error())
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		usage(os.Stderr)
		return fmt.Errorf("a command is required")
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "version", "-v", "--version":
		// Preserve the `myceliumctl %s` prefix that downstream matchers depend on; append the
		// build-stamped source rev when present (RP-0008 P3 — the node's idempotent spine build keys on it).
		if spec.SourceRev != "" {
			fmt.Printf("myceliumctl %s (rev %s)\n", spec.Version, spec.SourceRev)
		} else {
			fmt.Printf("myceliumctl %s\n", spec.Version)
		}
		return nil
	case "identity":
		return cmdIdentity(rest)
	case "validate-bundle":
		return cmdValidateBundle(rest)
	case "vocab":
		return cmdVocab(rest)
	case "rotate-plan":
		return cmdRotatePlan(rest)
	case "rotate-record":
		return cmdRotateRecord(rest)
	case "reality-keys", "render-server", "subscription":
		return fmt.Errorf("%q is not yet ported to the Go spine; use the shell tool control/myceliumctl for now (RP-0002 W7)", cmd)
	case "help", "-h", "--help":
		usage(os.Stdout)
		return nil
	default:
		usage(os.Stderr)
		return fmt.Errorf("unknown command %q (run 'myceliumctl help')", cmd)
	}
}

func cmdIdentity(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("identity: expected a subcommand (add|revoke|list)")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "add":
		fs := flag.NewFlagSet("identity add", flag.ContinueOnError)
		name := fs.String("name", "", "client name (required)")
		state := fs.String("state", defaultState, "identity state file")
		if err := fs.Parse(rest); err != nil {
			return err
		}
		if *name == "" {
			return fmt.Errorf("identity add: --name is required")
		}
		s, err := identity.Load(*state)
		if err != nil {
			return err
		}
		c, err := s.Add(*name, time.Now())
		if err != nil {
			return err
		}
		if err := identity.Save(*state, s); err != nil {
			return err
		}
		fmt.Printf("added\t%s\t%s\t%s\n", c.Name, c.ID, c.Created)
		return nil

	case "revoke":
		fs := flag.NewFlagSet("identity revoke", flag.ContinueOnError)
		state := fs.String("state", defaultState, "identity state file")
		if err := fs.Parse(rest); err != nil {
			return err
		}
		if fs.NArg() != 1 {
			return fmt.Errorf("identity revoke: exactly one NAME or ID is required")
		}
		sel := fs.Arg(0)
		s, err := identity.Load(*state)
		if err != nil {
			return err
		}
		n, err := s.Revoke(sel)
		if err != nil {
			return err
		}
		if err := identity.Save(*state, s); err != nil {
			return err
		}
		fmt.Printf("revoked %d client(s) matching %q\n", n, sel)
		return nil

	case "list":
		fs := flag.NewFlagSet("identity list", flag.ContinueOnError)
		state := fs.String("state", defaultState, "identity state file")
		if err := fs.Parse(rest); err != nil {
			return err
		}
		s, err := identity.Load(*state)
		if err != nil {
			return err
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tID\tCREATED")
		for _, c := range s.Clients {
			fmt.Fprintf(w, "%s\t%s\t%s\n", c.Name, c.ID, c.Created)
		}
		return w.Flush()

	default:
		return fmt.Errorf("identity: unknown subcommand %q (expected add|revoke|list)", sub)
	}
}

// cmdValidateBundle reads a rendered distribution bundle (a file path, or "-" for stdin), unmarshals it
// into spec.Bundle, and runs the authoritative spec.Bundle.Validate(). It is the Go-owned round-trip
// boundary (RP-0008 P1): the shell renderer produces the JSON; this command is the single authority on
// whether that JSON is a structurally-valid Phase-1 bundle (version, >=1 endpoint, closed-vocab
// transport class + region, advisory-only health == "unknown", non-empty tag/link, dated). Pure
// read + validate: no network, no mutation. Exits non-zero on any invalid bundle.
func cmdValidateBundle(args []string) error {
	fs := flag.NewFlagSet("validate-bundle", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("validate-bundle: exactly one bundle FILE (or - for stdin) is required")
	}
	src := fs.Arg(0)
	var (
		data []byte
		err  error
	)
	if src == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(src)
	}
	if err != nil {
		return fmt.Errorf("validate-bundle: read %s: %w", src, err)
	}
	var b spec.Bundle
	if err := json.Unmarshal(data, &b); err != nil {
		return fmt.Errorf("validate-bundle: %s is not valid bundle JSON: %w", src, err)
	}
	if err := b.Validate(); err != nil {
		return fmt.Errorf("validate-bundle: %s is not a valid bundle: %w", src, err)
	}
	fmt.Printf("ok\tvalid bundle\tversion=%d\tendpoints=%d\tgenerated_at=%s\n",
		b.Version, len(b.Endpoints), b.GeneratedAt.UTC().Format(time.RFC3339))
	return nil
}

// cmdRotatePlan reads a node-local rotation PlanInput as JSON (a FILE argument or - for stdin), runs
// the pure rotation planner (internal/rotate, RP-0012), and writes the resulting RotationPlan as
// indented JSON on stdout. It is the shell-invocable boundary of the Plane-3 ADAPT decision: a
// Go-bearing node assembles the PlanInput (active member + its local verdict + the local tuner
// ranking + limits + state) and this returns the hold/rotate plan. The planner is pure and never
// reads the clock; this CLI boundary fills PlanInput.Now from the system clock when the caller leaves
// it zero. No network, no mutation. (Applying a plan is the shell flow_rotate, dry-run by default.)
func cmdRotatePlan(args []string) error {
	fs := flag.NewFlagSet("rotate-plan", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("rotate-plan: exactly one PlanInput FILE (or - for stdin) is required")
	}
	src := fs.Arg(0)
	var (
		data []byte
		err  error
	)
	if src == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(src)
	}
	if err != nil {
		return fmt.Errorf("rotate-plan: read %s: %w", src, err)
	}
	var in rotate.PlanInput
	if err := json.Unmarshal(data, &in); err != nil {
		return fmt.Errorf("rotate-plan: %s is not valid PlanInput JSON: %w", src, err)
	}
	if in.Now.IsZero() {
		in.Now = time.Now().UTC()
	}
	plan, err := rotate.Plan(in)
	if err != nil {
		return fmt.Errorf("rotate-plan: %w", err)
	}
	out, err := json.MarshalIndent(plan, "", "  ")
	if err != nil {
		return fmt.Errorf("rotate-plan: marshal plan: %w", err)
	}
	fmt.Println(string(out))
	return nil
}

// rotateRecordInput is the JSON cmdRotateRecord consumes: the persisted between-tick RotationState,
// the rotation limits, whether the just-applied rotation was rolled back, and the clock. It is the
// executor's feedback channel into the pure rotate.RecordOutcome (which spends the rollback budget and
// latches the planner to hold once the budget is exhausted). Kept tiny + flat so the shell flow_rotate
// can assemble it with jq.
type rotateRecordInput struct {
	State      spec.RotationState  `json:"state"`
	Limits     spec.RotationLimits `json:"limits"`
	RolledBack bool                `json:"rolled_back"`
	Now        time.Time           `json:"now"`
}

// cmdRotateRecord folds an apply outcome back into the rotation state (RP-0012 C4c): it reads a
// rotateRecordInput as JSON (FILE or - for stdin), runs the pure rotate.RecordOutcome, and writes the
// updated RotationState as JSON on stdout. The executor (flow_rotate) calls this after a LIVE rotation
// attempt — on a rollback it spends the per-window rollback budget and, once the budget is exhausted,
// latches the planner into a hold for CooldownAfterRollback so a valid-schema-but-breaks-service
// candidate cannot thrash. RecordOutcome does not validate its limits, so this boundary does (fail-closed)
// — bad limits would silently mis-size the latch window. The clock is filled from the system clock when
// the caller leaves Now zero. Pure read + compute: no network, no mutation.
func cmdRotateRecord(args []string) error {
	fs := flag.NewFlagSet("rotate-record", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("rotate-record: exactly one input FILE (or - for stdin) is required")
	}
	src := fs.Arg(0)
	var (
		data []byte
		err  error
	)
	if src == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(src)
	}
	if err != nil {
		return fmt.Errorf("rotate-record: read %s: %w", src, err)
	}
	var in rotateRecordInput
	if err := json.Unmarshal(data, &in); err != nil {
		return fmt.Errorf("rotate-record: %s is not valid input JSON: %w", src, err)
	}
	if err := in.Limits.Validate(); err != nil {
		return fmt.Errorf("rotate-record: %w", err)
	}
	if in.Now.IsZero() {
		in.Now = time.Now().UTC()
	}
	next := rotate.RecordOutcome(in.State, in.Limits, in.RolledBack, in.Now)
	out, err := json.MarshalIndent(next, "", "  ")
	if err != nil {
		return fmt.Errorf("rotate-record: marshal state: %w", err)
	}
	fmt.Println(string(out))
	return nil
}

// cmdVocab emits the canonical Go-owned control-plane vocabulary (spec.NewVocab) as
// deterministic, indented JSON on stdout: the closed transport-class / region-bucket /
// advisory-health vocabularies and the full proto->class/port/key/scheme/engine
// registry. It is the source the committed control/vocab.json is generated from and
// the shell renderer reads at render time (RP-0008 P2). Output is byte-stable (fixed
// struct field order, two-space indent, trailing newline) so the vocab_single_source
// gate can diff the regenerated emission against the committed file. Pure: no network,
// no mutation. The `--json` flag is accepted for forward-compatibility; JSON is the
// only (and default) format.
func cmdVocab(args []string) error {
	fs := flag.NewFlagSet("vocab", flag.ContinueOnError)
	_ = fs.Bool("json", true, "emit JSON (the only supported format)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("vocab: takes no positional arguments")
	}
	data, err := json.MarshalIndent(spec.NewVocab(), "", "  ")
	if err != nil {
		return fmt.Errorf("vocab: marshal: %w", err)
	}
	if _, err := os.Stdout.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("vocab: write: %w", err)
	}
	return nil
}

func usage(w *os.File) {
	fmt.Fprintf(w, `myceliumctl %s — Mycelium Phase 0 control CLI (Go spine).

Usage:
  myceliumctl <command> [options]

Commands:
  identity add    --name NAME [--state FILE]   issue a client (UUID via the OS CSPRNG)
  identity revoke NAME|ID     [--state FILE]   revoke a client by name or id
  identity list              [--state FILE]    list clients
  validate-bundle FILE|-                       validate a rendered distribution bundle (RP-0008 P1)
  vocab                                        emit the canonical transport/region/health vocabulary as JSON (RP-0008 P2)
  rotate-plan FILE|-                           plan a node-local transport rotation: PlanInput JSON -> RotationPlan JSON (RP-0012)
  rotate-record FILE|-                         fold an apply outcome into the rotation state: {state,limits,rolled_back,now} -> RotationState JSON (RP-0012)
  version                                      print the spine version
  help                                         show this help

Not yet ported to the Go spine (use the shell tool control/myceliumctl):
  reality-keys, render-server, subscription    (RP-0002 W7)

Default state file: %s
`, spec.Version, defaultState)
}
