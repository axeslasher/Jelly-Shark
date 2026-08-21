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

## Representation deviations from code

- **Primitive values are gamut-clipped sRGB.** `BaseColors` is authored in OKLCH and renders
  extended-sRGB on device; high-chroma shades are more saturated than the Figma swatch.
- **Alpha-baked theme values are raw RGBA**, not aliases (Figma can't alias-with-opacity).
  Gradient stops bind to color variables but take their *alpha from the variable* — hence the
  `color/artwork-scrim` / `color/artwork-scrim-clear` pair backing the playback-badge scrim.
- **Standard `focusFill` is transparent** in Figma; in code it is `nil` (untinted system
  Liquid Glass platter).
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

- **Custom fonts are desktop-local.** The Fontshare families aren't loadable by Figma's
  server-side scripting, so automated edits to any text node resolving to them fail
  (characters, truncation, bindings, instance text props). Such edits are done by hand in
  Figma; new text is authored in Inter with `fontFamily` bound last.
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
