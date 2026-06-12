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
	"flag"
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/mindicator/mycelium/internal/identity"
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
		fmt.Printf("myceliumctl %s\n", spec.Version)
		return nil
	case "identity":
		return cmdIdentity(rest)
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

func usage(w *os.File) {
	fmt.Fprintf(w, `myceliumctl %s — Mycelium Phase 0 control CLI (Go spine).

Usage:
  myceliumctl <command> [options]

Commands:
  identity add    --name NAME [--state FILE]   issue a client (UUID via the OS CSPRNG)
  identity revoke NAME|ID     [--state FILE]   revoke a client by name or id
  identity list              [--state FILE]    list clients
  version                                      print the spine version
  help                                         show this help

Not yet ported to the Go spine (use the shell tool control/myceliumctl):
  reality-keys, render-server, subscription    (RP-0002 W7)

Default state file: %s
`, spec.Version, defaultState)
}
