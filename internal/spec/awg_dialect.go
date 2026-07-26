// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

// awg_dialect.go — the AmneziaWG per-node obfuscation DIALECT, owned by the Go spine (RP-0008: control
// decisions live in a typed, testable owner, not in shell arithmetic).
//
// WHAT A DIALECT IS. AmneziaWG randomises the WireGuard message headers (H1..H4) and pads/junks the
// handshake (Jc/Jmin/Jmax/S1/S2). Every peer of one node — the server and all its clients — MUST carry the
// SAME nine values or the handshake cannot complete. They are TUNABLE, NOT SECRET.
//
// WHY IT IS DERIVED (Audit-0008 S1-4). A dialect hardcoded in a public repo is a free network-wide block:
// one passive UDP payload-match rule keyed on the published H1 drops the AmneziaWG family on EVERY node at
// once. Deriving it from the node's OWN key gives each node a different dialect, discloses none of them,
// and still keeps server+clients in agreement because the derivation is deterministic.
//
// ADR-0002 (no custom cryptography). This is HEADER RANDOMISATION + junk sizing — obfuscation the ADR
// explicitly permits ("shaping, padding, junk packets, header randomization ... permitted — but not a
// confidentiality boundary"). It produces NO key material and is not a confidentiality boundary; SHA-256 is
// used only as an off-the-shelf digest. No primitive is invented here.
//
// This is the AUTHORITATIVE implementation. control/lib/nb_render_awg.sh carries a bash twin for nodes
// without the spine binary; tests/conformance/awg_dialect_go_equiv.sh pins the two byte-identical, exactly
// as the other renderers are pinned (share_link / subscription / aggregate / render_server).

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
)

// awgDialectDomain is the domain-separation label folded into every digest. Changing it changes every
// node's dialect, so it is a constant of the format, not a knob.
const awgDialectDomain = "mycelium-awg-dialect-v1"

// awgHeaderModulus is 2^32 - 5, so `5 + (word % awgHeaderModulus)` lands in [5, 2^32-1]: a uint32 that can
// never collide with WireGuard's own message types 1..4.
const awgHeaderModulus = 4294967291

// awgMaxSaltRetries bounds the distinct-header redraw. Four draws colliding is ~1e-9; the bound exists so a
// pathological input cannot spin forever.
const awgMaxSaltRetries = 16

// AWGDialect is the nine-value AmneziaWG obfuscation dialect of ONE node at ONE rotation epoch.
// H1..H4 are the randomised message-type headers; Jc/Jmin/Jmax are the junk-packet count and size bounds;
// S1/S2 are the init/response packet junk sizes.
type AWGDialect struct {
	Jc   int    `json:"Jc"`
	Jmin int    `json:"Jmin"`
	Jmax int    `json:"Jmax"`
	S1   int    `json:"S1"`
	S2   int    `json:"S2"`
	H1   uint32 `json:"H1"`
	H2   uint32 `json:"H2"`
	H3   uint32 `json:"H3"`
	H4   uint32 `json:"H4"`
}

// Valid reports whether the dialect satisfies every AmneziaWG constraint the peers depend on:
// H1..H4 distinct and all > 4 (never the WireGuard message types), Jmin < Jmax, and (S1 + 56) != S2.
// A dialect that fails this must never be rendered — both sides of every handshake would be at risk.
func (d AWGDialect) Valid() bool {
	hs := [4]uint32{d.H1, d.H2, d.H3, d.H4}
	for i := range hs {
		if hs[i] <= 4 {
			return false
		}
		for j := i + 1; j < len(hs); j++ {
			if hs[i] == hs[j] {
				return false
			}
		}
	}
	if d.Jmin >= d.Jmax {
		return false
	}
	if d.S1+56 == d.S2 {
		return false
	}
	return true
}

// awgDigest returns the 64-hex SHA-256 of "<input>|<domain>|<salt>" — the same string the bash twin hashes.
func awgDigest(input string, salt int) string {
	sum := sha256.Sum256([]byte(input + "|" + awgDialectDomain + "|" + strconv.Itoa(salt)))
	return hex.EncodeToString(sum[:])
}

// awgHexField parses digest[lo:hi] as a hex number. The digest is always 64 hex chars, so a caller using
// the fixed offsets below cannot go out of range; an unparsable slice is a programming error, not input.
func awgHexField(digest string, lo, hi int) (uint64, error) {
	v, err := strconv.ParseUint(digest[lo:hi], 16, 64)
	if err != nil {
		return 0, fmt.Errorf("awg-dialect: unparsable digest field [%d:%d]: %w", lo, hi, err)
	}
	return v, nil
}

// DeriveAWGDialect returns the dialect for a node identified by key, at rotation epoch.
//
// key is the node's own AmneziaWG server private key — it is HASHED, never emitted, and never leaves the
// node. epoch is the node-local rotation counter: epoch 0 derives from the key ALONE (so introducing
// rotation reproduces a node's original dialect byte-for-byte), and every bump folds the counter in to
// yield a completely different dialect from the SAME key — a node can move off a known dialect without
// touching any key or peer. A negative epoch is treated as 0, matching the shell's non-numeric guard.
//
// Deterministic and pure: same (key, epoch) always yields the same dialect, which is exactly what keeps a
// node's server config and its clients' configs in agreement.
func DeriveAWGDialect(key string, epoch int) (AWGDialect, error) {
	if key == "" {
		return AWGDialect{}, fmt.Errorf("awg-dialect: empty node key (cannot derive a per-node dialect)")
	}
	input := key
	if epoch > 0 {
		input = fmt.Sprintf("%s|epoch%d", key, epoch)
	}

	var d AWGDialect
	var digest string
	for salt := 0; ; salt++ {
		if salt >= awgMaxSaltRetries {
			return AWGDialect{}, fmt.Errorf("awg-dialect: could not obtain 4 distinct headers after %d draws (unexpected)", awgMaxSaltRetries)
		}
		digest = awgDigest(input, salt)
		hs := [4]uint32{}
		ok := true
		for i := 0; i < 4; i++ {
			w, err := awgHexField(digest, i*8, i*8+8)
			if err != nil {
				return AWGDialect{}, err
			}
			hs[i] = uint32(5 + (w % awgHeaderModulus))
		}
		// Redraw (bump the salt) unless all four headers are distinct.
		for i := 0; i < 4 && ok; i++ {
			for j := i + 1; j < 4; j++ {
				if hs[i] == hs[j] {
					ok = false
					break
				}
			}
		}
		if ok {
			d.H1, d.H2, d.H3, d.H4 = hs[0], hs[1], hs[2], hs[3]
			break
		}
	}

	// Jitter within tight, known-good bounds, each from a fresh byte of the SAME digest that produced the
	// accepted headers: Jc 3..10, Jmin 24..64, Jmax = Jmin+16..Jmin+64 (Jmin<Jmax with margin),
	// S1 24..96, S2 = S1+57..S1+160 (so (S1+56) != S2 and S2 > S1).
	fields := [5]struct{ lo, hi int }{{32, 34}, {34, 36}, {36, 38}, {38, 40}, {40, 42}}
	var v [5]uint64
	for i, f := range fields {
		w, err := awgHexField(digest, f.lo, f.hi)
		if err != nil {
			return AWGDialect{}, err
		}
		v[i] = w
	}
	d.Jc = int(3 + v[0]%8)
	d.Jmin = int(24 + v[1]%41)
	d.Jmax = d.Jmin + int(16+v[2]%49)
	d.S1 = int(24 + v[3]%73)
	d.S2 = d.S1 + int(57+v[4]%104)

	if !d.Valid() {
		return AWGDialect{}, fmt.Errorf("awg-dialect: derived dialect violates the AmneziaWG constraints (refusing to emit)")
	}
	return d, nil
}

// RenderINI returns the nine dialect lines exactly as they appear in an AmneziaWG [Interface] section, in
// the canonical order the renderers emit (Jc, Jmin, Jmax, S1, S2, H1..H4), each terminated by a newline.
// This is the single source both the server awg0.conf and every client config use, so the two can never
// disagree about ordering or spelling.
func (d AWGDialect) RenderINI() string {
	return fmt.Sprintf("Jc = %d\nJmin = %d\nJmax = %d\nS1 = %d\nS2 = %d\nH1 = %d\nH2 = %d\nH3 = %d\nH4 = %d\n",
		d.Jc, d.Jmin, d.Jmax, d.S1, d.S2, d.H1, d.H2, d.H3, d.H4)
}
