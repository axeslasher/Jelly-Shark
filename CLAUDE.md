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
- Xcode 16.0+
- Swift 6.0+
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
The app follows a modular architecture with clear separation of concerns:

1. **JellyfinKit** (Planned): API client, networking, and data models
   - Jellyfin server integration and authentication
   - Network request handling and response parsing
   - Media streaming coordination
   - Platform support: Fully shared across iOS, tvOS, visionOS

2. **DesignSystem** (Planned): Theming engine, design tokens, and base UI components
   - Theme management with runtime switching (Standard, Horror, Action, Video Store)
   - Design token definitions (color, typography, spacing, motion)
   - Base SwiftUI components with variant support
   - Platform-specific adaptations for focus states and spatial layouts

3. **Features** (Planned): Application features, screens, and user flows
   - View implementations (library browsing, media detail, playback, search, settings)
   - View models and state management
   - Navigation coordination
   - Structure: Authentication/, Library/, MediaDetail/, Playback/, Search/, Settings/

4. **App Targets**: Platform-specific entry points
   - tvOS: Focus-driven navigation, remote control handling, Top Shelf integration
   - visionOS: Spatial navigation, immersive experiences, window/volume management

### Data Flow
```
User Interaction → Feature Views (SwiftUI) → View Models (Observable) →
JellyfinKit (API Client) → Jellyfin Server → SwiftData (Local Cache)
```

### Tech Stack
- Language: Swift 6.0+
- UI Framework: SwiftUI
- Networking: URLSession (or Alamofire if complexity warrants)
- Persistence: SwiftData
- Testing: Swift Testing
- Dependency Management: Swift Package Manager
- Min Deployment: tvOS 26.0+, visionOS 26.0+

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

### Authentication Flow
1. User enters server URL (auto-detect via mDNS/Bonjour on local network)
2. App validates server accessibility and version compatibility
3. User provides credentials (username/password)
4. App authenticates via `/Users/authenticatebyname`
5. Token stored securely in Keychain (NEVER in UserDefaults)
6. User profile cached in SwiftData

### Core API Endpoints
- Authentication: `POST /Users/authenticatebyname`, `GET /Users/{userId}`
- Libraries: `GET /Users/{userId}/Views`, `GET /Users/{userId}/Items`, `GET /Items/{itemId}`
- Images: `GET /Items/{itemId}/Images/{imageType}`
- Playback: `POST /Sessions/Playing`, `POST /Sessions/Playing/Progress`, `POST /Sessions/Playing/Stopped`
- User Data: `POST /Users/{userId}/PlayedItems/{itemId}`, `GET /Users/{userId}/Items/Resume`

### Caching Strategy
- Cache: Server config, user profiles, media metadata, user state, library structure
- Don't cache: Auth tokens (Keychain only), video streams, transcoding decisions
- Invalidation: On app launch, after playback, background refresh, manual pull-to-refresh

## Current Project State

This is a **new project** initialized with Xcode template boilerplate. The current code contains:
- Basic SwiftUI app structure with SwiftData persistence
- Template `Item` model and `ContentView` (to be replaced)
- Xcode project configured for tvOS and visionOS (26.0+ minimum deployment)

**Next Steps** (from docs):
1. Foundation: Architecture setup, core API integration, basic playback, Standard theme
2. Theming & Components: Remaining themes, component variant system, base component library
3. Platform Polish: tvOS/visionOS-specific optimizations, accessibility compliance
4. Beta & Refinement: Testing, bug fixes, performance tuning

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
