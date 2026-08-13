import SwiftUI

#if DEBUG
    /// A one-page specimen of a theme — palette, type ramp, and geometry —
    /// rendered through the theme itself. Backs the per-theme previews so a
    /// curation pass can read a whole theme at a glance.
    struct ThemeSpecimen: View {
        let theme: any Theme

        init(theme: any Theme) {
            self.theme = theme
            // Previews construct this without a ThemeManager, which is what
            // normally registers the bundled fonts. Registration is idempotent.
            DesignSystemFonts.registerAll()
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: SpacingTokens.xl) {
                    Text(theme.name)
                        .jsStyle(.display)
                        .foregroundStyle(theme.primary)

                    Text(theme.description)
                        .jsStyle(.overview)
                        .foregroundStyle(theme.secondary)

                    palette
                    typeRamp
                    geometry
                }
                .padding(SpacingTokens.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .environment(\.theme, theme)
        }

        // MARK: - Palette

        private var colorEntries: [(name: String, color: Color)] {
            [
                ("background", theme.background),
                ("surface", theme.surface),
                ("surfaceElevated", theme.surfaceElevated),
                ("primary", theme.primary),
                ("secondary", theme.secondary),
                ("tertiary", theme.tertiary),
                ("accent", theme.accent),
                ("accentSecondary", theme.accentSecondary),
                ("success", theme.success),
                ("warning", theme.warning),
                ("error", theme.error),
                ("focusRing", theme.focusRing),
                ("focusFill", theme.focusFill ?? .clear),
                ("onPlatter", theme.onPlatter),
                ("onPlatterSecondary", theme.onPlatterSecondary),
            ]
        }

        private var palette: some View {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: SpacingTokens.sm)],
                alignment: .leading,
                spacing: SpacingTokens.sm,
            ) {
                ForEach(colorEntries, id: \.name) { entry in
                    VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .fill(entry.color)
                            .frame(height: 64)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .strokeBorder(theme.primary.opacity(0.15), lineWidth: 1),
                            )

                        Text(entry.name)
                            .jsStyle(.small)
                            .foregroundStyle(theme.secondary)
                    }
                }
            }
        }

        // MARK: - Type ramp

        private static let rampRoles: [(role: TypeRole, name: String)] = [
            (.display, "display"),
            (.headline, "headline"),
            (.title, "title"),
            (.overview, "overview"),
            (.body, "body"),
            (.caption, "caption"),
            (.small, "small"),
            (.eyebrow, "eyebrow"),
            (.certificate, "certificate"),
        ]

        private var typeRamp: some View {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                ForEach(Self.rampRoles, id: \.name) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: SpacingTokens.md) {
                        Text(entry.name)
                            .jsStyle(.caption)
                            .foregroundStyle(theme.tertiary)
                            .frame(width: 160, alignment: .leading)

                        Text("The lighthouse keeps its own weather")
                            .jsStyle(entry.role)
                            .foregroundStyle(theme.primary)
                            .lineLimit(1)
                    }
                }
            }
        }

        // MARK: - Geometry

        private var geometry: some View {
            HStack(spacing: SpacingTokens.lg) {
                geometrySample("cornerRadius", radius: theme.cornerRadius)
                geometrySample("cornerRadiusLarge", radius: theme.cornerRadiusLarge)
            }
        }

        private func geometrySample(_ name: String, radius: CGFloat) -> some View {
            VStack(spacing: SpacingTokens.xxs) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(theme.focusRing, lineWidth: theme.borderWidth),
                    )
                    .frame(width: 180, height: 100)

                Text(name)
                    .jsStyle(.small)
                    .foregroundStyle(theme.secondary)
            }
        }
    }
#endif
