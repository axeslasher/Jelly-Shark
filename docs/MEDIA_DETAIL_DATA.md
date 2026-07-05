# Media Detail Data Inventory

What the Jellyfin server can tell us about a single media item, what JellyfinKit
currently surfaces, and what the media detail layout uses. Written while
deciding which fields to incorporate into `MediaDetailView`.

## How the data arrives

- `JellyfinClient.getMediaItem(itemId:)` calls the **single-item endpoint**
  (`/Users/{userId}/Items/{itemId}`), which returns the *complete*
  `BaseItemDto` — every field below is already on the wire for every detail
  fetch. Incorporating a field costs only adapter mapping + UI.
- The **list endpoints** (`getItems`, `getSimilarItems`, resume, search) only
  return fields named in their `fields:` parameter. If shelf *cards* ever need
  a field from this inventory, the corresponding request must ask for it.
- Series children (seasons/episodes) are **not** part of the item DTO; they
  come from separate endpoints (`getEpisodes` etc.) and are out of scope here.

## Surfaced on `MediaItem` today

| Field | In detail UI? |
|---|---|
| `id`, `name`, `type` | yes |
| `originalTitle` | mapped, not shown |
| `overview`, `tagline` | yes (hero overview + full-screen overlay) |
| `productionYear` | yes (metadata row) |
| `runTimeTicks` (`formattedRuntime`) | yes (metadata row) |
| `communityRating` | yes (metadata row) |
| `officialRating` | yes (certificate badge) |
| `genres` | yes (genre line under metadata row) |
| `imageTags` (primary/backdrop/banner/thumb/logo) | backdrop + logo in hero |
| `userData` (position, played, favorite, playCount, lastPlayedDate) | played/favorite toggles, resume label |
| `seriesId/Name`, `seasonId/Name`, `indexNumber`, `parentIndexNumber` | shelf captions, not on detail |
| `people` | yes (Cast & Crew shelf, credits column) |
| `criticRating` | yes (metadata row, percent) |
| `premiereDate`, `endDate`, `status` | endDate/status drive series year spans ("2008–2013") |
| `studios` | yes (credits column) |
| `childCount`, `recursiveItemCount` | childCount → "N Seasons" (series metadata row) |
| `technicalInfo` (distilled from `mediaStreams`) | yes (badge row: resolution / video range / audio / CC) |

`technicalInfo` intentionally does **not** expose raw `MediaStream`s. The
adapter reduces the default video/audio/subtitle streams to display-ready
labels (`resolution`, `videoRange`, `audioFormat`, `subtitleLanguages`),
keeping the facade philosophy: only what the app needs.

## Available on `BaseItemDto`, not yet mapped

Worth considering, roughly by payoff:

| Field(s) | Potential use |
|---|---|
| `remoteTrailers`, `trailerCount`, `localTrailerCount` | Trailer button beside Play (URLs are usually YouTube — needs a tvOS playability check) |
| `chapters` (name, `startPositionTicks`, image tag) | Scene-selection shelf / playback entry points |
| `imageBlurHashes` | Blurhash placeholders for all artwork — biggest available loading-polish win (`ArtworkImage`, hero backdrop) |
| `parentBackdropImageTags`, `parentLogoImageTag`, `seriesPrimaryImageTag`, `seriesThumbImageTag` | Fallback hero art for episodes that lack their own backdrop/logo |
| `indexNumberEnd` | Correct "S01E01–02" labels for multi-episode files |
| `cumulativeRunTimeTicks` | Total runtime for series/box sets |
| `dateCreated` | "Added on …" secondary metadata |
| `tags`, `productionLocations` | Freeform tags; low priority |
| `externalURLs`, `providerIDs` | IMDb/TMDb identifiers — little use on tvOS (no browser) |
| `primaryImageAspectRatio` | Layout stability before artwork loads |
| `specialFeatureCount`, `partCount`, `mediaSourceCount` | Extras/multi-version affordances |
| `customRating`, `airDays`, `airTime` | Niche metadata |

## Not worth mapping

- Photo EXIF: camera make/model, aperture, ISO, GPS, orientation
- Live TV: `channel*`, timers, program fields
- Music: `album*`, `artists`, `songCount` — revisit when music support lands
- Server plumbing: `etag`, `path`, `lockedFields`, `playAccess`, `canDelete`,
  `sortName`, `displayPreferencesID`

## Adoption tiers

1. **Free tier** (no JellyfinKit work): show already-mapped `genres` in the
   hero. — **done**
2. **Adapter tier**: map `criticRating`, `premiereDate`/`endDate`/`status`,
   `studios`, season/episode counts, and distill `mediaStreams` into
   `MediaTechnicalInfo`; surface in `MediaMetadataRow` / `CreditsColumn`.
   — **done**
3. **Feature tier** (each its own feature with UI decisions): trailer button,
   chapter shelf, blurhash placeholders, episode parent-art fallbacks.
   — not started
