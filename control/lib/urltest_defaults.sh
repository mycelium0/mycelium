# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# urltest_defaults.sh — the client urltest hysteresis knobs, in ONE place that anything may source.
# Author: mindicator & silicon bags quartet.
#
# These three values are emitted into every issued client config and are also what a conformance check
# must compare against. They used to live as literals in the renderer AND as literals in control/selftest.sh,
# and a deliberate, measured retune of the interval then read as a regression — with the obvious way out
# being to edit the number in the test, which is how a check stops checking anything.
#
# They cannot simply be read by sourcing the renderer: render_singbox.sh calls myc_vocab_protos at top
# level, so sourcing it standalone dies with command-not-found (the cross-lib dependency that a gate
# sourcing a lib on its own always trips over). This file defines VALUES ONLY and calls nothing, so it is
# safe to source from anywhere.
#
# The Go half mirrors them in internal/spec/aggregate.go, where the measurement behind the interval is
# recorded; subscription_go_equiv pins the two halves byte-for-byte.

# How often a client re-tests its group. This is what a blackout costs: sing-box's urltest re-selects on
# its interval and on nothing else, so an outage shorter than the interval produces no failover at all.
# 90s matches the node's own rotate tick, so the system has one control period rather than two.
MYC_URLTEST_INTERVAL="${MYC_URLTEST_INTERVAL:-90s}"
# Latency difference, in ms, required before the group switches — the anti-thrash margin.
MYC_URLTEST_TOLERANCE="${MYC_URLTEST_TOLERANCE:-150}"
# Testing pauses after this much idle time, so a shorter interval does not turn an idle client into a
# periodic heartbeat.
MYC_URLTEST_IDLE_TIMEOUT="${MYC_URLTEST_IDLE_TIMEOUT:-30m}"
