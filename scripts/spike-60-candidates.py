#!/usr/bin/env python3
"""List device-round test candidates for spike #60 from a live Jellyfin server.

    JELLYFIN_URL=https://server:8096 JELLYFIN_KEY=<api key or user token> \
        python3 -I scripts/spike-60-candidates.py

Read-only: three kinds of GET, nothing is played or changed. Prints up to
three titles per shape, shortest first. Spike scaffolding (docs/spikes/60.md).
"""

import json
import os
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("JELLYFIN_URL", "").rstrip("/")
KEY = os.environ.get("JELLYFIN_KEY", "")
if not BASE or not KEY:
    sys.exit("Set JELLYFIN_URL and JELLYFIN_KEY (an API key or a user token).")

# Header auth: Jellyfin 12 rejects the api_key query parameter.
HEADERS = {"Authorization": f'MediaBrowser Client="spike-60", Device="probe", DeviceId="spike-60-probe", Version="1", Token="{KEY}"'}


def get(path, **query):
    url = f"{BASE}{path}" + ("?" + urllib.parse.urlencode(query) if query else "")
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as response:
        return json.load(response)


def all_items(user):
    """Every movie and episode. Bulk MediaSources is unreliable, so anything
    that comes back without them is fetched again by id."""
    items, start = [], 0
    while True:
        page = get("/Items", userId=user, Recursive="true", IncludeItemTypes="Movie,Episode",
                   fields="MediaSources,SeriesName", startIndex=start, limit=500)["Items"]
        items += page
        start += len(page)
        if len(page) < 500:
            break
    missing = [i["Id"] for i in items if not i.get("MediaSources")]
    by_id = {i["Id"]: i for i in items}
    for n in range(0, len(missing), 50):
        for item in get("/Items", userId=user, ids=",".join(missing[n:n + 50]), fields="MediaSources,SeriesName")["Items"]:
            by_id[item["Id"]] = item
    return list(by_id.values())


def describe(item):
    source = (item.get("MediaSources") or [{}])[0]
    streams = source.get("MediaStreams") or []
    video = next((s for s in streams if s.get("Type") == "Video"), {})
    audio = [s for s in streams if s.get("Type") == "Audio"]
    subs = [s for s in streams if s.get("Type") == "Subtitle"]

    def is_atmos(stream):
        return "atmos" in f'{stream.get("Profile", "")} {stream.get("DisplayTitle", "")}'.lower()

    return {
        "name": (f'{item["SeriesName"]} S{item.get("ParentIndexNumber", 0):02d}E{item.get("IndexNumber", 0):02d}'
                 if item.get("Type") == "Episode" and item.get("SeriesName") else item.get("Name", "?")),
        "episode": item.get("Type") == "Episode",
        "container": (source.get("Container") or "").lower(),
        "minutes": (item.get("RunTimeTicks") or 0) / 600_000_000,
        "mbps": (source.get("Bitrate") or 0) / 1_000_000,
        "codec": (video.get("Codec") or "").lower(),
        "range": video.get("VideoRangeType") or "",
        "is4k": (video.get("Width") or 0) >= 3800,
        "audio": [(s.get("Codec") or "").lower() for s in audio],
        "eac3_atmos": any(s.get("Codec") == "eac3" and is_atmos(s) for s in audio),
        "truehd_atmos": any(s.get("Codec") == "truehd" and is_atmos(s) for s in audio),
        "image_subs": any((s.get("Codec") or "").lower() in ("pgssub", "dvdsub", "dvbsub") for s in subs),
        "ass_subs": any((s.get("Codec") or "").lower() in ("ass", "ssa") for s in subs),
    }


SHAPES = [
    ("H3/H4 headline: 4K Dolby Vision profile 8 MKV with E-AC-3 Atmos",
     lambda d: d["container"] == "mkv" and d["is4k"] and d["range"] == "DOVIWithHDR10" and d["eac3_atmos"]),
    ("Dolby Vision profile 7 MKV (TrueHD Atmos preferred)",
     lambda d: d["container"] == "mkv" and d["range"].startswith("DOVIWithEL")),
    ("HDR10 MKV with DTS or TrueHD and no Dolby track",
     lambda d: d["container"] == "mkv" and d["range"] == "HDR10" and set(d["audio"]) & {"dts", "truehd"}
     and not set(d["audio"]) & {"ac3", "eac3"}),
    ("H5: MKV episode with two or more audio tracks (audio switch, then Up Next)",
     lambda d: d["episode"] and d["container"] == "mkv" and len(d["audio"]) >= 2),
    ("Image subtitles (PGS / VobSub) in MKV", lambda d: d["container"] == "mkv" and d["image_subs"]),
    ("ASS / SSA subtitles in MKV", lambda d: d["container"] == "mkv" and d["ass_subs"]),
    ("AV1 or VP9 (software route, or hardware AV1 on newer boxes)", lambda d: d["codec"] in ("av1", "vp9")),
]

user = get("/Users")[0]["Id"]
described = [describe(item) for item in all_items(user)]
print(f"{len(described)} movies and episodes scanned\n")
for title, matches in SHAPES:
    hits = sorted((d for d in described if matches(d)), key=lambda d: d["minutes"])
    print(f"{title}: {len(hits)} found")
    for d in hits[:3]:
        print(f'    {d["name"]}  |  {d["codec"]} {d["range"]}  |  {",".join(d["audio"])}  |  {d["minutes"]:.0f} min, {d["mbps"]:.0f} Mbps')
    print()
