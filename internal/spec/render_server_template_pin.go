// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// ShippedServerTemplateSHA256 is the SHA-256 of nodes/dataplane/singbox/server.template.renderer.json —
// the template whose STRUCTURE the Go renderer encodes in typed structs (render_server_types.go).
//
// WHY A PIN EXISTS AT ALL. The shell renderer runs jq OVER the template file, so editing the template
// changes what a node serves. The Go renderer does not read it: reproducing jq's template-preserving key
// order in Go required encoding the shape in structs, and `--template` was accepted "for CLI parity" and
// then DISCARDED. That is fine while the shell is authoritative and the equivalence gate diffs the two.
// It stops being fine the moment Go renders the live config: an operator edits the template, the node
// converges, and the edit does nothing — silently, at rc=0, which is this project's most expensive
// failure shape.
//
// So the Go renderer now REFUSES a template it does not recognise instead of ignoring it. The refusal is
// on the BYTES, not on a parse: a reformat that changes no meaning still means the structs were not
// re-derived from it, and "no meaning changed" is exactly the judgement a machine must not make here.
//
// Editing the template is therefore a two-part change: edit it, re-derive the structs, update this
// constant. render_server_template_pinned.sh fails offline if the three fall out of step.
const ShippedServerTemplateSHA256 = "aa79c97daa86c84b3eb477169da6c8b27bb80f9fb9e75c4875b1ba5a89768ca9"

// CheckServerTemplatePinned reports whether the template bytes are the ones the Go renderer encodes.
// It returns a nil error only for an exact byte match.
func CheckServerTemplatePinned(template []byte) error {
	sum := sha256.Sum256(template)
	got := hex.EncodeToString(sum[:])
	if got == ShippedServerTemplateSHA256 {
		return nil
	}
	return fmt.Errorf("the Go renderer encodes the sing-box server template in typed structs and does not read the file; "+
		"the template it was handed is not the one it encodes (sha256 %s, expected %s). "+
		"Rendering would silently ignore your edit. Re-derive internal/spec/render_server_types.go from the new template and update "+
		"spec.ShippedServerTemplateSHA256, or render this node through the shell producer (control/myceliumctl render-server)",
		got, ShippedServerTemplateSHA256)
}
