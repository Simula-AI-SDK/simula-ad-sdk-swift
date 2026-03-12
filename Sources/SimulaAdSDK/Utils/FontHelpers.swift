import SwiftUI

/// Returns a font for the given family name, falling back to the system font.
func fontForFamily(_ family: String?, size: CGFloat, weight: Font.Weight) -> Font {
    if let family = family {
        return .custom(family, size: size).weight(weight)
    }
    return .system(size: size, weight: weight)
}
