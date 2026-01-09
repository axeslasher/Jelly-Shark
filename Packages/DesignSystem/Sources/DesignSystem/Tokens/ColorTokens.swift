import SwiftUI

/// Color tokens used throughout the design system
/// These are semantic colors that map to theme-specific values
public enum ColorTokens {
    // MARK: - Standard Theme Colors (Dark Mode - Primary for TV)

    public enum Standard {
        // Backgrounds
        public static let background = Color(hex: "000000")
        public static let surface = Color(hex: "1C1C1E")
        public static let surfaceElevated = Color(hex: "2C2C2E")

        // Content
        public static let primary = Color(hex: "F5F5F7")
        public static let secondary = Color(hex: "8E8E93")
        public static let tertiary = Color(hex: "636366")

        // Accent
        public static let accent = Color(hex: "0A84FF")
        public static let accentSecondary = Color(hex: "5E5CE6")

        // Semantic
        public static let success = Color(hex: "30D158")
        public static let warning = Color(hex: "FFD60A")
        public static let error = Color(hex: "FF453A")

        // Focus
        public static let focusRing = Color.white.opacity(0.8)
    }

    // MARK: - Horror Theme Colors (Dark Mode)

    public enum Horror {
        public static let background = Color(hex: "0A0A0A")
        public static let surface = Color(hex: "1A1A1A")
        public static let surfaceElevated = Color(hex: "2A2A2A")

        public static let primary = Color(hex: "E8E5E0")
        public static let secondary = Color(hex: "8B8B8B")
        public static let tertiary = Color(hex: "5A5A5A")

        public static let accent = Color(hex: "B22222")
        public static let accentSecondary = Color(hex: "660000")

        public static let success = Color(hex: "4A7C59")
        public static let warning = Color(hex: "CC9900")
        public static let error = Color(hex: "DC143C")

        public static let focusRing = Color(hex: "B22222").opacity(0.8)
    }

    // MARK: - Action Theme Colors (Dark Mode)

    public enum Action {
        public static let background = Color(hex: "0F1419")
        public static let surface = Color(hex: "1A1F25")
        public static let surfaceElevated = Color(hex: "252B33")

        public static let primary = Color(hex: "E5F1FF")
        public static let secondary = Color(hex: "8BA4BE")
        public static let tertiary = Color(hex: "5A6B7D")

        public static let accent = Color(hex: "00E5FF")
        public static let accentSecondary = Color(hex: "00B4D8")

        public static let success = Color(hex: "00FF87")
        public static let warning = Color(hex: "FFE500")
        public static let error = Color(hex: "FF3366")

        public static let focusRing = Color(hex: "00E5FF").opacity(0.8)
    }

    // MARK: - Video Store Theme Colors (Dark Mode)

    public enum VideoStore {
        public static let background = Color(hex: "001D3D")
        public static let surface = Color(hex: "002952")
        public static let surfaceElevated = Color(hex: "003566")

        public static let primary = Color(hex: "FAF5E8")
        public static let secondary = Color(hex: "B8B0A0")
        public static let tertiary = Color(hex: "7A7468")

        public static let accent = Color(hex: "FFD700")
        public static let accentSecondary = Color(hex: "4A90E2")

        public static let success = Color(hex: "7CB342")
        public static let warning = Color(hex: "FFA726")
        public static let error = Color(hex: "EF5350")

        public static let focusRing = Color(hex: "FFD700").opacity(0.8)
    }
}

// MARK: - Color Extension for Hex

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
                255
            )
        case 8: // RGBA
            (r, g, b, a) = (
                (int >> 24) & 0xFF,
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF
            )
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
