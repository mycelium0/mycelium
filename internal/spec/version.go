// Copyright © 2026 mindicator & silicon bags quartet.
// SPDX-License-Identifier: AGPL-3.0-or-later
// This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
// later. See the LICENSE file in the repository root.

// Package spec holds Mycelium's shared, typed control-plane schemas — the single
// source of truth that both myceliumctl and myceliumd build on (ADR-0012). It
// contains data models and pure logic only: no file I/O, no network, and no
// process execution, so it is trivially testable.
package spec

// Version is the Mycelium control-plane spine version (SemVer). It is the single
// runtime source of truth reported by both myceliumctl and myceliumd. During the 0.x
// alpha the MINOR digit tracks the lifecycle PHASE (0.0.x = Phase 0, 0.1.x = Phase 1,
// 0.2.x = Phase 2, …); the PATCH increments per landed phase increment, and a git tag
// (v0.1.N) marks a phase close. 1.0.0 is reserved for the first stable public release.
// Per-build identity is SourceRev (below), not this hand-bumped const.
const Version = "0.2.27"

// SourceRev is the source revision the binary was built from. It is empty for a plain
// `go build` and is stamped at build time via the linker
// (`-ldflags "-X github.com/mycelium0/mycelium/internal/spec.SourceRev=<rev>"`) by the
// node-bootstrap spine install (RP-0008 P3). Because Version is a hand-bumped SemVer
// const that two commits routinely share, SourceRev is the FINE-GRAINED identity the
// node's idempotent build keys on, so a node never serves a stale binary after an update.
var SourceRev = ""
