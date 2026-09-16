# Nuedeface — build interface, identical across every gwenn-ha-dev project.
# See ../Charte/CHARTE.md §5. This file delegates; it never reimplements.

NAME     := Nuedeface
BIN      := nuedeface
BUNDLE   := dev.gwennha.Nuedeface
# KIND: spm | xcode | swiftc   —   PLATFORM: macos | ios
KIND     := swiftc
PLATFORM := macos
SCHEME   := $(NAME)
CHARTE   := $(abspath ../../Charte)

BUILD_DIR := build

ifeq ($(PLATFORM),ios)
DESTINATION := generic/platform=iOS Simulator
else
DESTINATION := platform=macOS
endif
# CI has neither a provisioning profile nor a signing certificate. Locally we
# sign normally; under CI we do not, because nothing there gets run or shipped.
ifdef CI
SIGNING := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM=
else
SIGNING :=
endif

# MLX-Swift and friends ship build plugins; Xcode refuses to run them unattended.
ifdef CI
PLUGINS := -skipPackagePluginValidation -skipMacroValidation
else
PLUGINS :=
endif

# UI tests drive a real window and need a graphical session; a CI runner has none.
ifdef CI
SKIP_UI := -skip-testing:$(NAME)UITests
else
SKIP_UI :=
endif

APP       := $(BUILD_DIR)/$(NAME).app

.DEFAULT_GOAL := help

# ---------------------------------------------------------------- help

.PHONY: help
help: ## List every target
	@echo "$(NAME) — available targets:"
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- build

.PHONY: deps
deps: ## Fetch and build third-party dependencies, if this project has any
	@if [ -x outils/deps.sh ]; then ./outils/deps.sh; fi

.PHONY: build debug
build: deps ## Release build (warnings are errors)
ifeq ($(KIND),spm)
	swift build -c release -Xswiftc -warnings-as-errors
else ifeq ($(KIND),xcode)
	xcodebuild -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' \
	  -derivedDataPath $(BUILD_DIR)/DerivedData \
	  $(SIGNING) $(PLUGINS) build
else
	./outils/build.sh release
endif

debug: deps ## Debug build
ifeq ($(KIND),spm)
	swift build -c debug
else ifeq ($(KIND),xcode)
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR)/DerivedData build
else
	./outils/build.sh debug
endif

# ---------------------------------------------------------------- test

.PHONY: test
test: ## Run the test suite
ifeq ($(KIND),spm)
	@if swift test --list-tests >/dev/null 2>&1 && [ -n "$$(swift test --list-tests 2>/dev/null)" ]; then \
		swift test ; \
	else \
		echo "› no test target in this package — see make lint" ; \
	fi
else ifeq ($(KIND),xcode)
	@if xcodebuild -list -project $(NAME).xcodeproj 2>/dev/null | grep -q '$(NAME)Tests'; then \
		xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' \
		  -derivedDataPath $(BUILD_DIR)/DerivedData $(SIGNING) $(PLUGINS) $(SKIP_UI) test ; \
	else \
		echo "› no test target in this project — see make lint" ; \
	fi
else
	./outils/test.sh
endif

# ---------------------------------------------------------------- run

.PHONY: run
run: build ## Launch the app
ifeq ($(PLATFORM),ios)
	xcrun simctl boot "iPhone 16" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted "$(APP)" && xcrun simctl launch booted $(BUNDLE)
else
	@test -d "$(APP)" && open "$(APP)" || ./$(BIN)
endif

# ---------------------------------------------------------------- icon

.PHONY: icon
icon: Resources/AppIcon.icns ## Regenerate the app icon

Resources/AppIcon.icns: outils/icone.swift
	@echo "› generating icon"
	@swift outils/icone.swift "$(PWD)"
	@iconutil -c icns Resources/AppIcon.iconset -o $@
	@rm -rf Resources/AppIcon.iconset

# ---------------------------------------------------------------- package

.PHONY: package
package: build icon ## Produce a distributable bundle in build/
ifeq ($(KIND),xcode)
	xcodebuild -scheme $(SCHEME) -configuration Release \
	  -archivePath $(BUILD_DIR)/$(NAME).xcarchive archive
else
	./outils/package.sh
endif

# ---------------------------------------------------------------- lint

.PHONY: lint
lint: ## Check compliance with the project charter
	@if [ -x "$(CHARTE)/outils/verifier.sh" ]; then \
		"$(CHARTE)/outils/verifier.sh" . ; \
	else \
		echo "› charter not checked out next to this repo — lint skipped" ; \
	fi

# ---------------------------------------------------------------- clean

.PHONY: clean
clean: ## Remove every build artefact
	rm -rf $(BUILD_DIR) .build DerivedData Resources/AppIcon.iconset
