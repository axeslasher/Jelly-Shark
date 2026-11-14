# Figma Tokens

The DesignSystem tokens are mirrored as variables in
[Jelly-Shark-DS](https://www.figma.com/design/Q8aV4lenWHPqPdwtoPKpvc/Jelly-Shark-DS).
Code is the source of truth; the Figma file is a projection of it. Components are documented
in [FIGMA_COMPONENTS.md](FIGMA_COMPONENTS.md).

## Variable collections

| Collection | Modes | Contents | Swift source |
|---|---|---|---|
| `Primitives` | Value | 288 colors, `base/<family>/<shade>` + `base/black`, `base/white`. Hidden from pickers. | `Tokens/BaseColors.swift` |
| `Theme` | Standard, Horror, Action, Video Store, Sci-Fi | 17 `color/<role>` + 2 `color/artwork-scrim*` + 3 design-only `color/{accent,accentSecondary,tertiary}-clear` (GenreShelfItem's blob fades), 39 `type/…` (family/size/weight/tracking per role + emphasis weights), `motion/transition-duration`, `motion/easing`, 3 `geometry/…`, 2 design-only `focus/…` (see deviations) | `Theming/Themes/*.swift`, `Theming/{Theme,FontScheme}.swift` |
| `Platform` | tvOS, visionOS | 16 `spacing/…` + `spacing/platform-scale`, 9 `type/base-size/…`, 9 `type/base-weight/…`, 4 `type/tracking/…`, 3 `type/line-height/…`, `type/platform-scale` | `Tokens/SpacingTokens.swift`, `Tokens/TypographyTokens.swift` |
| `Motion` | Value | 4 `duration/…`, 6 `easing/…`, `focus-scale`, `pressed-scale`, `caption-idle-opacity` | `Tokens/MotionTokens.swift` |
| `System` | Mode 1 | 7 `tvOS/glass/…` (frost, light angle and strength, refraction, depth, dispersion, splay) — tuned by eye against Apple's UI kits | **Design-only.** tvOS draws the glass; these drive the Materials page. Bound to the glass effect in the app; the plugin API only sees the `frost` binding. |
| `Copy` | en | 14 STRINGs: 13 named after DesignSystem string-catalog keys (every key but the `#Preview` samples; `shelf.failed.retry` → `shelf/failed/retry`), plus `failedShelfNotice/message` | `Localizable.xcstrings` in DesignSystem; key-named variables carry the key and translator comment. `failedShelfNotice/message` is still an inline literal, `FailedShelfNotice(message:)`'s default. Change code first, then Figma. |

Switching a frame's `Theme` mode flips every bound color/type/motion value to that theme.
Every variable carries iOS code syntax (`theme.accent`, `SpacingTokens.md`,
`BaseColors.zinc900`, …) so Dev Mode shows the Swift accessor instead of a raw value.
Wherever a theme uses a base token unchanged, the Theme variable *aliases* the Platform base
token; multiplied values (`Size.display * 1.4`, `Tracking.wide * 4`) are flattened literals
with the exact code formula in the variable description (Figma variables cannot compute).

## Representation deviations from code

- **Two `focus/…` `Theme` variables are design-only**, derived from code rather than mirroring
  a Swift token (the `-clear` colours are the other design-only set; see the table). `focus/system-platter` (BOOLEAN) is true where `theme.focusFill == nil` (Standard),
  so glass buttons can show the white system platter. `focus/platter-padding` (FLOAT) sizes
  the focused glass circle: `SpacingTokens.sm × focusScale` = 16.8, except Standard's system
  glass lift, measured on the tvOS simulator at 18.25 (an 82.7pt circle).

- **Primitive values are gamut-clipped sRGB.** `BaseColors` is authored in OKLCH and renders
  extended-sRGB on device; high-chroma shades are more saturated than the Figma swatch.
- **Alpha values alias their primitive** through `COMPOSE_COLOR` expressions, mirroring
  code's `BaseColors.x.opacity(n)`. 24 cells use it: `focusRing` (all modes), `focusFill`
  (Standard/Horror/Action/Video Store), Horror + Video Store `secondary` and `tertiary`, Horror
  `onFocusFillSecondary`, and the scrim pair. The scrim aliases `color/background` *inside*
  `Theme` rather than a primitive, matching code's `theme.background.opacity(0.55)`.
  Gradient stops still take their *alpha from the variable*, so `color/artwork-scrim` /
  `color/artwork-scrim-clear` remain a pair.
- **The `COMPOSE_COLOR` alpha argument is a percentage.** `COMPOSE_COLOR(alias, 80)` is 80%
  opacity; passing `0.8` silently resolves to 0.8% — a near-invisible fill, no error raised.
  Same percent convention as `caption-idle-opacity`.
- **Standard `focusFill` is ahead of code.** Figma has `base/white` at 80%; code is still
  `nil` (the untinted system Liquid Glass platter) until the matching change lands. Until then
  `focus/system-platter` and Standard's `focus/platter-padding` (18.25) still describe code.
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
- **SF Pro does not render server-side** (verified 2026-10-30): every SF Pro / SF Compact
  style lists and "loads" but lays out at zero width, so it never shows in MCP screenshots
  and hugging layouts measure it as empty. `setProperties` on an SF Pro text property fails;
  writing `characters` on the layer after loading SF Pro works (verified 2026-11-13).
- SF Symbols are SF Pro text in components (FIGMA_COMPONENTS.md, convention 3). The vector
  `icon` set that `scripts/figma/sf-symbols/` generated for ⮑ Icons is outdated.
- **Copy variables bind to a text property's default, never to a property-linked text layer.**
  Binding that layer's `characters` drops its component-property link, and instance overrides are then
  silently ignored. Bound as the property's default (`editComponentProperty(key,
  { defaultValue: alias })`), instances without an override follow the variable, overrides
  stick, and an instance can bind its own property to a variable (verified 2026-11-04).

## Re-syncing after token changes

Ask Claude Code to *"diff the DesignSystem tokens against the Figma variables and update the
delta"*. Names are deterministic and creation scripts are check-before-create, so a re-run
updates values in place instead of duplicating. (Figma's Variables REST write API is
Enterprise-only; the MCP flow is the sync path.) Mind the percent/pixel guards above.
