// JellyfinKit - API client, networking, and data models for Jellyfin
// This module is fully shared across tvOS and visionOS

// MARK: - Public Exports

// Client
@_exported import struct Foundation.URL
@_exported import struct Foundation.Data
@_exported import struct Foundation.Date
@_exported import struct Foundation.UUID

// Re-export public types
public typealias JellyfinClientProtocol = JellyfinClient
