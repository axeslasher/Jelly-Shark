// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
