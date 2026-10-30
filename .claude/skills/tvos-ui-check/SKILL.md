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
   files, so it is identical on every run. Options: `server.sh up <version> <port>`.
2. **Write the check.** Copy `UICheckTemplate.swift` to
   `Jelly SharkUITests/UICheck<Name>.swift` and rename the class. Keep
   `writeVerdictOnTeardown()` as the first line. Write the steps, and follow
   each one with a `waitForExistence` and a `shot("NN-name")`.
3. **Run it.** `.claude/skills/tvos-ui-check/run.sh UICheck<Name>`. It prints
   PASS or FAIL with the failure messages and the screenshots folder. Exit
   codes: 0 pass, 1 test failure, 2 stalled or broke.
4. **Hand over the screenshots.** Send the relevant PNGs to the user with
   SendUserFile, one caption line each. Don't commit them or the check.
5. **Clean up.** Delete `Jelly SharkUITests/UICheck<Name>.swift`, then run
   `server.sh down`.

## Writing steps that fail fast

- Every wait has a deadline. Use `waitForExistence(timeout:)` and assert on it.
  A missing element should fail within seconds, with a screenshot and the
  element tree, not sit there.
- Avoid `sleep` and fixed delays. Wait for the thing that proves the step
  worked instead.
- Select a control only after `hasFocus` is true. `focus(_:trying:)` presses
  directions until it is, then fails with `focus-failed.png`.
- Assert on labels and text, never on positions. The UI is redesigned often.

## Focus rules learned the hard way

1. **Sidebar tabs and list rows take focus as the cell,** not the button,
   image or text inside them. Query `app.cells` (the `cell(_:)` helper), or
   `hasFocus` never turns true.
2. **Left on an open sidebar collapses it** into a pill. Its cells then have
   an empty frame and Up/Down can't reach them. `open(tab:)` uses Up/Down
   while the sidebar is open, and Left only to bring a collapsed one back.
3. **Re-selecting the current tab doesn't pop its stack.** If the target
   screen is already showing, use it as it is.
4. **Menu at the top level leaves the app.** Press Menu only while what you
   need is missing, and with a cap on presses.
5. **Text entry:** focus the field, press select, wait for `app.keyboards`,
   type the text, then press Menu. Clear the field first with
   `XCUIKeyboardKey.delete` repeated.
6. **The simulator keeps state between runs.** It may still be signed in to a
   server that no longer exists. Start each check from a known state; the
   template's `signIn` signs out first if it needs to.

## Hang modes, and how run.sh fails fast on them

| Mode | Signature | Guard |
|---|---|---|
| xcodebuild never exits after the last test | "Executed 1 test" is logged, then nothing more for minutes | The test writes its own `verdict.txt` and screenshots. run.sh stops xcodebuild as soon as the verdict appears. |
| Result bundle never finishes saving | `.xcresult` holds only `Data/` and `Staging/`, with no `Info.plist` | Nothing reads the bundle. The verdict and screenshots come from the test itself. |
| A parallel-testing clone never launches the app | The cloned simulator sits on the tvOS home screen | `-parallel-testing-enabled NO` |
| Simulator doesn't boot | `simctl bootstatus` never returns | run.sh boots it itself and gives it 120s |
| Build never gets to testing | No "Test suite started" line | 600s limit (`UI_CHECK_BUILD_LIMIT`) |
| Test stalls mid-run | The log stops growing | 90s with no output (`UI_CHECK_QUIET_LIMIT`) |
| The app crashes or is killed mid-test | XCTest keeps logging `Checking existence of …` against the dead app until the wait times out, so the log never goes quiet | run.sh watches the app process (its path contains the simulator's UDID) and fails 15s after it disappears. Before this guard, a crash took 160s to report; now it takes 24s. |
| The test runner dies (simulator shut down, or a second run) | `Restarting after unexpected exit, crash, or test timeout` or `Early unexpected exit`, then `Executed 0 tests` | run.sh fails on that line |
| Two runs on one simulator | Each kills the other's runner | A lock per simulator in `~/Library/Caches/jelly-shark-ui-check/locks/<UDID>`, shared across worktrees; a lock left by a dead process is taken over |
| Class name typo | `Executed 0 tests`, while xcodebuild reports `TEST SUCCEEDED` | run.sh fails on `Executed 0 tests` |
| UDID typo | xcodebuild searches for about 60s, then `Unable to find a device matching …` | run.sh checks the UDID before doing anything else |

The "never exits" mode was not reproduced on 2026-10-29. With a stored or a
computed `app`, xcodebuild exited within 10s after a failing test, in 3 of 3
runs each, so the Apple forums theory (thread 818688) isn't supported. The
guard stays because the hang has been seen.

When you hit a new hang, add a row here and a guard in `run.sh`, in the same PR.
