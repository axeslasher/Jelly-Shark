# SF Symbols → Figma `icon` set

Regenerates the Figma library's `icon` component set from the SF Symbols app, sized and placed
exactly as SwiftUI lays out `Image(systemName:)` at 18pt. Re-run it when a symbol is added to the
app, or when a new OS changes Apple's artwork.

## Run it

1. Check the symbol list covers the code: `scripts/figma/sf-symbols/run.sh --check`.
   Add any name it reports to `symbols.txt`.
2. Generate the SVGs: `scripts/figma/sf-symbols/run.sh` (or `run.sh <name>…` for a few).
   They land in `out/svg/`, one per symbol.
3. Upload them to the Icons page with the Figma MCP's `upload_assets` tool (at most 60 per
   call), POSTing each file as `multipart/form-data` with `file=@<name>.svg;type=image/svg+xml`
   so the frame takes the symbol's name.
4. Run `assemble.js` through the MCP's `use_figma` tool. It rebuilds existing variants in place
   and adds new ones. Split a large run with its `ONLY` filter if a call times out.
5. Screenshot the set on a dark background and compare it with SwiftUI's own render.

Needs: SF Symbols installed in `/Applications` (or `SFSYMBOLS=…/sfsymbols`), Xcode with a tvOS
simulator runtime, and the Figma MCP.

## What each icon is

| Part | Source |
|---|---|
| Component size | SwiftUI's layout box for the symbol — what an `HStack` spaces by. No shared bounding box. |
| Outline | The `Regular-S` master from `sfsymbols export --format svg`, scaled ×0.2284 (fitted against 70 renders; mean error 0.13pt). |
| Position | Centred on the ink SwiftUI draws, measured by `probe.swift`. |
| Layer opacity | Read off the same render: 0 is a knockout, between 0 and 1 a hierarchical layer (`tv`, `hifispeaker.fill` default to one). |
| Fill | Bound to `Theme › color/primary`. Constraints scale the glyph with a resized instance. |

tvOS and visionOS renders were byte-identical for all 70 symbols, so the probe runs on tvOS
only. Weight is regular and scale medium throughout, matching the app's code.

Nothing Apple ships is committed: the outlines are regenerated from the local SF Symbols app
on every run, inside its licence.

## Why not the obvious routes

- **Copy as SVG** from the SF Symbols app pads some frames and not others, and its glyphs are
  about 0.25pt larger than what SwiftUI draws.
- **`sfsymbols export --format pdf`** is about 0.3pt small and turns knockouts into bitmaps.
- **`NSImage` drawn into a PDF** is always a bitmap.
