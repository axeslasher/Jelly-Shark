# Jelly Shark

A premium Jellyfin client for tvOS and Apple Vision Pro that doesn't look like a Jellyfin client.

## What is Jelly Shark?

Jelly Shark brings professional-grade UI design to the open-source media server ecosystem. Built by someone who designed TV interfaces for Starz, it proves that open-source doesn't mean ugly or clunky.

Unlike existing Jellyfin clients that treat the interface as functional but forgettable, Jelly Shark makes the UI itself a feature—beautiful, configurable, and tailored to how you want to experience your media library.

## Key Features

### Genre-Inspired Themes
Visual languages that evoke the mood of what you're watching. Horror libraries get atmospheric dread, not corporate blue.

- **Standard**: Elegant, timeless baseline—professional and unobtrusive, letting content shine
- **Horror**: Atmospheric dread and visceral intensity—slow, tension-building motion over blood-red accents
- **Action**: Kinetic energy and technological precision—fast, explosive motion with electric cyan highlights
- **Video Store**: 90s nostalgia, Friday night vibes—bouncy, playful motion in deep blue and gold
- **Sci-Fi**: Deep-space greens and engineered precision—slow, weightless motion with a phosphor glow

Each theme carries its own typeface, palette, spacing, and motion curve. Switch themes from Settings at runtime—no app restart required. The system is committed to dark surfaces throughout; there is no light mode.

### Professional 10-Foot UI
Designed specifically for the lean-back, living room experience—not adapted from mobile. The Home marquee, shelves, and library grids are built around the tvOS focus engine, so focus, paging, and scrolling answer to the remote instead of a scaled-up pointer layout.

### A Player That Fills In What Streaming Drops
Jellyfin's HLS output leaves the source file's chapters, metadata, and scrub previews behind. Jelly Shark reconstructs them: native trickplay seek previews, chapter markers, an in-player Cast & Crew tab, and correctly-timed subtitles on both the fMP4 and TS paths.

## Status

**In Active Development** — The core loop works end to end: connect to a Jellyfin server, browse libraries with artwork and metadata, and play items with progress tracking and resume.

**Working today:**
- **Server & session** — connect and sign in, then stay signed in; the token lives in the Keychain and is validated and restored on launch
- **Home** — a paged hero marquee, Continue Watching, Next Up (foldable into a single shelf from Settings), a Recently Added row per library, and Browse by genre
- **Libraries** — paginated poster grids with sort, genre, decade, rating, watched-status, and favorites-only filtering
- **Detail pages** — movies, series, episodes, and collections: hero artwork, metadata and overview, a season/episode shelf, Cast & Crew, More Like This, collection contents, and Go to Series from an episode
- **People** — person pages with filmography
- **Search** — debounced live search across movies, shows, and episodes, with completion suggestions and a result grid
- **Playback** — direct play of compatible files with HLS remux/transcode fallback and true PlayMethod reporting; trickplay scrub previews; chapter markers (tvOS); audio and subtitle switching, including burned-in image subtitles; a Cast & Crew tab in the player; progress reporting, resume, and episode autoplay with an "Up Next" countdown
- **Watched & favorites** — optimistic toggles on media and person detail
- **Design system** — five themes on a Tailwind-derived color token layer, plus a bounded decoded-artwork cache, wired throughout the app

## Roadmap

Not built yet—listed here so nothing above reads as a promise:

- **Hand-curated palettes** for Horror, Action, Video Store, and Sci-Fi. The themes are live and contrast-tested, but their colors are still first-pass picks from the Tailwind base palette
- **Component variants** — swappable card, hero, navigation, and list-density layouts that stay within the chosen theme's aesthetic
- **Local metadata caching** (SwiftData). Only session tokens persist today; artwork rides `URLCache` plus an in-memory decoded-image cache
- **visionOS spatial experiences** — the app builds and runs on Vision Pro with the shared UI, but depth-aware and immersive layouts are not built
- **Top Shelf and Siri integration**

## Platform Support

- Apple TV 4K (tvOS 26.0+)
- Apple Vision Pro (visionOS 26.0+)

## Tech Stack

- Swift 6.2+
- SwiftUI
- AVKit / AVPlayer for direct play and HLS playback
- [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) (0.6.x) for the Jellyfin API
- Keychain for secure session storage; `URLCache` for artwork
- Swift Package Manager (modular: JellyfinKit, DesignSystem, Features)
- Swift Testing

## Building & Testing

Requires Xcode 26+. Everything runs through the `Makefile`:

```bash
make build            # build for the tvOS simulator
make build-visionos   # build for the visionOS simulator
```

Tests run in **two venues**, and a bare `xcodebuild test` covers only one of them:

- **Simulator** (`make test-sim`) — the app suite plus `DesignSystemTests` and `FeaturesTests`. Those packages use tvOS/visionOS-only SwiftUI APIs and no longer compile for the Mac host, so their test targets are wired into the `Jelly Shark` scheme.
- **Host** (`make test-host`) — `JellyfinKit`, via `swift test`. It's pure logic, but its Keychain and session tests need a real keychain, which a host-less simulator test bundle doesn't have.

Pick the cheapest tier that can fail on your change (timings are warm; cold, anything touching the simulator costs minutes rather than seconds):

```bash
make test-host                        # ~5s  — JellyfinKit only, no simulator
make test-only ONLY=DesignSystemTests # ~23s — one simulator suite (also: FeaturesTests, "Jelly SharkTests")
make test-sim                         #        the simulator venue on its own
make test                             # ~43s — both venues; a pre-merge check, not an iteration step
```

Formatting is SwiftFormat, pinned to **0.62.1** (`brew install swiftformat`). The Makefile refuses any other version, so local output matches CI:

```bash
make format        # format all Swift sources in place
make lint          # check only, no rewrites
make install-hooks # one-time opt-in: a lint-only pre-commit hook
```

CI runs the host suite, the tvOS simulator suite, and a visionOS build on every pull request (`.github/workflows/tests.yml`), plus `swiftformat --lint` with the same pinned version (`.github/workflows/swiftformat.yml`).

One gotcha for a fresh clone: most of the themes' typefaces are licensed from Fontshare, whose EULA forbids redistributing the files, so the `.ttf`s are git-ignored. The app still builds and runs—every text style falls back to San Francisco. `Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/FONTS.md` lists what to download and where to put it.

## Contributing

This project is in early development, but issues and pull requests are welcome. Before opening one, run `make format` and the test tier that can fail on your change—CI runs both venues and the formatter on every PR. `CLAUDE.md` covers the module layout and the conventions the codebase follows; deeper design and API notes live in `docs/`.

## License

Apache 2.0

---

**Your media library, your style.**
