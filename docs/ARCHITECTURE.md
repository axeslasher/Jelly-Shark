# Architecture

## Overview

Jelly Shark is a multi-platform Jellyfin client for tvOS and visionOS, built with a modular architecture that prioritizes shared code while respecting platform-specific interaction paradigms.

## Core Principles

- **Modular from day one**: Clear separation of concerns via Swift Package Manager
- **Platform-aware, not platform-specific**: Shared business logic with platform-specific UI adaptations
- **Design system driven**: Components and theming as first-class architectural concerns
- **Server as source of truth**: Jellyfin server is the canonical data source; local storage is for caching and performance

## Module Structure

### JellyfinKit
**Purpose**: API client, networking, and data models

**Responsibilities**:
- Jellyfin API integration and authentication
- Network request handling
- Response parsing and error handling
- Data model definitions (Media, User, Library, etc.)
- Media streaming coordination
- Persistence: Keychain session storage and the SwiftData metadata/user-state cache (`Persistence/`)

**Dependencies**: Foundation, [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) (0.6.0), [Get](https://github.com/kean/Get) (declared `from: 2.1.6`, resolves to 2.2.1; used to inspect HTTP status codes for error mapping)

**Platform support**: Fully shared (tvOS, visionOS)

#### SDK Integration Architecture

JellyfinKit wraps the official `jellyfin-sdk-swift` package using a **Facade/Wrapper pattern**. This provides a clean, app-specific API while leveraging the official SDK for network requests and API compatibility.

```
┌─────────────────────────────────────────────────────────┐
│                  App (Features module)                   │
├─────────────────────────────────────────────────────────┤
│                   JellyfinKit (ours)                     │
│  ┌───────────────────────────────────────────────────┐  │
│  │  JellyfinClientProtocol                           │  │
│  │  - Clean, app-focused async API                   │  │
│  │  - Our domain types: User, MediaItem, Library     │  │
│  └──────────────────────┬────────────────────────────┘  │
│                         │ wraps                          │
│  ┌──────────────────────▼────────────────────────────┐  │
│  │           jellyfin-sdk-swift (official)           │  │
│  │  - JellyfinAPI.JellyfinClient                     │  │
│  │  - SDK types: BaseItemDto, UserDto, etc.          │  │
│  │  - Auto-generated from OpenAPI spec               │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

#### Why This Pattern?

**Benefits of wrapping the SDK:**
1. **Clean API surface**: App code works with simple `User`, `MediaItem`, `Library` types instead of verbose SDK DTOs
2. **Isolation from SDK changes**: SDK updates don't ripple through the entire app
3. **Testability**: `JellyfinClientProtocol` enables easy mocking for unit tests
4. **Curated functionality**: Only expose methods the app actually needs
5. **Computed conveniences**: Add `formattedRuntime`, `progressPercentage`, etc. on our types

**What the SDK provides:**
- Auto-generated API coverage matching Jellyfin server OpenAPI spec
- Proper authentication header handling
- Type-safe request/response handling
- Maintained by the Jellyfin team

#### Adapter Layer

The `Adapters/` folder maps SDK types to our domain types. `SDKAdapters.swift` holds most of the mappings — not just the three shown below but also `Person`, `CastMember` (via `people`), `ImageTags`, `UserData`, `MediaTechnicalInfo`, `ParentArtwork`, `MediaType`, and `CollectionType`; `PlaybackAdapters.swift` maps the playback-info/media-source DTOs. Representative example:

```swift
// SDK type → Our type
extension User {
    init(from dto: JellyfinAPI.UserDto) { ... }
}

extension MediaItem {
    init(from dto: JellyfinAPI.BaseItemDto) { ... }
}

extension Library {
    init(from dto: JellyfinAPI.BaseItemDto) { ... }
}
```

This adapter pattern keeps mapping logic centralized and testable.

---

### DesignSystem
**Purpose**: Theming engine, design tokens, and base UI components

**Responsibilities**:
- Design token definitions (color, typography, spacing, motion)
- Theme management and switching
- Base SwiftUI components with variant support
- Platform-specific adaptations (focus states, spatial layout)
- Accessibility support

**Dependencies**: SwiftUI (no external dependencies)

**Platform support**: Shared with platform-specific variants

**Key concepts**:
- Themes as data via a `Theme` protocol, switched at runtime by `ThemeManager` (`@Observable` singleton, persisted to `UserDefaults`)
- Design tokens: `BaseColors` (the Tailwind CSS v4 palette, oklch → extended linear sRGB via `Color(oklch:)`), `TypographyTokens`, `SpacingTokens`, `MotionTokens`
- Base components: `ArtworkImage` (backed by `ArtworkLoader`, a bounded decoded-image cache — not `AsyncImage`), `ContentShelf`, `ArtworkShelfItem`, `CastCard`, `CircleActionButton`, `MetadataLabelStyle`, a `glassButtonStyle()` modifier, a `BlurHash` decoder, and `ComponentPlaceholder`. (A reusable component library exists; the configurable *variant* system in DESIGN_SYSTEM.md does not yet.)

**Current state**: All five themes are implemented (`StandardTheme`, `HorrorTheme`, `ActionTheme`, `VideoStoreTheme`, `SciFiTheme`) with per-theme fonts and motion; the three genre palettes are first-pass `BaseColors` picks pending hand curation, guarded by WCAG contrast tests. The component-variant system (poster-dominant, landscape, etc.) is documented in DESIGN_SYSTEM.md but not yet built.

---

### Features
**Purpose**: Application features, screens, and user flows

**Responsibilities**:
- View implementations (library browsing, media detail, playback)
- View models and state management
- Navigation coordination
- Feature-specific business logic

**Dependencies**: JellyfinKit, DesignSystem, SwiftUI

**Platform support**: Some shared, some platform-specific (`#if os(tvOS)` guards for button styles, keyboard types, and the player view)

**Structure** (as implemented):
```
Features/
├── RootView.swift          (.sidebarAdaptable TabView: Home, a tab per library, Search, Settings)
├── AppSession.swift        (app-level session/client state)
├── HomePreferences.swift   (persisted home-screen preferences)
├── Features.swift          (module stub — imports only)
├── Artwork/                (MediaArtwork image-URL helpers, TrimmedLogoImage)
├── Genre/                  (GenreShelvesView + GenreShelvesViewModel, GenreCardView + GenreCardViewModel, GenreBackdropStore)
├── Home/                   (HomeView + HomeViewModel, hero backdrop/motion/section, shelves section, placeholders)
├── Library/                (LibraryItemsView + LibraryItemsViewModel, LibraryFilterBar, GenreFilter, LibraryQueryDisplay, PosterGridLayout)
├── MediaDetail/            (MediaDetailView + MediaDetailViewModel, hero/episodes/shelves/credits sections)
├── PersonDetail/           (PersonDetailView + PersonDetailViewModel, PersonDetailHeader, PersonDetailShelves)
├── Playback/               (PlaybackContainerView, PlayerViewController, PlaybackViewModel, PlaybackLocalServer, UpNextOverlayView, audio/subtitle option matchers)
├── Search/                 (SearchView + SearchViewModel — debounced search UI)
└── Settings/               (SettingsView, ServerConnectionView, ServerConnectionViewModel)
```
Authentication is not a separate folder — server connection lives under `Settings/`.

---

### App Target
**Purpose**: Shared SwiftUI entry point and configuration

`Jelly Shark` is a **single app target** (`Jelly_SharkApp.swift`) that builds for both tvOS and visionOS. It does three things: creates the persistent `MediaCacheStore` (as a `let` on the `App` struct, because `App` is instantiated once per process while `RootView.init` re-runs on every body evaluation and each `makePersistent()` opens the store files), configures `URLCache.shared` (16MB memory / 256MB disk) for artwork in `init()`, and presents `RootView(cache:)` in a `WindowGroup` under `.preferredColorScheme(.dark)`. The template `Item` model and `ContentView` have been removed; the only `ModelContainer` in the project is the one `MediaCacheStore` owns.

**Current state**:
- tvOS: focus-driven `TabView` navigation, remote-friendly controls, AVPlayer transport-bar menus for audio/subtitle selection
- visionOS: runs via the shared SwiftUI views; no spatial/immersive-specific code yet (`#if os(visionOS)` only appears for a device-name string)

**Planned**: Top Shelf extension, Siri integration, visionOS spatial layouts and immersive playback.

---

## Data Flow

```
User Interaction
    ↓
Feature Views (SwiftUI)
    ↓
View Models (@Observable @MainActor)
    ↓
JellyfinKit (JellyfinClientProtocol)
    ↓
jellyfin-sdk-swift
    ↓
Jellyfin Server
```

**Every screen has a view model.** The `@Observable @MainActor` layer above is applied throughout — `ServerConnectionViewModel`, `HomeViewModel`, `LibraryItemsViewModel`, `MediaDetailViewModel`, `PersonDetailViewModel`, `SearchViewModel`, and `PlaybackViewModel`, plus `GenreShelvesViewModel` / `GenreCardViewModel` behind the genre shelves. Each has a Swift Testing suite in `FeaturesTests`; the server-backed ones drive it through `MockJellyfinClient`. Views keep only presentation state — server fetches and the optimistic played/favorite toggles live in the view models. The app-level `AppSession` and `HomePreferences` use the same `@Observable @MainActor` shape. Extracting the last three (Home, MediaDetail, PersonDetail) was tracked as test debt in issue #26, now closed by PR #103.

### Persistence Strategy

Four mechanisms, all implemented:

- **Keychain** (`SessionStore` / `KeychainStore`): the access token, server URL, and user ID as a `SavedSession`, plus a stable per-install device ID. Sessions are restored and re-validated on launch. Tokens live here and nowhere else.
- **UserDefaults**: the selected theme identifier (via `ThemeManager`) and the cache's schema-version marker.
- **URLCache**: artwork images (configured on `URLCache.shared` in the app's `init()`).
- **SwiftData** (`Persistence/Cache/`): the cold-start metadata and user-state cache, added 2026-07-30 for issue #24.

#### The SwiftData cache

`MediaCacheStore` is a `@ModelActor` — an actor, not `@MainActor`, so the write fan-out after a load (a multi-hundred-KB blob plus user-state upserts for ~100 items) never competes with the focus engine on the main thread. Two `@Model` types back it: `CachedSnapshot` (a Codable blob keyed by scope + entry) and `CachedUserState` (played / favorite / resume position as the server last reported them).

**Scoping is a privacy boundary, not an optimization.** Every row is keyed by a `CacheScope` — one Jellyfin user on one server, with the server URL normalized (host case, default ports, trailing slashes) so cosmetic address variants share a scope instead of fragmenting it. Sign-out purges exactly one scope; saved profiles (#192) get one scope each. Two users can never read each other's rows.

**Writes go through one choke point.** `CachingJellyfinClient` is a write-through decorator over any `JellyfinClientProtocol`, so persistence lives in one file instead of a dozen forgettable call sites in view models. It persists `.currentUser`, `.libraries`, `.mediaDetail`, `.genreBackdrops`, and `.libraryFirstPage` (page 0 of the *default* query only — filtered, re-sorted, and follow-up pages are never cached), plus server-acknowledged user state after a mark-played or favorite toggle. Playback URLs, transcoding decisions, and auth tokens pass straight through untouched, per CLAUDE.md.

**No migrations, by design.** `MediaCacheStore.schemaVersion` covers the `@Model` shapes, the Codable payload encodings, *and* the key formats; any mismatch — or any store the current code cannot open — deletes the store files and starts empty. The server rebuilds the contents, so migration machinery would be preserving data that is free to re-fetch. The store lives under `Caches/` on purpose: tvOS treats bulk local storage as evictable, and eviction is semantically fine here.

**Every failure degrades to a cache miss.** Reads, writes, saves, and store-file deletion all swallow errors; an undecodable row is deleted so it cannot fail twice; an unusable directory drops the store to in-memory rather than taking the app down. A cache that can break media browsing is worse than no cache. The cost of that posture is diagnostic silence — a persistently broken store disables caching indefinitely with no signal.

**CloudKit**: Not currently planned. Server is source of truth. May add for cross-device preference sync later.

---

## Platform Adaptations

### What Shares (90%+)
- API client and networking
- Data models
- Business logic
- Design tokens
- Base component implementations
- Authentication flows

### What Diverges
- Navigation patterns (TabView vs WindowGroup/Ornaments)
- Input handling (remote vs hands/eyes)
- Focus management (tvOS focus engine vs visionOS spatial)
- Layout for depth/immersion (visionOS)
- Top Shelf vs Home View experiences

### Adaptation Strategy
Platform differences handled through:
1. Compiler directives (`#if os(tvOS)`)
2. Protocol-based abstractions
3. Theme system variants
4. Dependency injection where beneficial

Preference: Keep components platform-agnostic when possible, use injection over conditionals.

---

## Tech Stack

**Language**: Swift 6.2+  
**UI Framework**: SwiftUI  
**Networking**: jellyfin-sdk-swift (0.6.0), built on Get/URLSession  
**Playback**: AVKit / AVPlayer (HLS transcode streaming)  
**Persistence**: Keychain (session) + SwiftData (metadata/user-state cache) + URLCache (artwork) + UserDefaults (theme)  
**Testing**: Swift Testing  
**Dependency Management**: Swift Package Manager  
**Minimum Deployments**: 
- tvOS 26.0+
- visionOS 26.2+

---

## Testing Strategy

Two venues, both run by `.github/workflows/tests.yml` on every PR. `make test-host` runs JellyfinKit alone via `swift test` (~5s, no simulator — the inner-loop tier); `make test-sim` runs the DesignSystem, Features, app, and UI suites on a tvOS simulator, because those targets reference tvOS/visionOS-only SwiftUI APIs and no longer compile for the Mac host. See CLAUDE.md § Building & Running for the full tier table.

**Unit tests (implemented)**: ~291 in JellyfinKit, ~416 in Features, ~47 in DesignSystem. Coverage is deep on cancellation races, stale async responses, cache corruption and scope isolation, remux edge cases, playback serialization, and optimistic user-state reconciliation. Server-backed paths run through `MockJellyfinClient`.

**UI tests (thin, deliberately)**: one tvOS launch smoke test asserting the tab navigation renders. The app target's unit suite is still an Xcode template stub. This is the known gap — authentication through the UI, tab/navigation-path behavior, filtering, and playback presentation have no automated coverage.

**What no suite here can verify**: visual appearance and tvOS focus behavior. CLAUDE.md § "What tests cannot verify" documents why probe tests, print-based harnesses, and simulator UI automation have each been tried and abandoned for these. Verification is a device check.

**Manual testing**: focus navigation, spatial interactions, playback — on real hardware, against a live server.

---

## Build & Release

**Development**: Xcode 26.0+  
**CI**: GitHub Actions on every push and PR — `tests.yml` (`host`: JellyfinKit via `swift test`; `simulator`: tvOS build + DesignSystem/Features/app/UI suites; `visionos`: build only) and `swiftformat.yml` (`lint`: `swiftformat --lint`, SwiftFormat pinned to 0.62.1). The macOS jobs run on `macos-26`, which pins Xcode to a 26.x — local Xcode betas can mask manifest and build errors CI will catch, so verify with an explicit `DEVELOPER_DIR` before trusting a green local run.  
**CD**: not set up.  
**Distribution**: TestFlight, then App Store  
**Open Source**: MIT license

---

## Future Considerations

**Potential modules to extract**:
- Analytics/Telemetry (if added)
- Offline downloads management
- Custom video player controls
- Top Shelf/Home View extensions

**Performance considerations**:
- Image caching strategy
- List virtualization for large libraries
- Background fetch for metadata updates
- Memory management during media playback

**Accessibility**:
- VoiceOver support
- Dynamic type
- Reduce motion
- High contrast themes

---

## Open Questions

1. ~~**Networking layer**: Native URLSession vs Alamofire?~~ → Resolved: Using official `jellyfin-sdk-swift` SDK
2. ~~**Navigation architecture**: Coordinator pattern or SwiftUI native?~~ → Resolved: SwiftUI-native `.sidebarAdaptable` `TabView` with a dynamic tab per library; `RootView` owns one value-based `NavigationPath` per tab and registers `MediaItem`/`CastMember` destinations at each root
3. ~~**State management**: Observable macros vs manual publishers?~~ → Resolved: `@Observable` macro (`AppSession`, `ServerConnectionViewModel`, `PlaybackViewModel`, `ThemeManager`)
4. **Video player**: stick with AVPlayer or add VLCKit for broader codec support? → Currently AVPlayer + HLS transcode only
5. ~~**Persistence**: when to adopt SwiftData, and what to cache first (metadata vs. user state)?~~ → Resolved 2026-07-30 (#24): both, behind one write-through decorator. See Persistence Strategy above.
6. **Accessibility**: what is the release bar? VoiceOver labels are sparse (5 explicit modifiers across Features + DesignSystem) and typography is fixed-size by design. Fixed type is defensible for a 10-foot tvOS UI; it is a weaker argument on visionOS.
7. **Orchestration size**: `PlaybackViewModel` (~1,650 lines) and `JellyfinClient` (~1,530) own a lot. Decomposition is deferred rather than rejected — the playback path is device-verified and the automated suites cannot see the behavior a refactor would risk.

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2025-01-06 | Multi-platform from start | UI paradigms overlap significantly between tvOS/visionOS |
| 2025-01-06 | Modular architecture via SPM | Clear boundaries, reusable design system |
| 2025-01-06 | SwiftData for persistence | Modern, type-safe, integrates well with SwiftUI |
| 2025-01-06 | Design system as first-class module | Core differentiator of the app |
| 2025-01-07 | Min deployment tvOS/visionOS 26.0 | Target latest features, smaller user base acceptable for v1 — *superseded 2026-07-25 for visionOS, see below* |
| 2025-01-07 | Start with established video player libs | Don't reinvent playback; focus on UI/UX differentiation |
| 2025-01-07 | Runtime theme switching | User control is core to customization philosophy |
| 2025-01-08 | Adopt jellyfin-sdk-swift with wrapper | Official SDK provides API coverage; wrapper pattern gives clean app-facing types |
| 2025-01 | SwiftUI-native navigation (`.sidebarAdaptable` `TabView` + per-tab `NavigationPath`) | Avoid coordinator overhead for a small, tab-based app |
| 2025-01 | `@Observable` for all view models and session state | Modern Observation framework integrates cleanly with SwiftUI |
| 2025-01 | AVPlayer + HLS transcode for playback | Native, no third-party player dependency; server handles transcoding |
| 2025-01 | Keychain-only persistence for now | Ship the core loop first; defer SwiftData metadata caching — *superseded 2026-07-30, see below* |
| 2025-01 | Single shared app target for tvOS + visionOS | Maximize shared SwiftUI; add platform-specific code via `#if os(...)` as needed |
| 2026-07-25 | Min deployment visionOS **26.2** (tvOS stays 26.0) | `XROS_DEPLOYMENT_TARGET = 26.2` has been in the pbxproj since the initial commit, arriving as an Xcode default at project creation rather than as a choice anyone made, while every document and manifest said 26.0. Ratified at 26.2 rather than lowered: no shipping code uses a 26.1/26.2-only API, so this is not a technical requirement — it is a deliberate call that Vision Pro is a secondary platform with no spatial-specific work built yet, and that carrying a floor nobody has validated at 26.0 is not worth the compatibility surface. **This narrows the installable base: visionOS 26.0 and 26.1 devices are excluded.** Revisit if visionOS becomes a primary target. Manifests express it as `.visionOS("26.2")` — the string form — because `SupportedPlatform.VisionOSVersion` only offers major-version granularity (`.v26`). |
| 2026-07-25 | **MIT license**, not Apache 2.0 | The repo asserted Apache 2.0 in four documents while carrying no `LICENSE` file at all, which meant the work was under exclusive copyright regardless of what the README said. Resolved toward MIT rather than the Apache the docs named. The goals are wide reuse — the packages are intended for SPM once they mature — with attribution as the only ask, and that ask is loosely held. MIT delivers exactly that in twenty lines. Apache 2.0's additions are an explicit patent grant, §4(b) change notices, and `NOTICE` propagation: real features, but they impose obligations on forkers in exchange for protections a solo project with no patent portfolio does not need. MIT also dominates the Swift ecosystem (including two of this project's own dependencies), so it is the lowest-friction choice for downstream adoption. Noted for the record: no permissive license compels *visible* credit — both MIT and Apache only require the notice ship with the source, so a fork may rebrand freely. Visible attribution is a README request, not a license term. |
| 2026-07-25 | No per-file license headers | Apache projects conventionally carry them; MIT projects conventionally do not. Skipped deliberately rather than by omission — a header on all 150 Swift files is a large permanent diff and a standing chore for every new file, buying nothing MIT's root `LICENSE` does not already establish. Third-party terms live in `THIRD-PARTY-NOTICES.md`; the one file-level obligation this repo actually carries is OFL 1.1's requirement that the license travel with the bundled Atkinson fonts, satisfied by `Resources/Fonts/OFL.txt`. |
| 2026-07-30 | **Binary dependencies live in their own `Packages/` sibling. `JellyfinKit` and `Features` may never declare a `binaryTarget`.** | Settled once for #176 (FFmpeg), #177 (libass) and #60 (VLCKit/mpv) rather than re-argued per dependency; there are zero binary dependencies today, so this is cheap now and expensive to retrofit. The shape #177 proposed was an *optional SPM product* inside `Features` — a second `.library` the app opts into and downstream clients decline. That works at **link** time but not at **resolve** time: SwiftPM reads the entire manifest and fetches `binaryTarget` `url:` artifacts before it knows which products will be built, and whether it prunes artifacts belonging to unselected products has varied across SwiftPM releases. It is not something a manifest can assert. A client wanting nothing to do with libass would still pay the download on every clean checkout and could not tell from reading the manifest. **Package-level separation is the only isolation SPM guarantees** — a consumer who never writes `.package(path: "../PlaybackASS")` never resolves it — and it keeps `grep binaryTarget Packages/*/Package.swift` an authoritative answer to "what am I obligated to?". Two repo-specific reinforcements: `JellyfinKit` declares `.macOS(.v13)` so its Keychain/session suites run host-side under `make test-host` (the ~5s inner-loop tier), and an xcframework with no macOS slice breaks that tier outright; and a binary inside `Features` would make an artifact download a precondition of the `FeaturesTests` simulator suite, which has nothing to do with playback. **Dependency direction is inverted:** `Features` declares the protocol (`SubtitleRenderer`, `RemuxEngine`, …), the binary-backed package depends on `Features` and conforms, and the app target is the only place the two meet. Precedent for the shape: `DesignSystem` already bundles git-ignored Fontshare `.ttf` files and degrades honestly to the system font when they are absent. **Verified 2026-07-30**, not assumed: a throwaway package built outside the repo — its own manifest, a two-slice (`tvos-arm64`, `tvos-arm64-simulator`) `.binaryTarget` xcframework, `.package(path:)` on `Features`, and a target calling into both — built clean for `generic/platform=tvOS` with zero errors under Xcode 26.6 (AppleTVOS26.5, matching CI) and Xcode 27 beta (AppleTVOS27.0). The scaffold was deleted rather than committed; the value was the measurement, not a permanent example package. **One prerequisite surfaced:** the engine seam such a package would conform to is module-internal. `PlayerEngine`, `PlayerEngineEvent`, `PlayerSessionMetadata`, `DeliveryProgress`, `PlaybackTransportStatus`, `AudibleOption` and `LegibleOption` are all `internal` to `Features`, so an external package can link `Features` today but cannot yet implement a playback extension point. `PlaybackCapabilities` is already `public` and already lives in `JellyfinKit`, so the capability-declaration half is done. Publishing the remainder is **#199**, and is a prerequisite for any binary-backed engine or renderer rather than a task of this policy. (First written as belonging to #85; that was wrong. #85's scope was "so `PlaybackViewModel` is engine-agnostic", which an internal protocol with an internal implementation satisfies completely — it closed correctly on 2026-07-29 via PR #180. Engine-agnostic *within the module* and conformable *from another package* are different properties, and only the first was ever in scope.) |
| 2026-07-30 | License bar: permissive **plus LGPL with static linking permitted**. GPL and FFmpeg `--enable-nonfree` are excluded outright. | A permissive-only bar was considered and rejected as *stricter than the tree already is* — `jellyfin-sdk-swift` is MPL 2.0, a file-level copyleft this repo already reasons about correctly in `THIRD-PARTY-NOTICES.md`. Permissive-only would also exclude fribidi (LGPL-2.1+), which in practice excludes libass, deciding #177 by side effect rather than on merit. The usual reason projects refuse static LGPL is §6(a): you must supply whatever a user needs to relink the app against a modified library, which for a closed-source app means publishing object files. **Jelly Shark is MIT and public, so that obligation is already discharged by the repository existing** — anyone can clone, swap the library and rebuild. Static linking is therefore legally cheaper here than for almost any other App Store app, and avoids the launch-time cost of embedded dynamic frameworks on tvOS. Residual risk is not Apple's review but the historical VLC-on-the-App-Store dispute, where a *copyright holder* argued Apple's usage rules impose restrictions LGPL forbids; VideoLAN relicensed the core to LGPL to end exactly that, and Swiftfin ships VLCKit on the App Store today. GPL is excluded because it would relicense the whole application; `--enable-nonfree` FFmpeg builds are excluded because they are not redistributable at all. **Per-candidate terms are verified against the source at the pinned version, never assumed from convention** — the claims to check are libass (ISC), harfbuzz (Old MIT), freetype (dual FTL/GPLv2 — elect FTL, which adds a documentation-credit obligation), fribidi (LGPL-2.1+), FFmpeg (LGPL-2.1+ only while `--enable-gpl` stays off). |
| 2026-07-30 | Binaries arrive as `.binaryTarget(url:checksum:)`. In-repo builds are permitted only where the configure flags *are* the license claim. An `.xcframework` is never committed to git. | A checksummed upstream artifact is reproducible, pinned in the manifest, verified by CI for free, and leaves nothing in git history. The exception exists because for FFmpeg the license is a build-time property: a demux/mux-only configuration with `--disable-gpl` is LGPL, and an off-the-shelf artifact built by someone else may not be. Where that is the case, the build script lives in-repo, the artifact is published to this project's own Releases, and **the configure flags are recorded in `THIRD-PARTY-NOTICES.md`, because they are what makes the license claim true**. #60 already flagged hand-built binaries as a standing maintenance burden, so this stays the exception rather than the default. Committing an xcframework is refused in all cases: tens of MB in history forever, no provenance trail, and it is the only one of the three that cannot be undone. CI note: a manifest that resolves locally under an Xcode beta is not evidence it resolves on CI's release Xcode — verify binary-target resolution with an explicit `DEVELOPER_DIR` before trusting a green local run. |
| 2026-07-30 | Soft ceiling of **15 MB added arm64 binary weight**; exceeding it requires an exception logged here. | Turns #176's prose contrast — "a few MB" for a demux-only FFmpeg versus "tens of MB" for MPVKit's full stack — into a check rather than an argument. tvOS's 4 GB bundle cap is not the binding constraint; install time and the premium-client positioning are. The line is drawn where it admits a demux-only FFmpeg (~3–6 MB) and the libass stack (~2–4 MB) while excluding VLCKit and MPVKit. **This does not pre-decide #60.** An alternate playback engine is explicitly exception-eligible: the spike is expected to argue its weight against what it buys, and if adopted, the exception is recorded as a row here rather than treated as a policy violation. A ceiling set low enough to reject #60 silently would defeat the purpose of running the spike. |
| 2026-07-30 | A binary may **feed** AVFoundation freely; a binary that **replaces** its decode/render/output path requires an exception on capability grounds, independent of size. | The size ceiling above is a proxy for this rule, and proxies drift. VLCKit and MPVKit are large *because* they carry a render path, so today the two rules catch the same cases — but a lean alternate engine would clear the ceiling on a technicality while still costing the thing the app exists to deliver. On tvOS, **Dolby Vision output and object audio are reachable only through AVFoundation**: DV metadata reaches the display only from an AVPlayer-fed asset — the same stream decoded via VideoToolbox and drawn into a Metal layer does not carry it — and Atmos survives only as an encoded bitstream handed to the system audio path, so an engine that decodes to PCM has already lost it. (Frame-rate and dynamic-range matching are *not* exclusive: `AVDisplayManager.preferredDisplayCriteria` is public, so any engine can do Match Content. Worth stating, because it is the piece usually assumed exclusive.) The same asymmetry covers the compatibility half of the product goal: an Apple TV 4K feeding an SDR 1080p panel gets HDR→SDR tone mapping from the system for free, and a replacement engine must rebuild it — which is what libplacebo and MoltenVK *are*, and where MPVKit's tens of MB actually go. So binaries that **feed** the path are additive and bounded only by the license, sourcing and size rules above: demux (#176), remux, subtitle rasterization (#177). Both of those also *reduce* server-side work, which serves the weak/unaccelerated-server case as a side effect. A **replacement** engine (#60) is subtractive by construction and must state explicitly what it forfeits. This does not close #60 — it reframes it from "should we switch engines" to "is long-tail codec coverage worth carrying a second, capability-degraded output path", which is both more answerable and likely to land on a per-format fallback with AVPlayer keeping everything it can handle. |
| 2026-07-30 | Attribution has two surfaces: `THIRD-PARTY-NOTICES.md` stays hand-written; a structured list feeds the in-app credits. | Mechanical generation was considered and rejected for the notices file. Its value is precisely the part no generator produces — prose reasoning about why MPL 2.0 §3.3 does not reach this app's files, or which FFmpeg configure flags keep a build LGPL. At five entries, hand-maintenance is not the cost. The in-app surface has the opposite requirement: #29's About destination is scoped as a themed credits roll, which wants uniform structured rows (name, copyright, license, URL) at a steady cadence. So a small structured list feeds that, and the two coexist. Adding a binary dependency therefore has exactly two defined touch points. File-level obligations are satisfied the way OFL 1.1 already is for the Atkinson fonts — the license text ships *beside the binary it covers*, not merely referenced from the notices file, which is what FTL and LGPL both require. |
| 2026-07-30 | **SwiftData cache adopted (#24), scoped per user-on-server, with no migrations and every failure degrading to a miss.** Supersedes the 2025-01 "Keychain-only for now" row. | Three sub-decisions worth recording, because each had a plausible alternative. **(1) Scope is a privacy boundary, not a cache key.** Rows are keyed by normalized-server + user id, so sign-out purges exactly one scope and two profiles (#192) can never read each other's rows. Normalizing the URL (host case, default ports, trailing slash) prevents cosmetic address variants from fragmenting one user's cache into several. The alternative — a flat cache with a user column filtered at read time — makes correct purging a property of every call site instead of the storage layer. **(2) No migrations, ever.** `schemaVersion` covers `@Model` shapes, Codable payload encodings *and* key formats; any mismatch wipes the store. Migration machinery would be preserving data the server hands back for free, and a partial migration is a class of bug the wipe cannot have. The store lives under `Caches/` for the same reason: tvOS may evict it and that is semantically fine. **(3) Writes go through `CachingJellyfinClient`, a write-through decorator, not through view models.** One choke point means the "what is cached" list is a file you can read rather than a survey of a dozen call sites — and it is what keeps playback URLs, transcoding decisions and auth tokens out of the cache, which CLAUDE.md forbids. **Known cost, accepted:** every failure path degrades to a cache miss with no logging, so a persistently broken store disables caching silently. Correct user-facing posture, poor diagnostics. |
| 2026-08-02 | **#176's Matroska demuxer is written in Swift, in-repo. No `binaryTarget`, so the binary-dependency policy above does not engage and #199 is not a prerequisite for it.** | The 2026-07-30 rows settled *how* a binary dependency would be structured; this settles that #176 does not need one. Spiked against real sources before choosing (`docs/spikes/176-mkv-demux/`, deleted when the real demuxer lands): a read-only EBML/Matroska parser covering VINT primitives, SeekHead, Info, Tracks, Cues, Clusters, SimpleBlock and BlockGroup is **~380 lines of dependency-free Swift**, and the muxing half already exists in-repo as `TrickplayIFrameMuxer`. Three measurements made the choice rather than taste. **(1) `CodecPrivate` for `V_MPEGH/ISO/HEVC` *is* the `hvcC` payload** — byte-identical to what an fMP4 `hvc1` sample entry needs, so the sample-entry tag Jellyfin's progressive path gets wrong (`hev1`, see docs/PLAYBACK_MATRIX.md) is a copy, not a synthesis. **(2) Matroska stores HEVC as length-prefixed NALUs, not Annex B**, verified on two real sources — so video remux is a byte copy with no bitstream conversion, no decode and no re-encode. **(3) The `dvcC` ffmpeg refuses to write** (`Not writing 'dvcC'/'dvvC' box. Requires -strict unofficial.`) **arrives in the file** as a 24-byte `DOVIDecoderConfigurationRecord` under a `BlockAdditionMapping`. Validated over HTTP `Range` against both extremes of a real library — a 25 GB / 6-track DV profile 8.1 source and a 65 GB / 37-track profile 7 one — indexing each in **five requests and under 4 MB**, with cue offsets landing exactly on Cluster elements at 12.9 GB and 29 GB depth. This is the same `static=true` endpoint verified to serve `206` + `Content-Range`. Choosing Swift removes an M-sized blocker (#199), the LGPL configure-flag obligation, the `THIRD-PARTY-NOTICES.md` touch point, and the 15 MB weight question from #176's critical path, and puts the demuxer in `make test-host`'s ~5s tier because it is pure logic. Cost is ~800–1200 lines once lacing (all three modes occur in the wild — `none`, `fixed` *and* `EBML`), per-track keyframe determination (subtitles arrive as `BlockGroup` and must not be counted as video keyframes), and a refusal path for `Cues`-less files are added. **The policy above is unchanged and still governs #177 (libass) and #60 (VLCKit/mpv)** — this row narrows what it applies to, it does not amend it. |
