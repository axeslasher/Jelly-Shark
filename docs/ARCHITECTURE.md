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
- Base components: `ArtworkImage` (themed `AsyncImage` wrapper), `ContentShelf`, `ArtworkShelfItem`, `CastCard`, `CircleActionButton`, `MetadataLabelStyle`, a `glassButtonStyle()` modifier, a `BlurHash` decoder, and `ComponentPlaceholder`. (A reusable component library exists; the configurable *variant* system in DESIGN_SYSTEM.md does not yet.)

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

`Jelly Shark` is a **single app target** (`Jelly_SharkApp.swift`) that builds for both tvOS and visionOS. It configures `URLCache.shared` (16MB memory / 256MB disk) for artwork in `init()` and presents `RootView` in a `WindowGroup`. The template `Item` SwiftData model and `ContentView` have been removed — there is no `ModelContainer`.

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

**Current (implemented)**:
- **Keychain** (`SessionStore` / `KeychainStore`): the access token, server URL, and user ID are persisted as a `SavedSession`, plus a stable per-install device ID. This is the only persistent state today. Sessions are restored and re-validated on launch.
- **UserDefaults**: the selected theme identifier (via `ThemeManager`).
- **URLCache**: artwork images (configured on `URLCache.shared` in the app's `init()`).

**Planned (not yet adopted)**:
- **SwiftData** for local caching of watch history/progress, favorites/collections, media metadata, and library structure. The tech stack lists SwiftData as the intended persistence layer, but no `import SwiftData` exists in the codebase yet.

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
**Persistence**: Keychain (session) + URLCache (artwork) today; SwiftData planned  
**Testing**: Swift Testing  
**Dependency Management**: Swift Package Manager  
**Minimum Deployments**: 
- tvOS 26.0+
- visionOS 26.2+

---

## Testing Strategy

**Unit Tests**: JellyfinKit, business logic, view models  
**Integration Tests**: API client against mock/test Jellyfin server  
**UI Tests**: Critical user flows on both platforms  
**Manual Testing**: Focus navigation, spatial interactions, playback

---

## Build & Release

**Development**: Xcode 26.0+  
**CI/CD**: TBD (GitHub Actions likely)  
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
5. **Persistence**: when to adopt SwiftData, and what to cache first (metadata vs. user state)?

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
| 2025-01 | Keychain-only persistence for now | Ship the core loop first; defer SwiftData metadata caching |
| 2025-01 | Single shared app target for tvOS + visionOS | Maximize shared SwiftUI; add platform-specific code via `#if os(...)` as needed |
| 2026-07-25 | Min deployment visionOS **26.2** (tvOS stays 26.0) | `XROS_DEPLOYMENT_TARGET = 26.2` has been in the pbxproj since the initial commit, arriving as an Xcode default at project creation rather than as a choice anyone made, while every document and manifest said 26.0. Ratified at 26.2 rather than lowered: no shipping code uses a 26.1/26.2-only API, so this is not a technical requirement — it is a deliberate call that Vision Pro is a secondary platform with no spatial-specific work built yet, and that carrying a floor nobody has validated at 26.0 is not worth the compatibility surface. **This narrows the installable base: visionOS 26.0 and 26.1 devices are excluded.** Revisit if visionOS becomes a primary target. Manifests express it as `.visionOS("26.2")` — the string form — because `SupportedPlatform.VisionOSVersion` only offers major-version granularity (`.v26`). |
| 2026-07-25 | **MIT license**, not Apache 2.0 | The repo asserted Apache 2.0 in four documents while carrying no `LICENSE` file at all, which meant the work was under exclusive copyright regardless of what the README said. Resolved toward MIT rather than the Apache the docs named. The goals are wide reuse — the packages are intended for SPM once they mature — with attribution as the only ask, and that ask is loosely held. MIT delivers exactly that in twenty lines. Apache 2.0's additions are an explicit patent grant, §4(b) change notices, and `NOTICE` propagation: real features, but they impose obligations on forkers in exchange for protections a solo project with no patent portfolio does not need. MIT also dominates the Swift ecosystem (including two of this project's own dependencies), so it is the lowest-friction choice for downstream adoption. Noted for the record: no permissive license compels *visible* credit — both MIT and Apache only require the notice ship with the source, so a fork may rebrand freely. Visible attribution is a README request, not a license term. |
| 2026-07-25 | No per-file license headers | Apache projects conventionally carry them; MIT projects conventionally do not. Skipped deliberately rather than by omission — a header on all 150 Swift files is a large permanent diff and a standing chore for every new file, buying nothing MIT's root `LICENSE` does not already establish. Third-party terms live in `THIRD-PARTY-NOTICES.md`; the one file-level obligation this repo actually carries is OFL 1.1's requirement that the license travel with the bundled Atkinson fonts, satisfied by `Resources/Fonts/OFL.txt`. |
