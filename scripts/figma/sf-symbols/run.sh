#!/bin/sh
# Regenerate the Figma `icon` set's SVGs from the SF Symbols app installed on this Mac.
# See README.md for the Figma half of the process.
#
#   run.sh             every symbol in symbols.txt
#   run.sh <name>...   just these symbols
#   run.sh --check     list SF Symbols used in the app's Swift sources but missing from
#                      symbols.txt (not-symbols.txt holds known false matches)
#
# Output lands in out/ (git-ignored). Nothing Apple ships is committed: the outlines are
# regenerated from the local SF Symbols app every run, which keeps this inside its licence.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT="$HERE/out"
SFSYMBOLS="${SFSYMBOLS:-/Applications/SF Symbols.app/Contents/Executables/sfsymbols}"

listed() {
    grep -v '^[[:space:]]*\(#\|$\)' "$HERE/symbols.txt"
}

if [ "${1:-}" = "--check" ]; then
    # Every lowercase dotted-or-plain string literal in the app's sources, kept only if macOS
    # resolves it as an SF Symbol. Catches names built in computed properties, not just call sites.
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    grep -rhoE '"[a-z][a-z0-9]*(\.[a-z0-9]+)*"' --include='*.swift' --exclude-dir=.build --exclude-dir=Tests \
        "$REPO/Packages" "$REPO/Jelly Shark" | tr -d '"' | sort -u >"$WORK/literals.txt"
    cat >"$WORK/valid.swift" <<'EOF'
import AppKit
while let line = readLine() {
    if NSImage(systemSymbolName: line, accessibilityDescription: nil) != nil { print(line) }
}
EOF
    swift "$WORK/valid.swift" <"$WORK/literals.txt" 2>/dev/null >"$WORK/symbols-in-code.txt"
    { listed; sed 's/[[:space:]]*#.*//' "$HERE/not-symbols.txt" | grep -v '^$'; } | sort -u >"$WORK/listed.txt"
    missing=$(comm -23 "$WORK/symbols-in-code.txt" "$WORK/listed.txt")
    if [ -n "$missing" ]; then
        echo "In code but not in symbols.txt (check each is really a symbol):"
        echo "$missing"
        exit 1
    fi
    echo "symbols.txt covers every SF Symbol name found in the app's sources."
    exit 0
fi

[ -x "$SFSYMBOLS" ] || { echo "SF Symbols app not found (set SFSYMBOLS=/path/to/sfsymbols)" >&2; exit 1; }

if [ $# -gt 0 ]; then
    NAMES=$(printf '%s\n' "$@")
else
    NAMES=$(listed)
fi

rm -rf "$OUT"
mkdir -p "$OUT/templates" "$OUT/svg"
# The simulator-side probe and its alpha files live in a local temp dir: a simulator process
# opening files on an external volume can block on a macOS privacy prompt no one sees.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/alpha"

echo "Exporting templates…"
echo "$NAMES" | while read -r name; do
    "$SFSYMBOLS" export "$name" --format svg --output "$OUT/templates/$name.svg" >/dev/null 2>&1 ||
        { echo "sfsymbols could not export $name" >&2; exit 1; }
done

echo "Building the probe for the tvOS simulator…"
TVOS=$(xcrun --sdk appletvsimulator --show-sdk-version)
xcrun --sdk appletvsimulator swiftc -O -target "arm64-apple-tvos$TVOS-simulator" \
    "$HERE/probe.swift" -o "$WORK/probe" 2>&1 | grep -v 'warning:' || true

# Any available Apple TV simulator will do; prefer one that's already booted.
SIM=${SIM:-$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devs = [d for r, ds in json.load(sys.stdin)["devices"].items() if "tvOS" in r for d in ds]
devs.sort(key=lambda d: d["state"] != "Booted")
print(devs[0]["udid"] if devs else "")')}
[ -n "$SIM" ] || { echo "no tvOS simulator available" >&2; exit 1; }
xcrun simctl bootstatus "$SIM" -b >/dev/null

echo "Measuring SwiftUI renders on $SIM…"
# shellcheck disable=SC2086 # one argument per symbol name
xcrun simctl spawn "$SIM" "$WORK/probe" "$WORK/alpha" $NAMES 2>/dev/null >"$OUT/metrics.tsv"

python3 -I "$HERE/pipeline.py" "$OUT/templates" "$OUT/metrics.tsv" "$WORK/alpha" "$OUT/svg"
