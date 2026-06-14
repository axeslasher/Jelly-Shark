# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Jelly Shark is a premium Jellyfin client for tvOS and visionOS that elevates the media browsing and playback experience through exceptional UI design and deep customization. Unlike existing Jellyfin clients, it treats the interface as a feature with genre-inspired theming and extensive component customization.

**Key Differentiators**:
- Genre-inspired theming system (Standard, Horror, Action, Video Store)
- Component variants with depth (different layouts work within any theme)
- Platform-native excellence (tvOS focus engine, visionOS spatial layouts)
- Professional 10-foot UI design for lean-back viewing
- Open source, community-driven (Apache 2.0)

**Target Platforms**:
- Apple TV 4K (tvOS 26.0+)
- Apple Vision Pro (visionOS 26.0+)

**Development Requirements**:
- Xcode 26.0+
- Swift 6.2+
- SwiftUI

## Building & Running

### Build the App
```bash
xcodebuild -scheme "Jelly Shark" -configuration Debug build
```

### Run Tests
```bash
# Run all tests
xcodebuild test -scheme "Jelly Shark" -destination 'platform=tvOS Simulator,name=Apple TV'

# Run unit tests only
xcodebuild test -scheme "Jelly Shark" -only-testing:Jelly\ SharkTests -destination 'platform=tvOS Simulator,name=Apple TV'

# Run UI tests only
xcodebuild test -scheme "Jelly Shark" -only-testing:Jelly\ SharkUITests -destination 'platform=tvOS Simulator,name=Apple TV'
```

### Clean Build
```bash
xcodebuild clean -scheme "Jelly Shark"
```

## Architecture

### Modular Design Philosophy
The app follows a modular architecture with clear separation of concerns. All three packages live under `Packages/` and are wired together via local Swift Package Manager dependencies:

1. **JellyfinKit** (`Packages/JellyfinKit`): API client, networking, and data models
   - Wraps the official [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) (0.6.0) behind a `JellyfinClientProtocol` facade
   - Authentication, library/item fetching, image URL building, playback info, and HLS stream URL construction
   - Playback reporting (start/progress/stopped), resume items, latest items, next-episode lookup
   - Domain models (`User`, `MediaItem`, `Library`, `ServerInfo`, `PlaybackSessionInfo`) + SDK adapters
   - Session persistence via Keychain (`SessionStore`, `KeychainStore`)
   - Platform support: Fully shared (macOS for tests, tvOS, visionOS)

2. **DesignSystem** (`Packages/DesignSystem`): Theming engine, design tokens, and base UI components
   - `Theme` protocol with `ThemeManager` (`@Observable` singleton) for runtime switching, persisted in `UserDefaults`
   - Design tokens: `ColorTokens`, `TypographyTokens`, `SpacingTokens`, `MotionTokens`
   - Base components: `ArtworkImage`, `ComponentPlaceholder`
   - **Current state**: Only `StandardTheme` is implemented; Horror/Action/Video Store identifiers exist but fall back to Standard. No component-variant system yet.

3. **Features** (`Packages/Features`): Application features, screens, and user flows
   - View implementations: `RootView`, `HomeView`, `LibraryView`/`LibraryItemsView`, `MediaDetailView`, `SearchView` (+ `SearchViewModel`), `SettingsView`, `ServerConnectionView`, playback views
   - View models (`@Observable @MainActor`): `ServerConnectionViewModel`, `PlaybackViewModel`; app-level `AppSession`
   - Navigation: `TabView` with Home / Library / Search / Settings, each in its own `NavigationStack`
   - Depends on JellyfinKit and DesignSystem
   - Structure: Artwork/, Library/, MediaDetail/, Playback/, Settings/ (no separate Authentication/ — connection lives under Settings/)

4. **App Target** (`Jelly Shark/`): Single SwiftUI entry point
   - `Jelly_SharkApp.swift` configures `URLCache` for artwork and presents `RootView` in a `WindowGroup`
   - Shared across tvOS and visionOS; platform divergence is handled with `#if os(tvOS)` guards in views
   - No SwiftData `ModelContainer` (template boilerplate has been removed)

### Data Flow
```
User Interaction → Feature Views (SwiftUI) → View Models (Observable) →
JellyfinKit (JellyfinClientProtocol) → jellyfin-sdk-swift → Jellyfin Server
```
Session tokens are persisted to the Keychain; artwork is cached via `URLCache`. SwiftData is not currently used (planned for metadata/state caching).

### Tech Stack
- Language: Swift 6.2+
- UI Framework: SwiftUI
- Networking: jellyfin-sdk-swift (0.6.0), built on Get/URLSession
- Playback: AVKit / AVPlayer (HLS transcode streaming)
- Persistence: Keychain (session tokens), URLCache (artwork); SwiftData planned but not yet adopted
- Testing: Swift Testing
- Dependency Management: Swift Package Manager
- Min Deployment: tvOS 26.0+, visionOS 26.0+ (packages also build for macOS 15 to support testing)

## Theming System

### Core Concept
Themes are **genre-inspired visual languages** that evoke the mood of different film genres. Each theme defines color, typography, motion, and spacing, while component variants define structure and layout.

**Themes** (high-level visual language):
- **Standard**: Elegant, timeless baseline (SF Pro, neutral palette, smooth animations)
- **Horror**: Atmospheric dread (angular typography, blood reds/blacks, slower tension-building animations)
- **Action**: Kinetic energy (geometric technical sans-serifs, electric blues, high-speed animations)
- **Video Store**: 90s nostalgia (rounded friendly typography, Blockbuster blue/gold, playful animations)

**Component Variants** (structural flexibility):
- Media cards: poster-dominant, landscape, minimal, detailed, immersive
- Detail page heroes: cinematic, minimal, split-screen, poster-first
- Navigation: tab bar, sidebar, immersive top menu
- List density: compact, comfortable, spacious

Users can switch themes globally and customize component variants individually, all without app restart.

## Jellyfin Integration

### Server Requirements
- Minimum Jellyfin version: 10.8.0+
- Server is the source of truth for all media, metadata, and user state
- Local storage (SwiftData) is for caching and performance only

### Authentication Flow (as implemented)
1. User enters server URL, username, and password in `ServerConnectionView` (mDNS/Bonjour auto-detect is planned, not yet built)
2. `ServerConnectionViewModel` creates a `JellyfinClient` and authenticates via the SDK's `signIn(username:password:)`
3. On success it fetches the user's libraries and publishes connection state
4. The access token + server URL + user ID are persisted to the Keychain as a `SavedSession` (NEVER in UserDefaults)
5. On next launch, `restoreSession()` reloads the saved session and validates the token via `fetchCurrentUser()` (clears the Keychain on 401, keeps it on transient network errors)

### Core API Endpoints (wrapped via jellyfin-sdk-swift)
- Authentication: SDK `signIn` (authenticate by name), `GET /Users/{userId}` (fetch current user)
- Libraries: `GET /Users/{userId}/Views`, `GET /Users/{userId}/Items`, `GET /Items/{itemId}`
- Discovery: `GET /Users/{userId}/Items/Resume`, `GET /Users/{userId}/Items/Latest`, episodes lookup for next-up
- Images: `GET /Items/{itemId}/Images/{imageType}` (URL building only)
- Playback: `GET /Items/{itemId}/PlaybackInfo`, HLS `GET /Videos/{itemId}/main.m3u8`, `POST /Sessions/Playing`, `/Progress`, `/Stopped`
- Search: `GET /Users/{userId}/Items` with `searchTerm` (movies/series/episodes), wired via `searchItems(query:limit:)`
- Not yet implemented: mark played/unplayed, favorites

### Caching Strategy (current vs. planned)
- **Current**: Session tokens in Keychain only; artwork via `URLCache` (64MB memory / 256MB disk). No persistent metadata cache.
- **Planned**: SwiftData caching for server config, user profiles, media metadata, user state, and library structure
- Don't cache: Auth tokens (Keychain only), video streams, transcoding decisions

## Current Project State

The foundation and core loop are in place. The app can connect to a Jellyfin server, browse libraries with artwork and metadata, and play items end to end.

**Implemented**:
- Modular SPM architecture (JellyfinKit, DesignSystem, Features) wired into the app target
- Server connection + authentication with Keychain-backed session persistence and restore-on-launch
- Home screen (Continue Watching, Recently Added), library browsing, media detail
- Search: debounced live search with a result grid, term-completion suggestions, and navigation to detail (`SearchView` + `SearchViewModel`)
- AVPlayer HLS playback: progress reporting, resume, audio/subtitle track switching, episode autoplay with "Up Next" overlay
- Standard theme and design-token system applied throughout
- Real unit tests for `ServerConnectionViewModel`, `PlaybackViewModel`, and `SearchViewModel` (Swift Testing) plus JellyfinKit unit tests

**Not yet implemented**:
- Horror / Action / Video Store themes (identifiers exist but resolve to Standard)
- Component variant system
- SwiftData metadata/state caching
- Top Shelf, Siri, and visionOS-specific spatial experiences

**Next Steps**:
1. Theming & Components: Implement remaining themes, build the component variant system
2. Caching: Adopt SwiftData for metadata and user-state caching
3. Platform Polish: tvOS/visionOS-specific optimizations, accessibility compliance
4. Beta & Refinement: Expand app-target test coverage, bug fixes, performance tuning

## Important Design Decisions

### Code Quality Principles
- Modular from day one: Clear separation via Swift Package Manager
- Platform-aware, not platform-specific: Shared logic with platform UI adaptations
- Design system driven: Components and theming as first-class architectural concerns
- Server as source of truth: Local storage only for caching

### Platform Adaptations
What shares (90%+): API client, data models, business logic, design tokens, base components, auth flows

What diverges: Navigation patterns (TabView vs WindowGroup), input handling (remote vs hands/eyes), focus management (tvOS focus engine vs visionOS spatial), immersive layouts

Strategy: Keep components platform-agnostic, use `#if os(tvOS)` conditionals and protocol abstractions where needed

### Performance Targets
- <2s initial library load
- <500ms theme switching
- Smooth 60fps scrolling
- <100MB memory footprint (excluding media cache)

### Accessibility Requirements
All themes must maintain:
- WCAG AA contrast ratios minimum
- Dynamic Type support (scale with system settings)
- VoiceOver labels for all interactive elements
- Focus indicators that work in all themes (minimum 3:1 contrast)
- Reduce Motion support (disable complex animations)

## Development Guidelines

### When Adding New Features
- Reference the PRD (docs/PRD.md) for product requirements and success criteria
- Follow the architecture patterns in docs/ARCHITECTURE.md
- Apply theming principles from docs/DESIGN_SYSTEM.md for all UI components
- Use Jellyfin API patterns documented in docs/JELLYFIN_INTEGRATION.md

### Avoid Over-Engineering
- Only make changes that are directly requested or clearly necessary
- Don't add features, refactor code, or make improvements beyond what was asked
- Keep solutions simple and focused
- Don't create helpers or abstractions for one-time operations

### Testing
- Unit tests: JellyfinKit, business logic, view models
- Integration tests: API client against mock/test Jellyfin server
- UI tests: Critical user flows on both platforms
- Manual testing: Focus navigation, spatial interactions, playback

## Reference Documentation

Full documentation is available in the `/docs` directory:
- **PRD.md**: Product requirements, feature list, success criteria, marketing positioning
- **ARCHITECTURE.md**: Module structure, data flow, tech stack, decision log
- **DESIGN_SYSTEM.md**: Theming philosophy, color palettes, typography, component variants
- **JELLYFIN_INTEGRATION.md**: API endpoints, authentication, data models, caching strategy

API Documentation: https://api.jellyfin.org
