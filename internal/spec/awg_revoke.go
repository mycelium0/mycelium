// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

package spec

import (
	"fmt"
	"strings"
)

// The AmneziaWG revoke DECISIONS, moved out of bash (RP-0008/RP-0009 "no new control-decisions-in-bash").
//
// What lives here is everything that is a judgement about a config: which peers a revoke targets, which
// of them no name can reach, whether there is anything to do at all, what the rewritten config is, and
// whether that rewrite is arithmetically sound. What stays in the shell is only the EFFECTS — removing a
// peer from the running interface, writing files, restarting units.
//
// The move is not tidiness. Every one of these decisions was wrong in bash at least once, and each bug
// was of a kind a table-driven test finds instantly and a shell rewrite hides:
//   - the strip captured the blank line between sections into the preceding block and re-emitted one, so
//     every pass grew the file by a blank per surviving peer, without bound;
//   - the peer resolver decided at the PublicKey line, so a `# name =` marker following the key was
//     invisible — and `PublicKey=KEY` without spaces was invisible to the matcher entirely;
//   - the post-rewrite check compared keys by substring, so a key that is a prefix of another reported
//     as still-present and aborted a revoke that had in fact succeeded;
//   - `grep -c` prints 0 AND exits 1, so a `|| printf '0'` fallback made every count read "0\n0".
//
// StripAWGPeers is byte-identical to the shell `_awg_strip_peers` (awg_revoke_go_equiv pins it).

// AWGPeer is one [Peer] block of an awg0.conf, kept as its exact source lines so a rewrite can put back
// what it did not mean to change — including fields this code has never heard of.
type AWGPeer struct {
	PublicKey string   // the normalised key value, however the line was spaced
	Name      string   // the `# name =` marker, empty when the block carries none
	Lines     []string // the block's source lines, verbatim, starting with "[Peer]"
}

// awgFieldValue returns the value of a `KEY = VALUE` line for the given key, and whether it matched.
// The separator is normalised: `PublicKey=K`, `PublicKey =K` and `  PublicKey  =  K  ` are all legal
// config and all mean the same thing. A matcher anchored on the literal "PublicKey = " sees only the
// third form, which in a revoke means failing to remove a peer while reporting success.
func awgFieldValue(line, key string) (string, bool) {
	t := strings.TrimSpace(line)
	if !strings.HasPrefix(strings.ToLower(t), strings.ToLower(key)) {
		return "", false
	}
	rest := strings.TrimSpace(t[len(key):])
	if !strings.HasPrefix(rest, "=") {
		return "", false
	}
	return strings.TrimSpace(rest[1:]), true
}

// awgNameMarker returns the `# name = VALUE` value of a comment line, and whether it matched.
func awgNameMarker(line string) (string, bool) {
	t := strings.TrimSpace(line)
	if !strings.HasPrefix(t, "#") {
		return "", false
	}
	return awgFieldValue(strings.TrimSpace(t[1:]), "name")
}

func isAWGPeerHeader(line string) bool { return strings.TrimSpace(line) == "[Peer]" }

// ParseAWGConf splits a config into its leading section and its [Peer] blocks. Blocks are read WHOLE:
// the name marker and the key may appear in either order, which a line-at-a-time decision gets wrong.
func ParseAWGConf(conf string) (preamble []string, peers []AWGPeer) {
	lines := strings.Split(conf, "\n")
	// A trailing "" from a final newline is an artefact of the split, not a line.
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	cur := -1
	for _, ln := range lines {
		if isAWGPeerHeader(ln) {
			peers = append(peers, AWGPeer{Lines: []string{ln}})
			cur = len(peers) - 1
			continue
		}
		if cur < 0 {
			preamble = append(preamble, ln)
			continue
		}
		p := &peers[cur]
		p.Lines = append(p.Lines, ln)
		if v, ok := awgFieldValue(ln, "PublicKey"); ok && p.PublicKey == "" {
			p.PublicKey = v
		}
		if v, ok := awgNameMarker(ln); ok && p.Name == "" {
			p.Name = v
		}
	}
	return preamble, peers
}

// trimTrailingBlank drops the blank lines at the end of a section. The separator between sections
// belongs to NEITHER of them: whichever section claims it re-emits it next time, and the file grows by a
// line per pass forever. Sections are stored without it and exactly one is written back on output.
func trimTrailingBlank(lines []string) []string {
	i := len(lines)
	for i > 0 && strings.TrimSpace(lines[i-1]) == "" {
		i--
	}
	return lines[:i]
}

// StripAWGPeers rewrites conf without the [Peer] blocks whose PublicKey is in remove.
//
// Byte-identical to the shell `_awg_strip_peers`, and IDEMPOTENT: stripping nothing returns the input
// unchanged once the input is normalised, and stripping twice equals stripping once. "Idempotent" has to
// mean byte-identical or it means nothing — the bash version grew the file on every no-op pass and its
// own gate could not see it, because after a revoke the name owns nothing and the second call
// short-circuits before the stripper runs.
func StripAWGPeers(conf string, remove []string) string {
	kill := make(map[string]bool, len(remove))
	for _, k := range remove {
		if k = strings.TrimSpace(k); k != "" {
			kill[k] = true
		}
	}
	preamble, peers := ParseAWGConf(conf)

	var b strings.Builder
	if pre := trimTrailingBlank(preamble); len(pre) > 0 {
		b.WriteString(strings.Join(pre, "\n"))
		b.WriteString("\n")
	}
	for _, p := range peers {
		if kill[p.PublicKey] {
			continue
		}
		blk := trimTrailingBlank(p.Lines)
		if len(blk) == 0 {
			continue
		}
		b.WriteString("\n")
		b.WriteString(strings.Join(blk, "\n"))
		b.WriteString("\n")
	}
	return b.String()
}

// AWGRevokeTargets decides which peers a by-NAME revoke must remove, and which it CANNOT reach.
//
// Two resolutions, and the second is not belt-and-braces. `--awg-issue` decides "is this a re-issue?"
// from the presence of clients/NAME.private, so a name whose stored key was lost gets a SECOND peer
// enrolled under it; resolving only by the stored key leaves that one valid under a name the operator
// believes is retired. Both were live on a node.
//
// unnamed lists peers carrying no `# name =` marker. Those are reachable by NO name, so their existence
// means a by-name revoke cannot promise the credential is gone — one such peer was found holding a key
// whose private half sat on the same host. The caller must refuse to claim success while any remain.
func AWGRevokeTargets(conf, name, storedPub string) (targets []string, unnamed []string) {
	_, peers := ParseAWGConf(conf)
	seen := map[string]bool{}
	add := func(k string) {
		if k != "" && !seen[k] {
			seen[k] = true
			targets = append(targets, k)
		}
	}
	for _, p := range peers {
		if p.PublicKey == "" {
			continue
		}
		if storedPub != "" && p.PublicKey == storedPub {
			add(p.PublicKey)
		}
		if name != "" && p.Name == name {
			add(p.PublicKey)
		}
		if p.Name == "" {
			unnamed = append(unnamed, p.PublicKey)
		}
	}
	return targets, unnamed
}

// awgDialectKeys are the nine [Interface] obfuscation fields. _awg_swap_dialect hard-dies on any count
// but nine, so a rewrite that loses one bricks the NEXT --awg-regen rather than failing now.
var awgDialectKeys = []string{"Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"}

// CountAWGDialectLines counts the obfuscation fields present in a config.
func CountAWGDialectLines(conf string) int {
	n := 0
	for _, ln := range strings.Split(conf, "\n") {
		for _, k := range awgDialectKeys {
			if _, ok := awgFieldValue(ln, k); ok {
				n++
				break
			}
		}
	}
	return n
}

// countAWGPeersMatching counts how many of the config's peers carry one of the given keys.
func countAWGPeersMatching(conf string, keys []string) int {
	kill := make(map[string]bool, len(keys))
	for _, k := range keys {
		if k = strings.TrimSpace(k); k != "" {
			kill[k] = true
		}
	}
	n := 0
	_, peers := ParseAWGConf(conf)
	for _, p := range peers {
		if kill[p.PublicKey] {
			n++
		}
	}
	return n
}

func countNonBlank(conf string) int {
	n := 0
	for _, ln := range strings.Split(conf, "\n") {
		if strings.TrimSpace(ln) != "" {
			n++
		}
	}
	return n
}

// VerifyAWGStrip checks that a rewrite removed exactly what it meant to and nothing else.
//
// The three cheap checks — a config still has [Interface], a private key and a listen port — only prove
// the file is not empty. These prove the arithmetic:
//   - peer count fell by exactly len(removed);
//   - none of the removed keys survives, matched on the FIELD and not as a substring (one key can
//     contain another as a prefix, and a substring match then aborts a revoke that succeeded);
//   - the dialect field count did not change — compared before-to-after rather than against the literal
//     nine, because a revoke is a SECURITY action and must not refuse to run on a config that is
//     unusual for unrelated reasons;
//   - the non-blank line count fell. This is the backstop: any parse miss that silently kept a block
//     shows up here instead of being reported as success.
func VerifyAWGStrip(before, after string, removed []string) error {
	if !strings.Contains(after, "[Interface]") {
		return fmt.Errorf("rewritten config has no [Interface] section")
	}
	if _, peers := ParseAWGConf(after); true {
		_, was := ParseAWGConf(before)
		// Count what was actually THERE to remove, not the length of the request. A caller may name a key
		// the config does not carry — a revoke re-run, or a removal list assembled from more than one
		// source — and that is a no-op, not an error. Deriving the expectation from the BEFORE config is
		// also the only form that stays right when a key appears twice.
		kill := make(map[string]bool, len(removed))
		for _, k := range removed {
			if k = strings.TrimSpace(k); k != "" {
				kill[k] = true
			}
		}
		present := 0
		for _, p := range was {
			if kill[p.PublicKey] {
				present++
			}
		}
		want := len(was) - present
		if len(peers) != want {
			return fmt.Errorf("peer count is %d, expected %d (%d before, %d of the named keys were present)", len(peers), want, len(was), present)
		}
		for _, p := range peers {
			for _, k := range removed {
				if p.PublicKey == k {
					return fmt.Errorf("a peer that was to be removed is still present")
				}
			}
		}
	}
	if db, da := CountAWGDialectLines(before), CountAWGDialectLines(after); db != da {
		return fmt.Errorf("dialect field count changed from %d to %d — this would brick the next --awg-regen rather than failing here", db, da)
	}
	if removedPresent := countAWGPeersMatching(before, removed); removedPresent > 0 {
		if nb, na := countNonBlank(before), countNonBlank(after); na >= nb {
			return fmt.Errorf("non-blank line count did not fall (%d -> %d) while %d peer(s) were removed — a parse miss looks exactly like this", nb, na, removedPresent)
		}
	}
	return nil
}

// AWGRevokeNeeded reports whether a by-name revoke has anything left to do.
//
// "Already clean" has to be a statement about every place the credential is honoured. A peer that
// survives ONLY inside a dialect backup is exactly what a failed --awg-rotate restores, so a check that
// consults live state alone will call such a node clean and be wrong the moment a rotation fails.
func AWGRevokeNeeded(livePeers int, storedMaterial bool, inBackups bool) bool {
	return livePeers > 0 || storedMaterial || inBackups
}
