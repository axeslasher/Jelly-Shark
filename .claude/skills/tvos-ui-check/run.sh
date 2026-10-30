#!/usr/bin/env bash
# Runs one UI check and fails fast instead of hanging.
#
#   run.sh <TestClass> [simulator-udid]
#
# Prints PASS/FAIL with each failure message, exports the screenshots to
# $UI_CHECK_OUT (default: a temp folder) under their attachment names, and
# exits 0 on pass, 1 on a test failure, 2 when the run stalled or broke.
#
# Why each guard exists is in SKILL.md § Hang modes.
set -uo pipefail

class=${1:?usage: run.sh <TestClass> [simulator-udid]}
udid=${2:-}
repo=$(git rev-parse --show-toplevel)
out=${UI_CHECK_OUT:-$(mktemp -d -t ui-check)}
derived=${UI_CHECK_DERIVED:-$HOME/Library/Caches/jelly-shark-ui-check/derived/$(basename "$repo")}
bundle="$out/result.xcresult"
log="$out/xcodebuild.log"
build_limit=${UI_CHECK_BUILD_LIMIT:-600} # seconds from start to "Testing started"
quiet_limit=${UI_CHECK_QUIET_LIMIT:-90}  # seconds with no log output once testing runs

mkdir -p "$out"

say() { echo "ui-check: $*"; }
die() { say "$*"; [[ -n ${pid:-} ]] && kill "$pid" 2>/dev/null; exit 2; }

# 1. Simulator: default to the Apple TV the Makefile tests on. Boot it here,
#    with a deadline, rather than letting xcodebuild boot it silently.
if [[ -z $udid ]]; then
    udid=$(xcrun simctl list devices available -j | python3 -c '
import sys, json
d = json.load(sys.stdin)["devices"]
print(next((x["udid"] for r, l in d.items() if "tvOS" in r for x in l
            if x["name"] == "Apple TV 4K (3rd generation)"), ""))')
    [[ -n $udid ]] || die "no 'Apple TV 4K (3rd generation)' simulator; pass a UDID"
fi
xcrun simctl boot "$udid" 2>/dev/null
( xcrun simctl bootstatus "$udid" >/dev/null 2>&1 ) & boot=$!
for _ in $(seq 1 120); do kill -0 $boot 2>/dev/null || break; sleep 1; done
kill -0 $boot 2>/dev/null && { kill $boot; die "simulator $udid did not finish booting in 120s"; }

# 2. The run. No parallel testing: it clones the simulator, and a clone has
#    been seen sitting on the home screen without ever launching the app.
#    The test writes its screenshots and verdict.txt straight into $shots
#    (TEST_RUNNER_ vars reach the test runner with the prefix stripped), so
#    nothing waits on xcodebuild saving its result bundle — it has been seen
#    stuck with the bundle still in staging long after the test ended.
shots="$out/screenshots"
mkdir -p "$shots"
rm -f "$shots"/*.png "$shots/verdict.txt"
start=$(date +%s)
TEST_RUNNER_UI_CHECK_OUT="$shots" xcodebuild test -scheme "Jelly Shark" -destination "id=$udid" \
    -derivedDataPath "$derived" -resultBundlePath "$bundle" \
    -parallel-testing-enabled NO -collect-test-diagnostics never \
    -only-testing:"Jelly SharkUITests/$class" >"$log" 2>&1 &
pid=$!
say "running $class on $udid (log: $log)"

# 3. Watch for the verdict, with a deadline for each phase.
testing=0 last_size=0 last_change=$start
while [[ ! -f $shots/verdict.txt ]]; do
    sleep 2
    now=$(date +%s)
    size=$(wc -c <"$log")
    ((size != last_size)) && { last_size=$size; last_change=$now; }

    if grep -q "BUILD FAILED\|Testing cancelled because the build failed" "$log"; then
        grep -E "error:" "$log" | head -5
        die "build failed"
    fi
    ((testing == 0)) && grep -q "Test suite .* started\|Test Suite .* started" "$log" && testing=1

    if ((testing == 0)); then
        ((now - start > build_limit)) && die "testing never started within ${build_limit}s"
    else
        ((now - last_change > quiet_limit)) && die "no output for ${quiet_limit}s mid-test: the run stalled"
        grep -q "Executed [0-9]* test" "$log" && { sleep 3; [[ -f $shots/verdict.txt ]] ||
            die "test ended without a verdict — does the class call writeVerdictOnTeardown()?"; }
    fi
    kill -0 $pid 2>/dev/null || { sleep 1; [[ -f $shots/verdict.txt ]] || die "xcodebuild exited without a verdict"; }
done

# 4. Done: stop xcodebuild rather than wait for it to wind down.
kill $pid 2>/dev/null; wait $pid 2>/dev/null
grep -E "error: .*(failed|XCTAssert)" "$log" | sed -E 's/.*: (failed|XCTAssert[A-Za-z]* failed)/  failure: \1/' | cut -c1-300 | head -5
verdict=$(head -1 "$shots/verdict.txt")
say "$verdict in $(($(date +%s) - start))s — screenshots: $shots"
[[ $verdict == PASS ]]
