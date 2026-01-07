# Jellyfin Integration

## Overview

Jelly Shark integrates with Jellyfin servers via the official REST API. The server is the source of truth for all media content, metadata, and user state. Local storage is exclusively for caching and performance optimization.

---

## Server Requirements

**Minimum Jellyfin Version**: 10.8.0+  
**Recommended**: 10.9.0+ (latest stable)

**Required Server Features**:
- User authentication
- Media libraries (movies, TV, music)
- Metadata providers configured
- Transcoding capability (optional but recommended)

**Optional Server Features** (enhance experience):
- Hardware transcoding
- Custom artwork/themes
- External subtitle providers

---

## Authentication Flow

### Initial Connection
1. User enters server URL (auto-detect via mDNS/Bonjour if on local network)
2. App validates server accessibility and version compatibility
3. User provides credentials (username/password)
4. App authenticates via `/Users/authenticatebyname`
5. Server returns access token and user profile
6. Token stored securely in Keychain
7. User profile cached in SwiftData

### Session Management
- **Token refresh**: Not required (Jellyfin tokens don't expire by default)
- **Re-authentication**: Only on explicit logout or token invalidation
- **Multiple servers**: Support for multiple server profiles (future)
- **Quick user switching**: Support for multiple users on same server

### Security
- Tokens stored in iOS/tvOS Keychain (never in UserDefaults or plaintext)
- HTTPS enforcement option (warn on HTTP)
- Server certificate validation
- Biometric authentication for app access (optional, future)

---

## Core API Endpoints

### Authentication
```
POST /Users/authenticatebyname
- Login with username/password
- Returns: AccessToken, User object

GET /Users/{userId}
- Retrieve user profile
- Returns: User details, preferences, permissions
```

### Libraries & Media
```
GET /Users/{userId}/Views
- Retrieve user's media libraries
- Returns: Array of library objects (Movies, TV, Music, etc.)

GET /Users/{userId}/Items
- Query media items with filters
- Params: ParentId, Filters, SortBy, Limit, StartIndex
- Returns: Paginated media items

GET /Items/{itemId}
- Retrieve detailed item information
- Returns: Full metadata, images, external IDs, people, etc.
```

### Images & Artwork
```
GET /Items/{itemId}/Images/{imageType}
- Retrieve item artwork
- Types: Primary, Backdrop, Logo, Thumb, Banner
- Params: MaxWidth, MaxHeight, Quality
- Returns: Image binary (JPEG/PNG)
```

### Playback
```
POST /Sessions/Playing
- Report playback start
- Params: ItemId, PositionTicks, PlayMethod

POST /Sessions/Playing/Progress  
- Report playback progress (heartbeat every 10s)
- Params: ItemId, PositionTicks, IsPaused

POST /Sessions/Playing/Stopped
- Report playback stopped
- Params: ItemId, PositionTicks
```

### User Data
```
POST /Users/{userId}/PlayedItems/{itemId}
- Mark item as played

DELETE /Users/{userId}/PlayedItems/{itemId}  
- Mark item as unplayed

POST /Users/{userId}/FavoriteItems/{itemId}
- Add to favorites

GET /Users/{userId}/Items/Resume
- Get continue watching items
```

### Search
```
GET /Users/{userId}/Items
- Search with SearchTerm param
- Returns: Matching items across all libraries
```

---

## Data Models

### Core Entities

**Server**
```swift
struct Server {
    let id: UUID
    let name: String
    let url: URL
    let version: String
    var isActive: Bool
}
```

**User**  
```swift
struct User {
    let id: String
    let name: String
    let hasPassword: Bool
    let hasConfiguredPassword: Bool
    let imageUrl: URL?
    var accessToken: String // Stored separately in Keychain
}
```

**MediaItem**
```swift
struct MediaItem {
    let id: String
    let name: String
    let type: MediaType // Movie, Episode, Series, Audio, etc.
    let overview: String?
    let productionYear: Int?
    let premiereDate: Date?
    let communityRating: Double?
    let officialRating: String? // MPAA rating
    let runtime: TimeInterval?
    let genres: [String]
    let studios: [String]
    let people: [Person] // Cast, crew
    let images: MediaImages
    let userData: UserData
    var parentId: String? // For episodes (series ID)
    var seasonId: String? // For episodes
    var indexNumber: Int? // Episode number
}
```

**MediaImages**
```swift
struct MediaImages {
    var primary: URL?
    var backdrop: URL?
    var logo: URL?
    var thumb: URL?
    var banner: URL?
}
```

**UserData**
```swift
struct UserData {
    var playbackPosition: TimeInterval
    var playCount: Int
    var isFavorite: Bool
    var played: Bool
    var lastPlayedDate: Date?
}
```

**Person**
```swift
struct Person {
    let id: String
    let name: String
    let role: String? // Actor, Director, Writer, etc.
    let type: PersonType
    let imageUrl: URL?
}
```

---

## Caching Strategy

### What to Cache (SwiftData)
- **Server configuration**: URL, version, capabilities
- **User profiles**: Basic info, preferences (NOT tokens)
- **Media metadata**: Items, images, cast/crew
- **User state**: Playback position, favorites, played status
- **Library structure**: Collections, folders, recently added

### Cache Invalidation
- **On app launch**: Check server for updates to recently modified items
- **After playback**: Sync playback state immediately
- **Background refresh**: Periodic metadata updates when app is active
- **Manual refresh**: User-initiated pull-to-refresh

### Image Caching
- Use URLCache for image assets
- Aggressive caching for posters/backdrops (rarely change)
- Configurable cache size limit (default 500MB)
- Purge on low storage warnings

### What NOT to Cache
- Authentication tokens (Keychain only)
- Video streams (always streamed, never stored)
- Transcoding decisions (server-side)

---

## Playback Integration

### Video Player Strategy
**Decision**: Use established Swift video player library (not AVPlayerViewController directly)

**Candidates**:
- **VLCKit**: Full-featured, wide codec support, heavier
- **MobileVLCKit**: iOS/tvOS optimized VLC
- Custom AVPlayer wrapper with UI layer

**Requirements**:
- Native Jellyfin streaming URL support
- Subtitle support (external and embedded)
- Audio track selection
- Playback speed control
- Picture-in-picture (iOS, future)
- Seek preview thumbnails (if available)

### Streaming
- Direct play when client supports codec/container
- Transcode when necessary (server handles this)
- HLS streaming for adaptive bitrate
- Offline downloads NOT supported in v1.0

### Playback State Sync
- Report play start immediately
- Progress updates every 10 seconds while playing
- Stop report on pause/exit with current position
- Resume from saved position on next play

---

## API Client Architecture

### Networking Layer
**Library**: Native URLSession or Alamofire

**Structure**:
```
JellyfinKit/
├── API/
│   ├── JellyfinClient.swift (main client)
│   ├── Endpoints/
│   │   ├── AuthenticationEndpoint.swift
│   │   ├── LibraryEndpoint.swift
│   │   ├── PlaybackEndpoint.swift
│   │   ├── UserDataEndpoint.swift
│   │   └── SearchEndpoint.swift
│   └── NetworkManager.swift
├── Models/
│   ├── Server.swift
│   ├── User.swift
│   ├── MediaItem.swift
│   └── (etc.)
└── Cache/
    ├── CacheManager.swift
    └── ImageCache.swift
```

### Error Handling
- Network errors (timeout, no connection)
- Authentication errors (invalid token, expired session)
- Server errors (500s, maintenance mode)
- API version incompatibility
- Graceful degradation when features unavailable

### Request Patterns
- Async/await for all API calls
- Pagination for large lists (default 100 items per page)
- Concurrent image fetching (max 6 simultaneous)
- Request debouncing for search
- Retry logic for transient failures

---

## Performance Considerations

### Optimization Strategies
- **Lazy loading**: Fetch metadata on-demand, not upfront
- **Pagination**: Never load entire library at once
- **Image resolution**: Request appropriate sizes for device/context
- **Prefetching**: Predictive loading for likely-next content
- **Background tasks**: Metadata updates during idle time

### Bandwidth Management
- Respect user's network conditions
- Quality settings for transcoding (Auto, High, Medium, Low)
- Cellular data warnings/restrictions (iOS)
- Download size estimates before transcoding

---

## Platform-Specific Considerations

### tvOS
- **Focus-driven loading**: Prefetch on focus, load on selection
- **Top Shelf**: Quick actions to resume watching
- **Siri integration**: "Play [movie name] in Jelly Shark"
- **Remote control**: Play/pause/skip mappings

### visionOS  
- **Spatial data**: Window management for detail views
- **Immersive playback**: Full environment video player
- **Hand gestures**: Natural playback controls
- **Eye tracking**: Attention-aware pause/resume

---

## Testing Strategy

### API Testing
- Mock Jellyfin server for unit tests
- Integration tests against real test server
- API version compatibility matrix
- Network failure simulation

### Test Server Setup
- Docker container with Jellyfin test instance
- Seeded with sample content
- Consistent test data for CI/CD

---

## Future Enhancements

### v1.x Candidates
- Multiple server support (switch between home/remote)
- Offline downloads for travel
- Live TV integration (if server supports)
- Plugin support (intro skipper, theme music, etc.)
- Cast/AirPlay support

### v2.x Possibilities
- Social features (watch parties, shared playlists)
- Advanced filtering/sorting
- Custom collections
- Parental controls beyond server settings

---

## Jellyfin API Resources

**Official Documentation**: https://api.jellyfin.org  
**API Spec (OpenAPI)**: https://api.jellyfin.org/openapi/api-docs  
**GitHub**: https://github.com/jellyfin/jellyfin  
**Community Forum**: https://forum.jellyfin.org

---

## Open Questions

1. Transcode quality defaults - let users configure or auto-detect?
2. Local metadata editing (update server) or read-only?
3. Background playback (audio) on iOS?
4. Plugin detection and integration strategy?
5. Server-side user preferences vs app-side preferences?
