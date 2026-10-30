---
name: tvos-ui-check
description: Verify a small tvOS UI change on the Apple TV simulator yourself, with screenshots, instead of asking for device time. Use for flows, on-screen text, and whether something appears after a change: sign-in, navigation, a row or label showing up, an error message. Not for appearance or how focus feels; those still go to the device.
---

# tvOS UI check

Write a throwaway XCUITest that drives the app with the simulated Siri Remote.
Run it with `run.sh`, which fails fast instead of hanging. Hand the screenshots
to the user.

**Don't use the Xcode MCP device-interaction tools on tvOS.** Taps return
"Unsupported command" and `b select` returns "Unsupported button". Arrow and
Return keys are accepted but do nothing. A UI test with `XCUIRemote` is the
only automation that moves focus here.

## What it can and can't verify

| Can verify | Can't verify; ask for a device check |
|---|---|
| A flow completes: sign-in, navigation, playback starts | How something looks: colour, spacing, typography, motion |
| Text on screen: titles, error messages, counts | How focus *feels*: scale, platter, parallax |
| An element exists, or is gone, after a change | Anything on visionOS (this skill is tvOS only) |
| Where focus lands, by `hasFocus` | |

Screenshots are evidence for the user to look at, not proof of appearance.

## Steps

1. **Start the server.** `.claude/skills/tvos-ui-check/server.sh up` starts
   Jellyfin 10.11.11 on `localhost:8096` with user `test` and password `test`.
   The library has three movies (Harbor Lights, The Long Field, Static Season)
   and one series (Night Shift Radio, three episodes). Metadata comes from NFO
   files, so it is identical on every run. Options: `server.sh up <version> <port>`;
   on another port, change `server` at the top of your check to match.
2. **Write the check.** Copy `UICheckTemplate.swift` to
   `Jelly SharkUITests/UICheck<Name>.swift` and rename the class. Keep
   `writeVerdictOnTeardown()` as the first line. Write the steps, and follow
   each one with a `waitForExistence` and a `shot("NN-name")`. Put every
   step in the one `testCheck`: run.sh stops at the first verdict, so a
   second test method never runs. The template's
   commented example checks Home and Search; uncomment and adapt it.
3. **Run it.**
   `UI_CHECK_SERVER=http://localhost:8096 .claude/skills/tvos-ui-check/run.sh UICheck<Name> [simulator-udid]`
   - It prints PASS or FAIL, the failure messages and the screenshots folder.
     Exit codes: 0 pass, 1 test failure, 2 stalled or broke.
   - `UI_CHECK_SERVER` makes it check the server answers before building.
   - `UI_CHECK_OUT` sets the output folder; the default is a new temp folder
     each run. Use a temp folder: screenshots can't be saved under `/Volumes/SSD`.
4. **Hand over the screenshots.** Send the relevant PNGs to the user with
   SendUserFile, one caption line each. A subagent without SendUserFile lists
   the absolute PNG paths with a caption each instead. Don't commit them or the check.
5. **Clean up.** Delete `Jelly SharkUITests/UICheck<Name>.swift`, then run
   `server.sh down`.

## Writing steps that fail fast

- Every wait has a deadline. Use `waitForExistence(timeout:)` and assert on it.
  A missing element should fail within seconds, with a screenshot and the
  element tree, not sit there.
- Never `sleep` or block the test. Wait for the thing that proves the step
  worked instead. run.sh treats 20s of silence in the log as a stall.
- To wait for one of several outcomes, such as success or an on-screen error,
  use `firstToExist`. A `waitForExistence` on the success element alone sits
  out its whole timeout when the app has already shown the error.
- Select a control only after `hasFocus` is true. `focus(_:trying:)` presses
  directions until it is, then fails with `focus-failed.png`.
- Assert on labels and text, never on positions. The UI is redesigned often.
- Assert the target is absent before the action that should produce it.
  Search's idle screen already lists every title as a suggestion, so a wait
  for "Static Season" passes before anything is typed.
- Find content with `labelled(_:)`, which matches anywhere in the label.
  Cards are Buttons, not cells. Movie cards read "Title, Year". Series cards
  put the unwatched count first ("3, Night Shift Radio, 2022"), so never
  match with `BEGINSWITH`. Text such as a details page's overview may live
  only inside a Button's label, not as a StaticText.
- Off-screen content is still in the tree, so `waitForExistence` passes for
  rows below the fold. When the screenshot is meant to show it, move focus
  there and assert `isHittable` before the `shot`.
- A selected option shows an image labelled "Selected" (identifier
  `checkmark.circle.fill`), so "is selected" can be asserted directly. The fixture's posters are plain colour, so a screenshot often
  can't show which title is which; the label match is the evidence.

## Focus rules learned the hard way

1. **Sidebar tabs and navigation rows take focus as the cell,** not the
   button, image or text inside them. Query `app.cells` (the `cell(_:)`
   helper), or `hasFocus` never turns true. **Picker rows are the exception:**
   in Theme and Streaming Quality each row is a Button inside a List, and the
   Button takes focus. Use `select(option:)`.
2. **Left on an open sidebar collapses it** into a pill. Its cells then have
   an empty frame and Up/Down can't reach them. `open(tab:)` uses Up/Down
   while the sidebar is open, and Left only to bring a collapsed one back.
   Left moves through the content first (Home's hero has three buttons), so
   it can take several presses; `open(tab:)` allows six. Equally, Left at a
   shelf's leading edge opens the sidebar; `focus(card:)` watches for that. Left does nothing while the screen behind has nothing focusable, such as
   Home's loading skeleton; `open(tab:)` then fails with `sidebar-stuck.png`.
3. **Re-selecting the current tab doesn't pop its stack.** If the target
   screen is already showing, use it as it is.
4. **Menu at the top level leaves the app,** and so does Menu on a screen with
   nothing focusable. Queries still match the backgrounded app's last tree,
   so `exists` stays true and later presses land on the tvOS home screen.
   Use `pressMenu()`, which fails as soon as the app leaves the foreground.
5. **Text entry:** focus the field, press select, wait for `app.keyboards`,
   type the text, then press Menu only if the keyboard is still up. Menu with
   no keyboard pops the screen. `type(_:into:)` deletes the field's whole
   current value and then asserts the field holds exactly the new text.
   The Search tab is different: its system search field already has the
   keyboard up when the tab opens. Use `search(_:)`, which only types.
6. **The simulator keeps state between runs.** It may still be signed in to a
   server that no longer exists. Start each check from a known state; the
   template's `signIn` signs out first if it needs to. Sign-out waits for the
   saved server's logout call. A refused server is quick, but one that
   accepts connections and never answers holds the screen past the 20s wait.
   Navigation isn't restored, so `app.launch()` always starts at the root.

## Hang modes, and how run.sh fails fast on them

| Mode | Signature | Guard |
|---|---|---|
| xcodebuild never exits after the last test | "Executed 1 test" is logged, then nothing more for minutes | The test writes its own `verdict.txt` and screenshots. run.sh stops xcodebuild as soon as the verdict appears. |
| Result bundle never finishes saving | `.xcresult` holds only `Data/` and `Staging/`, with no `Info.plist` | Nothing reads the bundle. The verdict and screenshots come from the test itself. |
| A parallel-testing clone never launches the app | The cloned simulator sits on the tvOS home screen | `-parallel-testing-enabled NO` |
| Simulator doesn't boot | `simctl bootstatus` never returns | run.sh boots it itself and gives it 120s |
| Build never gets to testing | No "Test suite started" line | 600s limit (`UI_CHECK_BUILD_LIMIT`) |
| Test stalls mid-run | The log stops growing | 20s with no output (`UI_CHECK_QUIET_LIMIT`); run.sh saves `stalled.png` and prints the last step |
| App's main thread stuck (process alive, so the crash watch can't see it) | One UI query takes ~107s: three snapshot attempts ~31s apart, then "Timed out while evaluating UI query" | The 20s quiet limit. A healthy check logs a step at least every 2.5s |
| Server down or frozen before the run | Sign-in fails a minute or more in | `UI_CHECK_SERVER` preflight: `curl -m 3` before the build |
| Server refuses mid-check | "Network error: Could not connect to the server." on the form | `signIn` waits for Disconnect *or* an error text, and fails on the error |
| Server frozen mid-check | "Signing in..." with a spinner until the request times out | The caller's 30s Disconnect wait. Nothing faster is possible from outside |
| The app crashes or is killed mid-test | XCTest keeps logging `Checking existence of …` against the dead app until the wait times out, so the log never goes quiet | run.sh watches the app process (its path contains the simulator's UDID) and fails 15s after it disappears. Before this guard, a crash took 160s to report; now it takes 24s. |
| The test runner dies (simulator shut down, or a second run) | `Restarting after unexpected exit, crash, or test timeout` or `Early unexpected exit`, then `Executed 0 tests` | run.sh fails on that line |
| Two runs on one simulator | Each kills the other's runner | A lock per simulator in `~/Library/Caches/jelly-shark-ui-check/locks/<UDID>`, shared across worktrees; a lock left by a dead process is taken over |
| Class name typo | `Executed 0 tests`, while xcodebuild reports `TEST SUCCEEDED` | run.sh fails on `Executed 0 tests` |
| UDID typo | xcodebuild searches for about 60s, then `Unable to find a device matching …` | run.sh checks the UDID before doing anything else |

Not hang modes, though they were suspected: on tvOS 27 a fresh simulator shows
no Local Network prompt, and Home's skeleton pulse doesn't stall XCUITest's idle
wait (each wait took 0.02–1.3s with the skeleton on screen).

The "never exits" mode was not reproduced on 2026-10-29. With a stored or a
computed `app`, xcodebuild exited within 10s after a failing test, in 3 of 3
runs each, so the Apple forums theory (thread 818688) isn't supported. The
guard stays because the hang has been seen.

When you hit a new hang, add a row here and a guard in `run.sh`, in the same PR.

## Exploring a screen you don't know yet (optional)

To learn a new screen's labels and focus order before you write steps,
[agent-device](https://github.com/callstack/agent-device) is faster than
rebuilding a test. Pin it to `0.21.35`, install it in a scratch folder (it needs
Node, installed through nvm, not Homebrew), and use `--platform ios --target tv`. Its snapshot marks the focused
element. Use it only to explore, never as evidence. It silently relaunches a
crashed app, its `fill` appends to existing text, and it throws occasional
errors mid-animation. Stop its daemon afterwards with `agent-device daemon stop`.
Its screenshots can't be saved under `/Volumes/SSD`; use a temp folder.
