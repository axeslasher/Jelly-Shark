#!/usr/bin/env bash
# Local Jellyfin for UI checks: a pinned version, setup wizard done, user
# test/test, and a small generated library (movies + one series) whose
# metadata comes from NFO files, so every run shows the same content offline.
#
#   server.sh up   [version] [port]   # default 10.11.11 on 8096; prints the URL
#   server.sh down [port]
#
# Generated media is cached under ~/Library/Caches/jelly-shark-ui-check and
# reused across runs; delete that folder to regenerate it.
#
# Live TV is off unless asked for, so ordinary checks need nothing else
# running. Point it at an M3U channel list and an XMLTV guide (ErsatzTV
# serves both) and the server gets a tuner and a guide:
#
#   UI_CHECK_LIVETV_M3U=http://host.docker.internal:8409/iptv/channels.m3u \
#   UI_CHECK_LIVETV_XMLTV=http://host.docker.internal:8409/iptv/xmltv.xml \
#       server.sh up 10.11.11 8097
#
# Use host.docker.internal, not localhost: the server fetches these from
# inside the container.
set -euo pipefail

cmd=${1:-}
version=${2:-10.11.11}
port=${3:-8096}
[[ $cmd == down ]] && port=${2:-8096}
name="js-ui-check-$port"
media="$HOME/Library/Caches/jelly-shark-ui-check/media"
# Bump when the generated media changes, so an older cache regenerates.
fixture_version=2
base="http://localhost:$port"
auth='MediaBrowser Client="ui-check", Device="ui-check", DeviceId="ui-check", Version="1"'

fail() { echo "server.sh: $*" >&2; exit 1; }
# set -e alone exits on any later failed curl without saying which step.
trap 'fail "failed at line $LINENO: $BASH_COMMAND"' ERR

# No text burned in: Homebrew's ffmpeg ships without drawtext. Titles come
# from the NFO files; artwork is told apart by colour.
clip() { # out, seconds
    ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=24:duration=$2" \
        -f lavfi -i "sine=frequency=440:duration=$2" \
        -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$1"
}

art() { # out, size, colour
    ffmpeg -loglevel error -y -f lavfi -i "color=c=$3:size=$2" -frames:v 1 "$1"
}

seed_media() {
    [[ $(cat "$media/.complete" 2>/dev/null) == "$fixture_version" ]] && return
    command -v ffmpeg >/dev/null || fail "ffmpeg is required (brew install ffmpeg)"
    rm -rf "$media"
    local i title year colour
    local movies=("Harbor Lights|2019|navy" "The Long Field|2021|darkgreen" "Static Season|2023|maroon")
    for i in "${!movies[@]}"; do
        IFS='|' read -r title year colour <<<"${movies[$i]}"
        local dir="$media/movies/$title ($year)"
        mkdir -p "$dir"
        clip "$dir/$title ($year).mp4" 20
        art "$dir/poster.jpg" 600x900 "$colour"
        art "$dir/backdrop.jpg" 1920x1080 "$colour"
        cat >"$dir/$title ($year).nfo" <<EOF
<movie><title>$title</title><year>$year</year><plot>A UI-check fixture film about $title.</plot><genre>Drama</genre><runtime>1</runtime></movie>
EOF
    done
    local show="$media/shows/Night Shift Radio"
    mkdir -p "$show/Season 01"
    art "$show/poster.jpg" 600x900 indigo
    art "$show/backdrop.jpg" 1920x1080 indigo
    echo '<tvshow><title>Night Shift Radio</title><year>2022</year><plot>A UI-check fixture series.</plot><genre>Comedy</genre></tvshow>' >"$show/tvshow.nfo"
    # 45s, not shorter: tvOS shows its Up Next card 30s before an episode
    # ends, and AVKit skips the card when the episode is shorter than that.
    for i in 1 2 3; do
        clip "$show/Season 01/Night Shift Radio S01E0$i.mp4" 45
        echo "<episodedetails><title>Episode $i</title><season>1</season><episode>$i</episode><plot>Fixture episode $i.</plot></episodedetails>" \
            >"$show/Season 01/Night Shift Radio S01E0$i.nfo"
    done
    echo "$fixture_version" >"$media/.complete"
}

# Spike #60 (docs/spikes/60.md): MKV sources the default engine cannot
# direct-play, for trialling a second engine. Opt-in with UI_CHECK_SPIKE=1 and
# kept in a cache of their own, so branches without this block never see the
# ordinary cache change under them.
spike_media="$HOME/Library/Caches/jelly-shark-ui-check/media-spike"
spike_version=1

spike_nfo() { # dir, title, year, plot
    art "$1/poster.jpg" 600x900 teal
    art "$1/backdrop.jpg" 1920x1080 teal
    echo "<movie><title>$2</title><year>$3</year><plot>$4</plot><genre>Drama</genre><runtime>1</runtime></movie>" >"$1/$2 ($3).nfo"
}

seed_spike_media() {
    [[ $(cat "$spike_media/.complete" 2>/dev/null) == "$spike_version" ]] && return
    command -v ffmpeg >/dev/null || fail "ffmpeg is required (brew install ffmpeg)"
    rm -rf "$spike_media"
    local video="testsrc2=size=640x360:rate=24:duration" tone="sine=frequency" dir i
    local surround="pan=5.1(side)|FL=c0|FR=c0|FC=c0|LFE=c0|SL=c0|SR=c0"

    # HEVC 10-bit HDR10, two audio tracks (the second an octave up, to tell
    # a switch by ear) and two text subtitle tracks. setparams is what makes
    # the stream read smpte2084: the x265 flags alone left it "unknown".
    dir="$spike_media/movies/Signal Fire (2024)"
    mkdir -p "$dir"
    printf '1\n00:00:01,000 --> 00:00:04,000\nFixture subtitle one\n\n2\n00:00:05,000 --> 00:00:09,000\nFixture subtitle two\n' >"$dir/en.srt"
    printf '1\n00:00:01,000 --> 00:00:04,000\nSubtitulo uno\n\n2\n00:00:05,000 --> 00:00:09,000\nSubtitulo dos\n' >"$dir/es.srt"
    ffmpeg -loglevel error -y -f lavfi -i "$video=20" -f lavfi -i "$tone=440:duration=20" \
        -f lavfi -i "$tone=880:duration=20" -i "$dir/en.srt" -i "$dir/es.srt" \
        -map 0:v -map 1:a -map 2:a -map 3 -map 4 \
        -vf "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" \
        -c:v libx265 -preset ultrafast \
        -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:repeat-headers=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
        -filter:a:0 "$surround" -c:a:0 eac3 -b:a:0 384k -c:a:1 aac -ac:a:1 2 -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=fra \
        -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa \
        -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 0 -disposition:s:1 0 \
        "$dir/Signal Fire (2024).mkv"
    rm "$dir/en.srt" "$dir/es.srt"
    spike_nfo "$dir" "Signal Fire" 2024 "Spike fixture: HEVC HDR10 MKV, E-AC-3 5.1 and AAC, two SRT tracks."

    # DTS 5.1: AVFoundation has no decoder, so the default engine needs a
    # server audio transcode here.
    dir="$spike_media/movies/Copper Wire (2020)"
    mkdir -p "$dir"
    ffmpeg -loglevel error -y -f lavfi -i "$video=20" -f lavfi -i "$tone=440:duration=20" \
        -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p \
        -filter:a "$surround" -c:a dca -strict -2 -b:a 1509k -metadata:s:a:0 language=eng \
        "$dir/Copper Wire (2020).mkv"
    spike_nfo "$dir" "Copper Wire" 2020 "Spike fixture: H.264 MKV with DTS 5.1."

    # AV1 + Opus: no hardware AV1 on the simulator, so this lands on a
    # software decode path.
    dir="$spike_media/movies/Glass Orbit (2025)"
    mkdir -p "$dir"
    SVT_LOG=1 ffmpeg -loglevel error -y -f lavfi -i "$video=20" -f lavfi -i "$tone=440:duration=20" \
        -map 0:v -map 1:a -c:v libsvtav1 -preset 10 -pix_fmt yuv420p -c:a libopus -b:a 96k \
        "$dir/Glass Orbit (2025).mkv"
    spike_nfo "$dir" "Glass Orbit" 2025 "Spike fixture: AV1 MKV with Opus."

    # A series for Up Next. 45s for the same reason as Night Shift Radio.
    local show="$spike_media/shows/Relay Station"
    mkdir -p "$show/Season 01"
    art "$show/poster.jpg" 600x900 teal
    art "$show/backdrop.jpg" 1920x1080 teal
    echo '<tvshow><title>Relay Station</title><year>2024</year><plot>Spike fixture series: HEVC MKV with AC-3.</plot><genre>Drama</genre></tvshow>' >"$show/tvshow.nfo"
    for i in 1 2 3; do
        ffmpeg -loglevel error -y -f lavfi -i "$video=45" -f lavfi -i "$tone=440:duration=45" \
            -map 0:v -map 1:a -c:v libx265 -preset ultrafast -x265-params log-level=error -pix_fmt yuv420p \
            -c:a ac3 -b:a 192k "$show/Season 01/Relay Station S01E0$i.mkv"
        echo "<episodedetails><title>Relay $i</title><season>1</season><episode>$i</episode><plot>Spike fixture episode $i.</plot></episodedetails>" \
            >"$show/Season 01/Relay Station S01E0$i.nfo"
    done
    echo "$spike_version" >"$spike_media/.complete"
}

api() { # method, path, [json]
    curl -sf -X "$1" -H 'Content-Type: application/json' -H "Authorization: $auth${TOKEN:+, Token=\"$TOKEN\"}" \
        "$base$2" ${3:+-d "$3"}
}

up() {
    command -v docker >/dev/null || fail "docker is required"
    docker info >/dev/null 2>&1 || fail "docker is not running"
    seed_media
    local mounts=(-v "$media:/media:ro") expected=6 spike=""
    if [[ -n ${UI_CHECK_SPIKE:-} ]]; then
        seed_spike_media
        mounts+=(-v "$spike_media:/media-spike:ro")
        expected=12
        spike=" + spike library: 3 MKV movies, 1 MKV series of 3 episodes"
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    # Loopback only: the admin is test/test, so it must not be reachable from
    # the LAN. The simulator shares the Mac's localhost, which is all it needs.
    docker run -d --rm --name "$name" -p "127.0.0.1:$port:8096" "${mounts[@]}" \
        "jellyfin/jellyfin:$version" >/dev/null

    # Wait for three answers in a row, not the first one: a cold 12.4 can answer
    # once mid-startup and then refuse for a moment, and a single confirm curl
    # after that first answer failed the start with the container healthy.
    local i answered=0
    for i in $(seq 1 90); do
        if curl -sf "$base/System/Info/Public" >/dev/null; then
            ((++answered >= 3)) && break
        else
            answered=0
        fi
        sleep 1
    done
    ((answered >= 3)) || fail "server did not come up on $base"

    # On a cold start /System/Info/Public answers before the wizard endpoints
    # do, and a bare call here exited silently under `set -e`. Retry it.
    local configured=0
    for i in $(seq 1 60); do
        api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null &&
            { configured=1; break; }
        sleep 1
    done
    ((configured)) || fail "setup wizard never accepted its first step on $base"
    api GET /Startup/User >/dev/null
    api POST /Startup/User '{"Name":"test","Password":"test"}' >/dev/null
    api POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
    api POST /Startup/Complete >/dev/null

    TOKEN=$(api POST /Users/AuthenticateByName '{"Username":"test","Pw":"test"}' |
        python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessToken"])')

    # Local NFO and artwork only: no online fetchers, so titles never get
    # "corrected" by a metadata provider.
    local options='{"LibraryOptions":{"EnableInternetProviders":false,"EnableRealtimeMonitor":false,"TypeOptions":[]}}'
    api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fmedia%2Fmovies&refreshLibrary=false" "$options" >/dev/null
    api POST "/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=%2Fmedia%2Fshows&refreshLibrary=false" "$options" >/dev/null
    if [[ -n $spike ]]; then
        api POST "/Library/VirtualFolders?name=Spike%20Movies&collectionType=movies&paths=%2Fmedia-spike%2Fmovies&refreshLibrary=false" "$options" >/dev/null
        api POST "/Library/VirtualFolders?name=Spike%20Shows&collectionType=tvshows&paths=%2Fmedia-spike%2Fshows&refreshLibrary=false" "$options" >/dev/null
    fi
    api POST /Library/Refresh >/dev/null

    # The scan is asynchronous: wait until every fixture item is indexed.
    local count=0
    for i in $(seq 1 90); do
        count=$(api GET "/Items?Recursive=true&IncludeItemTypes=Movie,Episode" |
            python3 -c 'import sys,json;print(json.load(sys.stdin)["TotalRecordCount"])')
        [[ $count -ge $expected ]] && break
        sleep 1
    done
    [[ $count -ge $expected ]] || fail "library scan found $count of $expected items"

    local live=""
    if [[ -n ${UI_CHECK_LIVETV_M3U:-} ]]; then
        seed_live_tv
        live=", $LIVE_CHANNELS live channels"
    fi

    echo "$base  (Jellyfin $version, user test / password test, 3 movies + 1 series of 3 episodes$spike$live)"
}

seed_live_tv() {
    [[ -n ${UI_CHECK_LIVETV_XMLTV:-} ]] || fail "UI_CHECK_LIVETV_M3U needs UI_CHECK_LIVETV_XMLTV as well"
    api POST /LiveTv/TunerHosts "{\"Type\":\"m3u\",\"Url\":\"$UI_CHECK_LIVETV_M3U\",\"AllowStreamSharing\":true}" >/dev/null
    # Adding the guide source starts the server's guide refresh.
    api POST /LiveTv/ListingProviders "{\"Type\":\"xmltv\",\"Path\":\"$UI_CHECK_LIVETV_XMLTV\",\"EnableAllTuners\":true}" >/dev/null

    # The refresh is asynchronous: wait until channels and programmes exist.
    local i programs=0
    LIVE_CHANNELS=0
    for i in $(seq 1 90); do
        LIVE_CHANNELS=$(api GET "/LiveTv/Channels?limit=1" |
            python3 -c 'import sys,json;print(json.load(sys.stdin)["TotalRecordCount"])')
        programs=$(api GET "/LiveTv/Programs?limit=1" |
            python3 -c 'import sys,json;print(json.load(sys.stdin)["TotalRecordCount"])')
        [[ $LIVE_CHANNELS -gt 0 && $programs -gt 0 ]] && break
        sleep 2
    done
    [[ $LIVE_CHANNELS -gt 0 && $programs -gt 0 ]] ||
        fail "live TV guide never loaded ($LIVE_CHANNELS channels, $programs programmes)"
}

down() {
    docker stop "$name" >/dev/null 2>&1 && echo "stopped $name" || echo "$name was not running"
}

case $cmd in
up) up ;;
down) down ;;
*) fail "usage: server.sh up [version] [port] | server.sh down [port]" ;;
esac
