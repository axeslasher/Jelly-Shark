# Figma Components

DesignSystem components are mirrored as Figma components in
[Jelly-Shark-DS](https://www.figma.com/design/Q8aV4lenWHPqPdwtoPKpvc/Jelly-Shark-DS). Code is
the source of truth; each Figma component is a projection of one Swift view. The variables they
bind to are documented in [FIGMA_TOKENS.md](FIGMA_TOKENS.md).

## Component map

| Figma component (page) | Code counterpart |
|---|---|
| `ArtworkImage` (⮑ Shelf Items; aspectRatio 2:3\|16:9 × hasImage) | `Components/ArtworkImage.swift` — hasImage is runtime state; deliberately decoration-free |
| `ArtworkShelfItem` (⮑ Shelf Items; same axes + title/subtitle/hasSubtitle/synopsis/hasSynopsis/hasCount/hasProgress/isUnwatched props) | `Components/ArtworkShelfItem.swift` — props mirror the init; `hasX = false` = `nil` param = reserved blank caption line |
| `base/artworkShelf/playback` (+ `progressTrack`) | `PlaybackBadge` / `playbackBadgeContent` in ArtworkShelfItem.swift — all three cases through `iconSlot`, `showProgressBar` and `timeLeft`, shown in *tvOS Theme Specimens — PlaybackBadge*; mapping in the *ArtworkShelfItem* spec |
| `base/countBadge` | the countBadge overlay in ArtworkShelfItem.swift |
| `base/shelfHeader` (⮑ Shelf Items; `title`, `icon` text, `hasIcon`) | the icon + headline `HStack` that `ContentShelf.swift` and `FailedShelfNotice.swift` each inline — **design-only consolidation**, so a change lands in both Swift files; icon size unverified (default tvOS body font) |
| `tvOS/FailedShelfNotice` (⮑ Shelf Items; `hasTitle`, `message`, `hasRetry`, exposed `header` and `retry`) | `Components/FailedShelfNotice.swift` — nests `base/shelfHeader` and `tvOS/GlassCapsuleButton`; Retry's label is bound to `shelf/failed/retry`, its glyph set by hand; visionOS not modelled |
| `base/watchedIndicator` | **design-only** — no code counterpart (code expresses watched via `PlaybackBadge.played`) |
| `tvOS/CastCard` (⮑ Shelf Items; Focus × hasImage, `name`, `role`, `hasRole`) | `Components/CastCard.swift` — Focus is the caption fade only; placeholder glyph set by hand |
| `tvOS/GenreShelfItem` (⮑ Shelf Items; `title`, `hasBackdrop`) | `Components/GenreShelfItem.swift` — blobs drawn for the seed of "Genre Name"; the spec holds the recipe |
| `tvOS/ContentShelf` (⮑ Shelf Items; headerVisible, exposed `header`, `content` slot) | `Components/ContentShelf.swift` — 1920-wide frame; header is `base/shelfHeader` |
| `GhostBlock`, `GhostCard` (`shape` 2:3\|16:9\|circle), `SkeletonShelf` (`shape`, `showsHeader`) (⮑ Shelf Items) | `Components/Skeleton.swift` — the *Skeleton* spec covers all three; the pulse isn't drawn |
| `tvOS/CircleActionButton` (⮑ Buttons; Focus False\|True × Tint Primary\|Accent, `title`, `symbol` text) | `Components/CircleActionButton.swift` — Tint=Accent is `tint` + `focusedTint` both `theme.accent`; glyph doesn't grow with focus; no disabled variant (unverified on device); visionOS not modelled |
| `tvOS/GlassCapsuleButton` (⮑ Buttons; Focus False\|True × Role Headline\|Title, `label`, `symbol` text, `hasSymbol`) | `glassButtonStyle(tint:)` capsule in `Components/GlassButtonStyle.swift` — Role is the label's `jsStyle`; content doesn't grow with focus; `inertGlassButtonStyle()` is Focus=False only; pressed, disabled and visionOS not modelled |
| `tvOS/PlainFocusButton` (⮑ Buttons; Focus, `content` slot) | `plainFocusButtonStyle(tint:cornerRadius:)` / `ThemedPlainButtonStyle` in `Components/GlassButtonStyle.swift` — the label owns its colours |
| `MetadataLabelStyle` (⮑ Labels and Placeholders; `title`, `symbol` text) | `Components/MetadataLabelStyle.swift` — drawn as the call sites style it (`.body` strong, `theme.tertiary`, `spacing: xs`) |
| `ComponentPlaceholder` (⮑ Labels and Placeholders; `name`, `symbol` text) | `Components/Placeholder.swift` — caption bound to `placeholder/comingSoon` |

**Not drawn, by design:** `CardButtonStyle` (visionOS-only and internal; it removes the system
hover so components draw their own), `ShelfCaption` (drawn as `caption-idle-opacity` on each
caption line), and the non-visual `ArtworkLoader`, `BlurHash` and `ShelfFocusID`. The ⮑ Icons
page and its `icon` set are outdated; new work draws symbols as SF Pro text (convention 3).

Each component's Figma description is a short Markdown summary: Swift view, prop↔parameter
mapping, and a GitHub link. Longer material — full mappings, geometry, deviations from code —
goes in a spec beside the component. Together they are the authoritative mapping until Code
Connect can show Swift snippets (see below).

## Building conventions

1. **Platform.** Size differences (type, spacing) come from the `Platform` variable mode, set on
   a frame. Structural differences get separate components prefixed `tvOS/` or `visionOS/`, as
   on ⮑ Input Fields. Avoid a Platform variant property: it doubles every set and can disagree
   with the frame's mode.
2. **Focus lift.** The component keeps its resting footprint; the scaled layer is centred inside
   it by auto layout and overflows, so focusing an instance never moves its neighbours — as on
   tvOS. Hanging labels are absolute children, so they never add width.
3. **Every symbol is SF Pro text,** as in Apple's own Figma kits: a text layer holding the
   symbol's character, bound to a text property. This covers inline symbols too; don't nest
   `icon` instances. Copy as text in the SF Symbols app and paste it in;
   `figma.util.getSfSymbolCharacter(name)` gives the character in a script. Size and weight
   bind to the role's type variables and the fill follows the variants, with nothing to scale.

   SF Pro lays out at 0 pt wide on Figma's servers (re-checked 2026-11-13), so MCP can't
   measure, screenshot or override these glyphs; `setProperties` on an SF Pro text property
   fails with "uses a font that isn't available". A person enters each non-default glyph in
   the Figma app. In a fixed glyph box that costs nothing; in a
   hugging label (`GlassCapsuleButton`) the button comes out one glyph narrow until the glyph
   is re-entered in the app.
4. **Don't model what tvOS does for free.** Behaviour the system adds at runtime, such as a
   symbol growing with its focus platter, stays out of the design file rather than gaining a
   variable to imitate it. Note it as a deviation in the component description instead.
5. **Previews.** Each component gets a `tvOS Theme Specimens — <name>` frame: one column per
   theme, each with an explicit `Theme` mode on a `color/background` ground, resting row above
   focused row. (CircleActionButton's frame is the unsuffixed `tvOS Theme Specimens`.)
   Components with no drawn focus state show a resting row only. Turn clipping off on specimen
   rows: new auto-layout frames clip, which hides a platter's bleed.
7. **Fades to `.clear`.** SwiftUI interpolates gradients in premultiplied colour, so a fade
   holds its hue. End a Figma gradient on the same colour at 0%, through a `-clear` variable
   (`color/artwork-scrim-clear`, `color/accent-clear`), never on transparent black.
8. **Copy.** Text that code reads from a string catalog binds to the `Copy` variable named
   after its key (see FIGMA_TOKENS.md); a semantic placeholder string otherwise.
6. **Structure.** `ArtworkShelfItem`'s artwork and caption lines are flat siblings of the button
   label — the tvOS borderless focus lockup breaks if they're wrapped in a stack.

## Liquid Glass calibration

Every glass platter is an instance of the *Liquid Glass - Regular - Small* material (Foundations
› ⮑ Materials), driven by the `System` variables; the *Glass and Platters* spec documents both.
This section is the method for checking them against what tvOS draws. Resting glass is compared
against a `#Preview` render, focused glass against a tvOS simulator capture (previews never show
focus).

1. Export a backdrop from the file (an `ArtworkImage` example) with `get_screenshot`.
2. Draw the real component over it in a scratch `#Preview`
   (`UIImage(contentsOfFile:)` on a host path works) and render it; for focus, capture the
   simulator with the `sim-ui-check` skill.
3. Put Figma instances at the same spots and compare crops side by side.
4. Sample pixels **raw** (`NSBitmapImageRep.getPixel`). `get_screenshot` URL PNGs carry no
   colour profile while preview and simulator PNGs are tagged sRGB; converting them reads
   different values for the same colour.

## Code Connect

1. **What works on the Professional plan.** Mappings made in the Figma app (Dev Mode →
   Connect to code, through the GitHub app link) attach a Swift file to a component.
   `ArtworkImage`, `ArtworkShelfItem`, `tvOS/CircleActionButton`, `tvOS/FailedShelfNotice`
   and `tvOS/GlassCapsuleButton` (as `ThemedGlassButtonStyle`) are mapped this way. These show the file and component name only — no snippet.
2. **What doesn't.** Mappings can't be written over MCP (`add_code_connect_map` refuses: "only
   … Organization or Enterprise plans", re-checked 2026-11-13), and templates — the only way
   to get a real `CircleActionButton(…)` snippet — need the same plans.
3. **Reading** mappings over MCP (`get_code_connect_map`) works.
4. **Still to map in the app:** `tvOS/CastCard`, `tvOS/GenreShelfItem`, `tvOS/ContentShelf`, `GhostBlock`, `GhostCard`,
   `SkeletonShelf`, `tvOS/PlainFocusButton`, `MetadataLabelStyle` and `ComponentPlaceholder`.
   Each description's GitHub link names the file to pick.

## Descriptions, specs and annotations

| Channel | Holds | MCP access |
|---|---|---|
| Description | Short summary per component | Write `descriptionMarkdown`; Figma derives the plain `description`. Writing `description` directly double-escapes apostrophes (`&amp;#39;`). |
| Spec | Long-form Markdown: mappings, deviations, foundations such as glass | `figma.spec.createOnCanvasAsync({ title, content })` → `{ specNodeId }`; `getContent({ specNodeId })` returns `markdown` (paged); `setContent({ specNodeId, content })` replaces it |
| Annotation | A note pinned to one node that nothing else can hold | `node.annotations`, with `labelMarkdown` |

Specs render only in the app; MCP screenshots show a placeholder. `setContent` diffs tables in
place and refuses a rewrite that changes their columns ("ambiguous table column
correspondence"); set plain text first, then the new content. In descriptions, bold each
code span on its own: Figma stores spaces inside a bold run of several code spans as `&#32;`.
