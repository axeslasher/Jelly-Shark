import XCTest

// Scratch UI check — copy into "Jelly SharkUITests/" as `UICheck<Name>.swift`,
// rename the class, write the steps in `testCheck`. Never commit the copy.
// Workflow and gotchas: .claude/skills/tvos-ui-check/SKILL.md

@MainActor
final class UICheckTemplate: XCTestCase {
    /// Not a stored property: an Apple forums report (thread 818688) ties a
    /// stored XCUIApplication plus continueAfterFailure = false to xcodebuild
    /// hanging after a failure. XCUIApplication() is a cheap proxy to the same app.
    private var app: XCUIApplication {
        XCUIApplication()
    }

    private var remote: XCUIRemote {
        XCUIRemote.shared
    }

    func testCheck() {
        writeVerdictOnTeardown()
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App never reached the foreground")
        shot("01-launch")

        // Example: sign in to the local server from server.sh.
        signIn(url: "http://localhost:8096", username: "test", password: "test")
        XCTAssertTrue(app.buttons["Disconnect"].firstMatch.waitForExistence(timeout: 30), dump("Sign-in failed"))
        shot("02-signed-in")

        // ... the steps for this check, each followed by a wait and a shot.

        // Leave the simulator signed out for the next check.
        signOut()
    }

    // MARK: - Flows

    /// Settings → Server → fill the form → Connect. Signs out first if the
    /// simulator kept a session from an earlier run.
    private func signIn(url: String, username: String, password: String) {
        open(tab: "Settings")
        open(row: "Server")
        let form = app.textFields.firstMatch
        let disconnect = app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 20) || disconnect.exists, dump("No server screen"))
        if disconnect.exists {
            focus(disconnect, trying: [.down, .up])
            remote.press(.select)
            XCTAssertTrue(form.waitForExistence(timeout: 20), dump("Sign-out did not return to the form"))
        }

        let fields = app.textFields.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(fields.count, 2, dump("Expected URL and username fields"))
        type(url, into: fields[0])
        type(username, into: fields[1])
        type(password, into: app.secureTextFields.firstMatch)

        focus(app.buttons["Connect"].firstMatch, trying: [.down, .up])
        remote.press(.select)
    }

    /// Settings → Server → Disconnect. The app must be signed in. Re-selecting
    /// the current tab does not pop its stack, so when the Server screen is
    /// already showing, use it as is.
    private func signOut() {
        let disconnect = app.buttons["Disconnect"].firstMatch
        if !disconnect.exists {
            open(tab: "Settings")
            open(row: "Server")
        }
        XCTAssertTrue(disconnect.waitForExistence(timeout: 20), dump("No Disconnect button"))
        focus(disconnect, trying: [.down, .up])
        remote.press(.select)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20), dump("Sign-out did not return to the form"))
    }

    // MARK: - Navigation

    /// Focuses a sidebar tab and selects it. From a pushed screen it backs out
    /// with Menu first — only while the tab is missing, because Menu on the
    /// top level leaves the app.
    private func open(tab label: String) {
        let tab = cell(label)
        for _ in 0 ..< 4 where !tab.exists {
            remote.press(.menu)
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 20), dump("No sidebar tab '\(label)'"))
        // Left on an open sidebar collapses it to a pill, after which its
        // cells have no frame and Up/Down never reach them. So: Up/Down while
        // it is open; one Left only to bring a collapsed sidebar back.
        if tab.frame.isEmpty {
            remote.press(.left)
        }
        focus(tab, trying: [.down, .up])
        remote.press(.select)
    }

    /// Focuses a list row (a cell whose label starts with `label`) and selects it.
    private func open(row label: String) {
        let row = cell(label)
        XCTAssertTrue(row.waitForExistence(timeout: 20), dump("No row '\(label)'"))
        focus(row, trying: [.right, .down, .up])
        remote.press(.select)
    }

    /// Selects a text field, clears it, types `text` and closes the keyboard.
    private func type(_ text: String, into field: XCUIElement) {
        focus(field, trying: [.up, .down])
        remote.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), dump("Keyboard never appeared"))
        let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60)
        app.typeText(clear + text)
        remote.press(.menu)
        _ = field.waitForExistence(timeout: 5)
    }

    // MARK: - Primitives

    /// Sidebar tabs and list rows take focus as the *cell*, not the button,
    /// image or text inside it — query the cell or `hasFocus` never turns true.
    private func cell(_ label: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    /// Presses each direction in turn, up to `limit` times, until `element`
    /// has focus. Fails with a screenshot and the element tree if it never does.
    private func focus(_ element: XCUIElement, trying directions: [XCUIRemote.Button], limit: Int = 12) {
        for direction in directions {
            for _ in 0 ..< limit {
                if element.hasFocus {
                    return
                }
                remote.press(direction)
            }
        }
        if !element.hasFocus {
            shot("focus-failed")
            XCTFail(dump("Could not focus \(element)"))
        }
    }

    /// Saves a named screenshot straight to run.sh's output folder, so it
    /// never depends on xcodebuild finishing its result bundle.
    private func shot(_ name: String) {
        let screenshot = app.screenshot()
        if let out = Self.outputFolder {
            try? screenshot.pngRepresentation.write(to: out.appending(path: "\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Writes the verdict run.sh waits for. Registered first thing in the
    /// test, so it runs even when an assertion stops the test early.
    private func writeVerdictOnTeardown() {
        addTeardownBlock { @MainActor [weak self] in
            guard let out = Self.outputFolder, let run = self?.testRun else { return }
            // Count failures: hasSucceeded is still false while the run is open.
            let verdict = run.failureCount + run.unexpectedExceptionCount == 0 ? "PASS" : "FAIL"
            try? verdict.write(to: out.appending(path: "verdict.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// run.sh passes TEST_RUNNER_UI_CHECK_OUT; xcodebuild strips the prefix.
    private static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["UI_CHECK_OUT"].map { URL(filePath: $0) }
    }

    private func dump(_ message: String) -> String {
        "\(message)\n\(app.debugDescription)"
    }
}
