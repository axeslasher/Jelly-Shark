# Fonts

Jelly Shark uses several variable fonts. Two licensing situations:

- **Fontshare / Indian Type Foundry families** (General Sans, Zodiak, Satoshi,
  Bevellier, Clash Grotesk, Nippo, Pilcrow Rounded, Sentient, Supreme, Switzer,
  Technor) — the EULA forbids redistributing the font files, so these are
  **git-ignored** and you must download them yourself (steps below).
- **OFL families** (Space Grotesk, Oswald, Grenze, Grenze Gotisch, Atkinson
  Hyperlegible Next) — the Open Font License permits redistribution. Atkinson
  **is committed** to the repo (it's earmarked for a future accessibility
  setting). The rest are git-ignored for consistency, but you may commit them
  if you like.

If a font file is missing the app still builds and runs — every text style falls
back to the system font (San Francisco). See `FontScheme.swift`.

## Download

1. Get each family:
   - General Sans — https://www.fontshare.com/fonts/general-sans
   - Zodiak — https://www.fontshare.com/fonts/zodiak
   - Satoshi — https://www.fontshare.com/fonts/satoshi
   - Bevellier — https://www.fontshare.com/fonts/bevellier
   - Clash Grotesk — https://www.fontshare.com/fonts/clash-grotesk
   - Nippo — https://www.fontshare.com/fonts/nippo
   - Pilcrow Rounded — https://www.fontshare.com/fonts/pilcrow-rounded
   - Sentient — https://www.fontshare.com/fonts/sentient
   - Supreme — https://www.fontshare.com/fonts/supreme
   - Switzer — https://www.fontshare.com/fonts/switzer
   - Technor — https://www.fontshare.com/fonts/technor
   - Space Grotesk — https://fonts.google.com/specimen/Space+Grotesk (Google Fonts; OFL)
   - Oswald — https://fonts.google.com/specimen/Oswald (Google Fonts; OFL)
   - Grenze — https://fonts.google.com/specimen/Grenze (Google Fonts; OFL)
   - Grenze Gotisch — https://fonts.google.com/specimen/Grenze+Gotisch (Google Fonts; OFL)
2. Download the **variable** `.ttf` (upright + italic where available).
3. Drop the files into THIS folder
   (`Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/`)
   with these exact names:

   ```
   GeneralSans-Variable.ttf
   GeneralSans-VariableItalic.ttf
   Zodiak-Variable.ttf
   Zodiak-VariableItalic.ttf
   Satoshi-Variable.ttf
   Satoshi-VariableItalic.ttf
   Bevellier-Variable.ttf
   Bevellier-VariableItalic.ttf
   ClashGrotesk-Variable.ttf
   Nippo-Variable.ttf
   PilcrowRounded-Variable.ttf
   Sentient-Variable.ttf
   Sentient-VariableItalic.ttf
   Supreme-Variable.ttf
   Supreme-VariableItalic.ttf
   Switzer-Variable.ttf
   Switzer-VariableItalic.ttf
   Technor-Variable.ttf
   SpaceGrotesk-Variable.ttf
   Oswald-Variable.ttf
   Grenze-VariableFont_wght.ttf
   Grenze-Italic-VariableFont_wght.ttf
   GrenzeGotisch-VariableFont_wght.ttf
   ```

   Already committed (no download needed):

   ```
   AtkinsonHyperlegibleNext-VariableFont_wght.ttf
   AtkinsonHyperlegibleNext-Italic-VariableFont_wght.ttf
   ```

   `Font.custom(_:)` resolves these by family NAME, not filename, so the exact
   file names above don't have to match — but keep them consistent for clarity.

No further wiring is needed: `Package.swift` bundles every `.ttf` in this
folder, `DesignSystemFonts.registerAll()` registers whatever it finds at
launch, and `FontFamily` in `FontScheme.swift` holds the registered family
name for each face.

## Verifying the PostScript / family names

`Font.custom(_:)` needs the font's registered name. To confirm what the OS
actually registered, the app prints every registered Jelly Shark font name to
the console on launch in DEBUG builds
(`DesignSystemFonts.debugPrintRegisteredNames()`). If a font isn't applying,
check that console output and fix the `FontFamily` constants. The registered
family names for all files above are recorded in `FontScheme.swift` (verified
against the actual binaries — note Oswald registers as plain `"Oswald"`, no
"Variable" suffix).

## License

- **Fontshare families** (General Sans, Zodiak, Satoshi, Bevellier, Clash
  Grotesk, Nippo, Pilcrow Rounded, Sentient, Supreme, Switzer, Technor) —
  Fontshare Free Font EULA (Indian Type Foundry). Free for commercial use,
  including embedding in apps. **Redistribution of the font files is
  prohibited** — hence the git-ignore.
- **Space Grotesk, Oswald, Grenze, Grenze Gotisch** — SIL Open Font License
  (OFL), which *does* permit redistribution. Git-ignored anyway for
  consistency; you may commit them if you prefer (loosen the `.gitignore`).
- **Atkinson Hyperlegible Next** — SIL Open Font License (OFL), Braille
  Institute. Committed to the repo (a `!` exception in `.gitignore`).

Keep this file in sync if the families change.
