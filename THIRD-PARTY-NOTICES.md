# Third-party notices

Jelly Shark is MIT licensed (see `LICENSE`). It bundles and links the work
listed below, which carries its own terms. Each license was read from the
upstream project at the version this repository pins — none is assumed from
convention.

## Bundled font

**Atkinson Hyperlegible Next**
Copyright 2020–2024 The Atkinson Hyperlegible Next Project Authors
<https://github.com/googlefonts/atkinson-hyperlegible-next>
SIL Open Font License, Version 1.1 — full text in
`Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/OFL.txt`

The two Atkinson Hyperlegible Next variable font files in that directory are
committed to this repository and ship inside the app bundle. They are the only
fonts redistributed here — the Fontshare / Indian Type Foundry families the
themes also use are git-ignored and must be downloaded separately, as their
EULA forbids redistribution. See `Resources/Fonts/FONTS.md`.

OFL 1.1 requires the license text to travel with the font binaries, which is
why `OFL.txt` sits beside them rather than only being referenced here.

## Swift Package Manager dependencies

Fetched at build time rather than vendored into this repository, but linked
into the shipped app. Versions are those pinned in `Package.resolved`.

**Get 2.2.1** — <https://github.com/kean/Get>
MIT License. Copyright (c) 2021–2024 Alexander Grebenyuk.

**URLQueryEncoder 0.2.1** — <https://github.com/CreateAPI/URLQueryEncoder>
MIT License. Copyright (c) 2022 Alexander Grebenyuk.

**jellyfin-sdk-swift 0.6.0** (module `JellyfinAPI`) —
<https://github.com/jellyfin/jellyfin-sdk-swift>
Mozilla Public License, Version 2.0. Copyright (c) Jellyfin & Jellyfin
Contributors. Full text: <https://mozilla.org/MPL/2.0/>

The MPL grant is made per-file via the license's own Exhibit A notice, carried
in the header of each source file, rather than by a `LICENSE` at the repository
root. GitHub's license API reports none for that repository for this reason;
the notice in the sources is the authoritative statement.

MPL 2.0 is a file-level copyleft: it reaches modifications to the SDK's own
files, not this application's separate files that merely link against it
(§1.10, §3.3). No SDK source is modified or vendored here, so the obligation is
attribution.

## Design tokens

`BaseColors` is the Tailwind CSS v4 palette, referenced by name and converted
from oklch. Tailwind CSS is MIT licensed (<https://github.com/tailwindlabs/tailwindcss>).
Listed for credit rather than obligation — colour values are facts, not
copyrightable expression.
