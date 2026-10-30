#if os(visionOS)
    import XCTest

    // Scratch visionOS UI check — copy into "Jelly SharkUITests/" as `UICheck<Name>.swift`,
    // rename the class, write the steps in `testCheck`. Never commit the copy.
    // Workflow: .claude/skills/sim-ui-check/SKILL.md; visionOS rules: visionos.md beside it.

    @MainActor
    final class UICheckTemplateVision: XCTestCase {
        /// The server from server.sh: run.sh's UI_CHECK_SERVER when set, so the
        /// same check runs against `server.sh up <version> <port>` unedited.
        private let server = ProcessInfo.processInfo.environment["UI_CHECK_SERVER"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:8096"

        /// A cheap proxy to the same app, so there is nothing to store.
        private var app: XCUIApplication {
            XCUIApplication()
        }

        func testCheck() {
            writeVerdictOnTeardown()
            continueAfterFailure = false
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App never reached the foreground")
            shot("01-launch")

            // Example: sign in to the local server from server.sh. To check a
            // rejected sign-in instead, pass `expectError: true`; it returns the
            // form's error text.
            signIn(url: server, username: "test", password: "test")
            shot("02-signed-in")

            // ... the steps for this check, each followed by a wait and a shot.
            // Example: a seeded title on Home, its details page, then a search.
            // Cards read "Title, Year". Home's hero has a Play button too, so
            // prove the details page by its Back button, not by Play.
            //
            // open(tab: "Home")
            // let card = labelled("Harbor Lights, 2019")
            // XCTAssertTrue(card.waitForExistence(timeout: 20), dump("Not on Home"))
            // shot("03-home")
            // card.tap()
            // XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 20), dump("No details page"))
            // XCTAssertTrue(labelled("A UI-check fixture film about Harbor Lights.").exists, dump("Wrong details page"))
            // shot("04-details")
            // back()
            //
            // While Search's suggestion dropdown is open, only its suggestions
            // ("Static Season", no year) can be queried; the cards behind it can't.
            // The libraries are "Movies" and "Shows". Episodes read
            // "0m, S1E1, Episode 1, Fixture episode 1.".
            //
            // open(tab: "Search")
            // search("Static")
            // The idle screen already lists every title, so the proof is that
            // the others go away; then that the match is there.
            // XCTAssertTrue(waitUntil(timeout: 10) { !labelled("The Long Field").exists }, dump("Search did not narrow"))
            // XCTAssertTrue(labelled("Static Season").waitForExistence(timeout: 20), dump("No search result"))
            // shot("05-search")
            // To prove something went away, such as the other titles once the
            // search narrows, wait for its absence; it can take a moment:
            // XCTAssertTrue(waitUntil(timeout: 5) { !labelled("The Long Field").exists }, dump("Still listed"))
            //
            // A scenario switch from outside: `TEST_RUNNER_MODE=revoked run.sh …`
            // reaches the check as MODE.
            // let mode = ProcessInfo.processInfo.environment["MODE"] ?? "default"

            // Leave the simulator signed out for the next check. Keep this the
            // last line: a bare `return` on the line above it would still run
            // it, because Swift reads `return` and the next line as one statement.
            signOut()
        }

        // MARK: - Flows

        /// Settings → Server → fill the form → Connect. Signs out first if the
        /// simulator kept a session from an earlier run. With `expectError`, the
        /// sign-in must fail, and the form's error text is returned.
        @discardableResult
        private func signIn(url: String, username: String, password: String, expectError: Bool = false) -> String? {
            let form = app.textFields.firstMatch
            let disconnect = app.buttons["Disconnect"].firstMatch
            if !form.exists, !disconnect.exists {
                openServerScreen()
            }
            // Wait for either screen: waiting on the form alone costs its whole
            // timeout whenever the simulator starts signed in.
            XCTAssertNotNil(firstToExist([form, disconnect], timeout: 20), dump("No server screen"))
            if disconnect.exists {
                disconnect.tap()
                // Sign-out awaits the server's logout call, so a server that
                // accepts connections but never answers holds this screen.
                XCTAssertTrue(form.waitForExistence(timeout: 20),
                              dump("Sign-out did not return to the form — is the saved server answering?"))
            }

            let fields = app.textFields.allElementsBoundByIndex
            XCTAssertGreaterThanOrEqual(fields.count, 2, dump("Expected URL and username fields"))
            type(url, into: fields[0])
            type(username, into: fields[1])
            type(password, into: app.secureTextFields.firstMatch, secure: true)

            // The form shows a refused or rejected sign-in within a second or so;
            // fail on it then rather than waiting out the whole Disconnect wait.
            let error = app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS[c] 'error' OR label CONTAINS[c] 'invalid' OR label CONTAINS[c] 'could not' OR label CONTAINS[c] 'expired' OR label CONTAINS[c] 'not supported'",
            )).firstMatch
            // A message left by a failed restore is still up when Connect is
            // tapped; wait for Connect to clear it, or it reads as this sign-in failing.
            let stale = error.exists ? error.label : nil
            app.buttons["Connect"].firstMatch.tap()
            if let stale {
                _ = waitUntil(timeout: 5) { !error.exists || error.label != stale }
            }
            // Keep the outcome: re-reading `disconnect.exists` afterwards can
            // land while the Save Password sheet has emptied the tree.
            let outcome = firstToExist([disconnect, error], timeout: 30)
            XCTAssertNotNil(outcome, dump("Still signing in after 30s — is the server answering?"))
            let message = outcome == error ? error.label : nil
            if expectError {
                XCTAssertNotNil(message, dump("Sign-in was expected to fail, but it succeeded"))
            } else if let message {
                XCTFail(dump("Sign-in failed: \(message)"))
            }
            // The system Save Password sheet arrives a moment after either
            // outcome, and hides the tab bar and the form until it goes.
            if app.alerts["Save Password?"].waitForExistence(timeout: 3) {
                dismissSavePassword()
            }
            return message
        }

        /// Taps "Not Now" on the Save Password sheet and waits for it to go:
        /// it stays in the tree while it animates away, and a second tap then
        /// fails with "No matches found".
        private func dismissSavePassword() {
            let notNow = app.buttons["Not Now"].firstMatch
            notNow.tap()
            _ = notNow.waitForNonExistence(timeout: 3)
        }

        /// Settings → Server → Disconnect. Returns at once when the sign-in form
        /// is already showing, as after `signIn(expectError: true)`.
        private func signOut() {
            let disconnect = app.buttons["Disconnect"].firstMatch
            if app.textFields.firstMatch.exists, !disconnect.exists {
                return
            }
            if !disconnect.exists {
                openServerScreen()
            }
            XCTAssertTrue(disconnect.waitForExistence(timeout: 20), dump("No Disconnect button"))
            disconnect.tap()
            XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20), dump("Sign-out did not return to the form"))
        }

        /// Quits and relaunches the app. The Keychain survives, so a signed-in
        /// app restores its saved session; navigation doesn't, so it starts at
        /// the root.
        private func relaunch() {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App never came back after relaunch")
        }

        // MARK: - Server

        /// Revokes the app's session on the server: deletes every device whose
        /// AppName is "Jelly Shark". After a relaunch the app's token gets 401.
        /// Returns how many devices it deleted.
        @discardableResult
        private func revokeAppDevices() -> Int {
            let body = api("GET", "/Devices").body
            let items = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["Items"] as? [[String: Any]] ?? []
            let ids = items.filter { $0["AppName"] as? String == "Jelly Shark" }.compactMap { $0["Id"] as? String }
            for id in ids {
                api("DELETE", "/Devices?id=\(id)")
            }
            return ids.count
        }

        /// One call to the server as its admin (test/test, on a device of its
        /// own, so the app's session is untouched), for server-side steps such
        /// as revoking the app's token. Returns the status code and the body.
        @discardableResult
        private func api(_ method: String, _ path: String) -> (status: Int, body: Data) {
            let header = #"MediaBrowser Client="ui-check", Device="ui-check", DeviceId="ui-check-runner", Version="1""#
            func send(_ request: URLRequest) -> (Int, Data) {
                final class Box: @unchecked Sendable {
                    var result = (0, Data())
                }
                let box = Box()
                let done = expectation(description: "\(request.httpMethod ?? "") \(request.url?.path() ?? "")")
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    box.result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
                    done.fulfill()
                }.resume()
                wait(for: [done], timeout: 10)
                return box.result
            }
            var signIn = URLRequest(url: URL(string: server + "/Users/AuthenticateByName")!)
            signIn.httpMethod = "POST"
            signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
            signIn.setValue(header, forHTTPHeaderField: "Authorization")
            signIn.httpBody = Data(#"{"Username":"test","Pw":"test"}"#.utf8)
            let token = (try? JSONSerialization.jsonObject(with: send(signIn).1) as? [String: Any])?["AccessToken"] as? String
            XCTAssertNotNil(token, "Admin sign-in failed on \(server)")

            var request = URLRequest(url: URL(string: server + path)!)
            request.httpMethod = method
            request.setValue(header + #", Token="\#(token ?? "")""#, forHTTPHeaderField: "Authorization")
            return send(request)
        }

        // MARK: - Navigation

        /// Settings → Server, from wherever the app is, unless the sign-in
        /// form or Disconnect is already showing.
        private func openServerScreen() {
            if app.textFields.firstMatch.exists || app.buttons["Disconnect"].firstMatch.exists {
                return
            }
            open(tab: "Settings")
            open(row: "Server")
        }

        /// Taps a tab in the tab bar ornament. The ornament is a window of its
        /// own, and its tabs are Buttons labelled with the tab's name.
        private func open(tab label: String) {
            let tab = app.buttons[label].firstMatch
            // While Search's suggestion dropdown is open, it is all the tree
            // holds: the tab bar and the search field drop out, though both
            // stay on screen. Return and a tap outside leave it open; tapping
            // a suggestion closes it.
            if firstToExist([tab], timeout: 2) == nil, let query = lastSearch {
                let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", query)).firstMatch
                if suggestion.exists {
                    suggestion.tap()
                }
            }
            XCTAssertNotNil(firstToExist([tab], timeout: 20), dump("No tab '\(label)'"))
            tab.tap()
        }

        /// Taps the navigation bar's Back button.
        private func back() {
            let button = app.buttons["BackButton"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), dump("No Back button"))
            button.tap()
        }

        /// Taps a list row: the cell whose label starts with `label`, or failing
        /// that a button that does. Not any element: a pushed screen's own title
        /// can start with the same word. Re-selecting a tab doesn't pop its
        /// stack, so from a pushed screen (Server after `signIn`, a picker) it
        /// goes back until the row shows.
        private func open(row label: String) {
            let starts = NSPredicate(format: "label BEGINSWITH %@", label)
            let cell = app.cells.containing(starts).firstMatch
            let button = app.buttons.matching(starts).firstMatch
            for _ in 0 ..< 4 where firstToExist([cell, button], timeout: 2) == nil && app.buttons["BackButton"].exists {
                back()
            }
            let row = firstToExist([cell, button], timeout: 20)
            XCTAssertNotNil(row, dump("No row '\(label)'"))
            row?.tap()
        }

        /// Taps a text field, clears it, types `text` and checks the field now
        /// holds exactly `text` (secure fields can't be read). There is no
        /// keyboard to dismiss.
        private func type(_ text: String, into field: XCUIElement, secure: Bool = false) {
            // firstToExist, not waitForExistence: it dismisses a late Save
            // Password sheet that would otherwise hide the form.
            XCTAssertNotNil(firstToExist([field], timeout: 10), dump("No field to type into"))
            // An empty field reports its placeholder as its value. The server
            // form prefills the URL field with that same text, so only an empty
            // secure field is known to be empty. Deleting a secure field's
            // placeholder length lost the password typed after it.
            let value = field.value as? String
            let existing = secure && value == field.placeholderValue ? 0 : value?.count ?? 0
            field.tap()
            let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing == 0 ? 0 : existing + 5)
            field.typeText(clear + text)
            // The value lags the typing: read at once, it can still be the placeholder.
            if !secure {
                _ = waitUntil(timeout: 3) { field.value as? String == text }
                XCTAssertEqual(field.value as? String, text, dump("Field holds the wrong text"))
            }
        }

        /// The last text given to `search(_:)`, so `open(tab:)` can close its
        /// suggestion dropdown.
        private var lastSearch: String?

        /// Types into the Search tab's system search field. Its suggestion
        /// dropdown then hides the tab bar from queries; `open(tab:)` closes it.
        private func search(_ text: String) {
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), dump("No search field"))
            field.tap()
            field.typeText(text)
            lastSearch = text
        }

        /// The first of `elements` to exist within `timeout`, or nil.
        private func firstToExist(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
            var hit: XCUIElement?
            _ = waitUntil(timeout: timeout) {
                hit = elements.first(where: \.exists)
                return hit != nil
            }
            return hit
        }

        /// Polls `condition` every quarter second until it holds or `timeout`
        /// passes. Dismisses a late system Save Password sheet on the way:
        /// it hides the tab bar until it goes.
        private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let notNow = app.buttons["Not Now"].firstMatch
            let deadline = Date.now.addingTimeInterval(timeout)
            repeat {
                if notNow.exists {
                    dismissSavePassword()
                }
                if condition() {
                    return true
                }
                RunLoop.current.run(until: .now.addingTimeInterval(0.25))
            } while Date.now < deadline
            return condition()
        }

        // MARK: - Primitives

        /// Any element whose label contains `text`.
        private func labelled(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

        /// Asks run.sh for a simulator screenshot named `name`, and waits for it.
        /// XCUITest's own screenshot crops the window to 1280×720 and
        /// XCUIScreen's is 1×1 on visionOS, so only `simctl io` shows the whole
        /// window. Without run.sh, falls back to the cropped one as an attachment.
        private func shot(_ name: String) {
            guard let out = Self.outputFolder else {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            let requests = out.appending(path: "requests")
            let request = requests.appending(path: name)
            try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: request.path(), contents: nil)
            let answered = waitUntil(timeout: 10) { !FileManager.default.fileExists(atPath: request.path()) }
            XCTAssertTrue(answered, "run.sh never answered the screenshot request '\(name)': it is blocked, or the simulator is wedged")
            let failed = try? String(contentsOf: out.appending(path: "\(name).failed"), encoding: .utf8)
            XCTAssertTrue(!answered || FileManager.default.fileExists(atPath: out.appending(path: "\(name).png").path()),
                          "No screenshot '\(name)': \(failed ?? "run.sh answered without one")")
        }

        /// Prints the element tree to the log and saves it as `<name>.txt`
        /// beside the screenshots, then carries on: for learning a screen's
        /// labels, several screens in one run.
        private func explore(_ name: String) {
            let tree = app.debugDescription
            print("explore \(name):\n\(tree)")
            if let out = Self.outputFolder {
                try? tree.write(to: out.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
            }
        }

        /// Writes the verdict run.sh waits for. Registered first thing in the
        /// test, so it runs even when an assertion stops the test early. A
        /// failure first gets a `zz-failure` screenshot: once the verdict is
        /// written, run.sh stops and the app closes.
        private func writeVerdictOnTeardown() {
            addTeardownBlock { @MainActor [weak self] in
                guard let out = Self.outputFolder, let run = self?.testRun else { return }
                // Count failures: hasSucceeded is still false while the run is open.
                let verdict = run.failureCount + run.unexpectedExceptionCount == 0 ? "PASS" : "FAIL"
                if verdict == "FAIL" {
                    let request = out.appending(path: "requests/zz-failure")
                    try? FileManager.default.createDirectory(at: request.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: request.path(), contents: nil)
                    let deadline = Date.now.addingTimeInterval(10)
                    while FileManager.default.fileExists(atPath: request.path()), Date.now < deadline {
                        RunLoop.current.run(until: .now.addingTimeInterval(0.25))
                    }
                }
                try? verdict.write(to: out.appending(path: "verdict.txt"), atomically: true, encoding: .utf8)
            }
        }

        /// run.sh passes TEST_RUNNER_UI_CHECK_OUT; xcodebuild strips the prefix.
        private static var outputFolder: URL? {
            ProcessInfo.processInfo.environment["UI_CHECK_OUT"].map { URL(filePath: $0) }
        }

        /// Failure text: the message, then the headings on screen (enough to act
        /// on at a glance), then the full element tree.
        private func dump(_ message: String) -> String {
            let headings = app.staticTexts.allElementsBoundByIndex.prefix(40)
                .filter { $0.frame.height >= 30 && !$0.label.isEmpty }
                .map(\.label).prefix(4).joined(separator: ", ")
            return """
            \(message)
            Screen: \(headings.isEmpty ? "no headings" : headings) · App: \(app.state == .runningForeground ? "foreground" : "NOT foreground")
            \(app.debugDescription)
            """
        }
    }
#endif
