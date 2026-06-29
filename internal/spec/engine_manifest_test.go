// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"strings"
	"testing"
)

func TestParseEngineManifestAndPin(t *testing.T) {
	const j = `{"_comment":"note","version":1,"engines":{
		"singbox":{"version":"v1.13.13","dl_base":"https://example/sb","sha256":{"amd64":"aa","arm64":"bb"}},
		"xray":{"version":"v26.3.27","dl_base":"https://example/xr","sha256":{"amd64":"cc"}}}}`
	m, err := ParseEngineManifest(strings.NewReader(j))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if m.Version != 1 {
		t.Errorf("version = %d, want 1", m.Version)
	}
	if v, s, b, ok := m.Pin("singbox", "amd64"); !ok || v != "v1.13.13" || s != "aa" || b != "https://example/sb" {
		t.Errorf("Pin(singbox,amd64) = %q,%q,%q,%v", v, s, b, ok)
	}
	if _, _, _, ok := m.Pin("singbox", "armv7"); ok {
		t.Error("armv7 must be uncovered (required-flag fallback)")
	}
	if _, _, _, ok := m.Pin("xray", "arm64"); ok {
		t.Error("xray arm64 (absent sha) must be !ok")
	}
	if _, _, _, ok := m.Pin("nope", "amd64"); ok {
		t.Error("unknown engine must be !ok")
	}
}

func TestNormArch(t *testing.T) {
	cases := map[string]string{
		"amd64": "amd64", "x86_64": "amd64",
		"arm64": "arm64", "aarch64": "arm64",
		"arm": "armv7", "armv7l": "armv7",
		"mips": "", "": "",
	}
	for in, want := range cases {
		if got := NormArch(in); got != want {
			t.Errorf("NormArch(%q) = %q, want %q", in, got, want)
		}
	}
}
