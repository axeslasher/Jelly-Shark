#!/usr/bin/env bash
# Runs `xcodebuild test <args>` and stops it if it stalls, so a red run can't
# look like a slow one. The make test targets call this.
#
#   scripts/xcodebuild-test.sh <xcodebuild test arguments>
#
# Exits with xcodebuild's own code, except:
#   - it printed its verdict but didn't exit within TEST_EXIT_LIMIT seconds:
#     stopped, exit 0 for TEST SUCCEEDED, 65 for TEST FAILED (xcodebuild's code);
#   - no output for TEST_QUIET_LIMIT seconds: stopped, exit 2.
#
# Both stalls have been seen (#339). The usual one, xcodebuild waiting 600s on
# simulator diagnostics after a failure, is switched off by the Makefile's
# -collect-test-diagnostics never; this catches whatever else stalls.
set -uo pipefail

# A cold build or a slow test can go quiet for a while; the stall this
# guards against goes quiet for 600s.
quiet_limit=${TEST_QUIET_LIMIT:-300}
exit_limit=${TEST_EXIT_LIMIT:-30}

log=$(mktemp -t xcodebuild-test)
stalled=$log.stalled
xcodebuild test "$@" >"$log" 2>&1 &
pid=$!
tail -n +1 -f "$log" &
tailpid=$!

# The watchdog runs beside xcodebuild rather than polling in front of it, so
# a run that ends normally ends with no added delay.
(
    last_size=0 last_change=$(date +%s) verdict="" verdict_at=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        now=$(date +%s)
        size=$(wc -c <"$log")
        if ((size != last_size)); then
            last_size=$size last_change=$now
            if [[ -z $verdict ]]; then
                verdict=$(grep -m1 -oE '\*\* TEST (SUCCEEDED|FAILED) \*\*' "$log")
                [[ -n $verdict ]] && verdict_at=$now
            fi
        fi
        if [[ -n $verdict ]] && ((now - verdict_at > exit_limit)); then
            echo "$verdict" >"$stalled"
            echo "xcodebuild-test: xcodebuild printed '$verdict' but hadn't exited ${exit_limit}s later; stopped it." >&2
            break
        fi
        if ((now - last_change > quiet_limit)); then
            echo "quiet" >"$stalled"
            echo "xcodebuild-test: no output for ${quiet_limit}s; stopped xcodebuild. Treat the run as failed." >&2
            break
        fi
    done
    if [[ -f $stalled ]]; then
        kill "$pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || exit; sleep 0.5; done
        kill -9 "$pid" 2>/dev/null
    fi
) &
watchdog=$!
trap 'kill "$pid" "$watchdog" "$tailpid" 2>/dev/null; rm -f "$log" "$stalled"' EXIT
trap 'exit 130' INT TERM

wait "$pid"
code=$?
if [[ -f $stalled ]]; then
    wait "$watchdog" 2>/dev/null
else
    kill "$watchdog" 2>/dev/null
fi
sleep 0.2 # tail follows the log through kqueue, so this lets it print the last lines
case $(cat "$stalled" 2>/dev/null) in
"") exit "$code" ;;
*SUCCEEDED*) exit 0 ;;
*FAILED*) exit 65 ;;
*) exit 2 ;;
esac
