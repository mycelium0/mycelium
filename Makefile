# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# Makefile — build, test, and check the Go control-plane spine (ADR-0012).
# The offline conformance suite remains shell+jq: run `bash tests/run.sh`.

GO  ?= go
PKG := ./...

.PHONY: all build test race vet fmt-check tidy clean conformance

all: build

build:
	$(GO) build $(PKG)

test:
	$(GO) test $(PKG)

# race is the required CI gate for the spine (ADR-0012 Compliance).
race:
	$(GO) test -race $(PKG)

vet:
	$(GO) vet $(PKG)

fmt-check:
	@out="$$(gofmt -l . )"; \
	if [ -n "$$out" ]; then echo "gofmt needed in:"; echo "$$out"; exit 1; fi

tidy:
	$(GO) mod tidy

clean:
	$(GO) clean

# Offline conformance gates (shell + jq; no Go toolchain required).
conformance:
	bash tests/run.sh
