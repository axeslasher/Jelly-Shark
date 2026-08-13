import SwiftUI

extension Color {
    /// Initialize a Color from a hex string (without #)
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: UInt64
        switch hex.count {
        case 6: // RGB
            (r, g, b, a) = (
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF,
                255,
            )
        case 8: // RGBA
            (r, g, b, a) = (
                (int >> 24) & 0xFF,
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF,
            )
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255,
        )
    }
}

#Preview {
    let manager = ThemeManager.preview()
    HStack(spacing: SpacingTokens.sm) {
        // Six-digit RGB plus one eight-digit RGBA to show the alpha path.
        ForEach(["16202E", "C46C2A", "7A1018", "5AB4DC", "C46C2A80"], id: \.self) { hex in
            VStack(spacing: SpacingTokens.xxs) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: hex))
                    .frame(width: 140, height: 72)

                Text("#\(hex)")
                    .jsStyle(.small)
                    .foregroundStyle(manager.currentTheme.secondary)
            }
        }
    }
    .padding(SpacingTokens.xl)
    .withThemeEnvironment(manager)
}
