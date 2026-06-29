# Copyright © 2026 mindicator & silicon bags quartet.
# SPDX-License-Identifier: AGPL-3.0-or-later
# This file is part of Mycelium, licensed under the GNU Affero General Public License v3.0 or
# later. See the LICENSE file in the repository root.
#
# Makefile — build, test, and check the Go control-plane spine (ADR-0012).
# The offline conformance suite remains shell+jq: run `bash tests/run.sh`.

GO  ?= go
PKG := ./...

# --- Release packaging (RP-0011 REL) ---
# DIST_DIR    where the artifact + SHA256SUMS are written.
# DIST_REF    the committed ref to package (default HEAD; release.yml passes the signed tag).
# DIST_VERSION is derived from the single source of truth (internal/spec.Version), so the artifact
#             name can never drift from the spine version (pinned by release_dist_sane.sh).
# SHA256SUM   portable checksum tool (Linux sha256sum / macOS shasum -a 256).
DIST_DIR     ?= dist
DIST_REF     ?= HEAD
DIST_VERSION  = $(shell grep -E '^[[:space:]]*const[[:space:]]+Version' internal/spec/version.go | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
SHA256SUM    ?= $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")

.PHONY: all build test race vet fmt-check tidy clean conformance dist

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
	rm -rf "$(DIST_DIR)"

# Offline conformance gates (shell + jq; no Go toolchain required).
conformance:
	bash tests/run.sh

# dist — produce a DETERMINISTIC source tarball (= AGPL Corresponding Source) of the committed tree at
# DIST_REF, named by the spine version, plus a SHA256SUMS. `git archive` is reproducible and ships ONLY
# tracked files (per-node identity/secrets/rendered configs are gitignored + never tracked, so they can
# never leak into the artifact); `gzip -n` drops the name/mtime so two builds are byte-identical. The
# release is authenticated by a SIGNED git TAG (ADR-0015 SSH-sig, the same scheme verify_signed_ref uses)
# and an SSH signature over SHA256SUMS — neither produced here (the maintainer signs locally; see
# docs/RELEASING.md). Pinned by tests/conformance/release_dist_sane.sh.
dist:
	@command -v git >/dev/null 2>&1 || { echo "dist: git is required" >&2; exit 1; }
	@git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "dist: not inside a git work tree" >&2; exit 1; }
	@mkdir -p "$(DIST_DIR)"
	@name="mycelium-$(DIST_VERSION)"; \
	  git archive --format=tar --prefix="$$name/" "$(DIST_REF)" | gzip -n -9 > "$(DIST_DIR)/$$name.tar.gz"; \
	  ( cd "$(DIST_DIR)" && $(SHA256SUM) "$$name.tar.gz" > SHA256SUMS ); \
	  echo "dist: wrote $(DIST_DIR)/$$name.tar.gz + $(DIST_DIR)/SHA256SUMS (version $(DIST_VERSION), ref $(DIST_REF))"
