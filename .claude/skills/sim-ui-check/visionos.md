# visionOS rules

Read with SKILL.md. The template is `UICheckTemplateVision.swift`. It drives the
app with `tap()` and `typeText`: there is no focus to steer, so a step is "find
the element, tap it".

## Writing steps

- Cards are Buttons labelled "Title, Year", as on tvOS; series cards put the
  unwatched count first ("3, Night Shift Radio, 2022").
- **Prove a details page by its Back button** (`app.buttons["BackButton"]`),
  not by Play: Home's hero has a Play button too. `back()` taps it.
- **Tabs live in an ornament,** a window of its own beside the app window.
  They are Buttons labelled "Home", "Search", "Libraries" (signed in only) and
  "Settings". `open(tab:)` taps one.
- **Text fields need no keyboard handling.** Tap, then `typeText`.
  `type(_:into:)` clears the field and checks the result.
  - An empty field reports its placeholder as its value, and the server form
    prefills the URL field with that same text, so the value alone can't say
    whether a field is empty. Only an empty secure field is treated as empty:
    deleting its placeholder's length lost the password typed after it.
  - The value lags the typing. Read at once, it can still be the placeholder,
    so `type` waits up to 3s for it to match.
- Episodes read "0m, S1E1, Episode 1, Fixture episode 1.".
- **Settings rows** read "Theme, Standard" and "Server, Connected as test".
  The Theme picker stays open after a pick, and the chosen option carries the
  Selected trait (`isSelected`); go `back()` to see the row's new value.
- A `shot` shows only what is on screen. Content below the fold is in the tree,
  so the label match is the evidence for it, not the screenshot.

## System sheets and hidden elements

| What happens | Effect | What the template does |
|---|---|---|
| A "Save Password?" sheet follows every sign-in, failed ones too, a moment after the outcome shows | It hides the tab bar and the form from queries until it goes. It stays in the tree while it animates away, so a second tap fails. | `signIn` waits up to 3s for it, taps "Not Now" and waits for it to go. Every `waitUntil` also dismisses a late one. |
| Typing in Search opens a suggestion dropdown | The tree then holds only the suggestions ("Static Season", no year). The tab bar, the search field and the result cards all drop out, though they stay on screen. Return and a tap outside leave it open. | `open(tab:)` taps a suggestion that matches the last `search(_:)`, which closes the dropdown |

To assert on search results, match the suggestion text. A wait for a card
("Static Season, 2023") fails while the dropdown is open.

## Screenshots

`app.screenshot()` crops the window to 1280×720, and `XCUIScreen.main` returns
a 1×1 image. So `shot` asks run.sh for one instead: it writes
`screenshots/requests/<name>`, and run.sh answers with `xcrun simctl io
screenshot`. The result is the whole simulated room at 3840×2160, with the app
window, its ornaments and any system sheet in it.

Without run.sh (no `UI_CHECK_OUT`), `shot` falls back to the cropped
screenshot as an attachment. Under run.sh, `shot` fails when the screenshot
didn't land (`<name>.failed` gives the reason), or when run.sh doesn't answer
within 10s.

On a failure, the template asks for `zz-failure.png` before writing the
verdict: once the verdict is written, run.sh stops and the app closes.

## Exploring a screen you don't know yet

The Xcode MCP tools refuse visionOS (see SKILL.md), and agent-device has only
been tried on tvOS. Explore with `explore("name")` wherever you want to look:
it saves the whole element tree, every label and identifier, as `name.txt` and
carries on, so one run can look at several screens. A run costs about 35–70s
warm.
