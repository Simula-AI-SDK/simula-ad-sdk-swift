import SwiftUI

extension Color {
    /// Initialize a Color from a hex string like "#FF5733", "FF5733", "#RRGGBBAA", or "rgba(r,g,b,a)".
    /// Supports 3-char (RGB), 6-char (RRGGBB), and 8-char (RRGGBBAA) hex formats.
    public init(hex: String) {
        // Handle rgba() format: "rgba(0, 0, 0, 0.08)"
        if hex.lowercased().hasPrefix("rgba(") {
            let inner = hex
                .replacingOccurrences(of: "rgba(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let components = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 4,
               let r = Double(components[0]),
               let g = Double(components[1]),
               let b = Double(components[2]),
               let a = Double(components[3]) {
                self.init(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
                return
            }
        }

        // Handle rgb() format: "rgb(0, 0, 0)"
        if hex.lowercased().hasPrefix("rgb(") {
            let inner = hex
                .replacingOccurrences(of: "rgb(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let components = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 3,
               let r = Double(components[0]),
               let g = Double(components[1]),
               let b = Double(components[2]) {
                self.init(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: 1.0)
                return
            }
        }

        // Handle "transparent"
        if hex.lowercased() == "transparent" {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 0)
            return
        }

        // Strip # prefix and any non-hex chars
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3: // RGB (12-bit) e.g. "F53"
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RRGGBB (24-bit) e.g. "FF5733"
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // RRGGBBAA (32-bit) e.g. "FF573380"
            (a, r, g, b) = (int & 0xFF, int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}
