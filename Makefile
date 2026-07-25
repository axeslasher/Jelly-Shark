# Jelly Shark — build & test entry points.
#
# The app ships to tvOS + visionOS only. Tests run in two venues and `make test`
# runs BOTH so no suite is silently skipped:
#   - simulator (via the "Jelly Shark" scheme): the app tests plus DesignSystemTests
#     and FeaturesTests. Those packages use tvOS/visionOS-only SwiftUI APIs and no
#     longer compile for the Mac host, so they run on the simulator.
#   - host (`swift test`): JellyfinKit. It is pure logic, and its Keychain/Session
#     tests need a real keychain, which a host-less simulator test bundle lacks.
#
# Verification tiers — pick the cheapest one that can fail on your change.
# Timings below are warm (populated DerivedData), measured 2026-07-25 on an
# M-series Mac. Cold, anything in the simulator venue costs minutes rather than
# seconds, because it links the whole app and boots a tvOS runtime; that cold
# cost is what makes the tiering worth honouring mid-iteration.
#   1. `make test-host`  (~5s warm)  — JellyfinKit only, no simulator. The
#      inner-loop tier: run it after every edit to API/session/model logic.
#   2. `make test-only ONLY=<target>`  (~23s warm) — one simulator suite, e.g.
#      `make test-only ONLY=DesignSystemTests`. Run before committing a change
#      that touches DesignSystem or Features.
#   3. `make test`  (~43s warm) — both venues, everything. This is CI's job on
#      every PR (.github/workflows/tests.yml); locally it is a pre-merge check,
#      not an iteration step.

SCHEME   = Jelly Shark
SIM_DEST = platform=tvOS Simulator,name=Apple TV

# Formatting is pinned to an exact SwiftFormat version so local runs, the
# pre-commit hook, and CI all agree on the output. Bump here and in
# .github/workflows/swiftformat.yml together.
SWIFTFORMAT_VERSION = 0.62.1

.PHONY: test test-sim test-host test-only build build-visionos clean \
	format lint check-swiftformat install-hooks

# Full suite across both venues.
test: test-sim test-host

# App + DesignSystemTests + FeaturesTests on the tvOS simulator.
test-sim:
	xcodebuild test -scheme "$(SCHEME)" -destination "$(SIM_DEST)"

# JellyfinKit on the Mac host.
test-host:
	cd Packages/JellyfinKit && swift test

# One simulator suite, e.g. `make test-only ONLY=DesignSystemTests`. Targets are
# quoted because the app suite's name contains a space ("Jelly SharkTests").
test-only:
	@[ -n "$(ONLY)" ] || \
		{ echo "usage: make test-only ONLY=<test target>   (Jelly SharkTests | DesignSystemTests | FeaturesTests)"; exit 1; }
	xcodebuild test -scheme "$(SCHEME)" -destination "$(SIM_DEST)" -only-testing:"$(ONLY)"

# Build the app for the two shipping platforms.
build:
	xcodebuild -scheme "$(SCHEME)" -destination "$(SIM_DEST)" build

build-visionos:
	xcodebuild -scheme "$(SCHEME)" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build

clean:
	xcodebuild clean -scheme "$(SCHEME)"

# Format all Swift sources in place (config in .swiftformat).
format: check-swiftformat
	swiftformat .

# Check formatting without modifying files — what CI and the pre-commit hook run.
lint: check-swiftformat
	swiftformat --lint .

# Fail fast if swiftformat is missing or not the pinned version.
check-swiftformat:
	@command -v swiftformat >/dev/null 2>&1 || \
		{ echo "swiftformat not installed — run: brew install swiftformat"; exit 1; }
	@[ "$$(swiftformat --version)" = "$(SWIFTFORMAT_VERSION)" ] || \
		{ echo "swiftformat $$(swiftformat --version) installed, but $(SWIFTFORMAT_VERSION) is required"; exit 1; }

# Point git at the repo's versioned hooks (one-time, opt-in).
install-hooks:
	git config core.hooksPath .githooks
	@echo "Pre-commit format check enabled (core.hooksPath -> .githooks)."
