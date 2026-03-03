import Foundation
import CoreGraphics

// MARK: - WidthValue

/// Represents a parsed width/offset value (translates `parseWidth.ts`)
public enum WidthValue: Sendable, Equatable {
    /// Fixed pixel value
    case pixels(CGFloat)
    /// Fraction of container (0.0 - 1.0)
    case fraction(CGFloat)
    /// Fill available width (100%)
    case fill

    /// Resolves this value to an actual CGFloat given a container width
    public func resolve(in containerWidth: CGFloat) -> CGFloat {
        switch self {
        case .pixels(let px):
            return px
        case .fraction(let f):
            return containerWidth * f
        case .fill:
            return containerWidth
        }
    }
}

// MARK: - parseWidth

/// Parses a width value from various input formats.
/// - number < 1: percentage as decimal (e.g., 0.8 = 80%)
/// - number >= 1: pixels (e.g., 500 = 500px)
/// - string with %: percentage (e.g., "80%" = 80%)
/// - string with px: pixels (e.g., "500px" = 500px)
/// - string with plain number: pixels (e.g., "500" = 500px)
/// - nil / "auto" / "": fill (100%)
public func parseWidth(_ value: Any?) -> WidthValue {
    guard let value = value else { return .fill }

    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            return .fill
        }
        // Handle percentage string: "80%"
        if trimmed.hasSuffix("%"), let num = Double(trimmed.dropLast()) {
            if num > 0 && num <= 100 {
                return .fraction(CGFloat(num / 100.0))
            }
        }
        // Handle pixel string: "500px"
        if trimmed.lowercased().hasSuffix("px"), let num = Double(trimmed.dropLast(2)) {
            if num > 0 {
                return .pixels(CGFloat(num))
            }
        }
        // Handle plain number string: "500"
        if let num = Double(trimmed), num > 0 {
            return .pixels(CGFloat(num))
        }
        return .fill
    }

    if let number = value as? Double {
        if number > 0 && number < 1 {
            return .fraction(CGFloat(number))
        }
        if number >= 1 {
            return .pixels(CGFloat(number))
        }
    }

    if let number = value as? CGFloat {
        if number > 0 && number < 1 {
            return .fraction(number)
        }
        if number >= 1 {
            return .pixels(number)
        }
    }

    if let number = value as? Int {
        if number >= 1 {
            return .pixels(CGFloat(number))
        }
    }

    return .fill
}

// MARK: - parseOffset

/// Parses an offset value (top, right, etc.) from various input formats.
/// Same format as width: number < 1 = percentage, number >= 1 = pixels, etc.
public func parseOffset(_ value: Any?) -> WidthValue? {
    guard let value = value else { return nil }

    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%"), let num = Double(trimmed.dropLast()) {
            return .fraction(CGFloat(num / 100.0))
        }
        if let num = Double(trimmed) {
            return .pixels(CGFloat(num))
        }
        return nil
    }

    if let number = value as? Double {
        if number >= 0 && number < 1 {
            return .fraction(CGFloat(number))
        }
        if number >= 1 {
            return .pixels(CGFloat(number))
        }
        if number == 0 {
            return .pixels(0)
        }
    }

    if let number = value as? CGFloat {
        if number >= 0 && number < 1 {
            return .fraction(number)
        }
        if number >= 1 {
            return .pixels(number)
        }
        if number == 0 {
            return .pixels(0)
        }
    }

    if let number = value as? Int {
        return .pixels(CGFloat(number))
    }

    return nil
}
