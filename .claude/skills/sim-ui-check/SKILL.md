---
name: sim-ui-check
description: Verify a small tvOS or visionOS UI change on the simulator yourself, with screenshots, instead of asking for device time. Use for flows, on-screen text, and whether something appears after a change: sign-in, navigation, a row or label showing up, an error message. Not for appearance, how focus feels, or spatial behaviour; those still go to the device.
---

# Simulator UI check

Write a throwaway XCUITest that drives the app on the Apple TV or Apple Vision
Pro simulator. Run it with `run.sh`, which fails fast instead of hanging. Hand
the screenshots to the user.

Before writing steps, read the rules for your platform: tvos.md (Siri Remote
and focus) or visionos.md (taps, system sheets, screenshots).

## Which tool

| Platform | Use | Not this, and why |
|---|---|---|
| tvOS | This skill, `UICheckTemplateTV.swift` | Xcode MCP device-interaction tools: a session starts, but taps return "Unsupported command", `b select` "Unsupported button", and arrow and Return keys do nothing |
| visionOS | This skill, `UICheckTemplateVision.swift` | Xcode MCP device-interaction tools: they refuse to start a session ("Supported: iOS / watchOS / tvOS [Simulator] 27.0+") |

Checked with Xcode 27 and the 27.0 simulators. After an Xcode update, the
`Supported:` line in that error says whether visionOS has been added.

## What it can and can't verify

| Can verify | Can't verify; ask for a device check |
|---|---|
| A flow completes: sign-in, navigation, playback starts | How something looks: colour, spacing, typography, motion |
| Text on screen: titles, error messages, counts | How focus *feels* on tvOS: scale, platter, parallax |
| An element exists, or is gone, after a change | Depth, hover effects, gaze and look to scroll on visionOS |
| Where focus lands on tvOS, by `hasFocus` | Window sizing and immersive playback on visionOS |

Screenshots are evidence for the user to look at, not proof of appearance.

## Steps

1. **Start the server.** `.claude/skills/sim-ui-check/server.sh up` starts
   Jellyfin 10.11.11 on `localhost:8096` with user `test` and password `test`.
   The library has three movies (Harbor Lights 2019, The Long Field 2021,
   Static Season 2023) and one series (Night Shift Radio 2022, three
   episodes), in two libraries named "Movies" and "Shows". Metadata comes from NFO
   files, so it is identical on every run. Options: `server.sh up <version> <port>`.
   Versions on different ports run side by side (Jellyfin 12 tags are two-part:
   `12.4`). The check reads its server from run.sh's `UI_CHECK_SERVER`, so one
   check runs against every port unedited. Pull a new image with its own
   `server.sh up` before starting others: a first start of `12.4` beside a
   second server outran the 90s wait once, then started in 7s warm. Checks
   that run at the same time each get their own port: a check that revokes
   the app's devices would sign the other one out. **On any port but 8096,
   set `UI_CHECK_SERVER` in step 3,** or the check signs in to 8096. The
   version comes before the port:

   ```bash
   .claude/skills/sim-ui-check/server.sh up 10.11.11 8097
   UI_CHECK_SERVER=http://localhost:8097 .claude/skills/sim-ui-check/run.sh UICheck<Name> visionos
   ```
2. **Write the check.** Copy the platform's template to
   `Jelly SharkUITests/UICheck<Name>.swift` and rename the class. Keep
   `writeVerdictOnTeardown()` as the first line. Write the steps, and follow
   each one with a wait and a `shot("NN-name")`. Put every step in the one
   `testCheck`: run.sh stops at the first verdict, so a second test method
   never runs. Each template has a commented example (Home, then Search, and
   a details page on visionOS); uncomment and adapt it. The `#if os(...)`
   around each template keeps the other platform's build compiling.
3. **Run it.**
   `UI_CHECK_SERVER=http://localhost:8096 .claude/skills/sim-ui-check/run.sh UICheck<Name> [tvos|visionos|simulator-udid]`
   - The platform defaults to tvOS. `visionos` picks the "Apple Vision Pro"
     simulator; a UDID picks its own platform.
   - It prints PASS or FAIL, the failure messages and the screenshots folder.
     Exit codes: 0 pass, 1 test failure, 2 stalled or broke.
   - `UI_CHECK_SERVER` makes it check the server answers before building, and
     reaches the check as `server`. Any other `TEST_RUNNER_<NAME>` you export
     reaches it as `<NAME>`, such as a mode switch for one check with several
     scenarios.
   - `UI_CHECK_OUT` sets the output folder; the default is a new temp folder
     each run. Use a temp folder: screenshots can't be saved under `/Volumes/SSD`.
     The folder holds `xcodebuild.log`, and `screenshots/` with every `shot`,
     every `explore` tree (`.txt`), `zz-failure.png` and `verdict.txt`. Its
     `result.xcresult` is often unfinished; nothing reads it.
   - run.sh prints "testing" once the build is done; it is otherwise quiet
     until the verdict.
   - A warm run takes about 35–90s, build included.
   - run.sh builds the checkout it is run from, so it works from a worktree.
   - A failed check also leaves `zz-failure.png`, the screen it failed on.
   - To learn a screen's labels, call `explore("name")`: it saves the element
     tree as `name.txt` and carries on.
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
- Assert on labels and text, never on positions. The UI is redesigned often.
- Assert the target is absent before the action that should produce it.
  Search's idle screen already lists every title as a suggestion, so a wait
  for "Static Season" passes before anything is typed.
- Find content with `labelled(_:)`, which matches anywhere in the label.
  The fixture's posters are plain colour, so a screenshot often can't show
  which title is which; the label match is the evidence.
- **The simulator keeps state between runs.** It may still be signed in to a
  server that no longer exists. Start each check from a known state; the
  templates' `signIn` signs out first if it needs to. Sign-out waits for the
  saved server's logout call. A refused server is quick, but one that accepts
  connections and never answers holds the screen past the 20s wait.
  Navigation isn't restored, so `app.launch()` always starts at the root.

## Checking a saved session

A restore check signs in, then relaunches: `relaunch()` keeps the Keychain,
so the app restores its session. `api(_:_:)` calls the server as its admin
from the test, on a device of its own.

| To get | Do this |
|---|---|
| A revoked token | `revokeAppDevices()`, which calls `api("DELETE", "/Devices?id=<id>")` for each `GET /Devices` item whose `AppName` is "Jelly Shark", then relaunch. Verified on 10.11.11 and 12.4: the token then gets 401. `DELETE /Auth/Keys/{token}` answers 204 but leaves a session token valid |
| A token the server never issued | Leave the app signed in, run `server.sh up` again on the same port (a fresh container), relaunch |
| A too-old server behind the saved URL | Sign in on 10.11.11, `server.sh up 10.11.10` on the same port, relaunch |
| A server that's down | Leave the app signed in, `server.sh down <port>`, relaunch |
| Proof that sign-out revoked the token | `GET /Devices` has no "Jelly Shark" item afterwards |

The form shows a failed restore's message under Settings → Server, above
Connect, with the URL and username kept. For a revoked token it reads "Your
session has expired. Please sign in again." Home shows only "Welcome to Jelly
Shark" and "Connect in Settings" (both seen on visionOS). On tvOS a down server
also blocks navigation; see tvos.md.

## Checking the server side

To show what the server recorded, such as a device appearing or going away,
or the version the app reports, screenshot the Jellyfin web dashboard with
`dashboard.py`. It signs in through the API, so no login form is driven.

1. **Set up once,** in a temp folder, not the repo:
   `python3 -m venv <dir>/pw && <dir>/pw/bin/pip install playwright && <dir>/pw/bin/playwright install chromium`.
   Chromium lands in `~/Library/Caches/ms-playwright` (about 100 MB).
2. **Run it from outside the repo:**
   `<dir>/pw/bin/python -I .claude/skills/sim-ui-check/dashboard.py http://localhost:8097 <out>.png [page]`.
   The page defaults to `dashboard/devices`; `dashboard/activity` also works.
3. **Read the rows.** The app is "Jelly Shark <version>", after the device
   name ("Apple TV" on tvOS; on visionOS, read the row the check created). "Chrome ·
   Jellyfin Web" is the script's own session and "ui-check" is server.sh's.

For an assertion inside the check itself, use `api("GET", "/Devices")`
instead: the dashboard shows the same data, and the screenshot is for people.

## Hang modes, and how run.sh fails fast on them

| Mode | Signature | Guard |
|---|---|---|
| xcodebuild never exits after the last test | "Executed 1 test" is logged, then nothing more for minutes | The test writes its own `verdict.txt` and screenshots. run.sh stops xcodebuild as soon as the verdict appears. |
| Result bundle never finishes saving | `.xcresult` holds only `Data/` and `Staging/`, with no `Info.plist` | Nothing reads the bundle. The verdict and screenshots come from the test itself. |
| A parallel-testing clone never launches the app | The cloned simulator sits on the home screen | `-parallel-testing-enabled NO` |
| Simulator doesn't boot | `simctl bootstatus` never returns | run.sh boots it itself and gives it 120s |
| Build never gets to testing | No "Test suite started" line | 600s limit (`UI_CHECK_BUILD_LIMIT`) |
| Test stalls mid-run | The log stops growing | 20s with no output (`UI_CHECK_QUIET_LIMIT`); run.sh saves `stalled.png` and prints the last step |
| App's main thread stuck (process alive, so the crash watch can't see it) | One UI query takes ~107s: three snapshot attempts ~31s apart, then "Timed out while evaluating UI query" | The 20s quiet limit. A healthy check logs a step at least every 2.5s |
| Server down or frozen before the run | Sign-in fails a minute or more in | `UI_CHECK_SERVER` preflight: `curl -m 3` before the build |
| Server refuses mid-check | "Network error: Could not connect to the server." on the form | `signIn` waits for Disconnect *or* an error text, and fails on the error |
| Server frozen mid-check | "Signing in..." with a spinner until the request times out | `signIn`'s 30s outcome wait: "Still signing in after 30s — is the server answering?". Nothing faster is possible from outside |
| Simulator wedged: reports Booted, but launches nothing (seen on visionOS) | `simctl bootstatus` and `simctl launch` print nothing and never return; the test runner fails with "The system shell probably crashed" | The 120s boot limit, then a message naming the fix: `xcrun simctl shutdown <udid>` and run again. A clean boot took 14s. |
| Simulator shut down mid-run (visionOS) | The test runner boots it again within about 4s, so it looks like an app crash and the "runner died" line never appears | run.sh records the simulator's launchd pid when testing starts; a new pid means "the simulator shut down or restarted mid-run" (15s) |
| A visionOS `shot` gets no answer, or no screenshot | The check waits on `screenshots/requests/<name>` | run.sh caps each screenshot at 5s and writes `<name>.failed` when it gets none; `shot` then fails with that reason. No answer in 10s means run.sh is blocked |
| The app crashes or is killed mid-test | XCTest keeps logging `Checking existence of …` against the dead app until the wait times out, so the log never goes quiet | run.sh watches the app process (its path contains the simulator's UDID) and fails 15s after it disappears. Before this guard, a crash took 160s to report; now it takes 24s on tvOS and 18s on visionOS. |
| The test runner dies (simulator shut down, or a second run) | `Restarting after unexpected exit, crash, or test timeout` or `Early unexpected exit`, then `Executed 0 tests` | run.sh fails on that line |
| Two runs on one simulator | Each kills the other's runner | A lock per simulator in `~/Library/Caches/jelly-shark-ui-check/locks/<UDID>`, shared across worktrees; a lock left by a dead process is taken over |
| Class name typo | `Executed 0 tests`, while xcodebuild reports `TEST SUCCEEDED` | run.sh fails on `Executed 0 tests` |
| UDID typo | xcodebuild searches for about 60s, then `Unable to find a device matching …` | run.sh checks the UDID before doing anything else |
| A tvOS and a visionOS run building at once | Both build into one derived-data folder and fight over its lock | One derived-data folder per platform |

Not hang modes, though they were suspected: on tvOS 27 a fresh simulator shows
no Local Network prompt, and Home's skeleton pulse doesn't stall XCUITest's idle
wait (each wait took 0.02–1.3s with the skeleton on screen). On visionOS,
xcodebuild exited by itself after every one of 5 runs.

The "never exits" mode was not reproduced on 2026-10-29. With a stored or a
computed `app`, xcodebuild exited within 10s after a failing test, in 3 of 3
runs each, so the Apple forums theory (thread 818688) isn't supported. The
guard stays because the hang has been seen.

When you hit a new hang, add a row here and a guard in `run.sh`, in the same PR.
