# Fonts

Jelly Shark uses three free Fontshare families. **The `.ttf` binaries are NOT
committed** — the Fontshare EULA forbids redistributing the font files (no
uploading to a public server, no passing them on). Only this instructions file
is tracked; the font files are git-ignored. You must download them yourself.

If the files are missing the app still builds and runs — every text style falls
back to the system font (San Francisco). See `FontScheme.swift`.

## Download

1. Get each family:
   - General Sans — https://www.fontshare.com/fonts/general-sans
   - Zodiak — https://www.fontshare.com/fonts/zodiak
   - Satoshi — https://www.fontshare.com/fonts/satoshi
   - Space Grotesk — https://fonts.google.com/specimen/Space+Grotesk (Google Fonts; OFL)
2. Download the **variable** `.ttf` (upright + italic where available; Space
   Grotesk is upright only here).
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
   SpaceGrotesk-Variable.ttf
   ```

   If your downloads have different filenames, either rename them to match, or
   update the filename constants in `FontScheme.swift`.

## Verifying the PostScript / family names

`Font.custom(_:)` needs the font's registered name. The names assumed in
`FontScheme.swift` are best-guesses. To confirm what the OS actually registered,
the app prints every registered Jelly Shark font name to the console on launch
in DEBUG builds (`DesignSystemFonts.debugPrintRegisteredNames()`). If a font
isn't applying, check that console output and fix the name constants.

## License

- **General Sans, Zodiak, Satoshi** — Fontshare Free Font EULA (Indian Type
  Foundry). Free for commercial use, including embedding in apps.
  **Redistribution of the font files is prohibited** — hence the git-ignore.
- **Space Grotesk** — SIL Open Font License (OFL), which *does* permit
  redistribution. It's git-ignored anyway for consistency; you may commit it if
  you prefer (loosen the `.gitignore`).

Keep this file in sync if the families change.
