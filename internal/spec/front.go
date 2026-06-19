// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "fmt"

// FrontMode is the closed vocabulary for how an operator's CDN/ingress front handles the tunnel
// (ADR-0033). It is the doctrine's relay-vs-terminate switch: relay keeps the metadata posture clean;
// terminate is an explicit, acknowledged trade-off.
type FrontMode string

const (
	// FrontModeUnknown is the zero value and is never a valid wire value (an empty Mode defaults to
	// relay via EffectiveMode, but Validate still rejects an explicitly-unknown enabled front).
	FrontModeUnknown FrontMode = ""
	// FrontModeRelay: the edge FORWARDS the encrypted tunnel — it learns only that a client reached AN
	// edge, never the inner destination or content. The doctrine-clean default (ADR-0029 §4).
	FrontModeRelay FrontMode = "relay"
	// FrontModeTerminate: the edge TERMINATES TLS — it sees the user's source address and destination
	// hostnames and hands both to a third party. A metadata trade-off (ADR-0026 / THREAT-MODEL "worse
	// than neutral"); permitted ONLY with an explicit acknowledgement, never a silent default.
	FrontModeTerminate FrontMode = "terminate"
)

// IsValid reports whether m is a concrete FrontMode (not the unknown sentinel).
func (m FrontMode) IsValid() bool {
	switch m {
	case FrontModeRelay, FrontModeTerminate:
		return true
	default:
		return false
	}
}

// frontableProtos is the CLOSED set of transports a CDN/ingress front may sit in front of: the
// genuine-single-TLS own-cert HTTP-framed shapes. REALITY (borrowed donor handshake), raw, and UDP
// transports are NOT frontable — a front that inspects or terminates TLS would break or not apply to
// them. (A follow-on RP may promote this to a vocab.json registry field; for now it is exactly the
// ADR-0010 transport #10 + ws-tls pair.)
var frontableProtos = map[string]bool{
	"vless-xhttp-tls": true,
	"vless-ws-tls":    true,
}

// IsFrontableTransport reports whether proto is a CDN-frontable transport (ADR-0033 §3).
func IsFrontableTransport(proto string) bool { return frontableProtos[proto] }

// FrontConfig is the INERT, node-local descriptor for an OPTIONAL operator-provided CDN/ingress front
// (ADR-0033, extends ADR-0029). Bring-your-own-domain, opt-in, default-off. Nothing consumes it yet —
// it is the schema-before-behaviour anchor for the fronting render/deploy a follow-on RP adds. A front
// is COMPLEMENTARY / last-resort: it adds reachability on networks that block by IP/SNI and hardens
// control-plane distribution, but it is NOT a fix for the destination-class throughput throttle, where
// the in-region two-hop is primary (THREAT-MODEL / ADR-0027). Pure data; nothing actuates on it here.
type FrontConfig struct {
	Enabled              bool      `json:"enabled"`                          // opt-in; default-off (a disabled front is byte-identical to no front)
	Domain               string    `json:"domain,omitempty"`                 // the operator's OWN fronting domain (core registers none — ADR-0029 / positioning)
	Transport            string    `json:"transport,omitempty"`              // the CDN-frontable transport the front sits in front of (frontable set only)
	Mode                 FrontMode `json:"mode,omitempty"`                   // relay (default, doctrine-clean) | terminate (explicit metadata trade-off)
	AckTerminateTradeoff bool      `json:"ack_terminate_tradeoff,omitempty"` // REQUIRED to choose terminate (the ADR-0026 metadata trade-off, never silent)
}

// EffectiveMode returns the configured Mode, defaulting an empty Mode to relay — the doctrine-clean
// default (ADR-0029 §4). It does not validate.
func (c FrontConfig) EffectiveMode() FrontMode {
	if c.Mode == FrontModeUnknown {
		return FrontModeRelay
	}
	return c.Mode
}

// Validate enforces the ADR-0033 invariants. A disabled front is always valid (default-off, inert). An
// enabled front MUST carry the operator's own domain, sit in front of a frontable transport, and use a
// known mode; choosing terminate REQUIRES the explicit trade-off acknowledgement (relay never does).
// Pure.
func (c FrontConfig) Validate() error {
	if !c.Enabled {
		return nil // default-off: nothing to constrain
	}
	if c.Domain == "" {
		return fmt.Errorf("%w: front.domain (an enabled front requires the operator's own domain — core registers none)", ErrEmptyField)
	}
	if !IsFrontableTransport(c.Transport) {
		return fmt.Errorf("%w: front.transport %q is not CDN-frontable (only the genuine-single-TLS own-cert HTTP transports vless-xhttp-tls / vless-ws-tls; REALITY/raw/UDP cannot be fronted)", ErrUnknownEnum, c.Transport)
	}
	mode := c.EffectiveMode()
	if !mode.IsValid() {
		return fmt.Errorf("%w: front.mode %q", ErrUnknownEnum, c.Mode)
	}
	if mode == FrontModeTerminate && !c.AckTerminateTradeoff {
		return fmt.Errorf("front.mode terminate requires ack_terminate_tradeoff=true: a TLS-terminating edge sees the user's source address and destination hostnames (a metadata trade-off — ADR-0026 / THREAT-MODEL); relay is the doctrine-clean default")
	}
	return nil
}
