# Playback Matrix

What actually happens to a given source when it travels a given delivery path, verified against a live server rather than inferred from documentation.

Most playback questions in this project are not "does AVPlayer support HEVC" — they are "what happens to HEVC-in-MKV with Dolby Vision and TrueHD when the server hands it over as HLS fMP4." The **delivery path** is what decides outcomes, so it is the axis this document is organised around.

> **Every claim here carries a verification marker.** ✅ verified means it was measured against a live server on the date given. ⚠️ inferred means it follows from something verified but was not directly observed. ❓ untested means nobody has checked. Do not promote a marker without re-running the probe.

---

## Verification baseline

| | |
|---|---|
| **Jellyfin server** | 10.11.11 |
| **Server ffmpeg** | jellyfin-ffmpeg 7.1.4 (a [fork](https://github.com/jellyfin/jellyfin-ffmpeg), not upstream) |
| **Server hardware** | Synology DS1522+, AMD Ryzen R1600 — **no iGPU, so no hardware encode** |
| **Client** | AVFoundation on macOS 26 (asset-level probes) and Apple TV 4K (device observations) |
| **Verified on** | 2026-08-02 unless a row says otherwise |

The no-iGPU detail matters more than it looks: every "the server re-encodes" outcome below is catastrophic on this host specifically, and merely slow on a host with QSV/NVENC. Throughput figures do not transfer between servers; **behavioural** findings (codec tags, box presence, manifest attributes) do.

### Reference sources

Described by characteristics rather than title, per project convention.

- **Source A** — 4K HEVC MKV, 10-bit, **DV profile 8** (`DvBlSignalCompatibilityId 1`), E-AC-3 JOC Atmos 5.1 @ 768 kbps, four SRT subtitle tracks, ~25 Mbps, 133 min.
- **Source B** — 4K HEVC MKV, 10-bit, **DV profile 7.6** (`DvBlSignalCompatibilityId 6`, `ElPresentFlag 1`), TrueHD Atmos 7.1 @ 4559 kbps + AC-3 5.1 @ 640 kbps + DTS-HD MA + FLAC + four AC-3 commentary tracks, PGS subtitles, ~90 Mbps, 103 min.

---

## The four delivery paths

| Path | URL shape | Built by |
|---|---|---|
| **Direct Play** | `/Videos/{id}/stream[.{container}]?static=true` | `StreamURLBuilder.directPlayURL` |
| **HLS MPEG-TS** | `/Videos/{id}/master.m3u8` + `SegmentContainer=ts` | `StreamURLBuilder.hlsURL` |
| **HLS fMP4** | `/Videos/{id}/master.m3u8` + `SegmentContainer=mp4` | `StreamURLBuilder.hlsURL` |
| **Progressive** | `/Videos/{id}/stream.mp4?static=false` | *not built by the app* |

`hlsURL` picks the segment container from the **source** video codec: HEVC gets fMP4, everything else gets TS. HEVC in MPEG-TS is audio over a black screen on Apple's stack (#73), and an fMP4 stream-copy has irregular fragments AVPlayer hitches on (#99) — so the container choice is a trade between two known defects, not a free parameter.

---

## Master matrix

| Source shape | Direct Play | HLS TS | HLS fMP4 | Progressive |
|---|---|---|---|---|
| H.264 / MP4 / SDR / AAC | ✅ plays | ✅ plays | ⚠️ works | ❓ |
| HEVC / MP4 / any | ✅ plays | ❌ black screen | ✅ plays | ❌ unplayable |
| HEVC / MKV / SDR | ❌ container | ❌ black screen | ✅ plays | ❌ unplayable |
| HEVC / MKV / DV profile 8 | ❌ container | ❌ black screen | ✅ **DV signalled** | ❌ unplayable |
| HEVC / MKV / DV profile 7 | ❌ container | ❌ black screen | ⚠️ **tone-mapped, ~0.4× realtime** | ❌ unplayable |
| any + TrueHD / DTS audio | ❌ codec | — | ⚠️ audio re-encoded | ⚠️ audio re-encoded |
| any + PGS subtitle selected | — | — | ⚠️ burn-in forces re-encode | ❌ subtitles dropped |

"❌ container" means Jellyfin's `directPlayProfiles` claims only `mp4,m4v,mov`, so MKV never direct-plays regardless of codec — the single largest reason a typical library transcodes.

Three clarifications on that table. The **Progressive** column describes *Jellyfin's* progressive endpoint, which is unplayable for container reasons (`hev1`, no `moov`) — a well-formed progressive file plays fine, see the HDR section. **Direct Play ✅ holds for HDR sources on SDR displays**, verified on device; the HLS variant-eligibility gate does not apply there. And the two **HDR MKV rows no longer describe what an SDR display gets**: since #172 those sessions take `RemuxHLSDelivery` instead, which replaces the profile-7 row's `~0.4× realtime` with measured realtime playback and no server transcode at all. The columns here are server-side delivery modes, and the remux is not one; see "Acceptance round run 2026-08-11" below for what those sources actually do now.

---

## Video

### Codec tags

The MP4 sample-entry tag decides whether AVFoundation will open the stream at all. Apple requires **`hvc1`**; `hev1` carries parameter sets in-band and is refused.

| Path | Tag emitted | Verified |
|---|---|---|
| HLS fMP4 | **`hvc1`** | ✅ 2026-08-02, `ffprobe` on the `EXT-X-MAP` init segment |
| Progressive | **`hev1`** | ✅ 2026-08-02, `ffprobe` on 24 MB pulled from the live endpoint |

MKV sources carry **no sample-entry tag at all** — the concept is MP4-specific. This is why `DeviceProfile+JellyShark.swift` scopes its `hvc1` requirement to the mp4 container family: an unscoped condition always fails on MKV and forces a pointless re-encode (#146).

> ⚠️ **Probe trap.** Declaring `VideoCodecTag EqualsAny hvc1` unscoped in a DeviceProfile makes PlaybackInfo return `TranscodeReasons: …,VideoCodecTagNotSupported` on any MKV source. That is the profile misbehaving, not the server.

### Dolby Vision

DV is signalled **differently per path**, and looking in the wrong place produces a false negative.

| Path | Mechanism | Present? |
|---|---|---|
| HLS fMP4 | `SUPPLEMENTAL-CODECS` on `EXT-X-STREAM-INF` | ✅ verified |
| Progressive | `dvcC`/`dvvC` box in the container | ❌ **absent** |

Observed on the HLS master playlist for Source A:

```
#EXT-X-STREAM-INF:BANDWIDTH=25355375,VIDEO-RANGE=PQ,
  CODECS="hvc1.2.4.L150.B0,mp4a.40.2",
  SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",
  RESOLUTION=3840x2160,FRAME-RATE=23.976
```

`dvh1.08.06/db1p` reads as DV profile 8, level 6, HDR10-compatible base layer. This is the HLS-native signalling Apple's authoring spec prescribes for cross-compatible profile 8.1 — the `hvc1` track carries the HDR10 base and DV is advertised at the manifest level. **The absence of a `dvcC` box in the init segment is correct here, not a defect.**

The progressive path has no manifest to carry it, and ffmpeg refuses to write the container box:

```
[mp4 @ ...] Not writing 'dvcC'/'dvvC' box. Requires -strict unofficial.
```

Jellyfin does not pass `-strict unofficial`, and no client parameter makes it.

✅ **`remove_dovi` does not fire on the progressive path** — the DOVI configuration record appears identically on ffmpeg's input and output side data.

### DV profile 7 is declared unsupported, deliberately

`AVFoundationPlayerEngine.swift:109` declares `SDR|HDR10|HLG|DOVIWithHDR10`. **`DOVIWithEL` is deliberately omitted**, so profile-7 sources (Source B's shape) are not offered a DV variant and the server tone-maps instead.

> ⚠️ **The stated rationale has been falsified.** The comment at `AVFoundationPlayerEngine.swift:86` justified the omission on the grounds it selects the server's strip-to-HDR10 copy path on 10.11+. Measured 2026-07-28 against 10.11.11: the server **tone-mapped** instead, running `libx264` with `tonemapx` at ~0.4× realtime — first frame frozen, playhead never moved.
>
> Declaring `DOVIWithEL` is now a one-line change and remains an **untested** experiment. `DvBlSignalCompatibilityId 6` implies an HDR10-compatible base layer, which makes it plausible rather than speculative.

### HDR variant selection

AVFoundation refuses HDR **variants** on SDR displays (`-12927`), and the gate cannot be blinded — stripping `VIDEO-RANGE` changes nothing (#146). The master playlist for Source A shows why this is decisive:

| Variant | `VIDEO-RANGE` | `CODECS` | Copy? |
|---|---|---|---|
| 1 | `PQ` | `hvc1.2.4.L150.B0` + `SUPPLEMENTAL-CODECS` | yes |
| 2 | `SDR` | `hvc1.1.4.L120.B0` | **no** — `AllowVideoStreamCopy=false`, `hevc-profile=main` |
| 3 | `SDR` | `avc1.424029` | **no** — `AllowVideoStreamCopy=false` |

✅ All three advertise **identical `BANDWIDTH=25355375`**. AVFoundation therefore cannot discriminate by bitrate; selection falls entirely to `VIDEO-RANGE` eligibility. The two SDR entries are the server-injected re-encode variants #146 identified, captured here directly.

### The gate is HLS-only — non-HLS HDR plays fine on an SDR display

✅ Verified 2026-08-02 on **Apple TV 4K driving a 1080p SDR panel** (the same rig as #146's `-12927` capture), observed on the panel and reproduced on the tvOS simulator at 1080p.

A locally-remuxed progressive HDR file — `hvc1`, `color_transfer=smpte2084`, `ec-3` audio, produced with `ffmpeg -c copy -tag:v hvc1 -strict unofficial -movflags +faststart` — was added to the library and **direct-played**. It loaded fast, the playhead advanced through real content (`pos=0` → `178584899`, ~17.9s), and colour was correctly tone-mapped.

So `-12927` is a property of **HLS variant selection**, not of HDR content on SDR displays. The gate evaluates `EXT-X-STREAM-INF` entries and rules some ineligible; an asset with no manifest has nothing to be ruled ineligible. #146's "the gate cannot be blinded" is correct **within HLS**, and does not extend to non-HLS delivery.

> ⚠️ **Superseded 2026-08-02, same day, by device measurement (below).** This block previously concluded that delivering HDR to SDR displays "requires a non-HLS mode" via a progressive fragmented MP4. Both halves of that were falsified on the device: the progressive mode is dead, and the gate turns out not to reach master-less HLS at all.

### The gate reads declared master attributes — and a media playlist has none

✅ Measured 2026-08-02 on the Apple TV 4K + 1080p SDR panel rig, via headless `RunCodeSnippet` probes loading `AVPlayerItem`s from a LAN HTTP server (verdicts beaconed back as HTTP requests; assets were synthesized `libx265` PQ content with `color_transfer=smpte2084` verified via ffprobe). All four cells same device, same session:

| Playlist | Declares | Content | Verdict |
|---|---|---|---|
| Master, `RESOLUTION=1920x1080` + `VIDEO-RANGE=PQ` | 1080p PQ | 1080p PQ | ✅ plays, all segments fetched |
| Master, `RESOLUTION=3840x2160` + `VIDEO-RANGE=PQ` | 4K PQ | either | ❌ instant refusal, only the master ever fetched |
| Master, 4K PQ + `SUPPLEMENTAL-CODECS="dvh1.08.01/db4h"` | 4K DV | 1080p PQ | ❌ instant refusal, same codes |
| **Media playlist, no master** (`EXT-X-MAP` + fMP4 segments) | nothing | genuine 4K PQ | ✅ `readyToPlay`, `rate=1.0`, init + segments fetched and buffered |

Two consequences:

1. **The gate keys on declared 4K attributes, not `VIDEO-RANGE=PQ`.** A 1080p PQ master plays on the SDR panel. On tvOS 26.6 the refusal surfaces as `AVFoundationErrorDomain -11868` with underlying `CoreMediaErrorDomain -17223` (not the `-12927` recorded from #146 — same gate, different surface error).
2. **A media playlist with no master never reaches variant selection** — nothing is declared, so nothing can be ruled ineligible — and the display pipeline tone-maps genuine 4K PQ segments on-device. This is the delivery mode #172 now implements (`RemuxHLSDelivery` → `RemuxHLSServer`, serving `HLSSegmentPlan`'s playlist over the in-app Matroska remux).

⚠️ Not verified in that probe: frame advancement (headless snippets have no display surface; playhead stayed at 0.00) and audio (the probe content had none).

✅ **Acceptance round run 2026-08-11**, in-app on the SDR-panel Apple TV, closing both gaps. DV profile 8.1 + E-AC-3 4K MKV sustained **0.994× and 0.984× realtime** with ~80s of buffer, against the 0.88× tone-map starvation this delivery exists to replace; colors confirmed correct by eye. Server side ran **zero ffmpeg jobs** for those sessions — not a cheap transcode, none at all — while the same window's copy-variant and interposer sessions each logged `-codec:v:0 copy`. Segment production ran 0.04–0.34s against ~6s of content, with three outliers to 1.35/2.07/2.17s, all absorbed by the buffer. Memory topped out at **120 MB** during 4K remux playback (span-sized buffers are the working set; note the ARCHITECTURE target of <100 MB excludes media cache). Profile-7 sources needed the signalling fix above before they passed.

✅ Vision Pro, same day: all three HDR MKV sessions logged `[delivery] HLS interposer` with `displayHDR=true`, no `[remux-hls]` or `[copy-variant]` line anywhere — the delivery is inert on HDR displays, as designed.

### The server's own copy variant also plays master-less

✅ Measured 2026-08-02, same rig, against a real library source: 4K Dolby Vision **profile 7** (`DOVIWithEL`) MKV with DTS-HD MA audio — a source the in-app remux declines (`A_DTS` is not carriable). A PlaybackInfo negotiation permitting hevc copy produced a Jellyfin master in the #146 shape: the copy variant (`VIDEO-RANGE=PQ`, `hvc1.2.4.L153.B0`, `AllowVideoStreamCopy=true`) beside two injected SDR re-encode variants. Loading that variant's `main.m3u8` **directly, no master** on the SDR-panel Apple TV:

- `readyToPlay` in **4s**; playhead tracked wall clock at **rate 1.0 for 48s+**, buffer grew to **102s ahead**, never `isPlaybackBufferEmpty`.
- Server side ran as `FFmpeg.DirectStream`: `-codec:v:0 copy -codec:a:0 ac3` at **9.89× realtime** (the tone-map re-encode of the same class of source runs 0.88× and starves).
- Profile 7 is copied signalled as plain PQ HEVC — AVFoundation decodes the HDR10-compatible base layer and ignores the unsignalled EL/RPU NALs; the display tone-maps on-device. Note: the app's engine capabilities exclude `DOVIWithEL`, so the session's own master omits the copy variant — the delivery re-resolves with the range widened for exactly this resolve.
- ✅ **Declaring `DOVIWithEL` selects a stream copy, not another tone-map** (this was an open question). Confirmed again 2026-08-11 by contrast across two devices on the same profile-7 source: the widened copy variant ran `-bsf:v hevc_mp4toannexb` with the **DV RPU preserved**, while the ordinary path on Vision Pro ran `-bsf:v hevc_mp4toannexb,hevc_metadata=remove_dovi=1` and stripped it. The widening is what buys the copy, and it is scoped to that one resolve.
- ⚠️ ffmpeg logged a benign-looking `dts ... out of range` timestamp warning during the copy; nothing observable client-side, but worth remembering if A/V sync issues surface.

This is `RemuxHLSDelivery`'s ladder rung 2 (`HLSMasterCopyVariant`): remux → master-less server copy variant → interposed HLS tone-map.

### Progressive fMP4 is dead: the file reader ignores `sidx`

❌ Measured 2026-08-02, two device rounds against the branch's loopback progressive server, with structurally different `moov`s (one with `mehd`, one declaring no duration anywhere): identical failure signature — AVPlayer linear-scans the whole virtual file with 16KB-aligned resume ranges, never jumps via the index, never reads the tail, buffered stays 0.0s until the first-frame watchdog kills the session (~30s). AVFoundation's progressive (file-parser) reader drives off `moov` sample tables and categorically ignores `sidx`; only the manifest-driven stack consumes segment indexes. A full-`moov` progressive head is unreachable for a live remux — per-sample tables require scanning the entire source. Hence the pivot above.

### The SDR fallback is app-clamped, and it starves

The 15 Mbps / 1080p cap on the SDR path is **ours, not the server's**. `TrickplayHLSPlaylist.clampedSDRURI` injects `VideoBitrate=15000000&MaxWidth=1920`, and `clampedSDRTagLine` rewrites the advertised `BANDWIDTH`/`RESOLUTION` to match. (Recorded because #172 previously carried this as an open question against server-side stream limits — nothing server-side is involved.)

❌ It does not sustain playback. Measured 2026-08-02 on Apple TV 4K against the 1080p panel: the server ran `libx264` + `tonemapx` at **`speed=0.881x`**, and the playhead advanced 95.86s in 114s of wall clock — **0.84× realtime** — before freezing permanently. The clamp's own comment records a bench figure of 1.14× for 1080p/15M and names 720p/8M as the retreat, but the field is worse than the bench even on an easier source, because a real session also serves trickplay tiles, subtitle renditions and artwork.

⚠️ The 720p retreat was **considered and rejected** (#172): it permanently degrades every SDR-display session to accommodate one server's CPU, and no other client makes that trade — Swiftfin defaults to VLCKit, Infuse ships its own decode stack, and neither routes 4K HDR through a server-side tone-map. The clamp treats the symptom of being on the wrong delivery path. The `TrickplayHLSPlaylist` comment was corrected on the #172 branch; the clamp still governs whatever stays on server HLS (non-MKV HDR sources, and remux-delivery fallbacks).

---

## Audio

### What AVFoundation can decode

`AVFoundationPlayerEngine.swift:45` (direct play) and `:163` (transcode):

| Codec | Direct play | Transcode target |
|---|---|---|
| AAC, AC-3, E-AC-3 | ✅ | ✅ |
| FLAC, ALAC | ✅ | — |
| **TrueHD** | ❌ | ❌ |
| **DTS / DTS-HD MA / DTS:X** | ❌ | ❌ |

This is a description of the framework, not a policy choice. **No delivery path changes it, and neither does remuxing** — repackaging TrueHD into fMP4 still hands AVFoundation a codec it refuses.

### Dolby Atmos

| Carriage | Reachable? |
|---|---|
| **E-AC-3 JOC** | ✅ yes — copies through, Atmos preserved |
| **TrueHD Atmos** | ❌ **never** — no decoder, and ffmpeg cannot *encode* E-AC-3 JOC, so no transcode can recreate it |

TrueHD-only Atmos — the common UHD Blu-ray remux shape — is unreachable by every path the app has or plans. Tracked as #221. It is **codec-shaped, not container-shaped**, so it lies outside what #172 or #176 could ever fix.

### ✅ Fixed: the audio budget used to destroy E-AC-3 Atmos

**Fixed in #222** — `StreamURLBuilder.audioBitrate` raised from 192 kbps to 1.5 Mbps. Recorded here because the mechanism is non-obvious and worth not reintroducing.

`AudioBitrate` is a **ceiling the server copies under and re-encodes over**, not a target. The old 192 kbps value was correct as the audio share of a *re-encode* budget, but it was sent unconditionally — so on Source A's **768 kbps** Atmos track the server could not stream-copy and was obliged to re-encode to AAC, taking the object metadata with it.

✅ Measured 2026-08-02, five runs, each with a unique `DeviceId`/`PlaySessionId`:

| Run | `AudioCodec` sent | `AudioBitrate` | Server chose | Delivered |
|---|---|---|---|---|
| A — **today's behaviour** | `aac,ac3,eac3` | `192000` | `aac` | `aac / mp4a / 6ch` |
| B | `aac,ac3,eac3` | `1536000` | **`copy`** | **`eac3 / ec-3 / 6ch`** |
| C | `eac3,ac3,aac` | `1536000` | **`copy`** | **`eac3`** |
| D | `eac3,ac3,aac` | *omitted* | **`copy`** | **`eac3`** |
| E | `eac3` | *omitted* | **`copy`** | **`eac3`** |

Run B is the control that matters, and it is also the verification of the fix: **the codec list is unchanged from what the app sends** and only the budget was raised — and the server switched to `copy`. Codec ordering is irrelevant; the ceiling was the entire cause.

⚠️ By the same mechanism, AC-3 5.1 at 640 kbps was also above the old ceiling and should also have been re-encoding. Not directly measured, but 1.5 Mbps clears it too.

Raising the ceiling cannot let an undecodable track through: `AudioCodec=aac,ac3,eac3` already bounds what may be copied, so TrueHD and DTS still re-encode regardless of headroom. The cost is that a genuine re-encode is now permitted a higher bitrate than it needs.

Two more precise fixes were considered and not taken, since they need the selected audio stream at URL-build time: omitting `AudioBitrate` entirely when the source codec is already client-playable, or deriving the ceiling from that stream's actual bitrate. Worth revisiting if the re-encode bitrate ever matters.

---

## Subtitles

| Source format | HLS fMP4 | Progressive |
|---|---|---|
| SRT / SUBRIP | ✅ WebVTT renditions via `EXT-X-MEDIA` | ❌ dropped |
| PGS / VobSub | ⚠️ not text-servable — server burns in, forcing a full re-encode | ❌ dropped |

✅ Progressive drops subtitles entirely — `subtitle:0KiB` in the transcode log for a source carrying four SRT tracks.

Jellyfin's WebVTT output carries `X-TIMESTAMP-MAP=MPEGTS:900000`, which lands every cue 10s late on fMP4 (zero-based) but is correct on TS. `PlaybackLocalServer` strips it container-awarely (#90).

Related open work: #175 (render image subtitles on device), #177 (ASS/SSA), #184 (reconciliation on sources with many renditions), #218 (a burn-in preference set on another client fails playback invisibly).

---

## Trickplay

✅ The server advertises native trickplay in the master playlist:

```
#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=5295,RESOLUTION=320x180,CODECS="jpeg",
  URI="Trickplay/320/tiles.m3u8?..."
```

The app nonetheless synthesizes its own I-frame rendition through `PlaybackLocalServer`. Whether the native rendition could replace that is ❓ untested. Relevant to #59 and #171.

---

## Throughput on the reference server

Delivery is **I/O-bound, not encode-bound**, which is easy to misread.

✅ ffmpeg self-reports `speed= 94.2x` to `108x` on a 4K HEVC stream-copy. Measured delivery rates across every probe cluster at **35.8–60.4 MiB/s (~500 Mbps)** regardless of source bitrate, audio codec, or whether an encoder is in the graph.

So the "realtime multiple" is simply *(I/O ceiling ÷ source bitrate)*:

| Source | Bitrate | Multiple |
|---|---|---|
| Source A | ~25 Mbps | ~20× |
| Source B | ~90 Mbps | ~3.3–5.6× |

⚠️ Do not cite a realtime multiple as evidence of encoding cost. Compare absolute byte rates instead.

For contrast, the **tone-map** path on this host runs at **~0.4× realtime** with a frozen first frame — the only measurement here that represents a broken experience rather than a slow one.

---

## What the source MKV already contains

Measured 2026-08-02 with a Swift Matroska parser against two real sources (the #176 spike, since deleted — its findings live on here and in docs/ARCHITECTURE.md's 2026-08-02 decision row; the parser itself became `MatroskaDemuxer` in JellyfinKit). This matters because it bounds what an in-app remuxer would have to *construct* versus merely copy — and the answer is that it constructs almost nothing.

| Wanted for an fMP4 | Where it already is | Consequence |
|---|---|---|
| `hvc1` sample entry config | `CodecPrivate` for `V_MPEGH/ISO/HEVC` **is** the `hvcC` payload, byte-identical | ✅ copy, not synthesise — this is the tag Jellyfin's progressive path gets wrong |
| Video sample data | Length-prefixed NALUs, **not** Annex B | ✅ byte copy; no bitstream conversion, decode, or re-encode |
| Dolby Vision config | 24-byte `DOVIDecoderConfigurationRecord` under a `BlockAdditionMapping` of type `dvcC` | ✅ the box ffmpeg refuses to write is in the file |
| Seek index | `Cues`, reachable directly via `SeekHead` | ✅ 8,759 and 78,069 cue points parsed on the two sources |
| Duration | `Info` → `Duration` × `TimestampScale` | ✅ needed for `mehd` on a fragmented init |

✅ Indexing cost over `Range`: **five requests, under 4 MB** on both a 25 GB / 6-track source and a 65 GB / 37-track one, with cue offsets landing exactly on Cluster elements at 12.9 GB and 29 GB depth.

### Dolby Vision profile 7 needs a NAL filter

Profile 7 is dual-layer, and the observed source carries it **single-track**: the enhancement layer is remapped to `UNSPEC63` and the RPU to `UNSPEC62`, both in the video track at `nuh_layer_id=0`.

**Apple does not decode profile 7** — tvOS supports profile 5 and 8.1; profile 7 is a disc format. The remux drops the `UNSPEC63` NALUs and keeps the base slices.

❌ **Re-signalling the result as profile 8.1 does not work, and was removed.** The obvious conversion — drop the EL, keep the `UNSPEC62` RPU, author a `dvcC` declaring profile 8.1 on the strength of `DvBlSignalCompatibilityId 6` — is what this document previously described as "established". Measured 2026-08-11 on the SDR-panel Apple TV against **four** profile-7 library sources: every one decoded with intact geometry and catastrophic chroma (a green/magenta ruin), while profile-8.1 sources on the identical code path were correct. The cause is that a profile-7 RPU carries **dual-layer** composition metadata (NLQ coefficients describing reconstruction from the EL residual) which profile 8.1 does not have. Relabelling the configuration record leaves that RPU in the stream, the display pipeline engages the DV composer, and it applies two-layer mapping to a base layer whose EL has just been stripped. An honest conversion must **rewrite the RPU** (what `dovi_tool --mode 2` does); this remuxer does not, so it must not claim profile 8.1.

✅ **Unsignalled is correct**: `signalledForAVFoundation()` returns `nil` for profile 7, so the init segment carries `hvcC` alone with no DV box, and the decoder renders the HDR10 base layer. Device-verified 2026-08-11 across three profile-7 sources (two AC-3, one FLAC): correct colors, fast load, no stalls. This is the same shape ladder rung 2 already served correctly — see "The server's own copy variant also plays master-less" — which is the corroborating evidence that the bitstream was never the problem, only the claim made about it. The delivery serves SDR displays exclusively, and those tone-map either way, so no DV rendering is lost.

✅ Dropping the EL costs nothing on the measured source: across 40 sampled frames the EL was **5,958 bytes — 0.05% of video payload**, ~149 bytes per frame, *smaller than the RPU*. That is a **MEL** (Minimal Enhancement Layer), not a FEL. A FEL would be 20–30% of the bitrate; EL byte share is a cheap way to tell them apart.

---

## Range and seekability

| Endpoint | `Accept-Ranges` | Behaviour |
|---|---|---|
| `static=true` (original file) | ✅ `bytes` | 206 + correct `Content-Range` at arbitrary offsets |
| Progressive `stream.mp4` | ❌ `none` | 200 + `Transfer-Encoding: chunked`; `Range` ignored, including mid-file |

✅ The `static=true` result is load-bearing for #176: an in-app demuxer can read the Matroska Cues and range-fetch cluster offsets against this endpoint. That prerequisite is **verified**.

The progressive stream additionally has **no `moov` at the head** (top-level boxes observed: `moof`, `moof`), so there is nothing for AVFoundation to initialize from. Combined with the `hev1` tag, this is why an `AVURLAsset` pointed at it throws `Operation Stopped` on `isPlayable`, `duration` and `tracks`, and never reaches `readyToPlay`. ✅ Verified on macOS, which is more permissive than tvOS.

`startTimeTicks` is accepted and streams (200), making it the only available seek mechanism on that path. ❓ It was **not** verified that the delivered content actually begins at the requested offset.

---

## How to re-verify

1. Read `SERVER` and `KEY` from 1Password into environment variables; never echo them. Use an `X-Emby-Token` header so the key stays out of server access logs.
2. Pull the real bytes and inspect them with `ffprobe`. **Do not trust the server's own transcode log** for what was delivered — it records intent.
3. For HLS, walk master playlist → variant playlist → `EXT-X-MAP` init segment. The init segment is where codec tags and box structure live.

### Gotchas that will silently corrupt results

- ⚠️ **Use a unique `DeviceId` *and* `PlaySessionId` per probe.** Jellyfin keys transcode sessions on them; reusing either serves an earlier run's output while the manifest reflects the new request. This produced a false "Atmos is unreachable" result on 2026-08-02 before it was caught — the tell was the master advertising `ac-3` while the init segment contained `mp4a`.
- Stop sessions afterwards: `DELETE /Videos/ActiveEncodings?deviceId=…&playSessionId=…`
- `mediaSourceId` is **required** on `master.m3u8` (400 without it) but **optional** on the progressive endpoint, which happily starts transcoding without one.
- A Jellyfin **API key is not a user token** — `/Users/Me` rejects it. Verify auth against `/System/Info`, resolve a user id from `/Users`.
- ⚠️ `/Items?videoRangeTypes=…` is a **no-op filter on 10.11.11** — every value returns the unfiltered total. `is4K=true` does work.
- `fields=MediaSources` populates for Movies in list queries but is unreliable in bulk; re-fetch candidates by `ids=` for a dependable pass.

---

## Open questions

| Question | Tracked |
|---|---|
| Is there any tvOS path to TrueHD Atmos? | #221 |
| Does `startTimeTicks` content actually start at the requested offset? | #172 |
| Could the server's native trickplay rendition replace the synthesized one? | #59 / #171 |
| Does the fMP4 fragment-boundary theory explain the #99 frameskip? | #99 |

---

## Related documents

- [JELLYFIN_INTEGRATION.md](JELLYFIN_INTEGRATION.md) — endpoints, auth, caching
- [ARCHITECTURE.md](ARCHITECTURE.md) — module structure and the decision log, including the binary-dependency policy (#178) that governs #176
