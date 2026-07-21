// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
)

// TestClientFingerprintClosedVocab pins the RP-0015 closed vocabulary: the exact member set with chrome
// first (the default), the deliberate exclusion of a randomiser (principle 1 — a unique per-connection
// ClientHello is itself a tell), and the defensive copy on the accessor.
func TestClientFingerprintClosedVocab(t *testing.T) {
	got := ClientFingerprints()
	want := []string{"chrome", "firefox", "edge", "safari", "ios", "android"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("ClientFingerprints() = %v, want %v", got, want)
	}
	if DefaultClientFingerprint != "chrome" || got[0] != DefaultClientFingerprint {
		t.Errorf("default must be chrome and first: default=%q first=%q", DefaultClientFingerprint, got[0])
	}
	for _, bad := range []string{"random", "randomized"} {
		if ValidClientFingerprint(bad) {
			t.Errorf("%q must NOT be a valid client fingerprint (a random ClientHello is itself a tell)", bad)
		}
	}
	// The accessor must hand back a copy, never the package-level slice.
	got[0] = "mutated"
	if ClientFingerprints()[0] != "chrome" {
		t.Error("ClientFingerprints() must return a defensive copy")
	}
}

// TestValidAndNormalizeClientFingerprint: every member validates and normalises to itself; every non-member
// (empty, a randomiser, a case variant, whitespace, garbage) is rejected and normalises to the default.
func TestValidAndNormalizeClientFingerprint(t *testing.T) {
	for _, f := range ClientFingerprints() {
		if !ValidClientFingerprint(f) {
			t.Errorf("ValidClientFingerprint(%q) = false, want true", f)
		}
		if NormalizeClientFingerprint(f) != f {
			t.Errorf("NormalizeClientFingerprint(%q) = %q, want identity", f, NormalizeClientFingerprint(f))
		}
	}
	for _, bad := range []string{"", "random", "randomized", "Chrome", "CHROME", "bogus", "chrome "} {
		if ValidClientFingerprint(bad) {
			t.Errorf("ValidClientFingerprint(%q) = true, want false", bad)
		}
		if NormalizeClientFingerprint(bad) != DefaultClientFingerprint {
			t.Errorf("NormalizeClientFingerprint(%q) = %q, want default %q", bad, NormalizeClientFingerprint(bad), DefaultClientFingerprint)
		}
	}
}

// TestVocabCarriesClientFingerprints: the Go-owned vocab surfaces the closed set (mirrored into
// control/vocab.json by the vocab_single_source gate) and the operator knob is in the toggle allowlist.
func TestVocabCarriesClientFingerprints(t *testing.T) {
	v := NewVocab()
	if strings.Join(v.ClientFingerprints, ",") != strings.Join(ClientFingerprints(), ",") {
		t.Errorf("Vocab.ClientFingerprints = %v, want %v", v.ClientFingerprints, ClientFingerprints())
	}
	found := false
	for _, k := range OperatorToggleKeys() {
		if k == "client_fingerprint" {
			found = true
		}
	}
	if !found {
		t.Error("operator_toggle_keys must include client_fingerprint (RP-0015)")
	}
}

// TestClientFingerprintThreadedConsistently is the increment-A consistency invariant on the Go render
// surface: the ONE client_fingerprint parameter reaches the sing-box subscription outbound, the Clash
// entry, and the share-link identically — and an unset/empty value renders the chrome default everywhere
// (so a node with no override is byte-identical to the pre-RP output).
func TestClientFingerprintThreadedConsistently(t *testing.T) {
	for _, fp := range []string{"firefox", "chrome"} {
		// Two INDEPENDENT families (reality-tcp + genuine-TLS ws) so RenderSubscription's >=2-family
		// invariant (RP-0013 AC-2) is satisfied; both carry the client fingerprint.
		p := rawParams(t, `{
			"node_address":"n","donor_sni":"d","reality_public_key":"P","short_ids":["0123abcd"],
			"tls_sni":"t","vless_reality_vision_enabled":true,"vless_reality_vision_port":443,
			"vless_ws_tls_enabled":true,"vless_ws_tls_port":2089,
			"client_fingerprint":"`+fp+`"}`)
		subs, err := RenderSubscription(p, []SubClient{{Name: "a", ID: "id"}})
		if err != nil {
			t.Fatalf("RenderSubscription(%s): %v", fp, err)
		}
		sb := marshalSub(t, subs[0].Singbox)
		if !strings.Contains(sb, `"fingerprint": "`+fp+`"`) {
			t.Errorf("sing-box config missing utls fingerprint %q:\n%s", fp, sb)
		}
		if !strings.Contains(subs[0].Clash, "client-fingerprint: "+fp) {
			t.Errorf("clash entry missing client-fingerprint %q:\n%s", fp, subs[0].Clash)
		}
		lp := LinkParams{Server: "n", Port: "443", UUID: "id", DonorSNI: "d", Pub: "P", ShortID: "s", Fingerprint: fp}
		link, err := ShareLink("vless-reality-vision", lp)
		if err != nil {
			t.Fatalf("ShareLink(%s): %v", fp, err)
		}
		if !strings.Contains(link, "fp="+fp) {
			t.Errorf("share-link missing fp=%s: %s", fp, link)
		}
	}

	// An empty/omitted fingerprint normalises to chrome at every site (additive: unset == pre-RP output).
	lp := LinkParams{Server: "n", Port: "443", UUID: "id", DonorSNI: "d", Pub: "P", ShortID: "s"} // Fingerprint == ""
	link, err := ShareLink("vless-reality-vision", lp)
	if err != nil {
		t.Fatalf("ShareLink(empty): %v", err)
	}
	if !strings.Contains(link, "fp=chrome") {
		t.Errorf("an empty fingerprint must render fp=chrome (the default): %s", link)
	}
}
