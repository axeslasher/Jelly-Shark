# Spike: pure-Swift Matroska demuxer (#176)

> **Throwaway reference. Delete this folder when the real demuxer lands.**
>
> These are standalone `swift` scripts, not part of any target. They exist to
> record *how* #176's Path A/B decision was reached, so the measurements can be
> re-run rather than trusted. They are not production code and are not tested.

The decision they support is on [#176](https://github.com/axeslasher/Jelly-Shark/issues/176); the findings are summarised in [docs/PLAYBACK_MATRIX.md](../../PLAYBACK_MATRIX.md).

## What each one answers

| Script | Question | Result |
|---|---|---|
| `mkvdemux-spike.swift` | Can EBML/Matroska be parsed usefully in dependency-free Swift? | Yes — ~380 lines covers EBML, SeekHead, Info, Tracks, Cues, Clusters, SimpleBlock |
| `mkvdemux-ranged.swift` | Does it work over HTTP `Range` against a real 25–65 GB source? | Yes — full index in 5 requests / 1.9–3.7 MB |
| `mkvdemux-el-probe.swift` | Where does Dolby Vision profile 7's enhancement layer live? | In-band as `UNSPEC63` at layer 0; 0.05% of payload (a MEL) |

## Running them

`mkvdemux-spike.swift` takes a local file:

```bash
# generate a fixture (HEVC Main 10 + AC-3 5.1 in MKV)
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=24:duration=8" \
       -f lavfi -i "sine=frequency=440:duration=8" \
       -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
       -x265-params log-level=none:keyint=48 \
       -c:a ac3 -ac 6 fixture.mkv

swift mkvdemux-spike.swift fixture.mkv
```

The other two read a live Jellyfin source over `Range`, taking `SERVER`, `KEY`
and optionally `ITEM` from the environment. They print no URL and no key:

```bash
SERVER=... KEY=... ITEM=... swift mkvdemux-ranged.swift
SERVER=... KEY=... ITEM=... CLUSTERS=20 swift mkvdemux-el-probe.swift
```

`KEY` is a Jellyfin API key (Dashboard → API Keys), sent as `X-Emby-Token`.

## Findings worth carrying into the implementation

1. **`CodecPrivate` for `V_MPEGH/ISO/HEVC` *is* the `hvcC` payload** — byte-identical
   to what an fMP4 `hvc1` sample entry needs. Copy, don't synthesize.
2. **Frames are length-prefixed NALUs, not Annex B.** Video remux is a byte copy.
3. **`dvcC` arrives via `BlockAdditionMapping`** as a 24-byte
   `DOVIDecoderConfigurationRecord` — the DV box ffmpeg refuses to write.
4. **All three lacing modes occur in the wild** (`none`, `fixed`, `EBML`).
5. **Subtitles arrive as `BlockGroup`**, so keyframe determination must be
   per-track or subtitle blocks get miscounted as video keyframes.
6. **Profile 7 needs a NAL filter**: drop `UNSPEC63`, keep base slices and the
   `UNSPEC62` RPU, author a `dvcC` declaring profile 8.1. Apple does not decode
   profile 7.

## Two bugs these scripts had, because both looked like content findings

Recorded deliberately — a demuxer bug and a real discovery are hard to tell apart,
and both of these produced confident, internally-consistent, wrong output.

- A non-HEVC track's `CodecPrivate` clobbered the NAL length prefix (a FLAC track
  set it to 1). The NALU walker then read garbage lengths, bailed on its sanity
  check, and reported an empty histogram — which read as "no enhancement layer".
- The EL check tested for `nuh_layer_id == 1`. That is the *cross-track*
  dual-layer form; single-track profile 7 remaps the EL to NAL type 63 at layer 0,
  so the probe missed an EL that was plainly there.

## Known rough edges

- `mkvdemux-ranged.swift` mis-prints non-essential SeekHead IDs (shows
  `0x1254C36` where the real ID is `0x1254C367`). The IDs the scripts depend on —
  Info, Tracks, Cues — resolve correctly and their offsets work.
- No lacing support: laced blocks are counted but not split into frames.
- No `Cues`-less fallback. Real code must refuse such files back to the server path.
