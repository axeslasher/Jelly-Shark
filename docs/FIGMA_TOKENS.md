# Figma Design File

The DesignSystem tokens and first components are mirrored in
[Jelly Shark (Code-based)](https://www.figma.com/design/Q8aV4lenWHPqPdwtoPKpvc/Jelly-Shark--Code-based-).
Code is the source of truth; the Figma file is a projection of it.

## Variable collections

| Collection | Modes | Contents | Swift source |
|---|---|---|---|
| `Primitives` | Value | 288 colors, `base/<family>/<shade>` + `base/black`, `base/white`. Hidden from pickers. | `Tokens/BaseColors.swift` |
| `Theme` | Standard, Horror, Action, Video Store, Sci-Fi | 17 `color/<role>` + 2 `color/artwork-scrim*`, 39 `type/…` (family/size/weight/tracking per role + emphasis weights), `motion/transition-duration`, `motion/easing`, 3 `geometry/…` | `Theming/Themes/*.swift`, `Theming/{Theme,FontScheme}.swift` |
| `Platform` | tvOS, visionOS | 16 `spacing/…` + `spacing/platform-scale`, 9 `type/base-size/…`, 9 `type/base-weight/…`, 4 `type/tracking/…`, 3 `type/line-height/…`, `type/platform-scale` | `Tokens/SpacingTokens.swift`, `Tokens/TypographyTokens.swift` |
| `Motion` | Value | 4 `duration/…`, 6 `easing/…`, `focus-scale`, `pressed-scale`, `caption-idle-opacity` | `Tokens/MotionTokens.swift` |

Switching a frame's `Theme` mode flips every bound color/type/motion value to that theme.
Every variable carries iOS code syntax (`theme.accent`, `SpacingTokens.md`,
`BaseColors.zinc900`, …) so Dev Mode shows the Swift accessor instead of a raw value.
Wherever a theme uses a base token unchanged, the Theme variable *aliases* the Platform base
token; multiplied values (`Size.display * 1.4`, `Tracking.wide * 4`) are flattened literals
with the exact code formula in the variable description (Figma variables cannot compute).

## Components (page: Component Previews)

| Figma component | Code counterpart |
|---|---|
| `ArtworkImage` (aspectRatio 2:3\|16:9 × hasImage) | `Components/ArtworkImage.swift` — hasImage is runtime state; deliberately decoration-free |
| `ArtworkShelfItem` (same axes + title/subtitle/hasSubtitle/synopsis/hasSynopsis/hasCount/hasProgress/isUnwatched props) | `Components/ArtworkShelfItem.swift` — props mirror the init; `hasX = false` = `nil` param = reserved blank caption line |
| `base/artworkShelf/playback` (+ `progressTrack`) | `PlaybackBadge` / `playbackBadgeContent` in ArtworkShelfItem.swift — models `.inProgress`; `.unplayed`/`.played` variants pending curated SF Symbols |
| `base/countBadge` | the countBadge overlay in ArtworkShelfItem.swift |
| `base/watchedIndicator` | **design-only** — no code counterpart (code expresses watched via `PlaybackBadge.played`) |

Each component's Figma description carries its Swift file, init signature, prop↔parameter
mapping, and GitHub URL — that is the code↔design mapping, because **Code Connect is
unavailable**: it requires an Organization/Enterprise plan and this file is on Professional
(UI, CLI, and MCP mapping calls all refuse; verified 2026-08). The structural rule recorded
on `ArtworkShelfItem`: artwork and caption lines are flat siblings of the button label —
the tvOS borderless focus lockup breaks if they're wrapped in a stack.

**Dev Mode annotations** are the second mapping channel, and unlike descriptions they attach
to any node, not just components. `node.annotations` reads and writes them over MCP;
`labelMarkdown` renders bold and code ticks in Dev Mode (verified 2026-09-11). Categories in
this file: Development, Interaction, Accessibility, Content. Use them for per-node dev notes
a component description can't hold — which variable a fill resolves through, why a frame
carries an explicit `Theme` mode.

## Representation deviations from code

- **Primitive values are gamut-clipped sRGB.** `BaseColors` is authored in OKLCH and renders
  extended-sRGB on device; high-chroma shades are more saturated than the Figma swatch.
- **Alpha values alias their primitive** through `COMPOSE_COLOR` expressions, mirroring
  code's `BaseColors.x.opacity(n)`. 23 cells use it: `focusRing` (all modes), `focusFill`
  (Horror/Action/Video Store), Horror + Video Store `secondary` and `tertiary`, Horror
  `onFocusFillSecondary`, and the scrim pair. The scrim aliases `color/background` *inside*
  `Theme` rather than a primitive, matching code's `theme.background.opacity(0.55)`.
  Gradient stops still take their *alpha from the variable*, so `color/artwork-scrim` /
  `color/artwork-scrim-clear` remain a pair.
- **The `COMPOSE_COLOR` alpha argument is a percentage.** `COMPOSE_COLOR(alias, 80)` is 80%
  opacity; passing `0.8` silently resolves to 0.8% — a near-invisible fill, no error raised.
  Same percent convention as `caption-idle-opacity`.
- **Standard `focusFill` is the one remaining raw RGBA**, at alpha 0; in code it is `nil`
  (untinted system Liquid Glass platter). That is the absence of a color, not a primitive at
  0%, so it must not be converted to an alias.
- **Multiplied type sizes are tvOS points**; aliased size modes resolve through `Platform`
  and are platform-aware (theme × platform would need a 10-mode cross product).
- **Durations are FLOAT seconds and easings are STRINGs** — TIMING/EASING variable types are
  unsupported in this file. Spring parameters are recorded in the value/description.
- **Opacity variables are percent** (`caption-idle-opacity` = `60`, code's `0.6`) and
  **bound line-height is pixels** (so the `type/line-height/*` multipliers are reference-only,
  also latent in code — `.jsStyle()` never applies them; body copy uses `.lineSpacing(4)`).
  A re-sync must not "correct" either.
- Text nodes bind `fontFamily`, `fontSize`, `fontWeight`, `letterSpacing`, fill, and opacity.

## Working limitations

- **All 16 code font families are uploaded to the Figma team and load server-side**
  (verified 2026-09-11: `listAvailableFontsAsync` lists every `FontFamily` name and
  `loadFontAsync` succeeds for each; a round-trip `characters` edit and a `Theme` mode
  switch to Horror both ran clean). Automated text edits follow the load-first recipe:
  load the node's *current* fonts from `getStyledTextSegments(['fontName'])` before
  mutating, and load every mode's value of a `FONT_FAMILY` variable before binding it or
  switching a frame's `Theme` mode.
- Component text uses semantic strings ("Item Title", "Item Subtitle", "Time Left",
  "Episode Description"), never mock titles.
- SF Symbols are hand-curated: export SVGs from the SF Symbols app into the repo, then
  automation places them (`createNodeFromSvg`) and binds fills. Current glyphs are
  approximations pending that drop.

## Re-syncing after token changes

Ask Claude Code to *"diff the DesignSystem tokens against the Figma variables and update the
delta"*. Names are deterministic and creation scripts are check-before-create, so a re-run
updates values in place instead of duplicating. (Figma's Variables REST write API is
Enterprise-only; the MCP flow is the sync path.) Mind the percent/pixel guards above.
