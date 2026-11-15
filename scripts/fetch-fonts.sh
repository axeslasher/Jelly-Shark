#!/bin/sh
# Download the theme typefaces into DesignSystem's Fonts folder. Run with
# `make fonts`; see Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/FONTS.md.
#
# The files stay git-ignored: the Fontshare EULA allows downloading and using
# the fonts but forbids redistributing them, so each clone fetches its own copy
# from the source rather than from this repo.
#
# Files already present are skipped, so re-running only fills gaps. FORCE=1
# re-downloads everything.
#
# Every file, fetched or already present, must match scripts/fonts.sha256.
# Release builds embed these bytes in a signed app, and Fontshare's API always
# serves its latest build, so the checksums are what stop an upstream change
# from shipping unnoticed. Updating a font means refreshing that file in the
# same change (FONTS.md § Updating a font).

set -eu

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FONTS_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)/Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts"
FONTSHARE_URL="https://api.fontshare.com/v2/fonts/download"
# Pinned to a google/fonts commit rather than main. Brackets in Google's
# variable-font filenames are URL-encoded (%5B, %5D).
GOOGLE_URL="https://raw.githubusercontent.com/google/fonts/cc39c4c2c304bc368c9b7c311ea2bcc6013299fe/ofl"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

have() {
    [ -z "${FORCE:-}" ] && [ -f "$FONTS_DIR/$1" ]
}

# fontshare <slug> <file>... — one zip per family; the variable TTFs live in
# <Family>_Complete/Fonts/TTF/ under the same names FONTS.md expects.
fontshare() {
    slug=$1
    shift
    missing=""
    for file in "$@"; do
        have "$file" || missing="$missing $file"
    done
    [ -n "$missing" ] || { echo "skip  $slug (present)"; return; }

    echo "fetch $slug"
    curl -fsSL -o "$WORK/$slug.zip" "$FONTSHARE_URL/$slug"
    for file in $missing; do
        unzip -o -j -q "$WORK/$slug.zip" "*/Fonts/TTF/$file" -d "$FONTS_DIR"
    done
}

# google <dir> <remote file> <local file> — straight from the google/fonts repo.
google() {
    have "$3" && { echo "skip  $3 (present)"; return; }
    echo "fetch $3"
    curl -fsSL -o "$FONTS_DIR/$3" "$GOOGLE_URL/$1/$2"
}

fontshare general-sans GeneralSans-Variable.ttf GeneralSans-VariableItalic.ttf
fontshare zodiak Zodiak-Variable.ttf Zodiak-VariableItalic.ttf
fontshare satoshi Satoshi-Variable.ttf Satoshi-VariableItalic.ttf
fontshare bevellier Bevellier-Variable.ttf Bevellier-VariableItalic.ttf
fontshare clash-grotesk ClashGrotesk-Variable.ttf
fontshare nippo Nippo-Variable.ttf
fontshare pilcrow-rounded PilcrowRounded-Variable.ttf
fontshare sentient Sentient-Variable.ttf Sentient-VariableItalic.ttf
fontshare supreme Supreme-Variable.ttf Supreme-VariableItalic.ttf
fontshare switzer Switzer-Variable.ttf Switzer-VariableItalic.ttf
fontshare technor Technor-Variable.ttf
# OFL, but fetched from Fontshare: its build registers as "Space Grotesk
# Variable" (what FontFamily.spaceGrotesk expects); Google's registers as
# plain "Space Grotesk" and would silently fall back to the system font.
fontshare space-grotesk SpaceGrotesk-Variable.ttf

google oswald 'Oswald%5Bwght%5D.ttf' Oswald-Variable.ttf
google grenze 'Grenze%5Bwght%5D.ttf' Grenze-VariableFont_wght.ttf
google grenze 'Grenze-Italic%5Bwght%5D.ttf' Grenze-Italic-VariableFont_wght.ttf
google grenzegotisch 'GrenzeGotisch%5Bwght%5D.ttf' GrenzeGotisch-VariableFont_wght.ttf

if ! (cd "$FONTS_DIR" && shasum -a 256 -c --quiet "$SCRIPTS_DIR/fonts.sha256"); then
    echo "error: fonts don't match scripts/fonts.sha256; see FONTS.md § Updating a font" >&2
    exit 1
fi

echo "Fonts ready and verified in $FONTS_DIR"
