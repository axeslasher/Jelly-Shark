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

**Dependencies**: Foundation, [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift)

**Platform support**: Fully shared (iOS, tvOS, visionOS)

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

**Dependencies**: SwiftUI

**Platform support**: Shared with platform-specific variants

**Key concepts**:
- Themes as data, not hard-coded styles
- Component variants for density, layout, interaction patterns
- Multi-modal theming (light/dark, color schemes, density modes)

---

### Features
**Purpose**: Application features, screens, and user flows

**Responsibilities**:
- View implementations (library browsing, media detail, playback)
- View models and state management
- Navigation coordination
- Feature-specific business logic

**Dependencies**: JellyfinKit, DesignSystem, SwiftUI

**Platform support**: Some shared, some platform-specific

**Structure** (potential):
```
Features/
├── Authentication/
├── Library/
├── MediaDetail/
├── Playback/
├── Search/
└── Settings/
```

---

### App Targets
**Purpose**: Platform-specific entry points and configurations

**Jelly Shark (tvOS)**:
- App entry point and lifecycle
- Focus-driven navigation
- Remote control handling
- Top Shelf extension (future)

**Jelly Shark (visionOS)**:
- App entry point and lifecycle  
- Spatial navigation and immersive experiences
- Hand/eye tracking integration
- Window/volume management

---

## Data Flow

```
User Interaction
    ↓
Feature Views (SwiftUI)
    ↓
View Models (Observable)
    ↓
JellyfinKit (API Client)
    ↓
Jellyfin Server
    ↓
SwiftData (Local Cache)
```

### Persistence Strategy

**SwiftData** for local caching:
- Watch history and progress
- Favorites and collections
- Downloaded metadata and images
- User preferences and settings

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

**Language**: Swift 6.0+  
**UI Framework**: SwiftUI  
**Networking**: URLSession (evaluate Alamofire if complexity warrants)  
**Persistence**: SwiftData  
**Testing**: Swift Testing  
**Dependency Management**: Swift Package Manager  
**Minimum Deployments**: 
- tvOS 26.0+
- visionOS 26.0+

---

## Testing Strategy

**Unit Tests**: JellyfinKit, business logic, view models  
**Integration Tests**: API client against mock/test Jellyfin server  
**UI Tests**: Critical user flows on both platforms  
**Manual Testing**: Focus navigation, spatial interactions, playback

---

## Build & Release

**Development**: Xcode 16.0+  
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
2. **Navigation architecture**: Coordinator pattern or SwiftUI native?
3. **State management**: Observable macros vs manual publishers?

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
