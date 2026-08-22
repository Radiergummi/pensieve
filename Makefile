# Canonical tasks. The framework and its tests are SwiftPM; the app, the CLI and
# the sync agent are Xcode targets — this file is the one place both live.
#
# Steps are cached: each one records what it verified, and re-running it with no
# source change does nothing. `make -B <target>` forces a step to run anyway, and
# `make clean` discards every record.
#
# CI (.github/workflows/ci.yml) keeps its own step wrappers, because it adds
# GitHub-specific plumbing (xcbeautify annotations, result bundles) that has no
# meaning locally — and because a fresh runner has nothing cached to begin with.

# -destination names the Mac explicitly. Without it xcodebuild finds three matching
# destinations (arm64 / x86_64 / Any Mac), prints "WARNING: Using the first of multiple
# matching destinations" on every build, and picks arm64 — which is what this pins, so
# the flag silences the notice without changing what gets built.
#
# -allowProvisioningUpdates is required, not optional: signing is Automatic and the app carries an
# App Group entitlement, so xcodebuild has to register/refresh the App ID and profile with Apple.
# Without the flag it fails with "No profiles for 'me.mazetti.pensieve' were found" instead.
XCODEBUILD_FLAGS = -project Pensieve.xcodeproj \
	-configuration Debug -derivedDataPath ./.build-xcode \
	-destination 'platform=macOS,arch=arm64' \
	-skipMacroValidation -skipPackagePluginValidation \
	-allowProvisioningUpdates

# App Store Connect API key, if one is configured. Without it xcodebuild can only reach Apple
# through a logged-in Xcode GUI session, which lapses silently and then fails every build with
# "No Accounts: Add a new account in Accounts settings". .authkey.mk is gitignored and absent on a
# fresh clone, so -include keeps that clone building exactly as before.
-include .authkey.mk
ifdef ASC_KEY_ID
XCODEBUILD_FLAGS += -authenticationKeyPath $(ASC_KEY_PATH) \
	-authenticationKeyID $(ASC_KEY_ID) \
	-authenticationKeyIssuerID $(ASC_ISSUER_ID)
endif

PRODUCTS = ./.build-xcode/Build/Products/Debug
APP = $(PRODUCTS)/Pensieve.app
PBXPROJ = Pensieve.xcodeproj/project.pbxproj

# What `build` and `cli` actually produce. Used as the cache records for those
# two steps, so deleting build products by hand correctly forces a rebuild —
# which a stamp file in .make would not notice.
APP_CLI = $(APP)/Contents/Helpers/pensieve
CLI = $(PRODUCTS)/pensieve

# The UI probe: a development tool, deliberately outside Sources/ because BUILD_SOURCES globs that
# directory — a probe there would trigger a full app rebuild on every probe edit.
UIPROBE = ./.build/uiprobe
UIPROBE_SOURCES := $(shell find Tools/uiprobe -type f -name '*.swift')

# SMAppService pins the sync agent's registration to path + cdhash, so the app
# only works as a background-sync host from here — not from DerivedData.
INSTALLED_APP = /Applications/Pensieve.app

# Inputs, recomputed every invocation: a find over ~600 paths costs milliseconds.
#
# Directories are prerequisites alongside files, because a stamp compares mtimes
# and a deleted file has none — but removing (or adding) one does bump its
# directory's mtime. That is what makes `make build` notice a file set change and
# regenerate the project, which is the failure this repo hits most (a stale
# .xcodeproj fails as "cannot find X in scope", reading as a code error).
#
# Package.resolved is deliberately NOT an input: xcodebuild rewrites it on every
# app build (MarkdownUI is an xcodebuild-only dependency), so depending on it
# would invalidate the test record after every build.
SWIFT_SOURCES := $(shell find Sources Tests Tools -type f -name '*.swift')
# Tests/ narrowed to the SwiftPM suite on purpose: `swift test` never builds the UI test target, so
# globbing all of Tests/ would re-run the whole suite on every UI-test edit.
#
# Sources/PensieveApp and Sources/PensieveWidget are inputs even though `swift test` never COMPILES
# them: CatalogCoverageTests reads both trees and their .xcstrings to check that every rendered
# literal has a catalog key and vice versa. Without them here, adding a literal to a view leaves
# this record valid and `make test` reports cached-green over a real failure. The cost is small for
# the same reason — app targets are not compiled by the suite, so an app-only edit re-runs the
# tests without rebuilding anything.
TEST_INPUTS := Package.swift $(shell find Sources/PensieveKit Tests/PensieveKitTests \
	Sources/PensieveApp Sources/PensieveWidget ! -name '.*')
UITEST_SOURCES := $(shell find Tests/PensieveUITests -type f -name '*.swift')
# The entitlements files live at the repo root, outside every find root above, so an edit to one
# used to be invisible to this cache: `make build` reported success while the product on disk still
# carried the previous App Group id. They are signing inputs, so they belong here.
BUILD_SOURCES := Pensieve.entitlements PensieveWidget.entitlements $(shell find Sources SyncAgent icons/Pensieve.icon ! -name '.*')

.PHONY: help all test lint generate build cli uiprobe smoke uitest install run clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) \
		| sed 's/:.*##/\t/' \
		| awk -F'\t' '{ printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }'

all: lint test build smoke ## Check, test and build — everything CI checks, in CI's order

# A filtered run proves one test rather than the suite, so it deliberately does
# not record anything: otherwise `make test FILTER=x && make test` would report a
# green suite that nobody ran.
test: ## Run the PensieveKit test suite (make test FILTER=projectRoundTrips)
ifeq ($(strip $(FILTER)),)
test: .make/test
else
test:
	@swift test --filter $(FILTER)
endif

lint: .make/lint ## Run SwiftLint as CI runs it

generate: $(PBXPROJ) ## Regenerate Pensieve.xcodeproj from project.yml

build: $(APP_CLI) ## Build Pensieve.app (also builds and embeds the CLI)

cli: $(CLI) ## Build only the embedded pensieve CLI

uiprobe: $(UIPROBE) ## Build the accessibility probe for driving the running app

$(UIPROBE): $(UIPROBE_SOURCES)
	@mkdir -p $(dir $@)
	@swiftc -O $(UIPROBE_SOURCES) -o $@
	@echo "ok: $@"

uitest: .make/uitest ## Run the app UI test suite (launches a real window; not part of `all`)

smoke: .make/smoke ## Verify the built bundle's embedded CLI launches

# Deliberately outside `all`: this launches a real GUI window and holds focus for ~35s, which would
# make the most-run command hostile to work alongside.
#
# The app writes its own defaults (lastOpenedAt among them), and a test run must not shift the real
# Briefing baseline — so the domain is exported and restored around the suite. Best-effort: a crash
# mid-suite skips the restore, but this run's export is still on disk at the path it prints.
#
# The backup path is per-run (mktemp), and the restore happens only if this run's own export actually
# produced a file. A fixed path plus an unconditional restore is a trap: a failed export — silently
# swallowed by `|| true` — is followed by importing a STALE backup left behind by an earlier run,
# overwriting the live domain rather than leaving it untouched. That domain now carries the custom
# store root, so the failure mode is a moved store, not a shifted Briefing date.
.make/uitest: $(APP_CLI) $(UITEST_SOURCES) | .make
	@backup=$$(mktemp /tmp/pensieve-defaults-backup.XXXXXX); \
	if ! defaults export me.mazetti.pensieve "$$backup" 2>/dev/null; then rm -f "$$backup"; backup=""; fi; \
	xcodebuild $(XCODEBUILD_FLAGS) -scheme Pensieve -only-testing:PensieveUITests test; status=$$?; \
	if [ -n "$$backup" ]; then defaults import me.mazetti.pensieve "$$backup" 2>/dev/null || true; rm -f "$$backup"; fi; \
	exit $$status
	@touch $@

.make/test: $(TEST_INPUTS) | .make
	@swift test
	@touch $@

.make/lint: $(SWIFT_SOURCES) .swiftlint.yml | .make
	@swiftlint lint --strict
	@touch $@

# XcodeGen skips the write when the generated project would be identical, so the
# touch is what stops every later make from regenerating it again.
$(PBXPROJ): project.yml $(shell find Sources SyncAgent Tests/PensieveUITests -type d)
	@xcodegen generate
	@touch $@

# Touched for the same reason: an incremental build that changes only a resource
# leaves the binary alone, and without the touch that would never settle. Mtime
# is not part of a code signature, so this does not disturb the ad-hoc signing.
$(APP_CLI): $(BUILD_SOURCES) $(PBXPROJ)
	@xcodebuild $(XCODEBUILD_FLAGS) -scheme Pensieve build
	@touch $@

$(CLI): $(shell find Sources/pensieve Sources/PensieveKit ! -name '.*') $(PBXPROJ)
	@xcodebuild $(XCODEBUILD_FLAGS) -scheme PensieveCLI build
	@touch $@

# The app target has no unit tests, so proving the CLI embedded and launches is
# the only automated signal the bundle is intact. Same check CI runs.
.make/smoke: $(APP_CLI) | .make
	@$(APP_CLI) --help >/dev/null
	@echo "ok: $(APP_CLI) launches"
	@touch $@

# Order-only (the `|`): writing a record inside .make bumps the directory's own
# mtime, and as a normal prerequisite that would invalidate every other record.
.make:
	@mkdir -p $@

# Deliberately depends on the build rather than on all: reinstalling after a
# rebuild is a frequent chore, and making it run the whole suite first would get
# it avoided. Always copies — what sits in /Applications is not ours to cache.
install: $(APP_CLI) ## Replace /Applications/Pensieve.app with the built bundle
	@if pgrep -qx Pensieve; then \
		echo "Pensieve is running — quit it (⌘Q) before replacing its bundle."; \
		exit 1; \
	fi
	@rm -rf "$(INSTALLED_APP)"
	@ditto "$(APP)" "$(INSTALLED_APP)"
	@echo "installed: $(INSTALLED_APP)"
	@echo "note: launch it once so the sync agent re-registers its new cdhash."

# The opposite prerequisite choice from install, on purpose: install is the
# frequent chore, run is the deliberate "look at the real thing" gesture, and the
# step cache makes a no-change run free anyway.
#
# Launching from here rather than Spotlight is the point. Every worktree build
# registers another bundle under the same id, so Spotlight picks between them by
# rules of its own — which is how a month-old copy ends up on screen looking like
# a regression. This path names the bundle.
#
# install is invoked from the recipe rather than listed as a prerequisite because
# the quit has to happen first, and prerequisites have no order among themselves.
# The quit is graceful and guarded by pgrep — asking a *non*-running app to quit
# launches it first, which would leave a copy of the old bundle running.
run: all ## Build, install and launch /Applications/Pensieve.app
	@if pgrep -qx Pensieve; then \
		echo "quitting the running Pensieve…"; \
		osascript -e 'quit app id "me.mazetti.pensieve"' >/dev/null 2>&1 || true; \
		for _ in $$(seq 1 20); do pgrep -qx Pensieve || break; sleep 0.25; done; \
	fi
	@$(MAKE) --no-print-directory install
	@open "$(INSTALLED_APP)"

# Build products and step records only. Never touches $(INSTALLED_APP) — that is
# the bundle SMAppService has registered, and `install` is the only path writing it.
clean: ## Remove .build, .build-xcode and the cached step records
	@rm -rf .build .build-xcode .make
