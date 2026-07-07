# Jellyfin Integration

## Overview

Jelly Shark integrates with Jellyfin servers through the official [`jellyfin-sdk-swift`](https://github.com/jellyfin/jellyfin-sdk-swift) SDK (0.6.0), wrapped behind a `JellyfinClientProtocol` facade in JellyfinKit. The server is the source of truth for all media content, metadata, and user state. Local storage is exclusively for caching and performance optimization.

> **Implementation status note**: This document describes both what is built and what is planned. Sections marked _(planned)_ are not yet implemented. As of now, the client supports authentication, paged library/item browsing with sort/filter, search, image URLs, resume/latest discovery, seasons/episodes + next-up, similar items, people (person detail + filmography), playback info + HLS streaming, and playback reporting. **"Mark played/unplayed" and "favorites" are implemented** — read via item `UserData` and written back through optimistic toggles on media and person detail. SwiftData caching is not yet adopted — only session tokens (Keychain) and artwork (`URLCache`) are persisted.

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

### Initial Connection (as implemented)
1. User enters server URL, username, and password in `ServerConnectionView`
2. `ServerConnectionViewModel` constructs a `JellyfinClient` and calls the SDK's `signIn(username:password:)`
3. The SDK authenticates (authenticate-by-name) and returns an access token + user
4. The client fetches the user's libraries to confirm the connection
5. The access token, server URL, and user ID are saved as a `SavedSession` in the Keychain
6. On next launch, `restoreSession()` reloads the session and validates the token via `fetchCurrentUser()`

_(planned)_ Auto-detect via mDNS/Bonjour on the local network; explicit server version-compatibility gating before login.

### Session Management
- **Persistence**: `SavedSession` (server URL + user ID + token) in Keychain; restored and re-validated on launch
- **Token refresh**: Not required (Jellyfin tokens don't expire by default)
- **Re-authentication**: On explicit logout, or automatically cleared if the saved token returns 401 during restore (kept on transient network errors)
- **Device ID**: A stable per-install UUID is generated and stored in the Keychain, surviving logout
- **Multiple servers**: Support for multiple server profiles _(future)_
- **Quick user switching**: Multiple users on same server _(future)_

### Security
- Tokens stored in iOS/tvOS Keychain (never in UserDefaults or plaintext)
- HTTPS enforcement option (warn on HTTP)
- Server certificate validation
- Biometric authentication for app access (optional, future)

---

## Core API Endpoints

All endpoints are accessed through `jellyfin-sdk-swift` (`Paths.*`) rather than hand-rolled requests. The list below marks current implementation status.

### Authentication — ✅ implemented
```
authenticate(username:password:) — facade method; wraps the SDK's
  signIn(username:password:) (authenticate-by-name)
- Returns: AccessToken, User object

GET /Users/{userId}              (fetchCurrentUser)
- Retrieve user profile; used to validate a restored token

signOut()                        — facade method; clears the session
```

### Libraries & Media — ✅ implemented
```
GET /Users/{userId}/Views        (getLibraries)
- Returns: user's media libraries

GET /Users/{userId}/Items        (getLibraryItems)
- Takes a LibraryQuery (sort field + direction, genres, decades,
  watched status, favorites-only, official ratings); paginated via
  Limit/StartIndex; Fields=overview,genres,dateCreated,mediaSources
- Returns: a MediaItemPage (items + startIndex + totalRecordCount)

GET /Items/Filters               (getLibraryFilterOptions, unfiltered overload)
GET /Users/{userId}/Items        (getLibraryFilterOptions, matching: overload)
- Derives the available genres / decades / official ratings for a
  library. The unfiltered overload uses the server's Filters endpoint;
  the `matching query:` overload scans items and returns nil when the
  result set is too large to scan

GET /Items/{itemId}              (getMediaItem)
- Returns: full metadata for one item

GET /Users/{userId}/Items/Resume (getResumeItems)  — Continue Watching
GET /Users/{userId}/Items/Latest (getLatestItems)  — Recently Added
```

### Episodes, Seasons & Next-Up — ✅ implemented
```
GET /Shows/{seriesId}/Seasons    (getSeasons)
GET /Shows/{seriesId}/Episodes   (getEpisodes)      — all episodes, optionally by season
GET /Shows/NextUp                (getNextUpEpisode) — server Next-Up logic for a series
GET /Shows/{seriesId}/Episodes   (getNextEpisode)   — strict next-in-order after an episode
```

### Similar Items — ✅ implemented
```
GET /Items/{itemId}/Similar      (getSimilarItems)  — "More Like This"
```

### People — ✅ implemented
```
GET /Users/{userId}/Items/{personId}  (getPerson)  — person detail (bio, life facts)
GET /Users/{userId}/Items with PersonIds (getItemsFeaturingPerson) — filmography
- Filmography is split into Movies, TV Series, and Episodes on PersonDetailView
```

### Images & Artwork — ✅ implemented (URL building)
```
GET /Items/{itemId}/Images/{imageType}
- Types: Primary, Backdrop, Logo, Thumb, Banner
- Params: MaxWidth, MaxHeight
- JellyfinKit builds these URLs; SwiftUI's AsyncImage (via ArtworkImage) loads them
GET /Users/{userId}/Images/Primary   — user avatar
```

### Playback — ✅ implemented
```
GET /Items/{itemId}/PlaybackInfo (getPlaybackInfo)
- Returns: media sources + play session ID

GET /Videos/{itemId}/main.m3u8   (hlsStreamURL — built by StreamURLBuilder)
- HLS transcode stream; codecs hevc,h264 / aac,ac3,eac3; SegmentContainer=mp4

POST /Sessions/Playing           (reportPlaybackStart)
POST /Sessions/Playing/Progress  (reportPlaybackProgress — heartbeat every 10s)
POST /Sessions/Playing/Stopped   (reportPlaybackStopped)
- Note: PlayMethod is currently hardcoded to Transcode
```

### User Data — ✅ implemented
```
POST   /Users/{userId}/PlayedItems/{itemId}     (markPlayed)
DELETE /Users/{userId}/PlayedItems/{itemId}     (markUnplayed)
POST   /Users/{userId}/FavoriteItems/{itemId}   (markFavorite)
DELETE /Users/{userId}/FavoriteItems/{itemId}   (unmarkFavorite)
```
Played/favorite state is both read (via item `UserData`) and written from the app. `MediaDetailHeroSection` exposes watched + favorite toggles; `PersonDetailHeader` exposes a favorite toggle. Both apply the change optimistically and revert on failure.

### Search — ✅ implemented
```
GET /Users/{userId}/Items with SearchTerm
```
Exposed as `searchItems(query:limit:)` on `JellyfinClientProtocol`. It sends a recursive `GetItems` request with `searchTerm`, restricted to `includeItemTypes` of movie/series/episode and sorted by name. `SearchView` drives it through `SearchViewModel`, which debounces input (~300ms), cancels in-flight requests, and derives term-completion suggestions from the result titles.

---

## Data Models

These are the domain types defined in `JellyfinKit/Models/`. They are plain `struct`s (`Sendable`, `Equatable`, `Hashable`) mapped from SDK DTOs in `Adapters/SDKAdapters.swift`. The access token is never a model field — it lives only in the Keychain.

**User** (`Models/User.swift`)
```swift
struct User: Identifiable {
    let id: String
    let name: String
    let serverId: String?
    let isAdministrator: Bool
    let primaryImageTag: String?
}
```

**MediaItem** (`Models/MediaItem.swift`)
```swift
struct MediaItem: Identifiable {
    let id: String
    let name: String
    let originalTitle: String?
    let type: MediaType            // movie, series, season, episode, boxSet, audio, ...
    let overview: String?
    let productionYear: Int?
    let runTimeTicks: Int64?       // Jellyfin ticks (10,000,000 per second)
    let communityRating: Double?
    let criticRating: Double?
    let officialRating: String?    // MPAA-style rating
    let tagline: String?           // marketing tagline (movies)
    let genres: [String]?
    let studios: [String]?
    let premiereDate, endDate: Date?
    let status: String?            // e.g. "Continuing", "Ended" (series)
    let childCount, recursiveItemCount: Int?
    let imageTags: ImageTags?      // tags, not URLs — URLs are built on demand
    let userData: UserData?
    let technicalInfo: MediaTechnicalInfo?   // resolution/HDR/codec/audio badges
    let people: [CastMember]?      // cast & crew credits
    let parentArtwork: ParentArtwork?        // fallback art from series/season
    let seriesId, seriesName, seasonId, seasonName: String?
    let indexNumber, parentIndexNumber: Int?
    // Computed (sample): formattedRuntime, progressPercentage, hasProgress,
    //   episodeDisplayTitle, seasonCountText, episodeCode, *BlurHash
}
```
Note: artwork is referenced by **image tags** (`ImageTags`), not pre-built URLs. URLs are constructed via `getImageURL(...)` / the `MediaArtwork` helpers. Cast/crew are modeled both as lightweight `CastMember` credits embedded on the item (`people`) and as a full `Person` for the person-detail screen; `studios` are modeled. Two supporting types live in the same file: `MediaTechnicalInfo` (backs the resolution/HDR/audio/codec badges) and `ParentArtwork` (series/season art used when an item has none of its own).

**ImageTags** (in `MediaItem.swift`)
```swift
struct ImageTags {
    let primary, backdrop, banner, thumb, logo: String?
    let primaryBlurHash, backdropBlurHash, thumbBlurHash: String?  // placeholder hashes
}
```

**UserData** (in `MediaItem.swift`)
```swift
struct UserData {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool
    var played: Bool
    var lastPlayedDate: Date?
}
```

**Library** (`Models/Library.swift`)
```swift
struct Library: Identifiable {
    let id: String
    let name: String
    let collectionType: CollectionType?   // movies, tvshows, music, ...
    let primaryImageTag: String?
    let childCount: Int?
    // Computed: systemImageName (SF Symbol per collection type)
}
```

**Person** (`Models/Person.swift`)
```swift
struct Person: Identifiable {
    let id: String
    let name: String
    let biography: String?
    let birthDate, deathDate: Date?
    let birthPlace: String?
    let primaryImageTag, primaryBlurHash: String?
    let isFavorite: Bool
    // Computed: formattedBirthDate, formattedDeathDate, age
}
```

**CastMember** (`Models/CastMember.swift`) — a lightweight credit entry embedded on a `MediaItem`, distinct from `Person`
```swift
struct CastMember: Identifiable {
    let id: String
    let name: String
    let role: String?
    let kind: ...              // actor, director, writer, ...
    let primaryImageTag: String?
    // Computed: hasServerId (false for "person-N" fallback IDs, which don't navigate)
}
```

**Library query & filter types** (`Models/LibraryQuery.swift`)
```swift
struct LibraryQuery {                 // drives getLibraryItems
    var sort: LibrarySort             // name, releaseDate, dateAdded, communityRating, criticRating
    var direction: LibrarySortDirection
    var genres: Set<String>
    var decades: Set<Int>
    var watched: WatchedFilter        // any, unplayed, played
    var favoritesOnly: Bool
    var officialRatings: Set<String>
    // Computed: isFiltering, expandedYears, withFiltersCleared
}
struct MediaItemPage { let items: [MediaItem]; let startIndex: Int; let totalRecordCount: Int?; /* hasMore */ }
struct LibraryFilterOptions { let genres: [String]; let officialRatings: [String]; let years: [Int]; /* decades */ }
```

**ServerInfo** (`Models/ServerInfo.swift`) — `Codable`
```swift
struct ServerInfo {
    let serverName, version, id: String
    let operatingSystem: String?
    let startupWizardCompleted: Bool?
    static let minimumVersion = "10.8.0"   // computed isSupported
}
```
(Defined for version-compatibility checks; no client fetch method wired up yet.)

**PlaybackSessionInfo / MediaSource / MediaStreamInfo** (`Models/PlaybackSession.swift`)
Describe the playable media sources returned by `PlaybackInfo`, including audio/subtitle stream lists (`MediaStreamInfo`) used for in-player track switching. `PlaybackTicks` provides ticks↔seconds conversion helpers.

---

## Caching Strategy

### Current (implemented)
- **Keychain**: `SavedSession` (server URL, user ID, access token) + a stable device ID
- **URLCache**: artwork images, via `URLCache.shared` configured at app launch (64MB memory / 256MB disk)
- **UserDefaults**: selected theme identifier
- Everything else (libraries, items, metadata) is fetched live on each view's `.task` — there is no persistent metadata cache yet.

### Planned (SwiftData)
SwiftData is the intended persistence layer for caching but has **not been adopted yet**. Once added, the plan is to cache:
- **Server configuration**: URL, version, capabilities
- **User profiles**: Basic info, preferences (NOT tokens)
- **Media metadata**: Items, images, cast/crew
- **User state**: Playback position, favorites, played status
- **Library structure**: Collections, folders, recently added

### Cache Invalidation _(planned, once SwiftData is added)_
- **On app launch**: Check server for updates to recently modified items
- **After playback**: Sync playback state immediately
- **Background refresh**: Periodic metadata updates when app is active
- **Manual refresh**: User-initiated pull-to-refresh

### What NOT to Cache
- Authentication tokens (Keychain only)
- Video streams (always streamed, never stored)
- Transcoding decisions (server-side)

---

## Playback Integration

### Video Player Strategy
**Decision (implemented)**: `AVPlayer` + `AVPlayerViewController`, bridged into SwiftUI via a `UIViewControllerRepresentable` (`PlayerViewController`, guarded by `#if canImport(UIKit)`). No third-party player (VLCKit was considered but not adopted). Playback lifecycle is owned by `PlaybackViewModel` (`@Observable @MainActor`).

**Implemented capabilities**:
- HLS streaming from Jellyfin's transcode endpoint
- Resume from saved position
- Audio + subtitle track switching (rebuilds the HLS stream with the chosen indices; on tvOS, surfaced via `AVPlayerViewController` transport-bar menus)
- Episode autoplay with an "Up Next" countdown overlay (`UpNextOverlayView`)

**Planned**: Direct play (currently always transcodes), playback speed control, Picture-in-Picture, seek-preview thumbnails, broader codec support.

### Streaming (as implemented)
- **Always HLS transcode** via `GET /Videos/{itemId}/main.m3u8` — direct play is not yet implemented even when the client could support the codec/container
- `PlaybackInfo` is requested first to obtain media sources and a play session ID
- Offline downloads NOT supported in v1.0

### Playback State Sync (implemented)
- Report play start immediately on stream start
- Progress updates every 10 seconds while playing (interval is injectable for tests), plus on pause/play transitions
- Stop report on exit/finish with current position
- Resume from saved position (`userData.playbackPositionTicks`) on next play

---

## API Client Architecture

### Networking Layer
**Library**: `jellyfin-sdk-swift` (built on [Get](https://github.com/kean/Get)/URLSession). JellyfinKit does not issue raw requests — it calls SDK `Paths.*` and adapts the DTOs to domain models.

**Structure (as implemented)**:
```
JellyfinKit/Sources/JellyfinKit/
├── Client/
│   ├── JellyfinClient.swift          (JellyfinClientProtocol + concrete client)
│   ├── StreamURLBuilder.swift        (HLS main.m3u8 URL construction)
│   └── DeviceProfile+JellyShark.swift (codec/container capabilities)
├── Models/
│   ├── User.swift, MediaItem.swift, Library.swift
│   ├── Person.swift, CastMember.swift, LibraryQuery.swift
│   ├── ServerInfo.swift, PlaybackSession.swift
├── Adapters/
│   ├── SDKAdapters.swift             (DTO → domain mapping)
│   └── PlaybackAdapters.swift
├── Persistence/
│   ├── KeychainStore.swift
│   └── SessionStore.swift            (SessionStoring protocol + SavedSession)
├── Networking/
│   └── APIError.swift
└── JellyfinKit.swift
```
There is no `Cache/` module yet (no SwiftData/metadata cache).

### Error Handling (implemented)
- `APIError` enum covers invalidURL, httpError, unauthorized, forbidden, notFound, serverError, networkError, decodingError, unsupportedServerVersion, notAuthenticated, generic
- `JellyfinClient.mapTransportError(_:)` maps `Get.APIError` HTTP status codes (401→unauthorized, 403→forbidden, 404→notFound, 500+→serverError) to `APIError`
- Views degrade gracefully (e.g. Home shows empty sections rather than blocking on errors)

### Request Patterns
- Async/await for all API calls
- Pagination params supported (`Limit`/`StartIndex`); `LibraryItemsView` pages a library in fixed-size batches and loads more on infinite scroll, tracking `MediaItemPage.totalRecordCount` to know when to stop
- Image loading via SwiftUI `AsyncImage` (`ArtworkImage`), cached by `URLCache`
- Search input is debounced (~300ms) with in-flight cancellation in `SearchViewModel`
- _(planned)_ Retry logic for transient failures, predictive prefetching

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
