import SwiftUI

extension Color {
    /// Initialize a Color from a hex string like "#FF5733", "FF5733", "#RRGGBBAA", or "rgba(r,g,b,a)".
    /// Supports 3-char (RGB), 6-char (RRGGBB), and 8-char (RRGGBBAA) hex formats.
    ///
    /// The parse (lowercasing + `replacingOccurrences` + `Scanner`) is cached by the raw input string,
    /// because this is called from animated SwiftUI bodies that re-evaluate the same theme colors many
    /// times per second. The cache stores the resolved sRGB components, so the produced `Color` is
    /// byte-identical to parsing fresh — it just skips the repeated string work.
    public init(hex: String) {
        let c = Color.rgbaComponents(for: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    // MARK: - Cached parse

    private typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    private static let hexCacheLock = NSLock()
    private static var hexCache: [String: RGBA] = [:]
    /// Bound the cache so adversarial/unbounded distinct inputs can't grow it without limit.
    private static let hexCacheMax = 256

    private static func rgbaComponents(for hex: String) -> RGBA {
        hexCacheLock.lock()
        if let cached = hexCache[hex] {
            hexCacheLock.unlock()
            return cached
        }
        hexCacheLock.unlock()

        let parsed = parseHex(hex)

        hexCacheLock.lock()
        // Simplest safe bound: drop everything once full (theme palettes are tiny, so this rarely trips).
        if hexCache.count >= hexCacheMax { hexCache.removeAll(keepingCapacity: true) }
        hexCache[hex] = parsed
        hexCacheLock.unlock()
        return parsed
    }

    /// Pure parse of a hex / rgb(a) / "transparent" string into sRGB components in 0...1.
    /// Identical logic (and fallbacks) to the original initializer.
    private static func parseHex(_ hex: String) -> RGBA {
        let lower = hex.lowercased()

        // rgba(0, 0, 0, 0.08)
        if lower.hasPrefix("rgba(") {
            let inner = hex
                .replacingOccurrences(of: "rgba(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let components = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 4,
               let r = Double(components[0]),
               let g = Double(components[1]),
               let b = Double(components[2]),
               let a = Double(components[3]) {
                return (r / 255.0, g / 255.0, b / 255.0, a)
            }
        }

        // rgb(0, 0, 0)
        if lower.hasPrefix("rgb(") {
            let inner = hex
                .replacingOccurrences(of: "rgb(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let components = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 3,
               let r = Double(components[0]),
               let g = Double(components[1]),
               let b = Double(components[2]) {
                return (r / 255.0, g / 255.0, b / 255.0, 1.0)
            }
        }

        // "transparent"
        if lower == "transparent" {
            return (0, 0, 0, 0)
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

        return (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0, Double(a) / 255.0)
    }
}
