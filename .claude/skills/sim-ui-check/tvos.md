# tvOS rules

Read with SKILL.md. The template is `UICheckTemplateTV.swift`. It drives the app
with the simulated Siri Remote (`XCUIRemote`): press a direction until the
target has focus, then press select.

## Writing steps

- Select a control only after `hasFocus` is true. `focus(_:trying:)` presses
  directions until it is, then fails with `focus-failed.png`.
- Cards are Buttons, not cells. Movie cards read "Title, Year". Series cards
  put the unwatched count first ("3, Night Shift Radio, 2022"), so never
  match with `BEGINSWITH`. Text such as a details page's overview may live
  only inside a Button's label, not as a StaticText.
- Off-screen content is still in the tree, so `waitForExistence` passes for
  rows below the fold. When the screenshot is meant to show it, move focus
  there and assert `isHittable` before the `shot`.
- A selected option shows an image labelled "Selected" (identifier
  `checkmark.circle.fill`), so "is selected" can be asserted directly.
- Settings → Streaming Quality is `open(row: "Streaming Quality")`. Its
  options read "Maximum", "40 Mbps" and so on down to "2 Mbps".
- `shot` uses XCUITest's own screenshot, which shows the whole screen on tvOS.
- To show the sidebar in a screenshot, focus one of its cells first; it
  collapses whenever focus is in the content.

## Focus rules learned the hard way

1. **Sidebar tabs and navigation rows take focus as the cell,** not the
   button, image or text inside them. Query `app.cells` (the `cell(_:)`
   helper), or `hasFocus` never turns true. **Picker rows are the exception:**
   in Theme and Streaming Quality each row is a Button inside a List, and the
   Button takes focus. Use `select(option:)`. **"Libraries" is a section
   header, not a tab:** it can't take focus. Each library ("Movies", "Shows")
   is a sidebar tab of its own; open it with `open(tab: "Shows")`.
2. **Left on an open sidebar collapses it** into a pill. Its cells then have
   an empty frame and Up/Down can't reach them. `open(tab:)` uses Up/Down
   while the sidebar is open, and Left only to bring a collapsed one back.
   Left moves through the content first (Home's hero has three buttons), so
   it can take several presses; `open(tab:)` allows six. Equally, Left at a
   shelf's leading edge opens the sidebar; `focus(card:)` watches for that.
   Left does nothing while the screen behind has nothing focusable, such as
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

## A server that's down

With the server down, Home stays on its loading skeleton, which has nothing
focusable, so Settings can't be reached; the sidebar's library entries show
the session is still standing. Load Home once before taking the server down if
the check needs its content.

## Exploring a screen you don't know yet (optional)

To learn a new screen's labels and focus order before you write steps,
[agent-device](https://github.com/callstack/agent-device) is faster than
rebuilding a test. Pin it to `0.21.35`, install it in a scratch folder (it needs
Node, installed through nvm, not Homebrew), and use `--platform ios --target tv`.
Its snapshot marks the focused element. Use it only to explore, never as
evidence. It silently relaunches a crashed app, its `fill` appends to existing
text, and it throws occasional errors mid-animation. Stop its daemon afterwards
with `agent-device daemon stop`. Its screenshots can't be saved under
`/Volumes/SSD`; use a temp folder.
