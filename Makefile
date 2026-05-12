# Mnemo — engine layer. All build/test/lint flows go through this Makefile.
# `make help` lists targets. The CI workflow at .github/workflows/ci.yml runs
# the same gates — `make ci-local` reproduces it.
#
# The engine builds with Apple CommandLineTools alone (no Xcode required) —
# Phase 1 has no platform-specific APIs. swift-format is installed via Homebrew
# (`brew install swift-format`).

.DEFAULT_GOAL := help
SWIFT ?= swift

## help: list targets
help:
	@grep -E '^##' $(MAKEFILE_LIST) | sed -e 's/## //'

## build: swift build (CommandLineTools alone — no Xcode required)
build:
	$(SWIFT) build

## test: swift test — the swift-testing suite
test:
	$(SWIFT) test

## lint: swift-format lint (errors fail; warnings tolerated, matching the parent repo)
lint:
	swift-format lint -r Sources Tests mlx/Sources

## format: swift-format in place
format:
	swift-format format -i -r Sources Tests mlx/Sources

## ci-local: the same gates CI runs (build + test + lint)
ci-local: build test lint

## build-mlx: build the MnemoEngineMLX package (Xcode required — mlx-swift-lm needs the Metal toolchain). NOT in CI yet; see mlx/README.md.
build-mlx:
	cd mlx && $(SWIFT) build

## clean: remove build artifacts (engine + mlx)
clean:
	rm -rf .build mlx/.build

.PHONY: help build test lint format ci-local build-mlx clean
