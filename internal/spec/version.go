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
// runtime source of truth reported by both myceliumctl and myceliumd.
const Version = "0.1.0"
