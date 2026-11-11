#!/bin/sh
# Fail unless every build configuration of the app target sets
# MARKETING_VERSION to the release tag. release.yml runs this before
# archiving; run it locally the same way:
#
#   scripts/verify-release-version.sh v0.12.0 [path/to/project.pbxproj]
#
# Every configuration has to match, not just one: the archive builds Release,
# so a bump made only to Debug would pass a looser check and ship the old
# version. The test targets keep Xcode's template 1.0 and don't ship, so the
# app's configurations are found through the app target's own configuration
# list rather than by reading every MARKETING_VERSION in the file.

set -eu

TARGET="Jelly Shark"
release_tag="${1:?usage: $0 <v-tag> [project.pbxproj]}"
pbxproj="${2:-$(cd "$(dirname "$0")/.." && pwd)/Jelly Shark.xcodeproj/project.pbxproj}"

case "$release_tag" in
    v*) ;;
    *) echo "::error::'$release_tag' is not a v* release tag"; exit 1 ;;
esac
tag="${release_tag#v}"

list_id=$(grep -F "/* Build configuration list for PBXNativeTarget \"$TARGET\" */;" "$pbxproj" |
    awk '{ print $3; exit }')
if [ -z "$list_id" ]; then
    echo "::error::no target named \"$TARGET\" in $pbxproj — has the app target been renamed?"
    exit 1
fi

# The configuration IDs listed inside that XCConfigurationList block.
config_ids=$(awk -v id="$list_id" '
    $1 == id && /= \{/ { inlist = 1; next }
    inlist && /\);/ { exit }
    inlist && $1 ~ /^[0-9A-F]+$/ { print $1 }
' "$pbxproj")
if [ -z "$config_ids" ]; then
    echo "::error::\"$TARGET\" has no build configurations in $pbxproj"
    exit 1
fi

echo "tag: $tag"
failed=0
for config_id in $config_ids; do
    # "<name> <version>"; version is empty when the configuration doesn't set one.
    read -r name version <<EOF
$(awk -v id="$config_id" '
    function value(v) { sub(/;$/, "", v); gsub(/"/, "", v); return v }
    $1 == id && /= \{/ { inblock = 1; next }
    inblock && $1 == "MARKETING_VERSION" { version = value($3) }
    inblock && $1 == "name" { print value($3), version; exit }
' "$pbxproj")
EOF
    if [ "$version" = "$tag" ]; then
        echo "$name: $version"
    else
        echo "::error::$TARGET $name has MARKETING_VERSION ${version:-(not set)}, tag is $tag — bump project.pbxproj first, then tag (docs/RELEASING.md)"
        failed=1
    fi
done
exit "$failed"
