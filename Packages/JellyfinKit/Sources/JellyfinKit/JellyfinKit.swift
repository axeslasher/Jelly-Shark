// JellyfinKit - API client, networking, and data models for Jellyfin
//
// This module provides a clean, app-focused API for interacting with Jellyfin servers.
// It wraps the official Jellyfin SDK (jellyfin-sdk-swift) while exposing simplified,
// domain-specific types that are easier to work with in SwiftUI.
//
// Architecture:
// ┌─────────────────────────────────────────────┐
// │            App (Features module)            │
// ├─────────────────────────────────────────────┤
// │              JellyfinKit (this)             │
// │  ┌─────────────────────────────────────┐    │
// │  │  JellyfinClientProtocol             │    │
// │  │  User, MediaItem, Library, etc.     │    │
// │  └──────────────┬──────────────────────┘    │
// │                 │ wraps                      │
// │  ┌──────────────▼──────────────────────┐    │
// │  │     jellyfin-sdk-swift (official)   │    │
// │  │  JellyfinAPI.JellyfinClient         │    │
// │  │  BaseItemDto, UserDto, etc.         │    │
// │  └─────────────────────────────────────┘    │
// └─────────────────────────────────────────────┘
//
// This module is fully shared across tvOS and visionOS.

import Foundation

// MARK: - Public API

// The primary client for interacting with Jellyfin
// Use JellyfinClientProtocol for dependency injection
// Use JellyfinClient as the concrete implementation

// Models are exported from their respective files:
// - User: Authenticated user information
// - MediaItem: Movies, episodes, and other media
// - Library: Media collections/libraries
// - ServerInfo: Jellyfin server information

// Configuration
// - JellyfinClientConfiguration: Settings for creating a client

// Errors
// - APIError: Error types for API operations
