SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

KEYS ?= $(HOME)/.keys
NOTARY_PROFILE ?=
ARTIFACT_DIR ?= $(CURDIR)/zig-out/dist

init:
	@echo You probably want to run "zig build" instead.
.PHONY: init help

HELP_C_CYAN   := \033[36m
HELP_C_GREEN  := \033[32m
HELP_C_YELLOW := \033[33m
HELP_C_RESET  := \033[0m

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean

fmt-check:
	zig fmt --check \
		build.zig \
		src/apprt/vibecrafted.zig \
		src/apprt/vibecrafted \
		src/main_vc_board.zig \
		src/main_vc_board_tui_mock.zig \
		src/main_vc_mux.zig \
		src/mux \
		src/os/resourcesdir.zig
.PHONY: fmt-check

fmt:
	zig fmt .
.PHONY: fmt

test-vc:
	zig test src/apprt/vibecrafted/tui/tui.zig
	zig test src/apprt/vibecrafted/runtime/session.zig
	zig test src/apprt/vibecrafted/runtime/dispatch.zig
	zig build test-mux
	zig build vc-board-tui-mock
.PHONY: test-vc

gates: fmt-check test-vc
.PHONY: gates

# Build the vc_ (VC Underscore) runtime. The binary lands in
# zig-out/bin/vc_; a vc-term symlink is created at bundle time for
# environments that cannot render the trailing underscore.
vibecrafted:
	zig build -Druntime=vibecrafted
.PHONY: vibecrafted

# Convenience alias matching the new product mark.
vc:
	zig build -Druntime=vibecrafted
.PHONY: vc

bundle-linux:
	./distribution/bundle.sh --layout linux --output ./zig-out/bundle
.PHONY: bundle-linux

bundle-macos:
	./distribution/bundle.sh --layout macos --output ./zig-out/bundle
.PHONY: bundle-macos

tarball:
	./distribution/linux/build-tarball.sh
.PHONY: tarball

dmg:
	./distribution/macos/build-dmg.sh
.PHONY: dmg

app:
	zig build vc-board-app -Druntime=vibecrafted
.PHONY: app

app-debug:
	zig build vc-board-app -Druntime=vibecrafted -Doptimize=Debug
.PHONY: app-debug

dmg-signed: gates
	KEYS="$(KEYS)" REQUIRE_SIGNING=1 ./distribution/macos/build-dmg.sh
.PHONY: dmg-signed

notarize:
	@latest_dmg="$$(ls -t "$(ARTIFACT_DIR)"/*.dmg 2>/dev/null | head -1)"; \
	if [[ -z "$$latest_dmg" ]]; then \
		echo "No DMG found in $(ARTIFACT_DIR). Run make dmg-signed first." >&2; \
		exit 1; \
	fi; \
	zsh -ic 'KEYS="$(KEYS)" NOTARY_PROFILE="$(NOTARY_PROFILE)" ./distribution/macos/notarize.sh "$$0"' "$$latest_dmg"
.PHONY: notarize

release-local: gates
	KEYS="$(KEYS)" REQUIRE_SIGNING=1 ./distribution/macos/build-dmg.sh
.PHONY: release-local

release: gates
	KEYS="$(KEYS)" REQUIRE_SIGNING=1 ./distribution/macos/build-dmg.sh
	@latest_dmg="$$(ls -t "$(ARTIFACT_DIR)"/*.dmg 2>/dev/null | head -1)"; \
	zsh -ic 'KEYS="$(KEYS)" NOTARY_PROFILE="$(NOTARY_PROFILE)" ./distribution/macos/notarize.sh "$$0"' "$$latest_dmg"
.PHONY: release

release-clean: clean release
.PHONY: release-clean

info-artifacts:
	@if [[ -d "$(ARTIFACT_DIR)" ]]; then \
		ls -lh "$(ARTIFACT_DIR)"; \
	else \
		echo "$(ARTIFACT_DIR) does not exist yet."; \
	fi
.PHONY: info-artifacts

info-certs:
	@security find-identity -v -p codesigning | grep -E "Developer ID|Apple Development" || true
.PHONY: info-certs

wizard:
	@echo "Legacy Python installers are retired. Use \`make dmg\` on macOS or \`make tarball\` on Linux."
.PHONY: wizard

gui-install:
	@echo "Legacy GUI installer is retired. Use \`make dmg\` or open the packaged vc_.app bundle."
.PHONY: gui-install

help:
	@printf "\n$(HELP_C_CYAN)vc_$(HELP_C_RESET) - Zig runtime packaging\n\n"
	@printf "  $(HELP_C_YELLOW)BUILD$(HELP_C_RESET)\n"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "init" "Point new callers at zig build"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "vibecrafted" "Build the vc_ runtime"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "vc" "Alias for vibecrafted runtime build"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "app" "Build macOS app shell"
	@printf "\n  $(HELP_C_YELLOW)PACKAGE$(HELP_C_RESET)\n"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "bundle-linux" "Build Linux bundle"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "bundle-macos" "Build macOS bundle"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "tarball" "Build Linux tarball"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "dmg" "Build unsigned local macOS DMG"
	@printf "\n  $(HELP_C_YELLOW)RELEASE$(HELP_C_RESET)\n"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "gates" "Format check + targeted Vibecrafted tests"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "release-local" "Gated signed DMG, no notarization"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "release" "Gated signed + notarized DMG (KEYS/NOTARY_PROFILE)"
	@printf "\n  $(HELP_C_YELLOW)HOUSEKEEPING$(HELP_C_RESET)\n"
	@printf "    $(HELP_C_GREEN)%-14s$(HELP_C_RESET) %s\n" "clean" "Remove Zig/macOS build artifacts"
.PHONY: help
