//
//  Jelly_SharkUITests.swift
//  Jelly SharkUITests
//
//  Created by Justin Lascelle on 1/6/26.
//

import XCTest

final class Jelly_SharkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Smoke test: the app launches and its main tab navigation renders.
    ///
    /// On a fresh install (no saved session) `RootView` still shows the Home /
    /// Search / Settings tabs, so the Settings tab — always present regardless
    /// of auth or library state — is a stable "the UI actually came up" signal
    /// that doesn't depend on a reachable server.
    @MainActor
    func testLaunchRendersMainNavigation() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App did not reach the foreground after launch"
        )

        let settingsTab = app.descendants(matching: .any)["Settings"]
        XCTAssertTrue(
            settingsTab.waitForExistence(timeout: 30),
            "Main tab navigation did not render — 'Settings' tab never appeared.\n\(app.debugDescription)"
        )
    }
}
