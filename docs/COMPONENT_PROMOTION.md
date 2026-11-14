# Component Promotion Audit

Promote five hand-rolled Features views into DesignSystem, one PR each, so they get theme previews, Figma components and Code Connect like the rest of the package. Tracked in [#377](https://github.com/axeslasher/Jelly-Shark/issues/377).

## Decision

A Features view moves to DesignSystem when it depends only on `Theme` and tokens (no JellyfinKit models, no view models) **and** either copies a DesignSystem recipe or is used on two or more screens. Model adapters such as `LiveChannelCard` (a thin `ArtworkShelfItem` wrapper over `LiveChannel`) stay in Features.

**Must**

| # | Promote | Evidence |
|---|---|---|
| 1 | `CircleNavigationLink` into `CircleActionButton` as a `value:` init | Private copy in `HomeHeroSection.swift`; its comment says "matches CircleActionButton", and it already uses DesignSystem's `hangingActionLabel` |
| 2 | A `CountBadge` view | `LibraryFilterBar` repeats `ArtworkShelfItem`'s count badge styling (`padding(xxs)`, 32 minimum, `theme.accent` circle); `ArtworkShelfItem` adds an outer `padding(xs)` corner inset, which stays at its call site; Figma has `base/countBadge` |
| 3 | A `ShelfHeader` view | `ContentShelf` and `FailedShelfNotice` inline the same icon + headline `HStack`; Figma has `base/shelfHeader` |
| 4 | `MediaMetadataRow` | 3 call sites on 3 screens (Home hero, Live guide, Media Detail hero); takes plain strings; built on `MetadataLabelStyle` |
| 5 | `OverviewLabel` with `OverviewOverlay` | Media Detail and Person Detail; theme-only; `OverviewLabel` is the label `plainFocusButtonStyle` exists for |

**Nice to have**

| # | Promote | Evidence |
|---|---|---|
| 1 | `GhostEpisodeCard` as an episode `GhostCard` | Private in `EpisodeShelfStack.swift`; the skeleton family has no episode ghost |
| 2 | `TrimmedLogoImage` beside `ArtworkImage` | Home and Media Detail heroes; fetches through `URLSession.shared`, not `ArtworkLoader` |
| 3 | `CreditEntry` | 2 files, Media Detail only today; promote when a second screen needs it |
| 4 | `MediaDetailHeroBackdrop` | Media Detail and Person Detail; screen-level, so lowest priority |
| 5 | `SettingsRowLabel`, `SelectionRowLabel` | One screen; same on-platter focus swap as `OverviewLabel`; wait for a second user |

**Clean up in Features (no promotion)**

1. `HomeSkeleton` keeps a private `skeletonShelf(…)` that nothing calls, plus a private `ghostBlock` that duplicates `GhostBlock`. Delete both.
2. `HeroExitDrift` is defined in both `HomeView.swift` and `MediaDetailView.swift`, differing only in the scroll-state type. Share one copy, generic over the scroll state. (`HeroBackdropBridge` is also defined in both, but each wraps a different backdrop with different inputs, so it stays.)

**Stay in Features:** `LiveChannelCard`, `OnAirNowShelf`, `EpisodeShelfStack`, `PersonDetailHeader`, `HomeHeroBackdrop` (paging is tied to `HomeViewModel`), `HomeEmptyState`, `ReconnectingBanner`, `CreditsColumn`, and the Live guide's private views.

## Evidence

1. **Verified by grep (2026-11-13):** call-site counts are real calls (`Name(`), not doc-comment mentions; the duplicate recipes and the dead `skeletonShelf` were read in source.
2. **Hypothesis (unverified):** that each promotion is a move with no visual change. No build was run for this audit.

## Acceptance criteria

1. Each Must item lands in its own PR: the view moves to `Packages/DesignSystem/Sources/DesignSystem/Components/`, public, with five-theme `#Preview` tabs; Features call sites use it; the old copy is deleted.
2. Each promoted view gets a Figma component, description and spec per `docs/FIGMA_COMPONENTS.md`, plus a map row and a Code Connect mapping.
3. `make test-only ONLY=DesignSystemTests` and `ONLY=FeaturesTests` pass by exit code; CI is green.
4. Item 1 states which elements stay focusable and where default focus lands, and gets a device check of the Home hero's circle buttons.
5. The two clean-ups are done; Nice-to-have items are optional and can move to their own issues.
