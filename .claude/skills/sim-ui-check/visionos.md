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
  `type(_:into:)` clears the field by its value's length and checks the result.
  Keep the clearing tight: 60-plus deletes into the username field swallowed
  the text typed after them. An empty field reports its placeholder as its
  value, and the server form may also prefill the same text, so the value
  alone can't tell you whether the field is empty.

## System sheets and hidden elements

| What happens | Effect | What the template does |
|---|---|---|
| A "Save Password?" sheet follows every sign-in, a moment after Disconnect shows | It hides the tab bar from queries until it goes | `signIn` waits up to 3s for it and taps "Not Now". Every `waitUntil` also taps a late one. |
| Typing in Search opens a suggestion dropdown | The tree then holds only the suggestions ("Static Season", no year). The tab bar, the search field and the result cards all drop out, though they stay on screen. Return and a tap outside leave it open. | `open(tab:)` taps a suggestion that matches the last `search(_:)`, which closes the dropdown |

To assert on search results, match the suggestion text. A wait for a card
("Static Season, 2023") fails while the dropdown is open.

## Screenshots

`app.screenshot()` crops the window to 1280×720, and `XCUIScreen.main` returns
a 1×1 image. So `shot` asks run.sh for one instead: it writes
`screenshots/requests/<name>`, and run.sh answers with `xcrun simctl io
screenshot`. The result is the whole simulated room at 3840×2160, with the app
window, its ornaments and any system sheet in it.

A `shot` fails after 10s if nothing answers, which means the check isn't
running under run.sh.

## Exploring a screen you don't know yet

The Xcode MCP tools refuse visionOS (see SKILL.md), and agent-device has only
been tried on tvOS. Explore by adding a step that fails on purpose,
`XCTFail(dump("explore"))`, where you want to look: the failure prints the
whole element tree with every label and identifier. Each look costs a run,
about 50s warm.
