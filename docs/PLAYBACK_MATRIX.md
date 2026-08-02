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

Two clarifications on that table. The **Progressive** column describes *Jellyfin's* progressive endpoint, which is unplayable for container reasons (`hev1`, no `moov`) — a well-formed progressive file plays fine, see the HDR section. And **Direct Play ✅ holds for HDR sources on SDR displays**, verified on device; the HLS variant-eligibility gate does not apply there.

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

> ⚠️ **This is load-bearing for #176.** An app-side remuxer serving HLS through `PlaybackLocalServer` hits the *same* gate — correct `hvc1` and `dvcC` do not help, because the gate is about manifests, not containers. Delivering HDR to SDR displays requires a **non-HLS** mode, which means a progressive MP4 with a `moov` at the head, which means the full sample index must be known before the first byte is served. An in-app demuxer reading Matroska Cues is the only component that would have it.

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
| Can a **DV-signalled** progressive file be produced at all? ffmpeg declined to write `dvcC`/`dvvC` even with `-strict unofficial` | #172 — matters only if a progressive mode is built |
| Does declaring `DOVIWithEL` select a strip-to-HDR10 copy, or another tone-map? | #172 comments |
| Is there any tvOS path to TrueHD Atmos? | #221 |
| Does `startTimeTicks` content actually start at the requested offset? | #172 |
| Could the server's native trickplay rendition replace the synthesized one? | #59 / #171 |
| Does the fMP4 fragment-boundary theory explain the #99 frameskip? | #99 |

---

## Related documents

- [JELLYFIN_INTEGRATION.md](JELLYFIN_INTEGRATION.md) — endpoints, auth, caching
- [ARCHITECTURE.md](ARCHITECTURE.md) — module structure and the decision log, including the binary-dependency policy (#178) that governs #176
