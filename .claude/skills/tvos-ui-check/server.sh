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
set -euo pipefail

cmd=${1:-}
version=${2:-10.11.11}
port=${3:-8096}
[[ $cmd == down ]] && port=${2:-8096}
name="js-ui-check-$port"
media="$HOME/Library/Caches/jelly-shark-ui-check/media"
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
    [[ -f "$media/.complete" ]] && return
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
    for i in 1 2 3; do
        clip "$show/Season 01/Night Shift Radio S01E0$i.mp4" 15
        echo "<episodedetails><title>Episode $i</title><season>1</season><episode>$i</episode><plot>Fixture episode $i.</plot></episodedetails>" \
            >"$show/Season 01/Night Shift Radio S01E0$i.nfo"
    done
    touch "$media/.complete"
}

api() { # method, path, [json]
    curl -sf -X "$1" -H 'Content-Type: application/json' -H "Authorization: $auth${TOKEN:+, Token=\"$TOKEN\"}" \
        "$base$2" ${3:+-d "$3"}
}

up() {
    command -v docker >/dev/null || fail "docker is required"
    docker info >/dev/null 2>&1 || fail "docker is not running"
    seed_media
    docker rm -f "$name" >/dev/null 2>&1 || true
    # Loopback only: the admin is test/test, so it must not be reachable from
    # the LAN. The simulator shares the Mac's localhost, which is all it needs.
    docker run -d --rm --name "$name" -p "127.0.0.1:$port:8096" -v "$media:/media:ro" \
        "jellyfin/jellyfin:$version" >/dev/null

    local i
    for i in $(seq 1 90); do
        curl -sf "$base/System/Info/Public" >/dev/null && break
        sleep 1
    done
    curl -sf "$base/System/Info/Public" >/dev/null || fail "server did not come up on $base"

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
    api POST /Library/Refresh >/dev/null

    # The scan is asynchronous: wait until every fixture item is indexed.
    local count=0
    for i in $(seq 1 90); do
        count=$(api GET "/Items?Recursive=true&IncludeItemTypes=Movie,Episode" |
            python3 -c 'import sys,json;print(json.load(sys.stdin)["TotalRecordCount"])')
        [[ $count -ge 6 ]] && break
        sleep 1
    done
    [[ $count -ge 6 ]] || fail "library scan found $count of 6 items"

    echo "$base  (Jellyfin $version, user test / password test, 3 movies + 1 series of 3 episodes)"
}

down() {
    docker stop "$name" >/dev/null 2>&1 && echo "stopped $name" || echo "$name was not running"
}

case $cmd in
up) up ;;
down) down ;;
*) fail "usage: server.sh up [version] [port] | server.sh down [port]" ;;
esac
