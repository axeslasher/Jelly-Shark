#!/usr/bin/env bash
# Runs one UI check and fails fast instead of hanging.
#
#   run.sh <TestClass> [tvos|visionos|simulator-udid]
#
# The platform defaults to tvOS. A UDID picks its own platform.
#
# Prints PASS/FAIL with each failure message, exports the screenshots to
# $UI_CHECK_OUT (default: a temp folder) under their attachment names, and
# exits 0 on pass, 1 on a test failure, 2 when the run stalled or broke.
#
# Why each guard exists is in SKILL.md § Hang modes.
set -uo pipefail

class=${1:?usage: run.sh <TestClass> [tvos|visionos|simulator-udid]}
target=${2:-tvos}
repo=$(git rev-parse --show-toplevel)
out=${UI_CHECK_OUT:-$(mktemp -d -t ui-check)}
bundle="$out/result.xcresult"
log="$out/xcodebuild.log"
build_limit=${UI_CHECK_BUILD_LIMIT:-600} # seconds from start to the first "Test Suite … started"
# A healthy check logs an activity line at least every ~2.5s; an app whose
# main thread is stuck goes silent ~31s per UI query (SKILL.md § Hang modes).
quiet_limit=${UI_CHECK_QUIET_LIMIT:-20} # seconds with no log output once testing runs

mkdir -p "$out"

say() { echo "ui-check: $*"; }
# For failures the screen can't explain (bad arguments, a build error, a
# class typo): no stall screenshot or last step, which would only be noise.
fail() {
    say "$*"
    [[ -n ${pid:-} ]] && kill "$pid" 2>/dev/null
    exit 2
}
# A simulator screenshot at <path>, capped at 5s: on a wedged simulator the
# screenshot itself can hang. Writes to a temp name first, so <path> exists
# only when complete. Fails if no screenshot landed.
screenshot() {
    local tmp
    tmp="$(dirname "$1")/.$(basename "$1")"
    xcrun simctl io "$udid" screenshot "$tmp" >/dev/null 2>&1 &
    local shot=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 $shot 2>/dev/null || break; sleep 0.5; done
    kill $shot 2>/dev/null
    wait $shot 2>/dev/null && [[ -s $tmp ]] && mv "$tmp" "$1"
}
die() {
    say "$*"
    # What the screen showed when we gave up, and the step that never returned.
    if [[ -n ${udid:-} && -n ${shots:-} ]] && screenshot "$shots/stalled.png"; then
        say "screen at stall: $shots/stalled.png"
    fi
    [[ -f ${log:-} ]] && grep -E "^ +t = " "$log" | tail -1 | sed 's/^ */ui-check: last step: /'
    [[ -n ${pid:-} ]] && kill "$pid" 2>/dev/null
    exit 2
}

# 1. Simulator: a platform word picks the default simulator for it; a UDID
#    picks its platform from its runtime. An unknown UDID otherwise costs
#    about a minute while xcodebuild searches for the destination.
sims=$(xcrun simctl list devices available -j | python3 -c '
import sys, json
for runtime, devices in json.load(sys.stdin)["devices"].items():
    platform = "tvos" if "tvOS" in runtime else "visionos" if "xrOS" in runtime else ""
    for d in devices if platform else []:
        print(platform, d["udid"], d["state"], d["name"], sep="\t")')
case $target in
tvos) default="Apple TV 4K (3rd generation)" ;;
visionos) default="Apple Vision Pro" ;;
esac
if [[ -n ${default:-} ]]; then
    udid=$(awk -F'\t' -v p="$target" -v n="$default" '$1 == p && $4 == n { print $2; exit }' <<<"$sims")
    [[ -n $udid ]] || fail "no '$default' simulator; pass a UDID (xcrun simctl list devices available)"
else
    udid=$target
fi
platform=$(awk -F'\t' -v u="$udid" '$2 == u { print $1 }' <<<"$sims")
[[ -n $platform ]] || fail "$udid is not an available tvOS or visionOS simulator (xcrun simctl list devices available)"
# One folder per platform: a tvOS and a visionOS run building at once in a
# shared folder would fight over its build database lock.
derived=${UI_CHECK_DERIVED:-$HOME/Library/Caches/jelly-shark-ui-check/derived/$(basename "$repo")-$platform}

# Two runs on one simulator kill each other's test runner. Hold a lock per
# simulator, across worktrees; a lock whose owner has exited is stale.
lock="$HOME/Library/Caches/jelly-shark-ui-check/locks/$udid"
mkdir -p "$(dirname "$lock")"
if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/pid" 2>/dev/null)
    [[ -n $owner ]] && kill -0 "$owner" 2>/dev/null && fail "simulator $udid is in use by another ui-check run (pid $owner)"
    rm -rf "$lock" && mkdir "$lock" || die "could not take the lock at $lock"
fi
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"; [[ -n ${pid:-} ]] && kill "$pid" 2>/dev/null' EXIT

# A wedged simulator reports Booted yet never finishes booting and launches
# nothing; only a shutdown clears it (seen on visionOS).
booterr=$(xcrun simctl boot "$udid" 2>&1 | grep -v "current state: Booted")
( xcrun simctl bootstatus "$udid" >/dev/null 2>&1 ) & boot=$!
for _ in $(seq 1 120); do kill -0 $boot 2>/dev/null || break; sleep 1; done
if kill -0 $boot 2>/dev/null; then
    kill $boot
    [[ -n $booterr ]] && say "simctl boot said: $booterr"
    die "simulator $udid did not finish booting in 120s; if it shows Booted it is wedged: xcrun simctl shutdown $udid, then run again"
fi

# Server preflight, before the build: a dead server otherwise surfaces only
# as a sign-in failure, a minute or more into the run. A paused (frozen)
# container accepts the connection and never answers, hence -m.
if [[ -n ${UI_CHECK_SERVER:-} ]]; then
    curl -sf -m 3 "$UI_CHECK_SERVER/System/Info/Public" >/dev/null ||
        die "server $UI_CHECK_SERVER is not answering — run server.sh up first"
fi

# 2. The run. No parallel testing: it clones the simulator, and a clone has
#    been seen sitting on the home screen without ever launching the app.
#    The test writes its screenshots and verdict.txt straight into $shots
#    (TEST_RUNNER_ vars reach the test runner with the prefix stripped), so
#    nothing waits on xcodebuild saving its result bundle — it has been seen
#    stuck with the bundle still in staging long after the test ended.
#    UI_CHECK_SERVER goes through the same way, so one check runs against
#    any server.sh port without an edit.
# xcodebuild refuses to overwrite a result bundle, so reusing an output
# folder would otherwise end the run before it starts.
rm -rf "$bundle"
shots="$out/screenshots"
mkdir -p "$shots"
rm -rf "$shots"/*.png "$shots"/*.failed "$shots/verdict.txt" "$shots/requests"
start=$(date +%s)
TEST_RUNNER_UI_CHECK_OUT="$shots" TEST_RUNNER_UI_CHECK_SERVER="${UI_CHECK_SERVER:-}" xcodebuild test -scheme "Jelly Shark" -destination "id=$udid" \
    -derivedDataPath "$derived" -resultBundlePath "$bundle" \
    -parallel-testing-enabled NO -collect-test-diagnostics never \
    -only-testing:"Jelly SharkUITests/$class" >"$log" 2>&1 &
pid=$!
say "running $class on $platform simulator $udid (log: $log)"

# 3. Watch for the verdict, with a deadline for each phase.
testing=0 last_size=0 last_change=$start app_seen=$start
app_proc="$udid/data/Containers/Bundle/Application/.*/Jelly Shark.app/Jelly Shark"
requests="$shots/requests"
mkdir -p "$requests"
while [[ ! -f $shots/verdict.txt ]]; do
    sleep 0.5
    # Screenshot requests from the check (visionOS: XCUITest's own screenshot
    # crops the window). The PNG, or <name>.failed, lands before the request
    # is removed, which is what the check waits for.
    for request in "$requests"/*; do
        [[ -f $request ]] || continue
        name=$(basename "$request")
        screenshot "$shots/$name.png" || echo "simctl io screenshot failed or took over 5s" >"$shots/$name.failed"
        rm -f "$request"
    done
    now=$(date +%s)
    size=$(wc -c <"$log")
    ((size != last_size)) && { last_size=$size; last_change=$now; }

    if grep -q "BUILD FAILED\|Testing cancelled because the build failed" "$log"; then
        grep -E "error:" "$log" | head -5
        fail "build failed"
    fi
    # The simulator's launchd, recorded when testing starts: a shutdown mid-run
    # looks like an app crash, because the test runner boots it again within
    # about 4s (seen on visionOS), so only a new launchd pid tells them apart.
    if ((testing == 0)) && grep -q "Test suite .* started\|Test Suite .* started" "$log"; then
        testing=1
        say "testing"
        sim_pid=$(pgrep -f "launchd_sim.*$udid" | head -1)
    fi

    # The runner died: simulator shut down, or a second run on the same one.
    if grep -q "Restarting after unexpected exit\|Early unexpected exit" "$log"; then
        grep -E "encountered an error|Underlying Error" "$log" | head -2 | cut -c1-300
        die "the test runner died mid-run: was the simulator shut down, or used by another run?"
    fi

    if ((testing == 0)); then
        ((now - start > build_limit)) && die "testing never started within ${build_limit}s"
    else
        grep -q "Executed 0 tests" "$log" && fail "no test matched '$class' — check the class name"
        ((now - last_change > quiet_limit)) && die "no output for ${quiet_limit}s mid-test: the run stalled"
        # A dead app doesn't fail a wait: XCTest polls it until the timeout.
        # Once the test has launched the app, give it 15s to come back.
        launches=$(grep -c "Launch com.justinlascelle.jellyshark" "$log")
        if pgrep -qf "$app_proc" || ((launches != ${last_launches:-0})); then
            app_seen=$now last_launches=$launches
        elif ((launches > 0 && now - app_seen > 15)); then
            [[ $(pgrep -f "launchd_sim.*$udid" | head -1) != "${sim_pid:-}" ]] &&
                die "the simulator shut down or restarted mid-run: was it shut down, or used by another run?"
            die "the app has not been running for 15s mid-test: it crashed or was killed (crash logs: ~/Library/Logs/DiagnosticReports)"
        fi
        grep -q "Executed [0-9]* test" "$log" && { sleep 3; [[ -f $shots/verdict.txt ]] ||
            die "test ended without a verdict — does the class call writeVerdictOnTeardown()?"; }
    fi
    kill -0 $pid 2>/dev/null || { sleep 1; [[ -f $shots/verdict.txt ]] ||
        { grep -E "xcodebuild: error:" "$log" | head -3; die "xcodebuild exited without a verdict"; }; }
done

# 4. Done: stop xcodebuild rather than wait for it to wind down.
kill $pid 2>/dev/null; wait $pid 2>/dev/null
grep -iE "error: .*(failed|XCTAssert)" "$log" | sed -E 's/.*\] : /  failure: /' | cut -c1-300 | head -5
verdict=$(head -1 "$shots/verdict.txt")
say "$verdict in $(($(date +%s) - start))s — screenshots: $shots"
[[ $verdict == PASS ]]
