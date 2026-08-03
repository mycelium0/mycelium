// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import "testing"

// TestDemoteFloorIsOverTheIntersection is the whole reason this precondition exists rather than a
// served-set check. The counterexample row below passes a served-set floor and strands every client
// already holding a subscription — the same shape as the defect where the node's own probe reported six
// of six alive while the config it handed out was undialable.
func TestDemoteFloorIsOverTheIntersection(t *testing.T) {
	for _, tc := range []struct {
		name     string
		served   []string
		issued   []string
		demote   string
		wantOK   bool
		wantFams int
	}{
		{
			name:   "THE COUNTEREXAMPLE: served-set floor would pass, the issued client is stranded",
			served: []string{"vless-reality-vision", "hysteria2", "shadowtls", "trojan"},
			issued: []string{"vless-reality-vision", "hysteria2"},
			demote: "vless-reality-vision",
			// served after the demote = {hysteria2, shadowtls, trojan} -> quic-udp folds to own-tls-sni,
			// trojan too, plus shadowtls-tcp = 2 families, so a SERVED-set floor says yes.
			// The intersection is {hysteria2} = 1 family. The client holds nothing else.
			wantOK: false, wantFams: 1,
		},
		{
			name:   "the client holds two independent families besides the demoted one",
			served: []string{"vless-reality-vision", "hysteria2", "shadowsocks"},
			issued: []string{"vless-reality-vision", "hysteria2", "shadowsocks"},
			demote: "vless-reality-vision",
			// {hysteria2 -> own-tls-sni, shadowsocks -> shadowsocks-tcp} = 2
			wantOK: true, wantFams: 2,
		},
		{
			name:   "siblings the client holds are all ONE family after the fold",
			served: []string{"vless-reality-vision", "vless-ws-tls", "trojan"},
			issued: []string{"vless-reality-vision", "vless-ws-tls", "trojan"},
			demote: "vless-reality-vision",
			// ws-tls and trojan both fold to own-tls-sni: several endpoints, one block axis.
			wantOK: false, wantFams: 1,
		},
		{
			name:   "an UNKNOWN baseline is not permission",
			served: []string{"vless-reality-vision", "hysteria2", "shadowsocks"},
			issued: nil,
			demote: "vless-reality-vision",
			wantOK: false, wantFams: 0,
		},
		{
			name:   "the node serves more than the client was issued: only the overlap counts",
			served: []string{"vless-reality-vision", "hysteria2", "shadowsocks", "shadowtls"},
			issued: []string{"vless-reality-vision", "shadowsocks"},
			demote: "vless-reality-vision",
			wantOK: false, wantFams: 1,
		},
		{
			name:   "demoting something the client never held leaves its own set intact",
			served: []string{"vless-reality-vision", "hysteria2", "shadowsocks"},
			issued: []string{"hysteria2", "shadowsocks"},
			demote: "vless-reality-vision",
			wantOK: true, wantFams: 2,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ok, fams := DemoteKeepsIndependentFallback(tc.served, tc.issued, tc.demote)
			if ok != tc.wantOK {
				t.Errorf("ok = %v, want %v (families: %v)", ok, tc.wantOK, fams)
			}
			if len(fams) != tc.wantFams {
				t.Errorf("families = %d %v, want %d", len(fams), fams, tc.wantFams)
			}
		})
	}
}

// A served-set floor and an intersection floor must actually DISAGREE on the counterexample, or the
// distinction this precondition is built on would be decorative.
func TestServedFloorAndIntersectionFloorDisagree(t *testing.T) {
	served := []string{"vless-reality-vision", "hysteria2", "shadowtls", "trojan"}
	issued := []string{"vless-reality-vision", "hysteria2"}

	// what a served-set floor would compute: the whole served set minus the demoted member
	servedOK, servedFams := DemoteKeepsIndependentFallback(served, served, "vless-reality-vision")
	interOK, interFams := DemoteKeepsIndependentFallback(served, issued, "vless-reality-vision")

	if !servedOK {
		t.Fatalf("the served-set view should PASS here (families %v) — without that this test proves nothing", servedFams)
	}
	if interOK {
		t.Fatalf("the intersection view should REFUSE here (families %v)", interFams)
	}
}
