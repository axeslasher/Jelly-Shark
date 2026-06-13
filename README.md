# Jelly Shark

A premium Jellyfin client for tvOS and Apple Vision Pro that doesn't look like a Jellyfin client.

## What is Jelly Shark?

Jelly Shark brings professional-grade UI design to the open-source media server ecosystem. Built by someone who designed TV interfaces for Starz, it proves that open-source doesn't mean ugly or clunky.

Unlike existing Jellyfin clients that treat the interface as functional but forgettable, Jelly Shark makes the UI itself a feature—beautiful, configurable, and tailored to how you want to experience your media library.

## Key Features

### Genre-Inspired Themes
Visual languages that evoke the mood of what you're watching. Horror libraries get atmospheric dread, not corporate blue.

- **Standard**: Elegant, timeless Apple-quality baseline
- **Horror**: Blood reds and tension with angular typography
- **Action**: Kinetic energy with electric blues and sharp geometry
- **Video Store**: 90s Blockbuster nostalgia with warm, playful design

All themes support light and dark modes. Switch themes at runtime—no app restart required.

### Deep Customization
Component variants let you customize layouts while staying within your chosen theme's aesthetic. Mix and match: Horror theme with minimal cards, or Standard theme with detailed layouts.

### Platform-Native Excellence
Actually leverages tvOS and visionOS capabilities instead of just "running on" them:
- **tvOS**: Precise focus engine, intuitive remote gestures, Top Shelf integration, Siri support
- **visionOS**: Spatial layouts with meaningful depth, immersive viewing modes, natural hand/eye tracking

### Professional 10-Foot UI
Designed specifically for the lean-back, living room experience—not adapted from mobile.

## Status

**In Active Development** — The core loop works end to end: connect to a Jellyfin server, browse libraries with artwork and metadata, and play items with progress tracking and resume.

**Working today:**
- Server connection and authentication with session persistence (Keychain-backed, auto-restored on launch)
- Home screen with live "Continue Watching" and "Recently Added" rows
- Library browsing with drill-down to item grids
- Media detail views with artwork, metadata, and play/resume
- AVPlayer-based HLS playback: progress reporting, resume, audio/subtitle track switching, and episode autoplay with an "Up Next" countdown
- Design system with theming wired throughout the app

**Not yet implemented:**
- Search (UI placeholder only)
- Themes beyond Standard — Horror, Action, and Video Store are scaffolded but currently fall back to Standard
- Component variant system
- Local metadata/image caching (only session tokens are persisted today; artwork uses `URLCache`)

## Platform Support

- Apple TV 4K (tvOS 26.0+)
- Apple Vision Pro (visionOS 26.0+)

## Tech Stack

- Swift 6.2+
- SwiftUI
- AVKit / AVPlayer for HLS playback
- [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) for the Jellyfin API
- Keychain for secure session storage
- Swift Package Manager (modular: JellyfinKit, DesignSystem, Features)

## Contributing

This project is in early development. Contribution guidelines will be published as the codebase matures.

## License

Apache 2.0 (TBD)

---

**Your media library, your style.**
