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

**Dependencies**: Foundation, [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) (0.6.0), [Get](https://github.com/kean/Get) (2.1.6, used to inspect HTTP status codes for error mapping)

**Platform support**: Fully shared (macOS for tests, tvOS, visionOS)

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

The `Adapters/SDKAdapters.swift` file contains extensions that map SDK types to our domain types:

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
- Design tokens: `ColorTokens`, `TypographyTokens`, `SpacingTokens`, `MotionTokens`
- Base components: `ArtworkImage` (themed `AsyncImage` wrapper), `ComponentPlaceholder`

**Current state**: Only `StandardTheme` is implemented. The Horror, Action, and Video Store identifiers exist (with color/motion tokens defined) but currently resolve to `StandardTheme`. The component-variant system (poster-dominant, landscape, etc.) is documented in DESIGN_SYSTEM.md but not yet built.

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
├── HomeView.swift
├── SearchView.swift        (debounced search UI)
├── AppSession.swift        (app-level session/client state)
├── Artwork/                (MediaArtwork: image-URL helpers)
├── Library/                (LibraryItemsView, LibraryItemsViewModel, LibraryFilterBar)
├── Search/                 (SearchViewModel)
├── MediaDetail/            (MediaDetailView + hero/episodes/shelves/credits sections — no view model yet)
├── PersonDetail/           (PersonDetailView, PersonDetailHeader, PersonDetailShelves — no view model yet)
├── Playback/               (PlaybackContainerView, PlayerViewController, PlaybackViewModel, UpNextOverlayView)
└── Settings/               (SettingsView, ServerConnectionView, ServerConnectionViewModel)
```
Authentication is not a separate folder — server connection lives under `Settings/`. `HomeView` also has no dedicated view model (see the Data Flow note above).

---

### App Target
**Purpose**: Shared SwiftUI entry point and configuration

`Jelly Shark` is a **single app target** (`Jelly_SharkApp.swift`) that builds for both tvOS and visionOS. It configures `URLCache.shared` (64MB memory / 256MB disk) for artwork in `init()` and presents `RootView` in a `WindowGroup`. The template `Item` SwiftData model and `ContentView` have been removed — there is no `ModelContainer`.

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

**View models are not universal yet.** The `@Observable @MainActor` view-model layer above is fully applied on four screens — `ServerConnectionViewModel`, `LibraryItemsViewModel`, `SearchViewModel`, and `PlaybackViewModel` (each with Swift Testing coverage via `MockJellyfinClient`) — plus the app-level `AppSession`. `HomeView`, `MediaDetailView`, and `PersonDetailView` currently hold their load/selection logic (and the optimistic played/favorite toggles) inline in the views, largely untested. Extracting view models for those three is tracked as test debt in issue #26.

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
- visionOS 26.0+
- (packages also declare macOS 15 to enable test runs)

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
**Open Source**: Apache 2.0 license (TBD)

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
| 2025-01-07 | Min deployment tvOS/visionOS 26.0 | Target latest features, smaller user base acceptable for v1 |
| 2025-01-07 | Start with established video player libs | Don't reinvent playback; focus on UI/UX differentiation |
| 2025-01-07 | Runtime theme switching | User control is core to customization philosophy |
| 2025-01-08 | Adopt jellyfin-sdk-swift with wrapper | Official SDK provides API coverage; wrapper pattern gives clean app-facing types |
| 2025-01 | SwiftUI-native navigation (`.sidebarAdaptable` `TabView` + per-tab `NavigationPath`) | Avoid coordinator overhead for a small, tab-based app |
| 2025-01 | `@Observable` for all view models and session state | Modern Observation framework integrates cleanly with SwiftUI |
| 2025-01 | AVPlayer + HLS transcode for playback | Native, no third-party player dependency; server handles transcoding |
| 2025-01 | Keychain-only persistence for now | Ship the core loop first; defer SwiftData metadata caching |
| 2025-01 | Single shared app target for tvOS + visionOS | Maximize shared SwiftUI; add platform-specific code via `#if os(...)` as needed |
