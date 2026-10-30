#if os(tvOS)
    import XCTest

    // Scratch tvOS UI check — copy into "Jelly SharkUITests/" as `UICheck<Name>.swift`,
    // rename the class, write the steps in `testCheck`. Never commit the copy.
    // Workflow: .claude/skills/sim-ui-check/SKILL.md; tvOS rules: tvos.md beside it.
    // The #if keeps the visionOS build of the test target compiling: XCUIRemote is tvOS only.

    @MainActor
    final class UICheckTemplateTV: XCTestCase {
        /// The server from server.sh: run.sh's UI_CHECK_SERVER when set, so the
        /// same check runs against `server.sh up <version> <port>` unedited.
        private let server = ProcessInfo.processInfo.environment["UI_CHECK_SERVER"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:8096"

        /// A cheap proxy to the same app, so there is nothing to store.
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
            signIn(url: server, username: "test", password: "test")
            XCTAssertTrue(app.buttons["Disconnect"].firstMatch.waitForExistence(timeout: 30), dump("Sign-in failed"))
            shot("02-signed-in")

            // ... the steps for this check, each followed by a wait and a shot.
            // Example: a seeded title on Home, then a search that finds another.
            // Cards are labelled "Title, Year", and Search's idle screen already
            // lists every title as a suggestion, so match the card's year too.
            //
            // open(tab: "Home")
            // XCTAssertTrue(labelled("Harbor Lights, 2019").waitForExistence(timeout: 20), dump("Not on Home"))
            // shot("03-home")
            // open(tab: "Search")
            // XCTAssertFalse(labelled("Static Season, 2023").exists, dump("Result showing before the search"))
            // search("Static")
            // XCTAssertTrue(labelled("Static Season, 2023").waitForExistence(timeout: 20), dump("No search result"))
            // shot("04-search")

            // Leave the simulator signed out for the next check.
            signOut()
        }

        // MARK: - Flows

        /// Settings → Server → fill the form → Connect. Signs out first if the
        /// simulator kept a session from an earlier run. When the Server screen
        /// is already showing, it is used as is: re-selecting the tab doesn't
        /// pop back to the row.
        private func signIn(url: String, username: String, password: String) {
            let form = app.textFields.firstMatch
            let disconnect = app.buttons["Disconnect"].firstMatch
            if !form.exists, !disconnect.exists {
                open(tab: "Settings")
                open(row: "Server")
            }
            // Wait for either screen: waiting on the form alone costs its whole
            // timeout whenever the simulator starts signed in.
            XCTAssertNotNil(firstToExist([form, disconnect], timeout: 20), dump("No server screen"))
            if disconnect.exists {
                focus(disconnect, trying: [.down, .up])
                remote.press(.select)
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
            // fail on it then rather than waiting out the caller's Disconnect wait.
            let error = app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS[c] 'error' OR label CONTAINS[c] 'invalid' OR label CONTAINS[c] 'could not' OR label CONTAINS[c] 'expired' OR label CONTAINS[c] 'not supported'",
            )).firstMatch
            // A message left by a failed restore ("Your session has expired")
            // is still up when Connect is pressed; wait for Connect to clear it,
            // or it reads as this sign-in failing.
            let stale = error.exists ? error.label : nil
            focus(app.buttons["Connect"].firstMatch, trying: [.down, .up])
            remote.press(.select)
            if let stale {
                _ = waitUntil(timeout: 5) { !error.exists || error.label != stale }
            }
            if firstToExist([disconnect, error], timeout: 30) == error {
                XCTFail(dump("Sign-in failed: \(error.label)"))
            }
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

        /// Quits and relaunches the app. The Keychain survives, so a signed-in
        /// app restores its saved session; navigation doesn't, so it starts at
        /// the root.
        private func relaunch() {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App never came back after relaunch")
        }

        // MARK: - Server

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

        /// Focuses a sidebar tab and selects it. From a pushed screen it backs out
        /// with Menu first — only while the tab is missing, because Menu on the
        /// top level leaves the app.
        private func open(tab label: String) {
            let tab = cell(label)
            for _ in 0 ..< 4 where !tab.exists {
                pressMenu()
            }
            XCTAssertTrue(tab.waitForExistence(timeout: 20), dump("No sidebar tab '\(label)'"))
            // Left on an open sidebar collapses it to a pill, after which its
            // cells have no frame and Up/Down never reach them. So: Up/Down while
            // it is open; Left only to bring a collapsed sidebar back. Left moves
            // through the content first (Home's hero has three buttons), so it can
            // take several presses. A screen with nothing focusable, such as a
            // loading skeleton, never lets it reopen.
            var presses = 0
            while tab.frame.isEmpty, presses < 6 {
                remote.press(.left)
                presses += 1
                _ = waitUntil(timeout: 1) { !tab.frame.isEmpty }
            }
            if tab.frame.isEmpty {
                shot("sidebar-stuck")
                XCTFail(dump("Sidebar did not reopen for '\(label)' after \(presses) Left presses: is the screen still loading?"))
                return
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

        /// Selects a text field, clears it, types `text`, closes the keyboard and
        /// checks the field now holds exactly `text` (secure fields can't be read).
        private func type(_ text: String, into field: XCUIElement, secure: Bool = false) {
            let existing = (field.value as? String)?.count ?? 0
            focus(field, trying: [.up, .down])
            remote.press(.select)
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 10), dump("Keyboard never appeared"))
            // Delete at least what is there; a fixed count leaves the tail of a long value.
            let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(60, existing + 10))
            app.typeText(clear + text)
            // Menu with no keyboard up pops the screen, or leaves the app.
            if keyboard.exists {
                remote.press(.menu)
            }
            XCTAssertTrue(field.waitForExistence(timeout: 5), dump("Field gone after typing"))
            if !secure {
                XCTAssertEqual(field.value as? String, text, dump("Field holds the wrong text"))
            }
        }

        /// Selects an option row in a picker list (Theme, Streaming Quality). These
        /// rows are a Button inside a List, and the *Button* takes focus, not the
        /// cell, so `open(row:)` can't reach them. Labels read "Name, description".
        private func select(option label: String) {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label + ",")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), dump("No option '\(label)'"))
            focus(row, trying: [.down, .up])
            remote.press(.select)
        }

        /// Focuses a card in Home's shelves by walking each shelf right, then down
        /// to the next. Coming back left, a shelf's leading edge opens the sidebar,
        /// so the walk stops as soon as a sidebar cell takes focus.
        private func focus(card: XCUIElement, rows: Int = 5, perRow: Int = 5) {
            let sidebarFocused = app.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            for _ in 0 ..< rows {
                for _ in 0 ..< perRow {
                    if card.exists, card.hasFocus {
                        return
                    }
                    remote.press(.right)
                }
                if card.exists, card.hasFocus {
                    return
                }
                remote.press(.down)
                for _ in 0 ..< perRow {
                    if card.exists, card.hasFocus {
                        return
                    }
                    remote.press(.left)
                    if sidebarFocused.exists {
                        remote.press(.right)
                        break
                    }
                }
            }
            shot("focus-failed")
            XCTFail(dump("Could not focus \(card)"))
        }

        /// Types into the Search tab's field. It is the system `.searchable` field,
        /// and its keyboard is already up when the tab opens, so no select, no
        /// clearing and no Menu, unlike `type(_:into:)`.
        private func search(_ text: String) {
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), dump("No search field"))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), dump("Search keyboard not up"))
            app.typeText(text)
        }

        /// Menu, then fail at once if it took the app off screen: queries still
        /// match a backgrounded app's last tree, so later steps would go on
        /// pressing buttons on the tvOS home screen.
        /// The state flips a moment after the press, hence the short wait.
        private func pressMenu() {
            remote.press(.menu)
            XCTAssertFalse(app.wait(for: .runningBackground, timeout: 1.5),
                           "Menu left the app: the screen had no back stack")
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

        /// Polls `condition` every quarter second until it holds or `timeout` passes.
        private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date.now.addingTimeInterval(timeout)
            repeat {
                if condition() {
                    return true
                }
                RunLoop.current.run(until: .now.addingTimeInterval(0.25))
            } while Date.now < deadline
            return condition()
        }

        // MARK: - Primitives

        /// Any element whose label contains `text`. Content cards are Buttons
        /// labelled "Title, Year", not cells.
        private func labelled(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

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
                    // `exists` first: an element that briefly leaves the tree mid-scroll
                    // makes `hasFocus` throw instead of returning false.
                    if element.exists, element.hasFocus {
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

        /// Failure text: the message, then what had focus and which headings were
        /// on screen (enough to act on at a glance), then the full element tree.
        private func dump(_ message: String) -> String {
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let focusedText = focused.exists ? "'\(focused.label)'" : "nothing"
            let headings = app.staticTexts.allElementsBoundByIndex.prefix(40)
                .filter { $0.frame.height >= 40 && !$0.label.isEmpty }
                .map(\.label).prefix(4).joined(separator: ", ")
            return """
            \(message)
            Focused: \(focusedText) · Screen: \(headings.isEmpty ? "no headings" : headings) · App: \(app.state == .runningForeground ? "foreground" : "NOT foreground")
            \(app.debugDescription)
            """
        }
    }
#endif
