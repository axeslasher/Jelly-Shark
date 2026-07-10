# Jelly Shark — build & test entry points.
#
# The app ships to tvOS + visionOS only. Tests run in two venues and `make test`
# runs BOTH so no suite is silently skipped:
#   - simulator (via the "Jelly Shark" scheme): the app tests plus DesignSystemTests
#     and FeaturesTests. Those packages use tvOS/visionOS-only SwiftUI APIs and no
#     longer compile for the Mac host, so they run on the simulator.
#   - host (`swift test`): JellyfinKit. It is pure logic, and its Keychain/Session
#     tests need a real keychain, which a host-less simulator test bundle lacks.

SCHEME   = Jelly Shark
SIM_DEST = platform=tvOS Simulator,name=Apple TV

.PHONY: test test-sim test-host build build-visionos clean

# Full suite across both venues.
test: test-sim test-host

# App + DesignSystemTests + FeaturesTests on the tvOS simulator.
test-sim:
	xcodebuild test -scheme "$(SCHEME)" -destination "$(SIM_DEST)"

# JellyfinKit on the Mac host.
test-host:
	cd Packages/JellyfinKit && swift test

# Build the app for the two shipping platforms.
build:
	xcodebuild -scheme "$(SCHEME)" -destination "$(SIM_DEST)" build

build-visionos:
	xcodebuild -scheme "$(SCHEME)" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build

clean:
	xcodebuild clean -scheme "$(SCHEME)"
