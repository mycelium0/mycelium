// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"encoding/json"
	"io"
)

// EngineManifest mirrors control/engines.manifest.json (RP-0011 chunk C): the pinned dataplane
// engine versions + per-arch archive SHA256 that node-bootstrap reads as DEFAULT install pins. It is
// the SINGLE source both the bash resolver (control/lib/nb_engine_manifest.sh) and the Go deploy-plan
// preview read, so the printed/resolved pins cannot diverge from what the installer would use.
type EngineManifest struct {
	Version int                   `json:"version"`
	Engines map[string]EnginePins `json:"engines"`
}

// EnginePins is one engine's pinned version + download base + per-(normalised-)arch archive SHA256.
type EnginePins struct {
	Version string            `json:"version"`
	DLBase  string            `json:"dl_base"`
	SHA256  map[string]string `json:"sha256"`
}

// ParseEngineManifest decodes the manifest. Unknown keys (e.g. a leading "_comment") are tolerated so
// the committed file can carry an inline note.
func ParseEngineManifest(r io.Reader) (EngineManifest, error) {
	var m EngineManifest
	if err := json.NewDecoder(r).Decode(&m); err != nil {
		return EngineManifest{}, err
	}
	return m, nil
}

// NormArch maps a Go runtime.GOARCH (or a uname-ish token) to the manifest's normalised arch keyspace
// {amd64, arm64}. armv7 is intentionally uncovered (it stays a required install flag) and anything
// else returns "" (no manifest pin → the installer's required-flag fallback applies).
func NormArch(goarch string) string {
	switch goarch {
	case "amd64", "x86_64":
		return "amd64"
	case "arm64", "aarch64":
		return "arm64"
	case "arm", "armv7", "armv7l":
		return "armv7"
	default:
		return ""
	}
}

// Pin resolves {version, sha256, dl_base} for an engine on a normalised arch. ok is false when the
// engine, the arch, or a non-empty digest is missing — the caller then falls back to a required pin.
func (m EngineManifest) Pin(engine, arch string) (version, sha256, dlBase string, ok bool) {
	e, exists := m.Engines[engine]
	if !exists {
		return "", "", "", false
	}
	s, has := e.SHA256[arch]
	if !has || s == "" {
		return "", "", "", false
	}
	return e.Version, s, e.DLBase, true
}
