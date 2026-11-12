# Spike: Live TV on Apple TV (unticketed)

<!--
Built from docs/spikes/issue-template.md. That template is for a root-cause
investigation; this is a feature spike, so "Symptom" became "What this is" and an
"Open items" section was added. The template's rules still apply:

- Nothing graduates to a doc, issue body, PR, or memory file until it is CONFIRMED here
  with cited evidence. Everything else stays labelled a hypothesis.
- The scaffolding inventory below is a do-not-delete list. It survives until the findings
  are merged and the spike is closed.
- Update this file after every run, before reporting anything.
-->

**Status**: open, on device for soak testing
**Issue**: none yet
**Branch**: `spike/live-tv` (pushed, no PR)
**Started**: 2026-11-11

## What this is

An MVP of Jellyfin Live TV for Apple TV. Vision Pro is deliberately untouched.

| Piece | What it does |
| --- | --- |
| Sidebar entry | The server's Live TV view appears under Libraries and opens the guide. |
| Guide | Channels down the side, twelve hours across, a header describing the focused programme. Select plays the channel. |
| Player | The system player on the server's own stream for the channel, with a Guide tab in the swipe-down panel. |
| On Air Now | A Home shelf below Recently Added, one play-on-select card per channel. |
| Fixture | `server.sh` can add an M3U tuner and XMLTV guide to the UI-check Jellyfin. |

Test setup for everything below: Jellyfin 10.11.11 with an ErsatzTV M3U tuner and XMLTV
guide, five channels. The simulator runs used the Docker fixture on `localhost:8097`. The
device runs use the owner's real server, which has the same ErsatzTV instance as its tuner.

## Hypothesis ledger

Status is one of PROPOSED, TESTING, FALSIFIED, CONFIRMED.

### Confirmed

| ID | Finding | Evidence |
|----|---------|----------|
| H1 | With direct play on offer, Jellyfin hands a client the tuner's raw address, not a stream of its own. | E1 |
| H2 | With direct play refused, Jellyfin returns its own HLS stream for the channel. | E1, E4 |
| H3 | Offered MP4 segments, Jellyfin answers a tuner that disallows them with one progressive file, not HLS, and AVPlayer stops on it within seconds. Asking for MPEG-TS only returns HLS. | E4 |
| H4 | A stopped report that names the live stream makes Jellyfin close the tuner stream. | E5 |
| H5 | The guide froze the app because it sized itself from a measured width and rebuilt every row on each layout pass. | E3 |

| ID | Finding | Evidence |
|----|---------|----------|
| H6 | An XCUITest screen query can stall for over 20 seconds against a playing system player while the app's main thread is idle. | E6 |
| H7 | ErsatzTV delivers about 32 seconds of video at once, then nothing for about 24 seconds, then real time. | E7 |
| H8 | From an XMLTV guide, Jellyfin keeps one image per programme, the poster. Its thumb and backdrop return 404. | E8 |
| H9 | The system player shows the title, second line and its own LIVE badge once the full controls are up. The slim bar seen while buffering shows none of them. | E9 |
| H10 | The guide header's title changed size between programmes because it was allowed to shrink to fit. | E10 |

### Not yet confirmed

| ID | Hypothesis | Status | What would settle it |
|----|-----------|--------|----------------------|
| H11 | The rebuffer about 15 seconds in happens because AVPlayer opens near the end of H7's burst and runs dry. Starting 30 seconds back removes it. | TESTING | Several channel starts on device with no stall in the first minute. One simulator run looked clean (E7). The device soak reported no start-up stall (E11), but nobody counted starts. |
| H12 | A long play hangs after a few minutes, as Swiftfin's open issue #2100 reports on iOS. | TESTING | No hang in hours of play on device (E11). One rebuffer in that time, cause unknown. Read the ErsatzTV and Jellyfin logs for that moment if it recurs. |
| H13 | The system player treats the stream as both live and not live because Jellyfin serves it as a growing playlist with a fixed start. | PROPOSED | Compare against a stream served as a sliding window. It showed a LIVE badge and also offered "From Beginning". |
| H14 | An app killed mid-stream leaves the tuner counted as in use until the server restarts. | PROPOSED | Seen twice (E5 note); not tested on purpose, and no process was left running behind it. |
| H15 | Backing out during the loading spinner no longer leaves a stream open. | PROPOSED | The fix has no test that simulates the cancelled request. Check the server log after backing out mid-load. |

## Experiments run

Append-only. Newest last. All dated 2026-11-11. Server log times are UTC.

### E1 — What Jellyfin returns for a channel (fixture, curl)

- **Targets**: H1, H2
- **Method**: `POST /Items/{channel}/PlaybackInfo` with `AutoOpenLiveStream`, first with a
  direct-play profile, then with direct play refused.
- **Raw output**:

```
direct play offered:  Path http://host.docker.internal:8409/iptv/channel/4.m3u8?mode=segmenter
                      SupportsDirectPlay true, no TranscodingUrl
direct play refused:  TranscodingUrl /videos/{id}/master.m3u8?...&LiveStreamId=...
                      live.m3u8 served segments; POST /LiveStreams/Close -> 204
```

- **Result**: H1 → CONFIRMED, H2 → CONFIRMED

### E2 — How Swiftfin plays a live channel (source read, commit 30c2432)

- **Targets**: H2, H4
- **Method**: read `MediaPlayerItemResolver.swift`, `MediaProgressReporter.swift` and the
  AVPlayer device profile. Nothing was built or run.
- **Result**: Swiftfin never uses the tuner's address, relies on auto-open, sends the live
  stream ID on all three reports, and closes explicitly only for a stream opened and then
  abandoned. This set the design; it confirms nothing on its own.

### E3 — Guide freezes on opening (simulator, `sample`)

- **Targets**: H5
- **Method**: sampled the app's main thread while the UI check sat on a stalled query.
- **Raw output**:

```
LiveGuideView.body -> loaded -> rows.getter -> GuideLayout.cells(...)   (repeated)
GeometryActionBinder.updateValue -> LiveGuideView.viewWidth.setter
```

- **Result**: H5 → CONFIRMED. Fixed with a constant time scale, rows built once per load,
  and the scroll offset kept out of the grid's inputs. The guide then opened in every run.

### E4 — Stream dies with "Operation Stopped" (fixture log, curl)

- **Targets**: H3
- **Method**: read the server's ffmpeg command for the failing session, then asked for the
  same channel with four profile variants.
- **Raw output**:

```
failing session:   ffmpeg ... -y "/cache/transcodes/147ed5...ts"      (one progressive file)
container mp4,ts:  TranscodingUrl /videos/{id}/stream?...   subprotocol http
container ts:      TranscodingUrl /videos/{id}/master.m3u8  subprotocol hls
container mp4:     TranscodingUrl /videos/{id}/stream?...   subprotocol http
```

- **Result**: H3 → CONFIRMED. The live profile now asks for `ts` and H.264 only. The
  fixture's tuner has "Allow fMP4 transcoding container" off, which is the default; the
  setting was not tried switched on.

### E5 — Does the tuner get released (fixture log, ErsatzTV log)

- **Targets**: H4, H14
- **Method**: played and left channels from the app, then read both logs.
- **Raw output**:

```
23:34:10 Playback stopped reported by app Jelly Shark 0.11.0 playing Comfort
23:34:10 Live stream 370ee7... consumer count is now 0
23:34:10 Live stream ..._370ee7... closed successfully
ErsatzTV 16:35:08 -07:00 Terminating HLS session for channel 5
```

- **Result**: H4 → CONFIRMED on three channels. ErsatzTV ends its own session about a
  minute after the last request. Note for H14: after two test runs were killed mid-play,
  the Star Trek stream stayed at "consumer count is now 2" with no ffmpeg running.

### E6 — Back from the player stalls the UI check (simulator, `sample`)

- **Targets**: H6
- **Method**: sampled the app nine seconds after Back was pressed, in a run that stalled.
- **Raw output**: main thread 2191 of 2202 samples in `mach_msg2_trap`; video still playing.
- **Result**: H6 → CONFIRMED. Back had only hidden the controls. The check now asks the
  server whether playback has stopped instead of querying the screen.

### E7 — Rebuffer about 15 seconds in (fixture transcode log, simulator)

- **Targets**: H7, H11
- **Method**: read the frame counter over time in `/config/log/FFmpeg.Remux-*.log`, then
  set the player to start 30 seconds behind the newest video and reran the check.
- **Raw output**:

```
~ 4.0s wall  frame  958  media 00:00:32.03
~28.5s wall  frame 1053  media 00:00:35.99     (nothing arrived in between)
~32.5s wall  frame 1149  media 00:00:40.00     (then 4s of video every 4s)
```

- **Result**: H7 → CONFIRMED. H11 still TESTING: the 20-second screenshot showed a clean
  picture where every earlier run showed a loading bar, and the owner saw no rebuffer on
  the simulator. Not yet judged on device.

### E8 — Which artwork Jellyfin keeps (fixture, curl)

- **Targets**: H8
- **Method**: counted image entries in ErsatzTV's guide file, then asked Jellyfin for each
  image type on an airing programme.
- **Raw output**:

```
guide file: 307 programmes with poster + landscape still, 31 poster only, 864 none
Jellyfin:   Primary 200 (294x440)   Thumb 404   Backdrop 404
```

- **Result**: H8 → CONFIRMED. The app now prefers thumb, then backdrop, then poster, then
  channel logo, which changes nothing for this guide source.

### E9 — No title in the player (simulator screenshots)

- **Targets**: H9
- **Method**: screenshot at 20 seconds, then after a Select press, then after swipe down.
- **Result**: H9 → CONFIRMED. The full controls showed "Star Trek: Voyager", the second
  line and a red LIVE badge. A text "LIVE" the app had added was removed as a duplicate.

### E10 — Title changes size in the guide header (device)

- **Targets**: H10
- **Method**: the owner's two device screenshots showed one title at two sizes. Removed the
  shrink-to-fit setting and reinstalled.
- **Result**: H10 → CONFIRMED by the owner on device ("fix is much better"). Unexplained:
  the title was larger when the description was longer, the reverse of a squeeze.

### E11 — Device soak (Apple TV, Jellyfin 10.11.11, user report 2026-11-12)

- **Method:** Justin used the build on the Apple TV for an evening against the real
  server, and compared it with Swiftfin.
- **Result:** Reported, not instrumented. Playback, the guide and channel switching
  worked throughout. One rebuffer during a session hours long; no hang. No start-up
  stall was reported.
- **Not checked:** which channel or time the rebuffer happened at, so no log was read.

### E12 — Is ErsatzTV filler marked in the guide (ErsatzTV XMLTV, fixture, curl)

- **Method:** Read `/iptv/xmltv.xml` from ErsatzTV and `GET /LiveTv/Programs` from the
  fixture, and compared filler entries with ordinary ones.
- **Result:** Verified: nothing marks filler, in either place. Filler entries are bare.

```
<programme start="20261110231450 -0700" stop="20261110231506 -0700" ...>
  <title lang="en">Attention_Ricky_Gervais</title><previously-shown /></programme>

Jellyfin: "Genres": [], "ImageTags": {}, no Overview, no IsSeries/IsMovie, "IsRepeat": true
```

| Channel | Bare entries | Longest bare | Shortest full entry |
| --- | --- | --- | --- |
| 5 Comfort | 71 | 0.5 min | 5.0 min |
| 6 Horror | 387 | 2.7 min | 24.0 min |

- **Reading:** On this guide, "no genre, no overview, no image, not a series or movie,
  under five minutes" picks out filler exactly. That is a guess about one server's data,
  not a rule other guides promise to follow. Channel 3's music videos are as short
  (1.6 to 11.6 minutes) but carry a category, so the test leaves them alone.

### E13 — Guide and player polish (device, owner's eye, 2026-11-12)

- **Method:** Built each change to the Apple TV; Justin judged it and sent screenshots.
- **Result:** Approved on device: the header in the Home hero's order, progress on the
  artwork, the screen margin, the fact row, the episode title leading in the player, and
  both scroll-edge fades at the values in the table.

| Setting in `GuideMetrics` | Value | Finding |
| --- | --- | --- |
| `leadingFadeLength` | 24 points | 64 and 32 read as programmes vanishing. |
| `leadingFadeDepth` | 0.4 | A partial dim reads as a shadow from the channel column. A full fade "goes full background colour too early". |
| `topFadeLength` | 64 points | Approved. |
| `topFadeDepth` | 1.0 | 0.8 was tried and put back. |
| `topFadeRamp` | 8 points | See below. |

- **The hard line under the ruler.** The top fade first came in over its own 64 points of
  scroll. The grid often rests scrolled by less, so rows showed cut off at the grid's top
  edge. Bringing the fade in over 8 points removed it (approved on device). An earlier
  reading, that the depth setting caused the line, was wrong: the line was there at 1.0.
- **The bottom edge.** The grid stopped at the bottom safe area, which showed as a line.
  It now ignores that edge. The focused last row stays in view (owner, on device, with
  five channels).

### E14 — What else the guide data carries (fixture, curl)

- **Method:** `GET /LiveTv/Programs` for 400 programmes with every optional field asked
  for, counting which fields were filled.
- **Result:** Verified for this guide only.

```
400 programmes: RunTimeTicks 400, IsRepeat 400, Genres 351, EpisodeTitle 342,
IsSeries 342, OfficialRating 114, Overview 114, ImageTags 114, IndexNumber 105,
ProductionYear 9, IsMovie 9, IsNews 1. People, Studios, Taglines, ProviderIds: empty.
```

- **Reading:** Length and year were the only unused fields worth showing, and the header
  now shows both. A real broadcast guide may fill more, such as new and live flags.

## Scaffolding

Do not remove any of this until the spike is closed.

| What | Where | Why it exists |
|------|-------|---------------|
| Throwaway UI check | `docs/spikes/live-tv/UICheckLiveTV.swift` | Drives guide, playback, the Guide tab switch and Home on the simulator. Copy into `Jelly SharkUITests/` to run it, and remove it again afterwards. |
| Live TV step in the fixture script | `.claude/skills/sim-ui-check/server.sh` | Adds the tuner and guide when `UI_CHECK_LIVETV_M3U` and `UI_CHECK_LIVETV_XMLTV` are set. |
| Fixture server | Docker container `js-ui-check-8097` | The server E1, E4, E5, E7 and E8 ran against. Its logs are the evidence; a restart loses them. |
| Swiftfin clone | Session scratch folder, not in the repo | Source for E2. Re-clone at commit `30c2432` to recheck. |

## Current state

**Verified, and in which venue**

| Claim | Venue |
| --- | --- |
| Both suites exit 0, with 32 Live TV tests in Features and a Live TV suite in JellyfinKit. | Host, simulator |
| tvOS and visionOS builds exit 0. | Build |
| Guide opens, focus moves, a channel plays past 20 seconds, the Guide tab switches channel and closes its panel, Back returns to the guide, Home shows the shelf. | Simulator |
| Theming and guide traversal look right. | Simulator, by the owner |
| The guide header's title holds one size. | Device, by the owner |
| Hours of play with no hang and one rebuffer (E11). | Device, by the owner |
| Guide header layout, margin, fades, and the player's title order (E13). | Device, by the owner |

**Not verified anywhere**: all five themes on device, and a guide with more channels
than fit one screen.

**Decisions made along the way**

| Decision | Why |
| --- | --- |
| A separate live player, not a branch in `PlaybackViewModel`. | That type manages resume, duration, track rebuilds and Up Next, none of which a channel has. The owner plans to refactor the existing player separately. |
| Always play the server's stream, never the tuner's address. | H1, and the device often cannot reach the tuner. |
| Playback starts 30 seconds behind the newest video. | H7 and H11. |
| The channel is in the card's caption, not a badge on the artwork. | The shelf card has no badge slot. |
| The guide header copies the Home hero's order, tokens and spacing, with the detail page's fact row. | The owner's call (E13): similar views should read alike. |
| The header does not show the time range or channel. | The grid already shows both for the focused cell. VoiceOver still reads them. |
| For an episode the live player leads with the episode title. | Matches the library player. The guide header and shelf cards lead with the series, as the Home hero does. |
| Episode codes are written `S1E26`. | The form the rest of the app uses. |
| The live stream ID reaches playback reports through a registry inside the client. | No report call had to change its signature. |

## Open items

### Must settle before this merges

1. **A guide with more channels than fit one screen.** Every check so far had five.
   Scrolling, the bottom edge and load time are unproven beyond that.
2. **A frozen or ended stream is not detected.** Only an outright player failure is. The
   live player has no stall watchdog and no reconnecting banner.
3. **A server with Live TV and no other library** shows Home's "Nothing Here" and no shelf.
4. **How the branch lands.** One PR or several, and the doc updates that go with it:
   `JELLYFIN_INTEGRATION.md`, `MEDIA_DETAIL_DATA.md`, the PRD's Live TV non-goal, and an
   `ARCHITECTURE.md` row for the separate player.
5. **Tests for two fixes that have none**: the open that must survive dismissal (H15), and
   the registry entry cleared when a stopped report fails.

### Worth doing, not blocking

1. **Poster art is cropped to 16:9.** Proposed: show it whole over a blurred copy of
   itself. Needs an opt-in presentation on `ArtworkImage` and `ArtworkShelfItem`.
2. **The Guide tab's second lines are cut off.** Channel, next programme and time do not
   fit one line at that card width.
3. **No badge slot on the shelf card.** The watched channel is marked with text "LIVE".
4. **Guide reloads can overlap** at the half hour, and the guide is only proven for tens of
   channels.
5. **The live timeline can be scrubbed back** (H13). Decide whether that is wanted.

### Postponed

**Filler shows as tiny guide cells (E12).** Waiting on Justin's look at ErsatzTV's guide
mode options, which may hide filler at the source. If that does not pan out, the proposed
app-side fix:

1. When building guide rows, fold an entry into the programme before it when it has no
   genre, overview, image or episode number, is neither series nor movie, and runs under
   five minutes.
2. Use the same folded list for now and next, so the player and shelf never name a
   filler clip.

The rule is exact on this guide and a guess for others.

## Open questions

Things a fresh agent picking this up would need answered.

1. Does the rebuffer fix hold on device across all five channels (H11)?
2. With the tuner's "Allow fMP4 transcoding container" switched on, does the TS-only
   profile still get an HLS stream?
3. What does a tuner that is truly real time, with only a few seconds on hand, do with a
   30-second start offset?
4. Why did the header's title grow when the description was longer (E10)?
