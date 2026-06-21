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
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"text/tabwriter"
	"time"

	"github.com/mycelium0/mycelium/internal/identity"
	"github.com/mycelium0/mycelium/internal/rotate"
	"github.com/mycelium0/mycelium/internal/spec"
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
	case "share-link":
		return cmdShareLink(rest)
	case "bundle":
		return cmdBundle(rest)
	case "link-outbound":
		return cmdLinkOutbound(rest)
	case "aggregate":
		return cmdAggregate(rest)
	case "subscription":
		return cmdSubscription(rest)
	case "render-server":
		return cmdRenderServer(rest)
	case "front-render":
		return cmdFrontRender(rest)
	case "node":
		return cmdNode(rest)
	case "transport":
		return cmdTransport(rest)
	case "reality-keys":
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

// cmdShareLink renders the dialable client share-link for one transport (RP-0008 P3-a). It reads an
// already-resolved spec.LinkParams as JSON (a FILE argument or - for stdin) + a --proto flag, runs the
// pure spec.ShareLink, and prints the link. It is the Go port of the shell `myc_bundle_link`; the
// share_link_go_equiv gate asserts byte-identical output before any renderer cutover. No network, no
// mutation.
func cmdShareLink(args []string) error {
	fs := flag.NewFlagSet("share-link", flag.ContinueOnError)
	proto := fs.String("proto", "", "transport proto (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *proto == "" {
		return fmt.Errorf("share-link: --proto is required")
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("share-link: exactly one LinkParams FILE (or - for stdin) is required")
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
		return fmt.Errorf("share-link: read %s: %w", src, err)
	}
	var p spec.LinkParams
	if err := json.Unmarshal(data, &p); err != nil {
		return fmt.Errorf("share-link: %s is not valid LinkParams JSON: %w", src, err)
	}
	link, err := spec.ShareLink(*proto, p)
	if err != nil {
		return fmt.Errorf("share-link: %w", err)
	}
	fmt.Println(link)
	return nil
}

// cmdBundle renders a node's distribution Bundle (RP-0008 P3-b) from its params.json + identities.json
// (the first client is the endpoint credential), runs the pure spec.RenderBundle, and writes the JSON
// (jq-style: 2-space indent, no HTML escaping so '&' in links stays literal, trailing newline) to --out
// (or stdout). It is the Go port of the shell `myceliumctl bundle`; bundle_render_go_equiv asserts
// byte-identical output (modulo the generated_at instant) before any renderer cutover. No network.
func cmdBundle(args []string) error {
	fs := flag.NewFlagSet("bundle", flag.ContinueOnError)
	paramsPath := fs.String("params", "", "params.json (required)")
	statePath := fs.String("state", "", "identities.json (required)")
	frontPath := fs.String("front", "", "optional FrontConfig JSON (ADR-0033): when enabled, appends one fronted endpoint")
	out := fs.String("out", "-", "output file (- for stdout)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *paramsPath == "" || *statePath == "" {
		return fmt.Errorf("bundle: --params and --state are required")
	}
	var fc spec.FrontConfig // zero value = disabled => RenderBundleFront is byte-identical to RenderBundle
	if *frontPath != "" {
		fdata, err := os.ReadFile(*frontPath)
		if err != nil {
			return fmt.Errorf("bundle: read front %s: %w", *frontPath, err)
		}
		if err := json.Unmarshal(fdata, &fc); err != nil {
			return fmt.Errorf("bundle: %s is not a valid FrontConfig: %w", *frontPath, err)
		}
	}
	pdata, err := os.ReadFile(*paramsPath)
	if err != nil {
		return fmt.Errorf("bundle: read params %s: %w", *paramsPath, err)
	}
	var pmap map[string]json.RawMessage
	if err := json.Unmarshal(pdata, &pmap); err != nil {
		return fmt.Errorf("bundle: %s is not valid params JSON: %w", *paramsPath, err)
	}
	sdata, err := os.ReadFile(*statePath)
	if err != nil {
		return fmt.Errorf("bundle: read state %s: %w", *statePath, err)
	}
	var st struct {
		Clients []struct {
			ID       string `json:"id"`
			Password string `json:"password"`
		} `json:"clients"`
	}
	if err := json.Unmarshal(sdata, &st); err != nil {
		return fmt.Errorf("bundle: %s is not valid identity state JSON: %w", *statePath, err)
	}
	var id, pw string
	if len(st.Clients) > 0 {
		id, pw = st.Clients[0].ID, st.Clients[0].Password
	}
	b, err := spec.RenderBundleFront(pmap, id, pw, fc, time.Now().UTC().Truncate(time.Second))
	if err != nil {
		return fmt.Errorf("bundle: %w", err)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(b); err != nil {
		return fmt.Errorf("bundle: marshal: %w", err)
	}
	if *out == "-" {
		_, err = os.Stdout.Write(buf.Bytes())
		return err
	}
	if err := os.WriteFile(*out, buf.Bytes(), 0o644); err != nil {
		return fmt.Errorf("bundle: write %s: %w", *out, err)
	}
	return nil
}

// cmdSubscription emits per-client sing-box + Clash-Meta subscription configs (RP-0008 P3-d) via
// spec.RenderSubscription — the Go port of the shell `myceliumctl subscription --engine singbox`.
// It writes <safe>.singbox.json (marshalled exactly like bundle: SetEscapeHTML(false) + 2-space indent
// + trailing newline) and <safe>.clash.yaml per client into the --out directory.
func cmdSubscription(args []string) error {
	fs := flag.NewFlagSet("subscription", flag.ContinueOnError)
	paramsPath := fs.String("params", "", "params.json (required)")
	statePath := fs.String("state", "", "identities.json (required)")
	out := fs.String("out", "control/out", "output directory")
	engine := fs.String("engine", "singbox", "engine (only singbox is ported to the Go spine)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *engine != "singbox" {
		return fmt.Errorf("subscription: --engine %q is not ported to the Go spine; use control/myceliumctl for the xray subscription", *engine)
	}
	if *paramsPath == "" || *statePath == "" {
		return fmt.Errorf("subscription: --params and --state are required")
	}
	pdata, err := os.ReadFile(*paramsPath)
	if err != nil {
		return fmt.Errorf("subscription: read params %s: %w", *paramsPath, err)
	}
	var pmap map[string]json.RawMessage
	if err := json.Unmarshal(pdata, &pmap); err != nil {
		return fmt.Errorf("subscription: %s is not valid params JSON: %w", *paramsPath, err)
	}
	sdata, err := os.ReadFile(*statePath)
	if err != nil {
		return fmt.Errorf("subscription: read state %s: %w", *statePath, err)
	}
	var st struct {
		Clients []struct {
			Name     string `json:"name"`
			ID       string `json:"id"`
			Password string `json:"password"`
		} `json:"clients"`
	}
	if err := json.Unmarshal(sdata, &st); err != nil {
		return fmt.Errorf("subscription: %s is not valid identity state JSON: %w", *statePath, err)
	}
	clients := make([]spec.SubClient, 0, len(st.Clients))
	for _, c := range st.Clients {
		clients = append(clients, spec.SubClient{Name: c.Name, ID: c.ID, Password: c.Password})
	}
	subs, err := spec.RenderSubscription(pmap, clients)
	if err != nil {
		return fmt.Errorf("subscription: %w", err)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return fmt.Errorf("subscription: mkdir %s: %w", *out, err)
	}
	for _, s := range subs {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", "  ")
		if err := enc.Encode(s.Singbox); err != nil {
			return fmt.Errorf("subscription: marshal sing-box config for %q: %w", s.Name, err)
		}
		sbPath := filepath.Join(*out, s.Safe+".singbox.json")
		if err := os.WriteFile(sbPath, buf.Bytes(), 0o644); err != nil {
			return fmt.Errorf("subscription: write %s: %w", sbPath, err)
		}
		clashPath := filepath.Join(*out, s.Safe+".clash.yaml")
		if err := os.WriteFile(clashPath, []byte(s.Clash), 0o644); err != nil {
			return fmt.Errorf("subscription: write %s: %w", clashPath, err)
		}
	}
	return nil
}

// cmdRenderServer renders the node's sing-box SERVER config (RP-0008 P3-e) via spec.RenderServer — the
// Go port of `myceliumctl render-server --engine singbox` (incl. the two-hop via_user routing). The
// Go renderer encodes the template structure in typed structs, so --template is accepted (CLI parity)
// but unused; the render_server_go_equiv gate keeps the structs in lockstep with the shipped template.
func cmdRenderServer(args []string) error {
	fs := flag.NewFlagSet("render-server", flag.ContinueOnError)
	engine := fs.String("engine", "singbox", "engine (only singbox is ported to the Go spine)")
	_ = fs.String("template", "", "template path (accepted for CLI parity; the Go renderer encodes the template)")
	paramsPath := fs.String("params", "", "params.json (required)")
	statePath := fs.String("state", "", "identities.json (required)")
	out := fs.String("out", "-", "output file (- for stdout)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *engine != "singbox" {
		return fmt.Errorf("render-server: --engine %q is not ported to the Go spine; use control/myceliumctl for the xray engine", *engine)
	}
	if *paramsPath == "" || *statePath == "" {
		return fmt.Errorf("render-server: --params and --state are required")
	}
	pdata, err := os.ReadFile(*paramsPath)
	if err != nil {
		return fmt.Errorf("render-server: read params %s: %w", *paramsPath, err)
	}
	var pmap map[string]json.RawMessage
	if err := json.Unmarshal(pdata, &pmap); err != nil {
		return fmt.Errorf("render-server: %s is not valid params JSON: %w", *paramsPath, err)
	}
	sdata, err := os.ReadFile(*statePath)
	if err != nil {
		return fmt.Errorf("render-server: read state %s: %w", *statePath, err)
	}
	var st struct {
		Clients []struct {
			Name     string  `json:"name"`
			ID       string  `json:"id"`
			Password *string `json:"password"`
		} `json:"clients"`
	}
	if err := json.Unmarshal(sdata, &st); err != nil {
		return fmt.Errorf("render-server: %s is not valid identity state JSON: %w", *statePath, err)
	}
	clients := make([]spec.ServerClient, 0, len(st.Clients))
	for _, c := range st.Clients {
		clients = append(clients, spec.ServerClient{Name: c.Name, ID: c.ID, Password: c.Password})
	}
	srv, err := spec.RenderServer(pmap, clients)
	if err != nil {
		return fmt.Errorf("render-server: %w", err)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(srv); err != nil {
		return fmt.Errorf("render-server: marshal: %w", err)
	}
	if *out == "-" {
		_, err = os.Stdout.Write(buf.Bytes())
		return err
	}
	if err := os.WriteFile(*out, buf.Bytes(), 0o644); err != nil {
		return fmt.Errorf("render-server: write %s: %w", *out, err)
	}
	return nil
}

// cmdFrontRender compiles an operator's FrontConfig into the nginx edge-proxy config they deploy on their
// bring-your-own-domain front (ADR-0033 P2). The node's direct address + the frontable transport's port
// come from --params. A disabled / invalid / non-frontable front fails closed; nothing on a node runs this.
func cmdFrontRender(args []string) error {
	fs := flag.NewFlagSet("front-render", flag.ContinueOnError)
	frontPath := fs.String("front", "", "front config JSON (FrontConfig; required)")
	paramsPath := fs.String("params", "", "params.json (for node_address + the transport port; required)")
	out := fs.String("out", "-", "output file (- for stdout)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *frontPath == "" || *paramsPath == "" {
		return fmt.Errorf("front-render: --front and --params are required")
	}
	fdata, err := os.ReadFile(*frontPath)
	if err != nil {
		return fmt.Errorf("front-render: read front %s: %w", *frontPath, err)
	}
	var fc spec.FrontConfig
	if err := json.Unmarshal(fdata, &fc); err != nil {
		return fmt.Errorf("front-render: %s is not a valid FrontConfig: %w", *frontPath, err)
	}
	pdata, err := os.ReadFile(*paramsPath)
	if err != nil {
		return fmt.Errorf("front-render: read params %s: %w", *paramsPath, err)
	}
	var pmap map[string]json.RawMessage
	if err := json.Unmarshal(pdata, &pmap); err != nil {
		return fmt.Errorf("front-render: %s is not valid params JSON: %w", *paramsPath, err)
	}
	conf, err := spec.FrontProxyFromParams(fc, pmap)
	if err != nil {
		return fmt.Errorf("front-render: %w", err)
	}
	if *out == "-" {
		_, err = os.Stdout.Write([]byte(conf))
		return err
	}
	if err := os.WriteFile(*out, []byte(conf), 0o644); err != nil {
		return fmt.Errorf("front-render: write %s: %w", *out, err)
	}
	return nil
}

// cmdLinkOutbound parses an opaque client share-link into a sing-box client outbound (RP-0008 P3-c) via
// the pure spec.OutboundFromLink (the inverse of share-link) and prints the compact-JSON outbound on
// stdout, or "null" when the link yields no faithful outbound (a ShadowTLS ss-link or an unknown scheme —
// the shell's fail-closed null). It is the Go port of the shell `myc_agg_link_outbound`;
// aggregate_outbound_go_equiv asserts byte-identical output. No network.
func cmdLinkOutbound(args []string) error {
	fs := flag.NewFlagSet("link-outbound", flag.ContinueOnError)
	tag := fs.String("tag", "", "outbound tag (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *tag == "" {
		return fmt.Errorf("link-outbound: --tag is required")
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("link-outbound: exactly one LINK argument is required")
	}
	ob, err := spec.OutboundFromLink(*tag, fs.Arg(0))
	if err != nil {
		return fmt.Errorf("link-outbound: %w", err)
	}
	if ob == nil {
		fmt.Println("null")
		return nil
	}
	fmt.Println(string(ob))
	return nil
}

// cmdAggregate folds >=2 per-node distribution Bundles into ONE client sing-box profile (RP-0008 P3-c)
// via the pure spec.RenderAggregate, writing the profile (jq-style) to --out (or stdout). The flag shape
// mirrors the shell `myceliumctl aggregate`: --out FILE plus repeated `--bundle FILE [--name LABEL]` (a
// --name binds to the preceding --bundle; an unnamed input defaults to node<N>). LOCAL-only: it reads the
// input bundle files and writes the profile, no network. bundle_render's sibling; aggregate_render_go_equiv
// asserts byte-identical output before any cutover.
func cmdAggregate(args []string) error {
	var out string
	var files, labels []string
	cur := -1
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--out":
			i++
			if i >= len(args) {
				return fmt.Errorf("aggregate: --out needs a value")
			}
			out = args[i]
		case "--bundle":
			i++
			if i >= len(args) {
				return fmt.Errorf("aggregate: --bundle needs a value")
			}
			files = append(files, args[i])
			labels = append(labels, "")
			cur = len(files) - 1
		case "--name":
			i++
			if i >= len(args) {
				return fmt.Errorf("aggregate: --name needs a value")
			}
			if cur < 0 {
				return fmt.Errorf("aggregate: --name %q has no preceding --bundle (give --bundle FILE first)", args[i])
			}
			if labels[cur] != "" {
				return fmt.Errorf("aggregate: --bundle already has a --name (%q); only one --name per --bundle", labels[cur])
			}
			labels[cur] = args[i]
		default:
			return fmt.Errorf("aggregate: unknown argument: %s", args[i])
		}
	}
	if out == "" {
		return fmt.Errorf("aggregate: --out is required")
	}
	inputs := make([]spec.AggregateInput, 0, len(files))
	for i, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return fmt.Errorf("aggregate: read %s: %w", f, err)
		}
		var b spec.Bundle
		if err := json.Unmarshal(data, &b); err != nil {
			return fmt.Errorf("aggregate: %s is not valid bundle JSON: %w", f, err)
		}
		inputs = append(inputs, spec.AggregateInput{Bundle: b, Label: labels[i]})
	}
	profile, err := spec.RenderAggregate(inputs)
	if err != nil {
		return fmt.Errorf("aggregate: %w", err)
	}
	if out == "-" {
		_, err = os.Stdout.Write(profile)
		return err
	}
	if err := os.WriteFile(out, profile, 0o644); err != nil {
		return fmt.Errorf("aggregate: write %s: %w", out, err)
	}
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

// readFileOrStdin reads a CLI FILE argument, or stdin when the argument is "-".
func readFileOrStdin(name string) ([]byte, error) {
	if name == "-" {
		return io.ReadAll(os.Stdin)
	}
	return os.ReadFile(name)
}

// cmdNode is the operator-facing node-profile surface (ADR-0034 / RP-0011 chunk C). These verbs are
// READ-ONLY: they parse, validate, and preview the node descriptor — they never write node state or
// shell the deploy path (the live-mutating verbs land once the bootstrap reads the descriptor).
func cmdNode(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("node: a subcommand is required (validate | plan)")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "validate":
		return cmdNodeValidate(rest)
	case "plan":
		return cmdNodePlan(rest)
	default:
		return fmt.Errorf("node: unknown subcommand %q (validate | plan)", sub)
	}
}

// cmdNodeValidate parses + fail-closed-validates a node profile descriptor read from FILE|- (ADR-0034).
// Read-only. A stray node-"type" enum or any out-of-set field is refused by ParseNodeProfile.
func cmdNodeValidate(args []string) error {
	fs := flag.NewFlagSet("node validate", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("node validate: exactly one node profile FILE (or - for stdin) is required")
	}
	data, err := readFileOrStdin(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("node validate: read %s: %w", fs.Arg(0), err)
	}
	p, err := spec.ParseNodeProfile(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("node validate: %w", err)
	}
	keys, _ := p.EnabledKeys()
	fmt.Printf("ok\tvalid node profile\ttransports=%d\treachable=%t\tfront=%t\tingress=%t\n",
		len(keys), p.Reachable, p.Front.Enabled, p.Ingress != nil)
	return nil
}

// cmdNodePlan prints what a node profile resolves to — a DRY-RUN preview, no mutation. It shows the
// params enable-keys the descriptor's transports turn on (resolved through the registry) with each
// transport's port/engine/frontable, plus the reachability posture and the front/ingress/loops summary.
func cmdNodePlan(args []string) error {
	fs := flag.NewFlagSet("node plan", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("node plan: exactly one node profile FILE (or - for stdin) is required")
	}
	data, err := readFileOrStdin(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("node plan: read %s: %w", fs.Arg(0), err)
	}
	p, err := spec.ParseNodeProfile(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("node plan: %w", err)
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "# node profile plan (dry-run — nothing is applied)")
	if len(p.Transports) == 0 {
		fmt.Fprintln(w, "transports:\t(empty — the node keeps its default-on set)")
	} else {
		fmt.Fprintln(w, "transports:")
		for _, t := range p.Transports {
			d, _ := spec.ProtoByName(t)
			fmt.Fprintf(w, "  %s\tenable=%s\tport=%d\tengine=%s\tfrontable=%t\n",
				t, d.EnableKey, d.DefaultPort, d.Engine, spec.IsFrontableTransport(t))
		}
	}
	fmt.Fprintf(w, "reachable:\t%t (public-entry posture)\n", p.Reachable)
	if p.Front.Enabled {
		fmt.Fprintf(w, "front:\tenabled transport=%s mode=%s\n", p.Front.Transport, p.Front.EffectiveMode())
	} else {
		fmt.Fprintln(w, "front:\tdisabled")
	}
	fmt.Fprintf(w, "ingress(two-hop):\t%t\n", p.Ingress != nil)
	fmt.Fprintf(w, "loops:\tupdate=%t rotate=%t measure=%t\n", p.Loops.Update, p.Loops.Rotate, p.Loops.Measure)
	return w.Flush()
}

// cmdTransport is the operator-facing transport catalog surface (read-only).
func cmdTransport(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("transport: a subcommand is required (list)")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		return cmdTransportList(rest)
	default:
		return fmt.Errorf("transport: unknown subcommand %q (list)", sub)
	}
}

// cmdTransportList prints the closed transport registry (the Go-owned single source of truth) — proto,
// class, port, engine, and whether each is CDN-frontable / operator-toggleable. Read-only.
func cmdTransportList(args []string) error {
	fs := flag.NewFlagSet("transport list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit the registry as JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("transport list: takes no positional arguments")
	}
	reg := spec.TransportRegistry()
	if *asJSON {
		data, err := json.MarshalIndent(reg, "", "  ")
		if err != nil {
			return fmt.Errorf("transport list: marshal: %w", err)
		}
		_, err = os.Stdout.Write(append(data, '\n'))
		return err
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "PROTO\tCLASS\tPORT\tENGINE\tFRONTABLE\tTOGGLEABLE")
	for _, d := range reg {
		fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%t\t%t\n",
			d.Proto, d.Class, d.DefaultPort, d.Engine, spec.IsFrontableTransport(d.Proto), d.EnableKey != "")
	}
	return w.Flush()
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
  share-link --proto P FILE|-                  render the dialable client share-link for a transport from LinkParams JSON (RP-0008 P3)
  bundle --params F --state F [--out F|-]       render a node's distribution Bundle JSON from params + identities (RP-0008 P3)
  link-outbound --tag T LINK                    parse a client share-link into a sing-box client outbound JSON (RP-0008 P3)
  aggregate --out F --bundle F [--name L] ...   fold >=2 per-node bundles into one client sing-box profile (RP-0008 P3)
  node validate FILE|-                         parse + validate a node profile descriptor (ADR-0034)
  node plan FILE|-                             dry-run: preview what a node profile resolves to (read-only)
  transport list [--json]                      list the closed transport registry (proto/class/port/engine/frontable)
  version                                      print the spine version
  help                                         show this help

Not yet ported to the Go spine (use the shell tool control/myceliumctl):
  reality-keys                                 (RP-0002 W7)

Default state file: %s
`, spec.Version, defaultState)
}
